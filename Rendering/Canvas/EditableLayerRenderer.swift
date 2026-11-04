import Foundation
import Metal

/// Serialized by PreviewWorker. Rebuilds a derived surface without mutating the live document.
final class EditableLayerRenderer: @unchecked Sendable {
    private let metal: MetalDeviceContext
    private let serializer: LayerTextureSerializer
    private var imageRenderer: PatternPlacementRenderer?
    private var textureRenderer: SelectionFillRenderer?
    private var linearRenderer: LinearGradientRenderer?
    private var sectorRenderer: SectorGradientRenderer?

    init(metal: MetalDeviceContext, serializer: LayerTextureSerializer) {
        self.metal = metal; self.serializer = serializer
    }

    func renderRetainingCrop(_ content: EditableLayerContent, canvas: CanvasSize, layerID: LayerID,
                            retainedBounds: PixelRegion?, cancellation: WorkCancellation) throws -> (texture: MTLTexture, retained: [RetainedCropTile]?) {
        let visible = PixelRegion(originX: 0, originY: 0, width: canvas.width, height: canvas.height)
        guard let full = retainedBounds, full != visible else {
            return (try render(content, canvas: canvas, cancellation: cancellation), nil)
        }
        var expanded = content
        expanded.crop(originX: full.originX, originY: full.originY)
        let entire = try render(expanded, canvas: .init(width: full.width, height: full.height), cancellation: cancellation)
        let output = try crop(entire, origin: .init(x: Double(-full.originX), y: Double(-full.originY)), canvas: canvas, cancellation: cancellation)
        guard let grid = TileGrid(canvasSize: .init(width: full.width, height: full.height)) else { throw CocoaError(.fileReadCorruptFile) }
        var retained: [RetainedCropTile] = []
        for excluded in full.subtracting(visible) {
            for tile in grid.intersections(with: excluded.translatedBy(x: -full.originX, y: -full.originY)) {
                try cancellation.check()
                let region = tile.canvasRegion
                let snapshot = try serializer.snapshot(texture: entire, originX: region.originX, originY: region.originY, width: region.width, height: region.height)
                if snapshot.pixelData.allSatisfy({ $0 == 0 }) { continue }
                retained.append(try NonDestructiveCanvasCrop.encode(snapshot.pixelData, key: .init(layerID: layerID, kind: .content),
                    region: region.translatedBy(x: full.originX, y: full.originY), encoding: snapshot.encoding))
            }
        }
        return (output, retained)
    }

    func render(_ content: EditableLayerContent, canvas: CanvasSize, cancellation: WorkCancellation) throws -> MTLTexture {
        try content.validate(); try cancellation.check()
        guard canvas.width > 0, canvas.height > 0, canvas.width <= 32768, canvas.height <= 32768 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let origin = content.canvasOrigin ?? .init(x: 0, y: 0)
        if case .image = content.operation {} else if origin != .init(x: 0, y: 0) || canvas.width != content.source.width || canvas.height != content.source.height {
            var original = content; original.canvasOrigin = nil
            let full = try render(original, canvas: .init(width: content.source.width, height: content.source.height), cancellation: cancellation)
            return try crop(full, origin: origin, canvas: canvas, cancellation: cancellation)
        }
        let format = content.source.encoding.metalPixelFormat
        let bytes = (content.source.width * content.source.height + canvas.width * canvas.height) * content.source.encoding.bytesPerPixel
        let reservation = try metal.workingResourceBudget.reserve(bytes: bytes, residentBytes: metal.device.currentAllocatedSize)
        defer { withExtendedLifetime(reservation) {} }
        func texture(_ width: Int, _ height: Int) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .private; descriptor.usage = [.shaderRead, .renderTarget]
            guard let texture = metal.device.makeTexture(descriptor: descriptor) else { throw CanvasResourceError(message: "无法分配可编辑图层") }
            return texture
        }
        let source = try texture(content.source.width, content.source.height)
        try serializer.restore(snapshot: content.source.snapshot(), into: source)
        try cancellation.check()
        let result = try texture(canvas.width, canvas.height)
        guard let command = metal.commandQueue.makeCommandBuffer() else { throw CanvasResourceError(message: "无法创建可编辑图层命令") }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = result
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)

        switch content.operation {
        case .image(let placement):
            if placement == .init(), origin == .init(x: 0, y: 0), source.width == canvas.width, source.height == canvas.height {
                // Identity is a byte-exact restoration, not another sampled render.
                guard let blit = command.makeBlitCommandEncoder() else { throw CanvasResourceError(message: "无法还原源图") }
                blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
                          sourceSize: .init(width: source.width, height: source.height, depth: 1), to: result,
                          destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init(x: 0, y: 0, z: 0))
                blit.endEncoding()
            } else {
                if imageRenderer == nil { imageRenderer = try PatternPlacementRenderer(device: metal.device) }
                guard let clear = command.makeRenderCommandEncoder(descriptor: pass) else { throw CanvasResourceError(message: "无法清理图像预览") }
                clear.endEncoding(); pass.colorAttachments[0].loadAction = .load
                let width = Double(source.width) * abs(placement.scaleX), height = Double(source.height) * abs(placement.scaleY)
                let rect = CGRect(x: (Double(source.width) - width) / 2 + placement.translation.x - origin.x,
                                  y: (Double(source.height) - height) / 2 + placement.translation.y - origin.y, width: width, height: height)
                guard imageRenderer!.encode(into: pass, commandBuffer: command, sourceTexture: source, canvasSize: canvas,
                    destinationRect: rect, flipHorizontally: placement.scaleX < 0, flipVertically: placement.scaleY < 0,
                    rotationDegrees: placement.rotationDegrees) else { throw CanvasResourceError(message: "无法绘制无损图像") }
            }
        case .texture(let fill):
            try copyBase(source, to: result, command: command)
            pass.colorAttachments[0].loadAction = .load
            if textureRenderer == nil { textureRenderer = SelectionFillRenderer(device: metal.device) }
            let bounds = fill.shape.bounds
            guard [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY].allSatisfy(\.isFinite) else { throw CocoaError(.fileReadCorruptFile) }
            let x = Int(max(0, min(Double(canvas.width), floor(bounds.minX))))
            let y = Int(max(0, min(Double(canvas.height), floor(bounds.minY))))
            let right = Int(max(0, min(Double(canvas.width), ceil(bounds.maxX))))
            let bottom = Int(max(0, min(Double(canvas.height), ceil(bounds.maxY))))
            guard right > x, bottom > y else { throw CanvasResourceError(message: "纹理区域为空") }
            let mask = SelectionMaskRasterizer.selectionMaskRegion(for: fill.shape, canvasSize: canvas,
                originX: x, originY: y, width: right - x, height: bottom - y)
            let material = try fill.material.decoded(maximumBytes: 64 * 1024 * 1024)
            guard textureRenderer!.encode(into: pass, commandBuffer: command, canvasSize: canvas,
                selectionMaskOriginX: x, selectionMaskOriginY: y, selectionMaskWidth: mask.width, selectionMaskHeight: mask.height,
                selectionMaskAlphaBytes: mask.alphaBytes, fillCenter: fill.anchor, color: fill.color,
                paintJitterAmount: fill.jitter, paintContrastAmount: fill.contrast,
                alphaLockTexture: fill.alphaLocked ? source : nil, materialTextureData: material,
                materialScale: fill.scale, materialCoverage: fill.coverage, materialVariation: fill.variation,
                materialSeed: fill.seed, materialAngleRadians: fill.angle, materialArrangement: fill.arrangement) else {
                throw CanvasResourceError(message: "无法重建纹理图层")
            }
        case .gradient(let fill):
            try copyBase(source, to: result, command: command)
            pass.colorAttachments[0].loadAction = .load
            let ok: Bool
            switch fill.geometry {
            case .linear(let geometry):
                if linearRenderer == nil { linearRenderer = LinearGradientRenderer(device: metal.device) }
                ok = linearRenderer!.encode(into: pass, commandBuffer: command, canvasSize: canvas,
                    pointA: geometry.pointA, pointB: geometry.pointB, pointC: geometry.pointC,
                    transitionMidpoint: Float(geometry.transitionMidpoint), color: fill.color, settings: fill.settings,
                    paintJitterAmount: fill.jitter, paintContrastAmount: fill.contrast, distortionAmount: fill.distortion,
                    selectionShape: fill.selection, alphaLockTexture: fill.alphaLocked ? source : nil)
            case .sector(let geometry):
                if sectorRenderer == nil { sectorRenderer = SectorGradientRenderer(device: metal.device) }
                ok = sectorRenderer!.encode(into: pass, commandBuffer: command, canvasSize: canvas,
                    center: geometry.center, pathPoints: geometry.pathPoints, maxRadius: geometry.maxRadius,
                    color: fill.color, settings: fill.settings, paintJitterAmount: fill.jitter,
                    paintContrastAmount: fill.contrast, distortionAmount: fill.distortion, maskQuality: .commit,
                    selectionShape: fill.selection, alphaLockTexture: fill.alphaLocked ? source : nil)
            }
            guard ok else { throw CanvasResourceError(message: "无法重建渐变图层") }
        }
        try cancellation.check()
        command.commit(); command.waitUntilCompleted()
        try cancellation.check()
        guard command.status == .completed else { throw CanvasResourceError(message: "可编辑图层渲染失败") }
        return result
    }

    private func copyBase(_ source: MTLTexture, to target: MTLTexture, command: MTLCommandBuffer) throws {
        guard source.width == target.width, source.height == target.height,
              let blit = command.makeBlitCommandEncoder() else { throw CanvasResourceError(message: "源素材与画布尺寸不一致") }
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
                  sourceSize: .init(width: source.width, height: source.height, depth: 1), to: target,
                  destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init(x: 0, y: 0, z: 0))
        blit.endEncoding()
    }

    private func crop(_ source: MTLTexture, origin: CanvasPoint, canvas: CanvasSize, cancellation: WorkCancellation) throws -> MTLTexture {
        let reservation = try metal.workingResourceBudget.reserve(bytes: canvas.width * canvas.height * (source.pixelFormat == .rgba16Float ? 8 : 4),
            residentBytes: metal.device.currentAllocatedSize)
        defer { withExtendedLifetime(reservation) {} }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: source.pixelFormat, width: canvas.width, height: canvas.height, mipmapped: false)
        descriptor.storageMode = .private; descriptor.usage = [.shaderRead, .renderTarget]
        guard let output = metal.device.makeTexture(descriptor: descriptor), let command = metal.commandQueue.makeCommandBuffer() else { throw CanvasResourceError(message: "无法生成裁剪后的可编辑图层") }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output; pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let clear = command.makeRenderCommandEncoder(descriptor: pass) else { throw CanvasResourceError(message: "无法清理裁剪区域") }
        clear.endEncoding()
        let view = PixelRegion(originX: Int(origin.x), originY: Int(origin.y), width: canvas.width, height: canvas.height)
        if let overlap = view.intersection(with: .init(originX: 0, originY: 0, width: source.width, height: source.height)) {
            guard let blit = command.makeBlitCommandEncoder() else { throw CanvasResourceError(message: "无法复制裁剪区域") }
            blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: overlap.originX, y: overlap.originY, z: 0),
                sourceSize: .init(width: overlap.width, height: overlap.height, depth: 1), to: output, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: .init(x: overlap.originX - view.originX, y: overlap.originY - view.originY, z: 0))
            blit.endEncoding()
        }
        try cancellation.check(); command.commit(); command.waitUntilCompleted(); try cancellation.check()
        guard command.status == .completed else { throw CanvasResourceError(message: "裁剪图层渲染失败") }
        return output
    }
}

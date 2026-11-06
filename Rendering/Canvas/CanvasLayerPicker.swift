import Foundation
import Metal

/// Hit testing shares the canvas input plan, but does not occlude lower candidates:
/// the chooser must let the artist reach content under overlapping paint.
@MainActor
final class CanvasLayerPicker {
    struct Readback: @unchecked Sendable {
        struct Entry: Sendable {
            let candidate: CanvasLayerPickCandidate
            let content: Int
            let mask: Int?
            let clip: Int?
            let clipMask: Int?
            let opacity: Float
        }
        let pixels: DeferredLayerRegionSnapshots
        let entries: [Entry]

        nonisolated func read() throws -> [CanvasLayerPickCandidate] {
            let snapshots = try pixels.read()
            return entries.compactMap { entry in
                func alpha(_ index: Int?) -> Float {
                    index.map { snapshots[$0].linearPixel(x: 0, y: 0).alpha } ?? 1
                }
                func mask(_ index: Int?) -> Float {
                    index.map { snapshots[$0].linearPixel(x: 0, y: 0).red } ?? 1
                }
                let coverage = alpha(entry.content) * mask(entry.mask) * alpha(entry.clip) * mask(entry.clipMask) * entry.opacity
                return coverage.isFinite && coverage >= (1.0 / 255.0) ? entry.candidate : nil
            }
        }
    }

    private var previewPresenter: StageOneCanvasPresenter?

    private func plan(document: ArtDocument, surfaces: StageOneLayerSurfaceStore) throws -> CanvasCompositeInputPlan {
        try .make(document: document,
            textureForLayer: { id in surfaces.surfaceID(for: id).flatMap { surfaces.readTexture(for: $0) } },
            enabledMaskTextureForLayer: { surfaces.readMaskTexture(for: $0) })
    }

    func enqueue(at point: CanvasPoint, document: ArtDocument, surfaces: StageOneLayerSurfaceStore,
                 serializer: LayerTextureSerializer) throws -> Readback {
        guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0,
              point.x < Double(document.canvasSize.width), point.y < Double(document.canvasSize.height) else {
            return .init(pixels: try serializer.enqueueRegionSnapshots([]), entries: [])
        }
        var requests: [LayerTextureRegionSnapshotRequest] = []
        var indices: [ObjectIdentifier: Int] = [:]
        func index(_ texture: MTLTexture?) -> Int? {
            guard let texture else { return nil }
            let key = ObjectIdentifier(texture)
            if let found = indices[key] { return found }
            let next = requests.count
            indices[key] = next
            requests.append(.init(texture: texture, originX: Int(point.x), originY: Int(point.y), width: 1, height: 1))
            return next
        }
        let entries = try plan(document: document, surfaces: surfaces).entries.reversed().compactMap { entry -> Readback.Entry? in
            guard let layer = document.layer(entry.layerID), !layer.isAdjustmentLayer, entry.input.opacity > 0 else { return nil }
            var groups: [String] = []
            var parent = layer.parentID
            var visited: Set<LayerID> = [layer.id]
            while let id = parent, visited.insert(id).inserted, let group = document.layer(id) {
                groups.append(group.name); parent = group.parentID
            }
            return .init(candidate: .init(id: layer.id, name: layer.name,
                groupPath: groups.reversed().joined(separator: " / "),
                isLocked: document.isLayerEffectivelyLocked(layer.id), isEditableFill: layer.editableContent != nil),
                content: index(entry.input.texture)!, mask: index(entry.input.layerMaskTexture),
                clip: index(entry.input.clipMaskTexture), clipMask: index(entry.input.clipLayerMaskTexture), opacity: entry.input.opacity)
        }
        return .init(pixels: try serializer.enqueueRegionSnapshots(requests), entries: entries)
    }

    /// The canvas shader scales directly into a small transparent target. No
    /// whole-layer CPU readback, and no temporary changes to document visibility.
    func enqueuePreview(layerID: LayerID, document: ArtDocument, surfaces: StageOneLayerSurfaceStore,
                        serializer: LayerTextureSerializer, metal: MetalDeviceContext) throws -> DeferredLayerRegionSnapshots {
        guard let entry = try plan(document: document, surfaces: surfaces).entries.first(where: { $0.layerID == layerID }) else {
            throw CancellationError()
        }
        let scale = min(1, 256.0 / Double(max(document.canvasSize.width, document.canvasSize.height)))
        let width = max(1, Int(Double(document.canvasSize.width) * scale))
        let height = max(1, Int(Double(document.canvasSize.height) * scale))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private; descriptor.usage = [.renderTarget, .shaderRead]
        guard let target = metal.device.makeTexture(descriptor: descriptor),
              let command = metal.commandQueue.makeCommandBuffer() else { throw CocoaError(.coderInvalidValue) }
        if previewPresenter == nil { previewPresenter = try StageOneCanvasPresenter(device: metal.device) }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        var input = entry.input
        input.blendMode = .normal // Isolated content preview, not a claim about its blend against other layers.
        guard previewPresenter?.encode(layerInputs: [input], samplingMode: .linear, into: pass, commandBuffer: command) == true else {
            throw CocoaError(.coderInvalidValue)
        }
        command.commit()
        let readback = try serializer.enqueueRegionSnapshots([.init(texture: target, originX: 0, originY: 0, width: width, height: height)])
        return .init {
            let result = try readback.read()
            guard command.status == .completed else { throw command.error ?? CocoaError(.fileReadUnknown) }
            return result
        }
    }
}

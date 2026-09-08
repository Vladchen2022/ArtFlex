import Foundation
import Metal

struct CanvasResourceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Prepares a complete replacement without changing the source store. Color and mask
/// resources always travel together; groups carry metadata, never pixel textures.
enum LayerSurfaceTransfer {
    /// Validate first, then share immutable resources. Mutable access detaches in the store.
    static func share(document: ArtDocument, source: StageOneLayerSurfaceStore) throws -> StageOneLayerSurfaceStore {
        for layer in document.paintLayers {
            guard let id = source.surfaceID(for: layer.id), let texture = source.readTexture(for: id),
                  texture.width == document.canvasSize.width, texture.height == document.canvasSize.height else {
                throw CanvasResourceError(message: "图层资源不完整，无法创建方案；原画稿未修改")
            }
            if layer.mask != nil {
                guard let mask = source.readMaskTexture(for: layer.id),
                      mask.width == texture.width, mask.height == texture.height else {
                    throw CanvasResourceError(message: "图层蒙版不完整，无法创建方案；原画稿未修改")
                }
            }
        }
        return source.sharedCopy()
    }

    static func prepare(
        document: ArtDocument,
        source: StageOneLayerSurfaceStore,
        metal: MetalDeviceContext,
        targetSize: CanvasSize? = nil,
        originX: Int = 0,
        originY: Int = 0
    ) throws -> StageOneLayerSurfaceStore {
        let size = targetSize ?? document.canvasSize
        var targetDocument = document
        targetDocument.canvasSize = size
        let result = StageOneLayerSurfaceStore()
        _ = result.surfaceRecords(for: targetDocument)
        var copies: [(source: MTLTexture, target: MTLTexture, clear: Double)] = []
        for layer in document.paintLayers {
            guard let sourceID = source.surfaceID(for: layer.id),
                  let color = source.readTexture(for: sourceID),
                  let targetID = result.surfaceID(for: layer.id),
                  let target = result.makeTexture(width: size.width, height: size.height, pixelFormat: color.pixelFormat, metal: metal)
            else { throw CanvasResourceError(message: "无法准备图层“\(layer.name)”；原画稿未修改") }
            result.swapTexture(for: targetID, with: target)
            copies.append((color, target, 0))
            if layer.mask != nil {
                guard let mask = source.readMaskTexture(for: layer.id),
                      let targetMask = result.makeTexture(
                        width: size.width, height: size.height, pixelFormat: .r8Unorm,
                        usage: [.shaderRead, .shaderWrite, .renderTarget], storageMode: .private, metal: metal
                      )
                else { throw CanvasResourceError(message: "无法准备图层“\(layer.name)”的蒙版；原画稿未修改") }
                result.setMaskTexture(targetMask, for: layer.id)
                copies.append((mask, targetMask, 1))
            }
            if source.isKnownTransparent(layerID: layer.id) {
                result.markKnownTransparent(for: layer.id)
            }
        }
        guard !copies.isEmpty else { return result }
        guard let command = metal.commandQueue.makeCommandBuffer() else {
            throw CanvasResourceError(message: "无法创建图层复制任务；原画稿未修改")
        }
        command.label = "ArtFlex complete layer transfer"
        for copy in copies {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = copy.target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(
                red: copy.clear, green: copy.clear, blue: copy.clear, alpha: copy.clear
            )
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
                throw CanvasResourceError(message: "无法初始化图层复制目标；原画稿未修改")
            }
            encoder.endEncoding()
        }
        let sx = max(0, originX), sy = max(0, originY)
        let width = max(0, min(originX + size.width, document.canvasSize.width) - sx)
        let height = max(0, min(originY + size.height, document.canvasSize.height) - sy)
        if width > 0, height > 0 {
            guard let blit = command.makeBlitCommandEncoder() else {
                throw CanvasResourceError(message: "无法编码图层复制；原画稿未修改")
            }
            for copy in copies {
                blit.copy(from: copy.source, sourceSlice: 0, sourceLevel: 0,
                          sourceOrigin: MTLOrigin(x: sx, y: sy, z: 0),
                          sourceSize: MTLSize(width: width, height: height, depth: 1),
                          to: copy.target, destinationSlice: 0, destinationLevel: 0,
                          destinationOrigin: MTLOrigin(x: sx - originX, y: sy - originY, z: 0))
            }
            blit.endEncoding()
        }
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw CanvasResourceError(message: command.error?.localizedDescription ?? "图层复制失败；原画稿未修改")
        }
        return result
    }
}

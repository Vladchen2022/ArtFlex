import Foundation
import Metal

struct PreparedProjectTextures: @unchecked Sendable {
    var textures: [(layerID: LayerID, resourceKind: LayerHistoryResourceKind, texture: MTLTexture)]
}

/// Background staging owns fresh textures exclusively until the document replacement commits.
final class ProjectOpenTextureStager: @unchecked Sendable {
    private let metal: MetalDeviceContext
    private let serializer: LayerTextureSerializer
    init(metal: MetalDeviceContext, serializer: LayerTextureSerializer) { self.metal = metal; self.serializer = serializer }

    func prepare(_ opened: OpenProjectResult, context: ProjectReadContext) throws -> PreparedProjectTextures {
        let size = opened.workspace.document.canvasSize
        var textures: [(layerID: LayerID, resourceKind: LayerHistoryResourceKind, texture: MTLTexture)] = []
        context.report(.uploading, total: opened.layerSnapshots.count)
        for (index, snapshot) in opened.layerSnapshots.enumerated() {
            textures.append(try prepare(snapshot, canvas: size, context: context))
            context.report(.uploading, completed: index + 1, total: opened.layerSnapshots.count)
        }
        return .init(textures: textures)
    }

    func prepare(_ snapshot: LayerHistorySnapshot, canvas size: CanvasSize, context: ProjectReadContext) throws
        -> (layerID: LayerID, resourceKind: LayerHistoryResourceKind, texture: MTLTexture) {
        let store = StageOneLayerSurfaceStore()
        try context.check()
        let reservation = try metal.workingResourceBudget.reserve(bytes: size.width * size.height * snapshot.texture.encoding.bytesPerPixel,
            residentBytes: metal.device.currentAllocatedSize)
        defer { withExtendedLifetime(reservation) {} }
        guard let texture = store.makeTexture(width: size.width, height: size.height,
            pixelFormat: snapshot.texture.encoding.metalPixelFormat, metal: metal) else {
            throw CanvasResourceError(message: "无法为工程准备图层，当前画稿未改变")
        }
        // Sparse snapshots need a defined transparent/white background outside their region.
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture; pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        let clear = snapshot.resourceKind == .mask ? 1.0 : 0.0
        pass.colorAttachments[0].clearColor = MTLClearColorMake(clear, clear, clear, clear)
        guard let command = metal.commandQueue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw CanvasResourceError(message: "无法清理工程图层")
        }
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { throw CanvasResourceError(message: "工程图层初始化失败") }
        try context.check()
        try serializer.restore(snapshot: snapshot.texture, into: texture, destinationX: snapshot.originX, destinationY: snapshot.originY)
        try context.check()
        return (snapshot.layerID, snapshot.resourceKind, texture)
    }

}

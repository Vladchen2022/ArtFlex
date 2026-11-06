import Foundation
import Metal

/// Owns a private candidate document and surface set. Discarding preparation cannot
/// mutate the live pixels, topology, or history; publication is one main-actor boundary.
final class LayerDocumentPreparation {
    var document: ArtDocument
    let surfaces: StageOneLayerSurfaceStore
    private let metal: MetalDeviceContext

    init(document: ArtDocument, source: StageOneLayerSurfaceStore, metal: MetalDeviceContext) throws {
        self.document = document; self.metal = metal
        surfaces = try LayerSurfaceTransfer.share(document: document, source: source)
    }

    func addLayer(named name: String? = nil) throws -> LayerID {
        let id = document.addLayer(named: name).id
        try surfaces.requireTextures(for: document, metal: metal)
        return id
    }

    func duplicateActiveLayer() throws -> LayerID {
        let sourceID = document.activeLayerID
        guard let layer = document.duplicateActiveLayer() else { throw CanvasResourceError(message: "当前图层不能复制") }
        try surfaces.shareLayerResources(from: sourceID, to: layer.id, document: document)
        try surfaces.requireTextures(for: document, metal: metal)
        return layer.id
    }

    func addMask(to layerID: LayerID, revealsAll: Bool) throws {
        guard let index = document.layers.firstIndex(where: { $0.id == layerID && $0.isPaintLayer && $0.mask == nil }) else {
            throw CanvasResourceError(message: "当前图层不能添加蒙版")
        }
        document.cropRetention = try RetainedCropLayerOperations.mask(document: document, layerID: layerID, fill: revealsAll ? 255 : 0)
        document.layers[index].mask = LayerMaskDescriptor(isEnabled: true)
        try surfaces.requireTextures(for: document, metal: metal)
        guard revealsAll || surfaces.fillMaskTexture(for: layerID, value: 0, metal: metal) else {
            throw CanvasResourceError(message: "无法初始化图层蒙版；画稿未改变")
        }
    }

    func writableTexture(for layerID: LayerID) throws -> MTLTexture {
        guard let id = surfaces.surfaceID(for: layerID), let texture = surfaces.texture(for: id) else {
            throw CanvasResourceError(message: "无法准备图层像素；画稿未改变")
        }
        return texture
    }
}

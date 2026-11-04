import Foundation
import Metal

enum LayerImportSurfaceBuilder {
    static func prepare(document: ArtDocument, snapshots: [LayerHistorySnapshot], metal: MetalDeviceContext,
                        serializer: LayerTextureSerializer, existingDocument: ArtDocument? = nil,
                        existingSurfaces: StageOneLayerSurfaceStore? = nil) throws -> StageOneLayerSurfaceStore {
        let surfaces: StageOneLayerSurfaceStore
        if let existingDocument, let existingSurfaces {
            surfaces = try LayerSurfaceTransfer.share(document: existingDocument, source: existingSurfaces)
        } else { surfaces = StageOneLayerSurfaceStore() }
        surfaces.prepareTextures(for: document, metal: metal)
        for snapshot in snapshots {
            let texture = snapshot.resourceKind == .mask ? surfaces.maskTexture(for: snapshot.layerID)
                : surfaces.surfaceID(for: snapshot.layerID).flatMap(surfaces.texture(for:))
            guard let texture else { throw CanvasResourceError(message: "无法为导入图层准备内存") }
            try serializer.restore(snapshot: snapshot.texture, into: texture, destinationX: snapshot.originX, destinationY: snapshot.originY)
        }
        for layer in document.paintLayers {
            guard surfaces.surfaceID(for: layer.id).flatMap(surfaces.readTexture(for:)) != nil,
                  layer.mask == nil || surfaces.readMaskTexture(for: layer.id) != nil else {
                throw CanvasResourceError(message: "导入图层资源不完整，主稿未改变")
            }
        }
        return surfaces
    }
}

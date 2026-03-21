import Foundation

struct LayerSurfaceID: Hashable, Sendable, Equatable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

struct LayerSurfaceRecord: Sendable, Equatable {
    let surfaceID: LayerSurfaceID
    let layerID: LayerID
    let layerName: String
    let isVisible: Bool
    let opacity: Float
    let descriptor: MetalSurfaceDescriptor
}

struct CanvasSceneSnapshot: Sendable, Equatable {
    var renderSnapshot: CanvasRenderSnapshot
    var layerSurfaces: [LayerSurfaceRecord]
    var activeLayerSurfaceID: LayerSurfaceID?
    var selectionShape: SelectionShape?
}

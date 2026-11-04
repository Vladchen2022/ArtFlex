import Metal

struct TextureFillSlice {
    var anchorPoint: CanvasPoint
    var previousEdgePoint: CanvasPoint
    var currentEdgePoint: CanvasPoint
}

struct TextureFillGestureState {
    var layerID: LayerID
    var surfaceID: LayerSurfaceID
    var anchorPoint: CanvasPoint
    var sessionSeed: UInt64
    var baseTexture: MTLTexture?
    var rawEdgePoints: [CanvasPoint]
    var tipSettings: TextureFillTipSettings
    var brush: BrushSettings
    var color: RGBAColor
    var lastEdgePoint: CanvasPoint?
    var renderedSliceCount = 0
}


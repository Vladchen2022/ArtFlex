import Foundation

enum EditableLayerCapture {
    static func texture(state: TextureFillGestureState, source: LayerTextureSnapshot, alphaLocked: Bool) throws -> EditableLayerContent {
        let canvas = CanvasSize(width: source.width, height: source.height)
        guard let shape = SelectionMaskRasterizer.textureFillSmoothFinalSelectionShape(from: state.rawEdgePoints,
            anchorPoint: state.anchorPoint, canvasSize: canvas) else { throw CanvasResourceError(message: "纹理区域无效") }
        let material: Data
        if state.tipSettings.sourceSemantic == .importedImage {
            guard let data = state.tipSettings.customTipMaskData else { throw CanvasResourceError(message: "纹理素材缺失") }
            material = data
        } else {
            guard let bytes = StageOneBrushPreviewRasterizer.materialFieldAlphaBytes(for: state.brush, resolution: 384) else {
                throw CanvasResourceError(message: "无法保留纹理素材")
            }
            material = Data(bytes)
        }
        return try .init(source: .init(snapshot: source), operation: .texture(.init(shape: shape, anchor: state.anchorPoint,
            material: .init(data: material), seed: state.sessionSeed,
            angle: SelectionMaskRasterizer.textureFillMaterialAngle(from: state.rawEdgePoints), color: state.color,
            scale: state.tipSettings.materialScale, coverage: state.tipSettings.coverage, variation: state.tipSettings.variation,
            jitter: state.tipSettings.paintJitterAmount, contrast: state.brush.effectivePaintContrastAmount,
            arrangement: state.tipSettings.arrangement, alphaLocked: alphaLocked)))
    }
}

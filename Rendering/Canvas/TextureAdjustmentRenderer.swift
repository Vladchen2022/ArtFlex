import Foundation
import Metal

/// Accessed only by PreviewWorker. Owns a renderer/cache separate from live editing.
/// Input is a frozen pre-fill texture; no live document or surface store is accessed.
final class TextureAdjustmentRenderer: @unchecked Sendable {
    private let metal: MetalDeviceContext
    private let serializer: LayerTextureSerializer
    private var renderer: SelectionFillRenderer?

    init(metal: MetalDeviceContext, serializer: LayerTextureSerializer) {
        self.metal = metal
        self.serializer = serializer
    }

    func render(state: TextureFillGestureState, mask: SelectionMaskRegion, angle: Float,
                alphaLocked: Bool, cancellation: WorkCancellation) throws -> MTLTexture {
        try cancellation.check()
        guard let source = state.baseTexture, mask.width > 0, mask.height > 0,
              mask.alphaBytes.contains(where: { $0 != 0 }) else {
            throw CanvasResourceError(message: "纹理区域无效")
        }
        let material: Data
        if state.tipSettings.sourceSemantic == .importedImage {
            guard let data = state.tipSettings.customTipMaskData else { throw CanvasResourceError(message: "纹理图像缺失") }
            material = data
        } else {
            guard let bytes = StageOneBrushPreviewRasterizer.materialFieldAlphaBytes(for: state.brush, resolution: 384) else {
                throw CanvasResourceError(message: "无法生成纹理")
            }
            material = Data(bytes)
        }
        try cancellation.check()
        let target = try serializer.cloneBatchForDeferredSnapshot(textures: [source])[0]
        try cancellation.check()
        if renderer == nil { renderer = SelectionFillRenderer(device: metal.device) }
        guard let buffer = metal.commandQueue.makeCommandBuffer() else { throw CanvasResourceError(message: "无法创建纹理预览命令") }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard renderer!.encode(into: pass, commandBuffer: buffer,
            canvasSize: .init(width: target.width, height: target.height),
            selectionMaskOriginX: mask.originX, selectionMaskOriginY: mask.originY,
            selectionMaskWidth: mask.width, selectionMaskHeight: mask.height,
            selectionMaskAlphaBytes: mask.alphaBytes, fillCenter: state.anchorPoint,
            color: state.color, paintJitterAmount: state.tipSettings.paintJitterAmount,
            paintContrastAmount: state.brush.effectivePaintContrastAmount, distortionAmount: 0,
            alphaLockTexture: alphaLocked ? source : nil, materialTextureData: material,
            materialScale: state.tipSettings.materialScale, materialCoverage: state.tipSettings.coverage,
            materialVariation: state.tipSettings.variation, materialSeed: state.sessionSeed,
            materialAngleRadians: angle, materialArrangement: state.tipSettings.arrangement) else {
            throw CanvasResourceError(message: "无法编码纹理预览")
        }
        try cancellation.check()
        buffer.commit()
        buffer.waitUntilCompleted()
        try cancellation.check()
        guard buffer.status == .completed else { throw CanvasResourceError(message: "纹理预览未完成") }
        return target
    }
}

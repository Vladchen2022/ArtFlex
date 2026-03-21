import Foundation
import Metal

final class EyedropperSampler {
    private let serializer: LayerTextureSerializer

    init(serializer: LayerTextureSerializer) {
        self.serializer = serializer
    }

    func sampleVisibleColor(
        at point: CanvasPoint,
        document: ArtDocument,
        layerSurfaceStore: StageOneLayerSurfaceStore
    ) throws -> RGBAColor {
        let pixelX = max(0, min(document.canvasSize.width - 1, Int(point.x.rounded(.down))))
       let pixelY = max(0, min(document.canvasSize.height - 1, Int(point.y.rounded(.down))))

        var result = LinearPremultipliedColor.clear

        for layer in document.layers where layer.isVisible {
            guard
                let surfaceID = layerSurfaceStore.surfaceID(for: layer.id),
                let texture = layerSurfaceStore.texture(for: surfaceID)
            else {
                continue
            }

            let sampled = try serializer.samplePixel(texture: texture, x: pixelX, y: pixelY)
            let layerColor = LinearPremultipliedColor(srgbPremultiplied: sampled)
                .applyingOpacity(layer.opacity)

            result = layerColor.composited(over: result)
        }

        let compositedOverWhite = result.composited(over: .white)
        return compositedOverWhite.srgbUnpremultipliedOverOpaqueBackground
    }
}

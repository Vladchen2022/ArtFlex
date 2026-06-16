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
        layerSurfaceStore: StageOneLayerSurfaceStore,
        displayTextureForLayer: ((LayerID) -> MTLTexture?)? = nil
    ) throws -> RGBAColor {
        let pixelX = max(0, min(document.canvasSize.width - 1, Int(point.x.rounded(.down))))
        let pixelY = max(0, min(document.canvasSize.height - 1, Int(point.y.rounded(.down))))

        var result = LinearPremultipliedColor.clear

        for layer in document.layers where layer.isVisible {
            guard let texture = samplingTexture(
                for: layer.id,
                pixelX: pixelX,
                pixelY: pixelY,
                layerSurfaceStore: layerSurfaceStore,
                displayTextureForLayer: displayTextureForLayer
            ) else {
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

    private func samplingTexture(
        for layerID: LayerID,
        pixelX: Int,
        pixelY: Int,
        layerSurfaceStore: StageOneLayerSurfaceStore,
        displayTextureForLayer: ((LayerID) -> MTLTexture?)?
    ) -> MTLTexture? {
        if let displayTexture = displayTextureForLayer?(layerID),
           pixelX < displayTexture.width,
           pixelY < displayTexture.height {
            return displayTexture
        }

        guard
            let surfaceID = layerSurfaceStore.surfaceID(for: layerID),
            let texture = layerSurfaceStore.texture(for: surfaceID)
        else {
            return nil
        }
        return texture
    }
}

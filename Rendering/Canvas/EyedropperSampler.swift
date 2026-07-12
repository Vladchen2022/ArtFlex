import Foundation
import Metal

final class EyedropperSampler {
    private struct SamplingLayer {
        var layer: LayerRecord
        var texture: MTLTexture
    }

    private let serializer: LayerTextureSerializer

    init(serializer: LayerTextureSerializer) {
        self.serializer = serializer
    }

    func sampleVisibleColor(
        at point: CanvasPoint,
        document: ArtDocument,
        layerSurfaceStore: StageOneLayerSurfaceStore,
        settings: EyedropperSettings = .stageOneDefault,
        contentTextureForLayer: ((LayerID) -> MTLTexture?)? = nil,
        displayTextureForLayer: ((LayerID) -> MTLTexture?)? = nil
    ) throws -> RGBAColor {
        let centerX = max(0, min(document.canvasSize.width - 1, Int(point.x.rounded(.down))))
        let centerY = max(0, min(document.canvasSize.height - 1, Int(point.y.rounded(.down))))
        let radius = settings.sampleSize.radius
        let originX = max(0, centerX - radius)
        let originY = max(0, centerY - radius)
        let maximumX = min(document.canvasSize.width - 1, centerX + radius)
        let maximumY = min(document.canvasSize.height - 1, centerY + radius)
        let width = (maximumX - originX) + 1
        let height = (maximumY - originY) + 1

        let samplingLayers = resolveSamplingLayers(
            document: document,
            originX: originX,
            originY: originY,
            width: width,
            height: height,
            source: settings.source,
            layerSurfaceStore: layerSurfaceStore,
            contentTextureForLayer: contentTextureForLayer,
            displayTextureForLayer: displayTextureForLayer
        )
        let snapshots = try serializer.snapshotRegions(
            samplingLayers.map { samplingLayer in
                LayerTextureRegionSnapshotRequest(
                    texture: samplingLayer.texture,
                    originX: originX,
                    originY: originY,
                    width: width,
                    height: height
                )
            }
        )

        var compositedPixels = [LinearPremultipliedColor](
            repeating: .clear,
            count: width * height
        )
        for (samplingLayer, snapshot) in zip(samplingLayers, snapshots) {
            composite(
                snapshot: snapshot,
                layerOpacity: samplingLayer.layer.opacity,
                into: &compositedPixels
            )
        }

        let sampled = aggregate(
            compositedPixels,
            sampleSize: settings.sampleSize,
            statistic: settings.statistic
        )
        return outputColor(
            from: sampled,
            preservesTransparency: settings.preservesTransparency
        )
    }

    private func resolveSamplingLayers(
        document: ArtDocument,
        originX: Int,
        originY: Int,
        width: Int,
        height: Int,
        source: EyedropperSampleSource,
        layerSurfaceStore: StageOneLayerSurfaceStore,
        contentTextureForLayer: ((LayerID) -> MTLTexture?)?,
        displayTextureForLayer: ((LayerID) -> MTLTexture?)?
    ) -> [SamplingLayer] {
        let layers: [LayerRecord]
        switch source {
        case .currentLayer:
            layers = document.layers.filter { $0.id == document.activeLayerID }
        case .allVisibleLayers, .displayedColor:
            layers = document.layers.filter(\.isVisible)
        }

        return layers.compactMap { layer in
            guard let texture = samplingTexture(
                for: layer.id,
                source: source,
                originX: originX,
                originY: originY,
                width: width,
                height: height,
                layerSurfaceStore: layerSurfaceStore,
                contentTextureForLayer: contentTextureForLayer,
                displayTextureForLayer: displayTextureForLayer
            ) else {
                return nil
            }
            return SamplingLayer(layer: layer, texture: texture)
        }
    }

    private func samplingTexture(
        for layerID: LayerID,
        source: EyedropperSampleSource,
        originX: Int,
        originY: Int,
        width: Int,
        height: Int,
        layerSurfaceStore: StageOneLayerSurfaceStore,
        contentTextureForLayer: ((LayerID) -> MTLTexture?)?,
        displayTextureForLayer: ((LayerID) -> MTLTexture?)?
    ) -> MTLTexture? {
        if source == .displayedColor,
           let displayTexture = displayTextureForLayer?(layerID),
           originX + width <= displayTexture.width,
           originY + height <= displayTexture.height {
            return displayTexture
        }

        if let contentTexture = contentTextureForLayer?(layerID),
           originX + width <= contentTexture.width,
           originY + height <= contentTexture.height {
            return contentTexture
        }

        guard
            let surfaceID = layerSurfaceStore.surfaceID(for: layerID),
            let texture = layerSurfaceStore.texture(for: surfaceID),
            originX + width <= texture.width,
            originY + height <= texture.height
        else {
            return nil
        }
        return texture
    }

    private func composite(
        snapshot: LayerTextureSnapshot,
        layerOpacity: Float,
        into output: inout [LinearPremultipliedColor]
    ) {
        let bytes = [UInt8](snapshot.pixelData)
        for y in 0..<snapshot.height {
            for x in 0..<snapshot.width {
                let byteOffset = (y * snapshot.bytesPerRow) + (x * 4)
                guard byteOffset + 3 < bytes.count else { continue }
                let layerColor = LinearPremultipliedColor(
                    bgraBlue: bytes[byteOffset],
                    green: bytes[byteOffset + 1],
                    red: bytes[byteOffset + 2],
                    alpha: bytes[byteOffset + 3]
                ).applyingOpacity(layerOpacity)
                let outputIndex = (y * snapshot.width) + x
                guard output.indices.contains(outputIndex) else { continue }
                output[outputIndex] = layerColor.composited(over: output[outputIndex])
            }
        }
    }

    private func aggregate(
        _ pixels: [LinearPremultipliedColor],
        sampleSize: EyedropperSampleSize,
        statistic: EyedropperSampleStatistic
    ) -> LinearPremultipliedColor {
        guard let first = pixels.first else { return .clear }
        guard sampleSize != .point, pixels.count > 1 else { return first }

        switch statistic {
        case .average:
            let total = pixels.reduce(into: LinearPremultipliedColor.clear) { partial, color in
                partial.red += color.red
                partial.green += color.green
                partial.blue += color.blue
                partial.alpha += color.alpha
            }
            let divisor = Float(pixels.count)
            return LinearPremultipliedColor(
                red: total.red / divisor,
                green: total.green / divisor,
                blue: total.blue / divisor,
                alpha: total.alpha / divisor
            )
        case .median:
            let alpha = median(pixels.map(\.alpha))
            return LinearPremultipliedColor(
                red: min(median(pixels.map(\.red)), alpha),
                green: min(median(pixels.map(\.green)), alpha),
                blue: min(median(pixels.map(\.blue)), alpha),
                alpha: alpha
            )
        }
    }

    private func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) * 0.5
        }
        return sorted[middle]
    }

    private func outputColor(
        from color: LinearPremultipliedColor,
        preservesTransparency: Bool
    ) -> RGBAColor {
        if !preservesTransparency {
            let opaque = color.composited(over: .white)
            return RGBAColor(
                red: LinearPremultipliedColor.linearChannelToSRGB(opaque.red),
                green: LinearPremultipliedColor.linearChannelToSRGB(opaque.green),
                blue: LinearPremultipliedColor.linearChannelToSRGB(opaque.blue),
                alpha: 1
            )
        }

        let alpha = min(max(color.alpha, 0), 1)
        guard alpha > 0.000_001 else {
            return RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)
        }
        let inverseAlpha = 1 / alpha
        return RGBAColor(
            red: LinearPremultipliedColor.linearChannelToSRGB(color.red * inverseAlpha),
            green: LinearPremultipliedColor.linearChannelToSRGB(color.green * inverseAlpha),
            blue: LinearPremultipliedColor.linearChannelToSRGB(color.blue * inverseAlpha),
            alpha: alpha
        )
    }
}

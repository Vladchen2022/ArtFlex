import Foundation
import Metal
import simd

final class EyedropperSampler {
    private struct SamplingLayer {
        var layer: LayerRecord
        var texture: MTLTexture
        var clipMaskTexture: MTLTexture?
        var effectiveOpacity: Float
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
        let clipSnapshots = try samplingLayers.map { samplingLayer -> LayerTextureSnapshot? in
            guard let clipMaskTexture = samplingLayer.clipMaskTexture else { return nil }
            return try serializer.snapshot(
                texture: clipMaskTexture,
                originX: originX,
                originY: originY,
                width: width,
                height: height
            )
        }

        var compositedPixels = [LinearPremultipliedColor](
            repeating: .clear,
            count: width * height
        )
        for (index, pair) in zip(samplingLayers, snapshots).enumerated() {
            let (samplingLayer, snapshot) = pair
            composite(
                snapshot: snapshot,
                layerOpacity: samplingLayer.effectiveOpacity,
                blendMode: samplingLayer.layer.blendMode,
                clipMaskSnapshot: clipSnapshots[index],
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
            layers = document.layers.filter { $0.id == document.activeLayerID && $0.isPaintLayer }
        case .allVisibleLayers, .displayedColor:
            layers = document.layers.filter {
                $0.isPaintLayer && document.isLayerEffectivelyVisible($0.id)
            }
        }

        return layers.compactMap { layer -> SamplingLayer? in
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
            let clipMaskTexture: MTLTexture? = layer.clipTargetLayerID.flatMap { clipLayerID -> MTLTexture? in
                guard document.isLayerEffectivelyVisible(clipLayerID) else { return nil }
                return samplingTexture(
                    for: clipLayerID,
                    source: source,
                    originX: originX,
                    originY: originY,
                    width: width,
                    height: height,
                    layerSurfaceStore: layerSurfaceStore,
                    contentTextureForLayer: contentTextureForLayer,
                    displayTextureForLayer: displayTextureForLayer
                )
            }
            if layer.clipTargetLayerID != nil, clipMaskTexture == nil { return nil }
            return SamplingLayer(
                layer: layer,
                texture: texture,
                clipMaskTexture: clipMaskTexture,
                effectiveOpacity: document.effectiveLayerOpacity(layer.id)
            )
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
        blendMode: LayerBlendMode,
        clipMaskSnapshot: LayerTextureSnapshot?,
        into output: inout [LinearPremultipliedColor]
    ) {
        let bytes = [UInt8](snapshot.pixelData)
        for y in 0..<snapshot.height {
            for x in 0..<snapshot.width {
                let byteOffset = (y * snapshot.bytesPerRow) + (x * 4)
                guard byteOffset + 3 < bytes.count else { continue }
                let clipAlpha: Float
                if let clipMaskSnapshot {
                    let clipOffset = (y * clipMaskSnapshot.bytesPerRow) + (x * 4)
                    clipAlpha = clipOffset + 3 < clipMaskSnapshot.pixelData.count
                        ? Float(clipMaskSnapshot.pixelData[clipOffset + 3]) / 255
                        : 0
                } else {
                    clipAlpha = 1
                }
                let layerColor = LinearPremultipliedColor(
                    bgraBlue: bytes[byteOffset],
                    green: bytes[byteOffset + 1],
                    red: bytes[byteOffset + 2],
                    alpha: bytes[byteOffset + 3]
                ).applyingOpacity(layerOpacity * clipAlpha)
                let outputIndex = (y * snapshot.width) + x
                guard output.indices.contains(outputIndex) else { continue }
                output[outputIndex] = composite(
                    source: layerColor,
                    backdrop: output[outputIndex],
                    blendMode: blendMode
                )
            }
        }
    }

    private func composite(
        source: LinearPremultipliedColor,
        backdrop: LinearPremultipliedColor,
        blendMode: LayerBlendMode
    ) -> LinearPremultipliedColor {
        guard blendMode != .normal, source.alpha > 0, backdrop.alpha > 0 else {
            return source.composited(over: backdrop)
        }
        let sourceRGB = SIMD3(source.red, source.green, source.blue) / source.alpha
        let backdropRGB = SIMD3(backdrop.red, backdrop.green, backdrop.blue) / backdrop.alpha
        let blended: SIMD3<Float>
        switch blendMode {
        case .normal:
            blended = sourceRGB
        case .multiply:
            blended = backdropRGB * sourceRGB
        case .screen:
            blended = backdropRGB + sourceRGB - backdropRGB * sourceRGB
        case .add:
            blended = simd_min(SIMD3(repeating: 1), backdropRGB + sourceRGB)
        case .overlay:
            blended = SIMD3(
                overlay(backdropRGB.x, sourceRGB.x),
                overlay(backdropRGB.y, sourceRGB.y),
                overlay(backdropRGB.z, sourceRGB.z)
            )
        case .softLight:
            blended = SIMD3(
                softLight(backdropRGB.x, sourceRGB.x),
                softLight(backdropRGB.y, sourceRGB.y),
                softLight(backdropRGB.z, sourceRGB.z)
            )
        case .darken:
            blended = simd_min(backdropRGB, sourceRGB)
        case .lighten:
            blended = simd_max(backdropRGB, sourceRGB)
        }
        let outAlpha = source.alpha + backdrop.alpha * (1 - source.alpha)
        let outRGB =
            (1 - source.alpha) * SIMD3(backdrop.red, backdrop.green, backdrop.blue) +
            (1 - backdrop.alpha) * SIMD3(source.red, source.green, source.blue) +
            source.alpha * backdrop.alpha * blended
        return LinearPremultipliedColor(red: outRGB.x, green: outRGB.y, blue: outRGB.z, alpha: outAlpha)
    }

    private func overlay(_ backdrop: Float, _ source: Float) -> Float {
        backdrop <= 0.5
            ? 2 * backdrop * source
            : 1 - 2 * (1 - backdrop) * (1 - source)
    }

    private func softLight(_ backdrop: Float, _ source: Float) -> Float {
        if source <= 0.5 {
            return backdrop - (1 - 2 * source) * backdrop * (1 - backdrop)
        }
        let d = backdrop <= 0.25
            ? ((16 * backdrop - 12) * backdrop + 4) * backdrop
            : sqrt(backdrop)
        return backdrop + (2 * source - 1) * (d - backdrop)
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

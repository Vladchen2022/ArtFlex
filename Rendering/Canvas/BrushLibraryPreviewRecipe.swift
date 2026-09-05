import Foundation

/// A reproducible demonstration gesture, not a second brush renderer.
/// Only physical size is fitted to the thumbnail; all paint semantics survive.
struct BrushLibraryPreviewRecipe {
    static let seed: UInt32 = 0x4252_5553
    let brush: BrushSettings
    let points: [StrokePoint]

    init(brush source: BrushSettings, resolution: Int) {
        let primarySize = source.compoundBrush.enabled
            ? source.resolvedCompoundPrimaryTip.resolvedBaseSize(for: source.size) : source.size
        let secondaryIsVisible = source.compoundBrush.enabled &&
            (source.engineV2 == nil || source.engineV2?.combination == .pressureBlend)
        let secondarySize = secondaryIsVisible
            ? source.compoundBrush.secondary.resolvedBaseSize(for: source.size) : 0
        let largestSize = max(primarySize, secondarySize, 1)
        let scale = Float(resolution) * 0.24 / largestSize
        var fitted = source
        fitted.size = min(max(source.size * scale, 1), 512)
        if fitted.compoundBrush.primary?.sizeMode == .absolutePixels {
            fitted.compoundBrush.primary?.size = min(max(source.compoundBrush.primary!.size * scale, 1), 512)
        }
        if fitted.compoundBrush.secondary.sizeMode == .absolutePixels {
            fitted.compoundBrush.secondary.size = min(max(source.compoundBrush.secondary.size * scale, 1), 512)
        }
        brush = fitted
        points = (0...96).map { index in
            let t = Double(index) / 96
            // A short heavy head, a long transition showing mid-pressure grain,
            // and a light tail. No forced opacity or artificial faded stamps.
            let u = min(max((t - 0.12) / 0.80, 0), 1)
            let eased = u * u * (3 - 2 * u)
            return StrokePoint(
                x: Double(resolution) * (0.18 + 0.64 * t),
                y: Double(resolution) * (0.76 - 0.52 * t + 0.075 * sin(2 * .pi * t)),
                pressure: Float(0.95 - 0.77 * eased)
            )
        }
    }
}

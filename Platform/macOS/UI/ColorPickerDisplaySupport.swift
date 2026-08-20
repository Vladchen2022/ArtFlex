import CoreGraphics
import Foundation

enum ColorHueWheelGeometry {
    static func hue(at location: CGPoint, center: CGPoint) -> Float {
        let radians = atan2(location.y - center.y, location.x - center.x)
        var degrees = Float(radians * 180 / .pi)
        if degrees < 0 {
            degrees += 360
        }
        return degrees
    }

    static func indicatorCenter(hue: Float, center: CGPoint, radius: CGFloat) -> CGPoint {
        let wrappedHue = hue.truncatingRemainder(dividingBy: 360)
        let normalizedHue = wrappedHue < 0 ? wrappedHue + 360 : wrappedHue
        let radians = CGFloat(normalizedHue) * .pi / 180
        return CGPoint(
            x: center.x + cos(radians) * radius,
            y: center.y + sin(radians) * radius
        )
    }

    static func innerSquareSide(diameter: CGFloat, ringWidth: CGFloat, gap: CGFloat) -> CGFloat {
        let availableInnerDiameter = max(0, diameter - (ringWidth + gap) * 2)
        return availableInnerDiameter / sqrt(2)
    }

    static func containsRingPoint(
        _ location: CGPoint,
        center: CGPoint,
        diameter: CGFloat,
        ringWidth: CGFloat,
        tolerance: CGFloat = 4
    ) -> Bool {
        let distance = hypot(location.x - center.x, location.y - center.y)
        let outerRadius = diameter / 2 + tolerance
        let innerRadius = max(0, diameter / 2 - ringWidth - tolerance)
        return distance >= innerRadius && distance <= outerRadius
    }
}

@MainActor
final class ColorPickerDisplayImageCache {
    static let shared = ColorPickerDisplayImageCache()

    struct SVKey: Equatable {
        let size: Int
        let hue: Int
        let lightness: Int
        let saturation: Int
        let lightingHue: Int
        let lightingStrength: Int
    }

    struct HueKey: Equatable {
        let height: Int
        let width: Int
    }

    struct HorizontalHueKey: Equatable {
        let width: Int
        let height: Int
    }

    private let svCache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 8
        cache.totalCostLimit = 8 * 1024 * 1024
        cache.name = "ArtFlex.ColorPickerSVImages"
        return cache
    }()
    private var hueCache: (key: HueKey, image: CGImage)?
    private var horizontalHueCache: (key: HorizontalHueKey, image: CGImage)?

    func cachedSVImage(size: Int, panel: ColorPanelState) -> CGImage? {
        svCache.object(forKey: svCacheKey(size: size, panel: panel))
    }

    func storeSVImage(_ image: CGImage, size: Int, panel: ColorPanelState) {
        svCache.setObject(
            image,
            forKey: svCacheKey(size: size, panel: panel),
            cost: max(size, 0) * max(size, 0) * 4
        )
    }

    func svImage(size: Int, panel: ColorPanelState, builder: () -> CGImage?) -> CGImage? {
        if let cached = cachedSVImage(size: size, panel: panel) {
            return cached
        }
        guard let image = builder() else { return nil }
        storeSVImage(image, size: size, panel: panel)
        return image
    }

    private func svCacheKey(size: Int, panel: ColorPanelState) -> NSString {
        let key = SVKey(
            size: size,
            hue: Int(panel.pickerHue.rounded()),
            lightness: Int(panel.pickerLightness.rounded()),
            saturation: Int(panel.pickerSaturation.rounded()),
            lightingHue: Int(panel.lightingHue.rounded()),
            lightingStrength: Int(panel.lightingStrength.rounded())
        )
        return "\(key.size):\(key.hue):\(key.lightness):\(key.saturation):\(key.lightingHue):\(key.lightingStrength)"
            as NSString
    }

#if DEBUG
    func removeAllSVImagesForTesting() {
        svCache.removeAllObjects()
    }
#endif

    func hueImage(height: Int, width: Int, builder: () -> CGImage?) -> CGImage? {
        let key = HueKey(height: height, width: width)
        if let hueCache, hueCache.key == key {
            return hueCache.image
        }
        guard let image = builder() else { return nil }
        hueCache = (key, image)
        return image
    }

    func horizontalHueImage(width: Int, height: Int, builder: () -> CGImage?) -> CGImage? {
        let key = HorizontalHueKey(width: width, height: height)
        if let horizontalHueCache, horizontalHueCache.key == key {
            return horizontalHueCache.image
        }
        guard let image = builder() else { return nil }
        horizontalHueCache = (key, image)
        return image
    }
}

@MainActor
func sharedColorPickerSVImage(size: Int, panel: ColorPanelState) -> CGImage? {
    ColorPickerDisplayImageCache.shared.svImage(size: size, panel: panel) {
        makeColorPickerSVImage(size: size, panel: panel)
    }
}

@MainActor
func cachedSharedColorPickerSVImage(size: Int, panel: ColorPanelState) -> CGImage? {
    ColorPickerDisplayImageCache.shared.cachedSVImage(size: size, panel: panel)
}

@MainActor
func prepareSharedColorPickerSVImage(size: Int, panel: ColorPanelState) async -> CGImage? {
    if let cached = cachedSharedColorPickerSVImage(size: size, panel: panel) {
        return cached
    }

    let renderTask = Task.detached(priority: .userInitiated) {
        makeColorPickerSVImage(size: size, panel: panel) {
            Task.isCancelled
        }
    }
    let image = await withTaskCancellationHandler {
        await renderTask.value
    } onCancel: {
        renderTask.cancel()
    }
    guard !Task.isCancelled, let image else { return nil }
    ColorPickerDisplayImageCache.shared.storeSVImage(image, size: size, panel: panel)
    return image
}

func makeColorPickerSVImage(
    size: Int,
    panel: ColorPanelState,
    shouldCancel: @Sendable () -> Bool = { false }
) -> CGImage? {
    guard size > 0 else { return nil }

    let bytesPerPixel = 4
    let bytesPerRow = size * bytesPerPixel
    let denominator = Float(max(size - 1, 1))
    let currentLightness = ColorBlocksEngine.clamp(panel.pickerLightness, 0, 100)
    let maximumValue: Float = currentLightness <= 50 ? currentLightness / 50 : 1
    let minimumValue: Float = currentLightness > 50 ? (currentLightness - 50) / 50 : 0
    let maximumSaturation = ColorBlocksEngine.clamp(panel.pickerSaturation, 0, 100) / 100
    let appliesLighting = panel.lightingStrength > 0.0001
    var rgba = [UInt8](repeating: 0, count: size * size * bytesPerPixel)

    for y in 0..<size {
        guard !shouldCancel() else { return nil }
        let pointY = Float(y) / denominator
        let value = (1 - pointY) * (maximumValue - minimumValue) + minimumValue
        for x in 0..<size {
            let saturation = (Float(x) / denominator) * maximumSaturation
            var color = ColorBlocksEngine.hsvToRgb(
                HSVColor(h: panel.pickerHue, s: saturation, v: value)
            )
            if appliesLighting {
                color = ColorBlocksEngine.applyLighting(to: color, state: panel)
            }
            let offset = ((y * size) + x) * bytesPerPixel
            rgba[offset] = UInt8(clamping: Int((color.red * 255).rounded()))
            rgba[offset + 1] = UInt8(clamping: Int((color.green * 255).rounded()))
            rgba[offset + 2] = UInt8(clamping: Int((color.blue * 255).rounded()))
            rgba[offset + 3] = 255
        }
    }

    return makeSharedColorPickerImage(
        rgba: rgba,
        width: size,
        height: size,
        bytesPerRow: bytesPerRow
    )
}

@MainActor
func sharedColorPickerVerticalHueImage(height: Int, width: Int) -> CGImage? {
    ColorPickerDisplayImageCache.shared.hueImage(height: height, width: width) {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var rgba = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        for y in 0..<height {
            let hue = (Float(y) / Float(max(height - 1, 1))) * 360
            let color = ColorBlocksEngine.hsvToRgb(HSVColor(h: hue, s: 1, v: 1))
            for x in 0..<width {
                let offset = ((y * width) + x) * bytesPerPixel
                rgba[offset] = UInt8(clamping: Int((color.red * 255).rounded()))
                rgba[offset + 1] = UInt8(clamping: Int((color.green * 255).rounded()))
                rgba[offset + 2] = UInt8(clamping: Int((color.blue * 255).rounded()))
                rgba[offset + 3] = 255
            }
        }

        return makeSharedColorPickerImage(
            rgba: rgba,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        )
    }
}

@MainActor
func sharedColorPickerHorizontalHueImage(width: Int, height: Int) -> CGImage? {
    ColorPickerDisplayImageCache.shared.horizontalHueImage(width: width, height: height) {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var rgba = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        for x in 0..<width {
            let hue = (Float(x) / Float(max(width - 1, 1))) * 360
            let color = ColorBlocksEngine.hsvToRgb(HSVColor(h: hue, s: 1, v: 1))
            for y in 0..<height {
                let offset = ((y * width) + x) * bytesPerPixel
                rgba[offset] = UInt8(clamping: Int((color.red * 255).rounded()))
                rgba[offset + 1] = UInt8(clamping: Int((color.green * 255).rounded()))
                rgba[offset + 2] = UInt8(clamping: Int((color.blue * 255).rounded()))
                rgba[offset + 3] = 255
            }
        }

        return makeSharedColorPickerImage(
            rgba: rgba,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        )
    }
}

private func makeSharedColorPickerImage(
    rgba: [UInt8],
    width: Int,
    height: Int,
    bytesPerRow: Int
) -> CGImage? {
    guard
        let provider = CGDataProvider(data: Data(rgba) as CFData),
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    else {
        return nil
    }

    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )
}

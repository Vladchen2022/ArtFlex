import CoreGraphics
import Foundation

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

    private var svCache: (key: SVKey, image: CGImage)?
    private var hueCache: (key: HueKey, image: CGImage)?
    private var horizontalHueCache: (key: HorizontalHueKey, image: CGImage)?

    func svImage(size: Int, panel: ColorPanelState, builder: () -> CGImage?) -> CGImage? {
        let key = SVKey(
            size: size,
            hue: Int(panel.pickerHue.rounded()),
            lightness: Int(panel.pickerLightness.rounded()),
            saturation: Int(panel.pickerSaturation.rounded()),
            lightingHue: Int(panel.lightingHue.rounded()),
            lightingStrength: Int(panel.lightingStrength.rounded())
        )
        if let svCache, svCache.key == key {
            return svCache.image
        }
        guard let image = builder() else { return nil }
        svCache = (key, image)
        return image
    }

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
        let bytesPerPixel = 4
        let bytesPerRow = size * bytesPerPixel
        var rgba = [UInt8](repeating: 0, count: size * size * bytesPerPixel)

        for y in 0..<size {
            for x in 0..<size {
                let pointX = Float(x) / Float(max(size - 1, 1))
                let pointY = Float(y) / Float(max(size - 1, 1))
                var state = panel
                state.pickerX = pointX
                state.pickerY = pointY
                let color = ColorBlocksEngine.pickerColor(from: state)
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

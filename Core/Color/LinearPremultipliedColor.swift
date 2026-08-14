import Foundation

struct LinearPremultipliedColor: Sendable, Equatable {
    var red: Float
    var green: Float
    var blue: Float
    var alpha: Float

    static let clear = LinearPremultipliedColor(red: 0, green: 0, blue: 0, alpha: 0)
    static let white = LinearPremultipliedColor(red: 1, green: 1, blue: 1, alpha: 1)
    static let black = LinearPremultipliedColor(red: 0, green: 0, blue: 0, alpha: 1)
    private static let srgbByteToLinearTable: [Float] = (0...255).map {
        srgbChannelToLinear(Float($0) / 255)
    }

    init(red: Float, green: Float, blue: Float, alpha: Float) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(srgbPremultiplied color: RGBAColor) {
        self.init(
            red: Self.srgbChannelToLinear(color.red),
            green: Self.srgbChannelToLinear(color.green),
            blue: Self.srgbChannelToLinear(color.blue),
            alpha: color.alpha
        )
    }

    init(bgraBlue: UInt8, green: UInt8, red: UInt8, alpha: UInt8) {
        self.init(
            red: Self.srgbByteToLinearTable[Int(red)],
            green: Self.srgbByteToLinearTable[Int(green)],
            blue: Self.srgbByteToLinearTable[Int(bgraBlue)],
            alpha: Float(alpha) / 255
        )
    }

    static func linearChannel(forSRGBByte value: UInt8) -> Float {
        srgbByteToLinearTable[Int(value)]
    }

    func applyingOpacity(_ opacity: Float) -> LinearPremultipliedColor {
        let clamped = min(max(opacity, 0), 1)
        return LinearPremultipliedColor(
            red: red * clamped,
            green: green * clamped,
            blue: blue * clamped,
            alpha: alpha * clamped
        )
    }

    func composited(over destination: LinearPremultipliedColor) -> LinearPremultipliedColor {
        let inverseAlpha = 1 - alpha
        return LinearPremultipliedColor(
            red: red + (destination.red * inverseAlpha),
            green: green + (destination.green * inverseAlpha),
            blue: blue + (destination.blue * inverseAlpha),
            alpha: alpha + (destination.alpha * inverseAlpha)
        )
    }

    var srgbUnpremultipliedOverOpaqueBackground: RGBAColor {
        RGBAColor(
            red: Self.linearChannelToSRGB(red),
            green: Self.linearChannelToSRGB(green),
            blue: Self.linearChannelToSRGB(blue),
            alpha: 1
        )
    }

    var bgra8PremultipliedBytes: (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8) {
        (
            blue: UInt8(clamping: Int((Self.linearChannelToSRGB(blue) * 255).rounded())),
            green: UInt8(clamping: Int((Self.linearChannelToSRGB(green) * 255).rounded())),
            red: UInt8(clamping: Int((Self.linearChannelToSRGB(red) * 255).rounded())),
            alpha: UInt8(clamping: Int((min(max(alpha, 0), 1) * 255).rounded()))
        )
    }

    static func srgbChannelToLinear(_ value: Float) -> Float {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    static func linearChannelToSRGB(_ value: Float) -> Float {
        let clamped = min(max(value, 0), 1)
        return clamped <= 0.0031308 ? clamped * 12.92 : (1.055 * pow(clamped, 1 / 2.4)) - 0.055
    }
}

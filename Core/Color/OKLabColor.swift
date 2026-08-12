import Foundation
import simd

struct OKLabColor: Sendable, Equatable {
    var lightness: Float
    var a: Float
    var b: Float

    init(srgb color: RGBAColor) {
        let linear = SIMD3<Float>(
            LinearPremultipliedColor.srgbChannelToLinear(color.red),
            LinearPremultipliedColor.srgbChannelToLinear(color.green),
            LinearPremultipliedColor.srgbChannelToLinear(color.blue)
        )
        let lms = SIMD3<Float>(
            simd_dot(linear, SIMD3(0.4122214708, 0.5363325363, 0.0514459929)),
            simd_dot(linear, SIMD3(0.2119034982, 0.6806995451, 0.1073969566)),
            simd_dot(linear, SIMD3(0.0883024619, 0.2817188376, 0.6299787005))
        )
        let root = SIMD3<Float>(
            cbrt(max(lms.x, 0)),
            cbrt(max(lms.y, 0)),
            cbrt(max(lms.z, 0))
        )
        lightness = simd_dot(root, SIMD3(0.2104542553, 0.7936177850, -0.0040720468))
        a = simd_dot(root, SIMD3(1.9779984951, -2.4285922050, 0.4505937099))
        b = simd_dot(root, SIMD3(0.0259040371, 0.7827717662, -0.8086757660))
    }

    func srgb(alpha: Float) -> RGBAColor {
        var chromaScale: Float = 1
        var linear = linearSRGB(chromaScale: chromaScale)
        if !Self.isInGamut(linear) {
            var lower: Float = 0
            var upper: Float = 1
            for _ in 0..<12 {
                let candidate = (lower + upper) * 0.5
                let candidateLinear = linearSRGB(chromaScale: candidate)
                if Self.isInGamut(candidateLinear) {
                    lower = candidate
                    linear = candidateLinear
                } else {
                    upper = candidate
                }
            }
            chromaScale = lower
            linear = linearSRGB(chromaScale: chromaScale)
        }
        return RGBAColor(
            red: LinearPremultipliedColor.linearChannelToSRGB(linear.x),
            green: LinearPremultipliedColor.linearChannelToSRGB(linear.y),
            blue: LinearPremultipliedColor.linearChannelToSRGB(linear.z),
            alpha: alpha
        )
    }

    private func linearSRGB(chromaScale: Float) -> SIMD3<Float> {
        let scaledA = a * chromaScale
        let scaledB = b * chromaScale
        let root = SIMD3<Float>(
            lightness + (0.3963377774 * scaledA) + (0.2158037573 * scaledB),
            lightness - (0.1055613458 * scaledA) - (0.0638541728 * scaledB),
            lightness - (0.0894841775 * scaledA) - (1.2914855480 * scaledB)
        )
        let lms = root * root * root
        return SIMD3<Float>(
            simd_dot(lms, SIMD3(4.0767416621, -3.3077115913, 0.2309699292)),
            simd_dot(lms, SIMD3(-1.2684380046, 2.6097574011, -0.3413193965)),
            simd_dot(lms, SIMD3(-0.0041960863, -0.7034186147, 1.7076147010))
        )
    }

    private static func isInGamut(_ color: SIMD3<Float>) -> Bool {
        let tolerance: Float = 0.00001
        return color.x >= -tolerance && color.x <= 1 + tolerance
            && color.y >= -tolerance && color.y <= 1 + tolerance
            && color.z >= -tolerance && color.z <= 1 + tolerance
    }
}

enum OilPaintLightnessMatcher {
    static func match(
        _ color: RGBAColor,
        to reference: RGBAColor,
        amount: Float
    ) -> RGBAColor {
        let clampedAmount = min(max(amount, 0), 1)
        guard clampedAmount > 0.0001 else { return color }
        var sourceLab = OKLabColor(srgb: color)
        let referenceLab = OKLabColor(srgb: reference)
        sourceLab.lightness += (referenceLab.lightness - sourceLab.lightness) * clampedAmount
        return sourceLab.srgb(alpha: color.alpha)
    }
}

import Foundation

enum ArtPixelFormat: String, Codable, Sendable {
    case rgba8
    case rgba16Float

    var encoding: CanvasPixelEncoding {
        self == .rgba16Float ? .premultipliedRGBA16FloatLinear : .premultipliedBGRA8SRGB
    }
}

enum ArtAlphaMode: String, Codable, Sendable {
    case premultiplied
}

enum ArtColorSpace: String, Codable, Sendable {
    case sRGB
    case extendedSRGB
}

struct ArtColorStandard: Codable, Sendable, Equatable {
    let pixelFormat: ArtPixelFormat
    let alphaMode: ArtAlphaMode
    let colorSpace: ArtColorSpace

    init(pixelFormat: ArtPixelFormat, alphaMode: ArtAlphaMode, colorSpace: ArtColorSpace) {
        self.pixelFormat = pixelFormat; self.alphaMode = alphaMode; self.colorSpace = colorSpace
    }
    private enum CodingKeys: String, CodingKey { case pixelFormat, alphaMode, colorSpace }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pixelFormat = try c.decode(ArtPixelFormat.self, forKey: .pixelFormat)
        alphaMode = try c.decode(ArtAlphaMode.self, forKey: .alphaMode)
        colorSpace = try c.decode(ArtColorSpace.self, forKey: .colorSpace)
        if colorSpace == .extendedSRGB && pixelFormat != .rgba16Float {
            throw DecodingError.dataCorruptedError(forKey: .colorSpace, in: c, debugDescription: "广色域需要 16F 像素")
        }
    }

    static let stageOneDefault = ArtColorStandard(
        pixelFormat: .rgba8,
        alphaMode: .premultiplied,
        colorSpace: .sRGB
    )

    static let wideGamut = ArtColorStandard(pixelFormat: .rgba16Float, alphaMode: .premultiplied, colorSpace: .extendedSRGB)

    /// sRGB primaries, linear-light premultiplied half-float storage.
    static let highPrecision = ArtColorStandard(pixelFormat: .rgba16Float, alphaMode: .premultiplied, colorSpace: .sRGB)
}

struct RGBAColor: Codable, Sendable, Equatable, Hashable {
    var red: Float
    var green: Float
    var blue: Float
    var alpha: Float

    static let black = RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)
    static let white = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)

    var premultiplied: RGBAColor {
        RGBAColor(
            red: red * alpha,
            green: green * alpha,
            blue: blue * alpha,
            alpha: alpha
        )
    }

    func withAlpha(_ alpha: Float) -> RGBAColor {
        RGBAColor(
            red: red,
            green: green,
            blue: blue,
            alpha: min(max(alpha, 0), 1)
        )
    }
}

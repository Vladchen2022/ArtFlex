import Foundation

enum ArtPixelFormat: String, Codable, Sendable {
    case rgba8
}

enum ArtAlphaMode: String, Codable, Sendable {
    case premultiplied
}

enum ArtColorSpace: String, Codable, Sendable {
    case sRGB
}

struct ArtColorStandard: Codable, Sendable, Equatable {
    let pixelFormat: ArtPixelFormat
    let alphaMode: ArtAlphaMode
    let colorSpace: ArtColorSpace

    static let stageOneDefault = ArtColorStandard(
        pixelFormat: .rgba8,
        alphaMode: .premultiplied,
        colorSpace: .sRGB
    )
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

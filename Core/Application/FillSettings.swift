import Foundation

enum FillSampleSource: String, Codable, Sendable, Equatable, CaseIterable {
    /// Preserves the existing behavior: use visible marked references when present,
    /// otherwise sample the current layer.
    case automatic
    case currentLayer
    case allVisibleLayers
    case markedReferenceLayers
}

struct FillSettings: Codable, Sendable, Equatable {
    var tolerance: Float
    var isContiguous: Bool
    var sampleSource: FillSampleSource
    var closeGapPixels: Int
    var expandPixels: Int

    static let stageOneDefault = FillSettings(
        tolerance: 0,
        isContiguous: true,
        sampleSource: .automatic
    )

    init(
        tolerance: Float,
        isContiguous: Bool,
        sampleSource: FillSampleSource,
        closeGapPixels: Int = 0,
        expandPixels: Int = 0
    ) {
        self.tolerance = Self.clampedTolerance(tolerance)
        self.isContiguous = isContiguous
        self.sampleSource = sampleSource
        self.closeGapPixels = min(max(closeGapPixels, 0), 16)
        self.expandPixels = min(max(expandPixels, 0), 8)
    }

    private enum CodingKeys: String, CodingKey {
        case tolerance
        case isContiguous
        case sampleSource
        case closeGapPixels
        case expandPixels
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            tolerance: try container.decodeIfPresent(Float.self, forKey: .tolerance) ?? 0,
            isContiguous: try container.decodeIfPresent(Bool.self, forKey: .isContiguous) ?? true,
            sampleSource: try container.decodeIfPresent(
                FillSampleSource.self,
                forKey: .sampleSource
            ) ?? .automatic,
            closeGapPixels: try container.decodeIfPresent(Int.self, forKey: .closeGapPixels) ?? 0,
            expandPixels: try container.decodeIfPresent(Int.self, forKey: .expandPixels) ?? 0
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.clampedTolerance(tolerance), forKey: .tolerance)
        try container.encode(isContiguous, forKey: .isContiguous)
        try container.encode(sampleSource, forKey: .sampleSource)
        try container.encode(closeGapPixels, forKey: .closeGapPixels)
        try container.encode(expandPixels, forKey: .expandPixels)
    }

    var normalizedTolerance: Float {
        Self.clampedTolerance(tolerance)
    }

    private static func clampedTolerance(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

struct PremultipliedSRGBAPixel: Sendable, Equatable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var alpha: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(bgraBlue: UInt8, green: UInt8, red: UInt8, alpha: UInt8) {
        self.init(red: red, green: green, blue: bgraBlue, alpha: alpha)
    }
}

struct UnpremultipliedSRGBAComponents: Sendable, Equatable {
    var red: Float
    var green: Float
    var blue: Float
    var alpha: Float
}

enum FillColorDistance {
    static func unpremultipliedComponents(
        of pixel: PremultipliedSRGBAPixel
    ) -> UnpremultipliedSRGBAComponents {
        let alpha = Float(pixel.alpha) / 255
        guard pixel.alpha > 0 else {
            return .init(red: 0, green: 0, blue: 0, alpha: 0)
        }

        return UnpremultipliedSRGBAComponents(
            red: min(max((Float(pixel.red) / 255) / alpha, 0), 1),
            green: min(max((Float(pixel.green) / 255) / alpha, 0), 1),
            blue: min(max((Float(pixel.blue) / 255) / alpha, 0), 1),
            alpha: alpha
        )
    }

    /// Euclidean distance in unpremultiplied sRGB + alpha, normalized to 0...1.
    static func normalizedDistance(
        between lhs: PremultipliedSRGBAPixel,
        and rhs: PremultipliedSRGBAPixel
    ) -> Float {
        let lhs = unpremultipliedComponents(of: lhs)
        let rhs = unpremultipliedComponents(of: rhs)
        let red = lhs.red - rhs.red
        let green = lhs.green - rhs.green
        let blue = lhs.blue - rhs.blue
        let alpha = lhs.alpha - rhs.alpha
        return sqrt(((red * red) + (green * green) + (blue * blue) + (alpha * alpha)) / 4)
    }

    static func matches(
        _ lhs: PremultipliedSRGBAPixel,
        _ rhs: PremultipliedSRGBAPixel,
        tolerance: Float
    ) -> Bool {
        guard tolerance.isFinite, tolerance > 0 else {
            return lhs == rhs
        }
        return normalizedDistance(between: lhs, and: rhs) <= min(tolerance, 1)
    }
}

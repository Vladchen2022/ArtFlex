import Foundation

enum GeneratorKind: String, Codable, Sendable, Equatable, CaseIterable {
    case automaticLines
    case inkBlots
    case fragmentField
    case brushStack
    case colorClusters
    case driftDraw

    var displayName: String {
        switch self {
        case .automaticLines:
            return "自动线条"
        case .inkBlots:
            return "墨迹块"
        case .fragmentField:
            return "碎片场"
        case .brushStack:
            return "刷毛堆叠"
        case .colorClusters:
            return "色团组合"
        case .driftDraw:
            return "偏离手绘"
        }
    }
}

struct GeneratorSettings: Codable, Sendable, Equatable {
    var kind: GeneratorKind
    var density: Float
    var drift: Float
    var branch: Float
    var opacity: Float

    static let stageOneDefault = GeneratorSettings(
        kind: .automaticLines,
        density: 0.55,
        drift: 0.62,
        branch: 0.38,
        opacity: 1
    )

    private enum CodingKeys: String, CodingKey {
        case kind
        case density
        case drift
        case branch
        case opacity
        case scale
    }

    init(
        kind: GeneratorKind,
        density: Float,
        drift: Float,
        branch: Float,
        opacity: Float
    ) {
        self.kind = kind
        self.density = density
        self.drift = drift
        self.branch = branch
        self.opacity = opacity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kindRaw = try container.decodeIfPresent(String.self, forKey: .kind) ?? GeneratorKind.automaticLines.rawValue
        let legacyScale = try container.decodeIfPresent(Float.self, forKey: .scale)

        kind = Self.decodeKind(from: kindRaw)
        density = try container.decodeIfPresent(Float.self, forKey: .density) ?? Self.legacyDensity(from: legacyScale)
        drift = try container.decodeIfPresent(Float.self, forKey: .drift) ?? GeneratorSettings.stageOneDefault.drift
        branch = try container.decodeIfPresent(Float.self, forKey: .branch) ?? GeneratorSettings.stageOneDefault.branch
        opacity = try container.decodeIfPresent(Float.self, forKey: .opacity) ?? GeneratorSettings.stageOneDefault.opacity
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .kind)
        try container.encode(density, forKey: .density)
        try container.encode(drift, forKey: .drift)
        try container.encode(branch, forKey: .branch)
        try container.encode(opacity, forKey: .opacity)
    }

    private static func decodeKind(from rawValue: String) -> GeneratorKind {
        if let kind = GeneratorKind(rawValue: rawValue) {
            return kind
        }

        switch rawValue {
        case "checker", "diagonalStripes", "radialBurst":
            return .automaticLines
        default:
            return .automaticLines
        }
    }

    private static func legacyDensity(from scale: Float?) -> Float {
        guard let scale else {
            return GeneratorSettings.stageOneDefault.density
        }

        let normalized = 1 - ((min(max(scale, 8), 256) - 8) / (256 - 8))
        return min(max(0.15 + (normalized * 0.7), 0), 1)
    }
}

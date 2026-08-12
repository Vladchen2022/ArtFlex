import Foundation

struct OilPaintBrushSettings: Codable, Sendable, Equatable {
    var isEnabled: Bool
    var newColorLoad: Float
    var lightnessFollow: Float

    static let disabled = OilPaintBrushSettings(
        isEnabled: false,
        newColorLoad: 0.35,
        lightnessFollow: 0.75
    )

    init(isEnabled: Bool, newColorLoad: Float, lightnessFollow: Float = 0.75) {
        self.isEnabled = isEnabled
        self.newColorLoad = min(max(newColorLoad, 0), 1)
        self.lightnessFollow = min(max(lightnessFollow, 0), 1)
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case newColorLoad
        case lightnessFollow
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
            newColorLoad: try container.decodeIfPresent(Float.self, forKey: .newColorLoad) ?? 0.35,
            lightnessFollow: try container.decodeIfPresent(Float.self, forKey: .lightnessFollow) ?? 0.75
        )
    }
}

enum OilPaintOutputMode: String, Sendable, Equatable, Hashable {
    case reservoir
    case currentColor
}

struct BrushPigmentComponent: Sendable, Equatable {
    var color: RGBAColor
    var weight: Float
}

struct BrushPigmentPalette: Sendable, Equatable {
    static let maximumComponentCount = 4
    static let empty = BrushPigmentPalette(components: [])

    var components: [BrushPigmentComponent]

    init(components: [BrushPigmentComponent]) {
        self.components = Self.normalized(components)
    }

    private static func normalized(
        _ input: [BrushPigmentComponent]
    ) -> [BrushPigmentComponent] {
        let filtered = input
            .filter { $0.weight > 0.0001 }
            .prefix(maximumComponentCount)
        let total = filtered.reduce(Float.zero) { $0 + $1.weight }
        guard total > 0.0001 else { return [] }
        return filtered.map {
            BrushPigmentComponent(color: $0.color, weight: $0.weight / total)
        }
    }
}

struct OilPaintPigmentReservoirState: Sendable, Equatable {
    private(set) var components: [BrushPigmentComponent]
    private(set) var latestLoadedColor: RGBAColor

    init(cleanColor: RGBAColor) {
        components = [BrushPigmentComponent(color: cleanColor, weight: 1)]
        latestLoadedColor = cleanColor
    }

    var palette: BrushPigmentPalette {
        BrushPigmentPalette(components: components)
    }

    func palette(lightnessFollow: Float) -> BrushPigmentPalette {
        BrushPigmentPalette(components: components.map { component in
            BrushPigmentComponent(
                color: OilPaintLightnessMatcher.match(
                    component.color,
                    to: latestLoadedColor,
                    amount: lightnessFollow
                ),
                weight: component.weight
            )
        })
    }

    mutating func wash(with color: RGBAColor) {
        components = [BrushPigmentComponent(color: color, weight: 1)]
        latestLoadedColor = color
    }

    mutating func load(_ color: RGBAColor, amount: Float) {
        let clampedAmount = min(max(amount, 0), 1)
        latestLoadedColor = color
        guard !components.isEmpty else {
            wash(with: color)
            return
        }
        if clampedAmount <= 0.0001 || clampedAmount >= 0.9999 {
            wash(with: color)
            return
        }

        let retainedWeight = 1 - clampedAmount
        for index in components.indices {
            components[index].weight *= retainedWeight
        }

        if let matchingIndex = components.firstIndex(where: {
            Self.colorDistanceSquared($0.color, color) <= 0.0004
        }) {
            components[matchingIndex].weight += clampedAmount
        } else {
            components.append(BrushPigmentComponent(color: color, weight: clampedAmount))
        }

        components.removeAll { $0.weight < 0.01 }
        if components.count > BrushPigmentPalette.maximumComponentCount {
            let newestIndex = components.index(before: components.endIndex)
            let removableIndex = components.indices
                .filter { $0 != newestIndex }
                .min { components[$0].weight < components[$1].weight }
            if let removableIndex {
                components.remove(at: removableIndex)
            }
        }
        normalizeWeights()
    }

    mutating func setBoundary(
        after componentIndex: Int,
        cumulativeWeight: Float,
        minimumComponentWeight: Float = 0.03
    ) {
        guard components.indices.contains(componentIndex),
              components.indices.contains(componentIndex + 1) else {
            return
        }
        let lowerBound = components[..<componentIndex].reduce(Float.zero) { $0 + $1.weight }
        let pairTotal = components[componentIndex].weight + components[componentIndex + 1].weight
        let upperBound = lowerBound + pairTotal
        let minimum = min(max(minimumComponentWeight, 0), pairTotal * 0.5)
        let boundary = min(max(cumulativeWeight, lowerBound + minimum), upperBound - minimum)
        components[componentIndex].weight = boundary - lowerBound
        components[componentIndex + 1].weight = upperBound - boundary
        normalizeWeights()
    }

    private mutating func normalizeWeights() {
        let total = components.reduce(Float.zero) { $0 + $1.weight }
        guard total > 0.0001 else { return }
        for index in components.indices {
            components[index].weight /= total
        }
    }

    private static func colorDistanceSquared(_ lhs: RGBAColor, _ rhs: RGBAColor) -> Float {
        let red = lhs.red - rhs.red
        let green = lhs.green - rhs.green
        let blue = lhs.blue - rhs.blue
        return (red * red) + (green * green) + (blue * blue)
    }
}

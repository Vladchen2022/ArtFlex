import Foundation

struct GradientStop: Codable, Identifiable, Sendable, Equatable, Hashable {
    var id: UUID
    var position: Float
    var color: RGBAColor

    init(
        id: UUID = UUID(),
        position: Float,
        color: RGBAColor
    ) {
        self.id = id
        self.position = position
        self.color = color
    }
}

struct GradientSettings: Codable, Sendable, Equatable {
    static let minimumStopCount = 2
    static let maximumStopCount = 8

    private(set) var stops: [GradientStop]

    init(stops: [GradientStop]) {
        self.stops = Self.normalizedStops(stops)
    }

    private enum CodingKeys: String, CodingKey {
        case stops
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(stops: try container.decodeIfPresent([GradientStop].self, forKey: .stops) ?? [])
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stops, forKey: .stops)
    }

    static func currentColorToTransparent(_ color: RGBAColor) -> GradientSettings {
        let color = clampedColor(color)
        return GradientSettings(stops: [
            GradientStop(position: 0, color: color),
            GradientStop(position: 1, color: color.withAlpha(0))
        ])
    }

    @discardableResult
    mutating func insertStop(
        at position: Float,
        color: RGBAColor,
        id: UUID = UUID()
    ) -> Bool {
        guard stops.count < Self.maximumStopCount else { return false }
        stops.append(GradientStop(id: id, position: position, color: color))
        stops = Self.normalizedStops(stops)
        return true
    }

    @discardableResult
    mutating func updateStop(
        id: UUID,
        position: Float? = nil,
        color: RGBAColor? = nil
    ) -> Bool {
        guard let index = stops.firstIndex(where: { $0.id == id }) else { return false }
        if let position {
            stops[index].position = position
        }
        if let color {
            stops[index].color = color
        }
        stops = Self.normalizedStops(stops)
        return true
    }

    @discardableResult
    mutating func removeStop(id: UUID) -> Bool {
        guard stops.count > Self.minimumStopCount else { return false }
        guard let index = stops.firstIndex(where: { $0.id == id }) else { return false }
        stops.remove(at: index)
        return true
    }

    func color(at position: Float) -> RGBAColor {
        let position = position.isFinite ? min(max(position, 0), 1) : 0
        guard let first = stops.first else { return .black }

        var lower = first
        for upper in stops.dropFirst() {
            if position < upper.position {
                let span = upper.position - lower.position
                let amount = span > 0 ? (position - lower.position) / span : 1
                return Self.interpolate(lower.color, upper.color, amount: amount)
            }
            lower = upper
        }
        return lower.color
    }

    func premultipliedColor(at position: Float) -> RGBAColor {
        color(at: position).premultiplied
    }

    private static func normalizedStops(_ input: [GradientStop]) -> [GradientStop] {
        var normalized = input.prefix(Self.maximumStopCount).map { stop in
            GradientStop(
                id: stop.id,
                position: stop.position.isFinite ? min(max(stop.position, 0), 1) : 0,
                color: clampedColor(stop.color)
            )
        }

        if normalized.isEmpty {
            normalized = [
                GradientStop(position: 0, color: .black),
                GradientStop(position: 1, color: .black.withAlpha(0))
            ]
        } else if normalized.count == 1, let only = normalized.first {
            let addedPosition: Float = only.position < 0.5 ? 1 : 0
            normalized.append(GradientStop(position: addedPosition, color: only.color))
        }

        return normalized.enumerated().sorted { lhs, rhs in
            if lhs.element.position == rhs.element.position {
                return lhs.offset < rhs.offset
            }
            return lhs.element.position < rhs.element.position
        }.map(\.element)
    }

    private static func clampedColor(_ color: RGBAColor) -> RGBAColor {
        RGBAColor(
            red: color.red.isFinite ? min(max(color.red, 0), 1) : 0,
            green: color.green.isFinite ? min(max(color.green, 0), 1) : 0,
            blue: color.blue.isFinite ? min(max(color.blue, 0), 1) : 0,
            alpha: color.alpha.isFinite ? min(max(color.alpha, 0), 1) : 0
        )
    }

    private static func interpolate(
        _ lhs: RGBAColor,
        _ rhs: RGBAColor,
        amount: Float
    ) -> RGBAColor {
        let amount = min(max(amount, 0), 1)
        return RGBAColor(
            red: lhs.red + ((rhs.red - lhs.red) * amount),
            green: lhs.green + ((rhs.green - lhs.green) * amount),
            blue: lhs.blue + ((rhs.blue - lhs.blue) * amount),
            alpha: lhs.alpha + ((rhs.alpha - lhs.alpha) * amount)
        )
    }
}

import Foundation

struct CanvasPoint: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
}

struct CanvasViewport: Codable, Sendable, Equatable {
    var zoomScale: Double
    var contentOffset: CanvasPoint
    var rotationDegrees: Double

    init(
        zoomScale: Double,
        contentOffset: CanvasPoint,
        rotationDegrees: Double = 0
    ) {
        self.zoomScale = zoomScale
        self.contentOffset = contentOffset
        self.rotationDegrees = rotationDegrees
    }

    private enum CodingKeys: String, CodingKey {
        case zoomScale
        case contentOffset
        case rotationDegrees
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        zoomScale = try container.decode(Double.self, forKey: .zoomScale)
        contentOffset = try container.decode(CanvasPoint.self, forKey: .contentOffset)
        rotationDegrees = try container.decodeIfPresent(Double.self, forKey: .rotationDegrees) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(zoomScale, forKey: .zoomScale)
        try container.encode(contentOffset, forKey: .contentOffset)
        try container.encode(rotationDegrees, forKey: .rotationDegrees)
    }

    static let stageOneDefault = CanvasViewport(
        zoomScale: 1,
        contentOffset: CanvasPoint(x: 0, y: 0),
        rotationDegrees: 0
    )
}

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

    mutating func setZoomScale(
        _ newZoomScale: Double,
        anchoredAt anchorCanvasPoint: CanvasPoint?,
        canvasSize: CanvasSize,
        availableWidth: Double,
        availableHeight: Double
    ) {
        let clampedZoomScale = min(max(newZoomScale, 0.01), 256)
        guard clampedZoomScale.isFinite else { return }

        guard
            let anchorCanvasPoint,
            availableWidth > 0,
            availableHeight > 0,
            canvasSize.width > 0,
            canvasSize.height > 0
        else {
            zoomScale = clampedZoomScale
            return
        }

        let previousZoomScale = max(zoomScale, 0.01)
        guard abs(previousZoomScale - clampedZoomScale) > 0.000_001 else { return }

        let presentation = CanvasPresentationBuilder.makePresentation(
            canvasSize: canvasSize,
            viewport: self,
            availableWidth: availableWidth,
            availableHeight: availableHeight
        )
        let displayWidth = presentation.documentDisplaySize.x
        let displayHeight = presentation.documentDisplaySize.y
        guard displayWidth > 0, displayHeight > 0 else {
            zoomScale = clampedZoomScale
            return
        }

        let clampedAnchor = CanvasPoint(
            x: min(max(anchorCanvasPoint.x, 0), Double(canvasSize.width)),
            y: min(max(anchorCanvasPoint.y, 0), Double(canvasSize.height))
        )
        let localAnchor = CanvasPoint(
            x: (clampedAnchor.x / Double(canvasSize.width)) * displayWidth - (displayWidth / 2),
            y: (clampedAnchor.y / Double(canvasSize.height)) * displayHeight - (displayHeight / 2)
        )
        let rotationRadians = rotationDegrees * .pi / 180
        let rotatedAnchor = CanvasPoint(
            x: (localAnchor.x * cos(rotationRadians)) - (localAnchor.y * sin(rotationRadians)),
            y: (localAnchor.x * sin(rotationRadians)) + (localAnchor.y * cos(rotationRadians))
        )
        let zoomDelta = previousZoomScale - clampedZoomScale

        contentOffset.x += rotatedAnchor.x * zoomDelta
        contentOffset.y += rotatedAnchor.y * zoomDelta
        zoomScale = clampedZoomScale
    }
}

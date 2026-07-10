import Foundation

struct CanvasViewportTransform: Sendable, Equatable {
    let canvasSize: CanvasSize
    let viewport: CanvasViewport
    let viewportSize: CanvasPoint
    let padding: Double
    let fitScale: Double

    init(
        canvasSize: CanvasSize,
        viewport: CanvasViewport,
        availableWidth: Double,
        availableHeight: Double,
        padding: Double = 48
    ) {
        self.canvasSize = canvasSize
        self.viewport = viewport
        viewportSize = CanvasPoint(x: availableWidth, y: availableHeight)
        self.padding = padding

        let usableWidth = max(availableWidth - (padding * 2), 1)
        let usableHeight = max(availableHeight - (padding * 2), 1)
        fitScale = max(
            min(
                usableWidth / Double(max(canvasSize.width, 1)),
                usableHeight / Double(max(canvasSize.height, 1))
            ),
            0.01
        )
    }

    var actualDisplayScale: Double {
        fitScale * max(viewport.zoomScale, 0.01)
    }

    var actualZoomPercent: Double {
        actualDisplayScale * 100
    }

    var documentCenter: CanvasPoint {
        CanvasPoint(
            x: (viewportSize.x / 2) + viewport.contentOffset.x,
            y: (viewportSize.y / 2) + viewport.contentOffset.y
        )
    }

    func canvasToViewport(_ point: CanvasPoint) -> CanvasPoint {
        let localX = (point.x - (Double(canvasSize.width) / 2)) * actualDisplayScale
        let localY = (point.y - (Double(canvasSize.height) / 2)) * actualDisplayScale
        let radians = viewport.rotationDegrees * .pi / 180
        let rotatedX = (localX * cos(radians)) - (localY * sin(radians))
        let rotatedY = (localX * sin(radians)) + (localY * cos(radians))
        let center = documentCenter
        return CanvasPoint(x: center.x + rotatedX, y: center.y + rotatedY)
    }

    func viewportToCanvas(_ point: CanvasPoint, clamped: Bool = false) -> CanvasPoint {
        let center = documentCenter
        let translatedX = point.x - center.x
        let translatedY = point.y - center.y
        let radians = -viewport.rotationDegrees * .pi / 180
        let unrotatedX = (translatedX * cos(radians)) - (translatedY * sin(radians))
        let unrotatedY = (translatedX * sin(radians)) + (translatedY * cos(radians))
        let scale = max(actualDisplayScale, 0.000_001)
        let resolved = CanvasPoint(
            x: (unrotatedX / scale) + (Double(canvasSize.width) / 2),
            y: (unrotatedY / scale) + (Double(canvasSize.height) / 2)
        )
        guard clamped else { return resolved }
        return clampToCanvas(resolved)
    }

    func viewportOffsetCentering(on canvasPoint: CanvasPoint) -> CanvasPoint {
        let localX = (canvasPoint.x - (Double(canvasSize.width) / 2)) * actualDisplayScale
        let localY = (canvasPoint.y - (Double(canvasSize.height) / 2)) * actualDisplayScale
        let radians = viewport.rotationDegrees * .pi / 180
        return CanvasPoint(
            x: -((localX * cos(radians)) - (localY * sin(radians))),
            y: -((localX * sin(radians)) + (localY * cos(radians)))
        )
    }

    func clampToCanvas(_ point: CanvasPoint) -> CanvasPoint {
        CanvasPoint(
            x: min(max(point.x, 0), Double(canvasSize.width)),
            y: min(max(point.y, 0), Double(canvasSize.height))
        )
    }
}

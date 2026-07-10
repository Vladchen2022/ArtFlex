import Foundation

struct CanvasPresentation: Sendable, Equatable {
    var viewportSize: CanvasPoint
    var documentOrigin: CanvasPoint
    var documentDisplaySize: CanvasPoint
    var documentZoomScale: Double
    var fitScale: Double = 1

    var actualDisplayScale: Double {
        fitScale * documentZoomScale
    }
}

enum CanvasPresentationBuilder {
    static func makePresentation(
        canvasSize: CanvasSize,
        viewport: CanvasViewport,
        availableWidth: Double,
        availableHeight: Double,
        padding: Double = 48
    ) -> CanvasPresentation {
        let usableWidth = max(availableWidth - (padding * 2), 1)
        let usableHeight = max(availableHeight - (padding * 2), 1)

        let fitScale = min(
            usableWidth / Double(canvasSize.width),
            usableHeight / Double(canvasSize.height)
        )

        let baseScale = max(fitScale, 0.01)
        let displayWidth = Double(canvasSize.width) * baseScale
        let displayHeight = Double(canvasSize.height) * baseScale

        let centeredX = (availableWidth - displayWidth) / 2
        let centeredY = (availableHeight - displayHeight) / 2

        return CanvasPresentation(
            viewportSize: CanvasPoint(x: availableWidth, y: availableHeight),
            documentOrigin: CanvasPoint(
                x: centeredX + viewport.contentOffset.x,
                y: centeredY + viewport.contentOffset.y
            ),
            documentDisplaySize: CanvasPoint(
                x: displayWidth,
                y: displayHeight
            ),
            documentZoomScale: max(viewport.zoomScale, 0.01),
            fitScale: baseScale
        )
    }
}

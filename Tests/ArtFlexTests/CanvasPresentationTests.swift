import Foundation
import Testing
@testable import ArtFlex

struct CanvasPresentationTests {
    @Test
    func viewportDecodesLegacyPayloadWithoutRotationDegrees() throws {
        let data = Data("""
        {
          "zoomScale": 1.5,
          "contentOffset": {
            "x": 12,
            "y": -8
          }
        }
        """.utf8)

        let viewport = try JSONDecoder().decode(CanvasViewport.self, from: data)

        #expect(viewport.zoomScale == 1.5)
        #expect(viewport.contentOffset == CanvasPoint(x: 12, y: -8))
        #expect(viewport.rotationDegrees == 0)
    }

    @Test
    func presentationCentersDocumentWhenViewportOffsetIsZero() {
        let presentation = CanvasPresentationBuilder.makePresentation(
            canvasSize: CanvasSize(width: 1000, height: 1000),
            viewport: .stageOneDefault,
            availableWidth: 1200,
            availableHeight: 1000
        )

        #expect(presentation.documentDisplaySize.x == 904)
        #expect(presentation.documentDisplaySize.y == 904)
        #expect(presentation.documentOrigin.x == 148)
        #expect(presentation.documentOrigin.y == 48)
    }

    @Test
    func presentationAppliesViewportOffsetOnTopOfCentering() {
        let viewport = CanvasViewport(
            zoomScale: 1,
            contentOffset: CanvasPoint(x: 25, y: -10)
        )

        let presentation = CanvasPresentationBuilder.makePresentation(
            canvasSize: CanvasSize(width: 1000, height: 1000),
            viewport: viewport,
            availableWidth: 1200,
            availableHeight: 1000
        )

        #expect(presentation.documentOrigin.x == 173)
        #expect(presentation.documentOrigin.y == 38)
    }

    @Test
    func anchoredZoomKeepsHoveredCanvasPointStationary() {
        var viewport = CanvasViewport(
            zoomScale: 1,
            contentOffset: CanvasPoint(x: 18, y: -12)
        )
        let canvasSize = CanvasSize(width: 1000, height: 800)
        let anchorPoint = CanvasPoint(x: 760, y: 180)

        let before = screenPoint(
            for: anchorPoint,
            viewport: viewport,
            canvasSize: canvasSize,
            availableWidth: 1200,
            availableHeight: 1000
        )

        viewport.setZoomScale(
            1.8,
            anchoredAt: anchorPoint,
            canvasSize: canvasSize,
            availableWidth: 1200,
            availableHeight: 1000
        )

        let after = screenPoint(
            for: anchorPoint,
            viewport: viewport,
            canvasSize: canvasSize,
            availableWidth: 1200,
            availableHeight: 1000
        )

        #expect(abs(after.x - before.x) < 0.001)
        #expect(abs(after.y - before.y) < 0.001)
    }

    @Test
    func anchoredZoomKeepsHoveredCanvasPointStationaryWithRotation() {
        var viewport = CanvasViewport(
            zoomScale: 1.15,
            contentOffset: CanvasPoint(x: -34, y: 26),
            rotationDegrees: 32
        )
        let canvasSize = CanvasSize(width: 960, height: 960)
        let anchorPoint = CanvasPoint(x: 710, y: 260)

        let before = screenPoint(
            for: anchorPoint,
            viewport: viewport,
            canvasSize: canvasSize,
            availableWidth: 1400,
            availableHeight: 900
        )

        viewport.setZoomScale(
            1.95,
            anchoredAt: anchorPoint,
            canvasSize: canvasSize,
            availableWidth: 1400,
            availableHeight: 900
        )

        let after = screenPoint(
            for: anchorPoint,
            viewport: viewport,
            canvasSize: canvasSize,
            availableWidth: 1400,
            availableHeight: 900
        )

        #expect(abs(after.x - before.x) < 0.001)
        #expect(abs(after.y - before.y) < 0.001)
    }

    private func screenPoint(
        for canvasPoint: CanvasPoint,
        viewport: CanvasViewport,
        canvasSize: CanvasSize,
        availableWidth: Double,
        availableHeight: Double
    ) -> CanvasPoint {
        let presentation = CanvasPresentationBuilder.makePresentation(
            canvasSize: canvasSize,
            viewport: viewport,
            availableWidth: availableWidth,
            availableHeight: availableHeight
        )
        let displayWidth = presentation.documentDisplaySize.x
        let displayHeight = presentation.documentDisplaySize.y
        let center = CanvasPoint(
            x: presentation.documentOrigin.x + (displayWidth / 2),
            y: presentation.documentOrigin.y + (displayHeight / 2)
        )
        let localPoint = CanvasPoint(
            x: (canvasPoint.x / Double(canvasSize.width)) * displayWidth - (displayWidth / 2),
            y: (canvasPoint.y / Double(canvasSize.height)) * displayHeight - (displayHeight / 2)
        )
        let zoomedPoint = CanvasPoint(
            x: localPoint.x * viewport.zoomScale,
            y: localPoint.y * viewport.zoomScale
        )
        let rotationRadians = viewport.rotationDegrees * .pi / 180
        let rotatedPoint = CanvasPoint(
            x: (zoomedPoint.x * cos(rotationRadians)) - (zoomedPoint.y * sin(rotationRadians)),
            y: (zoomedPoint.x * sin(rotationRadians)) + (zoomedPoint.y * cos(rotationRadians))
        )
        return CanvasPoint(
            x: center.x + rotatedPoint.x,
            y: center.y + rotatedPoint.y
        )
    }
}

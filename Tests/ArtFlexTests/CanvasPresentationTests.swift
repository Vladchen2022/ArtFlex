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
        #expect(!viewport.isHorizontallyFlipped)
    }

    @Test
    func viewportRoundTripsHorizontalFlipState() throws {
        let viewport = CanvasViewport(
            zoomScale: 1.8,
            contentOffset: .init(x: 21, y: -13),
            rotationDegrees: 17,
            isHorizontallyFlipped: true
        )

        let data = try JSONEncoder().encode(viewport)
        let restored = try JSONDecoder().decode(CanvasViewport.self, from: data)

        #expect(restored == viewport)
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

    @Test
    func anchoredZoomKeepsHoveredCanvasPointStationaryWhenFlippedAndRotated() {
        var viewport = CanvasViewport(
            zoomScale: 1.15,
            contentOffset: CanvasPoint(x: -34, y: 26),
            rotationDegrees: 32,
            isHorizontallyFlipped: true
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

    @Test
    func viewportTransformRoundTripsCanvasPointsWithPanZoomAndRotation() {
        let transform = CanvasViewportTransform(
            canvasSize: .init(width: 1600, height: 900),
            viewport: .init(
                zoomScale: 2.4,
                contentOffset: .init(x: 73, y: -41),
                rotationDegrees: 27
            ),
            availableWidth: 1320,
            availableHeight: 840
        )
        let point = CanvasPoint(x: 1180, y: 247)

        let viewportPoint = transform.canvasToViewport(point)
        let restored = transform.viewportToCanvas(viewportPoint)

        #expect(abs(restored.x - point.x) < 0.000_001)
        #expect(abs(restored.y - point.y) < 0.000_001)
    }

    @Test
    func viewportTransformRoundTripsCanvasPointsWhenFlippedAndRotated() {
        let transform = CanvasViewportTransform(
            canvasSize: .init(width: 1600, height: 900),
            viewport: .init(
                zoomScale: 2.4,
                contentOffset: .init(x: 73, y: -41),
                rotationDegrees: 27,
                isHorizontallyFlipped: true
            ),
            availableWidth: 1320,
            availableHeight: 840
        )
        let point = CanvasPoint(x: 1180, y: 247)

        let viewportPoint = transform.canvasToViewport(point)
        let restored = transform.viewportToCanvas(viewportPoint)

        #expect(abs(restored.x - point.x) < 0.000_001)
        #expect(abs(restored.y - point.y) < 0.000_001)
    }

    @Test
    func horizontalFlipMirrorsCanvasPointsBeforeRotation() {
        let canvasSize = CanvasSize(width: 1000, height: 800)
        let normal = CanvasViewportTransform(
            canvasSize: canvasSize,
            viewport: .init(
                zoomScale: 1.7,
                contentOffset: .init(x: 18, y: -24),
                rotationDegrees: 31
            ),
            availableWidth: 1200,
            availableHeight: 900
        )
        let flipped = CanvasViewportTransform(
            canvasSize: canvasSize,
            viewport: .init(
                zoomScale: 1.7,
                contentOffset: .init(x: 18, y: -24),
                rotationDegrees: 31,
                isHorizontallyFlipped: true
            ),
            availableWidth: 1200,
            availableHeight: 900
        )

        let normalMirroredPoint = normal.canvasToViewport(.init(x: 750, y: 230))
        let flippedPoint = flipped.canvasToViewport(.init(x: 250, y: 230))

        #expect(abs(flippedPoint.x - normalMirroredPoint.x) < 0.000_001)
        #expect(abs(flippedPoint.y - normalMirroredPoint.y) < 0.000_001)
    }

    @Test
    func viewportTransformDetectsCanvasInteriorForRotatedOutsideSelectionStarts() {
        let transform = CanvasViewportTransform(
            canvasSize: .init(width: 640, height: 480),
            viewport: .init(
                zoomScale: 1.7,
                contentOffset: .init(x: 42, y: -31),
                rotationDegrees: 33
            ),
            availableWidth: 1100,
            availableHeight: 760
        )

        let insideViewportPoint = transform.canvasToViewport(.init(x: 320, y: 240))
        let edgeViewportPoint = transform.canvasToViewport(.init(x: 0, y: 480))
        let outsideViewportPoint = transform.canvasToViewport(.init(x: -12, y: 240))

        #expect(transform.containsViewportPoint(insideViewportPoint))
        #expect(transform.containsViewportPoint(edgeViewportPoint))
        #expect(!transform.containsViewportPoint(outsideViewportPoint))
    }

    @Test
    func everySelectionCreationToolSupportsAnOutsideCanvasStart() {
        let selectionTools: [ToolKind] = [
            .rectangleSelection,
            .ellipseSelection,
            .lassoSelection,
            .smartSelection,
            .polygonSelection,
            .lassoFill,
            .textureFill
        ]

        let everySelectionToolSupportsOutsideStart = selectionTools.allSatisfy {
            $0.supportsOutsideCanvasSelectionStart
        }
        #expect(everySelectionToolSupportsOutsideStart)
        #expect(!ToolKind.brush.supportsOutsideCanvasSelectionStart)
        #expect(!ToolKind.freeTransform.supportsOutsideCanvasSelectionStart)
    }

    @Test
    func viewportCenteringOffsetPlacesRequestedCanvasPointAtViewportCenter() {
        var viewport = CanvasViewport(
            zoomScale: 1.8,
            contentOffset: .init(x: 0, y: 0),
            rotationDegrees: -18
        )
        let target = CanvasPoint(x: 820, y: 220)
        let initial = CanvasViewportTransform(
            canvasSize: .init(width: 1200, height: 800),
            viewport: viewport,
            availableWidth: 1000,
            availableHeight: 700
        )
        viewport.contentOffset = initial.viewportOffsetCentering(on: target)
        let centered = CanvasViewportTransform(
            canvasSize: .init(width: 1200, height: 800),
            viewport: viewport,
            availableWidth: 1000,
            availableHeight: 700
        ).canvasToViewport(target)

        #expect(abs(centered.x - 500) < 0.000_001)
        #expect(abs(centered.y - 350) < 0.000_001)
    }

    @Test
    func canvasCropStateCreatesMovesAndResizesPixelAlignedBounds() throws {
        let canvasSize = CanvasSize(width: 100, height: 80)
        var state = CanvasCropInteractionState()

        state.begin(at: .init(x: 10.2, y: 8.7), canvasSize: canvasSize, handleRadius: 3)
        state.end(at: .init(x: 70.4, y: 50.1), canvasSize: canvasSize)
        #expect(state.pixelBounds(in: canvasSize) == .init(origin: .init(x: 10, y: 9), size: .init(x: 60, y: 41)))

        state.begin(at: .init(x: 30, y: 30), canvasSize: canvasSize, handleRadius: 3)
        state.end(at: .init(x: 40, y: 35), canvasSize: canvasSize)
        #expect(state.pixelBounds(in: canvasSize) == .init(origin: .init(x: 20, y: 14), size: .init(x: 60, y: 41)))

        state.begin(at: .init(x: 80, y: 55), canvasSize: canvasSize, handleRadius: 4)
        state.end(at: .init(x: 92, y: 70), canvasSize: canvasSize)
        #expect(state.pixelBounds(in: canvasSize) == .init(origin: .init(x: 20, y: 14), size: .init(x: 72, y: 56)))
    }

    @Test
    func canvasCropSingleClickSelectsWholeCanvasAndHandlesCanExpandBeyondIt() throws {
        let canvasSize = CanvasSize(width: 100, height: 80)
        var state = CanvasCropInteractionState()

        state.begin(at: .init(x: 42.2, y: 31.8), canvasSize: canvasSize, handleRadius: 3)
        state.end(at: .init(x: 42.2, y: 31.8), canvasSize: canvasSize)
        #expect(state.pixelBounds(in: canvasSize) == .init(
            origin: .init(x: 0, y: 0),
            size: .init(x: 100, y: 80)
        ))

        state.begin(at: .init(x: 0, y: 0), canvasSize: canvasSize, handleRadius: 3)
        state.end(at: .init(x: -20, y: -10), canvasSize: canvasSize)
        #expect(state.pixelBounds(in: canvasSize) == .init(
            origin: .init(x: -20, y: -10),
            size: .init(x: 120, y: 90)
        ))

        state.begin(at: .init(x: 100, y: 80), canvasSize: canvasSize, handleRadius: 3)
        state.end(at: .init(x: 130, y: 110), canvasSize: canvasSize)
        #expect(state.pixelBounds(in: canvasSize) == .init(
            origin: .init(x: -20, y: -10),
            size: .init(x: 150, y: 120)
        ))
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
            x: localPoint.x * viewport.zoomScale * (viewport.isHorizontallyFlipped ? -1 : 1),
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

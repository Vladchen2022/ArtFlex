import Testing
@testable import ArtFlex

struct PerspectiveGuideStateTests {
    @Test
    func initialGuideProvidesThreeEditableVanishingPointsWithoutAnchors() {
        let guide = PerspectiveGuideState.initial(canvasSize: .init(width: 1_000, height: 800))

        #expect(guide.mode == .threePoint)
        #expect(guide.activeVanishingPointRoles == [.left, .right, .vertical])
        #expect(guide.verticalVanishingPoint.y == 80)
        #expect(guide.verticalVanishingPoint.y < guide.leftVanishingPoint.y)
        #expect(guide.anchors.isEmpty)
        #expect(guide.isVisible)
        #expect(!guide.isLocked)
    }

    @Test
    func verticalDirectionKeepsTheThirdPointReachableInsideTheCanvas() {
        var guide = PerspectiveGuideState.initial(canvasSize: .init(width: 1_000, height: 800))

        guide.setVerticalDirection(.below, canvasSize: .init(width: 1_000, height: 800))
        #expect(guide.verticalVanishingPoint == CanvasPoint(x: 500, y: 720))
        #expect(guide.verticalVanishingPoint.y > guide.leftVanishingPoint.y)

        guide.setVerticalDirection(.above, canvasSize: .init(width: 1_000, height: 800))
        #expect(guide.verticalVanishingPoint == CanvasPoint(x: 500, y: 80))
    }

    @Test
    func modeControlsDefaultAnchorConnections() {
        var guide = PerspectiveGuideState.initial(canvasSize: .init(width: 1_000, height: 800))
        guide.setMode(.onePoint, canvasSize: .init(width: 1_000, height: 800))
        let onePointAnchor = guide.makeAnchor(at: .init(x: 500, y: 400))
        #expect(onePointAnchor.connectsLeft)
        #expect(!onePointAnchor.connectsRight)
        #expect(!onePointAnchor.connectsVertical)

        guide.setMode(.twoPoint, canvasSize: .init(width: 1_000, height: 800))
        let twoPointAnchor = guide.makeAnchor(at: .init(x: 500, y: 400))
        #expect(twoPointAnchor.connectsLeft)
        #expect(twoPointAnchor.connectsRight)
        #expect(!twoPointAnchor.connectsVertical)
    }

    @Test
    func hitTestingPrioritizesAnchorsThenVanishingPointsAndHorizon() {
        var guide = PerspectiveGuideState.initial(canvasSize: .init(width: 1_000, height: 800))
        let anchor = guide.makeAnchor(at: .init(x: 500, y: 500))
        guide.anchors = [anchor]

        #expect(
            perspectiveGuideHitTarget(
                state: guide,
                point: .init(x: 504, y: 502),
                hitRadius: 10,
                canvasSize: .init(width: 1_000, height: 800)
            ) == .anchor(anchor.id)
        )
        #expect(
            perspectiveGuideHitTarget(
                state: guide,
                point: guide.leftVanishingPoint,
                hitRadius: 10,
                canvasSize: .init(width: 1_000, height: 800)
            ) == .vanishingPoint(.left)
        )
        let horizonMidpoint = CanvasPoint(
            x: (guide.leftVanishingPoint.x + guide.rightVanishingPoint.x) * 0.5,
            y: guide.leftVanishingPoint.y
        )
        #expect(
            perspectiveGuideHitTarget(
                state: guide,
                point: horizonMidpoint,
                hitRadius: 10,
                canvasSize: .init(width: 1_000, height: 800)
            ) == .horizon
        )
    }

    @Test
    func cropTranslationKeepsGuideAlignedWithCanvasPixels() {
        var guide = PerspectiveGuideState.initial(canvasSize: .init(width: 1_000, height: 800))
        guide.anchors = [guide.makeAnchor(at: .init(x: 420, y: 360))]

        let cropped = guide.cropped(originX: 120, originY: 80)

        #expect(cropped.leftVanishingPoint.x == guide.leftVanishingPoint.x - 120)
        #expect(cropped.leftVanishingPoint.y == guide.leftVanishingPoint.y - 80)
        #expect(cropped.anchors[0].position == CanvasPoint(x: 300, y: 280))
    }
}

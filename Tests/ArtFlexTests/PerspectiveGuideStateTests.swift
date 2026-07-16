import Foundation
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

    @Test
    func tracedImageEdgesRecoverThreeVanishingPointsAndTiltedHorizon() throws {
        let canvasSize = CanvasSize(width: 1_200, height: 800)
        let expected: [PerspectiveGuideMatchRole: CanvasPoint] = [
            .left: CanvasPoint(x: -420, y: 270),
            .right: CanvasPoint(x: 1_760, y: 390),
            .vertical: CanvasPoint(x: 610, y: -980)
        ]
        var state = PerspectiveGuideMatchState()
        let starts: [PerspectiveGuideMatchRole: [CanvasPoint]] = [
            .left: [CanvasPoint(x: 180, y: 420), CanvasPoint(x: 760, y: 610)],
            .right: [CanvasPoint(x: 280, y: 570), CanvasPoint(x: 900, y: 430)],
            .vertical: [CanvasPoint(x: 460, y: 650), CanvasPoint(x: 780, y: 590)]
        ]
        for role in PerspectiveGuideMatchRole.allCases {
            let vanishingPoint = try #require(expected[role])
            for start in try #require(starts[role]) {
                state.lines.append(PerspectiveGuideMatchLine(
                    role: role,
                    start: start,
                    end: CanvasPoint(
                        x: start.x + (vanishingPoint.x - start.x) * 0.18,
                        y: start.y + (vanishingPoint.y - start.y) * 0.18
                    )
                ))
            }
        }

        #expect(state.isComplete)
        for role in PerspectiveGuideMatchRole.allCases {
            let actual = try #require(state.vanishingPoint(for: role))
            let target = try #require(expected[role])
            #expect(hypot(actual.x - target.x, actual.y - target.y) < 0.001)
        }

        var style = PerspectiveGuideState.initial(canvasSize: canvasSize)
        style.opacity = 0.73
        style.lineWidth = 2.4
        let guide = try #require(matchedPerspectiveGuide(
            state: state,
            preserving: style,
            canvasSize: canvasSize
        ))
        #expect(guide.mode == .threePoint)
        #expect(hypot(
            guide.leftVanishingPoint.x - (expected[.left]?.x ?? 0),
            guide.leftVanishingPoint.y - (expected[.left]?.y ?? 0)
        ) < 0.001)
        #expect(hypot(
            guide.rightVanishingPoint.x - (expected[.right]?.x ?? 0),
            guide.rightVanishingPoint.y - (expected[.right]?.y ?? 0)
        ) < 0.001)
        #expect(hypot(
            guide.verticalVanishingPoint.x - (expected[.vertical]?.x ?? 0),
            guide.verticalVanishingPoint.y - (expected[.vertical]?.y ?? 0)
        ) < 0.001)
        #expect(guide.verticalDirection == .above)
        #expect(guide.anchors.count == 6)
        #expect(guide.anchors.filter(\.connectsLeft).count == 2)
        #expect(guide.anchors.filter(\.connectsRight).count == 2)
        #expect(guide.anchors.filter(\.connectsVertical).count == 2)
        #expect(guide.opacity == style.opacity)
        #expect(guide.lineWidth == style.lineWidth)
    }

    @Test
    func perspectiveMatchRejectsParallelTracedEdges() {
        let segments = [
            PerspectiveMatchLineSegment(
                start: CanvasPoint(x: 10, y: 20),
                end: CanvasPoint(x: 210, y: 20)
            ),
            PerspectiveMatchLineSegment(
                start: CanvasPoint(x: 10, y: 80),
                end: CanvasPoint(x: 210, y: 80)
            )
        ]
        #expect(perspectiveMatchVanishingPoint(segments: segments) == nil)
    }
}

import Testing
@testable import ArtFlex

struct StraightLineInteractionStateTests {
    @Test
    func thicknessDeadZoneKeepsAConstantScreenDistanceAcrossZoomLevels() {
        #expect(straightLineThicknessDeadZoneCanvasDistance(actualDisplayScale: 0.5) == 100)
        #expect(straightLineThicknessDeadZoneCanvasDistance(actualDisplayScale: 2) == 25)
    }

    @Test
    func ordinaryDragKeepsEndpointAndBecomesPendingOnRelease() {
        var state = StraightLineInteractionState()
        state.begin(
            at: .init(x: 10, y: 20),
            brushSize: 18,
            paintVariationSeed: 42
        )

        #expect(state.updateDrag(to: .init(x: 90, y: 20)) == nil)
        let didFinish = state.finishDrag(at: .init(x: 90, y: 20))
        #expect(didFinish)
        #expect(state.phase == .pending)
        #expect(state.preview?.pointA == .init(x: 10, y: 20))
        #expect(state.preview?.pointB == .init(x: 90, y: 20))
        #expect(state.preview?.isPending == true)
    }

    @Test
    func perpendicularTurnFreezesEndpointAndAdjustsThickness() {
        var state = StraightLineInteractionState()
        state.begin(
            at: .init(x: 0, y: 0),
            brushSize: 20,
            paintVariationSeed: 7
        )

        _ = state.updateDrag(to: .init(x: 100, y: 0))
        _ = state.updateDrag(to: .init(x: 100, y: 3))
        let sizeInsideDeadZone = state.updateDrag(to: .init(x: 100, y: 49))

        #expect(sizeInsideDeadZone == nil)
        #expect(state.phase == .drawingLine)
        #expect(state.pointB == .init(x: 100, y: 0))

        let adjustedSize = state.updateDrag(to: .init(x: 100, y: 70))

        #expect(state.phase == .adjustingThickness)
        #expect(state.pointB == .init(x: 100, y: 0))
        #expect(adjustedSize == 40)
        #expect(state.thicknessHandlePoint == .init(x: 100, y: 70))
        let didFinish = state.finishDrag(at: .init(x: 100, y: 70))
        #expect(didFinish)
        #expect(state.phase == .pending)
    }

    @Test
    func shortPerpendicularTailKeepsOriginalEndpointAndDoesNotAdjustThickness() {
        var state = StraightLineInteractionState()
        state.begin(
            at: .init(x: 0, y: 0),
            brushSize: 20,
            paintVariationSeed: 9
        )

        _ = state.updateDrag(to: .init(x: 100, y: 0))
        _ = state.updateDrag(to: .init(x: 100, y: 2))
        #expect(state.updateDrag(to: .init(x: 102, y: 2)) == nil)
        #expect(state.phase == .drawingLine)
        let didFinish = state.finishDrag(at: .init(x: 102, y: 2))
        #expect(didFinish)
        #expect(state.pointB == .init(x: 100, y: 0))
    }

    @Test
    func thicknessAdjustmentClampsToSupportedBrushRange() {
        var state = StraightLineInteractionState()
        state.begin(
            at: .init(x: 0, y: 0),
            brushSize: 4,
            paintVariationSeed: 11
        )

        _ = state.updateDrag(to: .init(x: 100, y: 0))
        _ = state.updateDrag(to: .init(x: 100, y: -3))
        let adjustedSize = state.updateDrag(to: .init(x: 100, y: -90))

        #expect(state.phase == .adjustingThickness)
        #expect(adjustedSize == 1)
    }
}

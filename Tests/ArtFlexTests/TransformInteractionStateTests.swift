import Testing
@testable import ArtFlex

struct TransformInteractionStateTests {
    @Test
    func transformSessionAccumulatesOffsetsAcrossMultipleDrags() {
        var state = TransformInteractionState()

        state.beginSession(at: .init(x: 10, y: 10))
        let firstDelta = state.finishDrag(at: .init(x: 18.2, y: 15.8))
        #expect(firstDelta == .init(x: 8, y: 6))
        #expect(state.accumulatedOffset == .init(x: 8, y: 6))

        state.beginDrag(at: .init(x: 18, y: 16))
        let secondDelta = state.finishDrag(at: .init(x: 14.4, y: 26.2))
        #expect(secondDelta == .init(x: -4, y: 10))
        #expect(state.accumulatedOffset == .init(x: 4, y: 16))
    }

    @Test
    func clearBehaviorAppliesOnlyWhenTransformHasPendingOffset() {
        var state = TransformInteractionState()

        #expect(state.clearBehavior() == .none)

        state.beginSession(at: .init(x: 0, y: 0))
        #expect(state.clearBehavior() == .cancel)

        _ = state.finishDrag(at: .init(x: 12, y: 0))
        #expect(state.clearBehavior() == .apply)
    }

    @Test
    func clearBehaviorCancelsActiveTransformWithoutOffset() {
        var state = TransformInteractionState()

        state.beginSession(at: .init(x: 5, y: 5))

        #expect(state.hasPendingOffset == false)
        #expect(state.clearBehavior() == .cancel)
    }

    @Test
    func resetClearsSessionState() {
        var state = TransformInteractionState()

        state.beginSession(at: .init(x: 4, y: 5))
        _ = state.finishDrag(at: .init(x: 9, y: 11))
        state.reset()

        #expect(state.isActive == false)
        #expect(state.dragStartPoint == nil)
        #expect(state.accumulatedOffset == .init(x: 0, y: 0))
        #expect(state.clearBehavior() == .none)
    }

    @Test
    func toolAndLayerChangesApplyOnlyWhenTransformHasPendingOffset() {
        var state = TransformInteractionState()

        #expect(state.resolutionAction(for: .toolChange) == .none)
        #expect(state.resolutionAction(for: .layerChange) == .none)

        state.beginSession(at: .init(x: 0, y: 0))
        #expect(state.resolutionAction(for: .toolChange) == .cancelAndClearSelection)
        #expect(state.resolutionAction(for: .layerChange) == .cancelAndClearSelection)

        _ = state.finishDrag(at: .init(x: 12, y: 4))
        #expect(state.resolutionAction(for: .toolChange) == .applyAndClearSelection)
        #expect(state.resolutionAction(for: .layerChange) == .applyAndClearSelection)
    }

    @Test
    func historyNavigationCancelsTransformButPreservesSelection() {
        var state = TransformInteractionState()
        state.beginSession(at: .init(x: 5, y: 5))

        #expect(state.resolutionAction(for: .historyNavigation) == .cancelAndPreserveSelection)

        _ = state.finishDrag(at: .init(x: 11, y: 12))
        #expect(state.resolutionAction(for: .historyNavigation) == .cancelAndPreserveSelection)
    }

    @Test
    func documentOpenCancelsTransformAndClearsSelection() {
        var state = TransformInteractionState()
        state.beginSession(at: .init(x: 3, y: 9))

        #expect(state.resolutionAction(for: .documentOpen) == .cancelAndClearSelection)

        _ = state.finishDrag(at: .init(x: 9, y: 12))
        #expect(state.resolutionAction(for: .documentOpen) == .cancelAndClearSelection)
    }

    @Test
    func scaleOnlyTransformStillRequiresApply() {
        var state = TransformInteractionState()
        state.beginSession(at: .init(x: 0, y: 0))
        state.preview = FreeTransformPreview(
            translation: .init(x: 0, y: 0),
            scaleX: 1.2,
            scaleY: 1,
            rotationRadians: 0
        )

        #expect(state.clearBehavior() == .apply)
        #expect(state.resolutionAction(for: .toolChange) == .applyAndClearSelection)
    }
}

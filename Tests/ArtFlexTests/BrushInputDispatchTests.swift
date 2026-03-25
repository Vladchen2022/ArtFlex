import AppKit
import Testing
@testable import ArtFlex

struct BrushInputDispatchTests {
    @Test
    func cursorIndicatorActionsDisableImplicitUpdates() {
        let actions = makeCursorIndicatorDisabledActions()

        #expect(actions["path"] != nil)
        #expect(actions["position"] != nil)
        #expect(actions["bounds"] != nil)
        #expect(actions["hidden"] != nil)
        #expect(actions["transform"] != nil)
        #expect(actions["opacity"] != nil)
    }

    @Test
    func latestBrushHoverLocationUsesNewestBatchEvent() {
        let original = CGPoint(x: 10, y: 12)
        let latest = latestBrushHoverLocation(
            originalLocation: original,
            batchedLocations: [
                CGPoint(x: 14, y: 18),
                CGPoint(x: 21, y: 34)
            ]
        )

        #expect(latest == CGPoint(x: 21, y: 34))
        #expect(latestBrushHoverLocation(originalLocation: original, batchedLocations: []) == original)
    }

    @Test
    func brushLikeToolsPreferCrosshairAndHideOutlineDuringActiveStroke() {
        #expect(
            preferredBrushCursorMode(
                activeTool: .brush,
                isEyedropperCursorActive: false,
                hasHoverLocation: true
            ) == .crosshair
        )

        #expect(
            shouldShowBrushOutlineIndicator(
                activeTool: .brush,
                hasHoverLocation: true,
                isAdjustingBrushSizePreview: false,
                isBrushOutlineForcedVisible: false,
                suppressesBrushOutline: false,
                isBrushStrokeActive: true,
                showsBrushOutlineDuringStroke: false,
                hasContinuousStrokeGrace: false
            ) == false
        )

        #expect(
            shouldShowBrushTipIndicator(
                activeTool: .brush,
                hasHoverLocation: true
            ) == true
        )
    }

    @Test
    func pendingBrushInputQueueFlushesAndClears() {
        var queue = PendingBrushInputQueue()
        let sample = CanvasStrokeSample(location: .init(x: 5, y: 7), pressure: 1)

        queue.enqueue(.begin, at: 1)
        queue.enqueue(.samples([sample]), at: 2)
        queue.enqueue(.end, at: 3)

        let flushed = queue.flush()

        #expect(flushed.count == 3)
        #expect(flushed.map(\.kind) == [.begin, .samples([sample]), .end])
        #expect(queue.isEmpty)
    }

    @Test
    func localBrushSizePreviewIsNotStompedUntilModelCatchesUpOrTimeout() {
        let keepLocal = resolveBrushSizePreview(
            displayBrushSize: 40,
            modelBrushSize: 24,
            isAdjustingBrushSizePreview: true,
            previewExpiresAtNs: 1_000,
            nowUptimeNs: 500
        )

        #expect(keepLocal.displayBrushSize == 40)
        #expect(keepLocal.isAdjustingBrushSizePreview)
        #expect(keepLocal.state == .local)

        let synced = resolveBrushSizePreview(
            displayBrushSize: 40,
            modelBrushSize: 40,
            isAdjustingBrushSizePreview: true,
            previewExpiresAtNs: 1_000,
            nowUptimeNs: 600
        )

        #expect(synced.displayBrushSize == 40)
        #expect(synced.isAdjustingBrushSizePreview == false)
        #expect(synced.state == .synced)
    }
}

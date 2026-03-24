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
}

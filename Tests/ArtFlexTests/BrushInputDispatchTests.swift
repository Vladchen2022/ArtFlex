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
    func colorAdjustmentToolAlsoUsesBrushCursorAndTipIndicator() {
        #expect(
            preferredBrushCursorMode(
                activeTool: .brightnessAdjust,
                isEyedropperCursorActive: false,
                hasHoverLocation: true
            ) == .crosshair
        )

        #expect(
            shouldShowBrushOutlineIndicator(
                activeTool: .brightnessAdjust,
                hasHoverLocation: true,
                isAdjustingBrushSizePreview: false,
                isBrushOutlineForcedVisible: false,
                suppressesBrushOutline: false,
                isBrushStrokeActive: false,
                showsBrushOutlineDuringStroke: true,
                hasContinuousStrokeGrace: false
            ) == true
        )

        #expect(
            shouldShowBrushTipIndicator(
                activeTool: .brightnessAdjust,
                hasHoverLocation: true
            ) == true
        )
    }

    @Test
    func colorAdjustmentToolPrioritizesLocalEBKeysBeforeToolShortcuts() {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "e",
            charactersIgnoringModifiers: "e",
            isARepeat: false,
            keyCode: 14
        )

        let shouldPrioritize = shouldPrioritizeCanvasKeyHandlerBeforeToolShortcut(
            activeTool: .brightnessAdjust,
            event: try! #require(event),
            modifiers: []
        )

        #expect(shouldPrioritize == true)
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
    func brushLikeSampleMappingAllowsOverflowWhileBoundedToolsStillClamp() {
        let viewBounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        let canvasSize = CanvasSize(width: 1000, height: 500)
        let outsideRight = CGPoint(x: 240, y: 40)

        let brushLikeMapping = mapViewLocationToCanvasSample(
            viewLocation: outsideRight,
            viewBounds: viewBounds,
            canvasSize: canvasSize,
            clampsToDocumentBounds: false
        )

        #expect(brushLikeMapping.normalizedX == 1.2)
        #expect(brushLikeMapping.canvasPoint.x == 1200)
        #expect(brushLikeMapping.canvasPoint.y == 300)

        let boundedMapping = mapViewLocationToCanvasSample(
            viewLocation: outsideRight,
            viewBounds: viewBounds,
            canvasSize: canvasSize,
            clampsToDocumentBounds: true
        )

        #expect(boundedMapping.normalizedX == 1)
        #expect(boundedMapping.canvasPoint.x == 1000)
        #expect(boundedMapping.canvasPoint.y == 300)
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

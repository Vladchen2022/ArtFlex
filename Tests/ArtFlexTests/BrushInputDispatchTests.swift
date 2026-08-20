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

        #expect(
            preferredBrushCursorMode(
                activeTool: .colorVitalization,
                isEyedropperCursorActive: false,
                hasHoverLocation: true
            ) == .crosshair
        )
        #expect(
            shouldShowBrushTipIndicator(
                activeTool: .colorVitalization,
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
    func colorVitalizationDoesNotConsumeBrushShortcutLocally() {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "b",
            charactersIgnoringModifiers: "b",
            isARepeat: false,
            keyCode: 11
        )

        let shouldPrioritize = shouldPrioritizeCanvasKeyHandlerBeforeToolShortcut(
            activeTool: .colorVitalization,
            event: try! #require(event),
            modifiers: []
        )

        #expect(shouldPrioritize == false)
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
    func pendingBrushInputQueueCoalescesAdjacentSamplePacketsWithinAFrame() {
        var queue = PendingBrushInputQueue()
        let first = CanvasStrokeSample(location: .init(x: 5, y: 7), pressure: 0.25)
        let second = CanvasStrokeSample(location: .init(x: 9, y: 11), pressure: 0.75)

        queue.enqueue(.begin, at: 1)
        queue.enqueue(.samples([first]), at: 2)
        queue.enqueue(.samples([second]), at: 3)
        queue.enqueue(.end, at: 4)

        let flushed = queue.flush()

        #expect(flushed.count == 3)
        #expect(flushed.map(\.kind) == [.begin, .samples([first, second]), .end])
        #expect(flushed.map(\.enqueuedAt) == [1, 2, 4])
        #expect(queue.isEmpty)
    }

    @Test
    func highFrequencyBrushInputBecomesOneOrderedRenderPacketPerFrame() {
        var queue = PendingBrushInputQueue()
        queue.enqueue(.begin, at: 1)
        for index in 0..<256 {
            queue.enqueue(
                .samples([
                    CanvasStrokeSample(
                        location: .init(x: Double(index), y: 32),
                        pressure: Float(index % 100) / 100
                    )
                ]),
                at: UInt64(index + 2)
            )
        }
        queue.enqueue(.end, at: 258)

        let flushed = queue.flush()
        let sampleBatches = flushed.compactMap { batch -> [CanvasStrokeSample]? in
            guard case .samples(let samples) = batch.kind else { return nil }
            return samples
        }

        #expect(flushed.count == 3)
        #expect(sampleBatches.count == 1)
        #expect(sampleBatches[0].count == 256)
        #expect(sampleBatches[0].map(\.location.x) == (0..<256).map(Double.init))
        #expect(flushed.map(\.enqueuedAt) == [1, 2, 258])
    }

    @Test
    func pendingBrushInputQueueDoesNotMergeAcrossStrokeBoundaries() {
        var queue = PendingBrushInputQueue()
        let first = CanvasStrokeSample(location: .init(x: 5, y: 7), pressure: 0.25)
        let second = CanvasStrokeSample(location: .init(x: 9, y: 11), pressure: 0.75)

        queue.enqueue(.begin, at: 1)
        queue.enqueue(.samples([first]), at: 2)
        queue.enqueue(.end, at: 3)
        queue.enqueue(.begin, at: 4)
        queue.enqueue(.samples([second]), at: 5)
        queue.enqueue(.end, at: 6)

        let flushed = queue.flush()

        #expect(flushed.map(\.kind) == [
            .begin,
            .samples([first]),
            .end,
            .begin,
            .samples([second]),
            .end,
        ])
    }

    @Test
    @MainActor
    func brushInputUsesDemandDrivenMetalViewScheduling() {
        let view = StrokeCaptureMTKView(
            frame: .init(x: 0, y: 0, width: 120, height: 120),
            device: nil
        )
        view.enableSetNeedsDisplay = false
        view.isPaused = false

        view.beginDemandDrivenStrokeRendering()

        #expect(view.enableSetNeedsDisplay)
        #expect(view.isPaused)
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

    @Test
    func selectionFeatherContextMenuRequiresARightClickInsideTheSelection() {
        let selection = SelectionShape(
            kind: .rectangle,
            bounds: CanvasRect(
                origin: .init(x: 10, y: 12),
                size: .init(x: 30, y: 24)
            ),
            pathPoints: []
        )

        #expect(shouldOfferSelectionFeatherContextMenu(
            selectionShape: selection,
            at: .init(x: 20, y: 20)
        ))
        #expect(!shouldOfferSelectionFeatherContextMenu(
            selectionShape: selection,
            at: .init(x: 4, y: 20)
        ))
        #expect(!shouldOfferSelectionFeatherContextMenu(
            selectionShape: nil,
            at: .init(x: 20, y: 20)
        ))
        #expect(shouldOfferSelectionRefinementContextMenu(
            selectionShape: selection,
            at: .init(x: 20, y: 20)
        ))
    }
}

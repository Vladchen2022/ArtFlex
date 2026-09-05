import AppKit
import Metal
import Testing
@testable import ArtFlex

struct WorkspaceViewModelPixelHistoryTests {
    @Test
    @MainActor
    func adjustmentCommitPreservesPixelsAndSessionWhenUndoCaptureFails() throws {
        for usesCurve in [false, true] {
            let harness = try PixelHistoryHarness(canvasSize: .init(width: 64, height: 64))
            let layerID = harness.viewModel.workspace.document.activeLayerID
            try fillOpaqueRect(in: harness, layerID: layerID,
                originX: 12, originY: 12, width: 28, height: 28,
                color: .init(red: 0.4, green: 0.4, blue: 0.4, alpha: 1))
            let before = try harness.snapshot(layerID: layerID)
            if usesCurve {
                #expect(harness.viewModel.beginCurveAdjustmentFromWholeLayerIfNeeded(showFeedback: false))
                harness.viewModel.updateCurveAdjustmentChannelPoints([
                    .init(x: 0, y: 0), .init(x: 0.5, y: 0.25), .init(x: 1, y: 1)
                ], channel: .rgb)
            } else {
                harness.viewModel.setColorAdjustmentBrightness(0.55)
            }
            harness.bootstrap.historyController.debugPreventsCheckpointCapture = true
            let succeeded = usesCurve
                ? harness.viewModel.confirmCurveAdjustmentIfNeeded(showFeedback: false)
                : harness.viewModel.confirmColorAdjustmentSession()
            #expect(!succeeded)
            #expect(try harness.snapshot(layerID: layerID) == before)
            #expect(!harness.bootstrap.historyController.canUndo)
            #expect(usesCurve ? harness.viewModel.curveAdjustmentSession != nil
                             : harness.viewModel.colorAdjustmentSession != nil)
            harness.bootstrap.historyController.debugPreventsCheckpointCapture = false
            #expect(usesCurve ? harness.viewModel.confirmCurveAdjustmentIfNeeded(showFeedback: false)
                             : harness.viewModel.confirmColorAdjustmentSession())
            harness.viewModel.undo()
            #expect(try harness.snapshot(layerID: layerID) == before)
        }
    }

    @Test
    @MainActor
    func horizontalCanvasFlipChangesOnlyViewportAndLeavesLayerPixelsUntouched() throws {
        let harness = try PixelHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let activeLayerID = harness.viewModel.workspace.document.activeLayerID
        try fillOpaqueRect(
            in: harness,
            layerID: activeLayerID,
            originX: 8,
            originY: 12,
            width: 20,
            height: 16,
            color: .init(red: 0.2, green: 0.45, blue: 0.8, alpha: 1)
        )
        let before = try harness.snapshot(layerID: activeLayerID)

        harness.viewModel.toggleCanvasHorizontalFlip()

        #expect(harness.viewModel.workspace.viewport.isHorizontallyFlipped)
        #expect(try harness.snapshot(layerID: activeLayerID) == before)
        #expect(!harness.viewModel.canUndo)

        harness.viewModel.toggleCanvasHorizontalFlip()

        #expect(!harness.viewModel.workspace.viewport.isHorizontallyFlipped)
        #expect(try harness.snapshot(layerID: activeLayerID) == before)
    }

    @Test
    @MainActor
    func deletingLayerWithPendingTransformCancelsPreviewWithoutMovingBackground() throws {
        let harness = try PixelHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let backgroundLayerID = try #require(harness.viewModel.workspace.document.layers.first?.id)
        let drawingLayerID = harness.viewModel.workspace.document.activeLayerID
        let backgroundBefore = try harness.snapshot(layerID: backgroundLayerID)

        harness.makeRectangleSelection(minX: -12, minY: 8, maxX: 24, maxY: 32)
        harness.viewModel.fillSelectionContents()
        #expect(try harness.alpha(atX: 12, y: 16, layerID: drawingLayerID) > 0.95)

        harness.viewModel.selectTool(.freeTransform)
        let start = CanvasPoint(x: 12, y: 16)
        let end = CanvasPoint(x: 24, y: 16)
        harness.viewModel.beginSelectionTransform(at: start, mode: .move)
        harness.viewModel.updateSelectionTransform(to: end)
        harness.viewModel.commitSelectionTransform(at: end)

        #expect(harness.viewModel.isTransformingSelection)
        #expect(!harness.viewModel.freeTransformPreview.isIdentity)

        harness.viewModel.removeActiveLayer()

        #expect(harness.viewModel.workspace.document.layers.count == 1)
        #expect(harness.viewModel.workspace.document.activeLayerID == backgroundLayerID)
        #expect(!harness.viewModel.isTransformingSelection)
        #expect(harness.viewModel.freeTransformPreview.isIdentity)
        #expect(harness.viewModel.workspace.selection.committedShape == nil)
        #expect(harness.bootstrap.layerSurfaceStore.surfaceID(for: drawingLayerID) == nil)
        #expect(try harness.snapshot(layerID: backgroundLayerID) == backgroundBefore)
    }

    @Test
    @MainActor
    func deletingLayerIsBlockedWhileTransformCommitIsApplying() async throws {
        let harness = try PixelHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let drawingLayerID = harness.viewModel.workspace.document.activeLayerID
        try fillOpaqueRect(
            in: harness,
            layerID: drawingLayerID,
            originX: 12,
            originY: 12,
            width: 24,
            height: 24,
            color: .init(red: 0, green: 0, blue: 0, alpha: 1)
        )

        harness.makeRectangleSelection(minX: 8, minY: 8, maxX: 40, maxY: 40)
        harness.viewModel.selectTool(.freeTransform)
        let start = CanvasPoint(x: 20, y: 20)
        let end = CanvasPoint(x: 28, y: 20)
        harness.viewModel.beginSelectionTransform(at: start, mode: .move)
        harness.viewModel.updateSelectionTransform(to: end)
        harness.viewModel.commitSelectionTransform(at: end)
        harness.viewModel.applySelectionTransform()
        #expect(harness.viewModel.isApplyingTransformCommit)

        let layerCountBeforeDelete = harness.viewModel.workspace.document.layers.count
        harness.viewModel.removeActiveLayer()

        #expect(harness.viewModel.workspace.document.layers.count == layerCountBeforeDelete)
        #expect(harness.viewModel.workspace.document.activeLayerID == drawingLayerID)
        try await harness.waitForTransformCommitToFinish()
    }

    @Test
    @MainActor
    func applyingWholeLayerFreeTransformReprimesIdleStateWithoutReselectingTool() async throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.addLayer()

        try harness.drawBrushStroke(
            on: layerID,
            points: [
                .init(location: .init(x: 10, y: 10), pressure: 1),
                .init(location: .init(x: 18, y: 18), pressure: 1)
            ]
        )

        harness.viewModel.selectTool(.freeTransform)
        let initialBounds = try #require(harness.viewModel.sceneSnapshot.selectionShape?.bounds)
        let start = CanvasPoint(
            x: initialBounds.origin.x + initialBounds.size.x / 2,
            y: initialBounds.origin.y + initialBounds.size.y / 2
        )
        let end = CanvasPoint(x: start.x + 10, y: start.y + 6)

        harness.viewModel.beginSelectionTransform(at: start, mode: .move)
        harness.viewModel.updateSelectionTransform(to: end)
        harness.viewModel.commitSelectionTransform(at: end)
        harness.viewModel.applySelectionTransform()

        var movedBounds: CanvasRect?
        for _ in 0..<50 {
            if let bounds = harness.viewModel.sceneSnapshot.selectionShape?.bounds,
               bounds.origin.x > initialBounds.origin.x + 4,
               bounds.origin.y > initialBounds.origin.y + 2 {
                movedBounds = bounds
                break
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }

        let rebound = try #require(movedBounds)
        #expect(rebound.origin.x > initialBounds.origin.x + 4)
        #expect(rebound.origin.y > initialBounds.origin.y + 2)

        let secondStart = CanvasPoint(
            x: rebound.origin.x + rebound.size.x / 2,
            y: rebound.origin.y + rebound.size.y / 2
        )
        harness.viewModel.beginSelectionTransform(at: secondStart, mode: .move)

        let secondInteractionBounds = try #require(harness.viewModel.sceneSnapshot.selectionShape?.bounds)
        #expect(abs(secondInteractionBounds.origin.x - rebound.origin.x) < 0.5)
        #expect(abs(secondInteractionBounds.origin.y - rebound.origin.y) < 0.5)
    }

    @Test
    @MainActor
    func freeTransformWholeLayerImmediatelyUsesContentBoundsInsteadOfFullCanvas() throws {
        let harness = try PixelHistoryHarness(canvasSize: .init(width: 128, height: 128))
        let layerID = harness.addLayer()
        harness.viewModel.setBrushSize(8)

        try harness.drawBrushStroke(
            on: layerID,
            points: [
                .init(location: .init(x: 32, y: 32), pressure: 1),
                .init(location: .init(x: 40, y: 40), pressure: 1)
            ]
        )

        harness.viewModel.selectTool(.freeTransform)

        let bounds = try #require(harness.viewModel.sceneSnapshot.selectionShape?.bounds)
        #expect(bounds.size.x < Double(harness.viewModel.workspace.document.canvasSize.width))
        #expect(bounds.size.y < Double(harness.viewModel.workspace.document.canvasSize.height))
        #expect(bounds.size.x > 0)
        #expect(bounds.size.y > 0)
    }

    @Test
    @MainActor
    func meshWarpMovesAnAnchorCommitsPixelsAndSupportsUndo() async throws {
        let harness = try PixelHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let layerID = harness.addLayer()
        try fillOpaqueRect(
            in: harness,
            layerID: layerID,
            originX: 16,
            originY: 16,
            width: 32,
            height: 32,
            color: .init(red: 0.8, green: 0.2, blue: 0.1, alpha: 1)
        )

        harness.viewModel.selectTool(.freeTransform)
        harness.viewModel.setFreeTransformToolMode(.mesh)
        let grid = try #require(harness.viewModel.displayedMeshWarpGrid)
        let topLeft = try #require(grid.point(row: 0, column: 0))
        let movedTopLeft = CanvasPoint(x: topLeft.x - 8, y: topLeft.y - 8)

        harness.viewModel.beginSelectionTransform(at: topLeft, mode: .meshPoint(0))
        harness.viewModel.updateSelectionTransform(to: movedTopLeft)
        harness.viewModel.commitSelectionTransform(at: movedTopLeft)
        harness.viewModel.applySelectionTransform()
        try await harness.waitForTransformCommitToFinish()

        #expect(try harness.alpha(atX: 10, y: 10, layerID: layerID) > 0.1)
        harness.viewModel.undo()
        #expect(try harness.alpha(atX: 10, y: 10, layerID: layerID) < 0.01)
        #expect(try harness.alpha(atX: 24, y: 24, layerID: layerID) > 0.95)
    }

    @Test
    @MainActor
    func meshWarpDraggingInsideGridLocallyMovesTheGrabbedPixels() throws {
        let harness = try PixelHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let layerID = harness.addLayer()
        try fillOpaqueRect(
            in: harness,
            layerID: layerID,
            originX: 16,
            originY: 16,
            width: 32,
            height: 32,
            color: .init(red: 0.3, green: 0.7, blue: 0.4, alpha: 1)
        )

        harness.viewModel.selectTool(.freeTransform)
        harness.viewModel.setFreeTransformToolMode(.mesh)
        let initialGrid = try #require(harness.viewModel.displayedMeshWarpGrid)
        let parameter = MeshWarpParameter(u: 0.5, v: 0.5)
        let startPoint = try #require(initialGrid.surfacePoint(at: parameter))
        let interactionMode = meshWarpInteractionMode(
            point: startPoint,
            grid: initialGrid,
            handleRadius: 2
        )
        guard case .meshArea = interactionMode else {
            Issue.record("格内拖动必须进入局部曲面变形模式")
            return
        }

        let delta = CanvasPoint(x: 7, y: -5)
        let endPoint = CanvasPoint(x: startPoint.x + delta.x, y: startPoint.y + delta.y)
        harness.viewModel.beginSelectionTransform(at: startPoint, mode: interactionMode)
        harness.viewModel.updateSelectionTransform(to: endPoint)

        let movedGrid = try #require(harness.viewModel.displayedMeshWarpGrid)
        let movedSurfacePoint = try #require(movedGrid.surfacePoint(at: parameter))
        #expect(abs(movedSurfacePoint.x - endPoint.x) < 0.0001)
        #expect(abs(movedSurfacePoint.y - endPoint.y) < 0.0001)

        let originalCorner = initialGrid.controlPoints[0]
        let movedCorner = movedGrid.controlPoints[0]
        #expect(abs((movedCorner.x - originalCorner.x) - delta.x) > 0.1)
        #expect(abs((movedCorner.y - originalCorner.y) - delta.y) > 0.1)

        harness.viewModel.commitSelectionTransform(at: endPoint)
    }

    @Test
    @MainActor
    func meshWarpShiftSelectsAndDragsMultipleAnchors() throws {
        let harness = try PixelHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let layerID = harness.addLayer()
        try fillOpaqueRect(
            in: harness,
            layerID: layerID,
            originX: 16,
            originY: 16,
            width: 32,
            height: 32,
            color: .init(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)
        )

        harness.viewModel.selectTool(.freeTransform)
        harness.viewModel.setFreeTransformToolMode(.mesh)
        let initialGrid = try #require(harness.viewModel.displayedMeshWarpGrid)
        let firstPoint = initialGrid.controlPoints[0]
        let secondPoint = initialGrid.controlPoints[5]

        harness.viewModel.beginSelectionTransform(at: firstPoint, mode: .meshPoint(0))
        harness.viewModel.commitSelectionTransform(at: firstPoint)
        harness.viewModel.beginSelectionTransform(
            at: secondPoint,
            mode: .meshPoint(5),
            modifiers: [.shift]
        )
        harness.viewModel.commitSelectionTransform(at: secondPoint)
        #expect(harness.viewModel.selectedMeshWarpControlPointIndices == Set([0, 5]))

        let delta = CanvasPoint(x: 6, y: -3)
        harness.viewModel.beginSelectionTransform(at: firstPoint, mode: .meshPoint(0))
        harness.viewModel.updateSelectionTransform(
            to: .init(x: firstPoint.x + delta.x, y: firstPoint.y + delta.y)
        )
        harness.viewModel.commitSelectionTransform(
            at: .init(x: firstPoint.x + delta.x, y: firstPoint.y + delta.y)
        )

        let movedGrid = try #require(harness.viewModel.displayedMeshWarpGrid)
        #expect(movedGrid.controlPoints[0] == .init(
            x: initialGrid.controlPoints[0].x + delta.x,
            y: initialGrid.controlPoints[0].y + delta.y
        ))
        #expect(movedGrid.controlPoints[5] == .init(
            x: initialGrid.controlPoints[5].x + delta.x,
            y: initialGrid.controlPoints[5].y + delta.y
        ))
        #expect(movedGrid.controlPoints[1] == initialGrid.controlPoints[1])

        harness.viewModel.beginSelectionTransform(
            at: movedGrid.controlPoints[5],
            mode: .meshPoint(5),
            modifiers: [.shift]
        )
        harness.viewModel.commitSelectionTransform(at: movedGrid.controlPoints[5])
        #expect(harness.viewModel.selectedMeshWarpControlPointIndices == Set([0]))
    }

    @Test
    @MainActor
    func linearGradientApplySupportsUndoRedoAndSelectionClipping() async throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.addLayer()

        harness.makeLassoSelection([
            .init(x: 8, y: 8),
            .init(x: 40, y: 8),
            .init(x: 40, y: 40),
            .init(x: 8, y: 40),
            .init(x: 8, y: 8)
        ])

        let outsideSelection = try harness.color(atX: 48, y: 20, layerID: layerID)
        harness.viewModel.selectLayer(layerID)
        harness.viewModel.selectTool(.linearGradient)
        harness.viewModel.beginGradientDrag(at: .init(x: 12, y: 20))
        harness.viewModel.updateGradientDrag(to: .init(x: 24, y: 20))
        harness.viewModel.endGradientDrag(at: .init(x: 24, y: 20))
        #expect(harness.viewModel.linearGradientState.phase == .editing)
        harness.viewModel.applyActiveGradientSession()
        try await harness.waitForGradientCommitToFinish()

        #expect(harness.viewModel.isApplyingGradientCommit == false)
        #expect(harness.viewModel.linearGradientState.phase == .idle)

        #expect(try harness.alpha(atX: 10, y: 20, layerID: layerID) > 0.7)
        #expect(try harness.alpha(atX: 32, y: 20, layerID: layerID) < 0.05)
        #expect(try harness.color(atX: 48, y: 20, layerID: layerID) == outsideSelection)

        harness.viewModel.undo()
        #expect(try harness.alpha(atX: 10, y: 20, layerID: layerID) < 0.05)
        harness.viewModel.redo()
        #expect(try harness.alpha(atX: 10, y: 20, layerID: layerID) > 0.7)
    }

    @Test
    @MainActor
    func linearGradientRetainsEditorUntilExplicitApply() async throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.addLayer()

        harness.viewModel.selectLayer(layerID)
        harness.viewModel.selectTool(.linearGradient)
        harness.viewModel.beginGradientDrag(at: .init(x: 10, y: 16))
        harness.viewModel.updateGradientDrag(to: .init(x: 30, y: 16))
        harness.viewModel.endGradientDrag(at: .init(x: 30, y: 16))

        #expect(harness.viewModel.isApplyingGradientCommit == false)
        #expect(harness.viewModel.linearGradientState.phase == .editing)
        #expect(try harness.alpha(atX: 10, y: 16, layerID: layerID) < 0.05)

        harness.viewModel.applyActiveGradientSession()
        try await harness.waitForGradientCommitToFinish()

        #expect(harness.viewModel.isApplyingGradientCommit == false)
        #expect(harness.viewModel.linearGradientState.phase == .idle)
        #expect(harness.viewModel.workspace.toolSession.activeTool == .linearGradient)
        #expect(try harness.alpha(atX: 10, y: 16, layerID: layerID) > 0.7)
        #expect(try harness.alpha(atX: 36, y: 16, layerID: layerID) < 0.05)
    }

    @Test
    @MainActor
    func linearGradientToolSwitchCommitsRetainedEditorBeforeSwitching() async throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.addLayer()

        harness.viewModel.selectLayer(layerID)
        harness.viewModel.selectTool(.linearGradient)
        harness.viewModel.beginGradientDrag(at: .init(x: 10, y: 16))
        harness.viewModel.updateGradientDrag(to: .init(x: 30, y: 16))
        harness.viewModel.endGradientDrag(at: .init(x: 30, y: 16))
        #expect(harness.viewModel.linearGradientState.phase == .editing)

        harness.viewModel.selectTool(.brush)
        try await harness.waitForGradientCommitToFinish()

        #expect(harness.viewModel.workspace.toolSession.activeTool == .brush)
        #expect(harness.viewModel.linearGradientState.phase == .idle)
        #expect(try harness.alpha(atX: 10, y: 16, layerID: layerID) > 0.7)
    }

    @Test
    @MainActor
    func linearGradientRespectsBrushOpacity() async throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.addLayer()

        harness.viewModel.setBrushOpacity(0.24)
        harness.viewModel.selectLayer(layerID)
        harness.viewModel.selectTool(.linearGradient)
        harness.viewModel.beginGradientDrag(at: .init(x: 10, y: 16))
        harness.viewModel.updateGradientDrag(to: .init(x: 30, y: 16))
        harness.viewModel.endGradientDrag(at: .init(x: 30, y: 16))
        harness.viewModel.applyActiveGradientSession()
        try await harness.waitForGradientCommitToFinish()

        let nearAlpha = try harness.alpha(atX: 10, y: 16, layerID: layerID)
        #expect(nearAlpha > 0.18)
        #expect(nearAlpha < 0.30)
    }

    @Test
    @MainActor
    func linearGradientMidpointHandleChangesTransitionBalance() async throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.addLayer()

        harness.viewModel.selectLayer(layerID)
        harness.viewModel.selectTool(.linearGradient)
        harness.viewModel.beginGradientDrag(at: .init(x: 10, y: 16))
        harness.viewModel.updateGradientDrag(to: .init(x: 50, y: 16))
        harness.viewModel.endGradientDrag(at: .init(x: 50, y: 16))

        harness.viewModel.beginGradientDrag(at: .init(x: 30, y: 16))
        harness.viewModel.updateGradientDrag(to: .init(x: 20, y: 16))
        harness.viewModel.endGradientDrag(at: .init(x: 20, y: 16))
        #expect(abs(harness.viewModel.linearGradientState.transitionMidpoint - 0.25) < 0.0001)

        harness.viewModel.applyActiveGradientSession()
        try await harness.waitForGradientCommitToFinish()

        let midpointAlpha = try harness.alpha(atX: 20, y: 16, layerID: layerID)
        #expect(midpointAlpha > 0.40)
        #expect(midpointAlpha < 0.60)
    }

    @Test
    @MainActor
    func linearGradientApplyClearsRetainedBrushDisplayTexture() async throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.addLayer()

        try harness.drawBrushStroke(
            on: layerID,
            points: [
                .init(location: .init(x: 8, y: 8), pressure: 1),
                .init(location: .init(x: 20, y: 20), pressure: 1)
            ]
        )
        #expect(harness.bootstrap.strokeEngine.displayTexture(for: layerID) != nil)

        harness.viewModel.selectTool(.linearGradient)
        harness.viewModel.beginGradientDrag(at: .init(x: 10, y: 16))
        harness.viewModel.updateGradientDrag(to: .init(x: 30, y: 16))
        harness.viewModel.endGradientDrag(at: .init(x: 30, y: 16))
        harness.viewModel.applyActiveGradientSession()
        try await harness.waitForGradientCommitToFinish()

        #expect(harness.bootstrap.strokeEngine.displayTexture(for: layerID) == nil)
        #expect(try harness.alpha(atX: 10, y: 16, layerID: layerID) > 0.7)
    }

    @Test
    @MainActor
    func colorAdjustmentConfirmPaintedMaskSupportsUndoRedo() throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID

        try fillOpaqueRect(
            in: harness,
            layerID: layerID,
            originX: 12,
            originY: 12,
            width: 28,
            height: 28,
            color: .init(red: 0.24, green: 0.28, blue: 0.32, alpha: 1)
        )

        let sampleX = 24
        let sampleY = 24
        let basePixel = try harness.color(atX: sampleX, y: sampleY, layerID: layerID)

        harness.viewModel.selectTool(.brightnessAdjust)
        harness.viewModel.beginStrokeIfNeeded()
        harness.viewModel.applyStroke(samples: [
            .init(location: .init(x: Double(sampleX), y: Double(sampleY)), pressure: 1)
        ])
        harness.viewModel.endStroke()
        harness.viewModel.setColorAdjustmentBrightness(0.55)
        harness.viewModel.confirmColorAdjustmentPaintedSession()

        let committedPixel = try harness.color(atX: sampleX, y: sampleY, layerID: layerID)
        #expect(committedPixel.red > basePixel.red + 0.05)
        #expect(committedPixel.green > basePixel.green + 0.05)
        #expect(committedPixel.blue > basePixel.blue + 0.05)
        #expect(harness.viewModel.colorAdjustmentSession == nil)
        #expect(harness.viewModel.workspace.toolSession.activeTool == .brightnessAdjust)

        harness.viewModel.undo()
        let undonePixel = try harness.color(atX: sampleX, y: sampleY, layerID: layerID)
        #expect(abs(undonePixel.red - basePixel.red) < 0.02)
        #expect(abs(undonePixel.green - basePixel.green) < 0.02)
        #expect(abs(undonePixel.blue - basePixel.blue) < 0.02)

        harness.viewModel.redo()
        let redonePixel = try harness.color(atX: sampleX, y: sampleY, layerID: layerID)
        #expect(abs(redonePixel.red - committedPixel.red) < 0.02)
        #expect(abs(redonePixel.green - committedPixel.green) < 0.02)
        #expect(abs(redonePixel.blue - committedPixel.blue) < 0.02)
    }

    @Test
    @MainActor
    func colorAdjustmentToolSwitchPromptApplyCommitsPixelsBeforeSwitching() throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID
        let sampleX = 24
        let sampleY = 24

        try fillOpaqueRect(
            in: harness,
            layerID: layerID,
            originX: 12,
            originY: 12,
            width: 28,
            height: 28,
            color: .init(red: 0.24, green: 0.28, blue: 0.32, alpha: 1)
        )
        let basePixel = try harness.color(atX: sampleX, y: sampleY, layerID: layerID)

        harness.viewModel.selectTool(.brightnessAdjust)
        harness.viewModel.beginStrokeIfNeeded()
        harness.viewModel.applyStroke(samples: [
            .init(location: .init(x: Double(sampleX), y: Double(sampleY)), pressure: 1)
        ])
        harness.viewModel.endStroke()
        harness.viewModel.setColorAdjustmentBrightness(0.55)
        harness.viewModel.debugColorAdjustmentResolutionDecisionOverride = .apply

        harness.viewModel.selectTool(.brush)

        let committedPixel = try harness.color(atX: sampleX, y: sampleY, layerID: layerID)
        #expect(committedPixel.red > basePixel.red + 0.05)
        #expect(committedPixel.green > basePixel.green + 0.05)
        #expect(committedPixel.blue > basePixel.blue + 0.05)
        #expect(harness.viewModel.colorAdjustmentSession == nil)
        #expect(harness.viewModel.workspace.toolSession.activeTool == .brush)
    }

    @Test
    @MainActor
    func colorAdjustmentUndoPromptApplyCommitsThenContinuesHistoryNavigation() throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID
        let sampleX = 24
        let sampleY = 24

        try fillOpaqueRect(
            in: harness,
            layerID: layerID,
            originX: 12,
            originY: 12,
            width: 28,
            height: 28,
            color: .init(red: 0.24, green: 0.28, blue: 0.32, alpha: 1)
        )
        let basePixel = try harness.color(atX: sampleX, y: sampleY, layerID: layerID)

        harness.viewModel.selectTool(.brightnessAdjust)
        harness.viewModel.beginStrokeIfNeeded()
        harness.viewModel.applyStroke(samples: [.init(location: .init(x: 24, y: 24), pressure: 1)])
        harness.viewModel.endStroke()
        harness.viewModel.setColorAdjustmentBrightness(0.45)
        harness.viewModel.debugColorAdjustmentResolutionDecisionOverride = .apply

        harness.viewModel.undo()

        let undonePixel = try harness.color(atX: sampleX, y: sampleY, layerID: layerID)
        #expect(harness.viewModel.colorAdjustmentSession == nil)
        #expect(abs(undonePixel.red - basePixel.red) < 0.02)
        #expect(abs(undonePixel.green - basePixel.green) < 0.02)
        #expect(abs(undonePixel.blue - basePixel.blue) < 0.02)

        harness.viewModel.redo()

        let redonePixel = try harness.color(atX: sampleX, y: sampleY, layerID: layerID)
        #expect(redonePixel.red > basePixel.red + 0.05)
        #expect(redonePixel.green > basePixel.green + 0.05)
        #expect(redonePixel.blue > basePixel.blue + 0.05)
    }

    @Test
    @MainActor
    func colorAdjustmentUndoPromptDiscardConsumesSessionBeforeHistoryNavigation() throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.addLayer()

        try fillOpaqueRect(
            in: harness,
            layerID: layerID,
            originX: 12,
            originY: 12,
            width: 28,
            height: 28,
            color: .init(red: 0.22, green: 0.26, blue: 0.3, alpha: 1)
        )

        harness.viewModel.selectTool(.brightnessAdjust)
        harness.viewModel.beginStrokeIfNeeded()
        harness.viewModel.applyStroke(samples: [.init(location: .init(x: 24, y: 24), pressure: 1)])
        harness.viewModel.endStroke()
        harness.viewModel.setColorAdjustmentBrightness(0.45)
        harness.viewModel.debugColorAdjustmentResolutionDecisionOverride = .discard

        harness.viewModel.undo()

        #expect(harness.viewModel.colorAdjustmentSession == nil)
        #expect(harness.viewModel.workspace.document.layers.count == 2)
    }

    @Test
    @MainActor
    func colorVitalizationAutoCommitSupportsSingleStepUndoRedo() throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID
        let samplePoints = [(22, 22), (26, 26), (30, 30), (34, 34), (38, 38)]

        try fillOpaqueRect(
            in: harness,
            layerID: layerID,
            originX: 10,
            originY: 10,
            width: 44,
            height: 44,
            color: .init(red: 0.46, green: 0.25, blue: 0.61, alpha: 0.64)
        )
        let original = try samplePoints.map {
            try harness.color(atX: $0.0, y: $0.1, layerID: layerID)
        }

        harness.viewModel.setBrushSize(48)
        harness.viewModel.selectTool(.colorVitalization)
        harness.viewModel.beginStrokeIfNeeded()
        harness.viewModel.applyStroke(samples: [
            .init(location: .init(x: 30, y: 30), pressure: 1)
        ])
        harness.viewModel.endStroke()

        #expect(harness.viewModel.colorAdjustmentSession == nil)
        let committed = try samplePoints.map {
            try harness.color(atX: $0.0, y: $0.1, layerID: layerID)
        }
        let differences: [Float] = zip(original, committed).map { pair -> Float in
            let (before, after) = pair
            let red = before.red - after.red
            let green = before.green - after.green
            let blue = before.blue - after.blue
            let squaredDistance: Float = (red * red) + (green * green) + (blue * blue)
            return sqrt(squaredDistance)
        }
        let maximumDifference = differences.max() ?? 0
        #expect(maximumDifference > 0.015)
        for (before, after) in zip(original, committed) {
            #expect(abs(before.alpha - after.alpha) < 0.01)
        }

        harness.viewModel.undo()
        let undone = try samplePoints.map {
            try harness.color(atX: $0.0, y: $0.1, layerID: layerID)
        }
        for (before, after) in zip(original, undone) {
            #expect(abs(before.red - after.red) < 0.02)
            #expect(abs(before.green - after.green) < 0.02)
            #expect(abs(before.blue - after.blue) < 0.02)
            #expect(abs(before.alpha - after.alpha) < 0.01)
        }

        harness.viewModel.redo()
        let redone = try samplePoints.map {
            try harness.color(atX: $0.0, y: $0.1, layerID: layerID)
        }
        for (before, after) in zip(committed, redone) {
            #expect(abs(before.red - after.red) < 0.02)
            #expect(abs(before.green - after.green) < 0.02)
            #expect(abs(before.blue - after.blue) < 0.02)
            #expect(abs(before.alpha - after.alpha) < 0.01)
        }
    }

    @Test
    @MainActor
    func colorAdjustmentSelectionConfirmSupportsUndoRedo() throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID
        let insideSelectionX = 24
        let insideSelectionY = 24
        let outsideSelectionX = 42
        let outsideSelectionY = 42

        try fillOpaqueRect(
            in: harness,
            layerID: layerID,
            originX: 12,
            originY: 12,
            width: 40,
            height: 40,
            color: .init(red: 0.24, green: 0.28, blue: 0.32, alpha: 1)
        )
        harness.viewModel.selectTool(.rectangleSelection)
        harness.viewModel.beginSelection(kind: .rectangle, at: .init(x: 18, y: 18))
        harness.viewModel.updateSelection(to: .init(x: 32, y: 32))
        harness.viewModel.commitSelection(at: .init(x: 32, y: 32))

        let insideBasePixel = try harness.color(atX: insideSelectionX, y: insideSelectionY, layerID: layerID)
        let outsideBasePixel = try harness.color(atX: outsideSelectionX, y: outsideSelectionY, layerID: layerID)

        #expect(harness.viewModel.workspace.toolSession.activeTool == .rectangleSelection)
        harness.viewModel.setColorAdjustmentBrightness(0.55)
        #expect(harness.viewModel.canConfirmColorAdjustmentSession)
        harness.viewModel.confirmColorAdjustmentSession()
        let selectionAfterColorConfirm = harness.viewModel.workspace.selection.committedShape
        #expect(selectionAfterColorConfirm == nil)

        let insideCommittedPixel = try harness.color(atX: insideSelectionX, y: insideSelectionY, layerID: layerID)
        let outsideCommittedPixel = try harness.color(atX: outsideSelectionX, y: outsideSelectionY, layerID: layerID)
        #expect(insideCommittedPixel.red > insideBasePixel.red + 0.05)
        #expect(insideCommittedPixel.green > insideBasePixel.green + 0.05)
        #expect(insideCommittedPixel.blue > insideBasePixel.blue + 0.05)
        #expect(abs(outsideCommittedPixel.red - outsideBasePixel.red) < 0.02)
        #expect(abs(outsideCommittedPixel.green - outsideBasePixel.green) < 0.02)
        #expect(abs(outsideCommittedPixel.blue - outsideBasePixel.blue) < 0.02)

        harness.viewModel.undo()
        let selectionAfterColorUndo = harness.viewModel.workspace.selection.committedShape
        #expect(selectionAfterColorUndo == nil)

        let insideUndonePixel = try harness.color(atX: insideSelectionX, y: insideSelectionY, layerID: layerID)
        let outsideUndonePixel = try harness.color(atX: outsideSelectionX, y: outsideSelectionY, layerID: layerID)
        #expect(abs(insideUndonePixel.red - insideBasePixel.red) < 0.02)
        #expect(abs(insideUndonePixel.green - insideBasePixel.green) < 0.02)
        #expect(abs(insideUndonePixel.blue - insideBasePixel.blue) < 0.02)
        #expect(abs(outsideUndonePixel.red - outsideBasePixel.red) < 0.02)
        #expect(abs(outsideUndonePixel.green - outsideBasePixel.green) < 0.02)
        #expect(abs(outsideUndonePixel.blue - outsideBasePixel.blue) < 0.02)

        harness.viewModel.redo()
        let selectionAfterColorRedo = harness.viewModel.workspace.selection.committedShape
        #expect(selectionAfterColorRedo == nil)

        let insideRedonePixel = try harness.color(atX: insideSelectionX, y: insideSelectionY, layerID: layerID)
        let outsideRedonePixel = try harness.color(atX: outsideSelectionX, y: outsideSelectionY, layerID: layerID)
        #expect(abs(insideRedonePixel.red - insideCommittedPixel.red) < 0.02)
        #expect(abs(insideRedonePixel.green - insideCommittedPixel.green) < 0.02)
        #expect(abs(insideRedonePixel.blue - insideCommittedPixel.blue) < 0.02)
        #expect(abs(outsideRedonePixel.red - outsideCommittedPixel.red) < 0.02)
        #expect(abs(outsideRedonePixel.green - outsideCommittedPixel.green) < 0.02)
        #expect(abs(outsideRedonePixel.blue - outsideCommittedPixel.blue) < 0.02)
    }

    @Test
    @MainActor
    func colorAdjustmentWholeLayerConfirmSupportsUndoRedo() throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID
        let opaqueX = 24
        let opaqueY = 24
        let transparentX = 4
        let transparentY = 4

        try fillOpaqueRect(
            in: harness,
            layerID: layerID,
            originX: 12,
            originY: 12,
            width: 28,
            height: 28,
            color: .init(red: 0.24, green: 0.28, blue: 0.32, alpha: 1)
        )

        let opaqueBasePixel = try harness.color(atX: opaqueX, y: opaqueY, layerID: layerID)
        let transparentBasePixel = try harness.color(atX: transparentX, y: transparentY, layerID: layerID)

        #expect(harness.viewModel.workspace.toolSession.activeTool != .brightnessAdjust)
        harness.viewModel.setColorAdjustmentBrightness(0.55)
        harness.viewModel.confirmColorAdjustmentSession()

        let opaqueCommittedPixel = try harness.color(atX: opaqueX, y: opaqueY, layerID: layerID)
        let transparentCommittedPixel = try harness.color(atX: transparentX, y: transparentY, layerID: layerID)
        #expect(opaqueCommittedPixel.red > opaqueBasePixel.red + 0.05)
        #expect(opaqueCommittedPixel.green > opaqueBasePixel.green + 0.05)
        #expect(opaqueCommittedPixel.blue > opaqueBasePixel.blue + 0.05)
        #expect(abs(transparentCommittedPixel.alpha - transparentBasePixel.alpha) < 0.02)

        harness.viewModel.undo()

        let opaqueUndonePixel = try harness.color(atX: opaqueX, y: opaqueY, layerID: layerID)
        let transparentUndonePixel = try harness.color(atX: transparentX, y: transparentY, layerID: layerID)
        #expect(abs(opaqueUndonePixel.red - opaqueBasePixel.red) < 0.02)
        #expect(abs(opaqueUndonePixel.green - opaqueBasePixel.green) < 0.02)
        #expect(abs(opaqueUndonePixel.blue - opaqueBasePixel.blue) < 0.02)
        #expect(abs(transparentUndonePixel.alpha - transparentBasePixel.alpha) < 0.02)

        harness.viewModel.redo()

        let opaqueRedonePixel = try harness.color(atX: opaqueX, y: opaqueY, layerID: layerID)
        let transparentRedonePixel = try harness.color(atX: transparentX, y: transparentY, layerID: layerID)
        #expect(abs(opaqueRedonePixel.red - opaqueCommittedPixel.red) < 0.02)
        #expect(abs(opaqueRedonePixel.green - opaqueCommittedPixel.green) < 0.02)
        #expect(abs(opaqueRedonePixel.blue - opaqueCommittedPixel.blue) < 0.02)
        #expect(abs(transparentRedonePixel.alpha - transparentCommittedPixel.alpha) < 0.02)
    }

    @Test
    @MainActor
    func curveAdjustmentWholeLayerConfirmSupportsUndoRedo() throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID
        let opaqueX = 24
        let opaqueY = 24
        let transparentX = 4
        let transparentY = 4

        try fillOpaqueRect(
            in: harness,
            layerID: layerID,
            originX: 12,
            originY: 12,
            width: 28,
            height: 28,
            color: .init(red: 0.48, green: 0.48, blue: 0.48, alpha: 1)
        )

        let opaqueBasePixel = try harness.color(atX: opaqueX, y: opaqueY, layerID: layerID)
        let transparentBasePixel = try harness.color(atX: transparentX, y: transparentY, layerID: layerID)

        #expect(harness.viewModel.beginCurveAdjustmentFromWholeLayerIfNeeded(showFeedback: false))
        harness.viewModel.updateCurveAdjustmentChannelPoints(
            [
                .init(x: 0, y: 0),
                .init(x: 0.5, y: 0.25),
                .init(x: 1, y: 1)
            ],
            channel: .rgb
        )
        #expect(harness.viewModel.confirmCurveAdjustmentIfNeeded(showFeedback: false))

        let opaqueCommittedPixel = try harness.color(atX: opaqueX, y: opaqueY, layerID: layerID)
        let transparentCommittedPixel = try harness.color(atX: transparentX, y: transparentY, layerID: layerID)
        #expect(opaqueCommittedPixel.red < opaqueBasePixel.red - 0.04)
        #expect(opaqueCommittedPixel.green < opaqueBasePixel.green - 0.04)
        #expect(opaqueCommittedPixel.blue < opaqueBasePixel.blue - 0.04)
        #expect(abs(transparentCommittedPixel.alpha - transparentBasePixel.alpha) < 0.02)

        harness.viewModel.undo()

        let opaqueUndonePixel = try harness.color(atX: opaqueX, y: opaqueY, layerID: layerID)
        let transparentUndonePixel = try harness.color(atX: transparentX, y: transparentY, layerID: layerID)
        #expect(abs(opaqueUndonePixel.red - opaqueBasePixel.red) < 0.02)
        #expect(abs(opaqueUndonePixel.green - opaqueBasePixel.green) < 0.02)
        #expect(abs(opaqueUndonePixel.blue - opaqueBasePixel.blue) < 0.02)
        #expect(abs(transparentUndonePixel.alpha - transparentBasePixel.alpha) < 0.02)

        harness.viewModel.redo()

        let opaqueRedonePixel = try harness.color(atX: opaqueX, y: opaqueY, layerID: layerID)
        let transparentRedonePixel = try harness.color(atX: transparentX, y: transparentY, layerID: layerID)
        #expect(abs(opaqueRedonePixel.red - opaqueCommittedPixel.red) < 0.02)
        #expect(abs(opaqueRedonePixel.green - opaqueCommittedPixel.green) < 0.02)
        #expect(abs(opaqueRedonePixel.blue - opaqueCommittedPixel.blue) < 0.02)
        #expect(abs(transparentRedonePixel.alpha - transparentCommittedPixel.alpha) < 0.02)
    }

    @Test
    @MainActor
    func curveAdjustmentSelectionConfirmSupportsUndoRedoAndSelectionClipping() throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID
        let insideSelectionX = 24
        let insideSelectionY = 24
        let outsideSelectionX = 44
        let outsideSelectionY = 24

        try fillOpaqueRect(
            in: harness,
            layerID: layerID,
            originX: 12,
            originY: 12,
            width: 40,
            height: 24,
            color: .init(red: 0.48, green: 0.48, blue: 0.48, alpha: 1)
        )

        harness.makeLassoSelection([
            .init(x: 12, y: 12),
            .init(x: 36, y: 12),
            .init(x: 36, y: 36),
            .init(x: 12, y: 36),
            .init(x: 12, y: 12)
        ])

        let insideBasePixel = try harness.color(atX: insideSelectionX, y: insideSelectionY, layerID: layerID)
        let outsideBasePixel = try harness.color(atX: outsideSelectionX, y: outsideSelectionY, layerID: layerID)

        harness.viewModel.updateCurveAdjustmentChannelPoints(
            [
                .init(x: 0, y: 0),
                .init(x: 0.5, y: 0.25),
                .init(x: 1, y: 1)
            ],
            channel: .rgb
        )
        #expect(harness.viewModel.canConfirmCurveAdjustmentSession)
        #expect(harness.viewModel.confirmCurveAdjustmentIfNeeded(showFeedback: false))
        let selectionAfterCurveConfirm = harness.viewModel.workspace.selection.committedShape
        #expect(selectionAfterCurveConfirm == nil)

        let insideCommittedPixel = try harness.color(atX: insideSelectionX, y: insideSelectionY, layerID: layerID)
        let outsideCommittedPixel = try harness.color(atX: outsideSelectionX, y: outsideSelectionY, layerID: layerID)
        #expect(insideCommittedPixel.red < insideBasePixel.red - 0.04)
        #expect(insideCommittedPixel.green < insideBasePixel.green - 0.04)
        #expect(insideCommittedPixel.blue < insideBasePixel.blue - 0.04)
        #expect(abs(outsideCommittedPixel.red - outsideBasePixel.red) < 0.02)
        #expect(abs(outsideCommittedPixel.green - outsideBasePixel.green) < 0.02)
        #expect(abs(outsideCommittedPixel.blue - outsideBasePixel.blue) < 0.02)

        harness.viewModel.undo()
        let selectionAfterCurveUndo = harness.viewModel.workspace.selection.committedShape
        #expect(selectionAfterCurveUndo == nil)

        let insideUndonePixel = try harness.color(atX: insideSelectionX, y: insideSelectionY, layerID: layerID)
        let outsideUndonePixel = try harness.color(atX: outsideSelectionX, y: outsideSelectionY, layerID: layerID)
        #expect(abs(insideUndonePixel.red - insideBasePixel.red) < 0.02)
        #expect(abs(insideUndonePixel.green - insideBasePixel.green) < 0.02)
        #expect(abs(insideUndonePixel.blue - insideBasePixel.blue) < 0.02)
        #expect(abs(outsideUndonePixel.red - outsideBasePixel.red) < 0.02)
        #expect(abs(outsideUndonePixel.green - outsideBasePixel.green) < 0.02)
        #expect(abs(outsideUndonePixel.blue - outsideBasePixel.blue) < 0.02)

        harness.viewModel.redo()
        let selectionAfterCurveRedo = harness.viewModel.workspace.selection.committedShape
        #expect(selectionAfterCurveRedo == nil)

        let insideRedonePixel = try harness.color(atX: insideSelectionX, y: insideSelectionY, layerID: layerID)
        let outsideRedonePixel = try harness.color(atX: outsideSelectionX, y: outsideSelectionY, layerID: layerID)
        #expect(abs(insideRedonePixel.red - insideCommittedPixel.red) < 0.02)
        #expect(abs(insideRedonePixel.green - insideCommittedPixel.green) < 0.02)
        #expect(abs(insideRedonePixel.blue - insideCommittedPixel.blue) < 0.02)
        #expect(abs(outsideRedonePixel.red - outsideCommittedPixel.red) < 0.02)
        #expect(abs(outsideRedonePixel.green - outsideCommittedPixel.green) < 0.02)
        #expect(abs(outsideRedonePixel.blue - outsideCommittedPixel.blue) < 0.02)
    }

    @Test
    @MainActor
    func curveAdjustmentConfirmPaintedMaskSupportsUndoRedo() throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID
        let sampleX = 24
        let sampleY = 24

        try fillOpaqueRect(
            in: harness,
            layerID: layerID,
            originX: 12,
            originY: 12,
            width: 28,
            height: 28,
            color: .init(red: 0.48, green: 0.48, blue: 0.48, alpha: 1)
        )

        let basePixel = try harness.color(atX: sampleX, y: sampleY, layerID: layerID)

        harness.viewModel.selectTool(.brightnessAdjust)
        harness.viewModel.setBrightnessAdjustmentEditorMode(.curves)
        harness.viewModel.beginStrokeIfNeeded()
        harness.viewModel.applyStroke(samples: [
            .init(location: .init(x: Double(sampleX), y: Double(sampleY)), pressure: 1)
        ])
        harness.viewModel.endStroke()
        harness.viewModel.updateCurveAdjustmentChannelPoints(
            [
                .init(x: 0, y: 0),
                .init(x: 0.5, y: 0.25),
                .init(x: 1, y: 1)
            ],
            channel: .rgb
        )
        #expect(harness.viewModel.confirmCurveAdjustmentIfNeeded(showFeedback: false))

        let committedPixel = try harness.color(atX: sampleX, y: sampleY, layerID: layerID)
        #expect(committedPixel.red < basePixel.red - 0.04)
        #expect(committedPixel.green < basePixel.green - 0.04)
        #expect(committedPixel.blue < basePixel.blue - 0.04)
        #expect(harness.viewModel.curveAdjustmentSession == nil)
        #expect(harness.viewModel.workspace.toolSession.activeTool == .brightnessAdjust)

        harness.viewModel.undo()
        let undonePixel = try harness.color(atX: sampleX, y: sampleY, layerID: layerID)
        #expect(abs(undonePixel.red - basePixel.red) < 0.02)
        #expect(abs(undonePixel.green - basePixel.green) < 0.02)
        #expect(abs(undonePixel.blue - basePixel.blue) < 0.02)

        harness.viewModel.redo()
        let redonePixel = try harness.color(atX: sampleX, y: sampleY, layerID: layerID)
        #expect(abs(redonePixel.red - committedPixel.red) < 0.02)
        #expect(abs(redonePixel.green - committedPixel.green) < 0.02)
        #expect(abs(redonePixel.blue - committedPixel.blue) < 0.02)
    }

    @Test
    @MainActor
    func cutAndPastePixelsSupportUndoRedo() throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID

        try fillOpaqueRect(
            in: harness,
            layerID: layerID,
            originX: 12,
            originY: 14,
            width: 8,
            height: 8,
            color: .init(red: 1, green: 0, blue: 0, alpha: 1)
        )
        harness.viewModel.selectTool(.rectangleSelection)
        harness.viewModel.beginSelection(kind: .rectangle, at: .init(x: 13, y: 15))
        harness.viewModel.updateSelection(to: .init(x: 18, y: 20))
        harness.viewModel.commitSelection(at: .init(x: 18, y: 20))

        harness.viewModel.cutPixels()
        #expect(try harness.alpha(atX: 15, y: 17, layerID: layerID) < 0.01)

        harness.viewModel.undo()
        #expect(try harness.alpha(atX: 15, y: 17, layerID: layerID) > 0.95)

        harness.viewModel.redo()
        #expect(try harness.alpha(atX: 15, y: 17, layerID: layerID) < 0.01)

        let layerCountBeforePaste = harness.viewModel.workspace.document.layers.count
        harness.viewModel.pastePixels()
        let pastedLayerID = harness.viewModel.workspace.document.activeLayerID
        #expect(harness.viewModel.workspace.document.layers.count == layerCountBeforePaste + 1)
        #expect(try harness.alpha(atX: 15, y: 17, layerID: pastedLayerID) > 0.95)

        harness.viewModel.undo()
        #expect(harness.viewModel.workspace.document.layers.count == layerCountBeforePaste)

        harness.viewModel.redo()
        let restoredPastedLayerID = harness.viewModel.workspace.document.activeLayerID
        #expect(harness.viewModel.workspace.document.layers.count == layerCountBeforePaste + 1)
        #expect(try harness.alpha(atX: 15, y: 17, layerID: restoredPastedLayerID) > 0.95)
    }

    @Test
    @MainActor
    func sectorGradientAutoApplySupportsUndoRedoAndSelectionClipping() async throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.addLayer()

        harness.makeLassoSelection([
            .init(x: 8, y: 8),
            .init(x: 36, y: 8),
            .init(x: 36, y: 36),
            .init(x: 8, y: 36),
            .init(x: 8, y: 8)
        ])

        harness.viewModel.selectLayer(layerID)
        harness.viewModel.selectTool(.sectorGradient)
        harness.viewModel.beginGradientDrag(at: .init(x: 12, y: 20))
        harness.viewModel.updateGradientDrag(to: .init(x: 28, y: 8))
        harness.viewModel.updateGradientDrag(to: .init(x: 44, y: 20))
        harness.viewModel.updateGradientDrag(to: .init(x: 28, y: 38))
        harness.viewModel.endGradientDrag(at: .init(x: 12, y: 20))
        try await harness.waitForGradientCommitToFinish()

        #expect(harness.viewModel.isApplyingGradientCommit == false)
        #expect(harness.viewModel.sectorGradientState.phase == .idle)
        #expect(harness.viewModel.workspace.toolSession.activeTool == .sectorGradient)

        let nearAlpha = try harness.alpha(atX: 14, y: 20, layerID: layerID)
        let farAlpha = try harness.alpha(atX: 30, y: 20, layerID: layerID)
        let clippedAlpha = try harness.alpha(atX: 40, y: 20, layerID: layerID)

        #expect(nearAlpha > 0.35)
        #expect(farAlpha > 0.01)
        #expect(farAlpha < nearAlpha)
        #expect(clippedAlpha < 0.05)

        harness.viewModel.undo()
        #expect(try harness.alpha(atX: 14, y: 20, layerID: layerID) < 0.05)
        harness.viewModel.redo()
        #expect(try harness.alpha(atX: 14, y: 20, layerID: layerID) > 0.35)
    }

    @Test
    @MainActor
    func sectorGradientRespectsBrushOpacity() async throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.addLayer()

        harness.viewModel.setBrushOpacity(0.24)
        harness.viewModel.selectLayer(layerID)
        harness.viewModel.selectTool(.sectorGradient)
        harness.viewModel.beginGradientDrag(at: .init(x: 12, y: 20))
        harness.viewModel.updateGradientDrag(to: .init(x: 28, y: 8))
        harness.viewModel.updateGradientDrag(to: .init(x: 44, y: 20))
        harness.viewModel.updateGradientDrag(to: .init(x: 28, y: 38))
        harness.viewModel.endGradientDrag(at: .init(x: 12, y: 20))
        try await harness.waitForGradientCommitToFinish()

        let nearAlpha = try harness.alpha(atX: 14, y: 20, layerID: layerID)
        #expect(nearAlpha > 0.18)
        #expect(nearAlpha < 0.30)
    }

    @Test
    @MainActor
    func fillAtPointSupportsUndoRedo() throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID
        let basePixel = try harness.color(atX: 12, y: 12, layerID: layerID)

        harness.viewModel.fillAtPoint(.init(x: 12, y: 12))
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) > 0.01)

        harness.viewModel.undo()
        let restoredFillPixel = try harness.color(atX: 12, y: 12, layerID: layerID)
        #expect(abs(restoredFillPixel.alpha - basePixel.alpha) < 0.02)
        #expect(abs(restoredFillPixel.red - basePixel.red) < 0.02)
        #expect(abs(restoredFillPixel.green - basePixel.green) < 0.02)
        #expect(abs(restoredFillPixel.blue - basePixel.blue) < 0.02)

        harness.viewModel.redo()
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) > 0.01)
    }

    @Test
    @MainActor
    func fillReferenceLayerDefinesConnectivityWithoutPaintingTheReference() throws {
        let harness = try PixelHistoryHarness()
        let targetLayerID = harness.viewModel.workspace.document.activeLayerID
        let referenceLayerID = harness.addLayer()
        try fillOpaqueRect(
            in: harness,
            layerID: referenceLayerID,
            originX: 10,
            originY: 10,
            width: 12,
            height: 12,
            color: .init(red: 0.1, green: 0.3, blue: 0.9, alpha: 1)
        )
        harness.viewModel.toggleLayerReference(referenceLayerID)
        harness.viewModel.selectLayer(targetLayerID)
        harness.viewModel.setSelectedColor(.init(red: 0.9, green: 0.15, blue: 0.05, alpha: 1))

        harness.viewModel.fillAtPoint(.init(x: 12, y: 12))

        let filledPixel = try harness.color(atX: 12, y: 12, layerID: targetLayerID)
        #expect(filledPixel.red > 0.8)
        #expect(try harness.alpha(atX: 30, y: 30, layerID: targetLayerID) < 0.01)
        let referencePixel = try harness.color(atX: 12, y: 12, layerID: referenceLayerID)
        #expect(referencePixel.blue > 0.8)
        #expect(referencePixel.red < 0.2)
    }

    @Test
    @MainActor
    func fillAtPointOnLargeNonuniformLayerStoresOnlyDirtyRegion() throws {
        let harness = try PixelHistoryHarness(canvasSize: .init(width: 1024, height: 1024))
        let layerID = harness.viewModel.workspace.document.activeLayerID
        try fillOpaqueRect(
            in: harness,
            layerID: layerID,
            originX: 256,
            originY: 256,
            width: 32,
            height: 32,
            color: .init(red: 0.1, green: 0.2, blue: 0.9, alpha: 1)
        )

        harness.viewModel.setSelectedColor(.init(red: 0.9, green: 0.05, blue: 0.02, alpha: 1))
        harness.viewModel.fillAtPoint(.init(x: 260, y: 260))

        let filledPixel = try harness.color(atX: 260, y: 260, layerID: layerID)
        #expect(filledPixel.red > 0.8)
        #expect(try harness.alpha(atX: 64, y: 64, layerID: layerID) < 0.01)
#if DEBUG
        let entryBytes = harness.bootstrap.historyController.debugUndoEntryApproxByteCounts.last ?? 0
        #expect(entryBytes <= 32 * 32 * 4)
#endif

        harness.viewModel.undo()
        let restoredPixel = try harness.color(atX: 260, y: 260, layerID: layerID)
        #expect(restoredPixel.blue > 0.8)
        #expect(restoredPixel.red < 0.2)
        #expect(try harness.alpha(atX: 64, y: 64, layerID: layerID) < 0.01)

        harness.viewModel.redo()
        let redonePixel = try harness.color(atX: 260, y: 260, layerID: layerID)
        #expect(redonePixel.red > 0.8)
        #expect(try harness.alpha(atX: 64, y: 64, layerID: layerID) < 0.01)
    }

    @Test
    @MainActor
    func scatteredBrushCommitStoresOnlyRenderedRegionAndKeepsUndoRedoExact() throws {
        let harness = try PixelHistoryHarness(canvasSize: .init(width: 1024, height: 1024))
        let layerID = harness.viewModel.workspace.document.activeLayerID
        let before = try harness.snapshot(layerID: layerID)

        harness.viewModel.selectLayer(layerID)
        harness.viewModel.selectTool(.brush)
        harness.viewModel.setBrushSize(72)
        harness.viewModel.setBrushScatterAmount(1)
        harness.viewModel.setBrushJitterAmount(1)
        harness.viewModel.setBrushSizeJitterAmount(1)
        harness.viewModel.beginStrokeIfNeeded()
        harness.viewModel.applyStroke(samples: [
            .init(location: .init(x: 420, y: 430), pressure: 0.35),
            .init(location: .init(x: 500, y: 500), pressure: 0.7),
            .init(location: .init(x: 590, y: 570), pressure: 1)
        ])
        harness.viewModel.endStroke()
        try flushPendingPixelHistoryBrushWork(
            viewModel: harness.viewModel,
            metalContext: harness.bootstrap.metalContext
        )
        _ = harness.viewModel.flushBrushEditingBoundary(reason: "test dirty brush history")
        let after = try harness.snapshot(layerID: layerID)

        #expect(after != before)
#if DEBUG
        let entryBytes = harness.bootstrap.historyController.debugUndoEntryApproxByteCounts.last ?? 0
        #expect(entryBytes > 0)
        #expect(entryBytes < (1024 * 1024 * 4) / 4)
        let entryMode = try #require(harness.bootstrap.historyController.debugUndoEntryModes.last)
        switch entryMode {
        case .full:
            Issue.record("Expected brush commit to use in-place dirty history")
        case .inPlaceChangedLayers(_, let changedLayerIDs):
            #expect(Set(changedLayerIDs) == [layerID])
        case .workspaceOnly, .metadataOnly:
            Issue.record("Expected brush commit to use pixel history")
        }
#endif

        harness.viewModel.undo()
        #expect(try harness.snapshot(layerID: layerID) == before)
        harness.viewModel.redo()
        #expect(try harness.snapshot(layerID: layerID) == after)
    }

    @Test
    @MainActor
    func smudgeCommitUsesSingleLayerRenderedRegionHistory() throws {
        let harness = try PixelHistoryHarness(canvasSize: .init(width: 1024, height: 1024))
        let layerID = harness.viewModel.workspace.document.activeLayerID
        try harness.drawBrushStroke(on: layerID, points: [
            .init(location: .init(x: 480, y: 500), pressure: 1),
            .init(location: .init(x: 540, y: 500), pressure: 1)
        ])
        _ = harness.viewModel.flushBrushEditingBoundary(reason: "test smudge setup")
        harness.bootstrap.historyController.resetHistory()

        harness.viewModel.selectTool(.smudge)
        harness.viewModel.setBrushSize(64)
        harness.viewModel.beginStrokeIfNeeded()
        harness.viewModel.applyStroke(samples: [
            .init(location: .init(x: 490, y: 500), pressure: 1),
            .init(location: .init(x: 560, y: 520), pressure: 1)
        ])
        harness.viewModel.endStroke()
        try flushPendingPixelHistoryBrushWork(
            viewModel: harness.viewModel,
            metalContext: harness.bootstrap.metalContext
        )
        _ = harness.viewModel.flushBrushEditingBoundary(reason: "test smudge dirty history")

#if DEBUG
        let entryBytes = harness.bootstrap.historyController.debugUndoEntryApproxByteCounts.last ?? 0
        #expect(entryBytes > 0)
        #expect(entryBytes < 256 * 256 * 4)
        let entryMode = try #require(harness.bootstrap.historyController.debugUndoEntryModes.last)
        switch entryMode {
        case .full:
            Issue.record("Expected smudge commit to use in-place dirty history")
        case .inPlaceChangedLayers(_, let changedLayerIDs):
            #expect(Set(changedLayerIDs) == [layerID])
        case .workspaceOnly, .metadataOnly:
            Issue.record("Expected smudge commit to use pixel history")
        }
#endif
    }

    @Test
    @MainActor
    func optionBackspaceAndForwardDeleteFillSelectionWithForegroundColorFromAnyTool() throws {
        for keyCode: UInt16 in [51, 117] {
            let harness = try PixelHistoryHarness()
            let layerID = harness.viewModel.workspace.document.activeLayerID

            harness.makeRectangleSelection(minX: 8, minY: 8, maxX: 24, maxY: 24)
            harness.viewModel.selectTool(.brush)
            harness.viewModel.setSelectedColor(.init(red: 0.9, green: 0.05, blue: 0.02, alpha: 1))
            let handled = harness.viewModel.handleKeyDown(
                makeCanvasKeyEvent(
                    type: .keyDown,
                    characters: "\u{7f}",
                    charactersIgnoringModifiers: "\u{7f}",
                    modifiers: [.option],
                    keyCode: keyCode
                )
            )

            #expect(handled)
            let filledPixel = try harness.color(atX: 12, y: 12, layerID: layerID)
            #expect(filledPixel.red > 0.8)
            #expect(filledPixel.alpha > 0.9)
            #expect(try harness.alpha(atX: 32, y: 32, layerID: layerID) < 0.01)

            harness.viewModel.undo()
            #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) < 0.01)
        }
    }

    @Test
    @MainActor
    func deleteKeyClearsSelectedPixelsWithoutDeletingLayer() throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID
        try fillOpaqueRect(
            in: harness,
            layerID: layerID,
            originX: 0,
            originY: 0,
            width: 64,
            height: 64,
            color: .init(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        )
        harness.makeRectangleSelection(minX: 8, minY: 8, maxX: 24, maxY: 24)
        let initialLayerCount = harness.viewModel.workspace.document.layers.count

        let handled = harness.viewModel.handleKeyDown(
            makeCanvasKeyEvent(
                type: .keyDown,
                characters: "\u{7f}",
                charactersIgnoringModifiers: "\u{7f}",
                modifiers: [],
                keyCode: 51
            )
        )

        #expect(handled)
        #expect(harness.viewModel.workspace.document.layers.count == initialLayerCount)
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) < 0.01)
        #expect(try harness.alpha(atX: 32, y: 32, layerID: layerID) > 0.99)

        harness.viewModel.undo()
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) > 0.99)
    }

    @Test
    @MainActor
    func deleteKeyWithoutSelectionDoesNotDeleteActiveLayer() throws {
        let harness = try PixelHistoryHarness()
        let deletedLayerID = harness.viewModel.workspace.document.activeLayerID
        let initialLayerIDs = harness.viewModel.workspace.document.layers.map(\.id)

        let handled = harness.viewModel.handleKeyDown(
            makeCanvasKeyEvent(
                type: .keyDown,
                characters: "\u{7f}",
                charactersIgnoringModifiers: "\u{7f}",
                modifiers: [],
                keyCode: 51
            )
        )

        #expect(handled)
        #expect(harness.viewModel.workspace.document.layers.count == initialLayerIDs.count)
        #expect(harness.viewModel.workspace.document.layers.contains(where: { $0.id == deletedLayerID }))
        #expect(harness.viewModel.status?.message == "没有选区；请在图层面板中明确删除图层")
        #expect(harness.viewModel.workspace.document.layers.map(\.id) == initialLayerIDs)
        #expect(harness.viewModel.workspace.document.activeLayerID == deletedLayerID)
    }

    @Test
    @MainActor
    func featherSelectionSupportsUndoRedoAndCreatesASoftMask() async throws {
        let harness = try PixelHistoryHarness()
        harness.makeRectangleSelection(minX: 16, minY: 16, maxX: 48, maxY: 48)
        let originalSelection = try #require(harness.viewModel.workspace.selection.committedShape)

        harness.viewModel.featherSelection(radiusPixels: 8)
        let featheredSelection = try await harness.waitForFeatheredSelection(sampleX: 11, sampleY: 32)
        let featheredMask = try #require(featheredSelection.maskData)
        let softAlpha = try #require(featheredMask.alphaByte(at: (32 * 64) + 11))

        #expect(featheredSelection.kind == .mask)
        #expect(featheredSelection.bounds.minX < 16)
        #expect(featheredSelection.components.count == 1)
        #expect(featheredSelection.components.first?.shape == originalSelection)
        #expect(softAlpha > 0)
        #expect(softAlpha < 255)

        harness.viewModel.undo()
        #expect(harness.viewModel.workspace.selection.committedShape == originalSelection)

        harness.viewModel.redo()
        let redoneSelection = try #require(harness.viewModel.workspace.selection.committedShape)
        let redoneMask = try #require(redoneSelection.maskData)
        #expect(redoneMask.alphaByte(at: (32 * 64) + 11) == softAlpha)
    }

    @Test
    @MainActor
    func featheredSelectionSoftensColorFill() async throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID
        harness.makeRectangleSelection(minX: 16, minY: 16, maxX: 48, maxY: 48)
        harness.viewModel.featherSelection(radiusPixels: 8)
        _ = try await harness.waitForFeatheredSelection(sampleX: 11, sampleY: 32)

        harness.viewModel.setSelectedColor(.init(red: 1, green: 0, blue: 0, alpha: 1))
        harness.viewModel.fillSelectionContents()

        let featherAlpha = try harness.alpha(atX: 11, y: 32, layerID: layerID)
        let outerTransparentAlpha = try harness.alpha(atX: 8, y: 32, layerID: layerID)
        let outerSoftAlpha = try harness.alpha(atX: 9, y: 32, layerID: layerID)
        #expect(outerTransparentAlpha < 0.001)
        #expect(outerSoftAlpha > outerTransparentAlpha)
        #expect(outerSoftAlpha < featherAlpha)
        #expect(featherAlpha > 0.01)
        #expect(featherAlpha < 0.9)
        #expect(try harness.alpha(atX: 32, y: 32, layerID: layerID) > 0.95)
        #expect(try harness.alpha(atX: 4, y: 32, layerID: layerID) < 0.01)
    }

    @Test
    @MainActor
    func featheredSelectionSoftensPixelDeletion() async throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID
        try fillOpaqueRect(
            in: harness,
            layerID: layerID,
            originX: 0,
            originY: 0,
            width: 64,
            height: 64,
            color: .init(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        )
        harness.makeRectangleSelection(minX: 16, minY: 16, maxX: 48, maxY: 48)
        harness.viewModel.featherSelection(radiusPixels: 8)
        _ = try await harness.waitForFeatheredSelection(sampleX: 11, sampleY: 32)

        harness.viewModel.deleteSelectionContents()

        let featherAlpha = try harness.alpha(atX: 11, y: 32, layerID: layerID)
        #expect(featherAlpha > 0.1)
        #expect(featherAlpha < 0.99)
        #expect(try harness.alpha(atX: 32, y: 32, layerID: layerID) < 0.01)
        #expect(try harness.alpha(atX: 4, y: 32, layerID: layerID) > 0.99)
    }

    @Test
    @MainActor
    func featheredSelectionSoftensBrushPainting() async throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID
        harness.makeRectangleSelection(minX: 16, minY: 16, maxX: 48, maxY: 48)
        harness.viewModel.featherSelection(radiusPixels: 8)
        _ = try await harness.waitForFeatheredSelection(sampleX: 11, sampleY: 32)

        harness.viewModel.setBrushBuildMode(.opacityCap)
        harness.viewModel.setBrushTipShape(.hardRound)
        harness.viewModel.setBrushSize(64)
        harness.viewModel.setBrushOpacity(1)
        try harness.drawBrushStroke(
            on: layerID,
            points: [
                .init(location: .init(x: 30, y: 32), pressure: 1),
                .init(location: .init(x: 32, y: 32), pressure: 1),
                .init(location: .init(x: 34, y: 32), pressure: 1)
            ]
        )
        _ = harness.viewModel.flushBrushEditingBoundary(reason: "test feathered brush output")

        let featherAlpha = try harness.alpha(atX: 11, y: 32, layerID: layerID)
        let outerTransparentAlpha = try harness.alpha(atX: 8, y: 32, layerID: layerID)
        let outerSoftAlpha = try harness.alpha(atX: 9, y: 32, layerID: layerID)
        #expect(outerTransparentAlpha < 0.001)
        #expect(outerSoftAlpha > outerTransparentAlpha)
        #expect(outerSoftAlpha < featherAlpha)
        #expect(featherAlpha > 0.01)
        #expect(featherAlpha < 0.9)
        #expect(try harness.alpha(atX: 32, y: 32, layerID: layerID) > 0.95)
        #expect(try harness.alpha(atX: 4, y: 32, layerID: layerID) < 0.01)
    }

    @Test
    @MainActor
    func featheredSelectionSoftensBucketFill() async throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID
        harness.makeRectangleSelection(minX: 16, minY: 16, maxX: 48, maxY: 48)
        harness.viewModel.featherSelection(radiusPixels: 8)
        _ = try await harness.waitForFeatheredSelection(sampleX: 11, sampleY: 32)

        harness.viewModel.setSelectedColor(.init(red: 0, green: 0, blue: 1, alpha: 1))
        harness.viewModel.fillAtPoint(.init(x: 32, y: 32))

        let featherAlpha = try harness.alpha(atX: 11, y: 32, layerID: layerID)
        #expect(featherAlpha > 0.01)
        #expect(featherAlpha < 0.9)
        #expect(try harness.alpha(atX: 32, y: 32, layerID: layerID) > 0.95)
        #expect(try harness.alpha(atX: 4, y: 32, layerID: layerID) < 0.01)
    }

    @Test
    @MainActor
    func optionForwardDeleteWithoutSelectionFillsOpaqueLayerPixelsPreservingAlpha() throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID
        try fillOpaqueRect(
            in: harness,
            layerID: layerID,
            originX: 20,
            originY: 20,
            width: 16,
            height: 16,
            color: .init(red: 0.08, green: 0.12, blue: 0.72, alpha: 0.36)
        )
        let basePixel = try harness.color(atX: 24, y: 24, layerID: layerID)

        harness.viewModel.selectTool(.brush)
        harness.viewModel.setSelectedColor(.init(red: 0.92, green: 0.04, blue: 0.02, alpha: 1))
        let handled = harness.viewModel.handleKeyDown(
            makeCanvasKeyEvent(
                type: .keyDown,
                characters: "\u{7f}",
                charactersIgnoringModifiers: "\u{7f}",
                modifiers: [.option],
                keyCode: 117
            )
        )

        #expect(handled)
        let filledPixel = try harness.color(atX: 24, y: 24, layerID: layerID)
        #expect(filledPixel.red > basePixel.red + 0.04)
        #expect(abs(filledPixel.alpha - basePixel.alpha) < 0.03)
        #expect(try harness.alpha(atX: 8, y: 8, layerID: layerID) < 0.01)

        harness.viewModel.undo()
        let restoredPixel = try harness.color(atX: 24, y: 24, layerID: layerID)
        #expect(restoredPixel.blue > basePixel.blue - 0.04)
        #expect(abs(restoredPixel.alpha - basePixel.alpha) < 0.03)

        harness.viewModel.redo()
        let redonePixel = try harness.color(atX: 24, y: 24, layerID: layerID)
        #expect(redonePixel.red > basePixel.red + 0.04)
        #expect(abs(redonePixel.alpha - basePixel.alpha) < 0.03)
    }

    @Test
    @MainActor
    func selectionFillKeepsUntouchedEmptyLayerKnownTransparent() throws {
        let harness = try PixelHistoryHarness()
        let paintedLayerID = harness.viewModel.workspace.document.activeLayerID
        let untouchedLayerID = harness.addLayer()
        #expect(harness.bootstrap.layerSurfaceStore.isKnownTransparent(layerID: untouchedLayerID))

        harness.viewModel.selectLayer(paintedLayerID)
        harness.makeRectangleSelection(minX: 8, minY: 8, maxX: 24, maxY: 24)
        harness.viewModel.fillSelectionContents()

        #expect(!harness.bootstrap.layerSurfaceStore.isKnownTransparent(layerID: paintedLayerID))
        #expect(harness.bootstrap.layerSurfaceStore.isKnownTransparent(layerID: untouchedLayerID))
    }

    @Test
    @MainActor
    func fillAtPointMixedWithSelectionOperationsKeepsUndoRedoOrder() throws {
        let harness = try PixelHistoryHarness()
        let firstLayerID = harness.viewModel.workspace.document.activeLayerID
        let secondLayerID = harness.addLayer()
        let thirdLayerID = harness.addLayer()
        let fourthLayerID = harness.addLayer()

        harness.viewModel.selectLayer(fourthLayerID)
        harness.viewModel.fillAtPoint(.init(x: 12, y: 12))
        harness.bootstrap.historyController.resetHistory()

        harness.viewModel.selectLayer(firstLayerID)
        harness.viewModel.fillAtPoint(.init(x: 12, y: 12))

        harness.viewModel.selectLayer(secondLayerID)
        harness.makeLassoSelection([
            .init(x: 8, y: 8),
            .init(x: 24, y: 8),
            .init(x: 24, y: 24),
            .init(x: 8, y: 24),
            .init(x: 8, y: 8)
        ])
        harness.viewModel.fillSelectionContents()

        harness.viewModel.selectLayer(thirdLayerID)
        harness.makeLassoSelection([
            .init(x: 32, y: 32),
            .init(x: 48, y: 32),
            .init(x: 48, y: 48),
            .init(x: 32, y: 48),
            .init(x: 32, y: 32)
        ])
        harness.viewModel.fillLassoContents()

        harness.viewModel.selectLayer(fourthLayerID)
        harness.makeLassoSelection([
            .init(x: 12, y: 12),
            .init(x: 28, y: 12),
            .init(x: 28, y: 28),
            .init(x: 12, y: 28),
            .init(x: 12, y: 12)
        ])
        harness.viewModel.eraseLassoContents()

        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) > 0.01)
        #expect(try harness.alpha(atX: 12, y: 12, layerID: secondLayerID) > 0.01)
        #expect(try harness.alpha(atX: 40, y: 40, layerID: thirdLayerID) > 0.01)
        #expect(try harness.alpha(atX: 16, y: 16, layerID: fourthLayerID) < 0.01)

        harness.viewModel.undo()
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) > 0.01)
        #expect(try harness.alpha(atX: 12, y: 12, layerID: secondLayerID) > 0.01)
        #expect(try harness.alpha(atX: 40, y: 40, layerID: thirdLayerID) > 0.01)
        #expect(try harness.alpha(atX: 16, y: 16, layerID: fourthLayerID) > 0.01)

        harness.viewModel.redo()
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) > 0.01)
        #expect(try harness.alpha(atX: 12, y: 12, layerID: secondLayerID) > 0.01)
        #expect(try harness.alpha(atX: 40, y: 40, layerID: thirdLayerID) > 0.01)
        #expect(try harness.alpha(atX: 16, y: 16, layerID: fourthLayerID) < 0.01)
    }

    @Test
    @MainActor
    func selectionFillSupportsUndoRedo() throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID
        let basePixel = try harness.color(atX: 12, y: 12, layerID: layerID)

        harness.makeLassoSelection([
            .init(x: 8, y: 8),
            .init(x: 32, y: 8),
            .init(x: 32, y: 32),
            .init(x: 8, y: 32),
            .init(x: 8, y: 8)
        ])
        harness.viewModel.fillSelectionContents()
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) > 0.01)

        harness.viewModel.undo()
        let restoredSelectionPixel = try harness.color(atX: 12, y: 12, layerID: layerID)
        #expect(abs(restoredSelectionPixel.alpha - basePixel.alpha) < 0.02)
        #expect(abs(restoredSelectionPixel.red - basePixel.red) < 0.02)
        #expect(abs(restoredSelectionPixel.green - basePixel.green) < 0.02)
        #expect(abs(restoredSelectionPixel.blue - basePixel.blue) < 0.02)

        harness.viewModel.redo()
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) > 0.01)
    }

    @Test
    @MainActor
    func selectionFillRespectsSubtractedCompositeRegion() throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID

        let outer = SelectionShape(
            kind: .rectangle,
            bounds: CanvasRect(origin: .init(x: 8, y: 8), size: .init(x: 24, y: 24)),
            pathPoints: []
        )
        let inner = SelectionShape(
            kind: .rectangle,
            bounds: CanvasRect(origin: .init(x: 16, y: 16), size: .init(x: 8, y: 8)),
            pathPoints: []
        )
        harness.viewModel.debugSetCommittedSelectionShapeForTests(
            SelectionShape.composite([
                SelectionShapeComponent(operation: .add, shape: outer),
                SelectionShapeComponent(operation: .subtract, shape: inner)
            ])
        )
        harness.viewModel.fillSelectionContents()

        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) > 0.01)
        #expect(try harness.alpha(atX: 20, y: 20, layerID: layerID) < 0.01)
    }

    @Test
    @MainActor
    func lassoFillAndEraseSupportUndoRedo() throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID

        harness.makeLassoSelection([
            .init(x: 8, y: 8),
            .init(x: 32, y: 8),
            .init(x: 32, y: 32),
            .init(x: 8, y: 32),
            .init(x: 8, y: 8)
        ])
        harness.viewModel.fillLassoContents()
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) > 0.01)

        harness.makeLassoSelection([
            .init(x: 10, y: 10),
            .init(x: 20, y: 10),
            .init(x: 20, y: 20),
            .init(x: 10, y: 20),
            .init(x: 10, y: 10)
        ])
        harness.viewModel.eraseLassoContents()
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) < 0.01)

        harness.viewModel.undo()
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) > 0.01)

        harness.viewModel.redo()
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) < 0.01)
    }

    @Test
    @MainActor
    func lassoFillRespectsBrushOpacity() throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.addLayer()

        harness.viewModel.setBrushOpacity(0.24)
        harness.viewModel.selectLayer(layerID)
        harness.makeLassoSelection([
            .init(x: 8, y: 8),
            .init(x: 32, y: 8),
            .init(x: 32, y: 32),
            .init(x: 8, y: 32),
            .init(x: 8, y: 8)
        ])
        harness.viewModel.fillLassoContents()

        let fillAlpha = try harness.alpha(atX: 12, y: 12, layerID: layerID)
        #expect(fillAlpha > 0.18)
        #expect(fillAlpha < 0.30)
    }

    @Test
    @MainActor
    func textureFillSupportsUndoRedo() throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID

        harness.beginTextureFill(at: .init(x: 8, y: 8))
        harness.updateTextureFill(to: .init(x: 32, y: 8))
        harness.updateTextureFill(to: .init(x: 32, y: 32))
        #expect(harness.viewModel.selectionOverlayProxy.inProgressShape?.kind == .lasso)
        harness.endTextureFill(at: .init(x: 8, y: 32))

        let filledPixels = try harness.snapshot(layerID: layerID).pixelData
        #expect(stride(from: 3, to: filledPixels.count, by: 4).contains { filledPixels[$0] > 0 })
        #expect(harness.viewModel.selectionOverlayProxy.inProgressShape == nil)

        harness.viewModel.undo()
        let restoredPixel = try harness.color(atX: 12, y: 12, layerID: layerID)
        #expect(restoredPixel.alpha < 0.01)
        #expect(restoredPixel.red < 0.01)
        #expect(restoredPixel.green < 0.01)
        #expect(restoredPixel.blue < 0.01)
        #expect(harness.viewModel.workspace.selection.committedShape == nil)
        #expect(harness.viewModel.workspace.selection.inProgressShape == nil)
        #expect(harness.viewModel.selectionOverlayProxy.displayShape == nil)

        harness.viewModel.redo()
        #expect(try harness.snapshot(layerID: layerID).pixelData == filledPixels)
        #expect(harness.viewModel.workspace.selection.committedShape == nil)
        #expect(harness.viewModel.workspace.selection.inProgressShape == nil)
        #expect(harness.viewModel.selectionOverlayProxy.displayShape == nil)
    }

    @Test
    @MainActor
    func textureFillRespectsTransparentPixelLock() throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID
        try fillOpaqueRect(
            in: harness,
            layerID: layerID,
            originX: 12,
            originY: 12,
            width: 40,
            height: 40,
            color: .init(red: 0.85, green: 0.1, blue: 0.1, alpha: 0.5)
        )
        let before = try harness.snapshot(layerID: layerID).pixelData

        harness.viewModel.toggleLayerTransparentPixelLock(layerID)
        harness.viewModel.setSelectedColor(.init(red: 0.05, green: 0.25, blue: 0.95, alpha: 1))
        harness.beginTextureFill(at: .init(x: 4, y: 60))
        harness.updateTextureFill(to: .init(x: 60, y: 60))
        harness.updateTextureFill(to: .init(x: 60, y: 4))
        harness.updateTextureFill(to: .init(x: 4, y: 4))
        harness.endTextureFill(at: .init(x: 4, y: 60))

        let after = try harness.snapshot(layerID: layerID).pixelData
        let alphaOffsets = stride(from: 3, to: before.count, by: 4)
        #expect(alphaOffsets.allSatisfy { before[$0] == after[$0] })
        #expect(after != before)
    }

    @Test
    @MainActor
    func textureFillDragUpdatesOnlySelectionPreviewUntilCommit() throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID
        let before = try harness.snapshot(layerID: layerID).pixelData

        harness.beginTextureFill(at: .init(x: 8, y: 8))
        harness.updateTextureFill(to: .init(x: 32, y: 8))
        harness.updateTextureFill(to: .init(x: 32, y: 32))

        #expect(try harness.snapshot(layerID: layerID).pixelData == before)
        #expect(harness.viewModel.selectionOverlayProxy.inProgressShape?.kind == .lasso)

        harness.endTextureFill(at: .init(x: 8, y: 32))
        #expect(try harness.snapshot(layerID: layerID).pixelData != before)
    }

    @Test
    @MainActor
    func textureFillBatchedDragUpdatesOnlySelectionPreviewUntilCommit() throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID
        let before = try harness.snapshot(layerID: layerID).pixelData

        harness.beginTextureFill(at: .init(x: 8, y: 8))
        harness.viewModel.updateSelection(
            to: [
                .init(x: 32, y: 8),
                .init(x: 32, y: 32)
            ],
            modifiers: []
        )

        #expect(try harness.snapshot(layerID: layerID).pixelData == before)
        #expect(harness.viewModel.selectionOverlayProxy.inProgressShape?.kind == .lasso)

        harness.endTextureFill(at: .init(x: 8, y: 32))
        #expect(try harness.snapshot(layerID: layerID).pixelData != before)
    }

    @Test
    @MainActor
    func textureFillFinalFieldContainsBrushGaps() throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID
        let anchor = CanvasPoint(x: 8, y: 8)
        let previous = CanvasPoint(x: 32, y: 8)
        let current = CanvasPoint(x: 32, y: 32)

        harness.beginTextureFill(at: anchor)
        harness.updateTextureFill(to: previous)
        harness.updateTextureFill(to: current)
        harness.endTextureFill(at: current)

        var filledInteriorPixels = 0
        var emptyInteriorPixels = 0
        for y in 8...31 {
            for x in 8...31 {
                let point = CanvasPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                guard isPointInsideTriangle(point, anchor, previous, current) else { continue }
                let alpha = try harness.alpha(atX: x, y: y, layerID: layerID)
                if alpha > 0.01 {
                    filledInteriorPixels += 1
                } else {
                    emptyInteriorPixels += 1
                }
            }
        }

        #expect(filledInteriorPixels > 0)
        #expect(emptyInteriorPixels > 0)
    }

    @Test
    @MainActor
    func textureFillFinalReplayPreservesTextureGapsWhenEndAddsNoNewSlice() throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID
        let anchor = CanvasPoint(x: 8, y: 8)
        let previous = CanvasPoint(x: 32, y: 8)
        let current = CanvasPoint(x: 32, y: 32)

        harness.beginTextureFill(at: anchor)
        harness.updateTextureFill(to: previous)
        harness.updateTextureFill(to: current)
        harness.endTextureFill(at: current)

        var filledInteriorPixels = 0
        var emptyInteriorPixels = 0
        for y in 8...31 {
            for x in 8...31 {
                let point = CanvasPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                guard isPointInsideTriangle(point, anchor, previous, current) else { continue }
                let alpha = try harness.alpha(atX: x, y: y, layerID: layerID)
                if alpha > 0.01 {
                    filledInteriorPixels += 1
                } else {
                    emptyInteriorPixels += 1
                }
            }
        }

        #expect(filledInteriorPixels > 0)
        #expect(emptyInteriorPixels > 0)
    }

    @Test
    @MainActor
    func textureFillDistributesMaterialAcrossTheRegionInsteadOfTracingItsBoundary() throws {
        let canvasSize = CanvasSize(width: 512, height: 512)
        let harness = try PixelHistoryHarness(canvasSize: canvasSize)
        let layerID = harness.viewModel.workspace.document.activeLayerID
        harness.viewModel.updateCustomTipMask(makeTextureFillVerticalBandTipMask(resolution: 128))
        harness.viewModel.setTextureFillCoverage(0.72)

        let points = [
            CanvasPoint(x: 70, y: 80),
            CanvasPoint(x: 430, y: 70),
            CanvasPoint(x: 450, y: 420),
            CanvasPoint(x: 80, y: 440)
        ]
        harness.beginTextureFill(at: points[0])
        for point in points.dropFirst() {
            harness.updateTextureFill(to: point)
        }
        harness.endTextureFill(at: points[0])

        let quadrants = [
            (minX: 100, maxX: 230, minY: 100, maxY: 230),
            (minX: 280, maxX: 410, minY: 100, maxY: 230),
            (minX: 100, maxX: 230, minY: 280, maxY: 410),
            (minX: 280, maxX: 410, minY: 280, maxY: 410)
        ]
        for quadrant in quadrants {
            #expect(try regionHasVisiblePixels(
                harness: harness,
                layerID: layerID,
                minX: quadrant.minX,
                maxX: quadrant.maxX,
                minY: quadrant.minY,
                maxY: quadrant.maxY,
                step: 4
            ))
        }
    }

    @Test
    @MainActor
    func textureFillPaintJitterCreatesColorVariationInsideTheMaterialField() throws {
        let harness = try PixelHistoryHarness(canvasSize: .init(width: 512, height: 512))
        let layerID = harness.viewModel.workspace.document.activeLayerID
        harness.viewModel.setSelectedColor(.init(red: 0.76, green: 0.22, blue: 0.12, alpha: 1))
        harness.viewModel.setTextureFillPaintJitterAmount(0.75)

        let anchor = CanvasPoint(x: 90, y: 430)
        let radius = 320.0
        let angles = stride(from: -82.0, through: 8.0, by: 2.0).map {
            $0 * .pi / 180
        }
        let edgePoints = angles.map { angle in
            CanvasPoint(
                x: anchor.x + cos(angle) * radius,
                y: anchor.y + sin(angle) * radius
            )
        }
        harness.beginTextureFill(at: anchor)
        for point in edgePoints {
            harness.updateTextureFill(to: point)
        }
        harness.endTextureFill(at: edgePoints.last ?? anchor)

        var visibleColors: [RGBAColor] = []
        for y in stride(from: 120, through: 410, by: 5) {
            for x in stride(from: 120, through: 410, by: 5) {
                let color = try harness.color(atX: x, y: y, layerID: layerID)
                if color.alpha > 0.5 {
                    visibleColors.append(color)
                }
            }
        }

        #expect(visibleColors.count > 40)
        #expect(rgbChannelSpread(in: visibleColors) > 0.2)
    }

    @Test
    @MainActor
    func textureFillUsesAndFreezesCurrentDrawingBrushTip() throws {
        let squareHarness = try PixelHistoryHarness()
        squareHarness.viewModel.setBrushTipShape(.square)
        let squareLayerID = squareHarness.viewModel.workspace.document.activeLayerID
        squareHarness.beginTextureFill(at: .init(x: 8, y: 8))
        squareHarness.updateTextureFill(to: .init(x: 56, y: 8))
        squareHarness.updateTextureFill(to: .init(x: 56, y: 56))
        squareHarness.endTextureFill(at: .init(x: 8, y: 56))
        let squarePixels = try squareHarness.snapshot(layerID: squareLayerID).pixelData

        let frozenHarness = try PixelHistoryHarness()
        frozenHarness.viewModel.setBrushTipShape(.square)
        let frozenLayerID = frozenHarness.viewModel.workspace.document.activeLayerID
        frozenHarness.beginTextureFill(at: .init(x: 8, y: 8))
        frozenHarness.viewModel.setBrushTipShape(.softRound)
        frozenHarness.updateTextureFill(to: .init(x: 56, y: 8))
        frozenHarness.updateTextureFill(to: .init(x: 56, y: 56))
        frozenHarness.endTextureFill(at: .init(x: 8, y: 56))
        let frozenPixels = try frozenHarness.snapshot(layerID: frozenLayerID).pixelData

        let softHarness = try PixelHistoryHarness()
        softHarness.viewModel.setBrushTipShape(.softRound)
        let softLayerID = softHarness.viewModel.workspace.document.activeLayerID
        softHarness.beginTextureFill(at: .init(x: 8, y: 8))
        softHarness.updateTextureFill(to: .init(x: 56, y: 8))
        softHarness.updateTextureFill(to: .init(x: 56, y: 56))
        softHarness.endTextureFill(at: .init(x: 8, y: 56))
        let softPixels = try softHarness.snapshot(layerID: softLayerID).pixelData

        #expect(frozenPixels == squarePixels)
        #expect(softPixels != squarePixels)
        #expect(stride(from: 3, to: squarePixels.count, by: 4).contains { squarePixels[$0] > 0 })
        #expect(stride(from: 3, to: softPixels.count, by: 4).contains { softPixels[$0] > 0 })
    }

    @Test
    @MainActor
    func textureFillArrangementChangesCommittedSpatialField() throws {
        let directionalHarness = try PixelHistoryHarness()
        directionalHarness.viewModel.setTextureFillArrangement(.directional)
        let directionalLayerID = directionalHarness.viewModel.workspace.document.activeLayerID
        directionalHarness.beginTextureFill(at: .init(x: 8, y: 8))
        directionalHarness.updateTextureFill(to: .init(x: 56, y: 8))
        directionalHarness.updateTextureFill(to: .init(x: 56, y: 56))
        directionalHarness.endTextureFill(at: .init(x: 8, y: 56))
        let directionalPixels = try directionalHarness.snapshot(layerID: directionalLayerID).pixelData

        let radialHarness = try PixelHistoryHarness()
        radialHarness.viewModel.setTextureFillArrangement(.radial)
        let radialLayerID = radialHarness.viewModel.workspace.document.activeLayerID
        radialHarness.beginTextureFill(at: .init(x: 8, y: 8))
        radialHarness.updateTextureFill(to: .init(x: 56, y: 8))
        radialHarness.updateTextureFill(to: .init(x: 56, y: 56))
        radialHarness.endTextureFill(at: .init(x: 8, y: 56))
        let radialPixels = try radialHarness.snapshot(layerID: radialLayerID).pixelData

        #expect(directionalPixels != radialPixels)
        #expect(stride(from: 3, to: directionalPixels.count, by: 4).contains { directionalPixels[$0] > 0 })
        #expect(stride(from: 3, to: radialPixels.count, by: 4).contains { radialPixels[$0] > 0 })
    }

    @Test
    @MainActor
    func textureFillGestureResetsWhenSwitchingTools() throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID

        harness.beginTextureFill(at: .init(x: 8, y: 8))
        harness.updateTextureFill(to: .init(x: 24, y: 8))
        harness.viewModel.selectTool(.brush)
        #expect(harness.viewModel.selectionOverlayProxy.inProgressShape == nil)

        harness.beginTextureFill(at: .init(x: 40, y: 40))
        harness.updateTextureFill(to: .init(x: 56, y: 40))
        harness.updateTextureFill(to: .init(x: 56, y: 56))
        harness.endTextureFill(at: .init(x: 40, y: 56))

        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) < 0.01)
        #expect(
            try regionHasVisiblePixels(
                harness: harness,
                layerID: layerID,
                minX: 42,
                maxX: 56,
                minY: 42,
                maxY: 56,
                step: 2
            )
        )
    }

    @Test
    @MainActor
    func textureFillGestureResetsWhenActiveLayerIsLocked() throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID

        harness.beginTextureFill(at: .init(x: 8, y: 8))
        harness.updateTextureFill(to: .init(x: 24, y: 8))
        harness.viewModel.toggleLayerLock(layerID)
        #expect(harness.viewModel.selectionOverlayProxy.inProgressShape == nil)

        harness.viewModel.toggleLayerLock(layerID)
        harness.beginTextureFill(at: .init(x: 40, y: 40))
        harness.updateTextureFill(to: .init(x: 56, y: 40))
        harness.updateTextureFill(to: .init(x: 56, y: 56))
        harness.endTextureFill(at: .init(x: 40, y: 56))

        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) < 0.01)
        #expect(
            try regionHasVisiblePixels(
                harness: harness,
                layerID: layerID,
                minX: 42,
                maxX: 56,
                minY: 42,
                maxY: 56,
                step: 2
            )
        )
    }

    @Test
    @MainActor
    func canvasCropCropsEveryLayerAndSupportsUndoRedo() throws {
        let harness = try PixelHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let lowerLayerID = harness.viewModel.workspace.document.activeLayerID
        let upperLayerID = harness.addLayer()
        let red = RGBAColor(red: 0.9, green: 0.1, blue: 0.05, alpha: 1)
        let blue = RGBAColor(red: 0.05, green: 0.2, blue: 0.9, alpha: 1)

        try fillOpaqueRect(
            in: harness,
            layerID: lowerLayerID,
            originX: 20,
            originY: 12,
            width: 4,
            height: 4,
            color: red
        )
        try fillOpaqueRect(
            in: harness,
            layerID: upperLayerID,
            originX: 34,
            originY: 26,
            width: 4,
            height: 4,
            color: blue
        )

        harness.viewModel.selectTool(.canvasCrop)
        harness.viewModel.beginCanvasCrop(at: .init(x: 16, y: 8), handleRadius: 2)
        harness.viewModel.endCanvasCrop(at: .init(x: 48, y: 40))
        harness.viewModel.applyCanvasCrop()

        #expect(harness.viewModel.workspace.document.canvasSize == .init(width: 32, height: 32))
        #expect(try harness.color(atX: 4, y: 4, layerID: lowerLayerID).red > 0.8)
        #expect(try harness.color(atX: 18, y: 18, layerID: upperLayerID).blue > 0.8)
        #expect(harness.viewModel.canUndo)

        harness.viewModel.undo()
        #expect(harness.viewModel.workspace.document.canvasSize == .init(width: 64, height: 64))
        #expect(try harness.color(atX: 20, y: 12, layerID: lowerLayerID).red > 0.8)
        #expect(try harness.color(atX: 34, y: 26, layerID: upperLayerID).blue > 0.8)

        harness.viewModel.redo()
        #expect(harness.viewModel.workspace.document.canvasSize == .init(width: 32, height: 32))
        #expect(try harness.color(atX: 4, y: 4, layerID: lowerLayerID).red > 0.8)
        #expect(try harness.color(atX: 18, y: 18, layerID: upperLayerID).blue > 0.8)
    }

    @Test
    @MainActor
    func canvasCropCanExpandEveryEdgeWithTransparentPaddingAndUndoRedo() throws {
        let harness = try PixelHistoryHarness(canvasSize: .init(width: 32, height: 32))
        let layerID = harness.viewModel.workspace.document.activeLayerID
        try fillOpaqueRect(
            in: harness,
            layerID: layerID,
            originX: 4,
            originY: 6,
            width: 4,
            height: 4,
            color: .init(red: 0.85, green: 0.15, blue: 0.05, alpha: 1)
        )

        harness.viewModel.selectTool(.canvasCrop)
        harness.viewModel.beginCanvasCrop(at: .init(x: 16, y: 16), handleRadius: 2)
        harness.viewModel.endCanvasCrop(at: .init(x: 16, y: 16))
        harness.viewModel.beginCanvasCrop(at: .init(x: 0, y: 0), handleRadius: 2)
        harness.viewModel.endCanvasCrop(at: .init(x: -8, y: -4))
        harness.viewModel.beginCanvasCrop(at: .init(x: 32, y: 32), handleRadius: 2)
        harness.viewModel.endCanvasCrop(at: .init(x: 40, y: 40))
        harness.viewModel.applyCanvasCrop()

        #expect(harness.viewModel.workspace.document.canvasSize == .init(width: 48, height: 44))
        #expect(try harness.alpha(atX: 0, y: 0, layerID: layerID) < 0.01)
        #expect(try harness.color(atX: 12, y: 10, layerID: layerID).red > 0.8)
        #expect(try harness.alpha(atX: 47, y: 43, layerID: layerID) < 0.01)

        harness.viewModel.undo()
        #expect(harness.viewModel.workspace.document.canvasSize == .init(width: 32, height: 32))
        #expect(try harness.color(atX: 4, y: 6, layerID: layerID).red > 0.8)

        harness.viewModel.redo()
        #expect(harness.viewModel.workspace.document.canvasSize == .init(width: 48, height: 44))
        #expect(try harness.color(atX: 12, y: 10, layerID: layerID).red > 0.8)
    }

    @Test
    @MainActor
    func textureFillGestureCancelsCleanly() throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID

        harness.beginTextureFill(at: .init(x: 8, y: 8))
        harness.updateTextureFill(to: .init(x: 24, y: 8))
        harness.viewModel.cancelCanvasToolInteraction()

        harness.beginTextureFill(at: .init(x: 40, y: 40))
        harness.updateTextureFill(to: .init(x: 56, y: 40))
        harness.updateTextureFill(to: .init(x: 56, y: 56))
        harness.endTextureFill(at: .init(x: 40, y: 56))

        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) < 0.01)
        #expect(
            try regionHasVisiblePixels(
                harness: harness,
                layerID: layerID,
                minX: 42,
                maxX: 56,
                minY: 42,
                maxY: 56,
                step: 2
            )
        )
    }

    @Test
    @MainActor
    func textureFillImportedTipBlocksTipLibraryDeletion() throws {
        let harness = try PixelHistoryHarness()
        let maskData = makeTextureFillLibraryMask(resolution: 256)
        let assetID = BrushTipImageAssetID(maskData: maskData)

        harness.bootstrap.workspaceStore.updateTipImageLibrary { library in
            _ = library.upsertImportedItem(
                id: assetID,
                sourceInfo: .init(sourceLabel: "Test Tip", pixelWidth: 256, pixelHeight: 256),
                maskData: maskData
            )
        }

        harness.viewModel.applyTextureFillTipImageLibraryItem(assetID)

        let tipSettings = harness.viewModel.workspace.toolSession.textureFillTip
        #expect(tipSettings.sourceSemantic == .importedImage)
        #expect(tipSettings.tipAssetID == assetID)
        #expect(tipSettings.customTipMaskData == maskData)

        let summary = harness.viewModel.tipImageLibraryReferenceSummary(for: assetID)
        #expect(summary.currentTextureFillUsesImportedTip)
        #expect(harness.viewModel.deleteTipImageLibraryItem(assetID) == false)
    }

    @Test
    @MainActor
    func textureFillImportedMaterialProducesAVisibleNonSolidField() throws {
        let harness = try PixelHistoryHarness()
        let gradientMask = makeTextureFillGradientLibraryMask(resolution: 256)
        let assetID = BrushTipImageAssetID(maskData: gradientMask)

        harness.bootstrap.workspaceStore.updateTipImageLibrary { library in
            _ = library.upsertImportedItem(
                id: assetID,
                sourceInfo: .init(sourceLabel: "Gradient Tip", pixelWidth: 64, pixelHeight: 64),
                maskData: gradientMask
            )
        }
        harness.viewModel.applyTextureFillTipImageLibraryItem(assetID)
        harness.viewModel.setTextureFillCoverage(0.72)

        harness.beginTextureFill(at: .init(x: 8, y: 8))
        harness.updateTextureFill(to: .init(x: 56, y: 8))
        harness.updateTextureFill(to: .init(x: 56, y: 56))
        harness.endTextureFill(at: .init(x: 8, y: 56))

        let layerID = harness.viewModel.workspace.document.activeLayerID
        var visible = 0
        var empty = 0
        for y in 10...54 {
            for x in 10...54 {
                let alpha = try harness.alpha(atX: x, y: y, layerID: layerID)
                if alpha > 0.01 { visible += 1 } else { empty += 1 }
            }
        }
        #expect(visible > 0)
        #expect(empty > 0)
    }

    @Test
    @MainActor
    func textureFillImportedDragDefersPixelsUntilCommit() throws {
        let harness = try PixelHistoryHarness()
        let gradientMask = makeTextureFillGradientLibraryMask(resolution: 256)
        let assetID = BrushTipImageAssetID(maskData: gradientMask)

        harness.bootstrap.workspaceStore.updateTipImageLibrary { library in
            _ = library.upsertImportedItem(
                id: assetID,
                sourceInfo: .init(sourceLabel: "Gradient Tip", pixelWidth: 64, pixelHeight: 64),
                maskData: gradientMask
            )
        }
        harness.viewModel.applyTextureFillTipImageLibraryItem(assetID)

        let layerID = harness.viewModel.workspace.document.activeLayerID
        let anchor = CanvasPoint(x: 8, y: 8)
        let previous = CanvasPoint(x: 56, y: 8)
        let current = CanvasPoint(x: 56, y: 56)

        harness.beginTextureFill(at: anchor)
        harness.updateTextureFill(to: previous)
        harness.updateTextureFill(to: current)

        let samplePoints = [
            (x: 20, y: 12),
            (x: 28, y: 16),
            (x: 36, y: 20),
            (x: 44, y: 24)
        ]

        let previewSamples = try samplePoints.map { point in
            try harness.alpha(atX: point.x, y: point.y, layerID: layerID)
        }
        #expect(previewSamples.allSatisfy { $0 < 0.01 })
        #expect(harness.viewModel.selectionOverlayProxy.inProgressShape?.kind == .lasso)

        harness.endTextureFill(at: current)

        #expect(try regionHasVisiblePixels(
            harness: harness,
            layerID: layerID,
            minX: 10,
            maxX: 54,
            minY: 10,
            maxY: 54,
            step: 2
        ))
    }

    @Test
    @MainActor
    func pixelOperationsAcrossLayersPreserveUntouchedLayerContent() throws {
        let harness = try PixelHistoryHarness()
        let firstLayerID = harness.viewModel.workspace.document.layers[0].id
        let secondLayerID = harness.addLayer()

        try harness.drawBrushStroke(on: firstLayerID, points: [
            .init(location: .init(x: 10, y: 10), pressure: 1),
            .init(location: .init(x: 18, y: 18), pressure: 1)
        ])
        try harness.drawBrushStroke(on: secondLayerID, points: [
            .init(location: .init(x: 42, y: 42), pressure: 1),
            .init(location: .init(x: 50, y: 50), pressure: 1)
        ])

        harness.viewModel.selectLayer(firstLayerID)
        harness.makeLassoSelection([
            .init(x: 8, y: 8),
            .init(x: 24, y: 8),
            .init(x: 24, y: 24),
            .init(x: 8, y: 24),
            .init(x: 8, y: 8)
        ])
        harness.viewModel.eraseLassoContents()

        harness.viewModel.selectLayer(secondLayerID)
        harness.makeLassoSelection([
            .init(x: 36, y: 36),
            .init(x: 56, y: 36),
            .init(x: 56, y: 56),
            .init(x: 36, y: 56),
            .init(x: 36, y: 36)
        ])
        harness.viewModel.fillSelectionContents()

        harness.viewModel.undo()
        #expect(try harness.alpha(atX: 16, y: 16, layerID: firstLayerID) < 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)

        harness.viewModel.redo()
        #expect(try harness.alpha(atX: 16, y: 16, layerID: firstLayerID) < 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)
    }

    @Test
    @MainActor
    func fillAtPointAcrossLayersPreservesUntouchedLayerContent() throws {
        let harness = try PixelHistoryHarness()
        let firstLayerID = harness.viewModel.workspace.document.layers[0].id
        let secondLayerID = harness.addLayer()

        harness.viewModel.selectLayer(firstLayerID)
        harness.viewModel.fillAtPoint(.init(x: 12, y: 12))

        harness.viewModel.selectLayer(secondLayerID)
        harness.viewModel.fillAtPoint(.init(x: 46, y: 46))

        harness.viewModel.undo()
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) > 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) < 0.01)

        harness.viewModel.redo()
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) > 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)
    }

    @Test
    @MainActor
    func pixelOperationTopologyFenceKeepsUndoRedoChainCorrect() throws {
        let harness = try PixelHistoryHarness()
        let initialLayerCount = harness.viewModel.workspace.document.layers.count
        let firstLayerID = harness.viewModel.workspace.document.layers[0].id
        let secondLayerID = harness.addLayer()
        let layerCountAfterSecondLayer = initialLayerCount + 1

        try harness.drawBrushStroke(on: firstLayerID, points: [
            .init(location: .init(x: 10, y: 10), pressure: 1),
            .init(location: .init(x: 18, y: 18), pressure: 1)
        ])

        harness.viewModel.selectLayer(secondLayerID)
        harness.makeLassoSelection([
            .init(x: 40, y: 40),
            .init(x: 56, y: 40),
            .init(x: 56, y: 56),
            .init(x: 40, y: 56),
            .init(x: 40, y: 40)
        ])
        harness.viewModel.fillSelectionContents()

        let thirdLayerID = harness.addLayer()
#if DEBUG
        #expect(harness.bootstrap.historyController.debugUndoEntryModes.last == .full)
#endif

        harness.viewModel.undo()
        #expect(harness.viewModel.workspace.document.layers.count == layerCountAfterSecondLayer)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)

        harness.viewModel.undo()
        #expect(harness.viewModel.workspace.document.layers.count == layerCountAfterSecondLayer)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) < 0.01)

        harness.viewModel.redo()
        #expect(harness.viewModel.workspace.document.layers.count == layerCountAfterSecondLayer)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)

        harness.viewModel.redo()
        #expect(harness.viewModel.workspace.document.layers.count == layerCountAfterSecondLayer + 1)
        #expect(try harness.alpha(atX: 12, y: 12, layerID: thirdLayerID) < 0.01)
    }

    @Test
    @MainActor
    func fillAtPointTopologyFenceKeepsUndoRedoChainCorrect() throws {
        let harness = try PixelHistoryHarness()
        let initialLayerCount = harness.viewModel.workspace.document.layers.count
        let firstLayerID = harness.viewModel.workspace.document.layers[0].id
        let secondLayerID = harness.addLayer()
        let layerCountAfterSecondLayer = initialLayerCount + 1

        harness.viewModel.selectLayer(firstLayerID)
        harness.viewModel.fillAtPoint(.init(x: 12, y: 12))
        harness.viewModel.selectLayer(secondLayerID)
        harness.viewModel.fillAtPoint(.init(x: 46, y: 46))

        let thirdLayerID = harness.addLayer()
#if DEBUG
        #expect(harness.bootstrap.historyController.debugUndoEntryModes.last == .full)
#endif

        harness.viewModel.undo()
        #expect(harness.viewModel.workspace.document.layers.count == layerCountAfterSecondLayer)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)

        harness.viewModel.undo()
        #expect(harness.viewModel.workspace.document.layers.count == layerCountAfterSecondLayer)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) < 0.01)

        harness.viewModel.redo()
        #expect(harness.viewModel.workspace.document.layers.count == layerCountAfterSecondLayer)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)

        harness.viewModel.redo()
        #expect(harness.viewModel.workspace.document.layers.count == layerCountAfterSecondLayer + 1)
        #expect(try harness.alpha(atX: 12, y: 12, layerID: thirdLayerID) < 0.01)
    }

    @Test
    @MainActor
    func selectionFillUndoPushesSymmetricDirtyEntryOntoRedoStack() throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.addLayer()
        harness.viewModel.selectLayer(layerID)

        harness.makeLassoSelection([
            .init(x: 8, y: 8),
            .init(x: 24, y: 8),
            .init(x: 24, y: 24),
            .init(x: 8, y: 24),
            .init(x: 8, y: 8)
        ])
        harness.viewModel.fillSelectionContents()

        harness.viewModel.undo()
        let redoMode = try #require(harness.bootstrap.historyController.debugRedoEntryModes.last)
        switch redoMode {
        case .full:
            Issue.record("Expected symmetric dirty current-entry capture for applyPixelOperation in redo stack")
        case .inPlaceChangedLayers(_, let changedLayerIDs):
            #expect(Set(changedLayerIDs) == [layerID])
        case .workspaceOnly, .metadataOnly:
            Issue.record("Expected pixel operation to use pixel history")
        }
    }

    @Test
    @MainActor
    func dirtyUndoRedoExplicitlyInvalidateNavigatorPreview() throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.addLayer()
        harness.viewModel.selectLayer(layerID)

        harness.makeLassoSelection([
            .init(x: 8, y: 8),
            .init(x: 24, y: 8),
            .init(x: 24, y: 24),
            .init(x: 8, y: 24),
            .init(x: 8, y: 8)
        ])
        harness.viewModel.fillSelectionContents()

        harness.viewModel.setNavigatorPreviewVisible(true)
        harness.viewModel.refreshNavigatorPreviewNow()
        let revisionBeforeUndo = harness.viewModel.navigatorPreviewProxy.redrawRevision

        harness.viewModel.undo()
        #expect(
            harness.viewModel.navigatorPreviewProxy.redrawRevision > revisionBeforeUndo ||
                harness.viewModel.debugNavigatorPreviewHasPendingRefresh
        )

        harness.viewModel.refreshNavigatorPreviewNow()
        let revisionBeforeRedo = harness.viewModel.navigatorPreviewProxy.redrawRevision

        harness.viewModel.redo()
        #expect(
            harness.viewModel.navigatorPreviewProxy.redrawRevision > revisionBeforeRedo ||
                harness.viewModel.debugNavigatorPreviewHasPendingRefresh
        )
    }

    @Test
    @MainActor
    func advancedBucketFillUsesToleranceAndGlobalMatchingWithUndo() throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID
        try fillOpaqueRect(
            in: harness, layerID: layerID,
            originX: 4, originY: 4, width: 12, height: 12,
            color: .init(red: 0.40, green: 0.40, blue: 0.40, alpha: 1)
        )
        try fillOpaqueRect(
            in: harness, layerID: layerID,
            originX: 20, originY: 4, width: 12, height: 12,
            color: .init(red: 0.42, green: 0.42, blue: 0.42, alpha: 1)
        )
        harness.viewModel.setSelectedColor(.init(red: 1, green: 0, blue: 0, alpha: 1))
        harness.viewModel.setFillTolerance(0.04)
        harness.viewModel.setFillContiguous(false)
        harness.viewModel.fillAtPoint(.init(x: 8, y: 8))

        #expect(try harness.color(atX: 8, y: 8, layerID: layerID).red > 0.9)
        #expect(try harness.color(atX: 24, y: 8, layerID: layerID).red > 0.9)

        harness.viewModel.undo()
        #expect(try harness.color(atX: 8, y: 8, layerID: layerID).red < 0.5)
        #expect(try harness.color(atX: 24, y: 8, layerID: layerID).red < 0.5)
    }

    @Test
    @MainActor
    func selectionRefinementAndPreciseTransformHaveRuntimeEntryPoints() async throws {
        let harness = try PixelHistoryHarness()
        harness.makeRectangleSelection(minX: 16, minY: 16, maxX: 32, maxY: 32)
        harness.viewModel.expandSelection(radiusPixels: 4)
        try await waitForCondition { !harness.viewModel.isRefiningSelection }
        let expanded = try #require(harness.viewModel.workspace.selection.committedShape)
        #expect(expanded.contains(.init(x: 13, y: 24)))

        harness.viewModel.selectTool(.freeTransform)
        var precise = try #require(harness.viewModel.preciseFreeTransformInput)
        precise.centerX += 5
        precise.rotationDegrees = 15
        harness.viewModel.setPreciseFreeTransformInput(precise)
        #expect(abs(harness.viewModel.freeTransformPreview.translation.x - 5) < 0.001)
        #expect(abs(harness.viewModel.freeTransformPreview.rotationRadians - (.pi / 12)) < 0.001)
    }

    @Test
    @MainActor
    func freeTransformFlipButtonsMirrorSelectedPixelsAndUndoRestoresThem() async throws {
        let harness = try PixelHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let layerID = harness.viewModel.workspace.document.activeLayerID
        try fillOpaqueRect(
            in: harness,
            layerID: layerID,
            originX: 16,
            originY: 16,
            width: 16,
            height: 16,
            color: .init(red: 1, green: 0, blue: 0, alpha: 1)
        )
        try fillOpaqueRect(
            in: harness,
            layerID: layerID,
            originX: 32,
            originY: 32,
            width: 16,
            height: 16,
            color: .init(red: 0, green: 0, blue: 1, alpha: 1)
        )
        harness.makeRectangleSelection(minX: 16, minY: 16, maxX: 48, maxY: 48)
        harness.viewModel.selectTool(.freeTransform)

        harness.viewModel.flipFreeTransformHorizontally()
        #expect(harness.viewModel.freeTransformPreview.scaleX < 0)
        #expect(harness.viewModel.freeTransformPreview.scaleY > 0)
        harness.viewModel.flipFreeTransformVertically()
        #expect(harness.viewModel.freeTransformPreview.scaleX < 0)
        #expect(harness.viewModel.freeTransformPreview.scaleY < 0)

        harness.viewModel.applySelectionTransform()
        try await harness.waitForTransformCommitToFinish()

        let mirroredTopLeft = try harness.color(atX: 20, y: 20, layerID: layerID)
        let mirroredBottomRight = try harness.color(atX: 44, y: 44, layerID: layerID)
        #expect(mirroredTopLeft.blue > 0.9)
        #expect(mirroredTopLeft.red < 0.1)
        #expect(mirroredBottomRight.red > 0.9)
        #expect(mirroredBottomRight.blue < 0.1)

        harness.viewModel.undo()
        let restoredTopLeft = try harness.color(atX: 20, y: 20, layerID: layerID)
        let restoredBottomRight = try harness.color(atX: 44, y: 44, layerID: layerID)
        #expect(restoredTopLeft.red > 0.9)
        #expect(restoredBottomRight.blue > 0.9)
    }

    @Test
    @MainActor
    func multicolorGradientRendersMiddleStopAndSupportsUndo() async throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.addLayer()
        let initialStops = harness.viewModel.displayedGradientSettings.stops
        harness.viewModel.updateGradientStop(
            id: initialStops[0].id,
            position: 0,
            color: .init(red: 1, green: 0, blue: 0, alpha: 1)
        )
        harness.viewModel.updateGradientStop(
            id: initialStops[1].id,
            position: 1,
            color: .init(red: 0, green: 0, blue: 1, alpha: 1)
        )
        harness.viewModel.addGradientStop()
        let middle = try #require(
            harness.viewModel.displayedGradientSettings.stops.first { stop in
                stop.id != initialStops[0].id && stop.id != initialStops[1].id
            }
        )
        harness.viewModel.updateGradientStop(
            id: middle.id,
            position: 0.5,
            color: .init(red: 0, green: 1, blue: 0, alpha: 1)
        )

        harness.viewModel.selectLayer(layerID)
        harness.viewModel.selectTool(.linearGradient)
        harness.viewModel.beginGradientDrag(at: .init(x: 8, y: 24))
        harness.viewModel.updateGradientDrag(to: .init(x: 56, y: 24))
        harness.viewModel.endGradientDrag(at: .init(x: 56, y: 24))
        harness.viewModel.applyActiveGradientSession()
        try await harness.waitForGradientCommitToFinish()

        let midpoint = try harness.color(atX: 32, y: 24, layerID: layerID)
        #expect(midpoint.green > midpoint.red)
        #expect(midpoint.green > midpoint.blue)
        harness.viewModel.undo()
        #expect(try harness.alpha(atX: 32, y: 24, layerID: layerID) < 0.01)
    }

    @Test
    @MainActor
    func generatorDirectStrokeAcceptsSinglePointInputPackets() throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID
        harness.viewModel.setGeneratorKind(.automaticLines)
        harness.viewModel.setGeneratorDrift(0)
        harness.viewModel.setGeneratorDensity(0)
        harness.viewModel.setGeneratorBranch(0)
        let historyCountBeforeStroke = harness.viewModel.visibleHistoryTimeline.currentAppliedEntryCount
        harness.viewModel.beginStrokeIfNeeded(paintVariationSeed: 42)
        for x in stride(from: 12, through: 52, by: 4) {
            harness.viewModel.applyStroke(samples: [
                .init(location: .init(x: Double(x), y: 32), pressure: 1)
            ])
        }
        harness.viewModel.endStroke()
        _ = harness.viewModel.flushBrushEditingBoundary(reason: "generator-direct-test")

        #expect(
            harness.viewModel.visibleHistoryTimeline.currentAppliedEntryCount
                == historyCountBeforeStroke + 1
        )

        let snapshot = try harness.snapshot(layerID: layerID)
        #expect(snapshot.pixelData.enumerated().contains { index, byte in
            index % 4 == 3 && byte > 0
        })
    }

    @Test
    @MainActor
    func visibleHistoryPreviewCancelsBackToOriginalPixels() throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID
        try harness.drawBrushStroke(
            on: layerID,
            points: [.init(location: .init(x: 16, y: 24), pressure: 1)]
        )
        try harness.drawBrushStroke(
            on: layerID,
            points: [.init(location: .init(x: 48, y: 24), pressure: 1)]
        )
        harness.viewModel.prepareVisibleHistoryPresentation()
        harness.viewModel.cancelVisibleHistoryPreview()
        let paintOnlyHistoryCount = harness.viewModel.visibleHistoryTimeline.currentAppliedEntryCount
        harness.makeRectangleSelection(minX: 10, minY: 10, maxX: 54, maxY: 42)
        let originSelection = try #require(harness.viewModel.workspace.selection.committedShape)
        harness.viewModel.prepareVisibleHistoryPresentation()
        let originCount = harness.viewModel.visibleHistoryTimeline.currentAppliedEntryCount
        #expect(originCount >= 2)
        #expect(try harness.alpha(atX: 48, y: 24, layerID: layerID) > 0)

        harness.viewModel.previewVisibleHistory(toAppliedEntryCount: paintOnlyHistoryCount - 1)
        #expect(try harness.alpha(atX: 48, y: 24, layerID: layerID) < 0.01)
        #expect(harness.viewModel.visibleHistoryPreviewTargetCount == paintOnlyHistoryCount - 1)

        harness.viewModel.cancelVisibleHistoryPreview()
        #expect(try harness.alpha(atX: 48, y: 24, layerID: layerID) > 0)
        #expect(harness.viewModel.visibleHistoryTimeline.currentAppliedEntryCount == originCount)
        #expect(harness.viewModel.visibleHistoryPreviewTargetCount == nil)
        #expect(harness.viewModel.workspace.selection.committedShape == originSelection)
    }

    @Test
    @MainActor
    func generatorRegionModeRearmsAfterSuccessfulGeneration() async throws {
        let harness = try PixelHistoryHarness()
        harness.viewModel.setGeneratorKind(.elasticWhip)
        harness.viewModel.beginGeneratorRegionSelection()
        #expect(harness.viewModel.isGeneratorRegionSelectionArmed)
        #expect(harness.viewModel.workspace.toolSession.activeTool == .lassoSelection)

        let regionPoints: [CanvasPoint] = [
            .init(x: 10, y: 10),
            .init(x: 54, y: 10),
            .init(x: 54, y: 54),
            .init(x: 10, y: 54),
            .init(x: 10, y: 10),
        ]
        harness.viewModel.beginSelection(kind: .lasso, at: regionPoints[0])
        for point in regionPoints.dropFirst().dropLast() {
            harness.viewModel.updateSelection(to: point)
        }
        harness.viewModel.commitSelection(at: regionPoints.last!)
        try await waitForCondition {
            harness.viewModel.isGeneratorRegionSelectionArmed
                && harness.viewModel.workspace.toolSession.activeTool == .lassoSelection
                && harness.viewModel.workspace.selection.committedShape == nil
        }

        #expect(!harness.viewModel.isGeneratorStrokeModeEnabled)
        #expect(harness.viewModel.isGeneratorRegionSelectionArmed)
    }

}

@MainActor
private struct PixelHistoryHarness {
    let bootstrap: AppBootstrap
    let viewModel: WorkspaceViewModel

    init(canvasSize: CanvasSize = .init(width: 64, height: 64)) throws {
        guard let metalContext = MetalDeviceContext() else {
            throw PixelHistoryHarnessError.metalUnavailable
        }
        let workspaceStore = WorkspaceStore(state: .stageOneDefault)
        workspaceStore.updateDocument { document in
            document.canvasSize = canvasSize
        }
        let bootstrap = try AppBootstrap(
            workspaceStore: workspaceStore,
            metalContext: metalContext,
            layerSurfaceStore: StageOneLayerSurfaceStore()
        )
        let viewModel = WorkspaceViewModel(bootstrap: bootstrap, installsZoomKeyboardMonitor: false)
        self.bootstrap = bootstrap
        self.viewModel = viewModel
    }

    func addLayer() -> LayerID {
        viewModel.addLayer()
        return viewModel.workspace.document.activeLayerID
    }

    func makeLassoSelection(
        _ points: [CanvasPoint],
        modifiers: NSEvent.ModifierFlags = []
    ) {
        guard let first = points.first, points.count > 1 else { return }
        viewModel.selectTool(.lassoSelection)
        viewModel.beginSelection(kind: .lasso, at: first, modifiers: modifiers)
        for point in points.dropFirst().dropLast() {
            viewModel.updateSelection(to: point, modifiers: modifiers)
        }
        viewModel.commitSelection(at: points.last ?? first, modifiers: modifiers)
    }

    func makeRectangleSelection(
        minX: Double,
        minY: Double,
        maxX: Double,
        maxY: Double,
        modifiers: NSEvent.ModifierFlags = []
    ) {
        let start = CanvasPoint(x: minX, y: minY)
        let end = CanvasPoint(x: maxX, y: maxY)
        viewModel.selectTool(.rectangleSelection)
        viewModel.beginSelection(kind: .rectangle, at: start, modifiers: modifiers)
        viewModel.updateSelection(to: end, modifiers: modifiers)
        viewModel.commitSelection(at: end, modifiers: modifiers)
    }

    func beginTextureFill(at point: CanvasPoint) {
        viewModel.selectTool(.textureFill)
        _ = viewModel.handleSelectionMouseDown(at: point, modifiers: [])
    }

    func updateTextureFill(to point: CanvasPoint) {
        viewModel.updateSelection(to: point)
    }

    func endTextureFill(at point: CanvasPoint) {
        viewModel.commitSelection(at: point)
    }

    func drawBrushStroke(on layerID: LayerID, points: [CanvasStrokeSample]) throws {
        viewModel.selectLayer(layerID)
        viewModel.selectTool(.brush)
        viewModel.beginStrokeIfNeeded()
        viewModel.applyStroke(samples: points)
        viewModel.endStroke()
        try flushPendingPixelHistoryBrushWork(viewModel: viewModel, metalContext: bootstrap.metalContext)
        viewModel.opportunisticallyDrainBrushCommits(hadLiveBrushWorkThisFrame: false)
    }

    func alpha(atX x: Int, y: Int, layerID: LayerID) throws -> Float {
        try color(atX: x, y: y, layerID: layerID).alpha
    }

    func color(atX x: Int, y: Int, layerID: LayerID) throws -> RGBAColor {
        guard
            let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: layerID),
            let texture = bootstrap.layerSurfaceStore.texture(for: surfaceID)
        else {
            throw PixelHistoryHarnessError.textureUnavailable
        }
        return try bootstrap.textureSerializer.samplePixel(texture: texture, x: x, y: y)
    }

    func snapshot(layerID: LayerID) throws -> LayerTextureSnapshot {
        guard
            let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: layerID),
            let texture = bootstrap.layerSurfaceStore.texture(for: surfaceID)
        else {
            throw PixelHistoryHarnessError.textureUnavailable
        }
        return try bootstrap.textureSerializer.snapshot(texture: texture)
    }

    func waitForGradientCommitToFinish(timeoutIterations: Int = 80) async throws {
        for _ in 0..<timeoutIterations {
            if !viewModel.isApplyingGradientCommit {
                return
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }

        throw PixelHistoryHarnessError.gradientCommitTimeout
    }

    func waitForTransformCommitToFinish(timeoutIterations: Int = 120) async throws {
        for _ in 0..<timeoutIterations {
            if !viewModel.isApplyingTransformCommit {
                return
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }

        throw PixelHistoryHarnessError.transformCommitTimeout
    }

    func waitForFeatheredSelection(
        sampleX: Int,
        sampleY: Int,
        timeoutIterations: Int = 200
    ) async throws -> SelectionShape {
        for _ in 0..<timeoutIterations {
            if
                let selection = viewModel.workspace.selection.committedShape,
                let maskData = selection.maskData,
                let alpha = maskData.alphaByte(at: (sampleY * maskData.canvasWidth) + sampleX),
                alpha > 0,
                alpha < 255
            {
                return selection
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }

        throw PixelHistoryHarnessError.selectionFeatherTimeout
    }
}

@MainActor
private func flushPendingPixelHistoryBrushWork(
    viewModel: WorkspaceViewModel,
    metalContext: MetalDeviceContext
) throws {
    guard let commandBuffer = metalContext.commandQueue.makeCommandBuffer() else {
        throw PixelHistoryHarnessError.commandBufferUnavailable
    }
    _ = viewModel.flushPendingBrushWork(into: commandBuffer)
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
}

private enum PixelHistoryHarnessError: Error {
    case metalUnavailable
    case textureUnavailable
    case commandBufferUnavailable
    case gradientCommitTimeout
    case transformCommitTimeout
    case selectionFeatherTimeout
}

@MainActor
private func makeCanvasKeyEvent(
    type: NSEvent.EventType,
    characters: String,
    charactersIgnoringModifiers: String,
    modifiers: NSEvent.ModifierFlags,
    keyCode: UInt16
) -> NSEvent {
    NSEvent.keyEvent(
        with: type,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: charactersIgnoringModifiers,
        isARepeat: false,
        keyCode: keyCode
    )!
}

@MainActor
private func fillOpaqueRect(
    in harness: PixelHistoryHarness,
    layerID: LayerID,
    originX: Int,
    originY: Int,
    width: Int,
    height: Int,
    color: RGBAColor
) throws {
    guard
        let surfaceID = harness.bootstrap.layerSurfaceStore.surfaceID(for: layerID),
        let texture = harness.bootstrap.layerSurfaceStore.texture(for: surfaceID)
    else {
        throw PixelHistoryHarnessError.textureUnavailable
    }

    let pixelCount = width * height
    let bgraPixel = [
        UInt8((color.blue * color.alpha * 255).rounded()),
        UInt8((color.green * color.alpha * 255).rounded()),
        UInt8((color.red * color.alpha * 255).rounded()),
        UInt8((color.alpha * 255).rounded())
    ]
    var bytes = [UInt8]()
    bytes.reserveCapacity(pixelCount * 4)
    for _ in 0..<pixelCount {
        bytes.append(contentsOf: bgraPixel)
    }

    let snapshot = LayerTextureSnapshot(
        width: width,
        height: height,
        bytesPerRow: width * 4,
        pixelData: Data(bytes)
    )
    try harness.bootstrap.textureSerializer.restore(
        snapshot: snapshot,
        into: texture,
        destinationX: originX,
        destinationY: originY
    )
    harness.bootstrap.layerSurfaceStore.markContentUnknown(for: layerID)
}

@MainActor
private func regionHasVisiblePixels(
    harness: PixelHistoryHarness,
    layerID: LayerID,
    minX: Int,
    maxX: Int,
    minY: Int,
    maxY: Int,
    step: Int = 4
) throws -> Bool {
    var y = minY
    while y <= maxY {
        var x = minX
        while x <= maxX {
            if try harness.alpha(atX: x, y: y, layerID: layerID) > 0.05 {
                return true
            }
            x += step
        }
        y += step
    }
    return false
}

private func makeTextureFillLibraryMask(resolution: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: resolution * resolution)
    let minX = resolution / 4
    let maxX = resolution * 3 / 4
    let minY = resolution / 4
    let maxY = resolution * 3 / 4
    for y in minY..<maxY {
        for x in minX..<maxX {
            bytes[(y * resolution) + x] = 255
        }
    }
    return Data(bytes)
}

private func makeTextureFillGradientLibraryMask(resolution: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: resolution * resolution)
    let denominator = max(resolution - 1, 1)

    for y in 0..<resolution {
        for x in 0..<resolution {
            let alpha = UInt8((Double(x) / Double(denominator) * 255).rounded())
            bytes[(y * resolution) + x] = alpha
        }
    }

    return Data(bytes)
}

private func makeTextureFillVerticalBandTipMask(resolution: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: resolution * resolution)
    let bandWidth = max(resolution / 20, 3)
    let bandCenters = [18, 43, 69, 96, 116].map { $0 * resolution / 128 }
    for centerX in bandCenters {
        let minX = max(centerX - bandWidth / 2, 0)
        let maxX = min(centerX + bandWidth / 2, resolution - 1)
        for y in 0..<resolution {
            for x in minX...maxX {
                bytes[(y * resolution) + x] = 255
            }
        }
    }
    return Data(bytes)
}

private func binaryTransitions(in values: [Bool]) -> Int {
    zip(values, values.dropFirst()).reduce(into: 0) { count, pair in
        if pair.0 != pair.1 {
            count += 1
        }
    }
}

private func rgbChannelSpread(in colors: [RGBAColor]) -> Float {
    guard let first = colors.first else { return 0 }
    var minimum = SIMD3(first.red, first.green, first.blue)
    var maximum = minimum
    for color in colors.dropFirst() {
        let value = SIMD3(color.red, color.green, color.blue)
        minimum = SIMD3(
            min(minimum.x, value.x),
            min(minimum.y, value.y),
            min(minimum.z, value.z)
        )
        maximum = SIMD3(
            max(maximum.x, value.x),
            max(maximum.y, value.y),
            max(maximum.z, value.z)
        )
    }
    let spread = maximum - minimum
    return max(spread.x, max(spread.y, spread.z))
}

@MainActor
private func waitForCondition(
    timeoutIterations: Int = 80,
    pollIntervalMilliseconds: UInt64 = 10,
    _ condition: () throws -> Bool
) async throws {
    for _ in 0..<timeoutIterations {
        if try condition() {
            return
        }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(Int(pollIntervalMilliseconds)))
    }
    #expect(try condition())
}

private func isPointInsideTriangle(
    _ point: CanvasPoint,
    _ a: CanvasPoint,
    _ b: CanvasPoint,
    _ c: CanvasPoint
) -> Bool {
    func signedArea(_ p1: CanvasPoint, _ p2: CanvasPoint, _ p3: CanvasPoint) -> Double {
        (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y)
    }

    let d1 = signedArea(point, a, b)
    let d2 = signedArea(point, b, c)
    let d3 = signedArea(point, c, a)
    let hasNegative = d1 < 0 || d2 < 0 || d3 < 0
    let hasPositive = d1 > 0 || d2 > 0 || d3 > 0
    return !(hasNegative && hasPositive)
}

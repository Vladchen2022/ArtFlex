import Metal
import Testing
@testable import ArtFlex

struct WorkspaceViewModelPixelHistoryTests {
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

        let bounds = try #require(harness.viewModel.sceneSnapshot.selectionShape?.bounds)
        #expect(bounds.size.x < Double(harness.viewModel.workspace.document.canvasSize.width))
        #expect(bounds.size.y < Double(harness.viewModel.workspace.document.canvasSize.height))
        #expect(bounds.size.x > 0)
        #expect(bounds.size.y > 0)
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
    func linearGradientAutoApplyCompletesAtDragEnd() async throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.addLayer()

        harness.viewModel.selectLayer(layerID)
        harness.viewModel.selectTool(.linearGradient)
        harness.viewModel.beginGradientDrag(at: .init(x: 10, y: 16))
        harness.viewModel.updateGradientDrag(to: .init(x: 30, y: 16))
        harness.viewModel.endGradientDrag(at: .init(x: 30, y: 16))
        try await harness.waitForGradientCommitToFinish()

        #expect(harness.viewModel.isApplyingGradientCommit == false)
        #expect(harness.viewModel.linearGradientState.phase == .idle)
        #expect(harness.viewModel.workspace.toolSession.activeTool == .linearGradient)
        #expect(try harness.alpha(atX: 10, y: 16, layerID: layerID) > 0.7)
        #expect(try harness.alpha(atX: 36, y: 16, layerID: layerID) < 0.05)
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
        try await harness.waitForGradientCommitToFinish()

        let nearAlpha = try harness.alpha(atX: 10, y: 16, layerID: layerID)
        #expect(nearAlpha > 0.18)
        #expect(nearAlpha < 0.30)
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

        harness.viewModel.fillAtPoint(.init(x: 12, y: 12))
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) > 0.01)

        harness.viewModel.undo()
        let restoredFillPixel = try harness.color(atX: 12, y: 12, layerID: layerID)
        #expect(restoredFillPixel.alpha > 0.99)
        #expect(restoredFillPixel.red > 0.99)
        #expect(restoredFillPixel.green > 0.99)
        #expect(restoredFillPixel.blue > 0.99)

        harness.viewModel.redo()
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) > 0.01)
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
        #expect(restoredSelectionPixel.alpha > 0.99)
        #expect(restoredSelectionPixel.red > 0.99)
        #expect(restoredSelectionPixel.green > 0.99)
        #expect(restoredSelectionPixel.blue > 0.99)

        harness.viewModel.redo()
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) > 0.01)
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
    func textureFillSolidSupportsUndoRedo() throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID

        harness.beginTextureFill(at: .init(x: 8, y: 8))
        harness.updateTextureFill(to: .init(x: 32, y: 8))
        harness.updateTextureFill(to: .init(x: 32, y: 32))
        harness.endTextureFill(at: .init(x: 8, y: 32))

        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) > 0.01)

        harness.viewModel.undo()
        let restoredPixel = try harness.color(atX: 12, y: 12, layerID: layerID)
        #expect(restoredPixel.alpha < 0.01)
        #expect(restoredPixel.red < 0.01)
        #expect(restoredPixel.green < 0.01)
        #expect(restoredPixel.blue < 0.01)

        harness.viewModel.redo()
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) > 0.01)
    }

    @Test
    @MainActor
    func textureFillSolidWritesPixelsDuringDrag() throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID

        harness.beginTextureFill(at: .init(x: 8, y: 8))
        harness.updateTextureFill(to: .init(x: 32, y: 8))
        harness.updateTextureFill(to: .init(x: 32, y: 32))

        #expect(try harness.alpha(atX: 20, y: 12, layerID: layerID) > 0.01)
    }

    @Test
    @MainActor
    func textureFillProducesGapsInsideRenderedSlice() throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID
        let anchor = CanvasPoint(x: 8, y: 8)
        let previous = CanvasPoint(x: 32, y: 8)
        let current = CanvasPoint(x: 32, y: 32)

        harness.beginTextureFill(at: anchor)
        harness.updateTextureFill(to: previous)
        harness.updateTextureFill(to: current)

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
    func textureFillGestureResetsWhenSwitchingTools() throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID

        harness.beginTextureFill(at: .init(x: 8, y: 8))
        harness.updateTextureFill(to: .init(x: 24, y: 8))
        harness.viewModel.selectTool(.brush)

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
        let firstLayerID = harness.viewModel.workspace.document.layers[0].id
        let secondLayerID = harness.addLayer()

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

        harness.viewModel.undo()
        #expect(harness.viewModel.workspace.document.layers.count == 2)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)

        harness.viewModel.undo()
        #expect(harness.viewModel.workspace.document.layers.count == 2)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) < 0.01)

        harness.viewModel.redo()
        #expect(harness.viewModel.workspace.document.layers.count == 2)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)

        harness.viewModel.redo()
        #expect(harness.viewModel.workspace.document.layers.count == 3)
        #expect(try harness.alpha(atX: 12, y: 12, layerID: thirdLayerID) < 0.01)
    }

    @Test
    @MainActor
    func fillAtPointTopologyFenceKeepsUndoRedoChainCorrect() throws {
        let harness = try PixelHistoryHarness()
        let firstLayerID = harness.viewModel.workspace.document.layers[0].id
        let secondLayerID = harness.addLayer()

        harness.viewModel.selectLayer(firstLayerID)
        harness.viewModel.fillAtPoint(.init(x: 12, y: 12))
        harness.viewModel.selectLayer(secondLayerID)
        harness.viewModel.fillAtPoint(.init(x: 46, y: 46))

        let thirdLayerID = harness.addLayer()

        harness.viewModel.undo()
        #expect(harness.viewModel.workspace.document.layers.count == 2)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)

        harness.viewModel.undo()
        #expect(harness.viewModel.workspace.document.layers.count == 2)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) < 0.01)

        harness.viewModel.redo()
        #expect(harness.viewModel.workspace.document.layers.count == 2)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)

        harness.viewModel.redo()
        #expect(harness.viewModel.workspace.document.layers.count == 3)
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
        }
    }

    @Test
    @MainActor
    func creativeShapeGeneratorUndoDoesNotRestoreLassoSelection() async throws {
        let harness = try PixelHistoryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID

        harness.viewModel.selectCreativeShapeGeneratorSource(.currentColor)
        harness.viewModel.setCreativeShapeGeneratorFeatherProbability(0)
        harness.viewModel.setCreativeShapeGeneratorShapeCharacteristic(0.42)
        harness.viewModel.setCreativeShapeGeneratorShapeSize(0)
        harness.viewModel.setCreativeShapeGeneratorShapeJitter(0)
        harness.viewModel.setCreativeShapeGeneratorColorJitter(0)

        harness.makeLassoSelection([
            .init(x: 8, y: 8),
            .init(x: 40, y: 8),
            .init(x: 40, y: 40),
            .init(x: 8, y: 40),
            .init(x: 8, y: 8)
        ])

        var hasGeneratedPixels = false
        for _ in 0..<80 {
            hasGeneratedPixels = try regionHasVisiblePixels(
                harness: harness,
                layerID: layerID,
                minX: 12,
                maxX: 36,
                minY: 12,
                maxY: 36
            )
            if harness.viewModel.workspace.selection.committedShape == nil, hasGeneratedPixels {
                break
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(hasGeneratedPixels)
        #expect(harness.viewModel.workspace.selection.committedShape == nil)

        harness.viewModel.undo()

        #expect(
            try regionHasVisiblePixels(
                harness: harness,
                layerID: layerID,
                minX: 12,
                maxX: 36,
                minY: 12,
                maxY: 36
            ) == false
        )
        #expect(harness.viewModel.workspace.selection.committedShape == nil)
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

    func makeLassoSelection(_ points: [CanvasPoint]) {
        guard let first = points.first, points.count > 1 else { return }
        viewModel.selectTool(.lassoSelection)
        viewModel.beginSelection(kind: .lasso, at: first)
        for point in points.dropFirst().dropLast() {
            viewModel.updateSelection(to: point)
        }
        viewModel.commitSelection(at: points.last ?? first)
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

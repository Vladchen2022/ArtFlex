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

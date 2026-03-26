import Metal
import Testing
@testable import ArtFlex

struct WorkspaceViewModelPixelHistoryTests {
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
}

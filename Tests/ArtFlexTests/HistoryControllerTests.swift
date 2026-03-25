import Metal
import Testing
@testable import ArtFlex

struct HistoryControllerTests {
    @Test
    func historyNavigationPreservesTransientToolSettings() {
        var restored = WorkspaceState.stageOneDefault
        var current = WorkspaceState.stageOneDefault

        restored.selection = .empty
        current.toolSession.brush.buildMode = .opacityCap
        current.toolSession.brush.pressureOpacityAmount = 0.42
        current.viewport.zoomScale = 2.5

        let merged = HistoryController.mergedWorkspaceForHistoryNavigation(
            restored: restored,
            current: current
        )

        #expect(merged.document == restored.document)
        #expect(merged.selection == restored.selection)
        #expect(merged.toolSession == current.toolSession)
        #expect(merged.viewport == current.viewport)
    }

    @Test
    @MainActor
    func historyLimitsTrimByEntryCount() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 16, height: 16))
        let history = HistoryController(
            workspaceStore: harness.workspaceStore,
            layerSurfaceStore: harness.layerSurfaceStore,
            serializer: harness.serializer,
            metalContext: harness.metalContext,
            maxEntries: 2,
            maxResidentBytes: .max
        )

        try history.captureCheckpoint()
        try history.captureCheckpoint()
        try history.captureCheckpoint()

        var undoCount = 0
        while try history.undo() {
            undoCount += 1
        }

        #expect(undoCount == 2)
    }

    @Test
    @MainActor
    func historyLimitsTrimByResidentBytes() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 16, height: 16))
        let history = HistoryController(
            workspaceStore: harness.workspaceStore,
            layerSurfaceStore: harness.layerSurfaceStore,
            serializer: harness.serializer,
            metalContext: harness.metalContext,
            maxEntries: 10,
            maxResidentBytes: 1_500
        )

        try history.captureCheckpoint()
        try history.captureCheckpoint()

        var undoCount = 0
        while try history.undo() {
            undoCount += 1
        }

        #expect(undoCount == 1)
    }

    @Test
    @MainActor
    func historySupportsUndoRedoForTwoStrokesOnSameLayer() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let layerID = harness.workspaceStore.state.document.activeLayerID

        try harness.drawBrushStroke(
            layerID: layerID,
            points: [
                .init(x: 10, y: 10, pressure: 1),
                .init(x: 18, y: 18, pressure: 1)
            ]
        )
        try harness.drawBrushStroke(
            layerID: layerID,
            points: [
                .init(x: 42, y: 42, pressure: 1),
                .init(x: 52, y: 52, pressure: 1)
            ]
        )

        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) > 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: layerID) > 0.01)

        #expect(try harness.history.undo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) > 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: layerID) < 0.01)

        #expect(try harness.history.undo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) < 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: layerID) < 0.01)

        #expect(try harness.history.redo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) > 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: layerID) < 0.01)

        #expect(try harness.history.redo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) > 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: layerID) > 0.01)
    }

    @Test
    @MainActor
    func historySupportsUndoRedoAcrossDifferentLayersWithoutClearingUntouchedLayers() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let firstLayerID = harness.workspaceStore.state.document.layers[0].id
        let secondLayerID = harness.addLayer()

        try harness.drawBrushStroke(
            layerID: firstLayerID,
            points: [
                .init(x: 10, y: 10, pressure: 1),
                .init(x: 18, y: 18, pressure: 1)
            ]
        )
        try harness.drawBrushStroke(
            layerID: secondLayerID,
            points: [
                .init(x: 42, y: 42, pressure: 1),
                .init(x: 52, y: 52, pressure: 1)
            ]
        )

        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) > 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)

        #expect(try harness.history.undo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) > 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) < 0.01)

        #expect(try harness.history.undo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) < 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) < 0.01)

        #expect(try harness.history.redo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) > 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) < 0.01)

        #expect(try harness.history.redo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) > 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)
    }

    @Test
    @MainActor
    func topologyChangesDoNotLoseOtherLayerContentsDuringUndoRedo() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let firstLayerID = harness.workspaceStore.state.document.layers[0].id
        let secondLayerID = harness.addLayer()

        try harness.drawBrushStroke(
            layerID: firstLayerID,
            points: [
                .init(x: 10, y: 10, pressure: 1),
                .init(x: 18, y: 18, pressure: 1)
            ]
        )
        try harness.drawBrushStroke(
            layerID: secondLayerID,
            points: [
                .init(x: 42, y: 42, pressure: 1),
                .init(x: 52, y: 52, pressure: 1)
            ]
        )
        try harness.drawBrushStroke(
            layerID: firstLayerID,
            points: [
                .init(x: 36, y: 20, pressure: 1),
                .init(x: 46, y: 30, pressure: 1)
            ]
        )
        let thirdLayerID = harness.addLayer()
        #expect(harness.workspaceStore.state.document.layers.count == 3)

        #expect(try harness.history.undo())
        #expect(harness.workspaceStore.state.document.layers.count == 2)
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) > 0.01)
        #expect(try harness.alpha(atX: 40, y: 24, layerID: firstLayerID) < 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)

        #expect(try harness.history.redo())
        #expect(harness.workspaceStore.state.document.layers.count == 3)
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) > 0.01)
        #expect(try harness.alpha(atX: 40, y: 24, layerID: firstLayerID) > 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)
        #expect(try harness.alpha(atX: 12, y: 12, layerID: thirdLayerID) < 0.01)
    }
}

private enum BrushHistoryHarnessError: Error {
    case metalUnavailable
    case commandBufferUnavailable
    case textureUnavailable
}

@MainActor
private struct BrushHistoryHarness {
    let workspaceStore: WorkspaceStore
    let metalContext: MetalDeviceContext
    let layerSurfaceStore: StageOneLayerSurfaceStore
    let serializer: LayerTextureSerializer
    let history: HistoryController
    let engine: MetalStrokeEngine

    init(canvasSize: CanvasSize) throws {
        guard let metalContext = MetalDeviceContext() else {
            throw BrushHistoryHarnessError.metalUnavailable
        }

        var workspaceState = WorkspaceState.stageOneDefault
        workspaceState.document.canvasSize = canvasSize
        workspaceState.document.metadata.updatedAt = Date()

        let workspaceStore = WorkspaceStore(state: workspaceState)
        let layerSurfaceStore = StageOneLayerSurfaceStore()
        layerSurfaceStore.prepareTextures(for: workspaceState.document, metal: metalContext)

        let serializer = LayerTextureSerializer(metalContext: metalContext)
        let history = HistoryController(
            workspaceStore: workspaceStore,
            layerSurfaceStore: layerSurfaceStore,
            serializer: serializer,
            metalContext: metalContext
        )
        let engine = try MetalStrokeEngine(
            metalContext: metalContext,
            layerSurfaceStore: layerSurfaceStore
        )

        self.workspaceStore = workspaceStore
        self.metalContext = metalContext
        self.layerSurfaceStore = layerSurfaceStore
        self.serializer = serializer
        self.history = history
        self.engine = engine
    }

    func addLayer() -> LayerID {
        workspaceStore.updateDocument { document in
            _ = document.addLayer()
        }
        layerSurfaceStore.prepareTextures(for: workspaceStore.state.document, metal: metalContext)
        return workspaceStore.state.document.activeLayerID
    }

    func drawBrushStroke(
        layerID: LayerID,
        points: [StrokePoint]
    ) throws {
        engine.beginStrokeIfNeeded(
            toolSession: .stageOneDefault,
            layerID: layerID
        )
        _ = engine.applyStroke(
            StrokeDescriptor(
                tool: .brush,
                color: .black,
                brush: .stageOneDefault,
                points: points,
                selectionShape: nil,
                skipLeadingStamp: false
            ),
            to: layerID
        )
        engine.endStroke()

        guard let commandBuffer = metalContext.commandQueue.makeCommandBuffer() else {
            throw BrushHistoryHarnessError.commandBufferUnavailable
        }
        _ = engine.flushPendingStrokePackets(into: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        try engine.drainPendingBrushCommitJobs { [history] _ in
            try history.captureCheckpoint()
        }
    }

    func alpha(
        atX x: Int,
        y: Int,
        layerID: LayerID
    ) throws -> Float {
        guard
            let surfaceID = layerSurfaceStore.surfaceID(for: layerID),
            let texture = layerSurfaceStore.texture(for: surfaceID)
        else {
            throw BrushHistoryHarnessError.textureUnavailable
        }
        return try serializer.samplePixel(texture: texture, x: x, y: y).alpha
    }
}

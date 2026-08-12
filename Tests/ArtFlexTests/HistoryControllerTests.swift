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
    func historyNavigationPreservesTipImageLibraryState() {
        var restored = WorkspaceState.stageOneDefault
        var current = WorkspaceState.stageOneDefault

        restored.tipImageLibrary = .empty
        current.tipImageLibrary = TipImageLibraryState(
            items: [
                TipImageLibraryItem(
                    id: BrushTipImageAssetID(rawValue: "tip-a"),
                    sourceInfo: ImportedTipSourceInfo(
                        sourceLabel: "A",
                        pixelWidth: 64,
                        pixelHeight: 64
                    ),
                    maskData: Data([255, 0, 0, 255])
                ),
                TipImageLibraryItem(
                    id: BrushTipImageAssetID(rawValue: "tip-b"),
                    sourceInfo: ImportedTipSourceInfo(
                        sourceLabel: "B",
                        pixelWidth: 96,
                        pixelHeight: 96
                    ),
                    maskData: Data([0, 255, 0, 255])
                )
            ]
        )

        let merged = HistoryController.mergedWorkspaceForHistoryNavigation(
            restored: restored,
            current: current
        )

        #expect(merged.tipImageLibrary == current.tipImageLibrary)
        #expect(merged.tipImageLibrary.items.count == 2)
    }

    @Test
    @MainActor
    func workspaceOnlyHistoryRestoresDocumentStateWithoutTextureSnapshots() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 16, height: 16))

        try harness.history.captureCheckpoint(captureMode: .workspaceOnly)
        harness.workspaceStore.updateDocument { document in
            document.perspectiveGuide = .initial(canvasSize: document.canvasSize)
        }

        #expect(harness.history.debugUndoEntryApproxByteCounts.last == 0)
        let undoMode = try #require(harness.history.debugUndoEntryModes.last)
        if case .workspaceOnly = undoMode {
            // Expected: this entry contains document state but no layer texture snapshots.
        } else {
            Issue.record("Expected workspace-only history entry")
        }

        #expect(try harness.history.undo())
        #expect(harness.workspaceStore.state.document.perspectiveGuide == nil)
        #expect(try harness.history.redo())
        #expect(harness.workspaceStore.state.document.perspectiveGuide?.mode == .threePoint)
    }

    @Test
    @MainActor
    func undoDoesNotDropTipImageLibraryState() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 16, height: 16))
        let tipImageLibrary = TipImageLibraryState(
            items: [
                TipImageLibraryItem(
                    id: BrushTipImageAssetID(rawValue: "tip-a"),
                    sourceInfo: ImportedTipSourceInfo(
                        sourceLabel: "A",
                        pixelWidth: 64,
                        pixelHeight: 64
                    ),
                    maskData: Data([255, 0, 0, 255])
                ),
                TipImageLibraryItem(
                    id: BrushTipImageAssetID(rawValue: "tip-b"),
                    sourceInfo: ImportedTipSourceInfo(
                        sourceLabel: "B",
                        pixelWidth: 96,
                        pixelHeight: 96
                    ),
                    maskData: Data([0, 255, 0, 255])
                )
            ]
        )

        harness.workspaceStore.updateTipImageLibrary { library in
            library = tipImageLibrary
        }

        try harness.history.captureCheckpoint()
        #expect(try harness.history.undo())
        #expect(harness.workspaceStore.state.tipImageLibrary == tipImageLibrary)
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
    func defaultHistoryPolicySupportsAtLeastTwenty3000pxDirtyEntries() {
        let dirtyEntryBytes = 3_000 * 3_000 * 4
        let retainedByBudget = HistoryController.defaultMaxResidentBytes / dirtyEntryBytes
        let retainedByPolicy = min(HistoryController.defaultMaxEntries, retainedByBudget)

        #expect(HistoryController.defaultMaxEntries == 24)
        #expect(HistoryController.defaultMaxResidentBytes == 768 * 1024 * 1024)
        #expect(retainedByPolicy >= 20)
    }

    @Test
    @MainActor
    func oversizedSingleEntryStillKeepsLatestUndoState() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let history = HistoryController(
            workspaceStore: harness.workspaceStore,
            layerSurfaceStore: harness.layerSurfaceStore,
            serializer: harness.serializer,
            metalContext: harness.metalContext,
            maxEntries: 10,
            maxResidentBytes: 1_024
        )
        let layerID = harness.workspaceStore.state.document.activeLayerID

        try harness.drawBrushStroke(
            history: history,
            layerID: layerID,
            points: [
                .init(x: 10, y: 10, pressure: 1),
                .init(x: 18, y: 18, pressure: 1)
            ]
        )

        #expect(history.canUndo)
        #expect(try history.undo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) < 0.01)
    }

    @Test
    @MainActor
    func consecutiveOversizedEntriesTrimOlderEntriesButKeepNewest() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let history = HistoryController(
            workspaceStore: harness.workspaceStore,
            layerSurfaceStore: harness.layerSurfaceStore,
            serializer: harness.serializer,
            metalContext: harness.metalContext,
            maxEntries: 10,
            maxResidentBytes: 1_024
        )
        let layerID = harness.workspaceStore.state.document.activeLayerID

        try harness.drawBrushStroke(
            history: history,
            layerID: layerID,
            points: [
                .init(x: 8, y: 8, pressure: 1),
                .init(x: 16, y: 16, pressure: 1)
            ]
        )
        try harness.drawBrushStroke(
            history: history,
            layerID: layerID,
            points: [
                .init(x: 28, y: 28, pressure: 1),
                .init(x: 36, y: 36, pressure: 1)
            ]
        )
        try harness.drawBrushStroke(
            history: history,
            layerID: layerID,
            points: [
                .init(x: 44, y: 12, pressure: 1),
                .init(x: 52, y: 20, pressure: 1)
            ]
        )

        #expect(try history.undo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) > 0.01)
        #expect(try harness.alpha(atX: 32, y: 32, layerID: layerID) > 0.01)
        #expect(try harness.alpha(atX: 48, y: 16, layerID: layerID) < 0.01)
        #expect(!(try history.undo()))
    }

    @Test
    @MainActor
    func oversizedEntriesStillSupportUndoRedoForNewestEntry() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let history = HistoryController(
            workspaceStore: harness.workspaceStore,
            layerSurfaceStore: harness.layerSurfaceStore,
            serializer: harness.serializer,
            metalContext: harness.metalContext,
            maxEntries: 10,
            maxResidentBytes: 1_024
        )
        let layerID = harness.workspaceStore.state.document.activeLayerID

        try harness.drawBrushStroke(
            history: history,
            layerID: layerID,
            points: [
                .init(x: 10, y: 10, pressure: 1),
                .init(x: 18, y: 18, pressure: 1)
            ]
        )
        try harness.drawBrushStroke(
            history: history,
            layerID: layerID,
            points: [
                .init(x: 40, y: 40, pressure: 1),
                .init(x: 48, y: 48, pressure: 1)
            ]
        )

        #expect(try history.undo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) > 0.01)
        #expect(try harness.alpha(atX: 44, y: 44, layerID: layerID) < 0.01)

        #expect(try history.redo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) > 0.01)
        #expect(try harness.alpha(atX: 44, y: 44, layerID: layerID) > 0.01)
    }

    @Test
    @MainActor
    func historySupportsUndoRedoForTwoStrokesOnSameLayer() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let layerID = harness.workspaceStore.state.document.activeLayerID

        try harness.drawBrushStroke(
            useDirtyBrushHistory: true,
            layerID: layerID,
            points: [
                .init(x: 10, y: 10, pressure: 1),
                .init(x: 18, y: 18, pressure: 1)
            ]
        )
        try harness.drawBrushStroke(
            useDirtyBrushHistory: true,
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
        #expect(!harness.history.debugAttemptedFullResetWithDirtyEntry)
    }

    @Test
    @MainActor
    func historySupportsUndoRedoAcrossDifferentLayersWithoutClearingUntouchedLayers() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let firstLayerID = harness.workspaceStore.state.document.layers[0].id
        let secondLayerID = harness.addLayer()

        try harness.drawBrushStroke(
            useDirtyBrushHistory: true,
            layerID: firstLayerID,
            points: [
                .init(x: 10, y: 10, pressure: 1),
                .init(x: 18, y: 18, pressure: 1)
            ]
        )
        try harness.drawBrushStroke(
            useDirtyBrushHistory: true,
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
        #expect(!harness.history.debugAttemptedFullResetWithDirtyEntry)
    }

    @Test
    @MainActor
    func hiddenLockedOpacityLayersRemainIntactAcrossDirtyBrushRestore() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let baseLayerID = harness.workspaceStore.state.document.layers[0].id
        let decoratedLayerID = harness.addLayer()

        try harness.drawBrushStroke(
            useDirtyBrushHistory: true,
            layerID: decoratedLayerID,
            points: [
                .init(x: 42, y: 42, pressure: 1),
                .init(x: 52, y: 52, pressure: 1)
            ]
        )

        harness.workspaceStore.updateDocument { document in
            document.setLayerVisibility(decoratedLayerID, isVisible: false)
            document.toggleLayerLock(decoratedLayerID)
            document.setLayerOpacity(decoratedLayerID, opacity: 0.35)
        }

        try harness.drawBrushStroke(
            useDirtyBrushHistory: true,
            layerID: baseLayerID,
            points: [
                .init(x: 10, y: 10, pressure: 1),
                .init(x: 18, y: 18, pressure: 1)
            ]
        )

        #expect(try harness.history.undo())
        #expect(try harness.alpha(atX: 46, y: 46, layerID: decoratedLayerID) > 0.01)
        #expect(try harness.alpha(atX: 12, y: 12, layerID: baseLayerID) < 0.01)
        let decoratedLayer = try #require(harness.workspaceStore.state.document.layers.first(where: { $0.id == decoratedLayerID }))
        #expect(decoratedLayer.isVisible == false)
        #expect(decoratedLayer.isLocked == true)
        #expect(abs(decoratedLayer.opacity - 0.35) < 0.001)
        #expect(!harness.history.debugAttemptedFullResetWithDirtyEntry)
    }

    @Test
    @MainActor
    func topologyChangesDoNotLoseOtherLayerContentsDuringUndoRedo() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let firstLayerID = harness.workspaceStore.state.document.layers[0].id
        let secondLayerID = harness.addLayer()

        try harness.drawBrushStroke(
            useDirtyBrushHistory: true,
            layerID: firstLayerID,
            points: [
                .init(x: 10, y: 10, pressure: 1),
                .init(x: 18, y: 18, pressure: 1)
            ]
        )
        try harness.drawBrushStroke(
            useDirtyBrushHistory: true,
            layerID: secondLayerID,
            points: [
                .init(x: 42, y: 42, pressure: 1),
                .init(x: 52, y: 52, pressure: 1)
            ]
        )
        try harness.drawBrushStroke(
            useDirtyBrushHistory: true,
            layerID: firstLayerID,
            points: [
                .init(x: 36, y: 20, pressure: 1),
                .init(x: 46, y: 30, pressure: 1)
            ]
        )
        try harness.history.captureCheckpoint()
        let thirdLayerID = harness.addLayer()
        #expect(harness.workspaceStore.state.document.layers.count == 4)

        #expect(try harness.history.undo())
        #expect(harness.workspaceStore.state.document.layers.count == 3)
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) > 0.01)
        #expect(try harness.alpha(atX: 40, y: 24, layerID: firstLayerID) > 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)

        #expect(try harness.history.undo())
        #expect(harness.workspaceStore.state.document.layers.count == 3)
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) > 0.01)
        #expect(try harness.alpha(atX: 40, y: 24, layerID: firstLayerID) < 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)

        #expect(try harness.history.redo())
        #expect(harness.workspaceStore.state.document.layers.count == 3)
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) > 0.01)
        #expect(try harness.alpha(atX: 40, y: 24, layerID: firstLayerID) > 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)

        #expect(try harness.history.redo())
        #expect(harness.workspaceStore.state.document.layers.count == 4)
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) > 0.01)
        #expect(try harness.alpha(atX: 40, y: 24, layerID: firstLayerID) > 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)
        #expect(try harness.alpha(atX: 12, y: 12, layerID: thirdLayerID) < 0.01)
        #expect(!harness.history.debugAttemptedFullResetWithDirtyEntry)
    }

    @Test
    @MainActor
    func singleLayerBrushHistoryUsesDirtyEntry() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 64, height: 64), startsWithSingleLayer: true)
        let layerID = harness.workspaceStore.state.document.activeLayerID

        try harness.drawBrushStroke(
            useDirtyBrushHistory: true,
            layerID: layerID,
            points: [
                .init(x: 12, y: 12, pressure: 1),
                .init(x: 24, y: 24, pressure: 1)
            ]
        )

        let latestMode = try #require(harness.history.debugUndoEntryModes.last)
        switch latestMode {
        case .inPlaceChangedLayers:
            break
        case .full:
            Issue.record("Single-layer brush history should retain its rendered-region delta")
        case .workspaceOnly, .metadataOnly:
            Issue.record("Brush stroke should not produce workspace-only history entries")
        }

        #expect(try harness.history.undo())
        #expect(try harness.alpha(atX: 16, y: 16, layerID: layerID) < 0.01)
        #expect(try harness.history.redo())
        #expect(try harness.alpha(atX: 16, y: 16, layerID: layerID) > 0.01)
    }

    @Test
    @MainActor
    func dirtyBrushHistoryNeverFallsBackToFullResetWithPartialSnapshots() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let firstLayerID = harness.workspaceStore.state.document.layers[0].id
        let secondLayerID = harness.addLayer()

        try harness.drawBrushStroke(
            useDirtyBrushHistory: true,
            layerID: firstLayerID,
            points: [
                .init(x: 8, y: 8, pressure: 1),
                .init(x: 16, y: 16, pressure: 1)
            ]
        )
        try harness.drawBrushStroke(
            useDirtyBrushHistory: true,
            layerID: secondLayerID,
            points: [
                .init(x: 36, y: 36, pressure: 1),
                .init(x: 44, y: 44, pressure: 1)
            ]
        )

        #expect(try harness.history.undo())
        #expect(try harness.history.undo())
        #expect(try harness.history.redo())
        #expect(try harness.history.redo())
        #expect(!harness.history.debugAttemptedFullResetWithDirtyEntry)
    }

    @Test
    @MainActor
    func dirtyUndoCapturePushesSymmetricDirtyEntryOntoRedoStack() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let firstLayerID = harness.workspaceStore.state.document.layers[0].id
        let secondLayerID = harness.addLayer()

        try harness.drawBrushStroke(
            useDirtyBrushHistory: true,
            layerID: firstLayerID,
            points: [
                .init(x: 10, y: 10, pressure: 1),
                .init(x: 18, y: 18, pressure: 1)
            ]
        )
        try harness.drawBrushStroke(
            useDirtyBrushHistory: true,
            layerID: secondLayerID,
            points: [
                .init(x: 40, y: 40, pressure: 1),
                .init(x: 48, y: 48, pressure: 1)
            ]
        )

        #expect(try harness.history.undo())
        let redoMode = try #require(harness.history.debugRedoEntryModes.last)
        switch redoMode {
        case .full:
            Issue.record("Expected symmetric dirty current-entry capture in redo stack")
        case .inPlaceChangedLayers(_, let changedLayerIDs):
            #expect(Set(changedLayerIDs) == [secondLayerID])
        case .workspaceOnly, .metadataOnly:
            Issue.record("Brush stroke should not produce workspace-only history entries")
        }
    }

    @Test
    @MainActor
    func eraserHistorySupportsUndoRedoForTwoStrokesOnSameLayer() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let layerID = harness.workspaceStore.state.document.activeLayerID

        try harness.drawStroke(
            tool: .brush,
            layerID: layerID,
            points: [
                .init(x: 10, y: 10, pressure: 1),
                .init(x: 18, y: 18, pressure: 1)
            ]
        )
        try harness.drawStroke(
            tool: .brush,
            layerID: layerID,
            points: [
                .init(x: 42, y: 42, pressure: 1),
                .init(x: 52, y: 52, pressure: 1)
            ]
        )

        try harness.drawStroke(
            tool: .eraser,
            useDirtyHistory: true,
            layerID: layerID,
            points: [
                .init(x: 10, y: 10, pressure: 1),
                .init(x: 18, y: 18, pressure: 1)
            ]
        )
        try harness.drawStroke(
            tool: .eraser,
            useDirtyHistory: true,
            layerID: layerID,
            points: [
                .init(x: 42, y: 42, pressure: 1),
                .init(x: 52, y: 52, pressure: 1)
            ]
        )

        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) < 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: layerID) < 0.01)

        #expect(try harness.history.undo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) < 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: layerID) > 0.01)

        #expect(try harness.history.undo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) > 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: layerID) > 0.01)

        #expect(try harness.history.redo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) < 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: layerID) > 0.01)

        #expect(try harness.history.redo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) < 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: layerID) < 0.01)
        #expect(!harness.history.debugAttemptedFullResetWithDirtyEntry)
    }

    @Test
    @MainActor
    func eraserHistorySupportsUndoRedoAcrossDifferentLayersWithoutClearingUntouchedLayers() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let firstLayerID = harness.workspaceStore.state.document.layers[0].id
        let secondLayerID = harness.addLayer()

        try harness.drawStroke(
            tool: .brush,
            layerID: firstLayerID,
            points: [
                .init(x: 10, y: 10, pressure: 1),
                .init(x: 18, y: 18, pressure: 1)
            ]
        )
        try harness.drawStroke(
            tool: .brush,
            layerID: secondLayerID,
            points: [
                .init(x: 42, y: 42, pressure: 1),
                .init(x: 52, y: 52, pressure: 1)
            ]
        )

        try harness.drawStroke(
            tool: .eraser,
            useDirtyHistory: true,
            layerID: firstLayerID,
            points: [
                .init(x: 10, y: 10, pressure: 1),
                .init(x: 18, y: 18, pressure: 1)
            ]
        )
        try harness.drawStroke(
            tool: .eraser,
            useDirtyHistory: true,
            layerID: secondLayerID,
            points: [
                .init(x: 42, y: 42, pressure: 1),
                .init(x: 52, y: 52, pressure: 1)
            ]
        )

        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) < 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) < 0.01)

        #expect(try harness.history.undo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) < 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)

        #expect(try harness.history.undo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) > 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)

        #expect(try harness.history.redo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) < 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)

        #expect(try harness.history.redo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) < 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) < 0.01)
        #expect(!harness.history.debugAttemptedFullResetWithDirtyEntry)
    }

    @Test
    @MainActor
    func hiddenLockedOpacityLayersRemainIntactAcrossDirtyEraserRestore() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let baseLayerID = harness.workspaceStore.state.document.layers[0].id
        let decoratedLayerID = harness.addLayer()

        try harness.drawStroke(
            tool: .brush,
            layerID: decoratedLayerID,
            points: [
                .init(x: 42, y: 42, pressure: 1),
                .init(x: 52, y: 52, pressure: 1)
            ]
        )

        harness.workspaceStore.updateDocument { document in
            document.setLayerVisibility(decoratedLayerID, isVisible: false)
            document.toggleLayerLock(decoratedLayerID)
            document.setLayerOpacity(decoratedLayerID, opacity: 0.35)
        }

        try harness.drawStroke(
            tool: .brush,
            layerID: baseLayerID,
            points: [
                .init(x: 10, y: 10, pressure: 1),
                .init(x: 18, y: 18, pressure: 1)
            ]
        )
        try harness.drawStroke(
            tool: .eraser,
            useDirtyHistory: true,
            layerID: baseLayerID,
            points: [
                .init(x: 10, y: 10, pressure: 1),
                .init(x: 18, y: 18, pressure: 1)
            ]
        )

        #expect(try harness.history.undo())
        #expect(try harness.alpha(atX: 46, y: 46, layerID: decoratedLayerID) > 0.01)
        #expect(try harness.alpha(atX: 12, y: 12, layerID: baseLayerID) > 0.01)
        let decoratedLayer = try #require(harness.workspaceStore.state.document.layers.first(where: { $0.id == decoratedLayerID }))
        #expect(decoratedLayer.isVisible == false)
        #expect(decoratedLayer.isLocked == true)
        #expect(abs(decoratedLayer.opacity - 0.35) < 0.001)
        #expect(!harness.history.debugAttemptedFullResetWithDirtyEntry)
    }

    @Test
    @MainActor
    func eraserTopologyFenceKeepsUndoRedoChainCorrect() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let firstLayerID = harness.workspaceStore.state.document.layers[0].id
        let secondLayerID = harness.addLayer()

        try harness.drawStroke(
            tool: .brush,
            layerID: firstLayerID,
            points: [
                .init(x: 10, y: 10, pressure: 1),
                .init(x: 18, y: 18, pressure: 1)
            ]
        )
        try harness.drawStroke(
            tool: .brush,
            layerID: secondLayerID,
            points: [
                .init(x: 42, y: 42, pressure: 1),
                .init(x: 52, y: 52, pressure: 1)
            ]
        )
        try harness.drawStroke(
            tool: .eraser,
            useDirtyHistory: true,
            layerID: firstLayerID,
            points: [
                .init(x: 10, y: 10, pressure: 1),
                .init(x: 18, y: 18, pressure: 1)
            ]
        )
        try harness.history.captureCheckpoint()
        let thirdLayerID = harness.addLayer()

        #expect(try harness.history.undo())
        #expect(harness.workspaceStore.state.document.layers.count == 3)
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) < 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)

        #expect(try harness.history.undo())
        #expect(harness.workspaceStore.state.document.layers.count == 3)
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) > 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)

        #expect(try harness.history.redo())
        #expect(harness.workspaceStore.state.document.layers.count == 3)
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) < 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)

        #expect(try harness.history.redo())
        #expect(harness.workspaceStore.state.document.layers.count == 4)
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) < 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)
        #expect(try harness.alpha(atX: 12, y: 12, layerID: thirdLayerID) < 0.01)
        #expect(!harness.history.debugAttemptedFullResetWithDirtyEntry)
    }

    @Test
    @MainActor
    func dirtyRestoreTopologyMismatchLeavesWorkspaceAndStacksUnchanged() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let secondLayerID = harness.addLayer()

        try harness.drawBrushStroke(
            useDirtyBrushHistory: true,
            layerID: secondLayerID,
            points: [
                .init(x: 36, y: 36, pressure: 1),
                .init(x: 44, y: 44, pressure: 1)
            ]
        )

        let undoCountBefore = harness.history.debugUndoCount
        let redoCountBefore = harness.history.debugRedoCount

        harness.workspaceStore.updateDocument { document in
            _ = document.addLayer()
        }
        harness.layerSurfaceStore.prepareTextures(for: harness.workspaceStore.state.document, metal: harness.metalContext)
        let workspaceAfterTopologyChange = harness.workspaceStore.state

        do {
            _ = try harness.history.undo()
            Issue.record("Expected dirty restore topology mismatch to throw")
        } catch {
        }

        #expect(harness.history.debugUndoCount == undoCountBefore)
        #expect(harness.history.debugRedoCount == redoCountBefore)
        #expect(harness.workspaceStore.state == workspaceAfterTopologyChange)
        #expect(try harness.alpha(atX: 40, y: 40, layerID: secondLayerID) > 0.01)
    }

    @Test
    @MainActor
    func dirtyEraserUndoCapturePushesSymmetricDirtyEntryOntoRedoStack() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 64, height: 64))
        _ = harness.workspaceStore.state.document.activeLayerID
        let layerID = harness.addLayer()

        try harness.drawStroke(
            tool: .brush,
            layerID: layerID,
            points: [
                .init(x: 12, y: 12, pressure: 1),
                .init(x: 20, y: 20, pressure: 1)
            ]
        )
        try harness.drawStroke(
            tool: .eraser,
            useDirtyHistory: true,
            layerID: layerID,
            points: [
                .init(x: 12, y: 12, pressure: 1),
                .init(x: 20, y: 20, pressure: 1)
            ]
        )

        #expect(try harness.history.undo())
        let redoMode = try #require(harness.history.debugRedoEntryModes.last)
        switch redoMode {
        case .full:
            Issue.record("Expected symmetric dirty current-entry capture for eraser in redo stack")
        case .inPlaceChangedLayers(_, let changedLayerIDs):
            #expect(Set(changedLayerIDs) == [layerID])
        case .workspaceOnly, .metadataOnly:
            Issue.record("Eraser stroke should not produce workspace-only history entries")
        }
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

    init(canvasSize: CanvasSize, startsWithSingleLayer: Bool = false) throws {
        guard let metalContext = MetalDeviceContext() else {
            throw BrushHistoryHarnessError.metalUnavailable
        }

        var workspaceState = WorkspaceState.stageOneDefault
        if startsWithSingleLayer {
            let backgroundLayer = LayerRecord.stageOneDefault()
            workspaceState.document = ArtDocument(
                metadata: workspaceState.document.metadata,
                canvasSize: workspaceState.document.canvasSize,
                colorStandard: workspaceState.document.colorStandard,
                layers: [backgroundLayer],
                activeLayerID: backgroundLayer.id
            )
        }
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
        history: HistoryController? = nil,
        useDirtyBrushHistory: Bool = false,
        layerID: LayerID,
        points: [StrokePoint]
    ) throws {
        try drawStroke(
            history: history,
            tool: .brush,
            useDirtyHistory: useDirtyBrushHistory,
            layerID: layerID,
            points: points
        )
    }

    func drawStroke(
        history: HistoryController? = nil,
        tool: ToolKind,
        useDirtyHistory: Bool = false,
        layerID: LayerID,
        points: [StrokePoint]
    ) throws {
        engine.beginStrokeIfNeeded(
            toolSession: .stageOneDefault,
            layerID: layerID
        )
        _ = engine.applyStroke(
            StrokeDescriptor(
                tool: tool,
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

        let historyController = history ?? self.history
        try engine.drainPendingBrushCommitJobs { job in
            let captureMode: HistoryCaptureMode
            if useDirtyHistory, job.packets.last?.tool == .brush || job.packets.last?.tool == .eraser {
                captureMode = .inPlaceChangedLayers([job.layerID])
            } else {
                captureMode = .full
            }
            try historyController.captureCheckpoint(captureMode: captureMode)
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

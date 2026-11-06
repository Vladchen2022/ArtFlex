import AppKit
import Foundation
import Metal
import Testing
@testable import ArtFlex

@Suite(.serialized)
@MainActor
struct WorkspaceTransactionRegressionTests {
    @Test(arguments: ["allocation", "commands", "history"])
    func layerPreparationFailurePreservesPixelsTopologyHistoryAndDirtyState(failure: String) throws {
        for operation in ["add", "mask", "import"] {
            let h = try TransactionHarness()
            defer { h.cleanUp() }
            try h.paintFixturePatch()
            let document = h.viewModel.workspace.document
            let pixels = try h.snapshot()
            let history = h.bootstrap.historyController.currentStateID
            let sourceTexture = try h.texture()
            h.viewModel.hasUnsavedChanges = false
            h.bootstrap.layerSurfaceStore.debugPreventsTextureAllocation = failure == "allocation"
            h.bootstrap.layerSurfaceStore.debugRejectsTextureCommands = failure == "commands"
            h.bootstrap.historyController.debugPreventsCheckpointCapture = failure == "history"
            switch operation {
            case "add": h.viewModel.addLayer()
            case "mask": h.viewModel.addMaskToActiveLayer(revealsAll: false)
            default:
                #expect(throws: (any Error).self) { try h.viewModel.appendCompositeSnapshotAsNewLayer(pixels, named: "拒绝导入") }
            }
            #expect(h.viewModel.workspace.document == document)
            #expect(h.bootstrap.workspaceStore.state.document == document)
            #expect(h.bootstrap.historyController.currentStateID == history)
            #expect(!h.viewModel.hasUnsavedChanges)
            #expect(try h.texture() === sourceTexture)
            #expect(try h.snapshot() == pixels)
        }
    }

    @Test(arguments: [false, true])
    func failedNewCanvasKeepsTheOpenDocumentAndItsPixels(commands: Bool) throws {
        let h = try TransactionHarness()
        defer { h.cleanUp() }
        try h.paintFixturePatch()
        let document = h.viewModel.workspace.document
        let pixels = try h.snapshot()
        h.bootstrap.layerSurfaceStore.debugPreventsTextureAllocation = !commands
        h.bootstrap.layerSurfaceStore.debugRejectsTextureCommands = commands
        h.viewModel.createNewCanvasDiscardingUnsavedChanges(name: "失败画布", canvasSize: .init(width: 32, height: 32), resolutionDPI: 300, pixelFormat: .rgba8)
        #expect(h.viewModel.workspace.document == document)
        #expect(try h.snapshot() == pixels)
        #expect(h.viewModel.status?.kind == .error)
    }

    @Test func duplicateSharesPixelsUntilMutationAndMissingSourceCannotPublish() throws {
        let h = try TransactionHarness()
        defer { h.cleanUp() }
        try h.paintFixturePatch()
        h.viewModel.addMaskToActiveLayer(revealsAll: true)
        let sourceID = h.layerID
        let texture = try h.texture()
        let mask = try #require(h.bootstrap.layerSurfaceStore.readMaskTexture(for: sourceID))
        let pixels = try h.snapshot()
        h.viewModel.duplicateActiveLayer()
        let destinationID = h.layerID
        #expect(destinationID != sourceID)
        #expect(try h.texture() === texture)
        #expect(h.bootstrap.layerSurfaceStore.readMaskTexture(for: destinationID) === mask)
        #expect(h.bootstrap.layerSurfaceStore.fillMaskTexture(for: destinationID, value: 0, metal: h.bootstrap.metalContext))
        #expect(h.bootstrap.layerSurfaceStore.readMaskTexture(for: sourceID) === mask)
        #expect(h.bootstrap.layerSurfaceStore.readMaskTexture(for: destinationID) !== mask)
        h.viewModel.undo()
        #expect(h.layerID == sourceID)
        #expect(try h.snapshot() == pixels)
        h.bootstrap.layerSurfaceStore.debugRemoveContentTexture(for: sourceID)
        let document = h.viewModel.workspace.document
        let history = h.bootstrap.historyController.currentStateID
        h.viewModel.duplicateActiveLayer()
        #expect(h.viewModel.workspace.document == document)
        #expect(h.bootstrap.historyController.currentStateID == history)
        #expect(h.viewModel.status?.kind == .error)
    }

    @Test func savedPixelsBecomeCleanAfterUndoingTransformWithSelectionHistoryInBetween() async throws {
        let h = try TransactionHarness()
        defer { h.cleanUp() }
        try h.paintFixturePatch()
        h.viewModel.hasUnsavedChanges = true
        try await h.saveProject(named: "before-selection-transform")
        let savedPixels = try h.snapshot()

        h.makeRectangleSelection()
        try await h.waitUntil { h.viewModel.workspace.selection.committedShape?.maskData != nil }
        #expect(!h.viewModel.hasUnsavedChanges)
        h.viewModel.selectTool(.freeTransform)
        h.viewModel.beginSelectionTransform(at: .init(x: 20, y: 20), mode: .move)
        h.viewModel.updateSelectionTransform(to: .init(x: 32, y: 20))
        h.viewModel.commitSelectionTransform(at: .init(x: 32, y: 20))
        h.viewModel.applySelectionTransform()
        try await h.waitUntil { !h.viewModel.isApplyingTransformCommit }
        #expect(h.viewModel.hasUnsavedChanges)
        #expect(try h.snapshot() != savedPixels)

        h.viewModel.undo()
        try await h.waitUntil { !h.viewModel.isHistoryNavigating }
        #expect(try h.snapshot() == savedPixels)
        #expect(h.viewModel.workspace.selection.committedShape != nil)
        #expect(!h.viewModel.hasUnsavedChanges)
        h.viewModel.redo()
        try await h.waitUntil { !h.viewModel.isHistoryNavigating }
        #expect(h.viewModel.hasUnsavedChanges)
        h.viewModel.undo()
        try await h.waitUntil { !h.viewModel.isHistoryNavigating }
        #expect(!h.viewModel.hasUnsavedChanges)

        h.viewModel.selectTool(.brush)
        h.viewModel.undo()
        try await h.waitUntil { !h.viewModel.isHistoryNavigating }
        #expect(h.viewModel.workspace.selection.committedShape == nil)
        #expect(!h.viewModel.hasUnsavedChanges)
        h.viewModel.redo()
        try await h.waitUntil { !h.viewModel.isHistoryNavigating }
        #expect(h.viewModel.workspace.selection.committedShape != nil)
        #expect(try h.snapshot() == savedPixels)
        #expect(!h.viewModel.hasUnsavedChanges)
    }

    @Test func selectionHistoryAndItsNewBranchCannotClearUnsavedContent() async throws {
        let h = try TransactionHarness()
        defer { h.cleanUp() }
        try await h.saveProject(named: "before-dirty-selection")
        h.viewModel.setActiveLayerOpacity(0.65)
        h.makeRectangleSelection()
        try await h.waitUntil { h.viewModel.workspace.selection.committedShape?.maskData != nil }
        h.viewModel.undo()
        try await h.waitUntil { !h.viewModel.isHistoryNavigating }
        #expect(h.viewModel.hasUnsavedChanges)
        h.viewModel.redo()
        try await h.waitUntil { !h.viewModel.isHistoryNavigating }
        #expect(h.viewModel.hasUnsavedChanges)
        h.viewModel.undo()
        try await h.waitUntil { !h.viewModel.isHistoryNavigating }
        h.viewModel.selectAllCanvas()
        #expect(!h.viewModel.canRedo)
        #expect(h.viewModel.hasUnsavedChanges)
        #expect(h.opacity == 0.65)
        h.viewModel.undo()
        try await h.waitUntil { !h.viewModel.isHistoryNavigating }
        #expect(h.viewModel.hasUnsavedChanges)
        h.viewModel.undo()
        try await h.waitUntil { !h.viewModel.isHistoryNavigating }
        #expect(h.opacity == 1)
        #expect(!h.viewModel.hasUnsavedChanges)
    }

    @Test func selectionCreatedWhileSaveIsPendingRemainsEquivalentToTheSavedContent() async throws {
        let h = try TransactionHarness()
        defer { h.cleanUp() }
        try h.paintFixturePatch()
        h.viewModel.hasUnsavedChanges = true
        try #require(h.beginSave(named: "selection-during-save"))
        #expect(h.viewModel.isProjectSaving)
        // Save completion runs on MainActor, so this checkpoint necessarily
        // happens after capture and before the saved point is accepted.
        h.makeRectangleSelection()
        try await h.waitUntil {
            !h.viewModel.isProjectSaving && h.viewModel.workspace.selection.committedShape?.maskData != nil
        }
        #expect(!h.viewModel.hasUnsavedChanges)
        let opened = try h.bootstrap.persistenceController.openProject(
            from: h.root.appendingPathComponent("selection-during-save.artflex"))
        #expect(opened.workspace.selection.committedShape == nil)
        #expect(h.viewModel.workspace.selection.committedShape != nil)

        h.viewModel.setActiveLayerOpacity(0.65)
        h.viewModel.undo()
        try await h.waitUntil { !h.viewModel.isHistoryNavigating }
        #expect(h.opacity == 1)
        #expect(!h.viewModel.hasUnsavedChanges)
        h.viewModel.undo()
        try await h.waitUntil { !h.viewModel.isHistoryNavigating }
        #expect(!h.viewModel.hasUnsavedChanges)
        h.viewModel.redo()
        try await h.waitUntil { !h.viewModel.isHistoryNavigating }
        #expect(!h.viewModel.hasUnsavedChanges)
    }

    @Test func selectionHistoryKeepsLayerTexturesAndRefreshesOutlinesWithoutPixelSnapshots() async throws {
        let h = try TransactionHarness()
        defer { h.cleanUp() }
        try h.paintFixturePatch()
        h.viewModel.hasUnsavedChanges = false
        let layers = h.viewModel.workspace.document.paintLayers
        let textures = try layers.map { layer in
            let id = try #require(h.bootstrap.layerSurfaceStore.surfaceID(for: layer.id))
            return try #require(h.bootstrap.layerSurfaceStore.readTexture(for: id))
        }
        let pixels = try h.bootstrap.textureSerializer.snapshotBatch(textures: textures)
        let residentPixels = h.bootstrap.historyController.residentByteCount
        let savedContent = h.bootstrap.historyController.currentContentStateID
        h.makeRectangleSelection()
        try await h.waitUntil { h.viewModel.workspace.selection.committedShape?.maskData != nil }
        let rectangle = try #require(h.viewModel.workspace.selection.committedShape)
        let revision = h.viewModel.selectionRevision
        #expect(h.bootstrap.historyController.residentByteCount == residentPixels)
        #expect(h.bootstrap.historyController.currentContentStateID == savedContent)
        #expect(h.viewModel.visibleHistoryTimeline.appliedEntries.last?.displayName == "选区操作")
        #expect(h.viewModel.sceneSnapshot.selectionShape == rectangle)
        #expect(h.viewModel.selectionOverlayProxy.displayShape == rectangle)

        h.viewModel.undo()
        try await h.waitUntil { !h.viewModel.isHistoryNavigating }
        #expect(h.viewModel.workspace.selection.committedShape == nil)
        #expect(h.viewModel.sceneSnapshot.selectionShape == nil)
        #expect(h.viewModel.selectionOverlayProxy.displayShape == nil)
        #expect(h.viewModel.selectionRevision > revision)
        let undoRevision = h.viewModel.selectionRevision
        h.viewModel.redo()
        try await h.waitUntil { !h.viewModel.isHistoryNavigating }
        #expect(h.viewModel.sceneSnapshot.selectionShape == rectangle)
        #expect(h.viewModel.selectionOverlayProxy.displayShape == rectangle)
        #expect(h.viewModel.selectionRevision > undoRevision)
        #expect(!h.viewModel.hasUnsavedChanges)

        h.viewModel.selectAllCanvas()
        let allCanvas = h.viewModel.workspace.selection.committedShape
        h.viewModel.prepareVisibleHistoryPresentation()
        h.viewModel.previewVisibleHistory(toAppliedEntryCount: 0)
        try await h.waitUntil { !h.viewModel.isHistoryNavigating }
        #expect(h.viewModel.sceneSnapshot.selectionShape == nil)
        #expect(h.viewModel.selectionOverlayProxy.displayShape == nil)
        h.viewModel.cancelVisibleHistoryPreview()
        try await h.waitUntil { !h.viewModel.isHistoryNavigating }
        #expect(h.viewModel.sceneSnapshot.selectionShape == allCanvas)
        #expect(h.viewModel.selectionOverlayProxy.displayShape == allCanvas)
        #expect(!h.viewModel.hasUnsavedChanges)
        #expect(h.bootstrap.historyController.currentContentStateID == savedContent)
        #expect(h.bootstrap.historyController.residentByteCount == residentPixels)
        for (index, layer) in layers.enumerated() {
            let id = try #require(h.bootstrap.layerSurfaceStore.surfaceID(for: layer.id))
            let texture = try #require(h.bootstrap.layerSurfaceStore.readTexture(for: id))
            #expect(texture === textures[index])
            #expect(try h.bootstrap.textureSerializer.snapshot(texture: texture) == pixels[index])
        }
    }

    @Test func clearingSelectionKeepsSavedContentCleanAndRejectsFailedHistoryCapture() async throws {
        let h = try TransactionHarness()
        defer { h.cleanUp() }
        try h.paintFixturePatch()
        h.viewModel.hasUnsavedChanges = true
        try await h.saveProject(named: "before-selection-clear")
        h.makeRectangleSelection()
        try await h.waitUntil { h.viewModel.workspace.selection.committedShape?.maskData != nil }
        let selection = h.viewModel.workspace.selection
        let texture = try h.texture()
        let pixels = try h.snapshot()
        let timeline = h.viewModel.visibleHistoryTimeline
        let stateID = h.bootstrap.historyController.currentStateID
        let contentID = h.bootstrap.historyController.currentContentStateID
        let residentPixels = h.bootstrap.historyController.residentByteCount
#if DEBUG
        h.bootstrap.historyController.debugPreventsCheckpointCapture = true
        defer { h.bootstrap.historyController.debugPreventsCheckpointCapture = false }
        h.viewModel.clearSelection()
        #expect(h.viewModel.status?.kind == .error)
        #expect(h.viewModel.workspace.selection == selection)
        #expect(h.viewModel.sceneSnapshot.selectionShape == selection.committedShape)
        #expect(h.viewModel.selectionOverlayProxy.displayShape == selection.committedShape)
        #expect(h.viewModel.visibleHistoryTimeline == timeline)
        #expect(h.bootstrap.historyController.currentStateID == stateID)
        #expect(h.bootstrap.historyController.currentContentStateID == contentID)
        #expect(!h.viewModel.hasUnsavedChanges)
        h.bootstrap.historyController.debugPreventsCheckpointCapture = false
#endif
        h.viewModel.clearSelection()
        #expect(h.viewModel.workspace.selection.committedShape == nil)
        #expect(h.viewModel.sceneSnapshot.selectionShape == nil)
        #expect(h.viewModel.selectionOverlayProxy.displayShape == nil)
        #expect(h.viewModel.visibleHistoryTimeline.currentAppliedEntryCount == timeline.currentAppliedEntryCount + 1)
        #expect(h.bootstrap.historyController.currentStateID != stateID)
        #expect(h.bootstrap.historyController.currentContentStateID == contentID)
        #expect(h.bootstrap.historyController.residentByteCount == residentPixels)
        #expect(!h.viewModel.hasUnsavedChanges)

        h.viewModel.undo()
        try await h.waitUntil { !h.viewModel.isHistoryNavigating }
        #expect(h.viewModel.workspace.selection.committedShape == selection.committedShape)
        #expect(h.viewModel.selectionOverlayProxy.displayShape == selection.committedShape)
        #expect(h.bootstrap.historyController.currentContentStateID == contentID)
        #expect(!h.viewModel.hasUnsavedChanges)
        h.viewModel.redo()
        try await h.waitUntil { !h.viewModel.isHistoryNavigating }
        #expect(h.viewModel.workspace.selection.committedShape == nil)
        #expect(h.viewModel.selectionOverlayProxy.displayShape == nil)
        #expect(h.bootstrap.historyController.currentContentStateID == contentID)
        #expect(!h.viewModel.hasUnsavedChanges)
        #expect(h.bootstrap.historyController.residentByteCount == residentPixels)
        #expect(try h.texture() === texture)
        #expect(try h.snapshot() == pixels)
    }

    @Test func generatorCompletedAfterMetadataUndoCannotPublishIntoTheRestoredState() async throws {
        let h = try TransactionHarness()
        defer { h.cleanUp() }
        h.viewModel.setActiveLayerOpacity(0.7)
        h.viewModel.hasUnsavedChanges = false
        let pixels = try h.snapshot()
        let texture = try h.texture()
        let cursor = h.contentCursor

        // Both actions run in one MainActor turn. Publication cannot interleave,
        // even if the small background rasterization finishes immediately.
        h.viewModel.applyGeneratorToActiveLayer()
        #expect(h.viewModel.status?.message.hasPrefix("正在生成") == true)
        h.viewModel.undo()
        let timeline = h.viewModel.visibleHistoryTimeline
        let stateID = h.bootstrap.historyController.currentStateID
        let contentStateID = h.bootstrap.historyController.currentContentStateID
        #expect(h.opacity == 1)
        #expect(h.viewModel.canRedo)
        #expect(h.viewModel.hasUnsavedChanges)

        try await h.waitUntil {
            h.viewModel.status?.message.contains("过期生成结果") == true
        }
        #expect(try h.snapshot() == pixels)
        #expect(try h.texture() === texture)
        #expect(h.contentCursor == cursor)
        #expect(h.viewModel.visibleHistoryTimeline == timeline)
        #expect(h.bootstrap.historyController.currentStateID == stateID)
        #expect(h.bootstrap.historyController.currentContentStateID == contentStateID)
        #expect(h.viewModel.hasUnsavedChanges)
        h.viewModel.redo()
        #expect(h.opacity == 0.7)
        #expect(!h.viewModel.hasUnsavedChanges)
    }

#if DEBUG
    @Test func failedGeneratorRestorePreservesPixelsHistoryAndRedoThenAllowsRetry() async throws {
        let h = try TransactionHarness()
        defer { h.cleanUp() }
        h.viewModel.setActiveLayerOpacity(0.7)
        h.viewModel.undo()
        h.viewModel.hasUnsavedChanges = false
        let pixels = try h.snapshot()
        let texture = try h.texture()
        let cursor = h.contentCursor
        let timeline = h.viewModel.visibleHistoryTimeline
        let stateID = h.bootstrap.historyController.currentStateID
        let contentStateID = h.bootstrap.historyController.currentContentStateID
        #expect(h.viewModel.canRedo)

        h.bootstrap.textureSerializer.debugRejectsRestoreCompletion = true
        defer { h.bootstrap.textureSerializer.debugRejectsRestoreCompletion = false }
        h.viewModel.applyGeneratorToActiveLayer()
        try await h.waitUntil { h.viewModel.status?.kind == .error }

        #expect(try h.snapshot() == pixels)
        #expect(try h.texture() === texture)
        #expect(h.contentCursor == cursor)
        #expect(h.viewModel.visibleHistoryTimeline == timeline)
        #expect(h.bootstrap.historyController.currentStateID == stateID)
        #expect(h.bootstrap.historyController.currentContentStateID == contentStateID)
        #expect(h.viewModel.canRedo)
        #expect(!h.viewModel.hasUnsavedChanges)

        h.bootstrap.textureSerializer.debugRejectsRestoreCompletion = false
        h.viewModel.redo()
        #expect(h.opacity == 0.7)
        h.viewModel.undo()
        h.viewModel.applyGeneratorToActiveLayer()
        try await h.waitUntil {
            h.viewModel.status?.kind == .success &&
                h.viewModel.status?.message.contains("生成器") == true
        }
        #expect(try h.snapshot() != pixels)
        #expect(h.viewModel.visibleHistoryTimeline.currentAppliedEntryCount == timeline.currentAppliedEntryCount + 1)
        #expect(!h.viewModel.canRedo)
        #expect(h.viewModel.hasUnsavedChanges)
    }

    @Test func failedTransformHistoryCaptureKeepsDraftAndOriginalPixelsForRetry() async throws {
        let h = try TransactionHarness()
        defer { h.cleanUp() }
        try h.paintFixturePatch()
        h.makeRectangleSelection()
        // A geometry-only selection is still awaiting its exact raster mask.
        // Finish that independent job before injecting a history failure.
        try await h.waitUntil { h.viewModel.workspace.selection.committedShape?.maskData != nil }
        h.viewModel.selectTool(.freeTransform)
        h.viewModel.beginSelectionTransform(at: .init(x: 20, y: 20), mode: .move)
        h.viewModel.updateSelectionTransform(to: .init(x: 32, y: 20))
        h.viewModel.commitSelectionTransform(at: .init(x: 32, y: 20))
        #expect(h.viewModel.isTransformingSelection)
        #expect(!h.viewModel.freeTransformPreview.isIdentity)
        let draft = h.viewModel.freeTransformPreview
        let selection = h.viewModel.workspace.selection.committedShape
        let pixels = try h.snapshot()
        let texture = try h.texture()
        let cursor = h.contentCursor
        let timeline = h.viewModel.visibleHistoryTimeline
        let stateID = h.bootstrap.historyController.currentStateID
        let contentStateID = h.bootstrap.historyController.currentContentStateID
        let wasDirty = h.viewModel.hasUnsavedChanges

        h.bootstrap.historyController.debugPreventsCheckpointCapture = true
        defer { h.bootstrap.historyController.debugPreventsCheckpointCapture = false }
        h.viewModel.applySelectionTransform()
        #expect(h.viewModel.isApplyingTransformCommit)
        try await h.waitUntil { !h.viewModel.isApplyingTransformCommit }

        #expect(h.viewModel.status?.kind == .error)
        #expect(h.viewModel.isTransformingSelection)
        #expect(h.viewModel.freeTransformPreview == draft)
        #expect(h.viewModel.workspace.selection.committedShape == selection)
        #expect(try h.snapshot() == pixels)
        #expect(try h.texture() === texture)
        #expect(h.contentCursor == cursor)
        #expect(h.viewModel.visibleHistoryTimeline == timeline)
        #expect(h.bootstrap.historyController.currentStateID == stateID)
        #expect(h.bootstrap.historyController.currentContentStateID == contentStateID)
        #expect(h.viewModel.hasUnsavedChanges == wasDirty)

        h.bootstrap.historyController.debugPreventsCheckpointCapture = false
        h.viewModel.applySelectionTransform()
        try await h.waitUntil { !h.viewModel.isApplyingTransformCommit }
        #expect(!h.viewModel.isTransformingSelection)
        #expect(h.viewModel.freeTransformPreview.isIdentity)
        #expect(try h.snapshot() != pixels)
        #expect(h.viewModel.visibleHistoryTimeline.currentAppliedEntryCount == timeline.currentAppliedEntryCount + 1)
        h.viewModel.undo()
        #expect(try h.snapshot() == pixels)
    }
#endif

    @Test(arguments: [false, true])
    func editingDuringOrAfterLongHistoryPreviewCannotBeDiscardedByCancel(waitForPreview: Bool) async throws {
        let h = try TransactionHarness()
        defer { h.cleanUp() }
        for opacity in [Float(0.8), 0.6, 0.4] { h.viewModel.setActiveLayerOpacity(opacity) }
        h.viewModel.hasUnsavedChanges = false
        let pixels = try h.snapshot()
        h.viewModel.prepareVisibleHistoryPresentation()
        h.viewModel.previewVisibleHistory(toAppliedEntryCount: 0)
        #expect(h.viewModel.isHistoryNavigating)
        if waitForPreview {
            try await h.waitUntil { !h.viewModel.isHistoryNavigating }
            #expect(h.viewModel.visibleHistoryTimeline.currentAppliedEntryCount == 0)
        }

        // Editing either an in-flight preparation or an accepted preview must
        // abandon its origin. Cancelling later cannot restore an obsolete point.
        h.viewModel.setActiveLayerOpacity(0.2)
        let editedTimeline = h.viewModel.visibleHistoryTimeline
        let editedState = h.bootstrap.historyController.currentStateID
        #expect(!h.viewModel.isHistoryNavigating)
        #expect(h.viewModel.visibleHistoryPreviewTargetCount == nil)
        #expect(h.viewModel.hasUnsavedChanges)
        h.viewModel.cancelVisibleHistoryPreview()
        #expect(h.opacity == 0.2)
        #expect(h.viewModel.hasUnsavedChanges)

        // Complete a fresh navigation to the beginning and back. For the
        // in-flight case this is another long asynchronous jump, exercising
        // cancellation-generation isolation from the old task.
        h.viewModel.navigateVisibleHistory(toAppliedEntryCount: 0)
        try await h.waitUntil { !h.viewModel.isHistoryNavigating }
        h.viewModel.navigateVisibleHistory(toAppliedEntryCount: editedTimeline.currentAppliedEntryCount)
        try await h.waitUntil { !h.viewModel.isHistoryNavigating }
        h.viewModel.cancelVisibleHistoryPreview()
        #expect(h.opacity == 0.2)
        #expect(h.bootstrap.historyController.currentStateID == editedState)
        #expect(h.viewModel.visibleHistoryTimeline == editedTimeline)
        #expect(h.viewModel.hasUnsavedChanges)
        #expect(try h.snapshot() == pixels)
    }
}

@MainActor
private struct TransactionHarness {
    let bootstrap: AppBootstrap
    let viewModel: WorkspaceViewModel
    let root: URL

    init() throws {
        _ = NSApplication.shared
        let metal = try #require(MetalDeviceContext())
        let store = WorkspaceStore()
        store.updateDocument { $0.canvasSize = .init(width: 64, height: 64) }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ArtFlex-Transaction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        bootstrap = try AppBootstrap(workspaceStore: store, metalContext: metal,
            layerSurfaceStore: StageOneLayerSurfaceStore(),
            persistenceRecoveryRootURL: root.appendingPathComponent("Recovery"))
        viewModel = WorkspaceViewModel(bootstrap: bootstrap, installsZoomKeyboardMonitor: false)
    }

    var layerID: LayerID { viewModel.workspace.document.activeLayerID }
    var opacity: Float? { viewModel.workspace.document.layer(layerID)?.opacity }
    var contentCursor: LayerChangeCursor {
        bootstrap.layerSurfaceStore.changeJournal(for: .init(layerID: layerID, kind: .content)).cursor
    }

    func texture() throws -> MTLTexture {
        let surfaceID = try #require(bootstrap.layerSurfaceStore.surfaceID(for: layerID))
        return try #require(bootstrap.layerSurfaceStore.readTexture(for: surfaceID))
    }

    func snapshot() throws -> LayerTextureSnapshot {
        try bootstrap.textureSerializer.snapshot(texture: texture())
    }

    func paintFixturePatch() throws {
        let surfaceID = try #require(bootstrap.layerSurfaceStore.surfaceID(for: layerID))
        let region = PixelRegion(originX: 12, originY: 12, width: 12, height: 12)
        let texture = try #require(bootstrap.layerSurfaceStore.writableTexture(for: surfaceID, region: region))
        var bytes = Data(count: 12 * 12 * 4)
        bytes.withUnsafeMutableBytes { output in
            for offset in stride(from: 0, to: output.count, by: 4) {
                CanvasPixelCodec.write(.init(red: 0.25, green: 0.5, blue: 0.75, alpha: 1),
                    into: output, offset: offset, encoding: .premultipliedBGRA8SRGB)
            }
        }
        try bootstrap.textureSerializer.restore(
            snapshot: .init(width: 12, height: 12, bytesPerRow: 48, pixelData: bytes),
            into: texture, destinationX: 12, destinationY: 12)
        bootstrap.layerSurfaceStore.markContentUnknown(for: layerID)
    }

    func makeRectangleSelection() {
        let start = CanvasPoint(x: 8, y: 8)
        let end = CanvasPoint(x: 32, y: 32)
        viewModel.selectTool(.rectangleSelection)
        viewModel.beginSelection(kind: .rectangle, at: start, modifiers: [])
        viewModel.updateSelection(to: end, modifiers: [])
        viewModel.commitSelection(at: end, modifiers: [])
    }

    func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<1_000 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(predicate(), "Transaction completion timed out: \(viewModel.status?.message ?? "no status")")
    }

    func beginSave(named name: String) -> Bool {
        let url = root.appendingPathComponent("\(name).artflex")
        bootstrap.filePanelService.selectURLsForTesting = { _, finish in finish([url]) }
        return viewModel.saveProject()
    }

    func saveProject(named name: String) async throws {
        try #require(beginSave(named: name))
        try await waitUntil { !viewModel.isProjectSaving }
        try #require(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(name).artflex").path))
        try #require(!viewModel.hasUnsavedChanges)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

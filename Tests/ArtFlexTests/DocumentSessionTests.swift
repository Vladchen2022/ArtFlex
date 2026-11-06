import AppKit
import Foundation
import Testing
@testable import ArtFlex

@MainActor
struct DocumentSessionTests {
    @Test(arguments: [false, true])
    func recoveryFailureOrCancellationNeverOwnsOrRemovesSource(cancel: Bool) async throws {
        let (documents, root) = try make()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Documents/crashed")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let oldGeneration = source.appendingPathComponent("Autosave-2.artflex")
        let bytes = Data("damaged but irreplaceable recovery evidence".utf8)
        try bytes.write(to: oldGeneration)
        documents.refreshRecoverable()
        #expect(documents.recoverable.contains { RecoveryCatalog.identity($0.id) == RecoveryCatalog.identity(source) })
        let previous = documents.activeID
        documents.recover(.init(id: source, name: "失败恢复"))
        #expect(documents.sessions.last?.bootstrap.persistenceController.recoveryProjectURL.deletingLastPathComponent() != source)
        if cancel { documents.active.cancelProjectOpen() }
        for _ in 0..<300 where documents.sessions.count > 1 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(documents.sessions.count == 1)
        #expect(documents.activeID == previous)
        #expect(try Data(contentsOf: oldGeneration) == bytes)
        #expect(documents.recoverable.contains { RecoveryCatalog.identity($0.id) == RecoveryCatalog.identity(source) })
    }

    @Test func recoveryCatalogFindsBranchAndOlderGenerationsWithoutFollowingLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let branch = root.appendingPathComponent("Documents/doc/Branches/session/2")
        try FileManager.default.createDirectory(at: branch, withIntermediateDirectories: true)
        try Data([1]).write(to: branch.appendingPathComponent("Autosave-3.artflex"))
        #expect(RecoveryCatalog.roots(in: root).map(RecoveryCatalog.identity) == [RecoveryCatalog.identity(branch)])
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Documents/linked"),
            withDestinationURL: branch)
        #expect(RecoveryCatalog.roots(in: root).map(RecoveryCatalog.identity) == [RecoveryCatalog.identity(branch)])
    }

    private func make() throws -> (DocumentSessionController, URL) {
        var state = WorkspaceState.stageOneDefault
        state.document.canvasSize = .init(width: 32, height: 32)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bootstrap = try AppBootstrap(workspaceStore: .init(state: state), persistenceRecoveryRootURL: root)
        let model = WorkspaceViewModel(bootstrap: bootstrap, installsZoomKeyboardMonitor: false)
        return (.init(bootstrap: bootstrap, model: model), root)
    }

    @Test func documentsKeepIndependentHistoryFileIdentityAndRecoveryWithSharedMetal() throws {
        let (documents, root) = try make()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = documents.sessions[0]
        first.model.addLayer()
        let count = first.model.workspace.document.layers.count
        documents.create(name: "第二稿", size: .init(width: 32, height: 32), dpi: 300, format: .rgba8)
        #expect(documents.sessions.count == 2)
        let second = try #require(documents.sessions.last)
        #expect(documents.active === second.model)
        #expect(first.bootstrap.metalContext === second.bootstrap.metalContext)
        #expect(first.bootstrap.sharedMetalServices === second.bootstrap.sharedMetalServices)
        #expect(first.bootstrap.persistenceController.recoveryProjectURL != second.bootstrap.persistenceController.recoveryProjectURL)
        #expect(!first.model.isSessionActive && second.model.isSessionActive)
        second.model.addLayer(); second.model.addLayer(); second.model.undo()
        #expect(first.model.workspace.document.layers.count == count)
        #expect(documents.activate(first.id))
        first.model.undo()
        #expect(first.model.workspace.document.layers.count == count - 1)
        #expect(second.model.workspace.document.layers.count == count)
        #expect(first.model.workspace.document.metadata.drawingStatsID != second.model.workspace.document.metadata.drawingStatsID)
    }

    @Test func documentsUseOneLiveLibraryAndUndoCannotRewindOtherDocumentsEdits() throws {
        let (documents, root) = try make()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = documents.sessions[0]
        documents.create(name: "第二稿", size: .init(width: 32, height: 32), dpi: 300, format: .rgba8)
        let second = documents.sessions[1]
        #expect(first.bootstrap.libraryServices === second.bootstrap.libraryServices)
        let oldDocument = first.bootstrap.workspaceStore.state
        let preset = BrushPreset(id: "shared", name: "跨文档画笔", brush: .stageOneDefault, isBuiltIn: false, slotIndex: 0)
        first.bootstrap.workspaceStore.updateBrushLibrary { $0.presets.append(preset); $0.selectedPresetID = preset.id }
        #expect(second.model.workspace.brushLibrary.presets.contains(preset))
        #expect(second.model.workspace.brushLibrary.selectedPresetID != preset.id)
        second.bootstrap.workspaceStore.updateBrushLibrary { $0.presets.removeAll { $0.id == preset.id } }
        first.bootstrap.workspaceStore.replaceState(oldDocument)
        #expect(!first.bootstrap.workspaceStore.state.brushLibrary.presets.contains(preset))
        second.bootstrap.workspaceStore.updateBrushLibrary { $0.presets.append(preset) }
        first.bootstrap.workspaceStore.replaceState(oldDocument)
        #expect(first.bootstrap.workspaceStore.state.brushLibrary.presets.contains(preset))
    }

    @Test func quitWaitsForSharedWritesAndRejectsUnresolvedFailure() async throws {
        let (documents, root) = try make()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = documents.sessions[0].bootstrap.libraryServices.writes
        queue.enqueue(key: "failure") { throw CocoaError(.fileWriteNoPermission) } onError: { _ in }
        var result: Bool?
        documents.confirmCloseAll { result = $0 }
        #expect(result == nil)
        for _ in 0..<100 where result == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(result == false)
        queue.enqueue(key: "failure") {} onError: { _ in }
        result = nil
        documents.confirmCloseAll { result = $0 }
        for _ in 0..<100 where result == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(result == true)
    }

    @Test func saveAsRejectsAnotherOpenDocumentAndAliasesWithoutChangingEither() async throws {
        let (documents, root) = try make()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = documents.sessions[0]
        let url = root.appendingPathComponent("owned.artflex")
        first.bootstrap.filePanelService.selectURLsForTesting = { _, reply in reply([url]) }
        first.model.addLayer()
        #expect(first.model.saveProject())
        for _ in 0..<500 where first.model.isProjectSaving { try await Task.sleep(for: .milliseconds(10)) }
        let saved = try Data(contentsOf: url)
        documents.create(name: "第二稿", size: .init(width: 32, height: 32), dpi: 300, format: .rgba8)
        let second = documents.sessions[1]
        let alias = root.appendingPathComponent("hardlink.artflex")
        try FileManager.default.linkItem(at: url, to: alias)
        second.bootstrap.filePanelService.selectURLsForTesting = { _, reply in reply([alias]) }
        var accepted: Bool?
        _ = second.model.saveProject(asNewFile: true) { accepted = $0 }
        #expect(accepted == false)
        #expect(second.model.documentFileURL == nil)
        #expect(try Data(contentsOf: url) == saved)
        #expect(second.model.status?.message.contains("另一个文档") == true)
        documents.open(alias)
        #expect(documents.active === first.model)
        #expect(documents.sessions.count == 2)
    }

    @Test func processLedgerIncludesHistoryFromInactiveDocuments() throws {
        let (documents, root) = try make()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = documents.sessions[0]
        try first.bootstrap.historyController.captureCheckpoint()
        let firstHistory = first.bootstrap.historyController.residentByteCount
        #expect(firstHistory > 0)
        documents.create(name: "第二稿", size: .init(width: 32, height: 32), dpi: 300, format: .rgba8)
        let second = documents.sessions[1]
        let ledger = first.bootstrap.metalContext.resourceLedger
        let before = ledger.refresh()
        try second.bootstrap.historyController.captureCheckpoint()
        let secondHistory = second.bootstrap.historyController.residentByteCount
        #expect(secondHistory > 0)
        #expect(ledger.refresh() >= before + secondHistory)
        #expect(ledger.refresh(excluding: second.model) >= firstHistory)
    }

    @Test func switchingWithPendingAdjustmentIsRejectedAndDoesNotHideDraft() throws {
        let (documents, root) = try make()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = documents.activeID
        documents.create(name: "第二稿", size: .init(width: 32, height: 32), dpi: 300, format: .rgba8)
        let current = documents.activeID
        documents.active.beginEditableLayer(documents.active.workspace.document.activeLayerID)
        #expect(documents.active.editableLayerDraft != nil)
        #expect(!documents.activate(first))
        #expect(documents.activeID == current)
        #expect(documents.active.editableLayerDraft != nil)
        documents.active.editableLayerDraft = nil
        #expect(documents.activate(first))
    }

    @Test(arguments: [false, true])
    func failedOrCancelledOpenReturnsToPreviousDocumentWithoutAnEmptyTab(cancel: Bool) async throws {
        let (documents, root) = try make()
        defer { try? FileManager.default.removeItem(at: root) }
        documents.create(name: "保留的画稿", size: .init(width: 32, height: 32), dpi: 300, format: .rgba8)
        let previous = documents.activeID
        documents.active.addLayer()
        let layers = documents.active.workspace.document.layers
        documents.open(root.appendingPathComponent("missing.artflex"))
        #expect(documents.sessions.count == 3)
        if cancel { documents.active.cancelProjectOpen() }
        for _ in 0..<300 where documents.sessions.count == 3 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(documents.sessions.count == 2)
        #expect(documents.activeID == previous)
        #expect(documents.active.workspace.document.layers == layers)
        #expect(documents.active.hasUnsavedChanges)
        #expect(documents.active.status?.kind == (cancel ? .info : .error))
        if cancel { #expect(documents.active.status?.message.contains("已取消") == true) }
    }

    @Test func layerTransferPreservesSourceAndSupportsDestinationUndo() async throws {
        let (documents, root) = try make()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = documents.sessions[0]
        let before = first.model.workspace.document.layers
        documents.create(name: "第二稿", size: .init(width: 32, height: 32), dpi: 300, format: .rgba8)
        let second = documents.sessions[1]
        let sourceBefore = second.model.workspace.document.layers
        documents.copyActiveLayer(to: first.id)
        for _ in 0..<500 where documents.isTransferring { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!documents.isTransferring)
        #expect(second.model.workspace.document.layers == sourceBefore)
        #expect(first.model.workspace.document.layers.count == before.count + 2)
        first.model.undo()
        #expect(first.model.workspace.document.layers == before)
    }
    @Test func quitChecksEveryDocumentAndCancellationKeepsBothEditable() throws {
        let (documents, root) = try make()
        defer { try? FileManager.default.removeItem(at: root) }
        documents.active.addLayer()
        documents.create(name: "第二稿", size: .init(width: 32, height: 32), dpi: 300, format: .rgba8)
        var firstPrompt = false, secondPrompt = false
        documents.sessions[0].bootstrap.filePanelService.confirmForTesting = { reply in firstPrompt = true; reply(.alertSecondButtonReturn) }
        documents.sessions[1].bootstrap.filePanelService.confirmForTesting = { reply in secondPrompt = true; reply(.alertThirdButtonReturn) }
        var allowed: Bool?
        documents.confirmCloseAll { allowed = $0 }
        #expect(firstPrompt && secondPrompt)
        #expect(allowed == false)
        #expect(documents.sessions.count == 2)
        #expect(documents.sessions.allSatisfy { $0.model.hasUnsavedChanges })
    }

    @Test func smallerDestinationRetainsOutsidePixelsAndLargerRestoresThem() throws {
        var state = WorkspaceState.stageOneDefault
        state.document.canvasSize = .init(width: 32, height: 16)
        let snapshot = LayerTextureSnapshot(width: 32, height: 16, bytesPerRow: 128, pixelData: Data(repeating: 123, count: 32 * 16 * 4))
        let payload = ProjectArchivePayload(package: .fromWorkspace(state,
            layerSnapshots: state.document.paintLayers.map { .init(layerID: $0.id, texture: snapshot) }), referenceImages: [])
        let id = state.document.activeLayerID
        let small = try LayerImportCanvasAdapter.adapt(payload, included: [id], to: .init(width: 16, height: 8))
        #expect(small.package.document.cropRetention?.tiles.isEmpty == false)
        _ = try small.package.document.cropRetention?.validated(for: small.package.document)
        let large = try LayerImportCanvasAdapter.adapt(small, included: [id], to: state.document.canvasSize)
        #expect(large.package.layerSnapshots.first?.texture == snapshot)
        #expect(large.package.document.cropRetention?.tiles.isEmpty == true)
    }

}

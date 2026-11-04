import AppKit
import Foundation
import Testing
@testable import ArtFlex

@MainActor
struct DocumentSessionTests {
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

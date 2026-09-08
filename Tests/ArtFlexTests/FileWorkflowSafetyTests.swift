import AppKit
import Foundation
import ImageIO
import Testing
@testable import ArtFlex

@Suite(.serialized)
@MainActor
struct FileWorkflowSafetyTests {
    @Test func temporaryHistoryPreviewCannotReplaceTheRecoveryProject() async throws {
        let h = try FileWorkflowHarness()
        defer { h.cleanUp() }
        h.viewModel.addLayer()
        let realLayerCount = h.viewModel.workspace.document.layers.count
        h.viewModel.debugPerformRecoveryAutosaveNowForTests()
        try await h.waitUntil { !h.viewModel.debugRecoveryAutosaveWriteInFlight }
        let recovery = h.bootstrap.persistenceController.recoveryProjectURL
        let realBackup = try Data(contentsOf: recovery)
        h.viewModel.prepareVisibleHistoryPresentation()
        h.viewModel.previewVisibleHistory(toAppliedEntryCount: 0)
        #expect(h.viewModel.workspace.document.layers.count == realLayerCount - 1)
        h.viewModel.debugPerformRecoveryAutosaveNowForTests()
        try await h.waitUntil { !h.viewModel.debugRecoveryAutosaveWriteInFlight }
        #expect(try Data(contentsOf: recovery) == realBackup)
        #expect(!h.viewModel.debugRecoveryAutosaveIsScheduled)
        #expect(try h.bootstrap.persistenceController.openProject(from: recovery).workspace.document.layers.count == realLayerCount)
        h.viewModel.cancelVisibleHistoryPreview()
        #expect(h.viewModel.workspace.document.layers.count == realLayerCount)
        #expect(h.viewModel.debugRecoveryAutosaveIsScheduled)
        h.viewModel.debugPerformRecoveryAutosaveNowForTests()
        try await h.waitUntil { !h.viewModel.debugRecoveryAutosaveWriteInFlight }
        #expect(try h.bootstrap.persistenceController.openProject(from: recovery).workspace.document.layers.count == realLayerCount)
    }

    @Test func manualSaveWaitsForHistoryPreviewToBeAppliedOrCancelled() async throws {
        let h = try FileWorkflowHarness()
        defer { h.cleanUp() }
        h.viewModel.addLayer()
        h.viewModel.prepareVisibleHistoryPresentation()
        h.viewModel.previewVisibleHistory(toAppliedEntryCount: 0)
        let output = h.root.appendingPathComponent("chosen-history.artflex")
        h.select(output)
        var completed: Bool?
        let accepted = h.viewModel.saveProject { completed = $0 }
        try await h.waitUntil { completed != nil }
        #expect(!accepted && completed == false)
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(h.viewModel.visibleHistoryPreviewTargetCount == 0)
        h.viewModel.applyVisibleHistoryPreview()
        completed = nil
        #expect(h.viewModel.saveProject { completed = $0 })
        try await h.waitUntil { completed != nil }
        #expect(completed == true)
        #expect(try h.bootstrap.persistenceController.openProject(from: output).workspace.document.layers.count == h.viewModel.workspace.document.layers.count)
    }

    @Test func recoveryFrozenBeforeHistoryPreviewStillInstallsTheAcceptedCanvas() async throws {
        let h = try FileWorkflowHarness()
        defer { h.cleanUp() }
        h.viewModel.addLayer()
        let originalCount = h.viewModel.workspace.document.layers.count
        h.viewModel.debugPerformRecoveryAutosaveNowForTests()
        #expect(h.viewModel.debugRecoveryAutosaveWriteInFlight)
        h.viewModel.prepareVisibleHistoryPresentation()
        h.viewModel.previewVisibleHistory(toAppliedEntryCount: 0)
        try await h.waitUntil { !h.viewModel.debugRecoveryAutosaveWriteInFlight }
        #expect(h.viewModel.workspace.document.layers.count == originalCount - 1)
        let recovery = h.bootstrap.persistenceController.recoveryProjectURL
        #expect(try h.bootstrap.persistenceController.openProject(from: recovery).workspace.document.layers.count == originalCount)
        h.viewModel.cancelVisibleHistoryPreview()
    }

    @Test func appliedHistoryStateCanBecomeTheNextRecoveryPoint() async throws {
        let h = try FileWorkflowHarness()
        defer { h.cleanUp() }
        h.viewModel.addLayer()
        h.viewModel.prepareVisibleHistoryPresentation()
        h.viewModel.previewVisibleHistory(toAppliedEntryCount: 0)
        h.viewModel.debugExpireRecoveryAutosaveDeadlineForTests()
        h.viewModel.debugPerformRecoveryAutosaveNowForTests()
        #expect(!h.viewModel.debugRecoveryAutosaveWriteInFlight)
        #expect(!h.viewModel.debugRecoveryAutosaveIsScheduled)
        #expect(!h.bootstrap.persistenceController.hasRecoveryProject)
        h.viewModel.applyVisibleHistoryPreview()
        #expect(h.viewModel.debugRecoveryAutosaveIsScheduled)
        h.viewModel.debugPerformRecoveryAutosaveNowForTests()
        try await h.waitUntil { !h.viewModel.debugRecoveryAutosaveWriteInFlight }
        #expect(h.bootstrap.persistenceController.hasRecoveryProject)
        #expect(try h.bootstrap.persistenceController.openProject(from: h.bootstrap.persistenceController.recoveryProjectURL).workspace.document.layers == h.viewModel.workspace.document.layers)
    }

    @Test func onlyOneFileDialogAndOneCompletionAreAllowed() {
        _ = NSApplication.shared
        let service = FilePanelService()
        var pending: (([URL]?) -> Void)?
        var presentations = 0
        service.selectURLsForTesting = { _, finish in presentations += 1; pending = finish }
        var responses: [URL?] = []
        service.presentProjectSavePanel(defaultName: "first") { responses.append($0) }
        #expect(service.isPresentingDialog)
        service.presentProjectOpenPanel { responses.append($0) }
        #expect(presentations == 1)
        #expect(responses.count == 1 && responses[0] == nil)
        let url = URL(fileURLWithPath: "/tmp/first.artflex")
        pending?([url])
        pending?(nil)
        #expect(responses.count == 2 && responses[1] == url)
        #expect(!service.isPresentingDialog)
    }

    @Test func multipleImageSelectionAndCancellationPreserveTheirMeaning() {
        _ = NSApplication.shared
        let service = FilePanelService()
        let urls = [URL(fileURLWithPath: "/tmp/one.png"), URL(fileURLWithPath: "/tmp/two.png")]
        service.selectURLsForTesting = { panel, finish in
            #expect((panel as? NSOpenPanel)?.allowsMultipleSelection == true)
            finish(urls)
        }
        var selected: [URL]?
        service.presentImageOpenPanelURLs(allowsMultipleSelection: true) { selected = $0 }
        #expect(selected == urls)
        service.selectURLsForTesting = { _, finish in finish(nil) }
        service.presentImageOpenPanelURLs { selected = $0 }
        #expect(selected == nil)
    }

    @Test func confirmationReleasesDialogBeforeStartingSavePanel() {
        _ = NSApplication.shared
        let service = FilePanelService()
        service.confirmForTesting = { finish in finish(.alertFirstButtonReturn) }
        var didPresentSave = false
        service.selectURLsForTesting = { _, finish in didPresentSave = true; finish(nil) }
        service.presentUnsavedChangesConfirmation(message: "test", detail: "test") { _ in
            #expect(!service.isPresentingDialog)
            service.presentProjectSavePanel(defaultName: "test") { _ in }
        }
        #expect(didPresentSave)
        #expect(!service.isPresentingDialog)
    }

    @Test func thumbnailIsBoundedAndMalformedDataIsRejected() throws {
        let context = try #require(CGContext(data: nil, width: 1200, height: 300, bitsPerComponent: 8,
            bytesPerRow: 4800, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 300))
        let image = try #require(context.makeImage())
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let thumbnail = try #require(FilePanelService.projectThumbnail(from: data))
        #expect(thumbnail.width == 256)
        #expect(thumbnail.height == 64)
        #expect(FilePanelService.projectThumbnail(from: Data("invalid".utf8)) == nil)
    }

    @Test func cancelledSaveKeepsNameDirtyStateAndAllowsRetry() throws {
        let h = try FileWorkflowHarness()
        defer { h.cleanUp() }
        h.makeDirty()
        h.bootstrap.filePanelService.selectURLsForTesting = { _, finish in finish(nil) }
        var result: Bool?
        h.viewModel.saveProject { result = $0 }
        #expect(result == false)
        #expect(h.viewModel.workspace.document.metadata.name == "original")
        #expect(h.viewModel.hasUnsavedChanges)
        #expect(!h.viewModel.isProjectSaving)
        #expect(!h.bootstrap.filePanelService.isPresentingDialog)
    }

    @Test func saveFailureKeepsOriginalNameAndRetrySucceeds() async throws {
        let h = try FileWorkflowHarness()
        defer { h.cleanUp() }
        h.makeDirty()
        let blocker = h.root.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: blocker)
        h.select(blocker.appendingPathComponent("failed.artflex"))
        var saved: Bool?
        h.viewModel.saveProject { saved = $0 }
        try await h.waitUntil { saved != nil }
        #expect(saved == false)
        #expect(h.viewModel.workspace.document.metadata.name == "original")
        #expect(h.viewModel.hasUnsavedChanges)
        let output = h.root.appendingPathComponent("retry.artflex")
        h.select(output)
        saved = nil
        h.viewModel.saveProject { saved = $0 }
        try await h.waitUntil { saved != nil }
        #expect(saved == true)
        #expect(!h.viewModel.hasUnsavedChanges)
        #expect(h.viewModel.workspace.document.metadata.name == "retry")
        #expect(try h.bootstrap.persistenceController.openProject(from: output).workspace.document.canvasSize.width == 8)
    }

    @Test func choosingSavePositionBlocksDuplicateSaveAndNewDocument() throws {
        let h = try FileWorkflowHarness()
        defer { h.cleanUp() }
        h.makeDirty()
        var pending: (([URL]?) -> Void)?
        h.bootstrap.filePanelService.selectURLsForTesting = { _, finish in pending = finish }
        #expect(h.viewModel.saveProject())
        #expect(!h.viewModel.saveProject())
        h.viewModel.createNewCanvasDiscardingUnsavedChanges(name: "must-not-replace", canvasSize: .init(width: 16, height: 16), resolutionDPI: 72)
        #expect(h.viewModel.workspace.document.metadata.name == "original")
        var allowed: Bool?
        h.viewModel.confirmCloseOrQuitIfNeeded { allowed = $0 }
        #expect(allowed == false)
        pending?(nil)
        #expect(!h.bootstrap.filePanelService.isPresentingDialog)
    }

    @Test func newDocumentWaitsForConfirmedSaveToFinish() async throws {
        let h = try FileWorkflowHarness()
        defer { h.cleanUp() }
        h.makeDirty()
        let output = h.root.appendingPathComponent("saved-before-new.artflex")
        h.select(output)
        h.bootstrap.filePanelService.confirmForTesting = { $0(.alertFirstButtonReturn) }
        h.viewModel.createNewCanvas(name: "new-document", canvasSize: .init(width: 16, height: 16), resolutionDPI: 72)
        #expect(h.viewModel.workspace.document.metadata.name == "original")
        #expect(h.viewModel.isProjectSaving)
        try await h.waitUntil { !h.viewModel.isProjectSaving }
        #expect(h.viewModel.workspace.document.metadata.name == "new-document")
        #expect(h.viewModel.workspace.document.canvasSize.width == 16)
        #expect(try h.bootstrap.persistenceController.openProject(from: output).workspace.document.canvasSize.width == 8)
    }

    @Test func cancelledSaveBeforeOpenKeepsOriginalDocument() throws {
        let h = try FileWorkflowHarness()
        defer { h.cleanUp() }
        h.makeDirty()
        h.bootstrap.filePanelService.confirmForTesting = { $0(.alertFirstButtonReturn) }
        h.bootstrap.filePanelService.selectURLsForTesting = { _, finish in finish(nil) }
        h.viewModel.openProject(from: h.root.appendingPathComponent("another.artflex"), isRecovery: false)
        #expect(!h.viewModel.isProjectOpening)
        #expect(h.viewModel.workspace.document.metadata.name == "original")
        #expect(h.viewModel.hasUnsavedChanges)
    }

    @Test func closeWaitsForWriteAndEditsDuringWritePreventClose() async throws {
        let h = try FileWorkflowHarness()
        defer { h.cleanUp() }
        h.makeDirty()
        h.select(h.root.appendingPathComponent("before-close.artflex"))
        h.bootstrap.filePanelService.confirmForTesting = { $0(.alertFirstButtonReturn) }
        var allowed: Bool?
        h.viewModel.confirmCloseOrQuitIfNeeded { allowed = $0 }
        #expect(allowed == nil)
        #expect(h.viewModel.isProjectSaving)
        h.viewModel.setActiveLayerOpacity(0.5)
        try await h.waitUntil { allowed != nil }
        #expect(allowed == false)
        #expect(h.viewModel.hasUnsavedChanges)
        let activeID = h.viewModel.workspace.document.activeLayerID
        #expect(h.viewModel.workspace.document.layers.first { $0.id == activeID }?.opacity == 0.5)
    }

    @Test func invalidProjectNeverReplacesCurrentDocument() async throws {
        let h = try FileWorkflowHarness()
        defer { h.cleanUp() }
        let input = h.root.appendingPathComponent("corrupt.artflex")
        try Data("not an archive".utf8).write(to: input)
        h.makeDirty()
        h.bootstrap.filePanelService.confirmForTesting = { $0(.alertSecondButtonReturn) }
        h.viewModel.openProject(from: input, isRecovery: false)
        try await h.waitUntil { !h.viewModel.isProjectOpening }
        #expect(h.viewModel.workspace.document.metadata.name == "original")
        #expect(h.viewModel.hasUnsavedChanges)
    }

    @Test func cancelledNewAndCloseNeverDiscardDirtyDocument() throws {
        let h = try FileWorkflowHarness()
        defer { h.cleanUp() }
        h.makeDirty()
        h.bootstrap.filePanelService.confirmForTesting = { $0(.alertThirdButtonReturn) }
        h.viewModel.createNewCanvas(name: "cancelled", canvasSize: .init(width: 16, height: 16), resolutionDPI: 72)
        var allowed: Bool?
        h.viewModel.confirmCloseOrQuitIfNeeded { allowed = $0 }
        #expect(allowed == false)
        #expect(h.viewModel.workspace.document.metadata.name == "original")
        #expect(h.viewModel.hasUnsavedChanges)
    }

    @Test func failedSaveBeforeNewDocumentDoesNotReplaceIt() async throws {
        let h = try FileWorkflowHarness()
        defer { h.cleanUp() }
        h.makeDirty()
        let blocker = h.root.appendingPathComponent("file")
        try Data([1]).write(to: blocker)
        h.select(blocker.appendingPathComponent("failed.artflex"))
        h.bootstrap.filePanelService.confirmForTesting = { $0(.alertFirstButtonReturn) }
        h.viewModel.createNewCanvas(name: "must-not-create", canvasSize: .init(width: 16, height: 16), resolutionDPI: 72)
        try await h.waitUntil { !h.viewModel.isProjectSaving }
        #expect(h.viewModel.workspace.document.metadata.name == "original")
        #expect(h.viewModel.hasUnsavedChanges)
    }

    @Test func successfulSaveAllowsCloseOnlyAfterArchiveExists() async throws {
        let h = try FileWorkflowHarness()
        defer { h.cleanUp() }
        h.makeDirty()
        let output = h.root.appendingPathComponent("before-close.artflex")
        h.select(output)
        h.bootstrap.filePanelService.confirmForTesting = { $0(.alertFirstButtonReturn) }
        var allowed: Bool?
        h.viewModel.confirmCloseOrQuitIfNeeded { allowed = $0 }
        #expect(allowed == nil)
        try await h.waitUntil { allowed != nil }
        #expect(allowed == true)
        #expect(try h.bootstrap.persistenceController.openProject(from: output).workspace.document.canvasSize.width == 8)
    }

    @Test func editsWhileOpeningKeepCurrentDocumentInsteadOfReplacingIt() async throws {
        let h = try FileWorkflowHarness()
        defer { h.cleanUp() }
        let input = h.root.appendingPathComponent("another.artflex")
        try h.bootstrap.persistenceController.saveProject(to: input)
        h.viewModel.openProject(from: input, isRecovery: false)
        #expect(h.viewModel.isProjectOpening)
        h.viewModel.setActiveLayerOpacity(0.4)
        try await h.waitUntil { !h.viewModel.isProjectOpening }
        #expect(h.viewModel.workspace.document.metadata.name == "original")
        #expect(h.viewModel.hasUnsavedChanges)
        #expect(h.viewModel.status?.message.contains("保留当前工程") == true)
    }

    @Test func reschedulingRecoveryDoesNotInvalidateAnUnchangedSave() async throws {
        let h = try FileWorkflowHarness()
        defer { h.cleanUp() }
        h.makeDirty()
        h.select(h.root.appendingPathComponent("unchanged.artflex"))
        var saved: Bool?
        h.viewModel.saveProject { saved = $0 }
        h.viewModel.applicationDidResignActiveForPersistence()
        try await h.waitUntil { saved != nil }
        #expect(saved == true)
        #expect(!h.viewModel.hasUnsavedChanges)
    }
}

@MainActor
private struct FileWorkflowHarness {
    let bootstrap: AppBootstrap
    let viewModel: WorkspaceViewModel
    let root: URL

    init() throws {
        _ = NSApplication.shared
        let metal = try #require(MetalDeviceContext())
        let store = WorkspaceStore()
        store.updateDocument { document in
            document.metadata.name = "original"
            document.canvasSize = .init(width: 8, height: 8)
        }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ArtFlex-FileWorkflow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        bootstrap = try AppBootstrap(workspaceStore: store, metalContext: metal, layerSurfaceStore: StageOneLayerSurfaceStore(),
            persistenceRecoveryRootURL: root.appendingPathComponent("Recovery"))
        viewModel = WorkspaceViewModel(bootstrap: bootstrap, installsZoomKeyboardMonitor: false)
    }

    func makeDirty() { viewModel.setActiveLayerOpacity(0.8) }
    func select(_ url: URL) { bootstrap.filePanelService.selectURLsForTesting = { _, finish in finish([url]) } }
    func cleanUp() { try? FileManager.default.removeItem(at: root) }
    func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(predicate(), "File operation timed out")
    }
}

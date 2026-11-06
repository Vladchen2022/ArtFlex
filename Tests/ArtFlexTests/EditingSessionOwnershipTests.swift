import Foundation
import Testing
import ArtFlexPolicies
@testable import ArtFlex

struct EditingSessionOwnershipTests {
    @MainActor private func make() throws -> WorkspaceViewModel {
        var state = WorkspaceState.stageOneDefault
        state.document.canvasSize = .init(width: 64, height: 64)
        return WorkspaceViewModel(bootstrap: try AppBootstrap(workspaceStore: WorkspaceStore(state: state)), installsZoomKeyboardMonitor: false)
    }

    @Test @MainActor func disposalInvalidatesTasksGPURequestsAndDraftsTogether() async throws {
        let sessions = WorkspaceEditingSessions()
        let cancellation = WorkCancellation()
        sessions.bucketFillCancellation = cancellation
        sessions.isBucketFillInProgress = true
        sessions.transformCommitRequestID = UUID()
        sessions.isApplyingTransformCommit = true
        sessions.colorAdjustmentPreviewRenderInFlight = true
        sessions.isPreparingDocumentEdit = true
        var published = false
        sessions.preparation.submit { token in
            while !token.isCancelled { Thread.sleep(forTimeInterval: 0.001) }
            try token.check()
        } completion: { _ in published = true }
        #expect(DocumentPersistencePolicy.blocksAutomaticCapture(sessions.persistenceActivity))
        sessions.disposeForReplacement()
        try await Task.sleep(for: .milliseconds(30))
        #expect(cancellation.isCancelled && !published)
        #expect(sessions.transformCommitRequestID == nil)
        #expect(sessions.colorAdjustmentPreviewToken == 1 && sessions.curveAdjustmentPreviewToken == 1)
        #expect(!sessions.colorAdjustmentPreviewRenderInFlight && !sessions.preparation.isRunning)
        #expect(sessions.persistenceActivity.isEmpty && sessions.generation == 1)
    }

    @Test @MainActor func staleMenuActionsRecheckDocumentAndDraftBeforeMutation() async throws {
        let vm = try make()
        let command = try #require(vm.command("newLayer"))
        let before = vm.workspace.document.layers.count
        vm.beginEditableLayer(vm.workspace.document.activeLayerID)
        #expect(vm.command("newLayer")?.unavailableReason != nil)
        command.action()
        #expect(vm.workspace.document.layers.count == before)
        vm.undo() // Cancels preparation, not the previous accepted edit.
        try await Task.sleep(for: .milliseconds(50))
        #expect(vm.editableLayerDraft == nil && !vm.isPreparingDocumentEdit)
        command.action()
        #expect(vm.workspace.document.layers.count == before + 1)
        vm.isSessionActive = false
        command.action()
        #expect(vm.workspace.document.layers.count == before + 1)
    }

    @Test @MainActor func menusSearchAndZoomResolveTheActiveBranchAtExecution() throws {
        let host = try make()
        host.updateCanvasViewportSize(.init(width: 900, height: 700))
        host.adjustViewportZoom(byScaleMultiplier: 2)
        host.startIdeationSession()
        let session = try #require(host.ideationSession)
        session.focusSelectedBranchCanvas()
        let branch = try #require(host.ideationActiveBranchViewModel)
        branch.updateCanvasViewportSize(.init(width: 400, height: 300))
        let beforeHost = host.workspace.viewport.zoomScale
        let beforeBranch = branch.workspace.viewport.zoomScale
        let command = try #require(host.command("zoomIn"))
        command.action()
        #expect(host.workspace.viewport.zoomScale == beforeHost)
        #expect(abs(branch.workspace.viewport.zoomScale - beforeBranch * 1.2) < 0.001)
        branch.performCommand("fit")
        #expect(branch.workspace.viewport.zoomScale == 1)
        #expect(host.workspace.viewport.zoomScale == beforeHost)
        #expect(branch.commandRoot === host)
        let layerCount = branch.workspace.document.layers.count
        host.performCommand("newLayer")
        #expect(branch.workspace.document.layers.count == layerCount + 1)
        #expect(host.workspace.document.layers.count == layerCount)
    }

    @Test @MainActor func toolSwitchRetiresPendingSourcePreparation() async throws {
        let vm = try make()
        vm.beginEditableLayer(vm.workspace.document.activeLayerID)
        vm.selectTool(.eraser)
        try await Task.sleep(for: .milliseconds(100))
        #expect(vm.workspace.toolSession.activeTool == .eraser)
        #expect(vm.editableLayerDraft == nil && !vm.isPreparingDocumentEdit)
    }

    @Test @MainActor func retainedGradientCapturePublishesOnlyAfterPreparingItsSource() async throws {
        let vm = try make()
        vm.retainsEditableFillParameters = true
        vm.selectTool(.linearGradient)
        vm.beginGradientDrag(at: .init(x: 5, y: 10), modifiers: [])
        vm.updateGradientDrag(to: .init(x: 45, y: 30), modifiers: [])
        vm.endGradientDrag(at: .init(x: 45, y: 30), modifiers: [])
        vm.applyActiveGradientSession()
        #expect(vm.isPreparingDocumentEdit)
        #expect(vm.workspace.document.layer(vm.workspace.document.activeLayerID)?.editableContent == nil)
        try await vm.waitForDocumentPreparation()
        for _ in 0..<200 where vm.isApplyingGradientCommit { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!vm.isApplyingGradientCommit)
        #expect(vm.workspace.document.layer(vm.workspace.document.activeLayerID)?.editableContent != nil)
        vm.undo()
        #expect(vm.workspace.document.layer(vm.workspace.document.activeLayerID)?.editableContent == nil)
        vm.redo()
        #expect(vm.workspace.document.layer(vm.workspace.document.activeLayerID)?.editableContent != nil)
    }
}

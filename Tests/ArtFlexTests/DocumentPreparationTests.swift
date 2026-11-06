import Foundation
import Testing
@testable import ArtFlex

extension WorkspaceViewModel {
    @MainActor func waitForDocumentPreparation() async throws {
        let end = ContinuousClock.now + .seconds(60)
        while isPreparingDocumentEdit, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
        try #require(!isPreparingDocumentEdit)
    }
}

struct DocumentPreparationTests {
    @Test @MainActor func cancellationCannotPublishAndOtherDocumentRemainsResponsive() async throws {
        let a = DocumentPreparationCoordinator(), b = DocumentPreparationCoordinator()
        var firstPublished = false, secondPublished = false
        a.submit { token in
            #expect(!Thread.isMainThread)
            while !token.isCancelled { Thread.sleep(forTimeInterval: 0.001) }
            try token.check()
            return 1
        } completion: { _ in firstPublished = true }
        b.submit { _ in 2 } completion: { _ in secondPublished = true }
        for _ in 0..<100 where !secondPublished { try await Task.sleep(for: .milliseconds(5)) }
        #expect(secondPublished)
        a.cancel()
        try await Task.sleep(for: .milliseconds(30))
        #expect(!firstPublished && !a.isRunning)
    }

    @Test @MainActor func cancelledCropKeepsPixelsHistoryAndCanvas() async throws {
        var state = WorkspaceState.stageOneDefault
        state.document.canvasSize = .init(width: 128, height: 128)
        let bootstrap = try AppBootstrap(workspaceStore: WorkspaceStore(state: state))
        let vm = WorkspaceViewModel(bootstrap: bootstrap, installsZoomKeyboardMonitor: false)
        vm.selectTool(.canvasCrop)
        vm.beginCanvasCrop(at: .init(x: 16, y: 16), handleRadius: 1)
        vm.endCanvasCrop(at: .init(x: 100, y: 100))
        vm.applyCanvasCrop()
        #expect(vm.isPreparingDocumentEdit)
        #expect(vm.workspace.document.canvasSize == state.document.canvasSize)
        vm.cancelCanvasCrop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(vm.workspace.document.canvasSize == state.document.canvasSize)
        #expect(!vm.canUndo && vm.canvasCropState.bounds == nil)
    }

    @Test @MainActor func staleSourceCaptureCannotOpenAnEditorForChangedDocument() async throws {
        var state = WorkspaceState.stageOneDefault
        state.document.canvasSize = .init(width: 64, height: 64)
        let bootstrap = try AppBootstrap(workspaceStore: WorkspaceStore(state: state))
        let vm = WorkspaceViewModel(bootstrap: bootstrap, installsZoomKeyboardMonitor: false)
        vm.beginEditableLayer(state.document.activeLayerID)
        vm.cancelDocumentPreparation()
        vm.addLayer()
        try await Task.sleep(for: .milliseconds(100))
        #expect(vm.editableLayerDraft == nil)
        #expect(vm.workspace.document.layers.count == state.document.layers.count + 1)
    }
}

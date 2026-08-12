import Foundation
import Metal
import Testing
@testable import ArtFlex

struct SavedSnapshotSessionTests {
    @Test
    @MainActor
    func defaultBootstrapUsesTemporaryPersistenceRootUnderSwiftTestingCLI() throws {
        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal unavailable")
            return
        }
        let bootstrap = try AppBootstrap(
            workspaceStore: WorkspaceStore(),
            metalContext: metalContext,
            layerSurfaceStore: StageOneLayerSurfaceStore()
        )
        let recoveryURL = bootstrap.persistenceController.recoveryProjectURL
        let isolatedTestRoot = recoveryURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        defer {
            if isolatedTestRoot.lastPathComponent.hasPrefix("ArtFlexTests-") {
                try? FileManager.default.removeItem(at: isolatedTestRoot)
            }
        }

        #expect(isolatedTestRoot.lastPathComponent.hasPrefix("ArtFlexTests-"))
        #expect(!recoveryURL.path.hasPrefix(NSHomeDirectory() + "/Library/Application Support/"))
    }

    @Test
    @MainActor
    func requestedSnapshotSaveRunsAsynchronouslyAndIgnoresRepeatedClicks() async throws {
        let harness = try SavedSnapshotHarness()

        harness.viewModel.requestSnapshotSavePrimaryAction()
        #expect(harness.viewModel.isSavingSnapshot)
        harness.viewModel.requestSnapshotSavePrimaryAction()

        for _ in 0..<200 where harness.viewModel.savedSnapshotCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(harness.viewModel.isSavingSnapshot == false)
        #expect(harness.viewModel.savedSnapshotCount == 1)
    }

    @Test
    @MainActor
    func clearingSnapshotsCancelsPendingSaveWithoutLateWriteback() async throws {
        let harness = try SavedSnapshotHarness()

        harness.viewModel.requestSnapshotSavePrimaryAction()
        #expect(harness.viewModel.isSavingSnapshot)

        harness.viewModel.clearSavedSnapshots()
        #expect(harness.viewModel.isSavingSnapshot == false)

        try await Task.sleep(for: .milliseconds(150))
        #expect(harness.viewModel.savedSnapshotCount == 0)
    }

    @Test
    @MainActor
    func savedSnapshotLargePreviewIsPreparedOnlyAfterSlotAssignment() async throws {
        let harness = try SavedSnapshotHarness()

        harness.viewModel.handleSnapshotSavePrimaryAction()
        let snapshotID = try #require(harness.viewModel.savedSnapshots.first?.id)
        #expect(harness.viewModel.savedSnapshots.first?.previewImage == nil)

        harness.viewModel.openSnapshotCompare()
        #expect(harness.viewModel.savedSnapshots.first?.previewImage == nil)
        harness.viewModel.assignSavedSnapshot(snapshotID, to: .topLeading)

        for _ in 0..<200 where harness.viewModel.savedSnapshots.first?.previewImage == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(harness.viewModel.savedSnapshots.first?.previewImage != nil)
    }

    @Test
    @MainActor
    func requestedSnapshotComparePreparesCompositeOffMainActor() async throws {
        let harness = try SavedSnapshotHarness()
        harness.viewModel.handleSnapshotSavePrimaryAction()

        harness.viewModel.requestOpenSnapshotCompare()
        #expect(harness.viewModel.isPreparingSnapshotCompare)
        #expect(harness.viewModel.snapshotCompareSession == nil)

        for _ in 0..<200 where harness.viewModel.snapshotCompareSession == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(harness.viewModel.isPreparingSnapshotCompare == false)
        #expect(harness.viewModel.snapshotCompareSession != nil)
    }

    @Test
    @MainActor
    func savingSnapshotsCapsAtSixAndOpensCompareOnTheNextAction() throws {
        let harness = try SavedSnapshotHarness()

        for _ in 0..<6 {
            harness.viewModel.handleSnapshotSavePrimaryAction()
        }

        #expect(harness.viewModel.savedSnapshotCount == 6)
        #expect(harness.viewModel.snapshotCompareSession == nil)

        harness.viewModel.handleSnapshotSavePrimaryAction()
        #expect(harness.viewModel.savedSnapshotCount == 6)
        #expect(harness.viewModel.snapshotCompareSession != nil)
    }

    @Test
    @MainActor
    func deletingSavedSnapshotClearsAssignedCompareSlot() throws {
        let harness = try SavedSnapshotHarness()

        harness.viewModel.handleSnapshotSavePrimaryAction()
        harness.viewModel.setSelectedColor(.init(red: 1, green: 0, blue: 0, alpha: 1))
        harness.viewModel.fillAtPoint(.init(x: 4, y: 4))
        harness.viewModel.handleSnapshotSavePrimaryAction()

        let firstSnapshotID = try #require(harness.viewModel.savedSnapshots.first?.id)

        harness.viewModel.openSnapshotCompare()
        let session = try #require(harness.viewModel.snapshotCompareSession)
        harness.viewModel.assignSavedSnapshot(firstSnapshotID, to: .topLeading)
        harness.viewModel.selectSavedSnapshotForCompare(firstSnapshotID)

        #expect(session.assignedSnapshotID(for: .topLeading) == firstSnapshotID)
        #expect(session.selectedSnapshotID == firstSnapshotID)

        harness.viewModel.deleteSavedSnapshot(firstSnapshotID)

        #expect(harness.viewModel.savedSnapshotCount == 1)
        #expect(session.assignedSnapshotID(for: .topLeading) == nil)
        #expect(session.selectedSnapshotID == nil)
    }

    @Test
    @MainActor
    func applyingSelectedSavedSnapshotAppendsCompositeAsNewLayer() throws {
        let harness = try SavedSnapshotHarness()
        let baseLayerID = harness.viewModel.workspace.document.activeLayerID

        harness.viewModel.setSelectedColor(.black)
        harness.viewModel.fillAtPoint(.init(x: 4, y: 4))
        harness.viewModel.handleSnapshotSavePrimaryAction()

        let savedSnapshotID = try #require(harness.viewModel.savedSnapshots.first?.id)

        harness.viewModel.setSelectedColor(.init(red: 1, green: 0, blue: 0, alpha: 1))
        harness.viewModel.fillAtPoint(.init(x: 4, y: 4))

        harness.viewModel.openSnapshotCompare()
        harness.viewModel.selectSavedSnapshotForCompare(savedSnapshotID)
        harness.viewModel.applySelectedSavedSnapshotToMainCanvas()

        #expect(harness.viewModel.snapshotCompareSession == nil)
        #expect(harness.viewModel.workspace.document.layers.count == 3)

        let appendedLayerID = harness.viewModel.workspace.document.activeLayerID
        #expect(appendedLayerID != baseLayerID)

        let appendedPixel = try harness.samplePixel(in: harness.viewModel, x: 8, y: 8, layerID: appendedLayerID)
        #expect(appendedPixel.alpha > 0.99)
        #expect(appendedPixel.red < 0.05)
        #expect(appendedPixel.green < 0.05)
        #expect(appendedPixel.blue < 0.05)
    }

    @Test
    @MainActor
    func visibleCompositeSnapshotPreservesVisibleLayerOpacity() throws {
        let harness = try SavedSnapshotHarness()

        harness.viewModel.setSelectedColor(.black)
        harness.viewModel.fillAtPoint(.init(x: 4, y: 4))
        harness.viewModel.setActiveLayerOpacity(0.5)

        let snapshot = try harness.viewModel.makeVisibleCompositeSnapshot()
        let sampled = try harness.samplePixel(in: snapshot, x: 8, y: 8)
        let expected = LinearPremultipliedColor.black
            .applyingOpacity(0.5)
            .composited(over: .white)
            .srgbUnpremultipliedOverOpaqueBackground

        #expect(abs(sampled.red - expected.red) < 0.03)
        #expect(abs(sampled.green - expected.green) < 0.03)
        #expect(abs(sampled.blue - expected.blue) < 0.03)
        #expect(sampled.alpha > 0.99)
    }

    @Test
    @MainActor
    func snapshotComparePausesActiveTimelapseAndResumesOnExit() throws {
        let harness = try SavedSnapshotHarness()
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            harness.viewModel.timelapseRecorder.stopRecording()
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        harness.viewModel.handleSnapshotSavePrimaryAction()
        harness.viewModel.timelapseRecorder.outputDirectory = tempDirectory
        harness.viewModel.toggleTimelapseRecording()
        #expect(harness.viewModel.timelapseRecorder.isRecording)

        harness.viewModel.openSnapshotCompare()
        #expect(harness.viewModel.timelapseRecorder.isRecording == false)

        harness.viewModel.toggleTimelapseRecording()
        #expect(harness.viewModel.timelapseRecorder.isRecording == false)

        harness.viewModel.cancelSnapshotCompare()
        #expect(harness.viewModel.timelapseRecorder.isRecording)
    }

    @Test
    @MainActor
    func recoveryAutosavePersistsSavedSnapshotsThroughBackgroundArchiveWrite() async throws {
        let harness = try SavedSnapshotHarness(canvasSize: .init(width: 16, height: 12))
        defer {
            try? FileManager.default.removeItem(at: harness.recoveryRootURL)
        }

        harness.viewModel.handleSnapshotSavePrimaryAction()
        let savedSnapshot = try #require(harness.viewModel.savedSnapshots.first)
        harness.viewModel.debugPerformRecoveryAutosaveNowForTests()

        for _ in 0..<300 where !harness.viewModel.hasRecoveryProject {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(harness.viewModel.hasRecoveryProject)
        let result = try harness.bootstrap.persistenceController.openProject(
            from: harness.bootstrap.persistenceController.recoveryProjectURL
        )
        #expect(result.savedSnapshots.count == 1)
        #expect(result.savedSnapshots.first?.descriptor.id == savedSnapshot.id)
        #expect(result.savedSnapshots.first?.pixels == savedSnapshot.snapshot)
    }

    @Test
    @MainActor
    func concurrentRecoveryAutosavesUseIsolatedInjectedLocations() async throws {
        let first = try SavedSnapshotHarness(canvasSize: .init(width: 12, height: 10))
        let second = try SavedSnapshotHarness(canvasSize: .init(width: 14, height: 8))
        defer {
            try? FileManager.default.removeItem(at: first.recoveryRootURL)
            try? FileManager.default.removeItem(at: second.recoveryRootURL)
        }

        #expect(
            first.bootstrap.persistenceController.recoveryProjectURL
                != second.bootstrap.persistenceController.recoveryProjectURL
        )
        first.viewModel.handleSnapshotSavePrimaryAction()
        second.viewModel.handleSnapshotSavePrimaryAction()
        let firstID = try #require(first.viewModel.savedSnapshots.first?.id)
        let secondID = try #require(second.viewModel.savedSnapshots.first?.id)

        first.viewModel.debugPerformRecoveryAutosaveNowForTests()
        second.viewModel.debugPerformRecoveryAutosaveNowForTests()
        for _ in 0..<300 where
            !first.viewModel.hasRecoveryProject || !second.viewModel.hasRecoveryProject {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(first.viewModel.hasRecoveryProject)
        #expect(second.viewModel.hasRecoveryProject)
        let firstResult = try first.bootstrap.persistenceController.openProject(
            from: first.bootstrap.persistenceController.recoveryProjectURL
        )
        let secondResult = try second.bootstrap.persistenceController.openProject(
            from: second.bootstrap.persistenceController.recoveryProjectURL
        )
        #expect(firstResult.savedSnapshots.first?.descriptor.id == firstID)
        #expect(secondResult.savedSnapshots.first?.descriptor.id == secondID)
        #expect(firstResult.workspace.document.canvasSize == .init(width: 12, height: 10))
        #expect(secondResult.workspace.document.canvasSize == .init(width: 14, height: 8))
    }
}

@MainActor
private struct SavedSnapshotHarness {
    let bootstrap: AppBootstrap
    let viewModel: WorkspaceViewModel
    let recoveryRootURL: URL

    init(canvasSize: CanvasSize = .init(width: 64, height: 64)) throws {
        guard let metalContext = MetalDeviceContext() else {
            throw SavedSnapshotHarnessError.metalUnavailable
        }
        let workspaceStore = WorkspaceStore(state: .stageOneDefault)
        workspaceStore.updateDocument { document in
            document.canvasSize = canvasSize
        }
        let recoveryRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ArtFlex-SavedSnapshotRecovery-\(UUID().uuidString)",
                isDirectory: true
            )
        let bootstrap = try AppBootstrap(
            workspaceStore: workspaceStore,
            metalContext: metalContext,
            layerSurfaceStore: StageOneLayerSurfaceStore(),
            persistenceRecoveryRootURL: recoveryRootURL
        )
        let viewModel = WorkspaceViewModel(bootstrap: bootstrap, installsZoomKeyboardMonitor: false)
        self.bootstrap = bootstrap
        self.viewModel = viewModel
        self.recoveryRootURL = recoveryRootURL
    }

    func samplePixel(
        in viewModel: WorkspaceViewModel,
        x: Int,
        y: Int,
        layerID: LayerID? = nil
    ) throws -> RGBAColor {
        let targetLayerID = layerID ?? viewModel.workspace.document.activeLayerID
        guard
            let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: targetLayerID),
            let texture = bootstrap.layerSurfaceStore.texture(for: surfaceID)
        else {
            throw SavedSnapshotHarnessError.textureUnavailable
        }
        return try bootstrap.textureSerializer.samplePixel(texture: texture, x: x, y: y)
    }

    func samplePixel(
        in snapshot: LayerTextureSnapshot,
        x: Int,
        y: Int
    ) throws -> RGBAColor {
        guard let texture = bootstrap.layerSurfaceStore.makeTexture(
            width: snapshot.width,
            height: snapshot.height,
            metal: bootstrap.metalContext
        ) else {
            throw SavedSnapshotHarnessError.textureUnavailable
        }
        try bootstrap.textureSerializer.restore(snapshot: snapshot, into: texture)
        return try bootstrap.textureSerializer.samplePixel(texture: texture, x: x, y: y)
    }
}

private enum SavedSnapshotHarnessError: Error {
    case metalUnavailable
    case textureUnavailable
}

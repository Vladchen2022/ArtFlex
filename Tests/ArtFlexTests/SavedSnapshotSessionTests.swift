import Foundation
import Metal
import Testing
@testable import ArtFlex

struct SavedSnapshotSessionTests {
    @Test
    @MainActor
    func savingSnapshotsCapsAtSixAndAutoOpensCompareOnSixthSave() throws {
        let harness = try SavedSnapshotHarness()

        for _ in 0..<6 {
            harness.viewModel.handleSnapshotSavePrimaryAction()
        }

        #expect(harness.viewModel.savedSnapshotCount == 6)
        #expect(harness.viewModel.snapshotCompareSession != nil)

        harness.viewModel.cancelSnapshotCompare()
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
        #expect(harness.viewModel.workspace.document.layers.count == 2)

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
}

@MainActor
private struct SavedSnapshotHarness {
    let bootstrap: AppBootstrap
    let viewModel: WorkspaceViewModel

    init(canvasSize: CanvasSize = .init(width: 64, height: 64)) throws {
        guard let metalContext = MetalDeviceContext() else {
            throw SavedSnapshotHarnessError.metalUnavailable
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
}

private enum SavedSnapshotHarnessError: Error {
    case metalUnavailable
    case textureUnavailable
}

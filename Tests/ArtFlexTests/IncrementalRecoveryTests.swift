import Foundation
import Testing
@testable import ArtFlex

struct IncrementalRecoveryTests {
    @Test @MainActor func legacyRecoveryUpgradesAndFailedStagingKeepsAcceptedGeneration() throws {
        let metal = try #require(MetalDeviceContext())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArtFlex-RecoveryUpgrade-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var workspace = WorkspaceState.stageOneDefault
        workspace.document.canvasSize = .init(width: 32, height: 32)
        let state = WorkspaceStore(state: workspace)
        let surfaces = StageOneLayerSurfaceStore()
        surfaces.prepareTextures(for: workspace.document, metal: metal)
        let controller = PersistenceController(workspaceStore: state, layerSurfaceStore: surfaces,
            serializer: .init(metalContext: metal), recoveryRootURL: root)
        try controller.saveRecoveryProject()
        let old = try controller.openProject(from: controller.recoveryProjectURL)
        let capture = try controller.freezeIncrementalRecovery()
        let stage = try controller.makeRecoveryStagingURL()
        try controller.writeIncrementalRecovery(capture, to: stage)
        try controller.installRecoveryProject(from: stage)
        let current = try controller.openProject(from: controller.recoveryProjectURL)
        #expect(current.layerSnapshots == old.layerSnapshots)
        #expect(try controller.openProject(from: root.appendingPathComponent("Autosave-1.artflex")).layerSnapshots == old.layerSnapshots)
        let badStage = try controller.makeRecoveryStagingURL()
        try Data([0]).write(to: badStage)
        #expect(throws: (any Error).self) {
            try controller.writeIncrementalRecovery(controller.freezeIncrementalRecovery(), to: badStage)
        }
        controller.discardRecoveryStagingProject(at: badStage)
        #expect(try controller.openProject(from: controller.recoveryProjectURL).layerSnapshots == current.layerSnapshots)
    }

    @Test @MainActor func changedTilesOnlyAreCapturedAndEveryGenerationOpensIndependently() throws {
        let metal = try #require(MetalDeviceContext())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArtFlex-Incremental-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var workspace = WorkspaceState.stageOneDefault
        workspace.document.canvasSize = .init(width: 1200, height: 1000)
        let state = WorkspaceStore(state: workspace)
        let surfaces = StageOneLayerSurfaceStore()
        surfaces.prepareTextures(for: workspace.document, metal: metal)
        let serializer = LayerTextureSerializer(metalContext: metal)
        let controller = PersistenceController(workspaceStore: state, layerSurfaceStore: surfaces,
            serializer: serializer, recoveryRootURL: root)
        let layerID = workspace.document.activeLayerID
        let id = try #require(surfaces.surfaceID(for: layerID))
        let first = try controller.freezeIncrementalRecovery()
        #expect(first.changedTiles.count == 12)
        let firstStage = try controller.makeRecoveryStagingURL()
        try controller.writeIncrementalRecovery(first, to: firstStage)
        try controller.installRecoveryProject(from: firstStage)
        let unchanged = try controller.freezeIncrementalRecovery()
        #expect(unchanged.changedTiles.isEmpty)
        let region = PixelRegion(originX: 100, originY: 50, width: 2, height: 2)
        let texture = try #require(surfaces.writableTexture(for: id, region: region))
        let pixels = Data(repeating: 127, count: 16)
        try serializer.restore(snapshot: .init(width: 2, height: 2, bytesPerRow: 8, pixelData: pixels),
                               into: texture, destinationX: 100, destinationY: 50)
        let second = try controller.freezeIncrementalRecovery()
        #expect(second.changedTiles.count == 1)
        #expect(second.copiedPixelBytes == 512 * 512 * 4)
        // Later edits cannot race the private regional clone.
        let live = try #require(surfaces.writableTexture(for: id, region: region))
        try serializer.restore(snapshot: .init(width: 2, height: 2, bytesPerRow: 8, pixelData: Data(count: 16)),
                               into: live, destinationX: 100, destinationY: 50)
        let secondStage = try controller.makeRecoveryStagingURL()
        try controller.writeIncrementalRecovery(second, to: secondStage)
        try controller.installRecoveryProject(from: secondStage)
        let restored = try controller.openProject(from: controller.recoveryProjectURL)
        let saved = try #require(restored.layerSnapshots.first { $0.layerID == layerID })
        #expect(saved.texture.pixelData[(50 * 1200 + 100) * 4] == 127)
        let backup = root.appendingPathComponent("Autosave-1.artflex")
        let older = try controller.openProject(from: backup)
        #expect(older.layerSnapshots.allSatisfy { $0.texture.pixelData.allSatisfy { $0 == 0 } })
        try FileManager.default.removeItem(at: backup)
        #expect(try controller.openProject(from: controller.recoveryProjectURL).layerSnapshots == restored.layerSnapshots)
        // Removing one hard-link owner does not remove any current-generation data.
        let manifest = try IncrementalRecoveryArchive.manifest(at: controller.recoveryProjectURL, limits: .standard)
        let file = try #require(manifest.resources.first?.tiles.first)
        try Data([255]).write(to: controller.recoveryProjectURL.appendingPathComponent("tiles").appendingPathComponent(file.filename), options: .atomic)
        #expect(throws: (any Error).self) { try controller.openProject(from: controller.recoveryProjectURL) }
    }
}

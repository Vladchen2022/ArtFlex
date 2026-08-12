import Foundation
import Testing
@testable import ArtFlex

struct ProjectPersistenceIntegrationTests {
    @Test
    @MainActor
    func persistenceRoutesArtflexPackagesAndKeepsLegacyJSONReadable() throws {
        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal unavailable")
            return
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtFlex-PersistenceIntegration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let recoveryRoot = root.appendingPathComponent("Recovery", isDirectory: true)

        var workspace = WorkspaceState.stageOneDefault
        workspace.document.canvasSize = CanvasSize(width: 4, height: 3)
        let workspaceStore = WorkspaceStore(state: workspace)
        let surfaces = StageOneLayerSurfaceStore()
        surfaces.prepareTextures(for: workspace.document, metal: metalContext)
        let controller = PersistenceController(
            workspaceStore: workspaceStore,
            layerSurfaceStore: surfaces,
            serializer: LayerTextureSerializer(metalContext: metalContext),
            recoveryRootURL: recoveryRoot
        )
        let reference = try ProjectReferenceImagePayload(
            slotIndex: 0,
            displayName: "reference.png",
            originalFilename: "reference.png",
            typeIdentifier: "public.png",
            pixelWidth: 1,
            pixelHeight: 1,
            encodedImageData: Data([1, 2, 3, 4])
        )
        let savedSnapshot = PersistentCanvasSnapshotPayload(
            descriptor: PersistentCanvasSnapshotDescriptor(
                displayName: "快照 1",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                canvasSize: workspace.document.canvasSize,
                pixelResourceID: CanvasPixelResourceID()
            ),
            pixels: LayerTextureSnapshot(
                width: 4,
                height: 3,
                bytesPerRow: 16,
                pixelData: Data(repeating: 23, count: 48)
            )
        )

        let packageURL = root.appendingPathComponent("Drawing.artflex", isDirectory: true)
        try controller.saveProject(
            to: packageURL,
            referenceImages: [reference],
            savedSnapshots: [savedSnapshot]
        )
        #expect(FileManager.default.fileExists(
            atPath: packageURL.appendingPathComponent("manifest.json").path
        ))
        let packageResult = try controller.openProject(from: packageURL)
        #expect(packageResult.storageFormat == .archiveV2)
        #expect(packageResult.referenceImages == [reference])
        #expect(packageResult.savedSnapshots == [savedSnapshot])
        #expect(packageResult.workspace.document.canvasSize == workspace.document.canvasSize)

        let legacyURL = root.appendingPathComponent("Legacy.artflex.json")
        try controller.saveProject(to: legacyURL)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: legacyURL.path, isDirectory: &isDirectory))
        #expect(!isDirectory.boolValue)
        let legacyResult = try controller.openProject(from: legacyURL)
        #expect(legacyResult.storageFormat == .legacyJSON)
        #expect(legacyResult.referenceImages.isEmpty)

        do {
            try controller.saveProject(
                to: legacyURL,
                referenceImages: [reference],
                savedSnapshots: [savedSnapshot]
            )
            Issue.record("Legacy JSON unexpectedly accepted V2-only assets")
        } catch PersistenceError.legacyFormatCannotStoreAssets {
            // Expected: callers cannot silently discard embedded assets.
        } catch {
            Issue.record("Unexpected legacy save error: \(error)")
        }
        #expect(try controller.openProject(from: legacyURL).storageFormat == .legacyJSON)

        try controller.saveRecoveryProject(
            referenceImages: [reference],
            savedSnapshots: [savedSnapshot]
        )
        #expect(controller.hasRecoveryProject)
        let recoveryResult = try controller.openProject(from: controller.recoveryProjectURL)
        #expect(recoveryResult.referenceImages == [reference])
        #expect(recoveryResult.savedSnapshots == [savedSnapshot])

        var replacementSnapshot = savedSnapshot
        replacementSnapshot.descriptor.id = UUID()
        replacementSnapshot.descriptor.pixelResourceID = CanvasPixelResourceID()
        replacementSnapshot.descriptor.displayName = "快照 2"
        replacementSnapshot.pixels.pixelData = Data(repeating: 91, count: 48)
        let capturedReplacement = try controller.captureProjectPayload(
            referenceImages: [reference],
            savedSnapshots: [savedSnapshot, replacementSnapshot]
        )
        let stagingURL = try controller.makeRecoveryStagingURL()
        try controller.writeCapturedProject(capturedReplacement, to: stagingURL)
        try controller.installRecoveryProject(from: stagingURL)
        #expect(
            try controller.openProject(from: controller.recoveryProjectURL).savedSnapshots
                == [savedSnapshot, replacementSnapshot]
        )
        try controller.discardRecoveryProject()
        #expect(!controller.hasRecoveryProject)
    }
}

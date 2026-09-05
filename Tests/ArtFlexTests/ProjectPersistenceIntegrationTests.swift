import Foundation
import Testing
@testable import ArtFlex

struct ProjectPersistenceIntegrationTests {
    @Test
    @MainActor
    func frozenSaveCaptureIsIndependentFromLaterCanvasEdits() throws {
        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal unavailable")
            return
        }
        var workspace = WorkspaceState.stageOneDefault
        workspace.document.canvasSize = .init(width: 4, height: 3)
        let store = WorkspaceStore(state: workspace)
        let surfaces = StageOneLayerSurfaceStore()
        surfaces.prepareTextures(for: workspace.document, metal: metalContext)
        let serializer = LayerTextureSerializer(metalContext: metalContext)
        let controller = PersistenceController(
            workspaceStore: store,
            layerSurfaceStore: surfaces,
            serializer: serializer
        )
        let layerID = workspace.document.activeLayerID
        let texture = try #require(
            surfaces.surfaceID(for: layerID).flatMap(surfaces.texture(for:))
        )
        let before = LayerTextureSnapshot(
            width: 4,
            height: 3,
            bytesPerRow: 16,
            pixelData: Data(repeating: 11, count: 48)
        )
        try serializer.restore(snapshot: before, into: texture)
        let frozen = try controller.freezeProjectCapture(previewTexture: texture)

        try serializer.restore(
            snapshot: .init(
                width: 4,
                height: 3,
                bytesPerRow: 16,
                pixelData: Data(repeating: 99, count: 48)
            ),
            into: texture
        )
        let payload = try controller.materializeProjectPayload(from: frozen)
        let captured = try #require(
            payload.package.layerSnapshots.first(where: { $0.layerID == layerID })
        )
        #expect(captured.texture.pixelData == before.pixelData)
        #expect(payload.previewPNGData?.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) == true)
    }

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

        let packageURL = root.appendingPathComponent("Drawing.artflex", isDirectory: false)
        try controller.saveProject(
            to: packageURL,
            referenceImages: [reference],
            savedSnapshots: [savedSnapshot]
        )
        var packageIsDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: packageURL.path, isDirectory: &packageIsDirectory))
        #expect(!packageIsDirectory.boolValue)
        let packageResult = try controller.openProject(from: packageURL)
        #expect(packageResult.storageFormat == .archiveV2)
        #expect(packageResult.referenceImages == [reference])
        #expect(packageResult.savedSnapshots == [savedSnapshot])
        #expect(packageResult.workspace.document.canvasSize == workspace.document.canvasSize)

        // Directory packages from previous releases remain readable and are upgraded in place on save.
        let legacyPackageURL = root.appendingPathComponent("LegacyPackage.artflex", isDirectory: true)
        let legacyPackagePayload = try controller.captureProjectPayload(
            referenceImages: [reference],
            savedSnapshots: [savedSnapshot]
        )
        try ProjectArchiveV2Writer().write(legacyPackagePayload, to: legacyPackageURL)
        #expect(try controller.openProject(from: legacyPackageURL).referenceImages == [reference])
        try controller.saveProject(
            to: legacyPackageURL,
            referenceImages: [reference],
            savedSnapshots: [savedSnapshot]
        )
        var upgradedIsDirectory: ObjCBool = true
        #expect(FileManager.default.fileExists(atPath: legacyPackageURL.path, isDirectory: &upgradedIsDirectory))
        #expect(!upgradedIsDirectory.boolValue)
        #expect(try controller.openProject(from: legacyPackageURL).savedSnapshots == [savedSnapshot])

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
        try controller.writeCapturedProject(
            capturedReplacement,
            to: stagingURL,
            recordsVersionBackup: false
        )
        try controller.installRecoveryProject(from: stagingURL)
        #expect(
            try controller.openProject(from: controller.recoveryProjectURL).savedSnapshots
                == [savedSnapshot, replacementSnapshot]
        )

        let firstBackupURL = recoveryRoot.appendingPathComponent(
            "Autosave-1.artflex",
            isDirectory: true
        )
        #expect(FileManager.default.fileExists(atPath: firstBackupURL.path))

        var thirdSnapshot = replacementSnapshot
        thirdSnapshot.descriptor.id = UUID()
        thirdSnapshot.descriptor.pixelResourceID = CanvasPixelResourceID()
        thirdSnapshot.descriptor.displayName = "快照 3"
        thirdSnapshot.pixels.pixelData = Data(repeating: 157, count: 48)
        let capturedThirdGeneration = try controller.captureProjectPayload(
            referenceImages: [reference],
            savedSnapshots: [savedSnapshot, replacementSnapshot, thirdSnapshot]
        )
        let thirdStagingURL = try controller.makeRecoveryStagingURL()
        try controller.writeCapturedProject(
            capturedThirdGeneration,
            to: thirdStagingURL,
            recordsVersionBackup: false
        )
        try controller.installRecoveryProject(from: thirdStagingURL)

        let secondBackupURL = recoveryRoot.appendingPathComponent(
            "Autosave-2.artflex",
            isDirectory: true
        )
        #expect(FileManager.default.fileExists(atPath: firstBackupURL.path))
        #expect(FileManager.default.fileExists(atPath: secondBackupURL.path))

        // A corrupt newest generation must not hide the verified older generation.
        try Data([0xff]).write(to: controller.recoveryProjectURL, options: .atomic)
        #expect(controller.bestAvailableRecoveryProjectURL() == firstBackupURL)

        // Even two torn generations must still expose the last complete fallback.
        try Data([0xfe]).write(to: firstBackupURL, options: .atomic)
        #expect(controller.bestAvailableRecoveryProjectURL() == secondBackupURL)
        try controller.discardRecoveryProject()
        #expect(!controller.hasRecoveryProject)
    }

    @Test
    @MainActor
    func recoveryRotationRetainsEightVerifiedGenerationsInOrder() throws {
        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal unavailable")
            return
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtFlex-RecoveryRotation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var workspace = WorkspaceState.stageOneDefault
        workspace.document.canvasSize = .init(width: 4, height: 3)
        let store = WorkspaceStore(state: workspace)
        let surfaces = StageOneLayerSurfaceStore()
        surfaces.prepareTextures(for: workspace.document, metal: metalContext)
        let controller = PersistenceController(
            workspaceStore: store,
            layerSurfaceStore: surfaces,
            serializer: LayerTextureSerializer(metalContext: metalContext),
            recoveryRootURL: root.appendingPathComponent("Recovery", isDirectory: true),
            versionBackupRootURL: root.appendingPathComponent("Versions", isDirectory: true)
        )

        for generation in 1...10 {
            var payload = try controller.captureProjectPayload()
            payload.package.document.metadata.name = "恢复代数 \(generation)"
            let stagingURL = try controller.makeRecoveryStagingURL()
            _ = try controller.writeCapturedProject(
                payload,
                to: stagingURL,
                recordsVersionBackup: false
            )
            try controller.installRecoveryProject(from: stagingURL)
        }

        let expectedNames = (2...10).reversed().map { "恢复代数 \($0)" }
        let candidates = [controller.recoveryProjectURL] + (1...8).map {
            controller.recoveryProjectURL.deletingLastPathComponent()
                .appendingPathComponent("Autosave-\($0).artflex")
        }
        let names = try candidates.map {
            try controller.inspectProject(from: $0).workspace.document.metadata.name
        }
        #expect(names == expectedNames)
    }

    @Test
    @MainActor
    func formalSavesKeepFiveVerifiedVersionBackupsWithoutBackingUpRecoveryWrites() throws {
        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal unavailable")
            return
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtFlex-VersionBackups-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var workspace = WorkspaceState.stageOneDefault
        workspace.document.canvasSize = .init(width: 4, height: 3)
        let documentID = workspace.document.metadata.drawingStatsID
        let store = WorkspaceStore(state: workspace)
        let surfaces = StageOneLayerSurfaceStore()
        surfaces.prepareTextures(for: workspace.document, metal: metalContext)
        let controller = PersistenceController(
            workspaceStore: store,
            layerSurfaceStore: surfaces,
            serializer: LayerTextureSerializer(metalContext: metalContext),
            recoveryRootURL: root.appendingPathComponent("Recovery", isDirectory: true),
            versionBackupRootURL: root.appendingPathComponent("Versions", isDirectory: true)
        )
        let destinationURL = root.appendingPathComponent("长期作业.artflex")

        for revision in 1...7 {
            var payload = try controller.captureProjectPayload()
            payload.package.document.metadata.name = "正式版本 \(revision)"
            let outcome = try controller.writeCapturedProject(payload, to: destinationURL)
            #expect(outcome.versionBackupURL != nil)
            #expect(outcome.versionBackupWarning == nil)
        }

        let backups = controller.projectVersionBackupURLs(for: documentID)
        #expect(backups.count == PersistenceController.maximumProjectVersionBackupCount)
        let backupNames = try backups.map {
            try controller.inspectProject(from: $0).workspace.document.metadata.name
        }
        #expect(backupNames == [
            "正式版本 7", "正式版本 6", "正式版本 5", "正式版本 4", "正式版本 3"
        ])

        var recoveryPayload = try controller.captureProjectPayload()
        recoveryPayload.package.document.metadata.name = "仅自动恢复"
        let stagingURL = try controller.makeRecoveryStagingURL()
        _ = try controller.writeCapturedProject(
            recoveryPayload,
            to: stagingURL,
            recordsVersionBackup: false
        )
        try controller.installRecoveryProject(from: stagingURL)
        #expect(controller.projectVersionBackupURLs(for: documentID).count == 5)
    }

    @Test
    func startupCleanupRemovesOnlyExpiredRecoveryStagingFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtFlex-StagingCleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let freshPending = root.appendingPathComponent("Pending-fresh.artflex")
        let oldPending = root.appendingPathComponent("Pending-old.artflex")
        let oldHiddenPending = root.appendingPathComponent(".Pending-Version-old.artflex")
        let ordinaryFile = root.appendingPathComponent("Autosave.artflex")
        for url in [freshPending, oldPending, oldHiddenPending, ordinaryFile] {
            try Data([1]).write(to: url)
        }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let oldDate = now.addingTimeInterval(-PersistenceController.staleRecoveryStagingAge - 1)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldPending.path)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldHiddenPending.path)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: ordinaryFile.path)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: freshPending.path)

        PersistenceController.discardStaleRecoveryStagingProjects(in: root, now: now)

        #expect(FileManager.default.fileExists(atPath: freshPending.path))
        #expect(!FileManager.default.fileExists(atPath: oldPending.path))
        #expect(!FileManager.default.fileExists(atPath: oldHiddenPending.path))
        #expect(FileManager.default.fileExists(atPath: ordinaryFile.path))
    }
}

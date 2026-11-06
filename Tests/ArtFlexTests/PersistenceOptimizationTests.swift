import Foundation
import Metal
import Testing
@testable import ArtFlex

@MainActor
struct PersistenceOptimizationTests {
    private struct Fixture {
        let metal: MetalDeviceContext
        let workspace: WorkspaceStore
        let surfaces: StageOneLayerSurfaceStore
        let serializer: LayerTextureSerializer
        let controller: PersistenceController
        let root: URL
    }

    private func fixture(format: ArtPixelFormat = .rgba8, cacheBytes: Int = 64 * 1024 * 1024) throws -> Fixture {
        let metal = try #require(MetalDeviceContext())
        var state = WorkspaceState.stageOneDefault
        state.document.canvasSize = .init(width: 64, height: 48)
        state.document.colorStandard = format == .rgba16Float ? .highPrecision : .stageOneDefault
        state.document.layers[0].mask = LayerMaskDescriptor()
        let workspace = WorkspaceStore(state: state)
        let surfaces = StageOneLayerSurfaceStore()
        surfaces.prepareTextures(for: state.document, metal: metal)
        let serializer = LayerTextureSerializer(metalContext: metal)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArtFlex-SaveReuse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let controller = PersistenceController(workspaceStore: workspace, layerSurfaceStore: surfaces,
            serializer: serializer, recoveryRootURL: root.appendingPathComponent("recovery"),
            versionBackupRootURL: root.appendingPathComponent("versions"), saveResourceCacheMaximumBytes: cacheBytes)
        return .init(metal: metal, workspace: workspace, surfaces: surfaces, serializer: serializer,
                     controller: controller, root: root)
    }

    @Test func unchangedSaveReusesContentAndMaskButChangedRegionInvalidatesOnlyItsResource() throws {
        for format in [ArtPixelFormat.rgba8, .rgba16Float] {
            let f = try fixture(format: format)
            defer { try? FileManager.default.removeItem(at: f.root) }
            let expected = try f.controller.captureProjectPayload()
            let first = try f.controller.enqueueProjectCapture().waitUntilReady()
            #expect(first.reusedLayerResources.isEmpty)
            let payload = try f.controller.materializeProjectPayload(from: first, reuseEncodedLayers: true)
            let destination = f.root.appendingPathComponent("test.artflex")
            try f.controller.writeCapturedProject(payload, to: destination, recordsVersionBackup: false)
            #expect(try f.controller.openProject(from: destination).layerSnapshots == expected.package.layerSnapshots)
            f.workspace.updateDocument { $0.metadata.name = "renamed" }
            let unchanged = try f.controller.enqueueProjectCapture().waitUntilReady()
            #expect(unchanged.layerResources.isEmpty)
            #expect(unchanged.reusedLayerResources.count == expected.package.layerSnapshots.count)
            let renamed = try f.controller.materializeProjectPayload(from: unchanged, reuseEncodedLayers: true)
            try f.controller.writeCapturedProject(renamed, to: destination, recordsVersionBackup: false)
            let reopened = try f.controller.openProject(from: destination)
            #expect(reopened.workspace.document.metadata.name == "renamed")
            #expect(reopened.layerSnapshots == expected.package.layerSnapshots)
            let layerID = f.workspace.state.document.activeLayerID
            let surfaceID = try #require(f.surfaces.surfaceID(for: layerID))
            let region = PixelRegion(originX: 3, originY: 5, width: 2, height: 2)
            let live = try #require(f.surfaces.writableTexture(for: surfaceID, region: region))
            let bpp = format.encoding.bytesPerPixel
            var bytes = Data(count: 4 * bpp)
            bytes.withUnsafeMutableBytes { output in
                for offset in stride(from: 0, to: output.count, by: bpp) {
                    CanvasPixelCodec.write(.init(red: 0.25, green: 0.5, blue: 0.75, alpha: 1),
                        into: output, offset: offset, encoding: format.encoding)
                }
            }
            let patch = LayerTextureSnapshot(width: 2, height: 2, bytesPerRow: 2 * bpp,
                pixelData: bytes, encoding: format.encoding)
            try f.serializer.restore(snapshot: patch, into: live, destinationX: 3, destinationY: 5)
            let changed = try f.controller.enqueueProjectCapture().waitUntilReady()
            #expect(changed.layerResources.count == 1)
            #expect(changed.layerResources.first?.layer.id == layerID)
            #expect(changed.reusedLayerResources.count == expected.package.layerSnapshots.count - 1)
            let changedPayload = try f.controller.materializeProjectPayload(from: changed, reuseEncodedLayers: true)
            try f.controller.writeCapturedProject(changedPayload, to: destination, recordsVersionBackup: false)
            #expect(try f.controller.openProject(from: destination).layerSnapshots == f.controller.captureProjectPayload().package.layerSnapshots)
            f.controller.purgeSaveResourceCache()
            #expect(try f.controller.enqueueProjectCapture().waitUntilReady().reusedLayerResources.isEmpty)
        }
    }

    @Test func zeroCacheBudgetFallsBackToFreshCapture() throws {
        let f = try fixture(cacheBytes: 0)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let first = try f.controller.enqueueProjectCapture().waitUntilReady()
        _ = try f.controller.materializeProjectPayload(from: first, reuseEncodedLayers: true)
        #expect(f.controller.cachedSaveResourceByteCount == 0)
        #expect(try f.controller.enqueueProjectCapture().waitUntilReady().reusedLayerResources.isEmpty)
    }

    @Test func queuedRegionReadbackFreezesPixelsAndSharesOneResult() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let layerID = f.workspace.state.document.activeLayerID
        let id = try #require(f.surfaces.surfaceID(for: layerID))
        let region = PixelRegion(originX: 7, originY: 9, width: 3, height: 4)
        let texture = try #require(f.surfaces.writableTexture(for: id, region: region))
        let original = LayerTextureSnapshot(width: 3, height: 4, bytesPerRow: 12,
                                            pixelData: Data(repeating: 99, count: 48))
        try f.serializer.restore(snapshot: original, into: texture, destinationX: 7, destinationY: 9)
        let read = try f.serializer.enqueueRegionSnapshots([.init(texture: texture,
            originX: 7, originY: 9, width: 3, height: 4)])
        try f.serializer.restore(snapshot: .init(width: 3, height: 4, bytesPerRow: 12,
            pixelData: Data(count: 48)), into: texture, destinationX: 7, destinationY: 9)
        #expect(try read.read() == [original])
        #expect(read.isReady)
        #expect(try read.read() == [original])
    }

    @Test func queuedRecoveryFreezeRetainsOldPixelsAcrossLaterWritesAndRejectsFailedCopy() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let expected = try f.controller.captureProjectPayload().package.layerSnapshots
        let queued = try f.controller.enqueueIncrementalRecovery()
        let layerID = f.workspace.state.document.activeLayerID
        let surfaceID = try #require(f.surfaces.surfaceID(for: layerID))
        let live = try #require(f.surfaces.writableTexture(for: surfaceID, region: nil))
        try f.serializer.restore(snapshot: .init(width: 1, height: 1, bytesPerRow: 4,
            pixelData: Data(repeating: 255, count: 4)), into: live, destinationX: 0, destinationY: 0)
        let capture = try queued.waitUntilReady()
        let stage = try f.controller.makeRecoveryStagingURL()
        try f.controller.writeIncrementalRecovery(capture, to: stage)
        try f.controller.installRecoveryProject(from: stage)
        #expect(try f.controller.openProject(from: f.controller.recoveryProjectURL).layerSnapshots == expected)
        f.serializer.debugRejectsDeferredCloneCompletion = true
        f.controller.invalidateIncrementalRecoveryBase()
        let failed = try f.controller.enqueueIncrementalRecovery()
        #expect(throws: (any Error).self) { try failed.waitUntilReady() }
        #expect(try f.controller.openProject(from: f.controller.recoveryProjectURL).layerSnapshots == expected)
    }

    @Test func reusedEncodedCorruptionCannotReplaceLastGoodProject() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let payload = try f.controller.materializeProjectPayload(from: f.controller.freezeProjectCapture(), reuseEncodedLayers: true)
        let destination = f.root.appendingPathComponent("test.artflex")
        try f.controller.writeCapturedProject(payload, to: destination, recordsVersionBackup: false)
        let before = try Data(contentsOf: destination)
        var corrupt = payload
        corrupt.encodedLayerResources[0].compressedPixels[0] ^= 0xff
        #expect(throws: (any Error).self) {
            try f.controller.writeCapturedProject(corrupt, to: destination, recordsVersionBackup: false)
        }
        #expect(try Data(contentsOf: destination) == before)
    }

    @Test func replacementWithSameLayerIDsDoesNotReusePriorDocumentPixels() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try f.controller.materializeProjectPayload(from: f.controller.freezeProjectCapture(), reuseEncodedLayers: true)
        #expect(try f.controller.enqueueProjectCapture().waitUntilReady().layerResources.isEmpty)
        f.surfaces.reset()
        f.surfaces.prepareTextures(for: f.workspace.state.document, metal: f.metal)
        #expect(try f.controller.enqueueProjectCapture().waitUntilReady().reusedLayerResources.isEmpty)
    }

    @Test func changedSourceDuringOpenIsRejectedAfterSingleExtraction() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let expected = try f.controller.captureProjectPayload()
        let file = f.root.appendingPathComponent("open.artflex")
        try f.controller.writeCapturedProject(expected, to: file, recordsVersionBackup: false)
        var preflightCount = 0
        let unchanged = f.workspace.state
        #expect(throws: (any Error).self) {
            try f.controller.openProject(from: file) { _ in
                preflightCount += 1
                try FileManager.default.removeItem(at: file)
            }
        }
        #expect(preflightCount == 1)
        #expect(f.workspace.state == unchanged)
    }
}

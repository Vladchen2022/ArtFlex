import AppleArchive
import Foundation
import Metal
import System
import Testing
@testable import ArtFlex

struct ProgressiveProjectTests {
    private func fixture(_ encoding: CanvasPixelEncoding) -> ProjectArchivePayload {
        var state = WorkspaceState.stageOneDefault
        state.document.canvasSize = .init(width: 16, height: 16)
        state.document.colorStandard = encoding == .premultipliedRGBA16FloatLinear ? .highPrecision : .stageOneDefault
        state.document.layers[1].mask = .init()
        let pixels = LayerTextureSnapshot(width: 16, height: 16, bytesPerRow: 16 * encoding.bytesPerPixel,
            pixelData: Data(repeating: 0, count: 256 * encoding.bytesPerPixel), encoding: encoding)
        var snapshots = state.document.paintLayers.map { LayerHistorySnapshot(layerID: $0.id, texture: pixels) }
        snapshots.append(.init(layerID: state.document.layers[1].id, resourceKind: .mask,
            texture: .init(width: 16, height: 16, bytesPerRow: 16, pixelData: Data(repeating: 173, count: 256), encoding: .grayscale8)))
        return .init(package: .fromWorkspace(state, layerSnapshots: snapshots), referenceImages: [],
                     previewPNGData: Data([137,80,78,71]))
    }

    @Test(arguments: [CanvasPixelEncoding.premultipliedBGRA8SRGB, .premultipliedRGBA16FloatLinear])
    func streamedOpenRetainsOnlyMetadataAndIdenticalGPUResources(encoding: CanvasPixelEncoding) throws {
        let metal = try #require(MetalDeviceContext())
        let serializer = LayerTextureSerializer(metalContext: metal)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = fixture(encoding)
        let controller = PersistenceController(workspaceStore: .init(state: .stageOneDefault), layerSurfaceStore: .init(), serializer: serializer,
            recoveryRootURL: root.appendingPathComponent("Recovery"), versionBackupRootURL: root.appendingPathComponent("Versions"))
        let url = root.appendingPathComponent("test.artflex")
        try controller.writeCapturedProject(payload, to: url, recordsVersionBackup: false)
        let normal = try controller.openProject(from: url)
        let stream = try controller.openProject(from: url, context: ProjectReadContext(), stager: .init(metal: metal, serializer: serializer))
        #expect(stream.workspace.document == normal.workspace.document)
        #expect(stream.layerSnapshots.allSatisfy { $0.texture.pixelData.isEmpty })
        let prepared = try #require(stream.preparedTextures)
        #expect(prepared.textures.count == normal.layerSnapshots.count)
        for snapshot in normal.layerSnapshots {
            let texture = try #require(prepared.textures.first { $0.layerID == snapshot.layerID && $0.resourceKind == snapshot.resourceKind }?.texture)
            #expect(try serializer.snapshot(texture: texture) == snapshot.texture)
        }
    }

    @Test func cancellationDuringReadStopsBeforeNextLayerAndPreservesInput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = fixture(.premultipliedBGRA8SRGB)
        try ProjectArchiveV2Writer().write(payload, to: root)
        let token = WorkCancellation(), context = ProjectReadContext()
        let cancelled = ProjectReadContext(cancellation: token)
        var delivered = 0
        #expect(throws: CancellationError.self) {
            try ProjectArchiveV2Reader(context: cancelled).read(from: root) { _, _ in
                delivered += 1; token.cancel()
            }
        }
        #expect(delivered == 1)
        #expect(try ProjectArchiveV2Reader(context: context).read(from: root).package.layerSnapshots == payload.package.layerSnapshots)
    }

    @Test func cancellingSaveBeforeCommitPreservesOriginalAndCleansStaging() throws {
        let metal = try #require(MetalDeviceContext())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = PersistenceController(workspaceStore: .init(state: .stageOneDefault), layerSurfaceStore: .init(), serializer: .init(metalContext: metal),
            recoveryRootURL: root.appendingPathComponent("Recovery"), versionBackupRootURL: root.appendingPathComponent("Versions"))
        let url = root.appendingPathComponent("original.artflex")
        let payload = fixture(.premultipliedBGRA8SRGB)
        try controller.writeCapturedProject(payload, to: url, recordsVersionBackup: false)
        let original = try Data(contentsOf: url)
        let token = WorkCancellation()
        let context = ProjectReadContext(cancellation: token) { state in
            if state.phase == .packaging { token.cancel() }
        }
        #expect(throws: CancellationError.self) { try controller.writeCapturedProject(payload, to: url, recordsVersionBackup: false, context: context) }
        #expect(try Data(contentsOf: url) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".") }.isEmpty)
    }

    @Test func extractionChecksHeaderBeforeWritingAndAcceptsOnlyDirectoryRoot() throws {
        func status(path: String, type: ArchiveHeader.EntryType, bytes: UInt64 = 0) throws -> ArchiveHeader.EntryMessageStatus {
            let header = ArchiveHeader()
            header.append(.string(key: .init("PAT"), value: path))
            header.append(.uint(key: .init("TYP"), value: UInt64(type.rawValue)))
            header.append(.blob(key: .init("DAT"), size: bytes))
            let validator = ProjectArchiveExtractionGuard(limits: .standard, root: URL(fileURLWithPath: "/unused"), context: nil)
            return validator.filter(.extractBegin, path: FilePath(path), data: .header(header))
        }
        #expect(try status(path: "", type: .directory) == .ok)
        #expect(try status(path: "", type: .regularFile) == .cancel)
        #expect(try status(path: "../escape", type: .regularFile) == .cancel)
        #expect(try status(path: "/tmp/escape", type: .regularFile) == .cancel)
        #expect(try status(path: "link", type: .link) == .cancel)
        #expect(try status(path: "large", type: .regularFile, bytes: UInt64(ProjectArchiveReadLimits.standard.maximumStoredAssetBytes) + 1) == .cancel)
    }
}

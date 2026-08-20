import Foundation
import Metal

enum ProjectStorageFormat: Equatable {
    case archiveV2
    case legacyJSON
}

struct OpenProjectResult {
    var workspace: WorkspaceState
    var layerSnapshots: [LayerHistorySnapshot]
    var referenceImages: [ProjectReferenceImagePayload]
    var savedSnapshots: [PersistentCanvasSnapshotPayload]
    var storageFormat: ProjectStorageFormat

    init(
        workspace: WorkspaceState,
        layerSnapshots: [LayerHistorySnapshot],
        referenceImages: [ProjectReferenceImagePayload] = [],
        savedSnapshots: [PersistentCanvasSnapshotPayload] = [],
        storageFormat: ProjectStorageFormat = .legacyJSON
    ) {
        self.workspace = workspace
        self.layerSnapshots = layerSnapshots
        self.referenceImages = referenceImages
        self.savedSnapshots = savedSnapshots
        self.storageFormat = storageFormat
    }
}

enum PersistenceError: LocalizedError {
    case missingLayerTexture(LayerID)
    case invalidProject(String)
    case legacyFormatCannotStoreAssets

    var errorDescription: String? {
        switch self {
        case let .missingLayerTexture(layerID):
            return "Missing texture for layer \(layerID.rawValue.uuidString)."
        case let .invalidProject(reason):
            return "工程文件无效：\(reason)"
        case .legacyFormatCannotStoreAssets:
            return "旧版 JSON 工程无法保存参考图或画布快照，请另存为 .artflex 工程"
        }
    }
}

final class PersistenceController {
    private let workspaceStore: WorkspaceStore
    private let layerSurfaceStore: StageOneLayerSurfaceStore
    private let serializer: LayerTextureSerializer
    private let archiveWriter: ProjectArchiveV2Writer
    private let archiveReader: ProjectArchiveV2Reader
    private let canvasCapacityPolicy: CanvasCapacityPolicy
    let recoveryProjectURL: URL

    init(
        workspaceStore: WorkspaceStore,
        layerSurfaceStore: StageOneLayerSurfaceStore,
        serializer: LayerTextureSerializer,
        canvasCapacityPolicy: CanvasCapacityPolicy = .standard,
        recoveryRootURL: URL? = nil
    ) {
        self.workspaceStore = workspaceStore
        self.layerSurfaceStore = layerSurfaceStore
        self.serializer = serializer
        self.canvasCapacityPolicy = canvasCapacityPolicy
        self.archiveWriter = ProjectArchiveV2Writer()
        var archiveReadLimits = ProjectArchiveReadLimits.standard
        archiveReadLimits.maximumCanvasEdge = canvasCapacityPolicy.maximumEdge
        archiveReadLimits.maximumCanvasPixelCount = canvasCapacityPolicy.maximumPixelCount
        self.archiveReader = ProjectArchiveV2Reader(limits: archiveReadLimits)
        let rootURL = recoveryRootURL ?? Self.defaultRecoveryRootURL()
        self.recoveryProjectURL = rootURL.appendingPathComponent(
            "Autosave.artflex",
            isDirectory: true
        )
        Self.discardAbandonedRecoveryStagingProjects(in: rootURL)
    }

    func saveProject(
        to fileURL: URL,
        referenceImages: [ProjectReferenceImagePayload] = [],
        savedSnapshots: [PersistentCanvasSnapshotPayload] = []
    ) throws {
        let payload = try captureProjectPayload(
            referenceImages: referenceImages,
            savedSnapshots: savedSnapshots
        )
        try writeCapturedProject(payload, to: fileURL)
    }

    /// Freezes the current workspace and GPU layer resources into a value payload. Call this at a
    /// safe editing boundary; archive encoding/compression can then run off the main actor.
    func captureProjectPayload(
        referenceImages: [ProjectReferenceImagePayload] = [],
        savedSnapshots: [PersistentCanvasSnapshotPayload] = []
    ) throws -> ProjectArchivePayload {
        ProjectArchivePayload(
            package: try captureProjectPackage(),
            referenceImages: referenceImages,
            savedSnapshots: savedSnapshots
        )
    }

    func writeCapturedProject(_ payload: ProjectArchivePayload, to fileURL: URL) throws {
        if Self.shouldUseV2Archive(for: fileURL) {
            try archiveWriter.write(payload, to: fileURL)
            return
        }

        guard payload.referenceImages.isEmpty, payload.savedSnapshots.isEmpty else {
            throw PersistenceError.legacyFormatCannotStoreAssets
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        // Legacy JSON remains writable for asset-free compatibility projects.
        let data = try encoder.encode(payload.package)
        try data.write(to: fileURL, options: .atomic)
    }

    func saveRecoveryProject(
        referenceImages: [ProjectReferenceImagePayload] = [],
        savedSnapshots: [PersistentCanvasSnapshotPayload] = []
    ) throws {
        try FileManager.default.createDirectory(
            at: recoveryProjectURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try saveProject(
            to: recoveryProjectURL,
            referenceImages: referenceImages,
            savedSnapshots: savedSnapshots
        )
    }

    func makeRecoveryStagingURL() throws -> URL {
        let root = recoveryProjectURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(
            "Pending-\(UUID().uuidString).artflex",
            isDirectory: true
        )
    }

    /// The expensive archive write targets a unique staging package. Installing it is one local
    /// filesystem rename, so a stale async autosave can be discarded before it reaches Autosave.
    func installRecoveryProject(from stagingURL: URL) throws {
        guard isOwnedRecoveryStagingURL(stagingURL) else {
            throw PersistenceError.invalidProject("自动恢复暂存路径无效")
        }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: recoveryProjectURL.path) {
            _ = try fileManager.replaceItemAt(
                recoveryProjectURL,
                withItemAt: stagingURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: stagingURL, to: recoveryProjectURL)
        }
    }

    func discardRecoveryStagingProject(at stagingURL: URL) {
        guard isOwnedRecoveryStagingURL(stagingURL) else { return }
        try? FileManager.default.removeItem(at: stagingURL)
    }

    private func isOwnedRecoveryStagingURL(_ url: URL) -> Bool {
        let root = recoveryProjectURL.deletingLastPathComponent().standardizedFileURL
        let candidate = url.standardizedFileURL
        return candidate.deletingLastPathComponent() == root
            && candidate.lastPathComponent.hasPrefix("Pending-")
            && candidate.pathExtension.lowercased() == "artflex"
    }

    var hasRecoveryProject: Bool {
        FileManager.default.fileExists(atPath: recoveryProjectURL.path)
    }

    func discardRecoveryProject() throws {
        guard hasRecoveryProject else { return }
        try FileManager.default.removeItem(at: recoveryProjectURL)
    }

    private func captureProjectPackage() throws -> ProjectPackage {
        let state = workspaceStore.state
        var snapshotLayers: [(layer: LayerRecord, resourceKind: LayerHistoryResourceKind, texture: MTLTexture)] = []
        snapshotLayers.reserveCapacity(state.document.paintLayers.count * 2)

        for layer in state.document.paintLayers {
            guard
                let surfaceID = layerSurfaceStore.surfaceID(for: layer.id),
                let texture = layerSurfaceStore.texture(for: surfaceID)
            else {
                throw PersistenceError.missingLayerTexture(layer.id)
            }

            snapshotLayers.append((layer: layer, resourceKind: .content, texture: texture))
            if layer.mask != nil {
                guard let maskTexture = layerSurfaceStore.maskTexture(for: layer.id) else {
                    throw PersistenceError.invalidProject("图层蒙版资源缺失")
                }
                snapshotLayers.append((layer: layer, resourceKind: .mask, texture: maskTexture))
            }
        }

        let textureSnapshots = try serializer.snapshotBatch(
            textures: snapshotLayers.map(\.texture)
        )
        let layerSnapshots = zip(snapshotLayers, textureSnapshots).map { item, textureSnapshot in
            return LayerHistorySnapshot(
                layerID: item.layer.id,
                resourceKind: item.resourceKind,
                texture: textureSnapshot
            )
        }

        return ProjectPackage.fromWorkspace(
            state,
            layerSnapshots: layerSnapshots
        )
    }

    func openProject(from fileURL: URL) throws -> OpenProjectResult {
        let payload: ProjectArchivePayload
        let storageFormat: ProjectStorageFormat
        if Self.isDirectory(at: fileURL) {
            payload = try archiveReader.read(from: fileURL)
            storageFormat = .archiveV2
        } else {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            payload = ProjectArchivePayload(
                package: try decoder.decode(ProjectPackage.self, from: data)
            )
            storageFormat = .legacyJSON
        }
        let package = payload.package
        var workspace = package.workspaceState
        workspace.document.normalizeLayerHierarchy()
        try validateOpenedProject(
            workspace: workspace,
            layerSnapshots: package.layerSnapshots
        )

        return OpenProjectResult(
            workspace: workspace,
            layerSnapshots: package.layerSnapshots,
            referenceImages: payload.referenceImages,
            savedSnapshots: payload.savedSnapshots,
            storageFormat: storageFormat
        )
    }

    private static func shouldUseV2Archive(for url: URL) -> Bool {
        url.pathExtension.lowercased() == "artflex" || isDirectory(at: url)
    }

    private static func isDirectory(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func defaultRecoveryRootURL() -> URL {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("ArtFlex", isDirectory: true)
            .appendingPathComponent("Recovery", isDirectory: true)
    }

    private static func discardAbandonedRecoveryStagingProjects(in rootURL: URL) {
        guard let candidates = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return
        }
        for candidate in candidates where
            candidate.lastPathComponent.hasPrefix("Pending-")
                || candidate.lastPathComponent.hasPrefix(".Pending-") {
            try? FileManager.default.removeItem(at: candidate)
        }
    }

    private func validateOpenedProject(
        workspace: WorkspaceState,
        layerSnapshots: [LayerHistorySnapshot]
    ) throws {
        let document = workspace.document
        let canvasSize = document.canvasSize
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            throw PersistenceError.invalidProject("画布尺寸必须大于 0")
        }
        let capacity = canvasCapacityPolicy.assess(canvasSize)
        guard capacity.isSupported else {
            throw PersistenceError.invalidProject(
                capacity.rejectionReason ?? "画布尺寸超出支持范围"
            )
        }

        let layerIDs = document.layers.map(\.id)
        guard !layerIDs.isEmpty, Set(layerIDs).count == layerIDs.count else {
            throw PersistenceError.invalidProject("图层列表为空或包含重复图层")
        }
        guard layerIDs.contains(document.activeLayerID) else {
            throw PersistenceError.invalidProject("活动图层不存在")
        }

        let expectedPaintLayerIDs = Set(document.paintLayers.map(\.id))
        guard !expectedPaintLayerIDs.isEmpty else {
            throw PersistenceError.invalidProject("至少需要一个可绘制图层")
        }
        guard expectedPaintLayerIDs.contains(document.activeLayerID) else {
            throw PersistenceError.invalidProject("活动图层不是可绘制图层")
        }
        let contentSnapshots = layerSnapshots.filter { $0.resourceKind == .content }
        let maskSnapshots = layerSnapshots.filter { $0.resourceKind == .mask }
        let contentLayerIDs = contentSnapshots.map(\.layerID)
        guard Set(contentLayerIDs).count == contentLayerIDs.count else {
            throw PersistenceError.invalidProject("包含重复的图层像素数据")
        }
        guard Set(contentLayerIDs) == expectedPaintLayerIDs else {
            throw PersistenceError.invalidProject("图层与像素数据不完整")
        }
        let expectedMaskLayerIDs = Set(document.paintLayers.filter { $0.mask != nil }.map(\.id))
        let maskLayerIDs = maskSnapshots.map(\.layerID)
        guard Set(maskLayerIDs).count == maskLayerIDs.count,
              Set(maskLayerIDs) == expectedMaskLayerIDs else {
            throw PersistenceError.invalidProject("图层蒙版与蒙版像素数据不完整")
        }

        let (expectedBytesPerRow, rowOverflow) = canvasSize.width.multipliedReportingOverflow(by: 4)
        let (_, countOverflow) = expectedBytesPerRow.multipliedReportingOverflow(
            by: canvasSize.height
        )
        guard !rowOverflow, !countOverflow else {
            throw PersistenceError.invalidProject("画布尺寸超出支持范围")
        }

        for layerSnapshot in layerSnapshots {
            let texture = layerSnapshot.texture
            let expectedSnapshotBytesPerRow = canvasSize.width * (layerSnapshot.resourceKind == .mask ? 1 : 4)
            let expectedSnapshotByteCount = expectedSnapshotBytesPerRow * canvasSize.height
            guard
                layerSnapshot.originX == 0,
                layerSnapshot.originY == 0,
                texture.width == canvasSize.width,
                texture.height == canvasSize.height,
                texture.bytesPerRow == expectedSnapshotBytesPerRow,
                texture.pixelData.count == expectedSnapshotByteCount
            else {
                throw PersistenceError.invalidProject("图层像素尺寸或数据长度不匹配")
            }
        }
    }
}

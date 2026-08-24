import Foundation
import Metal

enum ProjectStorageFormat: Sendable, Equatable {
    case archiveV2
    case legacyJSON
}

struct OpenProjectResult: Sendable {
    var workspace: WorkspaceState
    var layerSnapshots: [LayerHistorySnapshot]
    var referenceImages: [ProjectReferenceImagePayload]
    var savedSnapshots: [PersistentCanvasSnapshotPayload]
    var previewPNGData: Data?
    var storageFormat: ProjectStorageFormat

    init(
        workspace: WorkspaceState,
        layerSnapshots: [LayerHistorySnapshot],
        referenceImages: [ProjectReferenceImagePayload] = [],
        savedSnapshots: [PersistentCanvasSnapshotPayload] = [],
        previewPNGData: Data? = nil,
        storageFormat: ProjectStorageFormat = .legacyJSON
    ) {
        self.workspace = workspace
        self.layerSnapshots = layerSnapshots
        self.referenceImages = referenceImages
        self.savedSnapshots = savedSnapshots
        self.previewPNGData = previewPNGData
        self.storageFormat = storageFormat
    }
}

struct ProjectOpenInspection: Sendable, Equatable {
    var workspace: WorkspaceState
    var savedSnapshotCount: Int
    var referenceArchiveBytes: Int
    var estimatedReferenceResidentBytes: Int
    var totalUncompressedAssetBytes: Int
    var storageFormat: ProjectStorageFormat
}

struct FrozenProjectLayerResource: @unchecked Sendable {
    var layer: LayerRecord
    var resourceKind: LayerHistoryResourceKind
    var texture: MTLTexture
}

struct FrozenProjectCapture: @unchecked Sendable {
    var workspace: WorkspaceState
    var layerResources: [FrozenProjectLayerResource]
    var referenceImages: [ProjectReferenceImagePayload]
    var savedSnapshots: [PersistentCanvasSnapshotPayload]
    var previewTexture: MTLTexture?
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
    private let flatContainer: ProjectArchiveFlatContainer
    private let thumbnailEncoder = ProjectThumbnailEncoder()
    private let archiveReadLimits: ProjectArchiveReadLimits
    private let canvasCapacityPolicy: CanvasCapacityPolicy
    let recoveryProjectURL: URL

    init(
        workspaceStore: WorkspaceStore,
        layerSurfaceStore: StageOneLayerSurfaceStore,
        serializer: LayerTextureSerializer,
        canvasCapacityPolicy: CanvasCapacityPolicy = .standard,
        recommendedMaxWorkingSetSize: UInt64? = nil,
        recoveryRootURL: URL? = nil
    ) {
        self.workspaceStore = workspaceStore
        self.layerSurfaceStore = layerSurfaceStore
        self.serializer = serializer
        self.canvasCapacityPolicy = canvasCapacityPolicy
        let archiveReadLimits = ProjectArchiveReadLimits.adaptive(
            recommendedMaxWorkingSetSize: recommendedMaxWorkingSetSize,
            canvasCapacityPolicy: canvasCapacityPolicy
        )
        self.archiveReadLimits = archiveReadLimits
        self.archiveWriter = ProjectArchiveV2Writer(limits: archiveReadLimits)
        self.archiveReader = ProjectArchiveV2Reader(limits: archiveReadLimits)
        self.flatContainer = ProjectArchiveFlatContainer()
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
        try materializeProjectPayload(
            from: freezeProjectCapture(
                referenceImages: referenceImages,
                savedSnapshots: savedSnapshots
            )
        )
    }

    /// Copies the live document into immutable private Metal textures. This GPU-only boundary is
    /// short; pixel readback and archive encoding can happen later without racing new brush work.
    func freezeProjectCapture(
        referenceImages: [ProjectReferenceImagePayload] = [],
        savedSnapshots: [PersistentCanvasSnapshotPayload] = [],
        previewTexture: MTLTexture? = nil
    ) throws -> FrozenProjectCapture {
        let state = workspaceStore.state
        var sources: [(layer: LayerRecord, resourceKind: LayerHistoryResourceKind, texture: MTLTexture)] = []
        sources.reserveCapacity(state.document.paintLayers.count * 2)

        for layer in state.document.paintLayers {
            guard let surfaceID = layerSurfaceStore.surfaceID(for: layer.id),
                  let texture = layerSurfaceStore.texture(for: surfaceID) else {
                throw PersistenceError.missingLayerTexture(layer.id)
            }
            sources.append((layer, .content, texture))
            if layer.mask != nil {
                guard let maskTexture = layerSurfaceStore.maskTexture(for: layer.id) else {
                    throw PersistenceError.invalidProject("图层蒙版资源缺失")
                }
                sources.append((layer, .mask, maskTexture))
            }
        }

        var texturesToFreeze = sources.map(\.texture)
        if let previewTexture {
            texturesToFreeze.append(previewTexture)
        }
        let frozenTextures = try serializer.cloneBatchForDeferredSnapshot(textures: texturesToFreeze)
        let frozenLayerTextures = frozenTextures.prefix(sources.count)
        return FrozenProjectCapture(
            workspace: state,
            layerResources: zip(sources, frozenLayerTextures).map { source, texture in
                FrozenProjectLayerResource(
                    layer: source.layer,
                    resourceKind: source.resourceKind,
                    texture: texture
                )
            },
            referenceImages: referenceImages,
            savedSnapshots: savedSnapshots,
            previewTexture: previewTexture == nil ? nil : frozenTextures.last
        )
    }

    func materializeProjectPayload(
        from capture: FrozenProjectCapture
    ) throws -> ProjectArchivePayload {
        var frozenTextures = capture.layerResources.map(\.texture)
        if let previewTexture = capture.previewTexture {
            frozenTextures.append(previewTexture)
        }
        let textureSnapshots = try serializer.snapshotBatch(textures: frozenTextures)
        let layerTextureSnapshots = textureSnapshots.prefix(capture.layerResources.count)
        let layerSnapshots = zip(capture.layerResources, layerTextureSnapshots).map { item, textureSnapshot in
            LayerHistorySnapshot(
                layerID: item.layer.id,
                resourceKind: item.resourceKind,
                texture: textureSnapshot
            )
        }
        let previewPNGData: Data?
        if capture.previewTexture != nil, let previewSnapshot = textureSnapshots.last {
            previewPNGData = try thumbnailEncoder.encodePNG(from: previewSnapshot)
        } else {
            previewPNGData = nil
        }
        return ProjectArchivePayload(
            package: ProjectPackage.fromWorkspace(
                capture.workspace,
                layerSnapshots: layerSnapshots
            ),
            referenceImages: capture.referenceImages,
            savedSnapshots: capture.savedSnapshots,
            previewPNGData: previewPNGData
        )
    }

    @discardableResult
    func writeCapturedProject(_ payload: ProjectArchivePayload, to fileURL: URL) throws -> Data? {
        if Self.shouldUseV2Archive(for: fileURL) {
            try writeFlatArchive(payload, to: fileURL)
            return payload.previewPNGData
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
        return nil
    }

    private func writeFlatArchive(_ payload: ProjectArchivePayload, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        let parentURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        let token = UUID().uuidString
        let stagingPackageURL = parentURL.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(token).package",
            isDirectory: true
        )
        let stagingArchiveURL = parentURL.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(token).tmp",
            isDirectory: false
        )
        defer {
            try? fileManager.removeItem(at: stagingPackageURL)
            try? fileManager.removeItem(at: stagingArchiveURL)
        }

        try archiveWriter.write(payload, to: stagingPackageURL)
        try flatContainer.encodePackage(at: stagingPackageURL, to: stagingArchiveURL)
        try flatContainer.withExtractedPackage(from: stagingArchiveURL, limits: archiveReadLimits) {
            try archiveReader.validateArchive(at: $0)
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: stagingArchiveURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: stagingArchiveURL, to: destinationURL)
        }
    }

    func saveRecoveryProject(
        referenceImages: [ProjectReferenceImagePayload] = [],
        savedSnapshots: [PersistentCanvasSnapshotPayload] = []
    ) throws {
        let payload = try captureProjectPayload(
            referenceImages: referenceImages,
            savedSnapshots: savedSnapshots
        )
        let stagingURL = try makeRecoveryStagingURL()
        do {
            try writeCapturedProject(payload, to: stagingURL)
            try installRecoveryProject(from: stagingURL)
        } catch {
            discardRecoveryStagingProject(at: stagingURL)
            throw error
        }
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
            let backupURLs = recoveryBackupProjectURLs
            if let oldestBackupURL = backupURLs.last,
               fileManager.fileExists(atPath: oldestBackupURL.path) {
                try fileManager.removeItem(at: oldestBackupURL)
            }
            if backupURLs.count >= 2,
               fileManager.fileExists(atPath: backupURLs[0].path) {
                try fileManager.moveItem(at: backupURLs[0], to: backupURLs[1])
            }
            _ = try fileManager.replaceItemAt(
                recoveryProjectURL,
                withItemAt: stagingURL,
                backupItemName: backupURLs[0].lastPathComponent,
                options: [.withoutDeletingBackupItem]
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
        recoveryProjectCandidates.contains {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    /// Returns the newest complete recovery generation. A torn or manually damaged newest
    /// generation no longer hides older valid work.
    func bestAvailableRecoveryProjectURL() -> URL? {
        recoveryProjectCandidates.first { candidate in
            guard FileManager.default.fileExists(atPath: candidate.path) else { return false }
            return (try? inspectProject(from: candidate)) != nil
        }
    }

    func openBestAvailableRecoveryProject(
        preflight: (ProjectOpenInspection) throws -> Void = { _ in }
    ) throws -> (url: URL, result: OpenProjectResult) {
        var lastError: Error?
        for candidate in recoveryProjectCandidates where
            FileManager.default.fileExists(atPath: candidate.path) {
            do {
                return (
                    candidate,
                    try openProject(from: candidate, preflight: preflight)
                )
            } catch {
                lastError = error
            }
        }
        throw lastError ?? PersistenceError.invalidProject("没有完整可用的自动恢复工程")
    }

    func discardRecoveryProject() throws {
        for candidate in recoveryProjectCandidates where
            FileManager.default.fileExists(atPath: candidate.path) {
            try FileManager.default.removeItem(at: candidate)
        }
    }

    private var recoveryBackupProjectURLs: [URL] {
        let root = recoveryProjectURL.deletingLastPathComponent()
        return (1...2).map { generation in
            root.appendingPathComponent("Autosave-\(generation).artflex", isDirectory: true)
        }
    }

    private var recoveryProjectCandidates: [URL] {
        [recoveryProjectURL] + recoveryBackupProjectURLs
    }

    func inspectProject(from fileURL: URL) throws -> ProjectOpenInspection {
        if Self.shouldUseV2Archive(for: fileURL) {
            let inspection = try withV2PackageDirectory(for: fileURL) {
                try archiveReader.inspect(from: $0)
            }
            return ProjectOpenInspection(
                workspace: inspection.workspace,
                savedSnapshotCount: inspection.savedSnapshotCount,
                referenceArchiveBytes: inspection.referenceArchiveBytes,
                estimatedReferenceResidentBytes: inspection.estimatedReferenceResidentBytes,
                totalUncompressedAssetBytes: inspection.totalUncompressedAssetBytes,
                storageFormat: .archiveV2
            )
        }

        let byteCount = Int((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard byteCount <= archiveReadLimits.maximumTotalUncompressedBytes else {
            throw ProjectArchiveV2Error.totalAssetSizeTooLarge
        }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let package = try decoder.decode(ProjectPackage.self, from: data)
        var workspace = package.workspaceState
        workspace.document.normalizeLayerHierarchy()
        try validateOpenedProject(workspace: workspace, layerSnapshots: package.layerSnapshots)
        return ProjectOpenInspection(
            workspace: workspace,
            savedSnapshotCount: 0,
            referenceArchiveBytes: 0,
            estimatedReferenceResidentBytes: 0,
            totalUncompressedAssetBytes: data.count,
            storageFormat: .legacyJSON
        )
    }

    func openProject(
        from fileURL: URL,
        preflight: (ProjectOpenInspection) throws -> Void = { _ in }
    ) throws -> OpenProjectResult {
        let payload: ProjectArchivePayload
        let storageFormat: ProjectStorageFormat
        if Self.shouldUseV2Archive(for: fileURL) {
            try preflight(inspectProject(from: fileURL))
            payload = try withV2PackageDirectory(for: fileURL) {
                try archiveReader.read(from: $0)
            }
            storageFormat = .archiveV2
        } else {
            let inspection = try inspectProject(from: fileURL)
            try preflight(inspection)
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
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
            previewPNGData: payload.previewPNGData,
            storageFormat: storageFormat
        )
    }

    private func withV2PackageDirectory<T>(
        for url: URL,
        _ body: (URL) throws -> T
    ) throws -> T {
        if Self.isDirectory(at: url) {
            return try body(url)
        }
        return try flatContainer.withExtractedPackage(
            from: url,
            limits: archiveReadLimits,
            body
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

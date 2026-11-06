import Foundation
import CryptoKit
import Metal

struct ProjectCaptureResourceToken: @unchecked Sendable {
    var key: LayerResourceKey
    var cursor: LayerChangeCursor
    var source: MTLTexture
}

/// Source references are weak so an optimization cannot retain replaced GPU resources.
private final class ProjectSavedResourceCache: @unchecked Sendable {
    private final class Entry {
        weak var source: (any MTLTexture)?
        let cursor: LayerChangeCursor
        let encoded: EncodedProjectLayerResource
        var useOrder: UInt64
        init(token: ProjectCaptureResourceToken, encoded: EncodedProjectLayerResource, useOrder: UInt64) {
            source = token.source
            cursor = token.cursor
            self.encoded = encoded
            self.useOrder = useOrder
        }
    }
    private let lock = NSLock()
    private let maximumBytes: Int
    private var entries: [LayerResourceKey: Entry] = [:]
    private var order: UInt64 = 0
    init(maximumBytes: Int) { self.maximumBytes = max(0, maximumBytes) }
    var residentBytes: Int { lock.withLock { entries.values.reduce(0) { $0 + $1.encoded.compressedPixels.count } } }

    func resource(matching token: ProjectCaptureResourceToken) -> EncodedProjectLayerResource? {
        lock.withLock {
            guard let entry = entries[token.key], entry.cursor == token.cursor,
                  entry.source === token.source else { return nil }
            order &+= 1
            entry.useOrder = order
            return entry.encoded
        }
    }

    func insert(_ encoded: EncodedProjectLayerResource, token: ProjectCaptureResourceToken) {
        lock.withLock {
            entries.removeValue(forKey: token.key)
            guard encoded.compressedPixels.count <= maximumBytes else { return }
            for key in entries.keys.filter({ entries[$0]?.source == nil }) { entries.removeValue(forKey: key) }
            var bytes = entries.values.reduce(0) { $0 + $1.encoded.compressedPixels.count }
            while bytes > maximumBytes - encoded.compressedPixels.count,
                  let oldest = entries.min(by: { $0.value.useOrder < $1.value.useOrder }) {
                bytes -= oldest.value.encoded.compressedPixels.count
                entries.removeValue(forKey: oldest.key)
            }
            order &+= 1
            entries[token.key] = Entry(token: token, encoded: encoded, useOrder: order)
        }
    }

    func purge() { lock.withLock { entries.removeAll() } }
}

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
    var resourceReservation: WorkingResourceBudget.Reservation? = nil
    var fileRevision: ProjectFileRevision? = nil
    var preparedTextures: PreparedProjectTextures? = nil

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
    var reusedLayerResources: [EncodedProjectLayerResource] = []
    var resourceTokens: [ProjectCaptureResourceToken] = []
    var pinnedResources: [StageOneLayerSurfaceStore.FrozenRead] = []
    var resourceReservation: WorkingResourceBudget.Reservation? = nil
}

/// Workspace metadata is captured synchronously; GPU copies are already submitted.
/// Only the save worker converts this into readable frozen resources.
struct QueuedProjectCapture: Sendable {
    var workspace: WorkspaceState
    var layerDescriptors: [(layer: LayerRecord, kind: LayerHistoryResourceKind)]
    var referenceImages: [ProjectReferenceImagePayload]
    var savedSnapshots: [PersistentCanvasSnapshotPayload]
    var hasPreviewTexture: Bool
    var textureBatch: DeferredTextureCloneBatch
    var reusedLayerResources: [EncodedProjectLayerResource] = []
    var resourceTokens: [ProjectCaptureResourceToken] = []
    var pinnedResources: [StageOneLayerSurfaceStore.FrozenRead] = []
    var resourceReservation: WorkingResourceBudget.Reservation? = nil

    func waitUntilReady() throws -> FrozenProjectCapture {
        let textures = try textureBatch.waitUntilReady()
        guard textures.count == layerDescriptors.count + (hasPreviewTexture ? 1 : 0) else {
            throw PersistenceError.invalidProject("冻结图层数量不一致")
        }
        return FrozenProjectCapture(workspace: workspace,
            layerResources: zip(layerDescriptors, textures).map { descriptor, texture in
                .init(layer: descriptor.layer, resourceKind: descriptor.kind, texture: texture)
            }, referenceImages: referenceImages, savedSnapshots: savedSnapshots,
            previewTexture: hasPreviewTexture ? textures.last : nil,
            reusedLayerResources: reusedLayerResources, resourceTokens: resourceTokens, pinnedResources: pinnedResources, resourceReservation: resourceReservation)
    }
}

struct ProjectWriteOutcome: Sendable, Equatable {
    var previewPNGData: Data?
    var versionBackupURL: URL?
    var versionBackupWarning: String?
    var fileRevision: ProjectFileRevision? = nil
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

private enum ProjectVersionBackupError: LocalizedError {
    case sourceInsideBackupRoot

    var errorDescription: String? {
        switch self {
        case .sourceInsideBackupRoot:
            return "不能把版本副本再次写入版本目录"
        }
    }
}

final class PersistenceController {
    static let recoveryBackupGenerationCount = 8
    static let staleRecoveryStagingAge: TimeInterval = 24 * 60 * 60
    static let maximumProjectVersionBackupCount = 5

    private let workspaceStore: WorkspaceStore
    private let layerSurfaceStore: StageOneLayerSurfaceStore
    private let serializer: LayerTextureSerializer
    private let archiveWriter: ProjectArchiveV2Writer
    private let archiveReader: ProjectArchiveV2Reader
    private let flatContainer: ProjectArchiveFlatContainer
    private let thumbnailEncoder = ProjectThumbnailEncoder()
    private let archiveReadLimits: ProjectArchiveReadLimits
    private let canvasCapacityPolicy: CanvasCapacityPolicy
    private var incrementalRecoveryNeedsFullCapture = false
    private let savedResourceCache: ProjectSavedResourceCache
    var cachedSaveResourceByteCount: Int { savedResourceCache.residentBytes }
    func purgeSaveResourceCache() { savedResourceCache.purge() }
    let recoveryProjectURL: URL
    let versionBackupRootURL: URL

    init(
        workspaceStore: WorkspaceStore,
        layerSurfaceStore: StageOneLayerSurfaceStore,
        serializer: LayerTextureSerializer,
        canvasCapacityPolicy: CanvasCapacityPolicy = .standard,
        recommendedMaxWorkingSetSize: UInt64? = nil,
        recoveryRootURL: URL? = nil,
        versionBackupRootURL: URL? = nil,
        saveResourceCacheMaximumBytes: Int = 64 * 1024 * 1024
    ) {
        self.savedResourceCache = ProjectSavedResourceCache(maximumBytes: saveResourceCacheMaximumBytes)
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
        self.versionBackupRootURL = versionBackupRootURL
            ?? rootURL.deletingLastPathComponent()
                .appendingPathComponent("VersionBackups", isDirectory: true)
        Self.discardStaleRecoveryStagingProjects(in: rootURL)
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
        _ = try writeCapturedProject(payload, to: fileURL)
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

    /// Synchronous compatibility path for callers that immediately need readable frozen resources.
    func freezeProjectCapture(
        referenceImages: [ProjectReferenceImagePayload] = [],
        savedSnapshots: [PersistentCanvasSnapshotPayload] = [],
        previewTexture: MTLTexture? = nil
    ) throws -> FrozenProjectCapture {
        try enqueueProjectCapture(referenceImages: referenceImages, savedSnapshots: savedSnapshots,
                                  previewTexture: previewTexture, allowsResourceReuse: false).waitUntilReady()
    }

    /// Called on the editing thread before later canvas writes can be enqueued. Private copies
    /// stay on the same Metal queue; the returned capture must be completed before archive writes.
    func enqueueProjectCapture(
        referenceImages: [ProjectReferenceImagePayload] = [],
        savedSnapshots: [PersistentCanvasSnapshotPayload] = [],
        previewTexture: MTLTexture? = nil,
        allowsResourceReuse: Bool = true
    ) throws -> QueuedProjectCapture {
        let state = workspaceStore.state
        var sources: [(layer: LayerRecord, resourceKind: LayerHistoryResourceKind, texture: MTLTexture)] = []
        sources.reserveCapacity(state.document.paintLayers.count * 2)

        for layer in state.document.paintLayers {
            guard let surfaceID = layerSurfaceStore.surfaceID(for: layer.id),
                  let texture = layerSurfaceStore.readTexture(for: surfaceID) else {
                throw PersistenceError.missingLayerTexture(layer.id)
            }
            sources.append((layer, .content, texture))
            if layer.mask != nil {
                guard let maskTexture = layerSurfaceStore.readMaskTexture(for: layer.id) else {
                    throw PersistenceError.invalidProject("图层蒙版资源缺失")
                }
                sources.append((layer, .mask, maskTexture))
            }
        }

        let tokens = sources.map { source in
            let key = LayerResourceKey(layerID: source.layer.id, kind: source.resourceKind)
            return ProjectCaptureResourceToken(key: key, cursor: layerSurfaceStore.changeJournal(for: key).cursor,
                                               source: source.texture)
        }
        var reused: [EncodedProjectLayerResource] = []
        if allowsResourceReuse {
            sources = zip(sources, tokens).compactMap { source, token in
                if let encoded = savedResourceCache.resource(matching: token) {
                    reused.append(encoded)
                    return nil
                }
                return source
            }
        }
        var texturesToFreeze = sources.map(\.texture)
        if let previewTexture {
            texturesToFreeze.append(previewTexture)
        }
        let rawBytes = texturesToFreeze.map { ApplicationResourceLedger.multiply(
            ApplicationResourceLedger.multiply($0.width, $0.height), $0.pixelFormat == .rgba16Float ? 8 : ($0.pixelFormat == .r8Unorm ? 1 : 4)) }
        let cpuPeak = ApplicationResourceLedger.add(rawBytes.reduce(0, ApplicationResourceLedger.add),
            ApplicationResourceLedger.multiply(rawBytes.max() ?? 0, 2))
        let reservation = try serializer.reserveWorkingMemory(bytes: cpuPeak)
        let pinned = try sources.map { try layerSurfaceStore.freezeRead(for: .init(layerID: $0.layer.id, kind: $0.resourceKind)) }
        let pendingTextures = try serializer.enqueuePinnedReadBatch(textures: pinned.map(\.texture), preview: previewTexture)
        return QueuedProjectCapture(
            workspace: state,
            layerDescriptors: sources.map { ($0.layer, $0.resourceKind) },
            referenceImages: referenceImages,
            savedSnapshots: savedSnapshots,
            hasPreviewTexture: previewTexture != nil,
            textureBatch: pendingTextures,
            reusedLayerResources: reused,
            resourceTokens: tokens,
            pinnedResources: pinned,
            resourceReservation: reservation
        )
    }

    func materializeProjectPayload(
        from capture: FrozenProjectCapture,
        reuseEncodedLayers: Bool = false,
        context: ProjectReadContext? = nil
    ) throws -> ProjectArchivePayload {
        var layerSnapshots: [LayerHistorySnapshot] = []
        var encodedResources = capture.reusedLayerResources
        let tokens = Dictionary(uniqueKeysWithValues: capture.resourceTokens.map { ($0.key, $0) })
        // Frozen GPU resources stay alive until capture completes. Raw CPU readback and
        // compression scratch, however, are bounded to one layer/mask at a time.
        for (index, resource) in capture.layerResources.enumerated() {
            try context?.check()
            context?.report(.materializing, completed: index, total: capture.layerResources.count)
            try autoreleasepool {
                if reuseEncodedLayers {
                    let encoded = try encodeLayerInStrips(resource, context: context)
                    if let token = tokens[encoded.key] { savedResourceCache.insert(encoded, token: token) }
                    encodedResources.append(encoded)
                } else {
                    layerSnapshots.append(LayerHistorySnapshot(layerID: resource.layer.id,
                        resourceKind: resource.resourceKind, texture: try serializer.snapshot(texture: resource.texture)))
                }
            }
        }
        if reuseEncodedLayers {
            layerSnapshots = encodedResources.map(\.template)
        } else {
            layerSnapshots += try capture.reusedLayerResources.map { try $0.materialized() }
            encodedResources = []
        }
        // The package order remains stable regardless of which resources were reused.
        let order = capture.workspace.document.paintLayers.flatMap { layer in
            (layer.mask == nil ? [LayerHistoryResourceKind.content] : [.content, .mask]).map {
                LayerResourceKey(layerID: layer.id, kind: $0)
            }
        }
        let positions = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        layerSnapshots.sort {
            positions[.init(layerID: $0.layerID, kind: $0.resourceKind), default: .max]
                < positions[.init(layerID: $1.layerID, kind: $1.resourceKind), default: .max]
        }
        let previewPNGData: Data?
        if let previewTexture = capture.previewTexture {
            previewPNGData = try autoreleasepool {
                try thumbnailEncoder.encodePNG(from: serializer.downsampledSnapshot(texture: previewTexture,
                    divisor: max(1, (max(previewTexture.width, previewTexture.height) + 511) / 512)))
            }
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
            previewPNGData: previewPNGData,
            encodedLayerResources: encodedResources,
            resourceReservation: capture.resourceReservation
        )
    }

    private func encodeLayerInStrips(_ resource: FrozenProjectLayerResource, context: ProjectReadContext?) throws -> EncodedProjectLayerResource {
        let texture = resource.texture
        let encoding: CanvasPixelEncoding = texture.pixelFormat == .rgba16Float ? .premultipliedRGBA16FloatLinear
            : texture.pixelFormat == .r8Unorm ? .grayscale8 : .premultipliedBGRA8SRGB
        let rowBytes = texture.width * encoding.bytesPerPixel
        let rows = max(1, (2 * 1024 * 1024) / rowBytes)
        var hash = SHA256()
        let compressed = try ZlibCodec.compressStreaming { consume in
            for y in stride(from: 0, to: texture.height, by: rows) {
                try context?.check()
                try autoreleasepool {
                    let strip = try serializer.snapshot(texture: texture, originX: 0, originY: y,
                        width: texture.width, height: min(rows, texture.height - y))
                    hash.update(data: strip.pixelData)
                    try consume(strip.pixelData)
                }
            }
        }
        let template = LayerHistorySnapshot(layerID: resource.layer.id, resourceKind: resource.resourceKind,
            texture: .init(width: texture.width, height: texture.height, bytesPerRow: rowBytes, pixelData: Data(), encoding: encoding))
        return .init(template: template, compressedPixels: compressed, uncompressedByteCount: rowBytes * texture.height,
            sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    @discardableResult
    func writeCapturedProject(
        _ payload: ProjectArchivePayload,
        to fileURL: URL,
        recordsVersionBackup: Bool = true,
        context: ProjectReadContext? = nil,
        expectedFileRevision: ProjectFileRevision? = nil
    ) throws -> ProjectWriteOutcome {
        try ProjectFileAccess.write(fileURL) { coordinated in
            try expectedFileRevision?.verify(at: coordinated)
            var outcome = try writeCapturedProjectUncoordinated(payload, to: coordinated,
                recordsVersionBackup: recordsVersionBackup, context: context, expectedFileRevision: expectedFileRevision)
            outcome.fileRevision = try ProjectFileRevision.read(coordinated)
            return outcome
        }
    }

    private func writeCapturedProjectUncoordinated(_ payload: ProjectArchivePayload, to fileURL: URL,
        recordsVersionBackup: Bool, context: ProjectReadContext?, expectedFileRevision: ProjectFileRevision?) throws -> ProjectWriteOutcome {
        if Self.shouldUseV2Archive(for: fileURL) {
            try writeFlatArchive(payload, to: fileURL, context: context, expectedFileRevision: expectedFileRevision)
        } else {
            guard payload.referenceImages.isEmpty, payload.savedSnapshots.isEmpty else {
                throw PersistenceError.legacyFormatCannotStoreAssets
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601

            // Legacy JSON remains writable for asset-free compatibility projects.
            var package = payload.package
            if !payload.encodedLayerResources.isEmpty {
                let decoded = try Dictionary(uniqueKeysWithValues: payload.encodedLayerResources.map { ($0.key, try $0.materialized()) })
                package.layerSnapshots = package.layerSnapshots.map {
                    decoded[.init(layerID: $0.layerID, kind: $0.resourceKind)] ?? $0
                }
            }
            let data = try encoder.encode(package)
            try context?.check()
            context?.report(.committing)
            try expectedFileRevision?.verify(at: fileURL)
            try data.write(to: fileURL, options: .atomic)
        }

        guard recordsVersionBackup else {
            return ProjectWriteOutcome(
                previewPNGData: payload.previewPNGData,
                versionBackupURL: nil,
                versionBackupWarning: nil
            )
        }

        let versionResult = archiveVerifiedProjectVersion(
            at: fileURL,
            documentID: payload.package.document.metadata.drawingStatsID
        )
        switch versionResult {
        case .success(let backupURL):
            return ProjectWriteOutcome(
                previewPNGData: payload.previewPNGData,
                versionBackupURL: backupURL,
                versionBackupWarning: nil
            )
        case .failure(let error):
            return ProjectWriteOutcome(
                previewPNGData: payload.previewPNGData,
                versionBackupURL: nil,
                versionBackupWarning: "工程已保存，但版本副本创建失败：\(error.localizedDescription)"
            )
        }
    }

    private func writeFlatArchive(_ payload: ProjectArchivePayload, to destinationURL: URL, context: ProjectReadContext? = nil, expectedFileRevision: ProjectFileRevision? = nil) throws {
        try context?.check()
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

        try archiveWriter.write(payload, to: stagingPackageURL, context: context)
        try flatContainer.encodePackage(at: stagingPackageURL, to: stagingArchiveURL, context: context)
        try flatContainer.withExtractedPackage(from: stagingArchiveURL, limits: archiveReadLimits, context: context) {
            try ProjectArchiveV2Reader(limits: archiveReadLimits, context: context).validateArchive(at: $0)
        }
        try context?.check()
        context?.report(.committing)

        try expectedFileRevision?.verify(at: destinationURL)
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

    private func archiveVerifiedProjectVersion(
        at projectURL: URL,
        documentID: UUID
    ) -> Result<URL, Error> {
        Result {
            let fileManager = FileManager.default
            let standardizedSource = projectURL.standardizedFileURL
            let standardizedBackupRoot = versionBackupRootURL.standardizedFileURL
            let backupRootPrefix = standardizedBackupRoot.path.hasSuffix("/")
                ? standardizedBackupRoot.path
                : standardizedBackupRoot.path + "/"
            guard !standardizedSource.path.hasPrefix(backupRootPrefix) else {
                throw ProjectVersionBackupError.sourceInsideBackupRoot
            }

            let documentDirectory = standardizedBackupRoot.appendingPathComponent(
                documentID.uuidString.lowercased(),
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: documentDirectory,
                withIntermediateDirectories: true
            )

            let timestamp = Self.projectVersionTimestamp(for: Date())
            let sourceName = Self.safeVersionFilenameComponent(
                standardizedSource.deletingPathExtension().lastPathComponent
            )
            let sourceExtension = standardizedSource.pathExtension.isEmpty
                ? "artflex"
                : standardizedSource.pathExtension
            let uniqueSuffix = UUID().uuidString.prefix(8).lowercased()
            let finalURL = documentDirectory.appendingPathComponent(
                "\(timestamp)-\(uniqueSuffix)-\(sourceName).\(sourceExtension)",
                isDirectory: false
            )
            let stagingURL = documentDirectory.appendingPathComponent(
                ".Pending-Version-\(UUID().uuidString).\(sourceExtension)",
                isDirectory: false
            )
            defer { try? fileManager.removeItem(at: stagingURL) }

            try fileManager.copyItem(at: standardizedSource, to: stagingURL)
            _ = try inspectProject(from: stagingURL)
            try fileManager.moveItem(at: stagingURL, to: finalURL)
            pruneProjectVersionBackups(in: documentDirectory, preserving: finalURL)
            return finalURL
        }
    }

    func projectVersionBackupURLs(for documentID: UUID) -> [URL] {
        let directory = versionBackupRootURL.appendingPathComponent(
            documentID.uuidString.lowercased(),
            isDirectory: true
        )
        guard let candidates = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return candidates
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func pruneProjectVersionBackups(in directory: URL, preserving newestURL: URL) {
        guard let candidates = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let newestPath = newestURL.standardizedFileURL.resolvingSymlinksInPath().path
        let versions = candidates
            .filter { candidate in
                candidate.standardizedFileURL.resolvingSymlinksInPath().path != newestPath
                    && (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        let keepOlderCount = max(Self.maximumProjectVersionBackupCount - 1, 0)
        for expiredURL in versions.dropFirst(keepOlderCount) {
            try? FileManager.default.removeItem(at: expiredURL)
        }
    }

    private static func projectVersionTimestamp(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: date
        )
        let milliseconds = (components.nanosecond ?? 0) / 1_000_000
        return String(
            format: "%04d%02d%02d-%02d%02d%02d-%03d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0,
            milliseconds
        )
    }

    private static func safeVersionFilenameComponent(_ source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = trimmed.map { character -> Character in
            if character == "/" || character == ":" || character == "\\" {
                return "_"
            }
            return character
        }
        let result = String(sanitized).prefix(80)
        return result.isEmpty ? "未命名" : String(result)
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
            _ = try writeCapturedProject(
                payload,
                to: stagingURL,
                recordsVersionBackup: false
            )
            try installRecoveryProject(from: stagingURL)
        } catch {
            discardRecoveryStagingProject(at: stagingURL)
            throw error
        }
    }

    func freezeIncrementalRecovery(
        referenceImages: [ProjectReferenceImagePayload] = [],
        savedSnapshots: [PersistentCanvasSnapshotPayload] = []
    ) throws -> FrozenRecoveryCapture {
        try enqueueIncrementalRecovery(referenceImages: referenceImages, savedSnapshots: savedSnapshots).waitUntilReady()
    }

    func enqueueIncrementalRecovery(
        referenceImages: [ProjectReferenceImagePayload] = [],
        savedSnapshots: [PersistentCanvasSnapshotPayload] = [],
        previewTexture: MTLTexture? = nil
    ) throws -> QueuedRecoveryCapture {
        let workspace = workspaceStore.state
        let previous = try? IncrementalRecoveryArchive.manifest(at: recoveryProjectURL, limits: archiveReadLimits)
        let compatible = !incrementalRecoveryNeedsFullCapture
            && previous?.documentID == workspace.document.metadata.drawingStatsID
            && previous?.canvasSize == workspace.document.canvasSize
        let oldResources = compatible ? Dictionary(uniqueKeysWithValues: previous!.resources.map { ($0.key, $0) }) : [:]
        var resources: [RecoveryResource] = []
        var sources: [(MTLTexture, PixelRegion)] = []
        var keys: [LayerResourceKey] = []
        var placeholders: [LayerHistorySnapshot] = []
        var byteCount = 0
        for layer in workspace.document.paintLayers {
            for kind in (layer.mask == nil ? [LayerHistoryResourceKind.content] : [.content, .mask]) {
                let key = LayerResourceKey(layerID: layer.id, kind: kind)
                let texture = kind == .mask ? layerSurfaceStore.readMaskTexture(for: layer.id)
                    : layerSurfaceStore.surfaceID(for: layer.id).flatMap(layerSurfaceStore.readTexture(for:))
                guard let texture else { throw PersistenceError.missingLayerTexture(layer.id) }
                let encoding = CanvasPixelEncoding(metalPixelFormat: texture.pixelFormat)
                let journal = layerSurfaceStore.changeJournal(for: key)
                let old = oldResources[key].flatMap { $0.encoding == encoding ? $0 : nil }
                let regions = journal.changedRegions(since: old?.cursor, canvasSize: workspace.document.canvasSize)
                for region in regions {
                    sources.append((texture, region))
                    keys.append(key)
                    byteCount += region.width * region.height * encoding.bytesPerPixel
                }
                resources.append(.init(key: key, cursor: journal.cursor, tiles: old?.tiles ?? [], pixelEncoding: encoding))
                let bpp = encoding.bytesPerPixel
                placeholders.append(.init(layerID: layer.id, resourceKind: kind,
                    texture: .init(width: 1, height: 1, bytesPerRow: bpp, pixelData: Data(count: bpp), encoding: encoding)))
            }
        }
        let pending = try serializer.enqueueCloneRegionsForDeferredSnapshot(sources)
        return QueuedRecoveryCapture(
            metadata: .init(package: .fromWorkspace(workspace, layerSnapshots: placeholders),
                            referenceImages: referenceImages, savedSnapshots: savedSnapshots),
            manifest: .init(canvasSize: workspace.document.canvasSize,
                            documentID: workspace.document.metadata.drawingStatsID, resources: resources),
            tileDescriptors: sources.indices.map { (keys[$0], sources[$0].1) },
            textureBatch: pending,
            previousURL: compatible ? recoveryProjectURL : nil, copiedPixelBytes: byteCount,
            preview: previewTexture.map(RecoveryPreviewTexture.init))
    }

    func writeIncrementalRecovery(_ capture: FrozenRecoveryCapture, to url: URL) throws {
        var capture = capture
        if let texture = capture.preview?.texture {
            capture.metadata.previewPNGData = try? autoreleasepool {
                let divisor = max(1, (max(texture.width, texture.height) + 511) / 512)
                return try thumbnailEncoder.encodePNG(from: serializer.downsampledSnapshot(texture: texture, divisor: divisor))
            }
        }
        try IncrementalRecoveryArchive.write(capture, serializer: serializer, to: url, limits: archiveReadLimits)
    }

    func invalidateIncrementalRecoveryBase() { incrementalRecoveryNeedsFullCapture = true }

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
            if backupURLs.count >= 2 {
                for destinationIndex in stride(
                    from: backupURLs.count - 1,
                    through: 1,
                    by: -1
                ) {
                    let sourceURL = backupURLs[destinationIndex - 1]
                    let destinationURL = backupURLs[destinationIndex]
                    guard fileManager.fileExists(atPath: sourceURL.path) else { continue }
                    if fileManager.fileExists(atPath: destinationURL.path) {
                        try fileManager.removeItem(at: destinationURL)
                    }
                    try fileManager.moveItem(at: sourceURL, to: destinationURL)
                }
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
        incrementalRecoveryNeedsFullCapture = false
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

    func recoverySummary() throws -> RecoveryProjectSummary {
        guard let url = bestAvailableRecoveryProjectURL() else {
            throw PersistenceError.invalidProject("没有可读取的恢复副本")
        }
        let inspection = try inspectProject(from: url)
        let preview: Data?
        if IncrementalRecoveryArchive.exists(at: url) {
            preview = try? archiveReader.previewData(from: url.appendingPathComponent("metadata"))
        } else if Self.shouldUseV2Archive(for: url) {
            preview = try? withV2PackageDirectory(for: url) { try archiveReader.previewData(from: $0) }
        } else { preview = nil }
        return .init(name: inspection.workspace.document.metadata.name,
            modified: try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
            canvasSize: inspection.workspace.document.canvasSize, previewPNGData: preview)
    }

    func openBestAvailableRecoveryProject(
        sourceRoot: URL? = nil,
        preflight: (ProjectOpenInspection) throws -> Void = { _ in },
        context: ProjectReadContext? = nil, stager: ProjectOpenTextureStager? = nil
    ) throws -> (url: URL, result: OpenProjectResult) {
        var lastError: Error?
        for candidate in sourceRoot.map(RecoveryCatalog.candidates(in:)) ?? recoveryProjectCandidates where
            FileManager.default.fileExists(atPath: candidate.path) {
            do {
                return (
                    candidate,
                    try openProject(from: candidate, preflight: preflight, context: context, stager: stager)
                )
            } catch {
                try context?.check()
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
        return (1...Self.recoveryBackupGenerationCount).map { generation in
            root.appendingPathComponent("Autosave-\(generation).artflex", isDirectory: true)
        }
    }

    private var recoveryProjectCandidates: [URL] {
        [recoveryProjectURL] + recoveryBackupProjectURLs
    }

    func inspectProject(from fileURL: URL) throws -> ProjectOpenInspection {
        if IncrementalRecoveryArchive.exists(at: fileURL) {
            return try IncrementalRecoveryArchive.inspect(at: fileURL, limits: archiveReadLimits)
        }
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
        preflight: (ProjectOpenInspection) throws -> Void = { _ in },
        context: ProjectReadContext? = nil, stager: ProjectOpenTextureStager? = nil
    ) throws -> OpenProjectResult {
        try ProjectFileAccess.read(fileURL) { coordinated in
            let revision = try ProjectFileRevision.read(coordinated)
            var reservation: WorkingResourceBudget.Reservation?
            var result = try openProjectUncoordinated(from: coordinated, preflight: { inspection in
                try preflight(inspection)
                let document = inspection.workspace.document
                let layerBytes = ApplicationResourceLedger.multiply(ApplicationResourceLedger.multiply(document.canvasSize.width,
                    document.canvasSize.height), document.colorStandard.pixelFormat.encoding.bytesPerPixel)
                let retainedLayers = stager == nil ? ApplicationResourceLedger.multiply(layerBytes, document.paintLayers.count * 2) : 0
                let cpuPeak = [inspection.estimatedReferenceResidentBytes, document.editableSourceByteCounts.resident,
                    ApplicationResourceLedger.multiply(layerBytes, inspection.savedSnapshotCount + 2), retainedLayers]
                    .reduce(0, ApplicationResourceLedger.add)
                reservation = try serializer.reserveWorkingMemory(bytes: cpuPeak)
            }, context: context, stager: stager)
            result.resourceReservation = reservation
            try revision.verify(at: coordinated)
            result.fileRevision = revision
            return result
        }
    }

    private func openProjectUncoordinated(
        from fileURL: URL,
        preflight: (ProjectOpenInspection) throws -> Void = { _ in },
        context: ProjectReadContext? = nil, stager: ProjectOpenTextureStager? = nil
    ) throws -> OpenProjectResult {
        let readContext = context ?? ProjectReadContext()
        try readContext.check()
        readContext.report(.inspecting)
        let reader = ProjectArchiveV2Reader(limits: archiveReadLimits, context: readContext)
        var prepared: [(layerID: LayerID, resourceKind: LayerHistoryResourceKind, texture: MTLTexture)] = []
        let consume: ((LayerHistorySnapshot, CanvasSize) throws -> Void)? = stager.map { stager in
            { snapshot, canvas in prepared.append(try stager.prepare(snapshot, canvas: canvas, context: readContext)) }
        }
        let payload: ProjectArchivePayload
        let storageFormat: ProjectStorageFormat
        if IncrementalRecoveryArchive.exists(at: fileURL) {
            try preflight(inspectProject(from: fileURL))
            payload = try IncrementalRecoveryArchive.read(at: fileURL, limits: archiveReadLimits, context: readContext, consumeLayer: consume)
            storageFormat = .archiveV2
        } else if Self.shouldUseV2Archive(for: fileURL) {
            payload = try withV2PackageDirectory(for: fileURL, context: readContext) { packageURL in
                readContext.preview(try? reader.previewData(from: packageURL))
                let inspection = try reader.inspect(from: packageURL)
                try preflight(ProjectOpenInspection(workspace: inspection.workspace,
                    savedSnapshotCount: inspection.savedSnapshotCount,
                    referenceArchiveBytes: inspection.referenceArchiveBytes,
                    estimatedReferenceResidentBytes: inspection.estimatedReferenceResidentBytes,
                    totalUncompressedAssetBytes: inspection.totalUncompressedAssetBytes, storageFormat: .archiveV2))
                return try reader.read(from: packageURL, consumeLayer: consume)
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
        try readContext.check()
        var package = payload.package
        if storageFormat == .legacyJSON, let consume {
            for index in package.layerSnapshots.indices {
                try readContext.check()
                readContext.report(.layers, completed: index, total: package.layerSnapshots.count)
                try consume(package.layerSnapshots[index], package.document.canvasSize)
                package.layerSnapshots[index].texture.pixelData = Data()
            }
        }
        var workspace = package.workspaceState
        workspace.document.normalizeLayerHierarchy()
        try validateOpenedProject(
            workspace: workspace,
            layerSnapshots: package.layerSnapshots, pixelsPrepared: stager != nil
        )

        var result = OpenProjectResult(
            workspace: workspace,
            layerSnapshots: package.layerSnapshots,
            referenceImages: payload.referenceImages,
            savedSnapshots: payload.savedSnapshots,
            previewPNGData: payload.previewPNGData,
            storageFormat: storageFormat
        )
        try readContext.check()
        if stager != nil { result.preparedTextures = .init(textures: prepared) }
        return result
    }

    private func withV2PackageDirectory<T>(
        for url: URL,
        context: ProjectReadContext? = nil,
        _ body: (URL) throws -> T
    ) throws -> T {
        if Self.isDirectory(at: url) {
            return try body(url)
        }
        return try flatContainer.withExtractedPackage(
            from: url,
            limits: archiveReadLimits, context: context,
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

    static func defaultRecoveryRootURL() -> URL {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("ArtFlex", isDirectory: true)
            .appendingPathComponent("Recovery", isDirectory: true)
    }

    static func discardStaleRecoveryStagingProjects(
        in rootURL: URL,
        now: Date = Date(),
        staleAfter: TimeInterval = staleRecoveryStagingAge,
        fileManager: FileManager = .default
    ) {
        guard let candidates = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
            options: []
        ) else {
            return
        }
        let cutoff = now.addingTimeInterval(-max(staleAfter, 0))
        for candidate in candidates where
            candidate.lastPathComponent.hasPrefix("Pending-")
                || candidate.lastPathComponent.hasPrefix(".Pending-") {
            let values = try? candidate.resourceValues(forKeys: [
                .contentModificationDateKey,
                .creationDateKey
            ])
            guard let lastWrite = values?.contentModificationDate ?? values?.creationDate,
                  lastWrite <= cutoff else {
                continue
            }
            try? fileManager.removeItem(at: candidate)
        }
    }

    private func validateOpenedProject(
        workspace: WorkspaceState,
        layerSnapshots: [LayerHistorySnapshot],
        pixelsPrepared: Bool = false
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

        let (expectedBytesPerRow, rowOverflow) = canvasSize.width.multipliedReportingOverflow(by: document.colorStandard.pixelFormat.encoding.bytesPerPixel)
        let (_, countOverflow) = expectedBytesPerRow.multipliedReportingOverflow(
            by: canvasSize.height
        )
        guard !rowOverflow, !countOverflow else {
            throw PersistenceError.invalidProject("画布尺寸超出支持范围")
        }

        for layerSnapshot in layerSnapshots {
            let texture = layerSnapshot.texture
            let encoding: CanvasPixelEncoding = layerSnapshot.resourceKind == .mask ? .grayscale8 : document.colorStandard.pixelFormat.encoding
            let expectedSnapshotBytesPerRow = canvasSize.width * encoding.bytesPerPixel
            let expectedSnapshotByteCount = expectedSnapshotBytesPerRow * canvasSize.height
            guard
                layerSnapshot.originX == 0,
                layerSnapshot.originY == 0,
                texture.width == canvasSize.width,
                texture.height == canvasSize.height,
                texture.encoding == encoding,
                texture.bytesPerRow == expectedSnapshotBytesPerRow,
                (pixelsPrepared ? texture.pixelData.isEmpty : texture.pixelData.count == expectedSnapshotByteCount)
            else {
                throw PersistenceError.invalidProject("图层像素尺寸或数据长度不匹配")
            }
        }
    }
}

import Foundation

enum ProjectArchiveCompression: String, Codable, Sendable, Equatable {
    case none
    case zlib
}

enum ProjectArchivePixelFormat: String, Codable, Sendable, Equatable {
    case premultipliedBGRA8SRGB
    case grayscale8Unorm
}

struct ProjectArchiveAssetDescriptor: Codable, Sendable, Equatable {
    var relativePath: String
    var compression: ProjectArchiveCompression
    var storedByteCount: Int
    var uncompressedByteCount: Int
    var sha256: String
}

struct ProjectArchiveLayerDescriptor: Codable, Sendable, Equatable {
    var layerID: LayerID
    var resourceKind: LayerHistoryResourceKind
    var originX: Int
    var originY: Int
    var width: Int
    var height: Int
    var bytesPerRow: Int
    var pixelFormat: ProjectArchivePixelFormat
    var asset: ProjectArchiveAssetDescriptor

    enum CodingKeys: String, CodingKey {
        case layerID
        case resourceKind
        case originX
        case originY
        case width
        case height
        case bytesPerRow
        case pixelFormat
        case asset
    }

    init(
        layerID: LayerID,
        resourceKind: LayerHistoryResourceKind = .content,
        originX: Int,
        originY: Int,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        pixelFormat: ProjectArchivePixelFormat,
        asset: ProjectArchiveAssetDescriptor
    ) {
        self.layerID = layerID
        self.resourceKind = resourceKind
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixelFormat = pixelFormat
        self.asset = asset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layerID = try container.decode(LayerID.self, forKey: .layerID)
        resourceKind = try container.decodeIfPresent(
            LayerHistoryResourceKind.self,
            forKey: .resourceKind
        ) ?? .content
        originX = try container.decode(Int.self, forKey: .originX)
        originY = try container.decode(Int.self, forKey: .originY)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
        bytesPerRow = try container.decode(Int.self, forKey: .bytesPerRow)
        pixelFormat = try container.decode(ProjectArchivePixelFormat.self, forKey: .pixelFormat)
        asset = try container.decode(ProjectArchiveAssetDescriptor.self, forKey: .asset)
    }
}

struct ProjectArchiveReferenceImageEntry: Codable, Sendable, Equatable {
    var descriptor: ProjectReferenceImageDescriptor
    var asset: ProjectArchiveAssetDescriptor
}

struct ProjectArchiveCanvasSnapshotEntry: Codable, Sendable, Equatable {
    var descriptor: PersistentCanvasSnapshotDescriptor
    var width: Int
    var height: Int
    var bytesPerRow: Int
    var pixelFormat: ProjectArchivePixelFormat
    var asset: ProjectArchiveAssetDescriptor
}

struct ProjectArchiveV2Manifest: Codable, Sendable, Equatable {
    static let formatIdentifier = "com.vladchen.artflex.project"
    static let currentFormatVersion = 2
    static let currentReaderVersion = 2
    static let manifestFilename = "manifest.json"
    static let projectStatePath = "project.json"

    var formatIdentifier: String
    var formatVersion: Int
    var minimumReaderVersion: Int
    var savedAt: Date
    var projectState: ProjectArchiveAssetDescriptor
    var layers: [ProjectArchiveLayerDescriptor]
    var referenceImages: [ProjectArchiveReferenceImageEntry]
    var savedSnapshots: [ProjectArchiveCanvasSnapshotEntry]

    enum CodingKeys: String, CodingKey {
        case formatIdentifier
        case formatVersion
        case minimumReaderVersion
        case savedAt
        case projectState
        case layers
        case referenceImages
        case savedSnapshots
    }

    init(
        savedAt: Date,
        projectState: ProjectArchiveAssetDescriptor,
        layers: [ProjectArchiveLayerDescriptor],
        referenceImages: [ProjectArchiveReferenceImageEntry],
        savedSnapshots: [ProjectArchiveCanvasSnapshotEntry] = []
    ) {
        self.formatIdentifier = Self.formatIdentifier
        self.formatVersion = Self.currentFormatVersion
        self.minimumReaderVersion = Self.currentReaderVersion
        self.savedAt = savedAt
        self.projectState = projectState
        self.layers = layers
        self.referenceImages = referenceImages
        self.savedSnapshots = savedSnapshots
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatIdentifier = try container.decode(String.self, forKey: .formatIdentifier)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        minimumReaderVersion = try container.decode(Int.self, forKey: .minimumReaderVersion)
        savedAt = try container.decode(Date.self, forKey: .savedAt)
        projectState = try container.decode(ProjectArchiveAssetDescriptor.self, forKey: .projectState)
        layers = try container.decode([ProjectArchiveLayerDescriptor].self, forKey: .layers)
        referenceImages = try container.decodeIfPresent(
            [ProjectArchiveReferenceImageEntry].self,
            forKey: .referenceImages
        ) ?? []
        // Optional on purpose: V2 packages written before persistent snapshots remain readable.
        savedSnapshots = try container.decodeIfPresent(
            [ProjectArchiveCanvasSnapshotEntry].self,
            forKey: .savedSnapshots
        ) ?? []
    }
}

struct ProjectArchivePayload: Sendable, Equatable {
    var package: ProjectPackage
    var referenceImages: [ProjectReferenceImagePayload]
    var savedSnapshots: [PersistentCanvasSnapshotPayload]

    init(
        package: ProjectPackage,
        referenceImages: [ProjectReferenceImagePayload] = [],
        savedSnapshots: [PersistentCanvasSnapshotPayload] = []
    ) {
        self.package = package
        self.referenceImages = referenceImages
        self.savedSnapshots = savedSnapshots
    }
}

struct ProjectArchiveReadLimits: Sendable, Equatable {
    var maximumManifestBytes: Int
    var maximumProjectStateBytes: Int
    var maximumStoredAssetBytes: Int
    var maximumUncompressedAssetBytes: Int
    var maximumTotalUncompressedBytes: Int
    var maximumLayerCount: Int
    var maximumReferenceImageCount: Int
    var maximumSavedSnapshotCount: Int

    static let standard = ProjectArchiveReadLimits(
        maximumManifestBytes: 8 * 1024 * 1024,
        maximumProjectStateBytes: 64 * 1024 * 1024,
        maximumStoredAssetBytes: 2 * 1024 * 1024 * 1024,
        maximumUncompressedAssetBytes: 4 * 1024 * 1024 * 1024,
        maximumTotalUncompressedBytes: 8 * 1024 * 1024 * 1024,
        maximumLayerCount: 4_096,
        maximumReferenceImageCount: ProjectReferenceImageDescriptor.maximumSlotCount,
        maximumSavedSnapshotCount: 6
    )
}

enum ProjectArchiveV2Error: LocalizedError, Sendable, Equatable {
    case destinationExistsAsFile
    case archiveIsNotDirectory
    case missingManifest
    case manifestTooLarge(Int)
    case invalidFormatIdentifier(String)
    case unsupportedFormatVersion(Int)
    case unsupportedMinimumReaderVersion(Int)
    case invalidRelativePath(String)
    case symbolicLinkNotAllowed(String)
    case missingAsset(String)
    case assetIsNotRegularFile(String)
    case storedByteCountMismatch(path: String, expected: Int, actual: Int)
    case assetTooLarge(path: String, byteCount: Int)
    case totalAssetSizeTooLarge
    case checksumMismatch(String)
    case duplicateLayerID(LayerID)
    case duplicateReferenceSlot(Int)
    case duplicateReferenceID(UUID)
    case duplicateSavedSnapshotID(UUID)
    case duplicatePixelResourceID(CanvasPixelResourceID)
    case duplicateAssetPath(String)
    case invalidLayerSnapshot(LayerID)
    case projectStateContainsInlineLayerSnapshots
    case projectLayerSetMismatch
    case invalidReferenceImage(String)
    case invalidSavedSnapshot(UUID)
    case malformedManifest(String)
    case malformedProjectState(String)
    case fileOperationFailed(String)

    var errorDescription: String? {
        switch self {
        case .destinationExistsAsFile:
            return "目标路径已存在且不是 ArtFlex 工程包目录"
        case .archiveIsNotDirectory:
            return "ArtFlex 工程包不是目录"
        case .missingManifest:
            return "ArtFlex 工程包缺少 manifest.json"
        case .manifestTooLarge(let byteCount):
            return "工程清单过大：\(byteCount) 字节"
        case .invalidFormatIdentifier(let identifier):
            return "工程格式标识无效：\(identifier)"
        case .unsupportedFormatVersion(let version):
            return "暂不支持工程格式版本 \(version)"
        case .unsupportedMinimumReaderVersion(let version):
            return "工程要求读取器版本 \(version) 或更高"
        case .invalidRelativePath(let path):
            return "工程包包含不安全的相对路径：\(path)"
        case .symbolicLinkNotAllowed(let path):
            return "工程包资产不允许使用符号链接：\(path)"
        case .missingAsset(let path):
            return "工程包缺少资产：\(path)"
        case .assetIsNotRegularFile(let path):
            return "工程包资产不是普通文件：\(path)"
        case .storedByteCountMismatch(let path, let expected, let actual):
            return "工程资产长度不匹配：\(path)，预期 \(expected)，实际 \(actual)"
        case .assetTooLarge(let path, let byteCount):
            return "工程资产超出读取上限：\(path)，\(byteCount) 字节"
        case .totalAssetSizeTooLarge:
            return "工程包解压后的总大小超出读取上限"
        case .checksumMismatch(let path):
            return "工程资产校验失败：\(path)"
        case .duplicateLayerID(let layerID):
            return "工程包包含重复图层资产：\(layerID.rawValue.uuidString)"
        case .duplicateReferenceSlot(let slot):
            return "工程包包含重复参考图槽位：\(slot)"
        case .duplicateReferenceID(let id):
            return "工程包包含重复参考图记录：\(id.uuidString)"
        case .duplicateSavedSnapshotID(let id):
            return "工程包包含重复快照记录：\(id.uuidString)"
        case .duplicatePixelResourceID(let id):
            return "工程包包含重复快照像素资源：\(id.rawValue.uuidString)"
        case .duplicateAssetPath(let path):
            return "工程包路径被多个不同资产占用：\(path)"
        case .invalidLayerSnapshot(let layerID):
            return "图层像素数据无效：\(layerID.rawValue.uuidString)"
        case .projectStateContainsInlineLayerSnapshots:
            return "V2 工程状态不应内联图层像素数据"
        case .projectLayerSetMismatch:
            return "工程图层列表与图层资产不一致"
        case .invalidReferenceImage(let reason):
            return "参考图资产无效：\(reason)"
        case .invalidSavedSnapshot(let id):
            return "画布快照像素数据无效：\(id.uuidString)"
        case .malformedManifest(let reason):
            return "工程清单无法解析：\(reason)"
        case .malformedProjectState(let reason):
            return "工程状态无法解析：\(reason)"
        case .fileOperationFailed(let reason):
            return "工程包文件操作失败：\(reason)"
        }
    }
}

enum ProjectArchiveRelativePath {
    static func validate(_ relativePath: String) throws -> [String] {
        guard
            !relativePath.isEmpty,
            !relativePath.hasPrefix("/"),
            !relativePath.contains("\\"),
            !relativePath.contains("\0")
        else {
            throw ProjectArchiveV2Error.invalidRelativePath(relativePath)
        }

        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ProjectArchiveV2Error.invalidRelativePath(relativePath)
        }
        return components
    }

    static func resolvedURL(
        in rootURL: URL,
        relativePath: String,
        fileManager: FileManager,
        requiresExistingFile: Bool
    ) throws -> URL {
        let components = try validate(relativePath)
        let standardizedRoot = rootURL.standardizedFileURL
        var candidate = standardizedRoot
        for component in components {
            candidate.appendPathComponent(component, isDirectory: false)
            if fileManager.fileExists(atPath: candidate.path),
               (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw ProjectArchiveV2Error.symbolicLinkNotAllowed(relativePath)
            }
        }

        let standardizedCandidate = candidate.standardizedFileURL
        guard pathComponents(of: standardizedCandidate, beginWith: standardizedRoot) else {
            throw ProjectArchiveV2Error.invalidRelativePath(relativePath)
        }

        if requiresExistingFile, !fileManager.fileExists(atPath: standardizedCandidate.path) {
            throw ProjectArchiveV2Error.missingAsset(relativePath)
        }
        return standardizedCandidate
    }

    private static func pathComponents(of candidate: URL, beginWith root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return zip(rootComponents, candidateComponents).allSatisfy(==)
    }
}

final class ProjectArchiveV2Writer {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    @discardableResult
    func write(
        _ payload: ProjectArchivePayload,
        to destinationURL: URL,
        savedAt: Date = Date()
    ) throws -> ProjectArchiveV2Manifest {
        try validate(payload)

        let parentURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)

        var destinationIsDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destinationURL.path, isDirectory: &destinationIsDirectory),
           !destinationIsDirectory.boolValue {
            throw ProjectArchiveV2Error.destinationExistsAsFile
        }

        let stagingURL = parentURL.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: true
        )
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
        var stagingStillExists = true
        defer {
            if stagingStillExists {
                try? fileManager.removeItem(at: stagingURL)
            }
        }

        do {
            var projectState = payload.package
            projectState.layerSnapshots = []
            let projectData = try Self.makeEncoder().encode(projectState)
            let projectAsset = makeAssetDescriptor(
                relativePath: ProjectArchiveV2Manifest.projectStatePath,
                compression: .none,
                storedData: projectData,
                uncompressedData: projectData
            )
            try write(projectData, descriptor: projectAsset, into: stagingURL)

            var layerDescriptors: [ProjectArchiveLayerDescriptor] = []
            layerDescriptors.reserveCapacity(payload.package.layerSnapshots.count)
            for layerSnapshot in payload.package.layerSnapshots {
                let pixelData = layerSnapshot.texture.pixelData
                let compressedData = try ZlibCodec.compress(pixelData)
                let resourceSuffix: String
                let pixelFormat: ProjectArchivePixelFormat
                switch layerSnapshot.resourceKind {
                case .content:
                    resourceSuffix = "content.bgra"
                    pixelFormat = .premultipliedBGRA8SRGB
                case .mask:
                    resourceSuffix = "mask.r8"
                    pixelFormat = .grayscale8Unorm
                }
                let relativePath = "layers/\(layerSnapshot.layerID.rawValue.uuidString.lowercased()).\(resourceSuffix).zlib"
                let asset = makeAssetDescriptor(
                    relativePath: relativePath,
                    compression: .zlib,
                    storedData: compressedData,
                    uncompressedData: pixelData
                )
                try write(compressedData, descriptor: asset, into: stagingURL)
                layerDescriptors.append(
                    ProjectArchiveLayerDescriptor(
                        layerID: layerSnapshot.layerID,
                        resourceKind: layerSnapshot.resourceKind,
                        originX: layerSnapshot.originX,
                        originY: layerSnapshot.originY,
                        width: layerSnapshot.texture.width,
                        height: layerSnapshot.texture.height,
                        bytesPerRow: layerSnapshot.texture.bytesPerRow,
                        pixelFormat: pixelFormat,
                        asset: asset
                    )
                )
            }

            var referenceEntries: [ProjectArchiveReferenceImageEntry] = []
            referenceEntries.reserveCapacity(payload.referenceImages.count)
            var writtenReferenceAssets: [ProjectReferenceImageAssetID: ProjectArchiveAssetDescriptor] = [:]
            for referenceImage in payload.referenceImages.sorted(by: {
                $0.descriptor.slotIndex < $1.descriptor.slotIndex
            }) {
                let asset: ProjectArchiveAssetDescriptor
                if let existing = writtenReferenceAssets[referenceImage.descriptor.assetID] {
                    asset = existing
                } else {
                    let relativePath = "assets/references/\(referenceImage.descriptor.assetID.rawValue).bin"
                    asset = makeAssetDescriptor(
                        relativePath: relativePath,
                        compression: .none,
                        storedData: referenceImage.encodedImageData,
                        uncompressedData: referenceImage.encodedImageData
                    )
                    try write(referenceImage.encodedImageData, descriptor: asset, into: stagingURL)
                    writtenReferenceAssets[referenceImage.descriptor.assetID] = asset
                }
                referenceEntries.append(
                    ProjectArchiveReferenceImageEntry(
                        descriptor: referenceImage.descriptor,
                        asset: asset
                    )
                )
            }

            var savedSnapshotEntries: [ProjectArchiveCanvasSnapshotEntry] = []
            savedSnapshotEntries.reserveCapacity(payload.savedSnapshots.count)
            for savedSnapshot in payload.savedSnapshots {
                let pixelData = savedSnapshot.pixels.pixelData
                let compressedData = try ZlibCodec.compress(pixelData)
                let resourceID = savedSnapshot.descriptor.pixelResourceID.rawValue.uuidString.lowercased()
                let relativePath = "snapshots/\(resourceID).bgra.zlib"
                let asset = makeAssetDescriptor(
                    relativePath: relativePath,
                    compression: .zlib,
                    storedData: compressedData,
                    uncompressedData: pixelData
                )
                try write(compressedData, descriptor: asset, into: stagingURL)
                savedSnapshotEntries.append(
                    ProjectArchiveCanvasSnapshotEntry(
                        descriptor: savedSnapshot.descriptor,
                        width: savedSnapshot.pixels.width,
                        height: savedSnapshot.pixels.height,
                        bytesPerRow: savedSnapshot.pixels.bytesPerRow,
                        pixelFormat: .premultipliedBGRA8SRGB,
                        asset: asset
                    )
                )
            }

            let manifest = ProjectArchiveV2Manifest(
                savedAt: savedAt,
                projectState: projectAsset,
                layers: layerDescriptors,
                referenceImages: referenceEntries,
                savedSnapshots: savedSnapshotEntries
            )
            let manifestData = try Self.makeEncoder().encode(manifest)
            let manifestURL = stagingURL.appendingPathComponent(ProjectArchiveV2Manifest.manifestFilename)
            try manifestData.write(to: manifestURL, options: .atomic)

            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(
                    destinationURL,
                    withItemAt: stagingURL,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: stagingURL, to: destinationURL)
            }
            stagingStillExists = false
            return manifest
        } catch let error as ProjectArchiveV2Error {
            throw error
        } catch let error as ProjectReferenceImageError {
            throw ProjectArchiveV2Error.invalidReferenceImage(error.localizedDescription)
        } catch {
            throw ProjectArchiveV2Error.fileOperationFailed(error.localizedDescription)
        }
    }

    private func validate(_ payload: ProjectArchivePayload) throws {
        let layerSnapshots = payload.package.layerSnapshots
        let resourceKeys = layerSnapshots.map {
            ProjectArchiveLayerResourceKey(layerID: $0.layerID, resourceKind: $0.resourceKind)
        }
        guard Set(resourceKeys).count == resourceKeys.count else {
            let duplicate = resourceKeys.first { key in resourceKeys.filter { $0 == key }.count > 1 }!
            throw ProjectArchiveV2Error.duplicateLayerID(duplicate.layerID)
        }

        let expectedResourceKeys = Self.expectedLayerResourceKeys(in: payload.package.document)
        guard Set(resourceKeys) == expectedResourceKeys else {
            throw ProjectArchiveV2Error.projectLayerSetMismatch
        }

        for layerSnapshot in layerSnapshots {
            let texture = layerSnapshot.texture
            let bytesPerPixel = layerSnapshot.resourceKind == .mask ? 1 : 4
            let (expectedBytesPerRow, rowOverflow) = texture.width.multipliedReportingOverflow(by: bytesPerPixel)
            let (expectedByteCount, countOverflow) = texture.bytesPerRow.multipliedReportingOverflow(by: texture.height)
            guard
                !rowOverflow,
                !countOverflow,
                layerSnapshot.originX >= 0,
                layerSnapshot.originY >= 0,
                texture.width > 0,
                texture.height > 0,
                texture.bytesPerRow == expectedBytesPerRow,
                texture.pixelData.count == expectedByteCount
            else {
                throw ProjectArchiveV2Error.invalidLayerSnapshot(layerSnapshot.layerID)
            }
        }

        var slots = Set<Int>()
        var recordIDs = Set<UUID>()
        for referenceImage in payload.referenceImages {
            do {
                try referenceImage.validate()
            } catch {
                throw ProjectArchiveV2Error.invalidReferenceImage(error.localizedDescription)
            }
            guard slots.insert(referenceImage.descriptor.slotIndex).inserted else {
                throw ProjectArchiveV2Error.duplicateReferenceSlot(referenceImage.descriptor.slotIndex)
            }
            guard recordIDs.insert(referenceImage.descriptor.id).inserted else {
                throw ProjectArchiveV2Error.duplicateReferenceID(referenceImage.descriptor.id)
            }
        }

        guard payload.savedSnapshots.count <= 6 else {
            throw ProjectArchiveV2Error.malformedManifest("画布快照数量超出上限")
        }
        var snapshotIDs = Set<UUID>()
        var pixelResourceIDs = Set<CanvasPixelResourceID>()
        for savedSnapshot in payload.savedSnapshots {
            let descriptor = savedSnapshot.descriptor
            let (expectedBytesPerRow, rowOverflow) = descriptor.canvasSize.width
                .multipliedReportingOverflow(by: 4)
            let (expectedByteCount, countOverflow) = expectedBytesPerRow
                .multipliedReportingOverflow(by: descriptor.canvasSize.height)
            guard snapshotIDs.insert(descriptor.id).inserted else {
                throw ProjectArchiveV2Error.duplicateSavedSnapshotID(descriptor.id)
            }
            guard pixelResourceIDs.insert(descriptor.pixelResourceID).inserted else {
                throw ProjectArchiveV2Error.duplicatePixelResourceID(descriptor.pixelResourceID)
            }
            guard
                descriptor.kind == .flattenedCanvas,
                descriptor.thumbnailResourceID == nil,
                descriptor.canvasSize == payload.package.document.canvasSize,
                !rowOverflow,
                !countOverflow,
                savedSnapshot.pixels.width == descriptor.canvasSize.width,
                savedSnapshot.pixels.height == descriptor.canvasSize.height,
                savedSnapshot.pixels.bytesPerRow == expectedBytesPerRow,
                savedSnapshot.pixels.pixelData.count == expectedByteCount
            else {
                throw ProjectArchiveV2Error.invalidSavedSnapshot(descriptor.id)
            }
        }
    }

    private static func expectedLayerResourceKeys(in document: ArtDocument) -> Set<ProjectArchiveLayerResourceKey> {
        var keys = Set(document.paintLayers.map {
            ProjectArchiveLayerResourceKey(layerID: $0.id, resourceKind: .content)
        })
        for layer in document.paintLayers where layer.mask != nil {
            keys.insert(ProjectArchiveLayerResourceKey(layerID: layer.id, resourceKind: .mask))
        }
        return keys
    }

    private func makeAssetDescriptor(
        relativePath: String,
        compression: ProjectArchiveCompression,
        storedData: Data,
        uncompressedData: Data
    ) -> ProjectArchiveAssetDescriptor {
        ProjectArchiveAssetDescriptor(
            relativePath: relativePath,
            compression: compression,
            storedByteCount: storedData.count,
            uncompressedByteCount: uncompressedData.count,
            sha256: ProjectReferenceImageHash.sha256Hex(uncompressedData)
        )
    }

    private func write(
        _ data: Data,
        descriptor: ProjectArchiveAssetDescriptor,
        into rootURL: URL
    ) throws {
        let destination = try ProjectArchiveRelativePath.resolvedURL(
            in: rootURL,
            relativePath: descriptor.relativePath,
            fileManager: fileManager,
            requiresExistingFile: false
        )
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

final class ProjectArchiveV2Reader {
    private let fileManager: FileManager
    private let limits: ProjectArchiveReadLimits

    init(
        fileManager: FileManager = .default,
        limits: ProjectArchiveReadLimits = .standard
    ) {
        self.fileManager = fileManager
        self.limits = limits
    }

    func read(from archiveURL: URL) throws -> ProjectArchivePayload {
        var archiveIsDirectory: ObjCBool = false
        guard
            fileManager.fileExists(atPath: archiveURL.path, isDirectory: &archiveIsDirectory),
            archiveIsDirectory.boolValue
        else {
            throw ProjectArchiveV2Error.archiveIsNotDirectory
        }

        let manifestURL = archiveURL.appendingPathComponent(ProjectArchiveV2Manifest.manifestFilename)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw ProjectArchiveV2Error.missingManifest
        }
        let manifestSize = try fileByteCount(at: manifestURL)
        guard manifestSize <= limits.maximumManifestBytes else {
            throw ProjectArchiveV2Error.manifestTooLarge(manifestSize)
        }

        let manifest: ProjectArchiveV2Manifest
        do {
            manifest = try Self.makeDecoder().decode(
                ProjectArchiveV2Manifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch {
            throw ProjectArchiveV2Error.malformedManifest(error.localizedDescription)
        }
        try validateManifestHeader(manifest)
        try validateManifestCollections(manifest)

        var totalUncompressedBytes = 0
        func reserveUncompressedBytes(_ count: Int) throws {
            let (sum, overflow) = totalUncompressedBytes.addingReportingOverflow(count)
            guard !overflow, sum <= limits.maximumTotalUncompressedBytes else {
                throw ProjectArchiveV2Error.totalAssetSizeTooLarge
            }
            totalUncompressedBytes = sum
        }

        try reserveUncompressedBytes(manifest.projectState.uncompressedByteCount)
        let projectData = try readAsset(
            manifest.projectState,
            from: archiveURL,
            maximumUncompressedBytes: limits.maximumProjectStateBytes
        )
        var package: ProjectPackage
        do {
            package = try Self.makeDecoder().decode(ProjectPackage.self, from: projectData)
        } catch {
            throw ProjectArchiveV2Error.malformedProjectState(error.localizedDescription)
        }
        guard package.layerSnapshots.isEmpty else {
            throw ProjectArchiveV2Error.projectStateContainsInlineLayerSnapshots
        }

        var layerSnapshots: [LayerHistorySnapshot] = []
        layerSnapshots.reserveCapacity(manifest.layers.count)
        for layer in manifest.layers {
            try validate(layer)
            try reserveUncompressedBytes(layer.asset.uncompressedByteCount)
            let pixelData = try readAsset(
                layer.asset,
                from: archiveURL,
                maximumUncompressedBytes: limits.maximumUncompressedAssetBytes
            )
            layerSnapshots.append(
                LayerHistorySnapshot(
                    layerID: layer.layerID,
                    resourceKind: layer.resourceKind,
                    texture: LayerTextureSnapshot(
                        width: layer.width,
                        height: layer.height,
                        bytesPerRow: layer.bytesPerRow,
                        pixelData: pixelData
                    ),
                    originX: layer.originX,
                    originY: layer.originY
                )
            )
        }
        let expectedResourceKeys = Self.expectedLayerResourceKeys(in: package.document)
        let decodedResourceKeys = Set(layerSnapshots.map {
            ProjectArchiveLayerResourceKey(layerID: $0.layerID, resourceKind: $0.resourceKind)
        })
        guard decodedResourceKeys == expectedResourceKeys else {
            throw ProjectArchiveV2Error.projectLayerSetMismatch
        }
        package.layerSnapshots = layerSnapshots

        var decodedAssetCache: [String: Data] = [:]
        var referenceImages: [ProjectReferenceImagePayload] = []
        referenceImages.reserveCapacity(manifest.referenceImages.count)
        for entry in manifest.referenceImages.sorted(by: {
            $0.descriptor.slotIndex < $1.descriptor.slotIndex
        }) {
            let data: Data
            if let cached = decodedAssetCache[entry.asset.relativePath] {
                data = cached
            } else {
                try reserveUncompressedBytes(entry.asset.uncompressedByteCount)
                data = try readAsset(
                    entry.asset,
                    from: archiveURL,
                    maximumUncompressedBytes: limits.maximumUncompressedAssetBytes
                )
                decodedAssetCache[entry.asset.relativePath] = data
            }
            do {
                referenceImages.append(
                    try ProjectReferenceImagePayload(
                        descriptor: entry.descriptor,
                        encodedImageData: data
                    )
                )
            } catch {
                throw ProjectArchiveV2Error.invalidReferenceImage(error.localizedDescription)
            }
        }

        var savedSnapshots: [PersistentCanvasSnapshotPayload] = []
        savedSnapshots.reserveCapacity(manifest.savedSnapshots.count)
        for entry in manifest.savedSnapshots {
            try validate(entry)
            guard entry.descriptor.canvasSize == package.document.canvasSize else {
                throw ProjectArchiveV2Error.invalidSavedSnapshot(entry.descriptor.id)
            }
            try reserveUncompressedBytes(entry.asset.uncompressedByteCount)
            let pixelData = try readAsset(
                entry.asset,
                from: archiveURL,
                maximumUncompressedBytes: limits.maximumUncompressedAssetBytes
            )
            savedSnapshots.append(
                PersistentCanvasSnapshotPayload(
                    descriptor: entry.descriptor,
                    pixels: LayerTextureSnapshot(
                        width: entry.width,
                        height: entry.height,
                        bytesPerRow: entry.bytesPerRow,
                        pixelData: pixelData
                    )
                )
            )
        }

        return ProjectArchivePayload(
            package: package,
            referenceImages: referenceImages,
            savedSnapshots: savedSnapshots
        )
    }

    private func validateManifestHeader(_ manifest: ProjectArchiveV2Manifest) throws {
        guard manifest.formatIdentifier == ProjectArchiveV2Manifest.formatIdentifier else {
            throw ProjectArchiveV2Error.invalidFormatIdentifier(manifest.formatIdentifier)
        }
        guard manifest.minimumReaderVersion <= ProjectArchiveV2Manifest.currentReaderVersion else {
            throw ProjectArchiveV2Error.unsupportedMinimumReaderVersion(manifest.minimumReaderVersion)
        }
        guard manifest.formatVersion == ProjectArchiveV2Manifest.currentFormatVersion else {
            throw ProjectArchiveV2Error.unsupportedFormatVersion(manifest.formatVersion)
        }
    }

    private func validateManifestCollections(_ manifest: ProjectArchiveV2Manifest) throws {
        guard manifest.layers.count <= limits.maximumLayerCount else {
            throw ProjectArchiveV2Error.malformedManifest("图层数量超出读取上限")
        }
        guard manifest.referenceImages.count <= limits.maximumReferenceImageCount else {
            throw ProjectArchiveV2Error.malformedManifest("参考图数量超出读取上限")
        }
        guard manifest.savedSnapshots.count <= limits.maximumSavedSnapshotCount else {
            throw ProjectArchiveV2Error.malformedManifest("画布快照数量超出读取上限")
        }

        var layerResources = Set<ProjectArchiveLayerResourceKey>()
        var referenceSlots = Set<Int>()
        var referenceIDs = Set<UUID>()
        var savedSnapshotIDs = Set<UUID>()
        var pixelResourceIDs = Set<CanvasPixelResourceID>()
        var descriptorByPath: [String: ProjectArchiveAssetDescriptor] = [:]

        func validateAsset(_ asset: ProjectArchiveAssetDescriptor) throws {
            _ = try ProjectArchiveRelativePath.validate(asset.relativePath)
            guard asset.storedByteCount >= 0, asset.uncompressedByteCount >= 0 else {
                throw ProjectArchiveV2Error.malformedManifest("资产长度不能为负数")
            }
            if let existing = descriptorByPath[asset.relativePath], existing != asset {
                throw ProjectArchiveV2Error.duplicateAssetPath(asset.relativePath)
            }
            descriptorByPath[asset.relativePath] = asset
        }

        try validateAsset(manifest.projectState)
        for layer in manifest.layers {
            let resourceKey = ProjectArchiveLayerResourceKey(
                layerID: layer.layerID,
                resourceKind: layer.resourceKind
            )
            guard layerResources.insert(resourceKey).inserted else {
                throw ProjectArchiveV2Error.duplicateLayerID(layer.layerID)
            }
            try validateAsset(layer.asset)
        }
        for entry in manifest.referenceImages {
            do {
                try entry.descriptor.validate()
            } catch {
                throw ProjectArchiveV2Error.invalidReferenceImage(error.localizedDescription)
            }
            guard referenceSlots.insert(entry.descriptor.slotIndex).inserted else {
                throw ProjectArchiveV2Error.duplicateReferenceSlot(entry.descriptor.slotIndex)
            }
            guard referenceIDs.insert(entry.descriptor.id).inserted else {
                throw ProjectArchiveV2Error.duplicateReferenceID(entry.descriptor.id)
            }
            try validateAsset(entry.asset)
        }
        for entry in manifest.savedSnapshots {
            guard savedSnapshotIDs.insert(entry.descriptor.id).inserted else {
                throw ProjectArchiveV2Error.duplicateSavedSnapshotID(entry.descriptor.id)
            }
            guard pixelResourceIDs.insert(entry.descriptor.pixelResourceID).inserted else {
                throw ProjectArchiveV2Error.duplicatePixelResourceID(entry.descriptor.pixelResourceID)
            }
            try validateAsset(entry.asset)
        }
    }

    private func validate(_ layer: ProjectArchiveLayerDescriptor) throws {
        let bytesPerPixel = layer.resourceKind == .mask ? 1 : 4
        let expectedPixelFormat: ProjectArchivePixelFormat = layer.resourceKind == .mask
            ? .grayscale8Unorm
            : .premultipliedBGRA8SRGB
        let (expectedBytesPerRow, rowOverflow) = layer.width.multipliedReportingOverflow(by: bytesPerPixel)
        let (expectedByteCount, countOverflow) = layer.bytesPerRow.multipliedReportingOverflow(by: layer.height)
        guard
            !rowOverflow,
            !countOverflow,
            layer.originX >= 0,
            layer.originY >= 0,
            layer.width > 0,
            layer.height > 0,
            layer.bytesPerRow == expectedBytesPerRow,
            layer.asset.uncompressedByteCount == expectedByteCount,
            layer.pixelFormat == expectedPixelFormat
        else {
            throw ProjectArchiveV2Error.invalidLayerSnapshot(layer.layerID)
        }
    }

    private func validate(_ entry: ProjectArchiveCanvasSnapshotEntry) throws {
        let descriptor = entry.descriptor
        let (expectedBytesPerRow, rowOverflow) = entry.width.multipliedReportingOverflow(by: 4)
        let (expectedByteCount, countOverflow) = entry.bytesPerRow.multipliedReportingOverflow(by: entry.height)
        guard
            !rowOverflow,
            !countOverflow,
            descriptor.kind == .flattenedCanvas,
            descriptor.thumbnailResourceID == nil,
            descriptor.canvasSize.width == entry.width,
            descriptor.canvasSize.height == entry.height,
            entry.width > 0,
            entry.height > 0,
            entry.bytesPerRow == expectedBytesPerRow,
            entry.asset.uncompressedByteCount == expectedByteCount,
            entry.pixelFormat == .premultipliedBGRA8SRGB
        else {
            throw ProjectArchiveV2Error.invalidSavedSnapshot(descriptor.id)
        }
    }

    private func readAsset(
        _ descriptor: ProjectArchiveAssetDescriptor,
        from rootURL: URL,
        maximumUncompressedBytes: Int
    ) throws -> Data {
        guard descriptor.storedByteCount <= limits.maximumStoredAssetBytes else {
            throw ProjectArchiveV2Error.assetTooLarge(
                path: descriptor.relativePath,
                byteCount: descriptor.storedByteCount
            )
        }
        guard descriptor.uncompressedByteCount <= maximumUncompressedBytes else {
            throw ProjectArchiveV2Error.assetTooLarge(
                path: descriptor.relativePath,
                byteCount: descriptor.uncompressedByteCount
            )
        }

        let assetURL = try ProjectArchiveRelativePath.resolvedURL(
            in: rootURL,
            relativePath: descriptor.relativePath,
            fileManager: fileManager,
            requiresExistingFile: true
        )
        let values = try assetURL.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            throw ProjectArchiveV2Error.assetIsNotRegularFile(descriptor.relativePath)
        }
        let actualStoredByteCount = try fileByteCount(at: assetURL)
        guard actualStoredByteCount == descriptor.storedByteCount else {
            throw ProjectArchiveV2Error.storedByteCountMismatch(
                path: descriptor.relativePath,
                expected: descriptor.storedByteCount,
                actual: actualStoredByteCount
            )
        }

        let storedData = try Data(contentsOf: assetURL, options: [.mappedIfSafe])
        let decodedData: Data
        switch descriptor.compression {
        case .none:
            guard storedData.count == descriptor.uncompressedByteCount else {
                throw ProjectArchiveV2Error.storedByteCountMismatch(
                    path: descriptor.relativePath,
                    expected: descriptor.uncompressedByteCount,
                    actual: storedData.count
                )
            }
            decodedData = storedData
        case .zlib:
            decodedData = try ZlibCodec.decompress(
                storedData,
                expectedSize: descriptor.uncompressedByteCount
            )
        }

        guard ProjectReferenceImageHash.sha256Hex(decodedData) == descriptor.sha256 else {
            throw ProjectArchiveV2Error.checksumMismatch(descriptor.relativePath)
        }
        return decodedData
    }

    private func fileByteCount(at url: URL) throws -> Int {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let number = attributes[.size] as? NSNumber else {
            throw ProjectArchiveV2Error.fileOperationFailed("无法读取 \(url.lastPathComponent) 的文件长度")
        }
        return number.intValue
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func expectedLayerResourceKeys(in document: ArtDocument) -> Set<ProjectArchiveLayerResourceKey> {
        var keys = Set(document.paintLayers.map {
            ProjectArchiveLayerResourceKey(layerID: $0.id, resourceKind: .content)
        })
        for layer in document.paintLayers where layer.mask != nil {
            keys.insert(ProjectArchiveLayerResourceKey(layerID: layer.id, resourceKind: .mask))
        }
        return keys
    }
}

private struct ProjectArchiveLayerResourceKey: Hashable {
    var layerID: LayerID
    var resourceKind: LayerHistoryResourceKind
}

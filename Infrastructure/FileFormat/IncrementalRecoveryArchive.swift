import Foundation
import Metal

struct RecoveryTile: Codable, Sendable, Equatable {
    var region: PixelRegion
    var sha256: String
    var storedBytes: Int
    var byteCount: Int
    var filename: String { sha256 + ".zlib" }
}

struct RecoveryResource: Codable, Sendable {
    var key: LayerResourceKey
    var cursor: LayerChangeCursor
    var tiles: [RecoveryTile]
    var pixelEncoding: CanvasPixelEncoding? = nil
    var encoding: CanvasPixelEncoding { pixelEncoding ?? (key.kind == .mask ? .grayscale8 : .premultipliedBGRA8SRGB) }
}

struct IncrementalRecoveryManifest: Codable, Sendable {
    static let filename = "incremental.json"
    var version = 1
    var canvasSize: CanvasSize
    var documentID: UUID
    var resources: [RecoveryResource]
}

struct FrozenRecoveryTile: @unchecked Sendable {
    var key: LayerResourceKey
    var region: PixelRegion
    var texture: MTLTexture
}

struct FrozenRecoveryCapture: @unchecked Sendable {
    var metadata: ProjectArchivePayload
    var manifest: IncrementalRecoveryManifest
    var changedTiles: [FrozenRecoveryTile]
    var previousURL: URL?
    var copiedPixelBytes: Int
}

/// Recovery generations are self-contained. Immutable compressed tiles are hard-linked between
/// generations, never referenced by a mutable chain; deleting an older generation is safe.
enum IncrementalRecoveryArchive {
    static func exists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(IncrementalRecoveryManifest.filename).path)
    }

    static func manifest(at url: URL, limits: ProjectArchiveReadLimits) throws -> IncrementalRecoveryManifest {
        let manifestURL = url.appendingPathComponent(IncrementalRecoveryManifest.filename)
        let data = try readRegularFile(manifestURL, maximumBytes: limits.maximumManifestBytes)
        let result = try JSONDecoder().decode(IncrementalRecoveryManifest.self, from: data)
        guard result.version == 1, result.canvasSize.width > 0, result.canvasSize.height > 0,
              result.canvasSize.width <= limits.maximumCanvasEdge, result.canvasSize.height <= limits.maximumCanvasEdge,
              result.canvasSize.width * result.canvasSize.height <= limits.maximumCanvasPixelCount,
              result.resources.count <= limits.maximumLayerCount,
              Set(result.resources.map(\.key)).count == result.resources.count,
              let grid = TileGrid(canvasSize: result.canvasSize) else {
            throw PersistenceError.invalidProject("增量恢复清单无效")
        }
        let expected = Set(grid.intersections(with: grid.canvasBounds).map(\.canvasRegion))
        var total = 0
        for resource in result.resources {
            guard resource.tiles.count == expected.count,
                  Set(resource.tiles.map(\.region)) == expected else {
                throw PersistenceError.invalidProject("增量恢复分块不完整或重叠")
            }
            let bpp = resource.encoding.bytesPerPixel
            for tile in resource.tiles {
                guard tile.sha256.count == 64, tile.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                      tile.storedBytes > 0, tile.storedBytes <= limits.maximumStoredAssetBytes,
                      tile.byteCount == tile.region.width * tile.region.height * bpp else {
                    throw PersistenceError.invalidProject("增量恢复分块描述无效")
                }
                let (sum, overflow) = total.addingReportingOverflow(tile.byteCount)
                guard !overflow, sum <= limits.maximumTotalUncompressedBytes else { throw ProjectArchiveV2Error.totalAssetSizeTooLarge }
                total = sum
            }
        }
        return result
    }

    static func write(_ capture: FrozenRecoveryCapture, serializer: LayerTextureSerializer,
                      to url: URL, limits: ProjectArchiveReadLimits) throws {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists) }
        try manager.createDirectory(at: url.appendingPathComponent("tiles"), withIntermediateDirectories: true)
        var manifest = capture.manifest
        var changed: [LayerResourceKey: [PixelRegion: RecoveryTile]] = [:]
        for item in capture.changedTiles {
            try Task.checkCancellation()
            let pixels = try serializer.snapshot(texture: item.texture).pixelData
            let compressed = try ZlibCodec.compress(pixels)
            let tile = RecoveryTile(region: item.region, sha256: ProjectReferenceImageHash.sha256Hex(pixels),
                                    storedBytes: compressed.count, byteCount: pixels.count)
            let target = url.appendingPathComponent("tiles").appendingPathComponent(tile.filename)
            if !manager.fileExists(atPath: target.path) { try compressed.write(to: target, options: .atomic) }
            changed[item.key, default: [:]][item.region] = tile
        }
        for index in manifest.resources.indices {
            let key = manifest.resources[index].key
            let old = Dictionary(uniqueKeysWithValues: manifest.resources[index].tiles.map { ($0.region, $0) })
            guard let grid = TileGrid(canvasSize: manifest.canvasSize) else { throw CocoaError(.fileWriteUnknown) }
            manifest.resources[index].tiles = try grid.intersections(with: grid.canvasBounds).map { entry in
                let region = entry.canvasRegion
                if let tile = changed[key]?[region] { return tile }
                guard let tile = old[region], let previous = capture.previousURL else {
                    throw PersistenceError.invalidProject("缺少增量恢复底稿分块")
                }
                let target = url.appendingPathComponent("tiles").appendingPathComponent(tile.filename)
                if !manager.fileExists(atPath: target.path) {
                    let source = previous.appendingPathComponent("tiles").appendingPathComponent(tile.filename)
                    // Verify before inheriting; a corrupt old tile must not silently poison all generations.
                    _ = try readTile(tile, at: previous, limits: limits)
                    do { try manager.linkItem(at: source, to: target) }
                    catch { try manager.copyItem(at: source, to: target) }
                }
                return tile
            }
        }
        try ProjectArchiveV2Writer(limits: limits).write(capture.metadata, to: url.appendingPathComponent("metadata"))
        let data = try JSONEncoder().encode(manifest)
        guard data.count <= limits.maximumManifestBytes else { throw ProjectArchiveV2Error.manifestTooLarge(data.count) }
        try data.write(to: url.appendingPathComponent(IncrementalRecoveryManifest.filename), options: .atomic)
        _ = try inspect(at: url, limits: limits)
    }

    static func inspect(at url: URL, limits: ProjectArchiveReadLimits) throws -> ProjectOpenInspection {
        let manifest = try manifest(at: url, limits: limits)
        let metadata = try ProjectArchiveV2Reader(limits: limits).inspect(from: url.appendingPathComponent("metadata"))
        let doc = metadata.workspace.document
        var expected = Set(doc.paintLayers.map { LayerResourceKey(layerID: $0.id, kind: .content) })
        for layer in doc.paintLayers where layer.mask != nil { expected.insert(.init(layerID: layer.id, kind: .mask)) }
        guard manifest.canvasSize == doc.canvasSize, manifest.documentID == doc.metadata.drawingStatsID,
              manifest.resources.allSatisfy({ $0.encoding == ($0.key.kind == .mask ? .grayscale8 : doc.colorStandard.pixelFormat.encoding) }),
              Set(manifest.resources.map(\.key)) == expected else { throw PersistenceError.invalidProject("增量恢复文档与像素不一致") }
        let bytes = manifest.resources.reduce(0) { $0 + $1.tiles.reduce(0) { $0 + $1.byteCount } }
        let (total, overflow) = bytes.addingReportingOverflow(metadata.totalUncompressedAssetBytes)
        guard !overflow, total <= limits.maximumTotalUncompressedBytes else { throw ProjectArchiveV2Error.totalAssetSizeTooLarge }
        return .init(workspace: metadata.workspace, savedSnapshotCount: metadata.savedSnapshotCount,
                     referenceArchiveBytes: metadata.referenceArchiveBytes,
                     estimatedReferenceResidentBytes: metadata.estimatedReferenceResidentBytes,
                     totalUncompressedAssetBytes: total, storageFormat: .archiveV2)
    }

    static func read(at url: URL, limits: ProjectArchiveReadLimits) throws -> ProjectArchivePayload {
        _ = try inspect(at: url, limits: limits)
        let manifest = try manifest(at: url, limits: limits)
        var payload = try ProjectArchiveV2Reader(limits: limits).read(from: url.appendingPathComponent("metadata"))
        payload.package.layerSnapshots = try manifest.resources.map { resource in
            let bpp = resource.encoding.bytesPerPixel
            let rowBytes = manifest.canvasSize.width * bpp
            var pixels = Data(count: rowBytes * manifest.canvasSize.height)
            for tile in resource.tiles {
                let bytes = try readTile(tile, at: url, limits: limits)
                pixels.withUnsafeMutableBytes { target in
                    bytes.withUnsafeBytes { source in
                        for row in 0..<tile.region.height {
                            memcpy(target.baseAddress!.advanced(by: (tile.region.originY + row) * rowBytes + tile.region.originX * bpp),
                                   source.baseAddress!.advanced(by: row * tile.region.width * bpp), tile.region.width * bpp)
                        }
                    }
                }
            }
            return LayerHistorySnapshot(layerID: resource.key.layerID, resourceKind: resource.key.kind,
                texture: .init(width: manifest.canvasSize.width, height: manifest.canvasSize.height,
                               bytesPerRow: rowBytes, pixelData: pixels, encoding: resource.encoding))
        }
        return payload
    }

    private static func readTile(_ tile: RecoveryTile, at url: URL, limits: ProjectArchiveReadLimits) throws -> Data {
        let directory = url.appendingPathComponent("tiles")
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
        let stored = try readRegularFile(directory.appendingPathComponent(tile.filename), maximumBytes: limits.maximumStoredAssetBytes)
        guard stored.count == tile.storedBytes else { throw CocoaError(.fileReadCorruptFile) }
        let bytes = try ZlibCodec.decompress(stored, expectedSize: tile.byteCount)
        guard ProjectReferenceImageHash.sha256Hex(bytes) == tile.sha256 else { throw ProjectArchiveV2Error.checksumMismatch(tile.filename) }
        return bytes
    }

    private static func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let count = values.fileSize, count >= 0, count <= maximumBytes else { throw CocoaError(.fileReadCorruptFile) }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }
}

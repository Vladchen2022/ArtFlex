import Foundation

/// Disposable, per-workspace pixel storage. Not an autosave or an on-disk document format.
/// The serial worker bounds compression scratch space to one 4 MiB chunk at a time.
final class HistoryDiskCache: @unchecked Sendable {
    static let defaultMaximumBytes = 2 * 1024 * 1024 * 1024
    let directoryURL: URL
    let maximumBytes: Int
    private let queue = DispatchQueue(label: "ArtFlex.history.disk", qos: .utility)
    private let lock = NSLock()
    private var reservedBytes = 0
    private var failure: String?

    init(rootURL: URL, maximumBytes: Int = defaultMaximumBytes) {
        directoryURL = rootURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.maximumBytes = max(0, maximumBytes)
    }

    deinit {
        // Only this instance's UUID directory is owned by this cache.
        let url = directoryURL
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    var reservedByteCount: Int { lock.withLock { reservedBytes } }
    var lastFailure: String? { lock.withLock { failure } }

    fileprivate func reserve(_ bytes: Int) -> Bool {
        lock.withLock {
            guard failure == nil, bytes <= maximumBytes - reservedBytes else { return false }
            reservedBytes += bytes
            return true
        }
    }

    fileprivate func release(_ bytes: Int, file: URL?) {
        // Deletion is queued before a later writer can use the released reservation, on the
        // same serial queue. Reclaim logical capacity immediately without blocking input.
        if let file {
            queue.async { [self] in
                do { try FileManager.default.removeItem(at: file) }
                catch let error as CocoaError where error.code == .fileNoSuchFile { }
                catch { recordFailure(error) }
            }
        }
        lock.withLock { reservedBytes = max(0, reservedBytes - bytes) }
    }

    fileprivate func submit(_ payload: HistoryPixelPayload) {
        queue.async { [weak payload] in
            guard let payload else { return }
            autoreleasepool { payload.writeArchive() }
        }
    }

    fileprivate func recordFailure(_ error: Error) {
        lock.withLock { failure = "撤销缓存写入失败，已保留内存记录：\(error.localizedDescription)" }
    }

    /// Test/diagnostic barrier; never used by drawing or checkpoint capture.
    func waitForPendingWrites() { queue.sync {} }
}

private struct HistoryDiskChunk: Sendable {
    let offset: UInt64
    let storedCount: Int
    let rawCount: Int
    let compressed: Bool
    let digest: String
}

private struct HistoryDiskResource: Sendable {
    var template: LayerHistorySnapshot
    var chunks: [HistoryDiskChunk]
}

private struct HistoryDiskArchive: Sendable {
    let url: URL
    let resources: [HistoryDiskResource]
    let byteCount: Int

    func validate() throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard try file.seekToEnd() == UInt64(byteCount) else { throw HistoryDiskError.invalidArchive }
        for resource in resources {
            for chunk in resource.chunks {
                try file.seek(toOffset: chunk.offset)
                guard let data = try file.read(upToCount: chunk.storedCount),
                      data.count == chunk.storedCount,
                      ProjectReferenceImageHash.sha256Hex(data) == chunk.digest else {
                    throw HistoryDiskError.invalidArchive
                }
            }
        }
    }

    func read() throws -> [LayerHistorySnapshot] {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard try file.seekToEnd() == UInt64(byteCount) else { throw HistoryDiskError.invalidArchive }
        return try resources.map { resource in
            var result = resource.template
            var data = Data()
            data.reserveCapacity(resource.chunks.reduce(0) { $0 + $1.rawCount })
            for chunk in resource.chunks {
                try file.seek(toOffset: chunk.offset)
                guard let stored = try file.read(upToCount: chunk.storedCount),
                      stored.count == chunk.storedCount,
                      ProjectReferenceImageHash.sha256Hex(stored) == chunk.digest else {
                    throw HistoryDiskError.invalidArchive
                }
                let decoded = chunk.compressed
                    ? try ZlibCodec.decompress(stored, expectedSize: chunk.rawCount) : stored
                guard decoded.count == chunk.rawCount else { throw HistoryDiskError.invalidArchive }
                data.append(decoded)
            }
            result.texture.pixelData = data
            return result
        }
    }
}

enum HistoryDiskError: LocalizedError {
    case invalidArchive
    case unavailable
    var errorDescription: String? {
        "无法读取这一步的撤销缓存。画布和历史位置未改变；请先保存当前工程。"
    }
}

/// Pixel ownership is separate from the history metadata. The lock protects only small state
/// transitions; compression and file I/O never run while holding it.
final class HistoryPixelPayload: @unchecked Sendable {
    let rawByteCount: Int
    private let cache: HistoryDiskCache?
    private let lock = NSLock()
    private var snapshots: [LayerHistorySnapshot]?
    private var archive: HistoryDiskArchive?
    private var pending = false
    private var failed = false
    private var discarded = false
    private var reservation = 0

    init(_ snapshots: [LayerHistorySnapshot], cache: HistoryDiskCache?) {
        self.snapshots = snapshots
        self.cache = cache
        rawByteCount = snapshots.reduce(0) { $0 + $1.approxByteCount }
    }

    deinit { discard() }

    var residentBytes: Int { lock.withLock { snapshots == nil ? 0 : rawByteCount } }
    var projectedResidentBytes: Int { lock.withLock { pending || snapshots == nil ? 0 : rawByteCount } }
    var diskBytes: Int { lock.withLock { archive?.byteCount ?? 0 } }
    var isPending: Bool { lock.withLock { pending } }

    func read() throws -> [LayerHistorySnapshot] {
        let state = lock.withLock { (snapshots, archive) }
        if let snapshots = state.0 { return snapshots }
        guard let archive = state.1 else { throw HistoryDiskError.unavailable }
        do { return try archive.read() }
        catch { throw HistoryDiskError.invalidArchive }
    }

    func validateReadable() throws {
        let state = lock.withLock { (snapshots != nil, archive) }
        if state.0 { return }
        guard let archive = state.1 else { throw HistoryDiskError.unavailable }
        do { try archive.validate() }
        catch { throw HistoryDiskError.invalidArchive }
    }

    @discardableResult
    func spill() -> Bool {
        guard let cache, rawByteCount > 0 else { return false }
        let accepted = lock.withLock {
            if archive != nil || pending { return true }
            guard !failed, !discarded, cache.reserve(rawByteCount) else { return false }
            reservation = rawByteCount
            pending = true
            return true
        }
        if accepted { cache.submit(self) }
        return accepted
    }

    func discard() {
        let old = lock.withLock { () -> (Int, URL?) in
            discarded = true
            pending = false
            snapshots = nil
            let old = (reservation, archive?.url)
            reservation = 0
            archive = nil
            return old
        }
        cache?.release(old.0, file: old.1)
    }

    fileprivate func writeArchive() {
        guard let cache,
              let source = lock.withLock({ !discarded && pending ? snapshots : nil }) else { return }
        let url = cache.directoryURL.appendingPathComponent(UUID().uuidString + ".pixels")
        do {
            guard cache.lastFailure == nil else { throw HistoryDiskError.unavailable }
            try FileManager.default.createDirectory(at: cache.directoryURL, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            var resources: [HistoryDiskResource] = []
            var offset: UInt64 = 0
            for snapshot in source {
                var template = snapshot
                template.texture.pixelData = Data()
                var resource = HistoryDiskResource(template: template, chunks: [])
                let pixels = snapshot.texture.pixelData
                for start in stride(from: 0, to: pixels.count, by: 4 * 1024 * 1024) {
                    if lock.withLock({ discarded }) { throw HistoryDiskError.unavailable }
                    let raw = pixels.subdata(in: start..<min(pixels.count, start + 4 * 1024 * 1024))
                    let compressed = try ZlibCodec.compress(raw, level: 1)
                    let useCompressed = compressed.count < raw.count
                    let stored = useCompressed ? compressed : raw
                    try file.write(contentsOf: stored)
                    resource.chunks.append(HistoryDiskChunk(
                        offset: offset, storedCount: stored.count, rawCount: raw.count,
                        compressed: useCompressed, digest: ProjectReferenceImageHash.sha256Hex(stored)
                    ))
                    offset += UInt64(stored.count)
                }
                resources.append(resource)
            }
            try file.synchronize()
            let completed = HistoryDiskArchive(url: url, resources: resources, byteCount: Int(offset))
            // Verify the bytes actually written before surrendering the only RAM copy.
            // Chunked verification avoids allocating a second complete history entry.
            try completed.validate()
            let keep = lock.withLock {
                pending = false
                guard !discarded else { return false }
                archive = completed
                snapshots = nil
                return true
            }
            if !keep { try? FileManager.default.removeItem(at: url) }
        } catch {
            try? FileManager.default.removeItem(at: url)
            let released = lock.withLock { () -> Int in
                pending = false
                failed = true
                let bytes = reservation
                reservation = 0
                return bytes
            }
            cache.release(released, file: nil)
            if !lock.withLock({ discarded }) { cache.recordFailure(error) }
        }
    }
}

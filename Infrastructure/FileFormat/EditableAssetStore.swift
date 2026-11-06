import Foundation

/// Disposable content-addressed storage, shared by live documents and history values.
/// References own files. Capacity exhaustion rejects the new operation; live assets are never evicted.
final class EditableAssetStore: @unchecked Sendable {
    static let shared = EditableAssetStore(rootURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("ArtFlex-editable-assets", isDirectory: true))
    let directoryURL: URL
    let maximumBytes: Int
    private let lock = NSLock()
    private let deletionQueue = DispatchQueue(label: "ArtFlex.editable-assets.cleanup", qos: .utility)
    private var references: [String: WeakReference] = [:]
    private var usedBytes = 0
    private struct WeakReference { weak var value: Reference? }

    init(rootURL: URL, maximumBytes: Int = 4 * 1024 * 1024 * 1024) {
        directoryURL = rootURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.maximumBytes = max(0, maximumBytes)
    }

    var reservedByteCount: Int { lock.withLock { usedBytes } }

    func store(_ compressed: Data, sha256: String, byteCount: Int) throws -> Reference {
        guard sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit }), byteCount >= 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let key = "\(sha256)-\(byteCount)"
        return try lock.withLock {
            if let existing = references[key]?.value {
                try existing.validate()
                return existing
            }
            guard compressed.count <= maximumBytes - usedBytes else {
                throw CanvasResourceError(message: "源素材缓存已达到容量上限，当前操作未应用；请先保存并关闭不使用的画稿")
            }
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            // UUID prevents a retiring reference's deferred deletion from removing a new generation.
            let url = directoryURL.appendingPathComponent("\(key)-\(UUID().uuidString).zlib")
            try compressed.write(to: url, options: .atomic)
            let reference = Reference(store: self, url: url, sha256: sha256, byteCount: byteCount,
                storedCount: compressed.count, storedHash: ProjectReferenceImageHash.sha256Hex(compressed))
            references = references.filter { $0.value.value != nil }
            references[key] = WeakReference(value: reference)
            usedBytes += compressed.count
            return reference
        }
    }

    private func release(url: URL, bytes: Int) {
        deletionQueue.async { [self] in
            do {
                try FileManager.default.removeItem(at: url)
                lock.withLock { usedBytes -= bytes }
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                lock.withLock { usedBytes -= bytes }
            } catch { /* Keep the capacity charged if deletion failed. */ }
        }
    }

    func waitForPendingDeletion() { deletionQueue.sync {} }

    deinit { try? FileManager.default.removeItem(at: directoryURL) }

    final class Reference: @unchecked Sendable {
        private let store: EditableAssetStore
        let url: URL
        let sha256: String
        let byteCount: Int
        let storedCount: Int
        private let storedHash: String
        fileprivate init(store: EditableAssetStore, url: URL, sha256: String, byteCount: Int,
                         storedCount: Int, storedHash: String) {
            self.store = store; self.url = url; self.sha256 = sha256; self.byteCount = byteCount
            self.storedCount = storedCount; self.storedHash = storedHash
        }
        func read() throws -> Data {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.size] as? NSNumber)?.intValue == storedCount else { throw CocoaError(.fileReadCorruptFile) }
            let data = try Data(contentsOf: url)
            guard data.count == storedCount, ProjectReferenceImageHash.sha256Hex(data) == storedHash else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return data
        }
        func validate() throws { _ = try read() }
        deinit { store.release(url: url, bytes: storedCount) }
    }
}

import AppleArchive
import Foundation
import System

/// AppleArchive calls this before creating each filesystem entry. Never validate traversal
/// or links only after extraction. Completion callbacks can arrive on different workers.
final class ProjectArchiveExtractionGuard {
    private let lock = NSLock()
    private let limits: ProjectArchiveReadLimits
    private let root: URL
    private let context: ProjectReadContext?
    private var paths = Set<String>()
    private var completedPaths = Set<String>()
    private var storedBytes: UInt64 = 0
    private var didDeliverPreview = false
    private var error: Error?
    var failure: Error? { lock.withLock { error } }

    init(limits: ProjectArchiveReadLimits, root: URL, context: ProjectReadContext?) {
        self.limits = limits; self.root = root; self.context = context
    }

    func filter(_ message: ArchiveHeader.EntryMessage, path: FilePath, data: ArchiveHeader.EntryFilterData?) -> ArchiveHeader.EntryMessageStatus {
        if context?.cancellation.isCancelled == true { return .cancel }
        do {
            if message == .extractBegin {
                guard case .header(let header) = data, let entryPath = header.entryPath?.string,
                      header.entryType == .regularFile || header.entryType == .directory else {
                    throw ProjectArchiveFlatContainerError.unsupportedArchiveEntry(path.string)
                }
                // writeDirectoryContents emits an empty path for the root directory.
                if !(header.entryType == .directory && (entryPath.isEmpty || entryPath == ".")) {
                    do { _ = try ProjectArchiveRelativePath.validate(entryPath) }
                    catch { throw ProjectArchiveFlatContainerError.unsupportedArchiveEntry(entryPath) }
                }
                let count: UInt64
                if case .blob(_, let size, _) = header.field(forKey: .init("DAT")) { count = size } else { count = 0 }
                try lock.withLock {
                    let maximumEntries = limits.maximumLayerCount * 4 + limits.maximumReferenceImageCount + limits.maximumSavedSnapshotCount + 64
                    guard paths.insert(entryPath).inserted, paths.count <= maximumEntries,
                          count <= UInt64(limits.maximumStoredAssetBytes),
                          count <= UInt64(limits.maximumTotalUncompressedBytes) + 32 * 1024 * 1024 - min(storedBytes, UInt64(limits.maximumTotalUncompressedBytes) + 32 * 1024 * 1024) else {
                        throw ProjectArchiveFlatContainerError.unsupportedArchiveEntry(entryPath)
                    }
                    storedBytes += count
                }
            } else if message == .extractEnd {
                let (completed, previewReady) = lock.withLock {
                    completedPaths.insert(path.string)
                    let ready = !didDeliverPreview && completedPaths.contains(ProjectArchiveV2Manifest.manifestFilename)
                        && completedPaths.contains(ProjectArchiveV2Manifest.previewPath)
                    if ready { didDeliverPreview = true }
                    return (completedPaths.count, ready)
                }
                context?.report(.extracting, completed: completed)
                if previewReady, let context {
                    context.preview(try? ProjectArchiveV2Reader(limits: limits).previewData(from: root))
                }
            }
            return .ok
        } catch {
            lock.withLock { if self.error == nil { self.error = error } }
            return .cancel
        }
    }
}

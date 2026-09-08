import Foundation
import Testing
@testable import ArtFlex

struct HistoryDiskCacheTests {
    @Test func abandonedCacheCleanupKeepsLiveProcessAndUnrelatedPaths() throws {
        let location = root()
        defer { try? FileManager.default.removeItem(at: location) }
        let pid = ProcessInfo.processInfo.processIdentifier
        let live = location.appendingPathComponent("Process-\(pid)")
        let abandoned = location.appendingPathComponent("Process-2147483647")
        let unrelated = location.appendingPathComponent("user-work")
        for url in [live, abandoned, unrelated] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data([13, 25]).write(to: url.appendingPathComponent("sentinel"))
        }
        let linked = location.appendingPathComponent("Process-2147483646")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: unrelated)
        HistoryCacheDirectory.removeAbandonedProcessDirectories(in: location, currentPID: pid)
        #expect(FileManager.default.fileExists(atPath: live.appendingPathComponent("sentinel").path))
        #expect(FileManager.default.fileExists(atPath: unrelated.appendingPathComponent("sentinel").path))
        #expect(FileManager.default.fileExists(atPath: linked.path))
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
    }

    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ArtFlexUndoTests-" + UUID().uuidString)
    }

    private func snapshot(size: Int = 1_024, value: UInt8 = 91) -> LayerHistorySnapshot {
        LayerHistorySnapshot(layerID: LayerID(), resourceKind: .mask,
            texture: .init(width: size, height: 1, bytesPerRow: size,
                           pixelData: Data(repeating: value, count: size)), originX: 3, originY: 5)
    }

    @Test func chunkedRoundTripReleasesPixelsOnlyAfterVerifiedWrite() throws {
        let location = root()
        defer { try? FileManager.default.removeItem(at: location) }
        let cache = HistoryDiskCache(rootURL: location)
        var content = snapshot(size: 4 * 1024 * 1024 + 113)
        content.resourceKind = .content
        content.texture.pixelData[4 * 1024 * 1024] = 243
        let source = [content, snapshot(value: 175)]
        let payload = HistoryPixelPayload(source, cache: cache)
        #expect(payload.residentBytes == source.reduce(0) { $0 + $1.approxByteCount })
        #expect(payload.spill())
        // An immediate read is valid whether the worker is still writing or has completed.
        #expect(try payload.read() == source)
        cache.waitForPendingWrites()
        #expect(payload.residentBytes == 0)
        #expect(payload.diskBytes > 0)
        #expect(payload.diskBytes < payload.rawByteCount)
        #expect(try payload.read() == source)
        payload.discard()
        cache.waitForPendingWrites()
        #expect(cache.reservedByteCount == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.directoryURL.path).isEmpty)
    }

    @Test func failedWriteKeepsReadableMemoryCopy() throws {
        let location = root()
        try Data([1]).write(to: location)
        defer { try? FileManager.default.removeItem(at: location) }
        let cache = HistoryDiskCache(rootURL: location)
        let source = [snapshot()]
        let payload = HistoryPixelPayload(source, cache: cache)
        #expect(payload.spill())
        cache.waitForPendingWrites()
        #expect(payload.residentBytes == 1_024)
        #expect(payload.diskBytes == 0)
        #expect(cache.reservedByteCount == 0)
        #expect(cache.lastFailure != nil)
        #expect(try payload.read() == source)
        #expect(!payload.spill())
    }

    @Test func diskBudgetRejectsAdditionalEntryWithoutDiscardingIt() throws {
        let location = root()
        defer { try? FileManager.default.removeItem(at: location) }
        let cache = HistoryDiskCache(rootURL: location, maximumBytes: 1_024)
        let first = HistoryPixelPayload([snapshot()], cache: cache)
        let secondSource = [snapshot(value: 17)]
        let second = HistoryPixelPayload(secondSource, cache: cache)
        #expect(first.spill())
        #expect(!second.spill())
        cache.waitForPendingWrites()
        #expect(cache.reservedByteCount == 1_024)
        #expect(second.residentBytes == 1_024)
        #expect(try second.read() == secondSource)
        first.discard()
        cache.waitForPendingWrites()
        #expect(second.spill())
        cache.waitForPendingWrites()
        #expect(second.residentBytes == 0)
    }

    @Test func corruptAndTruncatedBytesAreRejected() throws {
        let location = root()
        defer { try? FileManager.default.removeItem(at: location) }
        let cache = HistoryDiskCache(rootURL: location)
        let payload = HistoryPixelPayload([snapshot()], cache: cache)
        #expect(payload.spill())
        cache.waitForPendingWrites()
        let url = try #require(FileManager.default.contentsOfDirectory(at: cache.directoryURL,
            includingPropertiesForKeys: nil).first)
        let original = try Data(contentsOf: url)
        var corrupt = original
        corrupt[0] ^= 0xff
        try corrupt.write(to: url)
        #expect(throws: HistoryDiskError.self) { try payload.read() }
        try original.dropLast().write(to: url)
        #expect(throws: HistoryDiskError.self) { try payload.read() }
        try original.write(to: url)
        #expect(try payload.read().first?.texture.pixelData == Data(repeating: 91, count: 1_024))
    }

    @Test func discardedQueuedEntriesDoNotReappearAfterWriterFinishes() throws {
        let location = root()
        defer { try? FileManager.default.removeItem(at: location) }
        let cache = HistoryDiskCache(rootURL: location)
        let payloads = (0..<24).map { _ in HistoryPixelPayload([snapshot(size: 64 * 1_024)], cache: cache) }
        for payload in payloads { #expect(payload.spill()) }
        for payload in payloads { payload.discard() }
        cache.waitForPendingWrites()
        #expect(cache.reservedByteCount == 0)
        #expect(payloads.allSatisfy { $0.residentBytes == 0 && $0.diskBytes == 0 })
        if FileManager.default.fileExists(atPath: cache.directoryURL.path) {
            #expect(try FileManager.default.contentsOfDirectory(atPath: cache.directoryURL.path).isEmpty)
        }
    }
}

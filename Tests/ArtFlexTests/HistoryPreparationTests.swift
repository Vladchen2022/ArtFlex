import Foundation
import Metal
import Testing
@testable import ArtFlex

struct HistoryPreparationTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ArtFlex-HistoryPrepare-\(UUID().uuidString)")
    }

    private func snapshot(value: UInt8, count: Int = 4096) -> LayerHistorySnapshot {
        .init(layerID: LayerID(), resourceKind: .mask,
              texture: .init(width: count, height: 1, bytesPerRow: count,
                             pixelData: Data(repeating: value, count: count), encoding: .grayscale8))
    }

    @Test @MainActor func coldReadChecksAndDecodesOnceOffMainAndReusesCompletedResult() async throws {
        let location = root()
        defer { try? FileManager.default.removeItem(at: location) }
        let cache = HistoryDiskCache(rootURL: location)
        let expected = [snapshot(value: 37)]
        let payload = HistoryPixelPayload(expected, cache: cache)
        #expect(payload.spill())
        cache.waitForPendingWrites()
        #expect(!payload.hasResidentSnapshots)
        let read = HistoryPreparedPixelRead(payload: payload)
        #expect(try await read.value() == expected)
        #expect(try await read.value() == expected)
        #expect(try read.readyResult?.get() == expected)
        #expect(payload.debugDiskReadCount == 1)
        #expect(!payload.debugReadOnMainThread)
    }

    @Test func readAheadRetainsAtMostTwoEntriesAndRespectsBytes() async throws {
        let location = root()
        defer { try? FileManager.default.removeItem(at: location) }
        let disk = HistoryDiskCache(rootURL: location)
        let payloads = (1...3).map { HistoryPixelPayload([snapshot(value: UInt8($0))], cache: disk) }
        for payload in payloads { #expect(payload.spill()) }
        disk.waitForPendingWrites()
        let ahead = HistoryReadAheadCache(maximumBytes: 8192)
        ahead.update(candidates: payloads)
        #expect(ahead.reservedByteCount == 8192)
        #expect(ahead.preparedRead(for: payloads[2]) == nil)
        let first = try #require(ahead.preparedRead(for: payloads[0]))
        _ = try await first.value()
        ahead.update(candidates: payloads)
        #expect(ahead.preparedRead(for: payloads[0]) === first)
        #expect(payloads[0].debugDiskReadCount == 1)
        ahead.clear()
        #expect(ahead.reservedByteCount == 0)
        let tooSmall = HistoryReadAheadCache(maximumBytes: 4095)
        tooSmall.update(candidates: payloads)
        #expect(tooSmall.reservedByteCount == 0)
    }

    @Test @MainActor func preparedMissRestoresPixelsButChangedHistoryRejectsStalePublication() async throws {
        let f = try Fixture(root: root())
        defer { try? FileManager.default.removeItem(at: f.root) }
        let firstID = f.history.currentStateID
        try f.history.captureCheckpoint()
        f.store.updateDocument { $0.metadata.name = "state one" }
        let oneID = f.history.currentStateID
        try f.history.captureCheckpoint()
        f.store.updateDocument { $0.metadata.name = "state two" }
        let twoID = f.history.currentStateID
        #expect(firstID != oneID && oneID != twoID)
        f.disk.waitForPendingWrites()
        #expect(try f.history.undo())
        #expect(f.history.currentStateID == oneID)
        let preparation = try #require(f.history.makePreparation(direction: .undo))
        #expect(preparation.requiresBackgroundPreparation)
        let ready = try await preparation.prepare()
        #expect(try f.history.applyPrepared(ready))
        #expect(f.history.currentStateID == firstID)
        #expect(f.store.state.document.metadata.name == f.initialName)
        #expect(try f.history.redo())
        #expect(f.history.currentStateID == oneID)
        let stale = try await #require(f.history.makePreparation(direction: .redo)).prepare()
        let count = f.history.visibleTimeline.currentAppliedEntryCount
        try f.history.captureCheckpoint(captureMode: .metadataOnly)
        f.store.updateDocument { $0.metadata.name = "branch" }
        #expect(throws: HistoryDiskError.self) { try f.history.applyPrepared(stale) }
        #expect(f.store.state.document.metadata.name == "branch")
        #expect(f.history.visibleTimeline.currentAppliedEntryCount == count + 1)
    }

    @Test @MainActor func corruptedColdEntryFailsBeforeChangingCanvasOrStacks() async throws {
        let f = try Fixture(root: root())
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.history.captureCheckpoint()
        f.store.updateDocument { $0.metadata.name = "one" }
        try f.history.captureCheckpoint()
        f.store.updateDocument { $0.metadata.name = "two" }
        f.disk.waitForPendingWrites()
        #expect(try f.history.undo())
        let preparation = try #require(f.history.makePreparation(direction: .undo))
        #expect(preparation.requiresBackgroundPreparation)
        let files = try FileManager.default.contentsOfDirectory(at: f.disk.directoryURL, includingPropertiesForKeys: nil)
        for file in files { try Data([255]).write(to: file) }
        let id = f.history.currentStateID
        let timeline = f.history.visibleTimeline
        do {
            _ = try await preparation.prepare()
            Issue.record("Corrupt cold bytes must not prepare")
        } catch { }
        #expect(f.history.currentStateID == id)
        #expect(f.history.visibleTimeline == timeline)
        #expect(f.store.state.document.metadata.name == "one")
    }

    @Test @MainActor func longNavigationValidatesAllColdSourcesBeforeFirstPublicationAndAllowsRetry() async throws {
        let f = try Fixture(root: root())
        defer { try? FileManager.default.removeItem(at: f.root) }
        for index in 0..<4 {
            try f.history.captureCheckpoint()
            f.store.updateDocument { $0.metadata.name = "state \(index)" }
            f.disk.waitForPendingWrites()
        }
        let plan = try #require(f.history.visibleTimeline.navigationPlan(toAppliedEntryCount: 0))
        let validation = try f.history.makeNavigationValidation(plan)
        let files = try FileManager.default.contentsOfDirectory(at: f.disk.directoryURL, includingPropertiesForKeys: nil)
        let file = try #require(files.last)
        let bytes = try Data(contentsOf: file)
        try Data([0]).write(to: file)
        let stateID = f.history.currentStateID
        let timeline = f.history.visibleTimeline
        do {
            try await validation.validate()
            Issue.record("A broken cold source must reject the entire jump before publication")
        } catch { }
        #expect(f.history.currentStateID == stateID)
        #expect(f.history.visibleTimeline == timeline)
        #expect(f.store.state.document.metadata.name == "state 3")
        try bytes.write(to: file)
        try await validation.validate()
        #expect(f.history.currentStateID == stateID)
    }

    @Test @MainActor func exactRestoreRecoversStateIdentityAndResetCreatesNewIdentity() throws {
        let f = try Fixture(root: root())
        defer { try? FileManager.default.removeItem(at: f.root) }
        let entry = try f.history.captureCurrentEntry()
        #expect(entry.stateID == f.history.currentStateID)
        try f.history.captureCheckpoint(captureMode: .metadataOnly)
        f.store.updateDocument { $0.metadata.name = "edited" }
        try f.history.restoreExact(entry: entry)
        #expect(f.history.currentStateID == entry.stateID)
        f.history.resetHistory()
        #expect(f.history.currentStateID != entry.stateID)
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let store: WorkspaceStore
        let surfaces: StageOneLayerSurfaceStore
        let disk: HistoryDiskCache
        let history: HistoryController
        let initialName: String
        init(root: URL) throws {
            self.root = root
            let metal = try #require(MetalDeviceContext())
            var workspace = WorkspaceState.stageOneDefault
            workspace.document.canvasSize = .init(width: 32, height: 32)
            initialName = workspace.document.metadata.name
            store = WorkspaceStore(state: workspace)
            surfaces = StageOneLayerSurfaceStore()
            surfaces.prepareTextures(for: workspace.document, metal: metal)
            disk = HistoryDiskCache(rootURL: root)
            history = HistoryController(workspaceStore: store, layerSurfaceStore: surfaces,
                serializer: .init(metalContext: metal), metalContext: metal,
                maxResidentBytes: 8192, diskCache: disk, hotEntryCount: 1)
        }
    }
}

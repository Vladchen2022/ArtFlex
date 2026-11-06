import Foundation
import Testing
@testable import ArtFlex

struct EditableAssetStoreTests {
    private func bytes(seed: UInt64 = 7, count: Int = 512 * 1024) -> Data {
        var value = seed
        return Data((0..<count).map { _ in
            value ^= value << 13; value ^= value >> 7; value ^= value << 17
            return UInt8(truncatingIfNeeded: value)
        })
    }
    private func store(limit: Int = 8 * 1024 * 1024) -> EditableAssetStore {
        EditableAssetStore(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), maximumBytes: limit)
    }

    @Test func sharedImmutableReferenceSurvivesCopiesAndReleasesAfterLastOwner() throws {
        let store = store(), data = bytes()
        var a: EditableSourceAsset? = try .init(data: data, store: store)
        var b: EditableSourceAsset? = try .init(data: data, store: store)
        let file = try #require(a?.cachedFileURL)
        #expect(a?.residentByteCount == 0 && b?.cachedFileURL == file)
        #expect(store.reservedByteCount < data.count * 2)
        a = nil
        #expect(try b?.decoded() == data)
        b = nil
        store.waitForPendingDeletion()
        #expect(store.reservedByteCount == 0)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func standaloneEncodingRemainsSelfContainedAndCorruptionIsRejected() throws {
        let store = store(), data = bytes()
        let asset = try EditableSourceAsset(data: data, store: store)
        let encoded = try JSONEncoder().encode(asset)
        let decoded = try JSONDecoder().decode(EditableSourceAsset.self, from: encoded)
        #expect(decoded.isFileBacked && decoded.residentByteCount == 0)
        #expect(try decoded.decoded() == data)
        let file = try #require(asset.cachedFileURL)
        var corrupted = try Data(contentsOf: file)
        corrupted[corrupted.count / 2] ^= 1
        try corrupted.write(to: file)
        #expect(throws: (any Error).self) { try asset.validateReadable() }
        #expect(throws: (any Error).self) { try JSONEncoder().encode(asset) }
        #expect(try decoded.decoded() == data)
    }

    @Test func fullOrUnwritableCacheDoesNotEvictExistingAssets() throws {
        let store = store(limit: 600 * 1024), first = bytes()
        let asset = try EditableSourceAsset(data: first, store: store)
        #expect(throws: (any Error).self) { try EditableSourceAsset(data: bytes(seed: 9), store: store) }
        #expect(try asset.decoded() == first)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: root)
        let broken = EditableAssetStore(rootURL: root)
        #expect(throws: (any Error).self) { try EditableSourceAsset(data: first, store: broken) }
        #expect(broken.reservedByteCount == 0)
    }

    @Test @MainActor func largeMetadataAssetsDoNotEvictHistoryAndBrokenAssetCannotBeRestored() async throws {
        var state = WorkspaceState.stageOneDefault
        state.document.canvasSize = .init(width: 16, height: 16)
        let bootstrap = try AppBootstrap(workspaceStore: WorkspaceStore(state: state))
        let history = HistoryController(workspaceStore: bootstrap.workspaceStore, layerSurfaceStore: bootstrap.layerSurfaceStore,
            serializer: bootstrap.textureSerializer, metalContext: bootstrap.metalContext, maxResidentBytes: 1024)
        let store = store()
        for index in 0..<5 {
            try history.captureCheckpoint(captureMode: .metadataOnly)
            let asset = try EditableSourceAsset(data: bytes(seed: UInt64(index + 3)), store: store)
            bootstrap.workspaceStore.updateDocument { document in
                document.storedBranches = [.init(id: UUID(), name: "方案 \(index)", savedAt: Date(), project: asset,
                    canvasSize: .init(width: 16, height: 16), layerCount: 1)]
            }
        }
        #expect(history.visibleTimeline.appliedEntries.count == 5)
        #expect(history.residentByteCount == 0)
        let target = try #require(history.latestUndoWorkspaceForAudit?.document.storedBranches?.first?.project.cachedFileURL)
        try Data([1]).write(to: target)
        let before = bootstrap.workspaceStore.state
        let steps = history.visibleTimeline
        let request = try #require(history.makePreparation(direction: .undo))
        #expect(request.requiresBackgroundPreparation)
        await #expect(throws: (any Error).self) { try await request.prepare() }
        #expect(bootstrap.workspaceStore.state == before)
        #expect(history.visibleTimeline == steps)
    }
}

import Foundation
import Testing
@testable import ArtFlex

struct PersistenceSaveQueueTests {
    @Test
    @MainActor
    func projectSaveUsesSingleBatchTextureSnapshotForAllLayers() throws {
        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal unavailable")
            return
        }

        let bootstrap = try AppBootstrap(
            workspaceStore: WorkspaceStore(),
            metalContext: metalContext,
            layerSurfaceStore: StageOneLayerSurfaceStore()
        )
        let viewModel = WorkspaceViewModel(bootstrap: bootstrap, installsZoomKeyboardMonitor: false)
        viewModel.addLayer()
        viewModel.addLayer()

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtFlexProjectSaveBatch-\(UUID().uuidString)")
            .appendingPathExtension("artflex")
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            PerformanceAuditStore.shared.setRecordingEnabled(false)
        }

        PerformanceAuditStore.shared.reset()
        try bootstrap.persistenceController.saveProject(to: outputURL)
        let audit = PerformanceAuditStore.shared.snapshot()
        let layerCount = viewModel.workspace.document.layers.count

        #expect(audit.durations(for: "LayerTextureSerializer.snapshotBatch(\(layerCount))").count == 1)
        #expect(audit.durations(for: "LayerTextureSerializer.snapshot").isEmpty)
    }

    @Test
    func serialSaveQueueLeavesLatestBrushLibraryOnDiskWhenOlderSaveIsSlow() throws {
        let tempRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtFlexPersistenceSaveQueueTests-\(UUID().uuidString)", isDirectory: true)
        let controller = BrushLibraryPersistenceController(rootDirectoryURL: tempRootURL)
        let queue = PersistenceSaveQueue(label: "ArtFlex.Tests.BrushPersistence")
        let olderSaveStarted = DispatchSemaphore(value: 0)
        let releaseOlderSave = DispatchSemaphore(value: 0)
        let latestSaveFinished = DispatchSemaphore(value: 0)
        let errors = PersistenceSaveQueueErrorBox()

        defer {
            try? FileManager.default.removeItem(at: tempRootURL)
        }

        let olderLibrary = BrushLibraryState(
            presets: [
                BrushPreset(
                    id: "older",
                    name: "旧画笔",
                    brush: .stageOneDefault,
                    isBuiltIn: false,
                    slotIndex: 0
                )
            ],
            selectedPresetID: "older"
        )
        let latestLibrary = BrushLibraryState(
            presets: [
                BrushPreset(
                    id: "latest",
                    name: "新画笔",
                    brush: .stageOneDefault,
                    isBuiltIn: false,
                    slotIndex: 0,
                    colorTag: .blue
                )
            ],
            selectedPresetID: "latest"
        )

        queue.enqueue {
            olderSaveStarted.signal()
            _ = releaseOlderSave.wait(timeout: .now() + 2)
            try controller.saveResources(library: olderLibrary, tipImageLibrary: .empty)
        } onError: { error in
            errors.append(error)
        }

        #expect(olderSaveStarted.wait(timeout: .now() + 2) == .success)

        queue.enqueue {
            defer { latestSaveFinished.signal() }
            try controller.saveResources(library: latestLibrary, tipImageLibrary: .empty)
        } onError: { error in
            errors.append(error)
            latestSaveFinished.signal()
        }

        releaseOlderSave.signal()
        #expect(latestSaveFinished.wait(timeout: .now() + 2) == .success)

        #expect(errors.values.isEmpty)
        #expect(controller.loadResources()?.library == latestLibrary)
    }

    @Test
    func serialSaveQueueLeavesLatestPatternLibraryOnDiskWhenOlderSaveIsSlow() throws {
        let tempRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtFlexPersistenceSaveQueueTests-\(UUID().uuidString)", isDirectory: true)
        let controller = PatternLibraryPersistenceController(rootDirectoryURL: tempRootURL)
        let queue = PersistenceSaveQueue(label: "ArtFlex.Tests.PatternPersistence")
        let olderSaveStarted = DispatchSemaphore(value: 0)
        let releaseOlderSave = DispatchSemaphore(value: 0)
        let latestSaveFinished = DispatchSemaphore(value: 0)
        let errors = PersistenceSaveQueueErrorBox()

        defer {
            try? FileManager.default.removeItem(at: tempRootURL)
        }

        let olderItem = makePatternItem(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "旧图案",
            slotIndex: 0,
            renderPath: "renders/11/older.png"
        )
        var latestItem = makePatternItem(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            name: "新图案",
            slotIndex: 2,
            renderPath: "renders/22/latest.png"
        )
        latestItem.colorTag = .green

        let olderLibrary = PatternLibraryState(items: [olderItem], selectedItemID: olderItem.id)
        let latestLibrary = PatternLibraryState(items: [latestItem], selectedItemID: latestItem.id)

        queue.enqueue {
            olderSaveStarted.signal()
            _ = releaseOlderSave.wait(timeout: .now() + 2)
            try createManagedAssets(for: olderLibrary, rootDirectoryURL: tempRootURL)
            try controller.saveLibrary(olderLibrary)
        } onError: { error in
            errors.append(error)
        }

        #expect(olderSaveStarted.wait(timeout: .now() + 2) == .success)

        queue.enqueue {
            defer { latestSaveFinished.signal() }
            try createManagedAssets(for: latestLibrary, rootDirectoryURL: tempRootURL)
            try controller.saveLibrary(latestLibrary)
        } onError: { error in
            errors.append(error)
            latestSaveFinished.signal()
        }

        releaseOlderSave.signal()
        #expect(latestSaveFinished.wait(timeout: .now() + 2) == .success)

        #expect(errors.values.isEmpty)
        #expect(controller.loadLibrary()?.library == latestLibrary)
    }
}

private final class PersistenceSaveQueueErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Error] = []

    func append(_ error: Error) {
        lock.lock()
        storage.append(error)
        lock.unlock()
    }

    var values: [Error] {
        lock.lock()
        let result = storage
        lock.unlock()
        return result
    }
}

private func createManagedAssets(
    for library: PatternLibraryState,
    rootDirectoryURL: URL
) throws {
    let patternRoot = rootDirectoryURL.appendingPathComponent("PatternLibrary", isDirectory: true)
    for item in library.items {
        if case .managedCopy(let relativePath) = item.renderAssetLocation {
            try createManagedAsset(relativePath, under: patternRoot)
        }
        if case .managedCopy(let relativePath) = item.thumbnailLocation {
            try createManagedAsset(relativePath, under: patternRoot)
        }
    }
}

private func createManagedAsset(_ relativePath: String, under root: URL) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data([1]).write(to: url, options: .atomic)
}

private func makePatternItem(
    id: UUID,
    name: String,
    slotIndex: Int?,
    renderPath: String
) -> PatternLibraryItem {
    PatternLibraryItem(
        id: id,
        displayName: name,
        slotIndex: slotIndex,
        importRecipe: .init(),
        originalFilename: "\(name).png",
        sourcePixelWidth: 2,
        sourcePixelHeight: 2,
        renderAssetLocation: .managedCopy(relativePath: renderPath),
        thumbnailLocation: .managedCopy(relativePath: renderPath.replacingOccurrences(of: "renders", with: "thumbnails"))
    )
}

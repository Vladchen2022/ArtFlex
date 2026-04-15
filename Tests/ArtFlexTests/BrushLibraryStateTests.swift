import Foundation
import Testing
@testable import ArtFlex

struct BrushLibraryStateTests {
    @Test
    func savingCurrentPresetReusesExistingMatchingCustomBrush() {
        var brush = BrushSettings.stageOneDefault
        brush.size = 23
        brush.opacity = 0.61
        brush.scatterAmount = 0.19

        let existingPreset = BrushPreset(
            id: "existing",
            name: "笔刷 1",
            brush: brush,
            isBuiltIn: false,
            slotIndex: 4
        )
        var library = BrushLibraryState(
            presets: [existingPreset],
            selectedPresetID: nil
        )

        let savedPreset = library.saveCurrentPreset(brush: brush)

        #expect(savedPreset.id == existingPreset.id)
        #expect(library.presets.count == 1)
        #expect(library.selectedPresetID == existingPreset.id)
    }

    @Test
    func removingLikelyAutoSavedDuplicatePresetsKeepsIntentionalVariantsAndRemapsSelection() {
        var duplicateBrush = BrushSettings.stageOneDefault
        duplicateBrush.size = 31
        duplicateBrush.opacity = 0.42

        var uniqueBrush = BrushSettings.stageOneDefault
        uniqueBrush.size = 48
        uniqueBrush.opacity = 0.77

        let keptAutoPreset = BrushPreset(
            id: "keep-auto",
            name: "笔刷 1",
            brush: duplicateBrush,
            isBuiltIn: false,
            slotIndex: 0
        )
        let removedAutoPreset = BrushPreset(
            id: "remove-auto",
            name: "笔刷 2",
            brush: duplicateBrush,
            isBuiltIn: false,
            slotIndex: 1
        )
        let renamedPreset = BrushPreset(
            id: "renamed",
            name: "细铅笔",
            brush: duplicateBrush,
            isBuiltIn: false,
            slotIndex: 2
        )
        let taggedPreset = BrushPreset(
            id: "tagged",
            name: "笔刷 3",
            brush: duplicateBrush,
            isBuiltIn: false,
            slotIndex: 3,
            colorTag: .blue
        )
        let uniquePreset = BrushPreset(
            id: "unique",
            name: "笔刷 4",
            brush: uniqueBrush,
            isBuiltIn: false,
            slotIndex: 4
        )

        let library = BrushLibraryState(
            presets: [
                keptAutoPreset,
                removedAutoPreset,
                renamedPreset,
                taggedPreset,
                uniquePreset
            ],
            selectedPresetID: removedAutoPreset.id
        )

        let cleaned = library.removingLikelyAutoSavedDuplicatePresets()

        #expect(cleaned.presets.map(\.id) == [
            keptAutoPreset.id,
            renamedPreset.id,
            taggedPreset.id,
            uniquePreset.id
        ])
        #expect(cleaned.selectedPresetID == keptAutoPreset.id)
    }

    @Test
    @MainActor
    func workspaceViewModelLaunchSanitizesAndPersistsLikelyAutoSavedBrushDuplicates() async throws {
        let tempRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtFlexBrushLibraryStateTests-\(UUID().uuidString)", isDirectory: true)
        let redirectedFileManager = RedirectedApplicationSupportFileManager(
            applicationSupportRootURL: tempRootURL
        )
        let persistenceController = BrushLibraryPersistenceController(
            fileManager: redirectedFileManager
        )

        defer {
            try? FileManager.default.removeItem(at: tempRootURL)
        }

        var duplicateBrush = BrushSettings.stageOneDefault
        duplicateBrush.size = 17
        duplicateBrush.opacity = 0.38

        let keptAutoPreset = BrushPreset(
            id: "keep-auto",
            name: "笔刷 1",
            brush: duplicateBrush,
            isBuiltIn: false,
            slotIndex: 0
        )
        let removedAutoPreset = BrushPreset(
            id: "remove-auto",
            name: "笔刷 2",
            brush: duplicateBrush,
            isBuiltIn: false,
            slotIndex: 1
        )
        let renamedPreset = BrushPreset(
            id: "renamed",
            name: "我的排线",
            brush: duplicateBrush,
            isBuiltIn: false,
            slotIndex: 2
        )
        let dirtyLibrary = BrushLibraryState(
            presets: [keptAutoPreset, removedAutoPreset, renamedPreset],
            selectedPresetID: removedAutoPreset.id
        )

        try persistenceController.saveResources(
            library: dirtyLibrary,
            tipImageLibrary: .empty
        )

        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal is required to validate startup brush library sanitization.")
            return
        }

        let bootstrap = try AppBootstrap(
            workspaceStore: WorkspaceStore(),
            metalContext: metalContext,
            layerSurfaceStore: StageOneLayerSurfaceStore(),
            brushLibraryPersistenceController: persistenceController
        )
        let viewModel = WorkspaceViewModel(
            bootstrap: bootstrap,
            installsZoomKeyboardMonitor: false,
            preparesInitialTextures: false
        )

        let expectedPresetIDs = [keptAutoPreset.id, renamedPreset.id]
        #expect(viewModel.workspace.brushLibrary.presets.map(\.id) == expectedPresetIDs)
        #expect(viewModel.workspace.brushLibrary.selectedPresetID == keptAutoPreset.id)

        var persistedLibrary = persistenceController.loadResources()?.library
        for _ in 0..<20 where persistedLibrary?.presets.map(\.id) != expectedPresetIDs {
            try await Task.sleep(for: .milliseconds(50))
            persistedLibrary = persistenceController.loadResources()?.library
        }

        let cleanedPersistedLibrary = try #require(persistedLibrary)
        #expect(cleanedPersistedLibrary.presets.map(\.id) == expectedPresetIDs)
        #expect(cleanedPersistedLibrary.selectedPresetID == keptAutoPreset.id)
    }
}

private final class RedirectedApplicationSupportFileManager: FileManager {
    private let applicationSupportRootURL: URL

    init(applicationSupportRootURL: URL) {
        self.applicationSupportRootURL = applicationSupportRootURL
        super.init()
    }

    override func urls(
        for directory: SearchPathDirectory,
        in domainMask: SearchPathDomainMask
    ) -> [URL] {
        guard directory == .applicationSupportDirectory,
              domainMask == .userDomainMask else {
            return super.urls(for: directory, in: domainMask)
        }
        return [applicationSupportRootURL]
    }
}

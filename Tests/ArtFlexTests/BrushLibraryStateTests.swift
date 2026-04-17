import Foundation
import Testing
@testable import ArtFlex

struct BrushLibraryStateTests {
    @Test
    func recentPresetUsageTracksLastFourAppliedBrushes() {
        let ids = (1...5).map { "preset-\($0)" }
        let presets = ids.enumerated().map { index, id in
            BrushPreset(
                id: id,
                name: "笔刷 \(index + 1)",
                brush: .stageOneDefault,
                isBuiltIn: false,
                slotIndex: index + 4
            )
        }
        var library = BrushLibraryState(
            presets: presets,
            selectedPresetID: nil
        )

        library.notePresetUsed(ids[1])
        library.notePresetUsed(ids[3])
        library.notePresetUsed(ids[0])
        library.notePresetUsed(ids[4])
        library.notePresetUsed(ids[2])

        #expect(library.recentPresetIDs == [ids[2], ids[4], ids[0], ids[3]])
        #expect(library.recentPresets().map(\.id) == [ids[2], ids[4], ids[0], ids[3]])
    }

    @Test
    func quickAccessShortcutSlotsDoNotEnterRecentPresetUsageRow() {
        let shortcutPresetIDs = (1...4).map { "shortcut-\($0)" }
        let libraryPresetIDs = (1...2).map { "library-\($0)" }
        let presets =
            shortcutPresetIDs.enumerated().map { index, id in
                BrushPreset(
                    id: id,
                    name: "快捷笔刷 \(index + 1)",
                    brush: .stageOneDefault,
                    isBuiltIn: false,
                    slotIndex: index
                )
            } +
            libraryPresetIDs.enumerated().map { index, id in
                BrushPreset(
                    id: id,
                    name: "库笔刷 \(index + 1)",
                    brush: .stageOneDefault,
                    isBuiltIn: false,
                    slotIndex: index + 4
                )
            }

        var library = BrushLibraryState(
            presets: presets,
            selectedPresetID: nil
        )

        library.notePresetUsed(shortcutPresetIDs[0])
        library.notePresetUsed(shortcutPresetIDs[2])
        library.notePresetUsed(libraryPresetIDs[0])
        library.notePresetUsed(shortcutPresetIDs[1])
        library.notePresetUsed(libraryPresetIDs[1])

        #expect(library.recentPresetIDs == [libraryPresetIDs[1], libraryPresetIDs[0]])
        #expect(library.recentPresets().map(\.id) == [libraryPresetIDs[1], libraryPresetIDs[0]])
    }

    @Test
    func movingRecentPresetIntoQuickAccessRowRemovesItFromRecentUsageRow() {
        let quickPresetIDs = (1...4).map { "quick-\($0)" }
        let recentEligiblePresetID = "library-1"
        let presets =
            quickPresetIDs.enumerated().map { index, id in
                BrushPreset(
                    id: id,
                    name: "快捷笔刷 \(index + 1)",
                    brush: .stageOneDefault,
                    isBuiltIn: false,
                    slotIndex: index
                )
            } + [
                BrushPreset(
                    id: recentEligiblePresetID,
                    name: "库笔刷 1",
                    brush: .stageOneDefault,
                    isBuiltIn: false,
                    slotIndex: 4
                )
            ]

        var library = BrushLibraryState(
            presets: presets,
            selectedPresetID: nil
        )

        library.notePresetUsed(recentEligiblePresetID)
        #expect(library.recentPresetIDs == [recentEligiblePresetID])

        let didMovePreset = library.movePreset(id: recentEligiblePresetID, toSlot: 1)
        #expect(didMovePreset)
        #expect(library.recentPresetIDs.isEmpty)
        #expect(library.recentPresets().isEmpty)
    }

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

    @Test
    @MainActor
    func workspaceViewModelLaunchDefaultsToFirstBrushPresetInLibrary() async throws {
        let tempRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtFlexBrushLibraryDefaultPresetTests-\(UUID().uuidString)", isDirectory: true)
        let redirectedFileManager = RedirectedApplicationSupportFileManager(
            applicationSupportRootURL: tempRootURL
        )
        let persistenceController = BrushLibraryPersistenceController(
            fileManager: redirectedFileManager
        )

        defer {
            try? FileManager.default.removeItem(at: tempRootURL)
        }

        var firstBrush = BrushSettings.stageOneDefault
        firstBrush.size = 21
        firstBrush.opacity = 0.35

        var secondBrush = BrushSettings.stageOneDefault
        secondBrush.size = 82
        secondBrush.opacity = 0.91

        let firstPreset = BrushPreset(
            id: "first-brush",
            name: "第一支笔",
            brush: firstBrush,
            isBuiltIn: false,
            slotIndex: 0
        )
        let secondPreset = BrushPreset(
            id: "second-brush",
            name: "第二支笔",
            brush: secondBrush,
            isBuiltIn: false,
            slotIndex: 1
        )

        var workspaceState = WorkspaceState.stageOneDefault
        workspaceState.brushLibrary = BrushLibraryState(
            presets: [secondPreset, firstPreset],
            selectedPresetID: secondPreset.id
        )
        workspaceState.toolSession.brush = secondBrush

        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal is required to validate startup default brush preset selection.")
            return
        }

        let bootstrap = try AppBootstrap(
            workspaceStore: WorkspaceStore(state: workspaceState),
            metalContext: metalContext,
            layerSurfaceStore: StageOneLayerSurfaceStore(),
            brushLibraryPersistenceController: persistenceController
        )
        let viewModel = WorkspaceViewModel(
            bootstrap: bootstrap,
            installsZoomKeyboardMonitor: false,
            preparesInitialTextures: false
        )

        #expect(viewModel.workspace.brushLibrary.selectedPresetID == firstPreset.id)
        #expect(viewModel.workspace.toolSession.brush == firstBrush)

        var persistedLibrary = persistenceController.loadResources()?.library
        for _ in 0..<20 where persistedLibrary?.selectedPresetID != firstPreset.id {
            try await Task.sleep(for: .milliseconds(50))
            persistedLibrary = persistenceController.loadResources()?.library
        }

        #expect(persistedLibrary?.selectedPresetID == firstPreset.id)
    }

    @Test
    func launchDefaultPresetPrefersFirstVisibleShortcutSlotOverArrayOrder() {
        let firstPreset = BrushPreset(
            id: "slot-zero",
            name: "第一支笔",
            brush: .stageOneDefault,
            isBuiltIn: false,
            slotIndex: 0
        )
        let fourthPreset = BrushPreset(
            id: "slot-three",
            name: "第四支笔",
            brush: .stageOneDefault,
            isBuiltIn: false,
            slotIndex: 3
        )
        let library = BrushLibraryState(
            presets: [fourthPreset, firstPreset],
            selectedPresetID: fourthPreset.id
        )

        #expect(library.launchDefaultPreset()?.id == firstPreset.id)
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

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
    @MainActor
    func workspaceViewModelRelaunchKeepsInstalledPressureGrainCrayonBuiltIn() async throws {
        let tempRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtFlexPressureGrainCrayonTests-\(UUID().uuidString)", isDirectory: true)
        let redirectedFileManager = RedirectedApplicationSupportFileManager(
            applicationSupportRootURL: tempRootURL
        )
        let persistenceController = BrushLibraryPersistenceController(
            fileManager: redirectedFileManager
        )

        defer {
            try? FileManager.default.removeItem(at: tempRootURL)
        }

        var sourceBrush = BrushSettings.stageOneDefault
        sourceBrush.tipShape = .customRound
        sourceBrush.customTipSourceSemantic = .importedImage
        sourceBrush.customTipAssetID = BrushPreset.pressureGrainCrayonSourceTipAssetID
        sourceBrush.customTipEnvelopeMaskData = Data(repeating: 255, count: 256 * 256)
        sourceBrush.compoundBrush.enabled = true
        sourceBrush.compoundBrush.secondary.tipShape = .customRound
        sourceBrush.compoundBrush.secondary.customTipMaskData = Data(repeating: 127, count: 256 * 256)

        let sourcePreset = BrushPreset(
            id: "source-fourth-brush",
            name: "第四支笔",
            brush: sourceBrush,
            isBuiltIn: false,
            slotIndex: 3
        )
        try persistenceController.saveResources(
            library: BrushLibraryState(
                presets: [sourcePreset],
                selectedPresetID: sourcePreset.id
            ),
            tipImageLibrary: .empty
        )

        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal is required to validate pressure crayon startup migration.")
            return
        }

        let firstBootstrap = try AppBootstrap(
            workspaceStore: WorkspaceStore(),
            metalContext: metalContext,
            layerSurfaceStore: StageOneLayerSurfaceStore(),
            brushLibraryPersistenceController: persistenceController
        )
        let firstViewModel = WorkspaceViewModel(
            bootstrap: firstBootstrap,
            installsZoomKeyboardMonitor: false,
            preparesInitialTextures: false
        )
        #expect(
            firstViewModel.workspace.brushLibrary
                .preset(id: BrushPreset.pressureGrainCrayonPresetID)?.isBuiltIn == true
        )

        var persistedCrayon = persistenceController.loadResources()?.library
            .preset(id: BrushPreset.pressureGrainCrayonPresetID)
        for _ in 0..<20 where persistedCrayon?.isBuiltIn != true {
            try await Task.sleep(for: .milliseconds(50))
            persistedCrayon = persistenceController.loadResources()?.library
                .preset(id: BrushPreset.pressureGrainCrayonPresetID)
        }
        #expect(persistedCrayon?.isBuiltIn == true)

        let secondBootstrap = try AppBootstrap(
            workspaceStore: WorkspaceStore(),
            metalContext: metalContext,
            layerSurfaceStore: StageOneLayerSurfaceStore(),
            brushLibraryPersistenceController: persistenceController
        )
        let secondViewModel = WorkspaceViewModel(
            bootstrap: secondBootstrap,
            installsZoomKeyboardMonitor: false,
            preparesInitialTextures: false
        )
        let relaunchedCrayon = secondViewModel.workspace.brushLibrary
            .preset(id: BrushPreset.pressureGrainCrayonPresetID)

        #expect(relaunchedCrayon?.isBuiltIn == true)
        #expect(relaunchedCrayon?.brush.buildMode == .buildUp)
        #expect(
            secondViewModel.workspace.brushLibrary.selectedPresetID
                == BrushPreset.pressureGrainCrayonPresetID
        )
        #expect(secondViewModel.workspace.toolSession.brush.buildMode == .buildUp)
        #expect(
            secondViewModel.workspace.brushLibrary.presets
                .filter { $0.id == BrushPreset.pressureGrainCrayonPresetID }.count == 1
        )
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

    @Test
    func pressureGrainCrayonInstallsOnceFromKnownFourthBrushTip() throws {
        var sourceBrush = BrushSettings.stageOneDefault
        sourceBrush.tipShape = .customRound
        sourceBrush.customTipSourceSemantic = .importedImage
        sourceBrush.customTipAssetID = BrushPreset.pressureGrainCrayonSourceTipAssetID
        sourceBrush.customTipEnvelopeMaskData = Data(repeating: 255, count: 256 * 256)
        sourceBrush.compoundBrush.enabled = true
        sourceBrush.compoundBrush.secondary.tipShape = .customRound
        sourceBrush.compoundBrush.secondary.customTipMaskData = Data(
            (0..<(256 * 256)).map { index in
                index.isMultiple(of: 5) ? UInt8(255) : UInt8(0)
            }
        )

        let sourcePreset = BrushPreset(
            id: "source-fourth-brush",
            name: "第四支笔",
            brush: sourceBrush,
            isBuiltIn: false,
            slotIndex: 3
        )
        let library = BrushLibraryState(
            presets: [sourcePreset],
            selectedPresetID: sourcePreset.id
        )

        let installed = library.installingOrUpdatingPressureGrainCrayonPresetIfPossible()
        let crayon = try #require(installed.preset(id: BrushPreset.pressureGrainCrayonPresetID))

        #expect(installed.presets.count == 2)
        #expect(crayon.name == "颗粒蜡笔")
        #expect(crayon.isBuiltIn)
        #expect(crayon.slotIndex == 0)
        #expect(crayon.brush.size == 29)
        #expect(crayon.brush.spacingPercent == 5)
        #expect(crayon.brush.pressureSizeAmount == 0)
        #expect(crayon.brush.pressureOpacityAmount == 0)
        #expect(crayon.brush.buildMode == .buildUp)
        #expect(crayon.brush.buildUpOpacityCompensationAmount == 1)
        #expect(crayon.brush.compoundBrush.enabled)
        #expect(crayon.brush.compoundBrush.mode == .overlay)
        #expect(crayon.brush.compoundBrush.pressureMix == .balanced)
        #expect(crayon.brush.compoundBrush.globalPressureSizeAmount == 0)
        #expect(crayon.brush.compoundBrush.globalPressureOpacityAmount == 1)
        #expect(abs(crayon.brush.customTipSoftness - (44.0 / 49.0)) < 0.0001)
        #expect(
            abs(crayon.brush.compoundBrush.secondary.relativeSizeRatio - (214.0 / 150.0)) < 0.0001
        )
        #expect(crayon.brush.compoundBrush.secondary.spacingPercent == 75)
        #expect(abs(crayon.brush.compoundBrush.secondary.softness - (44.0 / 49.0)) < 0.0001)
        #expect(crayon.brush.compoundBrush.secondary.followsStrokeDirection == false)
        #expect(crayon.brush.compoundBrush.secondary.pressureSizeAmount == 0)
        #expect(crayon.brush.compoundBrush.secondary.pressureOpacityAmount == 0)
        #expect(crayon.brush.compoundBrush.secondary.tileRandomRotation == 0)
        #expect(
            crayon.brush.compoundBrush.secondary.opacityPressureCurve?.points == [
                .init(x: 0, y: 0),
                .init(x: 1, y: 1)
            ]
        )
        #expect(
            abs(crayon.brush.compoundBrush.secondary.resolvedOpacityFactor(for: 0) - 1) < 0.0001
        )
        #expect(
            abs(crayon.brush.compoundBrush.secondary.resolvedOpacityFactor(for: 0.5) - 1) < 0.0001
        )
        #expect(
            crayon.brush.resolvedOpacityPressureCurveState.points == [
                .init(x: 0, y: 0),
                .init(x: 1, y: 1)
            ]
        )

        let installedAgain = installed.installingOrUpdatingPressureGrainCrayonPresetIfPossible()
        #expect(installedAgain == installed)
    }

    @Test
    func pressureGrainCrayonMigrationReplacesBadVersionInOriginalSlot() throws {
        var sourceBrush = BrushSettings.stageOneDefault
        sourceBrush.tipShape = .customRound
        sourceBrush.customTipSourceSemantic = .importedImage
        sourceBrush.customTipAssetID = BrushPreset.pressureGrainCrayonSourceTipAssetID
        sourceBrush.customTipEnvelopeMaskData = Data(repeating: 255, count: 256 * 256)
        sourceBrush.compoundBrush.secondary.tipShape = .customRound
        sourceBrush.compoundBrush.secondary.customTipMaskData = Data(repeating: 127, count: 256 * 256)

        var badBrush = sourceBrush
        badBrush.spacingPercent = 6
        badBrush.buildMode = .opacityCap
        badBrush.buildUpOpacityCompensationAmount = 0
        badBrush.compoundBrush.globalPressureOpacityAmount = 0
        badBrush.compoundBrush.secondary.tileRandomRotation = 1
        let library = BrushLibraryState(
            presets: [
                BrushPreset(
                    id: "source-fourth-brush",
                    name: "第四支笔",
                    brush: sourceBrush,
                    isBuiltIn: false,
                    slotIndex: 3
                ),
                BrushPreset(
                    id: BrushPreset.pressureGrainCrayonPresetID,
                    name: "旧蜡笔",
                    brush: badBrush,
                    isBuiltIn: true,
                    slotIndex: 9
                )
            ],
            selectedPresetID: BrushPreset.pressureGrainCrayonPresetID
        )

        let migrated = library.installingOrUpdatingPressureGrainCrayonPresetIfPossible()
        let crayon = try #require(migrated.preset(id: BrushPreset.pressureGrainCrayonPresetID))

        #expect(migrated.presets.filter { $0.id == BrushPreset.pressureGrainCrayonPresetID }.count == 1)
        #expect(crayon.slotIndex == 9)
        #expect(crayon.name == "颗粒蜡笔")
        #expect(crayon.brush.spacingPercent == 5)
        #expect(crayon.brush.buildMode == .buildUp)
        #expect(crayon.brush.buildUpOpacityCompensationAmount == 1)
        #expect(crayon.brush.compoundBrush.mode == .overlay)
        #expect(crayon.brush.compoundBrush.globalPressureOpacityAmount == 1)
        #expect(crayon.brush.compoundBrush.secondary.tileRandomRotation == 0)
    }

    @Test
    func pressureGrainCrayonDoesNotInstallFromUnrelatedFourthBrush() {
        let sourcePreset = BrushPreset(
            id: "unrelated-fourth-brush",
            name: "第四支笔",
            brush: .stageOneDefault,
            isBuiltIn: false,
            slotIndex: 3
        )
        let library = BrushLibraryState(
            presets: [sourcePreset],
            selectedPresetID: sourcePreset.id
        )

        #expect(library.installingOrUpdatingPressureGrainCrayonPresetIfPossible() == library)
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

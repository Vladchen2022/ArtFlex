import Foundation
import Testing
@testable import ArtFlex

struct DualTipBrushSettingsTests {
    private final class BrushLibraryPersistenceTestFileManager: FileManager {
        private let rootURL: URL

        init(rootURL: URL) {
            self.rootURL = rootURL
            super.init()
        }

        override func urls(
            for directory: SearchPathDirectory,
            in domainMask: SearchPathDomainMask
        ) -> [URL] {
            [rootURL]
        }
    }

    @Test
    func legacySecondaryTipDescriptorDecodeFallsBackToSafeDefaults() throws {
        let legacyJSON = """
        {
          "tipShape": "softRound"
        }
        """

        let decoded = try JSONDecoder().decode(
            SecondaryTipDescriptor.self,
            from: Data(legacyJSON.utf8)
        )

        #expect(decoded.tipShape == .softRound)
        #expect(decoded.sourceSemantic == .procedural)
        #expect(decoded.tipAssetID == nil)
        #expect(decoded.importedSourceInfo == nil)
        #expect(decoded.customTipMaskData == nil)
        #expect(decoded.customTipSoftness == 0.5)
        #expect(decoded.customTipRoundness == 1)
        #expect(decoded.customTipAngleDegrees == 0)
    }

    @Test
    func legacyBrushSettingsDecodeFallsBackToPhaseZeroDualTipDefaults() throws {
        let legacyJSON = """
        {
          "size": 36,
          "opacity": 0.72,
          "buildMode": "buildUp",
          "tipShape": "softRound"
        }
        """

        let decoded = try JSONDecoder().decode(
            BrushSettings.self,
            from: Data(legacyJSON.utf8)
        )

        #expect(decoded.dualTipEnabled == false)
        #expect(decoded.secondaryTipDescriptor.tipShape == .hardRound)
        #expect(decoded.secondaryTipDescriptor.sourceSemantic == .procedural)
        #expect(decoded.secondaryTipDescriptor.tipAssetID == nil)
        #expect(decoded.secondaryTipDescriptor.importedSourceInfo == nil)
        #expect(decoded.dualTipCombineMode == .multiply)
        #expect(decoded.dualTipStrength == 1)
        #expect(decoded.secondarySizeRatio == 1)
        #expect(decoded.secondarySizeJitter == 0)
        #expect(decoded.secondaryAngleJitterDegrees == 0)
        #expect(decoded.secondaryAngleOffsetDegrees == 0)
        #expect(decoded.secondarySpacingPhase == 0)
        #expect(decoded.secondarySpacingPhaseJitter == 0)
        #expect(decoded.secondaryScatter == 0)
        #expect(decoded.secondaryScatterJitter == 0)
        #expect(decoded.secondaryInvert == false)
        #expect(decoded.customTipSourceSemantic == .procedural)
        #expect(decoded.customTipAssetID == nil)
        #expect(decoded.customTipImportedSourceInfo == nil)
        #expect(decoded.size == 36)
        #expect(decoded.opacity == 0.72)
        #expect(decoded.tipShape == .softRound)
    }

    @Test
    func brushPresetRoundTripPreservesDualTipPhaseZeroFields() throws {
        var brush = BrushSettings.stageOneDefault
        brush.dualTipEnabled = true
        brush.tipShape = .customRound
        brush.customTipSourceSemantic = .customMask
        brush.customTipAssetID = BrushTipImageAssetID(rawValue: "primary-asset")
        brush.customTipMaskData = Data([255, 24, 128, 96])
        brush.secondaryTipDescriptor = SecondaryTipDescriptor(
            tipShape: .customRound,
            sourceSemantic: .importedImage,
            tipAssetID: BrushTipImageAssetID(rawValue: "secondary-asset"),
            customTipMaskData: Data([0, 64, 255, 128]),
            customTipSoftness: 0.36,
            customTipRoundness: 0.71,
            customTipAngleDegrees: 41
        )
        brush.dualTipCombineMode = .subtract
        brush.dualTipStrength = 0.42
        brush.secondarySizeRatio = 1.8
        brush.secondarySizeJitter = 0.36
        brush.secondaryAngleJitterDegrees = 29
        brush.secondaryAngleOffsetDegrees = -35
        brush.secondarySpacingPhase = 0.24
        brush.secondarySpacingPhaseJitter = 0.18
        brush.secondaryScatter = 1.25
        brush.secondaryScatterJitter = 0.31
        brush.secondaryInvert = true

        let preset = BrushPreset(
            id: "dual-tip-phase-zero",
            name: "Dual Tip Phase 0",
            brush: brush,
            isBuiltIn: false,
            slotIndex: 3
        )

        let encoded = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(BrushPreset.self, from: encoded)

        #expect(decoded == preset)
    }

    @Test
    func legacyBrushPresetDecodeFallsBackToPhaseZeroDualTipDefaults() throws {
        let legacyPresetJSON = """
        {
          "id": "legacy",
          "name": "Legacy Brush",
          "brush": {
            "size": 24,
            "opacity": 1,
            "buildMode": "buildUp",
            "tipShape": "hardRound"
          },
          "isBuiltIn": false
        }
        """

        let decoded = try JSONDecoder().decode(
            BrushPreset.self,
            from: Data(legacyPresetJSON.utf8)
        )

        #expect(decoded.brush.dualTipEnabled == false)
        #expect(decoded.brush.secondaryTipDescriptor.tipShape == .hardRound)
        #expect(decoded.brush.secondaryTipDescriptor.sourceSemantic == .procedural)
        #expect(decoded.brush.secondaryTipDescriptor.tipAssetID == nil)
        #expect(decoded.brush.dualTipCombineMode == .multiply)
        #expect(decoded.brush.secondaryInvert == false)
        #expect(decoded.brush.customTipSourceSemantic == .procedural)
        #expect(decoded.brush.customTipAssetID == nil)
    }

    @Test
    func importedImageTipSemanticsRoundTripPreservesSourceMeaning() throws {
        var brush = BrushSettings.stageOneDefault
        brush.tipShape = .customRound
        brush.customTipSourceSemantic = .importedImage
        brush.customTipAssetID = BrushTipImageAssetID(rawValue: "primary-asset")
        brush.customTipImportedSourceInfo = ImportedTipSourceInfo(
            sourceLabel: "Primary Source",
            pixelWidth: 144,
            pixelHeight: 96
        )
        brush.customTipMaskData = Data([255, 16, 96, 200])
        brush.secondaryTipDescriptor = SecondaryTipDescriptor(
            tipShape: .customRound,
            sourceSemantic: .importedImage,
            tipAssetID: BrushTipImageAssetID(rawValue: "secondary-asset"),
            importedSourceInfo: ImportedTipSourceInfo(
                sourceLabel: "Secondary Source",
                pixelWidth: 80,
                pixelHeight: 120
            ),
            customTipMaskData: Data([255, 32, 128, 224]),
            customTipSoftness: 0.44,
            customTipRoundness: 0.73,
            customTipAngleDegrees: 27
        )

        let encoded = try JSONEncoder().encode(brush)
        let decoded = try JSONDecoder().decode(BrushSettings.self, from: encoded)

        #expect(decoded.customTipSourceSemantic == .importedImage)
        #expect(decoded.secondaryTipDescriptor.sourceSemantic == .importedImage)
        #expect(decoded.customTipAssetID == brush.customTipAssetID)
        #expect(decoded.secondaryTipDescriptor.tipAssetID == brush.secondaryTipDescriptor.tipAssetID)
        #expect(decoded.customTipImportedSourceInfo == brush.customTipImportedSourceInfo)
        #expect(decoded.secondaryTipDescriptor.importedSourceInfo == brush.secondaryTipDescriptor.importedSourceInfo)
        #expect(decoded.customTipMaskData == brush.customTipMaskData)
        #expect(decoded.secondaryTipDescriptor.customTipMaskData == brush.secondaryTipDescriptor.customTipMaskData)
    }

    @Test
    func brushLibraryArchiveExtractsAndRestoresImportedTipAssets() throws {
        var brush = BrushSettings.stageOneDefault
        brush.tipShape = .customRound
        brush.customTipSourceSemantic = .importedImage
        brush.customTipImportedSourceInfo = ImportedTipSourceInfo(
            sourceLabel: "Library Primary",
            pixelWidth: 256,
            pixelHeight: 128
        )
        brush.customTipMaskData = Data([255, 16, 96, 200])
        brush.secondaryTipDescriptor = SecondaryTipDescriptor(
            tipShape: .customRound,
            sourceSemantic: .importedImage,
            importedSourceInfo: ImportedTipSourceInfo(
                sourceLabel: "Library Secondary",
                pixelWidth: 64,
                pixelHeight: 64
            ),
            customTipMaskData: Data([255, 32, 128, 224]),
            customTipSoftness: 0.44,
            customTipRoundness: 0.73,
            customTipAngleDegrees: 27
        )

        let library = BrushLibraryState(
            presets: [
                BrushPreset(
                    id: "imported",
                    name: "Imported",
                    brush: brush,
                    isBuiltIn: false
                )
            ],
            selectedPresetID: "imported"
        )

        let primaryAssetID = BrushTipImageAssetID(maskData: brush.customTipMaskData!)
        let secondaryAssetID = BrushTipImageAssetID(maskData: brush.secondaryTipDescriptor.customTipMaskData!)
        let tipImageLibrary = TipImageLibraryState(
            items: [
                TipImageLibraryItem(
                    id: primaryAssetID,
                    sourceInfo: brush.customTipImportedSourceInfo!,
                    maskData: brush.customTipMaskData
                ),
                TipImageLibraryItem(
                    id: secondaryAssetID,
                    sourceInfo: brush.secondaryTipDescriptor.importedSourceInfo!,
                    maskData: brush.secondaryTipDescriptor.customTipMaskData
                )
            ]
        )

        let archive = BrushLibraryArchive(
            library: library,
            tipImageLibrary: tipImageLibrary
        )

        #expect(archive.tipImageAssets.count == 2)
        #expect(archive.tipImageLibrary.items.allSatisfy { $0.maskData == nil })
        #expect(archive.library.presets[0].brush.customTipMaskData == nil)
        #expect(archive.library.presets[0].brush.customTipAssetID != nil)
        #expect(archive.library.presets[0].brush.secondaryTipDescriptor.customTipMaskData == nil)
        #expect(archive.library.presets[0].brush.secondaryTipDescriptor.tipAssetID != nil)
        #expect(archive.resolvedLibrary == BrushTipImageAssetSystem.resolveLibrary(archive.library, assets: archive.tipImageAssets))
        #expect(archive.resolvedTipImageLibrary.items[0].maskData == brush.customTipMaskData)
        #expect(archive.resolvedTipImageLibrary.items[1].maskData == brush.secondaryTipDescriptor.customTipMaskData)
        #expect(archive.resolvedLibrary.presets[0].brush.customTipImportedSourceInfo == brush.customTipImportedSourceInfo)
        #expect(archive.resolvedLibrary.presets[0].brush.secondaryTipDescriptor.importedSourceInfo == brush.secondaryTipDescriptor.importedSourceInfo)
        #expect(archive.resolvedLibrary.presets[0].brush.customTipMaskData == brush.customTipMaskData)
        #expect(archive.resolvedLibrary.presets[0].brush.secondaryTipDescriptor.customTipMaskData == brush.secondaryTipDescriptor.customTipMaskData)

        let encoded = try JSONEncoder().encode(archive)
        let decoded = try JSONDecoder().decode(BrushLibraryArchive.self, from: encoded)

        #expect(decoded.tipImageAssets == archive.tipImageAssets)
        #expect(decoded.resolvedTipImageLibrary == archive.resolvedTipImageLibrary)
        #expect(decoded.resolvedLibrary.presets[0].brush.customTipImportedSourceInfo == brush.customTipImportedSourceInfo)
        #expect(decoded.resolvedLibrary.presets[0].brush.secondaryTipDescriptor.importedSourceInfo == brush.secondaryTipDescriptor.importedSourceInfo)
        #expect(decoded.resolvedLibrary.presets[0].brush.customTipMaskData == brush.customTipMaskData)
        #expect(decoded.resolvedLibrary.presets[0].brush.secondaryTipDescriptor.customTipMaskData == brush.secondaryTipDescriptor.customTipMaskData)
    }

    @Test
    func brushLibraryArchivePreservesImportedTipAssetsEvenWhenAnotherShapeIsActive() throws {
        var brush = BrushSettings.stageOneDefault
        brush.tipShape = .hardRound
        brush.customTipSourceSemantic = .importedImage
        brush.customTipImportedSourceInfo = ImportedTipSourceInfo(
            sourceLabel: "Dormant Primary",
            pixelWidth: 300,
            pixelHeight: 180
        )
        brush.customTipMaskData = Data([255, 80, 32, 0, 96])
        brush.secondaryTipDescriptor = SecondaryTipDescriptor(
            tipShape: .square,
            sourceSemantic: .importedImage,
            importedSourceInfo: ImportedTipSourceInfo(
                sourceLabel: "Dormant Secondary",
                pixelWidth: 144,
                pixelHeight: 144
            ),
            customTipMaskData: Data([0, 255, 96, 32, 8]),
            customTipSoftness: 0.44,
            customTipRoundness: 0.73,
            customTipAngleDegrees: 27
        )

        let library = BrushLibraryState(
            presets: [
                BrushPreset(
                    id: "dormant-imported",
                    name: "Dormant Imported",
                    brush: brush,
                    isBuiltIn: false
                )
            ],
            selectedPresetID: "dormant-imported"
        )

        let archive = BrushLibraryArchive(library: library)

        #expect(archive.tipImageAssets.count == 2)
        #expect(archive.library.presets[0].brush.customTipMaskData == nil)
        #expect(archive.library.presets[0].brush.customTipAssetID != nil)
        #expect(archive.library.presets[0].brush.secondaryTipDescriptor.customTipMaskData == nil)
        #expect(archive.library.presets[0].brush.secondaryTipDescriptor.tipAssetID != nil)
        #expect(archive.library.presets[0].brush.tipShape == .hardRound)
        #expect(archive.library.presets[0].brush.secondaryTipDescriptor.tipShape == .square)
        #expect(archive.resolvedLibrary.presets[0].brush.customTipMaskData == brush.customTipMaskData)
        #expect(archive.resolvedLibrary.presets[0].brush.secondaryTipDescriptor.customTipMaskData == brush.secondaryTipDescriptor.customTipMaskData)
        #expect(archive.resolvedLibrary.presets[0].brush.customTipImportedSourceInfo == brush.customTipImportedSourceInfo)
        #expect(archive.resolvedLibrary.presets[0].brush.secondaryTipDescriptor.importedSourceInfo == brush.secondaryTipDescriptor.importedSourceInfo)
    }

    @Test
    func tipImageLibraryCanBackfillImportedTipsFromBrushes() {
        let primaryMask = Data([255, 16, 96, 200])
        let secondaryMask = Data([255, 32, 128, 224])

        var brush = BrushSettings.stageOneDefault
        brush.tipShape = .customRound
        brush.customTipSourceSemantic = .importedImage
        brush.customTipImportedSourceInfo = ImportedTipSourceInfo(
            sourceLabel: "Primary Source",
            pixelWidth: 144,
            pixelHeight: 96
        )
        brush.customTipMaskData = primaryMask
        brush.secondaryTipDescriptor = SecondaryTipDescriptor(
            tipShape: .customRound,
            sourceSemantic: .importedImage,
            importedSourceInfo: ImportedTipSourceInfo(
                sourceLabel: "Secondary Source",
                pixelWidth: 80,
                pixelHeight: 120
            ),
            customTipMaskData: secondaryMask,
            customTipSoftness: 0.44,
            customTipRoundness: 0.73,
            customTipAngleDegrees: 27
        )

        var library = TipImageLibraryState.empty
        let changed = library.upsertImportedTips(from: brush)

        #expect(changed)
        #expect(library.items.count == 2)

        let unchanged = library.upsertImportedTips(from: brush)
        #expect(!unchanged)
        #expect(library.items.count == 2)
    }

    @Test
    func tipImageLibraryMoveItemReordersByDropTargetIndex() {
        let first = TipImageLibraryItem(
            id: BrushTipImageAssetID(rawValue: "first"),
            sourceInfo: ImportedTipSourceInfo(sourceLabel: "First", pixelWidth: 64, pixelHeight: 64),
            maskData: Data([1])
        )
        let second = TipImageLibraryItem(
            id: BrushTipImageAssetID(rawValue: "second"),
            sourceInfo: ImportedTipSourceInfo(sourceLabel: "Second", pixelWidth: 64, pixelHeight: 64),
            maskData: Data([2])
        )
        let third = TipImageLibraryItem(
            id: BrushTipImageAssetID(rawValue: "third"),
            sourceInfo: ImportedTipSourceInfo(sourceLabel: "Third", pixelWidth: 64, pixelHeight: 64),
            maskData: Data([3])
        )
        var library = TipImageLibraryState(items: [first, second, third])

        let movedToEnd = library.moveItem(id: first.id, to: 2)
        #expect(movedToEnd)
        #expect(library.items.map(\.id) == [second.id, third.id, first.id])

        let movedToFront = library.moveItem(id: first.id, to: 0)
        #expect(movedToFront)
        #expect(library.items.map(\.id) == [first.id, second.id, third.id])
    }

    @Test
    func brushLibraryPersistenceRestoresUnreferencedTipImageLibraryItems() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let fileManager = BrushLibraryPersistenceTestFileManager(rootURL: tempRoot)
        let controller = BrushLibraryPersistenceController(fileManager: fileManager)

        let orphanMask = Data([7, 14, 21, 28])
        let tipImageLibrary = TipImageLibraryState(
            items: [
                TipImageLibraryItem(
                    id: BrushTipImageAssetID(maskData: orphanMask),
                    sourceInfo: ImportedTipSourceInfo(
                        sourceLabel: "Unused Tip",
                        pixelWidth: 128,
                        pixelHeight: 96
                    ),
                    maskData: orphanMask
                )
            ]
        )

        try controller.saveResources(
            library: .stageOneDefault,
            tipImageLibrary: tipImageLibrary
        )

        let restored = try #require(controller.loadResources())
        #expect(restored.tipImageLibrary == tipImageLibrary)
    }

    @Test
    func tipImageLibraryNormalizesDuplicateAssetIDsByKeepingAvailableMaskData() {
        let sharedID = BrushTipImageAssetID(rawValue: "shared-tip")
        let maskData = Data([9, 18, 27, 36])
        let placeholder = TipImageLibraryItem(
            id: sharedID,
            sourceInfo: ImportedTipSourceInfo(
                sourceLabel: "Placeholder",
                pixelWidth: 32,
                pixelHeight: 32
            ),
            maskData: nil
        )
        let resolved = TipImageLibraryItem(
            id: sharedID,
            sourceInfo: ImportedTipSourceInfo(
                sourceLabel: "Resolved",
                pixelWidth: 128,
                pixelHeight: 96
            ),
            maskData: maskData
        )

        let normalized = TipImageLibraryState(items: [placeholder, resolved])
            .normalizedMergingDuplicates()

        #expect(normalized.items.count == 1)
        #expect(normalized.items[0].id == sharedID)
        #expect(normalized.items[0].maskData == maskData)
        #expect(normalized.items[0].sourceInfo == resolved.sourceInfo)
    }

    @Test
    func tipImageLibraryMergeFillsExistingDuplicateMaskData() {
        let sharedID = BrushTipImageAssetID(rawValue: "shared-tip")
        let maskData = Data([1, 3, 5, 7])

        var base = TipImageLibraryState(
            items: [
                TipImageLibraryItem(
                    id: sharedID,
                    sourceInfo: ImportedTipSourceInfo(
                        sourceLabel: "Base",
                        pixelWidth: 24,
                        pixelHeight: 24
                    ),
                    maskData: nil
                )
            ]
        )
        let imported = TipImageLibraryState(
            items: [
                TipImageLibraryItem(
                    id: sharedID,
                    sourceInfo: ImportedTipSourceInfo(
                        sourceLabel: "Imported",
                        pixelWidth: 80,
                        pixelHeight: 64
                    ),
                    maskData: maskData
                )
            ]
        )

        let changed = base.mergeItems(from: imported)

        #expect(changed)
        #expect(base.items.count == 1)
        #expect(base.items[0].maskData == maskData)
        #expect(base.items[0].sourceInfo == imported.items[0].sourceInfo)
    }

    @MainActor
    @Test
    func workspaceViewModelRestoreReappliesSelectedPresetBrushOnLaunch() throws {
        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal is required for WorkspaceViewModel tests.")
            return
        }

        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let controller = BrushLibraryPersistenceController(
            fileManager: BrushLibraryPersistenceTestFileManager(rootURL: tempRoot)
        )

        var restoredBrush = BrushSettings.stageOneDefault
        restoredBrush.tipShape = .customRound
        restoredBrush.dualTipEnabled = true
        restoredBrush.secondaryTipDescriptor = SecondaryTipDescriptor(tipShape: .softRound)
        restoredBrush.dualTipCombineMode = .intersect
        restoredBrush.secondarySizeRatio = 1.42
        restoredBrush.secondarySpacingPhase = 0.24

        let customPreset = BrushPreset(
            id: "restored-custom",
            name: "Restored Custom",
            brush: restoredBrush,
            isBuiltIn: false,
            slotIndex: 12
        )

        try controller.saveResources(
            library: BrushLibraryState(
                presets: [customPreset],
                selectedPresetID: customPreset.id
            ),
            tipImageLibrary: .empty
        )

        let bootstrap = try AppBootstrap(
            workspaceStore: WorkspaceStore(state: .stageOneDefault),
            metalContext: metalContext,
            layerSurfaceStore: StageOneLayerSurfaceStore(),
            brushLibraryPersistenceController: controller
        )
        let viewModel = WorkspaceViewModel(
            bootstrap: bootstrap,
            installsZoomKeyboardMonitor: false,
            preparesInitialTextures: false
        )

        #expect(viewModel.workspace.brushLibrary.selectedPresetID == customPreset.id)
        #expect(viewModel.workspace.toolSession.brush == customPreset.brush)
        #expect(
            bootstrap.workspaceStore.state.brushLibrary.preset(id: customPreset.id)?.brush == customPreset.brush
        )
    }

    @MainActor
    @Test
    func importedBrushLibraryReplaceRealignsCurrentBrushAndBackfillsTipImageLibrary() throws {
        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal is required for WorkspaceViewModel tests.")
            return
        }

        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let controller = BrushLibraryPersistenceController(
            fileManager: BrushLibraryPersistenceTestFileManager(rootURL: tempRoot)
        )

        let assetMask = Data([255, 12, 99, 33])
        let assetID = BrushTipImageAssetID(maskData: assetMask)
        let sourceInfo = ImportedTipSourceInfo(
            sourceLabel: "Imported Library Tip",
            pixelWidth: 96,
            pixelHeight: 96
        )

        var importedBrush = BrushSettings.stageOneDefault
        importedBrush.tipShape = .customRound
        importedBrush.customTipSourceSemantic = .importedImage
        importedBrush.customTipAssetID = assetID
        importedBrush.customTipImportedSourceInfo = sourceInfo
        importedBrush.customTipMaskData = assetMask
        importedBrush.dualTipEnabled = true

        let importedPreset = BrushPreset(
            id: "imported-preset",
            name: "Imported Preset",
            brush: importedBrush,
            isBuiltIn: false,
            slotIndex: 8
        )

        let bootstrap = try AppBootstrap(
            workspaceStore: WorkspaceStore(state: .stageOneDefault),
            metalContext: metalContext,
            layerSurfaceStore: StageOneLayerSurfaceStore(),
            brushLibraryPersistenceController: controller
        )
        let viewModel = WorkspaceViewModel(
            bootstrap: bootstrap,
            installsZoomKeyboardMonitor: false,
            preparesInitialTextures: false
        )

        let didRealign = viewModel.applyImportedBrushLibraryResources(
            PersistedBrushResources(
                library: BrushLibraryState(
                    presets: [importedPreset],
                    selectedPresetID: importedPreset.id
                ),
                tipImageLibrary: .empty
            ),
            replacingExistingLibrary: true
        )

        let state = bootstrap.workspaceStore.state
        #expect(didRealign)
        #expect(state.brushLibrary.selectedPresetID == importedPreset.id)
        #expect(state.toolSession.brush == importedPreset.brush)
        #expect(state.tipImageLibrary.item(id: assetID)?.maskData == assetMask)
        #expect(state.tipImageLibrary.item(id: assetID)?.sourceInfo == sourceInfo)
    }

    @MainActor
    @Test
    func deletingSelectedBrushPresetRealignsCurrentBrushToRemainingSelection() throws {
        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal is required for WorkspaceViewModel tests.")
            return
        }

        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let controller = BrushLibraryPersistenceController(
            fileManager: BrushLibraryPersistenceTestFileManager(rootURL: tempRoot)
        )

        var firstBrush = BrushSettings.stageOneDefault
        firstBrush.size = 22
        firstBrush.opacity = 0.4

        var secondBrush = BrushSettings.stageOneDefault
        secondBrush.size = 77
        secondBrush.opacity = 0.91
        secondBrush.dualTipEnabled = true
        secondBrush.dualTipCombineMode = .subtract

        let firstPreset = BrushPreset(
            id: "first-preset",
            name: "First Preset",
            brush: firstBrush,
            isBuiltIn: false,
            slotIndex: 0
        )
        let secondPreset = BrushPreset(
            id: "second-preset",
            name: "Second Preset",
            brush: secondBrush,
            isBuiltIn: false,
            slotIndex: 1
        )

        var workspace = WorkspaceState.stageOneDefault
        workspace.brushLibrary = BrushLibraryState(
            presets: [firstPreset, secondPreset],
            selectedPresetID: secondPreset.id
        )
        workspace.toolSession.brush = secondBrush

        let bootstrap = try AppBootstrap(
            workspaceStore: WorkspaceStore(state: workspace),
            metalContext: metalContext,
            layerSurfaceStore: StageOneLayerSurfaceStore(),
            brushLibraryPersistenceController: controller
        )
        let viewModel = WorkspaceViewModel(
            bootstrap: bootstrap,
            installsZoomKeyboardMonitor: false,
            preparesInitialTextures: false
        )
        bootstrap.workspaceStore.replaceState(workspace)

        viewModel.deleteBrushPreset(secondPreset.id)

        #expect(viewModel.workspace.brushLibrary.selectedPresetID == firstPreset.id)
        #expect(viewModel.workspace.toolSession.brush == firstPreset.brush)
    }

    @MainActor
    @Test
    func workspaceViewModelReportsTipImageLibraryReferenceSummary() throws {
        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal is required for WorkspaceViewModel tests.")
            return
        }

        let sharedAssetID = BrushTipImageAssetID(rawValue: "shared-tip")
        let importedSource = ImportedTipSourceInfo(
            sourceLabel: "Shared",
            pixelWidth: 64,
            pixelHeight: 64
        )

        var currentBrush = BrushSettings.stageOneDefault
        currentBrush.tipShape = .customRound
        currentBrush.customTipSourceSemantic = .importedImage
        currentBrush.customTipAssetID = sharedAssetID
        currentBrush.customTipImportedSourceInfo = importedSource
        currentBrush.customTipMaskData = Data([255, 32, 128, 16])
        currentBrush.secondaryTipDescriptor = SecondaryTipDescriptor(
            tipShape: .customRound,
            sourceSemantic: .importedImage,
            tipAssetID: sharedAssetID,
            importedSourceInfo: importedSource,
            customTipMaskData: Data([255, 64, 0, 32]),
            customTipSoftness: 0.5,
            customTipRoundness: 1,
            customTipAngleDegrees: 0
        )

        var presetPrimaryBrush = BrushSettings.stageOneDefault
        presetPrimaryBrush.tipShape = .customRound
        presetPrimaryBrush.customTipSourceSemantic = .importedImage
        presetPrimaryBrush.customTipAssetID = sharedAssetID
        presetPrimaryBrush.customTipImportedSourceInfo = importedSource
        presetPrimaryBrush.customTipMaskData = Data([255, 0, 0, 0])

        var presetSecondaryBrush = BrushSettings.stageOneDefault
        presetSecondaryBrush.secondaryTipDescriptor = SecondaryTipDescriptor(
            tipShape: .customRound,
            sourceSemantic: .importedImage,
            tipAssetID: sharedAssetID,
            importedSourceInfo: importedSource,
            customTipMaskData: Data([0, 255, 0, 0]),
            customTipSoftness: 0.5,
            customTipRoundness: 1,
            customTipAngleDegrees: 0
        )

        var workspace = WorkspaceState.stageOneDefault
        workspace.toolSession.brush = currentBrush
        workspace.brushLibrary = BrushLibraryState(
            presets: [
                BrushPreset(id: "preset-primary", name: "Preset Primary", brush: presetPrimaryBrush, isBuiltIn: false),
                BrushPreset(id: "preset-secondary", name: "Preset Secondary", brush: presetSecondaryBrush, isBuiltIn: false)
            ],
            selectedPresetID: nil
        )

        let bootstrap = try AppBootstrap(
            workspaceStore: WorkspaceStore(state: workspace),
            metalContext: metalContext,
            layerSurfaceStore: StageOneLayerSurfaceStore()
        )
        let viewModel = WorkspaceViewModel(bootstrap: bootstrap, installsZoomKeyboardMonitor: false)
        bootstrap.workspaceStore.replaceState(workspace)

        let summary = viewModel.tipImageLibraryReferenceSummary(for: sharedAssetID)
        #expect(summary.currentBrushUsesPrimary)
        #expect(summary.currentBrushUsesSecondary)
        #expect(summary.currentBrushPrimaryCount == 1)
        #expect(summary.currentBrushSecondaryCount == 1)
        #expect(summary.presetPrimaryNames == ["Preset Primary"])
        #expect(summary.presetSecondaryNames == ["Preset Secondary"])
        #expect(summary.presetPrimaryCount == 1)
        #expect(summary.presetSecondaryCount == 1)
        #expect(summary.totalCount == 4)
        #expect(summary.isReferenced)
    }

    @Test
    func phaseOneRealDrawingSupportGateStaysNarrow() {
        var supported = BrushSettings.stageOneDefault
        supported.dualTipEnabled = true
        supported.tipShape = .hardRound
        supported.secondaryTipDescriptor = SecondaryTipDescriptor(tipShape: .softRound)
        supported.dualTipCombineMode = .multiply

        #expect(supported.supportsPhaseOneDualTipRealDrawing(for: .brush))
        #expect(supported.supportsPhaseOneDualTipRealDrawing(for: .eraser))

        var disabled = supported
        disabled.dualTipEnabled = false
        #expect(disabled.supportsPhaseOneDualTipRealDrawing(for: .brush) == false)

        var wrongMode = supported
        wrongMode.dualTipCombineMode = .subtract
        #expect(wrongMode.supportsPhaseOneDualTipRealDrawing(for: .brush) == false)

        var wrongPrimaryShape = supported
        wrongPrimaryShape.tipShape = .square
        #expect(wrongPrimaryShape.supportsPhaseOneDualTipRealDrawing(for: .brush) == false)

        var wrongSecondaryShape = supported
        wrongSecondaryShape.secondaryTipDescriptor = SecondaryTipDescriptor(tipShape: .square)
        #expect(wrongSecondaryShape.supportsPhaseOneDualTipRealDrawing(for: .brush) == false)

        var customSecondary = supported
        customSecondary.secondaryTipDescriptor = SecondaryTipDescriptor(
            tipShape: .customRound,
            customTipMaskData: Data([255, 0, 255]),
            customTipSoftness: 0.4,
            customTipRoundness: 0.7,
            customTipAngleDegrees: 23
        )
        #expect(customSecondary.supportsPhaseOneDualTipRealDrawing(for: .brush))

        var customPrimary = supported
        customPrimary.tipShape = .customRound
        customPrimary.customTipMaskData = Data([255, 128, 64])
        #expect(customPrimary.supportsPhaseOneDualTipRealDrawing(for: .brush))

        var customBoth = customPrimary
        customBoth.secondaryTipDescriptor = SecondaryTipDescriptor(
            tipShape: .customRound,
            customTipMaskData: Data([255, 0, 255]),
            customTipSoftness: 0.4,
            customTipRoundness: 0.7,
            customTipAngleDegrees: 23
        )
        #expect(customBoth.supportsPhaseOneDualTipRealDrawing(for: .brush))

        #expect(supported.supportsPhaseOneDualTipRealDrawing(for: .smudge) == false)
    }

    @Test
    func phaseTwoSubtractRealDrawingSupportGateStaysNarrow() {
        var supported = BrushSettings.stageOneDefault
        supported.dualTipEnabled = true
        supported.tipShape = .softRound
        supported.secondaryTipDescriptor = SecondaryTipDescriptor(tipShape: .hardRound)
        supported.dualTipCombineMode = .subtract

        #expect(supported.supportsPhaseTwoDualTipSubtractRealDrawing(for: .brush))
        #expect(supported.supportsPhaseTwoDualTipSubtractRealDrawing(for: .eraser))

        var disabled = supported
        disabled.dualTipEnabled = false
        #expect(disabled.supportsPhaseTwoDualTipSubtractRealDrawing(for: .brush) == false)

        var wrongModeMultiply = supported
        wrongModeMultiply.dualTipCombineMode = .multiply
        #expect(wrongModeMultiply.supportsPhaseTwoDualTipSubtractRealDrawing(for: .brush) == false)

        var wrongModeIntersect = supported
        wrongModeIntersect.dualTipCombineMode = .intersect
        #expect(wrongModeIntersect.supportsPhaseTwoDualTipSubtractRealDrawing(for: .brush) == false)

        var wrongPrimaryShape = supported
        wrongPrimaryShape.tipShape = .square
        #expect(wrongPrimaryShape.supportsPhaseTwoDualTipSubtractRealDrawing(for: .brush) == false)

        var wrongSecondaryShape = supported
        wrongSecondaryShape.secondaryTipDescriptor = SecondaryTipDescriptor(tipShape: .square)
        #expect(wrongSecondaryShape.supportsPhaseTwoDualTipSubtractRealDrawing(for: .brush) == false)

        var customSecondary = supported
        customSecondary.secondaryTipDescriptor = SecondaryTipDescriptor(
            tipShape: .customRound,
            customTipMaskData: Data([255, 128, 32]),
            customTipSoftness: 0.55,
            customTipRoundness: 0.62,
            customTipAngleDegrees: 17
        )
        #expect(customSecondary.supportsPhaseTwoDualTipSubtractRealDrawing(for: .brush))

        var customPrimary = supported
        customPrimary.tipShape = .customRound
        customPrimary.customTipMaskData = Data([255, 32, 16])
        #expect(customPrimary.supportsPhaseTwoDualTipSubtractRealDrawing(for: .brush))

        var customBoth = customPrimary
        customBoth.secondaryTipDescriptor = SecondaryTipDescriptor(
            tipShape: .customRound,
            customTipMaskData: Data([255, 128, 32]),
            customTipSoftness: 0.55,
            customTipRoundness: 0.62,
            customTipAngleDegrees: 17
        )
        #expect(customBoth.supportsPhaseTwoDualTipSubtractRealDrawing(for: .brush))

        #expect(supported.supportsPhaseTwoDualTipSubtractRealDrawing(for: .smudge) == false)
    }

    @Test
    func phaseTwoIntersectRealDrawingSupportGateStaysNarrow() {
        var supported = BrushSettings.stageOneDefault
        supported.dualTipEnabled = true
        supported.tipShape = .customRound
        supported.customTipMaskData = Data([255, 32, 16])
        supported.secondaryTipDescriptor = SecondaryTipDescriptor(
            tipShape: .customRound,
            customTipMaskData: Data([255, 128, 32]),
            customTipSoftness: 0.55,
            customTipRoundness: 0.62,
            customTipAngleDegrees: 17
        )
        supported.dualTipCombineMode = .intersect

        #expect(supported.supportsPhaseTwoDualTipIntersectRealDrawing(for: .brush))
        #expect(supported.supportsPhaseTwoDualTipIntersectRealDrawing(for: .eraser))

        var disabled = supported
        disabled.dualTipEnabled = false
        #expect(disabled.supportsPhaseTwoDualTipIntersectRealDrawing(for: .brush) == false)

        var wrongModeMultiply = supported
        wrongModeMultiply.dualTipCombineMode = .multiply
        #expect(wrongModeMultiply.supportsPhaseTwoDualTipIntersectRealDrawing(for: .brush) == false)

        var wrongModeSubtract = supported
        wrongModeSubtract.dualTipCombineMode = .subtract
        #expect(wrongModeSubtract.supportsPhaseTwoDualTipIntersectRealDrawing(for: .brush) == false)

        var wrongPrimaryShape = supported
        wrongPrimaryShape.tipShape = .square
        #expect(wrongPrimaryShape.supportsPhaseTwoDualTipIntersectRealDrawing(for: .brush) == false)

        var wrongSecondaryShape = supported
        wrongSecondaryShape.secondaryTipDescriptor = SecondaryTipDescriptor(tipShape: .square)
        #expect(wrongSecondaryShape.supportsPhaseTwoDualTipIntersectRealDrawing(for: .brush) == false)

        #expect(supported.supportsPhaseTwoDualTipIntersectRealDrawing(for: .smudge) == false)
    }

    @Test
    func multiplySubtractAndIntersectRealDrawingGatesRemainSeparated() {
        var multiplyBrush = BrushSettings.stageOneDefault
        multiplyBrush.dualTipEnabled = true
        multiplyBrush.tipShape = .hardRound
        multiplyBrush.secondaryTipDescriptor = SecondaryTipDescriptor(tipShape: .softRound)
        multiplyBrush.dualTipCombineMode = .multiply

        #expect(multiplyBrush.supportsPhaseOneDualTipRealDrawing(for: .brush))
        #expect(multiplyBrush.supportsPhaseTwoDualTipSubtractRealDrawing(for: .brush) == false)
        #expect(multiplyBrush.supportsPhaseTwoDualTipIntersectRealDrawing(for: .brush) == false)

        var subtractBrush = multiplyBrush
        subtractBrush.dualTipCombineMode = .subtract

        #expect(subtractBrush.supportsPhaseOneDualTipRealDrawing(for: .brush) == false)
        #expect(subtractBrush.supportsPhaseTwoDualTipSubtractRealDrawing(for: .brush))
        #expect(subtractBrush.supportsPhaseTwoDualTipIntersectRealDrawing(for: .brush) == false)

        var intersectBrush = multiplyBrush
        intersectBrush.dualTipCombineMode = .intersect

        #expect(intersectBrush.supportsPhaseOneDualTipRealDrawing(for: .brush) == false)
        #expect(intersectBrush.supportsPhaseTwoDualTipSubtractRealDrawing(for: .brush) == false)
        #expect(intersectBrush.supportsPhaseTwoDualTipIntersectRealDrawing(for: .brush))
    }

    @Test
    func secondaryScatterOnlyAppliesInsideCurrentRealDrawingGates() {
        var supported = BrushSettings.stageOneDefault
        supported.dualTipEnabled = true
        supported.tipShape = .customRound
        supported.customTipMaskData = Data([255, 32, 16])
        supported.secondaryTipDescriptor = SecondaryTipDescriptor(
            tipShape: .customRound,
            customTipMaskData: Data([255, 128, 32]),
            customTipSoftness: 0.55,
            customTipRoundness: 0.62,
            customTipAngleDegrees: 17
        )
        supported.dualTipCombineMode = .intersect
        supported.secondaryScatter = 1.8

        #expect(supported.supportsSecondaryScatterRealDrawing(for: .brush))
        #expect(supported.supportsSecondaryScatterRealDrawing(for: .eraser))

        var disabled = supported
        disabled.dualTipEnabled = false
        #expect(disabled.supportsSecondaryScatterRealDrawing(for: .brush) == false)

        var zeroScatter = supported
        zeroScatter.secondaryScatter = 0
        #expect(zeroScatter.supportsSecondaryScatterRealDrawing(for: .brush) == false)

        var wrongMode = supported
        wrongMode.dualTipCombineMode = .multiply
        #expect(wrongMode.supportsSecondaryScatterRealDrawing(for: .brush))

        var unsupportedSecondary = supported
        unsupportedSecondary.secondaryTipDescriptor = SecondaryTipDescriptor(tipShape: .square)
        #expect(unsupportedSecondary.supportsSecondaryScatterRealDrawing(for: .brush) == false)

        #expect(supported.supportsSecondaryScatterRealDrawing(for: .smudge) == false)
    }

    @Test
    func secondaryScatterJitterOnlyAppliesInsideCurrentRealDrawingGates() {
        var supported = BrushSettings.stageOneDefault
        supported.dualTipEnabled = true
        supported.tipShape = .customRound
        supported.customTipMaskData = Data([255, 32, 16])
        supported.secondaryTipDescriptor = SecondaryTipDescriptor(
            tipShape: .customRound,
            customTipMaskData: Data([255, 128, 32]),
            customTipSoftness: 0.55,
            customTipRoundness: 0.62,
            customTipAngleDegrees: 17
        )
        supported.dualTipCombineMode = .subtract
        supported.secondaryScatter = 1.8
        supported.secondaryScatterJitter = 0.35

        #expect(supported.supportsSecondaryScatterJitterRealDrawing(for: .brush))
        #expect(supported.supportsSecondaryScatterJitterRealDrawing(for: .eraser))

        var disabled = supported
        disabled.dualTipEnabled = false
        #expect(disabled.supportsSecondaryScatterJitterRealDrawing(for: .brush) == false)

        var zeroJitter = supported
        zeroJitter.secondaryScatterJitter = 0
        #expect(zeroJitter.supportsSecondaryScatterJitterRealDrawing(for: .brush) == false)

        var zeroScatter = supported
        zeroScatter.secondaryScatter = 0
        #expect(zeroScatter.supportsSecondaryScatterJitterRealDrawing(for: .brush) == false)

        #expect(supported.supportsSecondaryScatterJitterRealDrawing(for: .smudge) == false)
    }

    @Test
    func secondaryAngleOffsetOnlyAppliesForCustomSecondaryInsideCurrentRealDrawingGates() {
        var supported = BrushSettings.stageOneDefault
        supported.dualTipEnabled = true
        supported.tipShape = .customRound
        supported.customTipMaskData = Data([255, 32, 16])
        supported.secondaryTipDescriptor = SecondaryTipDescriptor(
            tipShape: .customRound,
            customTipMaskData: Data([255, 128, 32]),
            customTipSoftness: 0.55,
            customTipRoundness: 0.62,
            customTipAngleDegrees: 17
        )
        supported.dualTipCombineMode = .subtract
        supported.secondaryAngleOffsetDegrees = 34

        #expect(supported.supportsSecondaryAngleOffsetRealDrawing(for: .brush))
        #expect(supported.supportsSecondaryAngleOffsetRealDrawing(for: .eraser))

        var disabled = supported
        disabled.dualTipEnabled = false
        #expect(disabled.supportsSecondaryAngleOffsetRealDrawing(for: .brush) == false)

        var zeroOffset = supported
        zeroOffset.secondaryAngleOffsetDegrees = 0
        #expect(zeroOffset.supportsSecondaryAngleOffsetRealDrawing(for: .brush) == false)

        var roundSecondary = supported
        roundSecondary.secondaryTipDescriptor = SecondaryTipDescriptor(tipShape: .softRound)
        #expect(roundSecondary.supportsSecondaryAngleOffsetRealDrawing(for: .brush) == false)

        var wrongMode = supported
        wrongMode.dualTipCombineMode = .multiply
        #expect(wrongMode.supportsSecondaryAngleOffsetRealDrawing(for: .brush))

        #expect(supported.supportsSecondaryAngleOffsetRealDrawing(for: .smudge) == false)
    }

    @Test
    func secondarySizeJitterOnlyAppliesInsideCurrentRealDrawingGates() {
        var supported = BrushSettings.stageOneDefault
        supported.dualTipEnabled = true
        supported.tipShape = .customRound
        supported.customTipMaskData = Data([255, 32, 16])
        supported.secondaryTipDescriptor = SecondaryTipDescriptor(
            tipShape: .customRound,
            customTipMaskData: Data([255, 128, 32]),
            customTipSoftness: 0.55,
            customTipRoundness: 0.62,
            customTipAngleDegrees: 17
        )
        supported.dualTipCombineMode = .subtract
        supported.secondarySizeJitter = 0.42

        #expect(supported.supportsSecondarySizeJitterRealDrawing(for: .brush))
        #expect(supported.supportsSecondarySizeJitterRealDrawing(for: .eraser))

        var disabled = supported
        disabled.dualTipEnabled = false
        #expect(disabled.supportsSecondarySizeJitterRealDrawing(for: .brush) == false)

        var zeroJitter = supported
        zeroJitter.secondarySizeJitter = 0
        #expect(zeroJitter.supportsSecondarySizeJitterRealDrawing(for: .brush) == false)

        var wrongMode = supported
        wrongMode.dualTipCombineMode = .multiply
        #expect(wrongMode.supportsSecondarySizeJitterRealDrawing(for: .brush))

        var unsupportedSecondary = supported
        unsupportedSecondary.secondaryTipDescriptor = SecondaryTipDescriptor(tipShape: .square)
        #expect(unsupportedSecondary.supportsSecondarySizeJitterRealDrawing(for: .brush) == false)

        #expect(supported.supportsSecondarySizeJitterRealDrawing(for: .smudge) == false)
    }

    @Test
    func secondaryAngleJitterOnlyAppliesForCustomSecondaryInsideCurrentRealDrawingGates() {
        var supported = BrushSettings.stageOneDefault
        supported.dualTipEnabled = true
        supported.tipShape = .customRound
        supported.customTipMaskData = Data([255, 32, 16])
        supported.secondaryTipDescriptor = SecondaryTipDescriptor(
            tipShape: .customRound,
            customTipMaskData: Data([255, 128, 32]),
            customTipSoftness: 0.55,
            customTipRoundness: 0.62,
            customTipAngleDegrees: 17
        )
        supported.dualTipCombineMode = .intersect
        supported.secondaryAngleJitterDegrees = 42

        #expect(supported.supportsSecondaryAngleJitterRealDrawing(for: .brush))
        #expect(supported.supportsSecondaryAngleJitterRealDrawing(for: .eraser))

        var disabled = supported
        disabled.dualTipEnabled = false
        #expect(disabled.supportsSecondaryAngleJitterRealDrawing(for: .brush) == false)

        var zeroJitter = supported
        zeroJitter.secondaryAngleJitterDegrees = 0
        #expect(zeroJitter.supportsSecondaryAngleJitterRealDrawing(for: .brush) == false)

        var roundSecondary = supported
        roundSecondary.secondaryTipDescriptor = SecondaryTipDescriptor(tipShape: .softRound)
        #expect(roundSecondary.supportsSecondaryAngleJitterRealDrawing(for: .brush) == false)

        var wrongMode = supported
        wrongMode.dualTipCombineMode = .multiply
        #expect(wrongMode.supportsSecondaryAngleJitterRealDrawing(for: .brush))

        #expect(supported.supportsSecondaryAngleJitterRealDrawing(for: .smudge) == false)
    }

    @Test
    func secondarySpacingPhaseOnlyAppliesInsideCurrentRealDrawingGates() {
        var supported = BrushSettings.stageOneDefault
        supported.dualTipEnabled = true
        supported.tipShape = .customRound
        supported.customTipMaskData = Data([255, 32, 16])
        supported.secondaryTipDescriptor = SecondaryTipDescriptor(
            tipShape: .softRound,
            customTipSoftness: 0.55,
            customTipRoundness: 0.62,
            customTipAngleDegrees: 17
        )
        supported.dualTipCombineMode = .subtract
        supported.secondarySpacingPhase = 0.3

        #expect(supported.supportsSecondarySpacingPhaseRealDrawing(for: .brush))
        #expect(supported.supportsSecondarySpacingPhaseRealDrawing(for: .eraser))

        var disabled = supported
        disabled.dualTipEnabled = false
        #expect(disabled.supportsSecondarySpacingPhaseRealDrawing(for: .brush) == false)

        var zeroPhase = supported
        zeroPhase.secondarySpacingPhase = 0
        #expect(zeroPhase.supportsSecondarySpacingPhaseRealDrawing(for: .brush) == false)

        var wrongMode = supported
        wrongMode.dualTipCombineMode = .multiply
        #expect(wrongMode.supportsSecondarySpacingPhaseRealDrawing(for: .brush))

        #expect(supported.supportsSecondarySpacingPhaseRealDrawing(for: .smudge) == false)
    }

    @Test
    func secondarySpacingPhaseJitterOnlyAppliesInsideCurrentRealDrawingGates() {
        var supported = BrushSettings.stageOneDefault
        supported.dualTipEnabled = true
        supported.tipShape = .customRound
        supported.customTipMaskData = Data([255, 32, 16])
        supported.secondaryTipDescriptor = SecondaryTipDescriptor(
            tipShape: .softRound,
            customTipSoftness: 0.55,
            customTipRoundness: 0.62,
            customTipAngleDegrees: 17
        )
        supported.dualTipCombineMode = .intersect
        supported.secondarySpacingPhaseJitter = 0.2

        #expect(supported.supportsSecondarySpacingPhaseJitterRealDrawing(for: .brush))
        #expect(supported.supportsSecondarySpacingPhaseJitterRealDrawing(for: .eraser))

        var disabled = supported
        disabled.dualTipEnabled = false
        #expect(disabled.supportsSecondarySpacingPhaseJitterRealDrawing(for: .brush) == false)

        var zeroJitter = supported
        zeroJitter.secondarySpacingPhaseJitter = 0
        #expect(zeroJitter.supportsSecondarySpacingPhaseJitterRealDrawing(for: .brush) == false)

        var wrongMode = supported
        wrongMode.dualTipCombineMode = .multiply
        #expect(wrongMode.supportsSecondarySpacingPhaseJitterRealDrawing(for: .brush))

        #expect(supported.supportsSecondarySpacingPhaseJitterRealDrawing(for: .smudge) == false)
    }

    @Test
    func secondaryInvertOnlyAppliesInsideCurrentRealDrawingGates() {
        var supported = BrushSettings.stageOneDefault
        supported.dualTipEnabled = true
        supported.tipShape = .customRound
        supported.customTipMaskData = Data([255, 32, 16])
        supported.secondaryTipDescriptor = SecondaryTipDescriptor(
            tipShape: .customRound,
            customTipMaskData: Data([255, 128, 32]),
            customTipSoftness: 0.55,
            customTipRoundness: 0.62,
            customTipAngleDegrees: 17
        )
        supported.dualTipCombineMode = .intersect
        supported.secondaryInvert = true

        #expect(supported.supportsSecondaryInvertRealDrawing(for: .brush))
        #expect(supported.supportsSecondaryInvertRealDrawing(for: .eraser))

        var disabled = supported
        disabled.dualTipEnabled = false
        #expect(disabled.supportsSecondaryInvertRealDrawing(for: .brush) == false)

        var toggleOff = supported
        toggleOff.secondaryInvert = false
        #expect(toggleOff.supportsSecondaryInvertRealDrawing(for: .brush) == false)

        var wrongMode = supported
        wrongMode.dualTipCombineMode = .multiply
        #expect(wrongMode.supportsSecondaryInvertRealDrawing(for: .brush))

        var unsupportedSecondary = supported
        unsupportedSecondary.secondaryTipDescriptor = SecondaryTipDescriptor(tipShape: .square)
        #expect(unsupportedSecondary.supportsSecondaryInvertRealDrawing(for: .brush) == false)

        #expect(supported.supportsSecondaryInvertRealDrawing(for: .smudge) == false)
    }

    @Test
    func legacyDualTipPhaseOneDemoPresetIDsStayStableForMigration() {
        #expect(BrushPreset.legacyDualTipPhaseOneDemoPresetIDs == Set([
            "builtin-dual-tip-tighten",
            "builtin-dual-tip-soft-compress",
            "builtin-dual-tip-strong-modulate"
        ]))
    }

    @Test
    func removingLegacyDualTipPhaseOneDemoPresetsDropsExamplesWithoutLosingCustomPresets() {
        var customBrush = BrushSettings.stageOneDefault
        customBrush.tipShape = .customRound
        let customPreset = BrushPreset(
            id: "custom-phase-one-check",
            name: "Custom Phase 1 Check",
            brush: customBrush,
            isBuiltIn: false,
            slotIndex: 6
        )

        let restoredLikeLibrary = BrushLibraryState(
            presets: [
                BrushPreset(
                    id: "builtin-dual-tip-tighten",
                    name: "Old Builtin Copy",
                    brush: .stageOneDefault,
                    isBuiltIn: false,
                    slotIndex: 99
                ),
                customPreset
            ],
            selectedPresetID: "builtin-dual-tip-tighten"
        )

        let filtered = restoredLikeLibrary.removingLegacyDualTipPhaseOneDemoPresets()

        #expect(filtered.presets.count == 1)
        #expect(filtered.presets.first?.id == customPreset.id)
        #expect(filtered.selectedPresetID == customPreset.id)
    }

    @Test
    func legacyDualTipPhaseOneDemoDetectionOnlyAppliesToKnownIDs() {
        let legacyPreset = BrushPreset(
            id: "builtin-dual-tip-tighten",
            name: "Legacy Dual Tip",
            brush: .stageOneDefault,
            isBuiltIn: false,
            slotIndex: 9
        )

        #expect(legacyPreset.isLegacyDualTipPhaseOneDemoPreset)

        let customPreset = BrushPreset(
            id: "custom-test-preset",
            name: "Custom Test",
            brush: .stageOneDefault,
            isBuiltIn: false,
            slotIndex: 9
        )

        #expect(customPreset.isLegacyDualTipPhaseOneDemoPreset == false)
    }
}

import Foundation
import Testing
@testable import ArtFlex

struct TextureFillLibraryTests {
    @Test
    func resourceManagementSupportsFavoriteRenameDuplicateReplaceAndUndoDelete() throws {
        var settings = TextureFillTipSettings.proceduralDefault
        settings.coverage = 0.42
        let original = TextureFillLibraryItem(
            displayName: "颗粒纹理",
            slotIndex: 0,
            settings: settings,
            sourceBrush: .stageOneDefault
        )
        var library = TextureFillLibraryState(items: [original], selectedItemID: original.id)

        library.setFavorite(true, forItemID: original.id)
        #expect(library.item(id: original.id)?.isFavorite == true)
        let didRename = library.renameItem(id: original.id, to: "  粗颗粒  ")
        #expect(didRename)
        #expect(library.item(id: original.id)?.displayName == "粗颗粒")

        let duplicateCandidate = library.duplicateItem(id: original.id)
        let duplicate = try #require(duplicateCandidate)
        #expect(duplicate.id != original.id)
        #expect(duplicate.isFavorite == false)
        settings.coverage = 0.81
        let replacedCandidate = library.replaceItem(
            id: duplicate.id,
            settings: settings,
            sourceBrush: .stageOneDefault
        )
        let replaced = try #require(replacedCandidate)
        #expect(replaced.settings.coverage == 0.81)
        let didDelete = library.removeItem(id: duplicate.id)
        #expect(didDelete)
        #expect(library.deletedItems.map(\.id) == [duplicate.id])

        let restoredCandidate = library.restoreMostRecentlyDeletedItem()
        let restored = try #require(restoredCandidate)
        #expect(restored.id == duplicate.id)
        #expect(restored.settings.coverage == 0.81)
        #expect(library.selectedItemID == duplicate.id)
    }

    @Test
    func savingTextureCapturesDistinctSettingsAndAvoidsExactDuplicates() {
        var library = TextureFillLibraryState()
        var brush = BrushSettings.stageOneDefault
        brush.size = 37
        var settings = TextureFillTipSettings.proceduralDefault
        settings.arrangement = .interwoven
        settings.materialScale = 1.42
        settings.coverage = 0.73
        settings.variation = 0.28
        settings.paintJitterAmount = 0.61

        let first = library.saveCurrentTexture(settings: settings, sourceBrush: brush)
        let duplicate = library.saveCurrentTexture(settings: settings, sourceBrush: brush)

        #expect(first.id == duplicate.id)
        #expect(library.items.count == 1)
        #expect(library.selectedItemID == first.id)
        #expect(first.sourceBrush?.size == 37)
        #expect(first.settings.arrangement == .interwoven)
        #expect(first.settings.paintJitterAmount == 0.61)

        settings.coverage = 0.74
        let second = library.saveCurrentTexture(settings: settings, sourceBrush: brush)

        #expect(second.id != first.id)
        #expect(library.items.count == 2)
        #expect(library.item(atSlot: 0)?.id == first.id)
        #expect(library.item(atSlot: 1)?.id == second.id)
    }

    @Test
    func slotsRecentItemsColorTagsAndDeletionFollowExistingLibrarySemantics() {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        var library = TextureFillLibraryState(items: [
            TextureFillLibraryItem(
                id: firstID,
                displayName: "A",
                slotIndex: 0,
                settings: .proceduralDefault,
                sourceBrush: .stageOneDefault
            ),
            TextureFillLibraryItem(
                id: secondID,
                displayName: "B",
                slotIndex: 1,
                settings: .proceduralDefault,
                sourceBrush: .stageOneDefault
            )
        ])

        let moved = library.moveItem(id: firstID, toSlot: 1)
        #expect(moved)
        #expect(library.item(atSlot: 0)?.id == secondID)
        #expect(library.item(atSlot: 1)?.id == firstID)

        library.noteItemUsed(firstID)
        library.noteItemUsed(secondID)
        library.noteItemUsed(firstID)
        #expect(library.recentItems().map(\.id) == [firstID, secondID])

        library.setColorTag(.cyan, forItemID: firstID)
        #expect(library.item(id: firstID)?.colorTag == .cyan)

        library.selectItem(id: firstID)
        let removed = library.removeItem(id: firstID)
        #expect(removed)
        #expect(library.selectedItemID == secondID)
        #expect(library.recentItems().map(\.id) == [secondID])
    }

    @Test
    func persistenceRoundTripKeepsImportedMaskAndBrushSnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtFlexTextureFillLibraryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let controller = TextureFillLibraryPersistenceController(rootDirectoryURL: root)
        var importedSettings = TextureFillTipSettings.proceduralDefault
        importedSettings.sourceSemantic = .importedImage
        importedSettings.customTipMaskData = Data([0, 64, 128, 255])
        importedSettings.importedSourceInfo = ImportedTipSourceInfo(
            sourceLabel: "texture.png",
            pixelWidth: 2,
            pixelHeight: 2
        )
        var brush = BrushSettings.stageOneDefault
        brush.size = 83

        let library = TextureFillLibraryState(items: [
            TextureFillLibraryItem(
                displayName: "导入纹理",
                slotIndex: 0,
                settings: importedSettings,
                sourceBrush: brush
            ),
            TextureFillLibraryItem(
                displayName: "画笔纹理",
                slotIndex: 1,
                settings: .proceduralDefault,
                sourceBrush: brush
            )
        ])

        try controller.saveLibrary(library)

        #expect(controller.loadLibrary() == library)
    }

    @Test
    func workspaceDecodingDefaultsMissingTextureLibraryForBackwardCompatibility() throws {
        let encoder = JSONEncoder()
        let encoded = try encoder.encode(WorkspaceState.stageOneDefault)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "textureFillLibrary")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(WorkspaceState.self, from: legacyData)

        #expect(decoded.textureFillLibrary == .init())
    }

    @Test
    @MainActor
    func viewModelSavesAppliesAndRestoresTextureWithoutReplacingCurrentBrush() async throws {
        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal is required to validate texture library integration.")
            return
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtFlexTextureFillViewModelTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = TextureFillLibraryPersistenceController(rootDirectoryURL: root)
        let bootstrap = try AppBootstrap(
            workspaceStore: WorkspaceStore(),
            metalContext: metalContext,
            layerSurfaceStore: StageOneLayerSurfaceStore(),
            textureFillLibraryPersistenceController: controller
        )
        let viewModel = WorkspaceViewModel(
            bootstrap: bootstrap,
            installsZoomKeyboardMonitor: false,
            preparesInitialTextures: false
        )

        viewModel.setBrushSize(91)
        viewModel.setTextureFillArrangement(.radial)
        viewModel.setTextureFillCoverage(0.76)
        viewModel.setTextureFillPaintJitterAmount(0.68)
        viewModel.saveCurrentTextureFillPreset()

        let item = try #require(viewModel.workspace.textureFillLibrary.items.first)
        #expect(item.sourceBrush?.size == 91)
        #expect(item.settings.arrangement == .radial)
        #expect(item.settings.coverage == 0.76)
        #expect(item.settings.paintJitterAmount == 0.68)

        viewModel.setBrushSize(12)
        viewModel.applyTextureFillLibraryItem(item.id)

        #expect(viewModel.workspace.toolSession.activeTool == .textureFill)
        #expect(viewModel.workspace.toolSession.drawingBrush.size == 12)
        #expect(viewModel.workspace.toolSession.textureFillBrushOverride?.size == 91)
        #expect(viewModel.textureFillPreviewBrush.size == 91)
        #expect(viewModel.workspace.toolSession.textureFillTip.paintJitterAmount == 0.68)

        var persisted = controller.loadLibrary()
        for _ in 0..<20 where persisted?.items.first?.id != item.id {
            try await Task.sleep(for: .milliseconds(50))
            persisted = controller.loadLibrary()
        }
        #expect(persisted?.items.first?.id == item.id)

        let restoredBootstrap = try AppBootstrap(
            workspaceStore: WorkspaceStore(),
            metalContext: metalContext,
            layerSurfaceStore: StageOneLayerSurfaceStore(),
            textureFillLibraryPersistenceController: controller
        )
        let restoredViewModel = WorkspaceViewModel(
            bootstrap: restoredBootstrap,
            installsZoomKeyboardMonitor: false,
            preparesInitialTextures: false
        )
        #expect(restoredViewModel.workspace.textureFillLibrary.items.first?.id == item.id)
        #expect(restoredViewModel.workspace.textureFillLibrary.items.first?.settings.paintJitterAmount == 0.68)
    }
}

import Foundation
import Testing
@testable import ArtFlex

struct PatternLibraryStateTests {
    @Test
    func resourceManagementSupportsFavoriteRenameDuplicateAndUndoDelete() throws {
        let original = PatternLibraryItem(
            displayName: "格纹",
            slotIndex: 0,
            importRecipe: PatternImportRecipe(),
            originalFilename: "grid.png",
            sourcePixelWidth: 400,
            sourcePixelHeight: 200,
            renderAssetLocation: .managedCopy(relativePath: "render/grid.png"),
            thumbnailLocation: .managedCopy(relativePath: "thumb/grid.png")
        )
        var library = PatternLibraryState(items: [original], selectedItemID: original.id)

        library.setFavorite(true, forItemID: original.id)
        #expect(library.item(id: original.id)?.isFavorite == true)
        let didRename = library.renameItem(id: original.id, to: "  建筑格纹  ")
        #expect(didRename)
        #expect(library.item(id: original.id)?.displayName == "建筑格纹")

        let duplicateCandidate = library.duplicateItem(id: original.id)
        let duplicate = try #require(duplicateCandidate)
        #expect(duplicate.id != original.id)
        #expect(duplicate.isFavorite == false)
        #expect(duplicate.renderAssetLocation == original.renderAssetLocation)
        let didDelete = library.removeItem(id: duplicate.id)
        #expect(didDelete)
        #expect(library.deletedItems.map(\.id) == [duplicate.id])

        let restoredCandidate = library.restoreMostRecentlyDeletedItem()
        let restored = try #require(restoredCandidate)
        #expect(restored.id == duplicate.id)
        #expect(library.selectedItemID == duplicate.id)
        #expect(library.deletedItems.isEmpty)
    }

    @Test
    func legacyPatternLibraryJSONDefaultsNewManagementFields() throws {
        let original = PatternLibraryItem(
            displayName: "旧图案",
            importRecipe: PatternImportRecipe(),
            originalFilename: "legacy.png",
            sourcePixelWidth: 64,
            sourcePixelHeight: 64,
            renderAssetLocation: .managedCopy(relativePath: "render/legacy.png"),
            thumbnailLocation: .managedCopy(relativePath: "thumb/legacy.png")
        )
        let encoded = try JSONEncoder().encode(PatternLibraryState(items: [original]))
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "deletedItems")
        var items = try #require(object["items"] as? [[String: Any]])
        items[0].removeValue(forKey: "isFavorite")
        object["items"] = items

        let decoded = try JSONDecoder().decode(
            PatternLibraryState.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.items.first?.isFavorite == false)
        #expect(decoded.deletedItems.isEmpty)
    }

    @Test
    func resolvedSlotMapRespectsRequestedSlotsAndBackfillsUnassignedItems() {
        let first = PatternLibraryItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            displayName: "A",
            slotIndex: 2,
            importRecipe: PatternImportRecipe(),
            originalFilename: "a.png",
            sourcePixelWidth: 64,
            sourcePixelHeight: 64,
            renderAssetLocation: .managedCopy(relativePath: "render/a.png"),
            thumbnailLocation: .managedCopy(relativePath: "thumb/a.png")
        )
        let second = PatternLibraryItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            displayName: "B",
            importRecipe: PatternImportRecipe(),
            originalFilename: "b.png",
            sourcePixelWidth: 64,
            sourcePixelHeight: 64,
            renderAssetLocation: .managedCopy(relativePath: "render/b.png"),
            thumbnailLocation: .managedCopy(relativePath: "thumb/b.png")
        )
        let third = PatternLibraryItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            displayName: "C",
            slotIndex: 0,
            importRecipe: PatternImportRecipe(),
            originalFilename: "c.png",
            sourcePixelWidth: 64,
            sourcePixelHeight: 64,
            renderAssetLocation: .managedCopy(relativePath: "render/c.png"),
            thumbnailLocation: .managedCopy(relativePath: "thumb/c.png")
        )

        let state = PatternLibraryState(items: [first, second, third])
        let map = state.resolvedSlotMap()

        #expect(map[0]?.id == third.id)
        #expect(map[3]?.id == second.id)
        #expect(map[2]?.id == first.id)
    }

    @Test
    func firstEmptySlotAndSlotCountReflectOccupiedSlots() {
        let state = PatternLibraryState(
            items: [
                PatternLibraryItem(
                    displayName: "A",
                    slotIndex: 0,
                    importRecipe: PatternImportRecipe(),
                    originalFilename: "a.png",
                    sourcePixelWidth: 32,
                    sourcePixelHeight: 32,
                    renderAssetLocation: .managedCopy(relativePath: "render/a.png"),
                    thumbnailLocation: .managedCopy(relativePath: "thumb/a.png")
                ),
                PatternLibraryItem(
                    displayName: "B",
                    slotIndex: 3,
                    importRecipe: PatternImportRecipe(),
                    originalFilename: "b.png",
                    sourcePixelWidth: 32,
                    sourcePixelHeight: 32,
                    renderAssetLocation: .managedCopy(relativePath: "render/b.png"),
                    thumbnailLocation: .managedCopy(relativePath: "thumb/b.png")
                )
            ]
        )

        #expect(state.firstEmptySlotIndex() == 1)
        #expect(state.slotCount(minRows: 2, columns: 4) == 8)
    }

    @Test
    func moveItemSwapsOccupiedSlots() {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!

        var state = PatternLibraryState(
            items: [
                PatternLibraryItem(
                    id: firstID,
                    displayName: "A",
                    slotIndex: 0,
                    importRecipe: PatternImportRecipe(),
                    originalFilename: "a.png",
                    sourcePixelWidth: 32,
                    sourcePixelHeight: 32,
                    renderAssetLocation: .managedCopy(relativePath: "render/a.png"),
                    thumbnailLocation: .managedCopy(relativePath: "thumb/a.png")
                ),
                PatternLibraryItem(
                    id: secondID,
                    displayName: "B",
                    slotIndex: 1,
                    importRecipe: PatternImportRecipe(),
                    originalFilename: "b.png",
                    sourcePixelWidth: 32,
                    sourcePixelHeight: 32,
                    renderAssetLocation: .managedCopy(relativePath: "render/b.png"),
                    thumbnailLocation: .managedCopy(relativePath: "thumb/b.png")
                )
            ]
        )

        let moved = state.moveItem(id: firstID, toSlot: 1)

        #expect(moved)
        #expect(state.item(atSlot: 0)?.id == secondID)
        #expect(state.item(atSlot: 1)?.id == firstID)
    }

    @Test
    func removeItemRemapsSelectionWhenSelectedItemIsDeleted() {
        let first = PatternLibraryItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
            displayName: "A",
            slotIndex: 0,
            importRecipe: PatternImportRecipe(),
            originalFilename: "a.png",
            sourcePixelWidth: 32,
            sourcePixelHeight: 32,
            renderAssetLocation: .managedCopy(relativePath: "render/a.png"),
            thumbnailLocation: .managedCopy(relativePath: "thumb/a.png")
        )
        let second = PatternLibraryItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
            displayName: "B",
            slotIndex: 1,
            importRecipe: PatternImportRecipe(),
            originalFilename: "b.png",
            sourcePixelWidth: 32,
            sourcePixelHeight: 32,
            renderAssetLocation: .managedCopy(relativePath: "render/b.png"),
            thumbnailLocation: .managedCopy(relativePath: "thumb/b.png")
        )

        var state = PatternLibraryState(items: [first, second], selectedItemID: second.id)
        let removed = state.removeItem(id: second.id)

        #expect(removed)
        #expect(state.items.count == 1)
        #expect(state.selectedItemID == first.id)
    }

    @Test
    func colorTagAndRecentUsagePersistOnLibraryState() {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000030")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000031")!
        let thirdID = UUID(uuidString: "00000000-0000-0000-0000-000000000032")!
        let fourthID = UUID(uuidString: "00000000-0000-0000-0000-000000000033")!
        let fifthID = UUID(uuidString: "00000000-0000-0000-0000-000000000034")!

        var state = PatternLibraryState(
            items: [
                PatternLibraryItem(
                    id: firstID,
                    displayName: "A",
                    importRecipe: PatternImportRecipe(),
                    originalFilename: "a.png",
                    sourcePixelWidth: 32,
                    sourcePixelHeight: 32,
                    renderAssetLocation: .managedCopy(relativePath: "render/a.png"),
                    thumbnailLocation: .managedCopy(relativePath: "thumb/a.png")
                ),
                PatternLibraryItem(
                    id: secondID,
                    displayName: "B",
                    importRecipe: PatternImportRecipe(),
                    originalFilename: "b.png",
                    sourcePixelWidth: 32,
                    sourcePixelHeight: 32,
                    renderAssetLocation: .managedCopy(relativePath: "render/b.png"),
                    thumbnailLocation: .managedCopy(relativePath: "thumb/b.png")
                ),
                PatternLibraryItem(
                    id: thirdID,
                    displayName: "C",
                    importRecipe: PatternImportRecipe(),
                    originalFilename: "c.png",
                    sourcePixelWidth: 32,
                    sourcePixelHeight: 32,
                    renderAssetLocation: .managedCopy(relativePath: "render/c.png"),
                    thumbnailLocation: .managedCopy(relativePath: "thumb/c.png")
                ),
                PatternLibraryItem(
                    id: fourthID,
                    displayName: "D",
                    importRecipe: PatternImportRecipe(),
                    originalFilename: "d.png",
                    sourcePixelWidth: 32,
                    sourcePixelHeight: 32,
                    renderAssetLocation: .managedCopy(relativePath: "render/d.png"),
                    thumbnailLocation: .managedCopy(relativePath: "thumb/d.png")
                ),
                PatternLibraryItem(
                    id: fifthID,
                    displayName: "E",
                    importRecipe: PatternImportRecipe(),
                    originalFilename: "e.png",
                    sourcePixelWidth: 32,
                    sourcePixelHeight: 32,
                    renderAssetLocation: .managedCopy(relativePath: "render/e.png"),
                    thumbnailLocation: .managedCopy(relativePath: "thumb/e.png")
                )
            ]
        )

        state.setColorTag(.blue, forItemID: secondID)
        state.noteItemUsed(secondID)
        state.noteItemUsed(fourthID)
        state.noteItemUsed(firstID)
        state.noteItemUsed(fifthID)
        state.noteItemUsed(thirdID)

        #expect(state.item(id: secondID)?.colorTag == .blue)
        #expect(state.recentItemIDs == [thirdID, fifthID, firstID, fourthID])
        #expect(state.recentItems().map(\.id) == [thirdID, fifthID, firstID, fourthID])
    }

    @Test
    func patternImportMergePreservesConcurrentTagMoveAndDeleteEdits() {
        let kept = makePatternMergeItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000040")!,
            name: "A",
            slotIndex: 0,
            renderPath: "renders/a.png"
        )
        let deleted = makePatternMergeItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000041")!,
            name: "B",
            slotIndex: 1,
            renderPath: "renders/b.png"
        )
        let imported = makePatternMergeItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000042")!,
            name: "C",
            slotIndex: 2,
            renderPath: "renders/c.png"
        )
        var currentLibrary = PatternLibraryState(items: [kept, deleted], selectedItemID: deleted.id)
        currentLibrary.setColorTag(.purple, forItemID: kept.id)
        let didMove = currentLibrary.moveItem(id: kept.id, toSlot: 4)
        let didRemove = currentLibrary.removeItem(id: deleted.id)
        #expect(didMove)
        #expect(didRemove)

        let staleImportResult = PatternLibraryImportBatchResult(
            updatedLibrary: PatternLibraryState(items: [kept, deleted, imported], selectedItemID: imported.id),
            importedItems: [imported],
            skippedDuplicateCount: 0,
            failedFileNames: []
        )

        let mergedResult = WorkspaceViewModel.mergedPatternImportResult(
            staleImportResult,
            into: currentLibrary
        )

        #expect(mergedResult.updatedLibrary.item(id: kept.id)?.colorTag == .purple)
        #expect(mergedResult.updatedLibrary.item(id: kept.id)?.slotIndex == 4)
        #expect(mergedResult.updatedLibrary.item(id: deleted.id) == nil)
        #expect(mergedResult.updatedLibrary.item(id: imported.id)?.slotIndex == 0)
        #expect(mergedResult.updatedLibrary.selectedItemID == imported.id)
        #expect(mergedResult.importedItems.map(\.id) == [imported.id])
    }

    @Test
    func patternImportMergeSkipsItemsAlreadyPresentInCurrentLibrary() {
        let imported = makePatternMergeItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000050")!,
            name: "Imported",
            slotIndex: 0,
            renderPath: "renders/shared.png"
        )
        let concurrentImported = makePatternMergeItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000051")!,
            name: "Concurrent",
            slotIndex: 3,
            renderPath: "renders/shared.png"
        )
        let currentLibrary = PatternLibraryState(
            items: [concurrentImported],
            selectedItemID: concurrentImported.id
        )
        let staleImportResult = PatternLibraryImportBatchResult(
            updatedLibrary: PatternLibraryState(items: [imported], selectedItemID: imported.id),
            importedItems: [imported],
            skippedDuplicateCount: 1,
            failedFileNames: []
        )

        let mergedResult = WorkspaceViewModel.mergedPatternImportResult(
            staleImportResult,
            into: currentLibrary
        )

        #expect(mergedResult.updatedLibrary.items.map(\.id) == [concurrentImported.id])
        #expect(mergedResult.updatedLibrary.selectedItemID == concurrentImported.id)
        #expect(mergedResult.importedItems.isEmpty)
        #expect(mergedResult.skippedDuplicateCount == 2)
    }
}

private func makePatternMergeItem(
    id: UUID,
    name: String,
    slotIndex: Int?,
    renderPath: String
) -> PatternLibraryItem {
    PatternLibraryItem(
        id: id,
        displayName: name,
        slotIndex: slotIndex,
        importRecipe: PatternImportRecipe(),
        originalFilename: "\(name).png",
        sourcePixelWidth: 32,
        sourcePixelHeight: 32,
        renderAssetLocation: .managedCopy(relativePath: renderPath),
        thumbnailLocation: .managedCopy(relativePath: renderPath.replacingOccurrences(of: "renders", with: "thumbs"))
    )
}

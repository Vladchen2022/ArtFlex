import Foundation
import Testing
@testable import ArtFlex

struct PatternLibraryStateTests {
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
}

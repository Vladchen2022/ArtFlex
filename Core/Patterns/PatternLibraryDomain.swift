import Foundation
import CoreGraphics

enum PatternImportMode: String, Codable, Sendable, Equatable {
    case originalColor
    case transparentMonochrome
}

struct PatternImportRecipe: Codable, Sendable, Equatable {
    var mode: PatternImportMode
    var contrast: Float
    var autoCropToContent: Bool

    init(
        mode: PatternImportMode = .originalColor,
        contrast: Float = 0,
        autoCropToContent: Bool = false
    ) {
        self.mode = mode
        self.contrast = contrast
        self.autoCropToContent = autoCropToContent
    }
}

enum PatternAssetLocation: Codable, Sendable, Equatable {
    case managedCopy(relativePath: String)
    case externalReference(bookmarkData: Data)
}

struct PatternLibraryItem: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var displayName: String
    var slotIndex: Int?
    var importRecipe: PatternImportRecipe
    var originalFilename: String
    var sourcePixelWidth: Int
    var sourcePixelHeight: Int
    var renderAssetLocation: PatternAssetLocation
    var thumbnailLocation: PatternAssetLocation

    init(
        id: UUID = UUID(),
        displayName: String,
        slotIndex: Int? = nil,
        importRecipe: PatternImportRecipe,
        originalFilename: String,
        sourcePixelWidth: Int,
        sourcePixelHeight: Int,
        renderAssetLocation: PatternAssetLocation,
        thumbnailLocation: PatternAssetLocation
    ) {
        self.id = id
        self.displayName = displayName
        self.slotIndex = slotIndex
        self.importRecipe = importRecipe
        self.originalFilename = originalFilename
        self.sourcePixelWidth = sourcePixelWidth
        self.sourcePixelHeight = sourcePixelHeight
        self.renderAssetLocation = renderAssetLocation
        self.thumbnailLocation = thumbnailLocation
    }
}

struct PatternLibraryState: Codable, Sendable, Equatable {
    var items: [PatternLibraryItem]
    var selectedItemID: UUID?

    init(
        items: [PatternLibraryItem] = [],
        selectedItemID: UUID? = nil
    ) {
        self.items = items
        self.selectedItemID = selectedItemID
    }

    func resolvedSlotMap() -> [Int: PatternLibraryItem] {
        var result: [Int: PatternLibraryItem] = [:]
        var nextFree = 0

        let sorted = items.sorted { lhs, rhs in
            let l = lhs.slotIndex ?? Int.max
            let r = rhs.slotIndex ?? Int.max
            if l != r { return l < r }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        for item in sorted {
            if let requested = item.slotIndex, result[requested] == nil {
                result[requested] = item
                nextFree = max(nextFree, requested + 1)
                continue
            }

            while result[nextFree] != nil {
                nextFree += 1
            }
            result[nextFree] = item
            nextFree += 1
        }

        return result
    }

    func item(id: UUID) -> PatternLibraryItem? {
        items.first(where: { $0.id == id })
    }

    func item(atSlot slot: Int) -> PatternLibraryItem? {
        resolvedSlotMap()[slot]
    }

    func firstEmptySlotIndex() -> Int {
        let map = resolvedSlotMap()
        var index = 0
        while map[index] != nil {
            index += 1
        }
        return index
    }

    func slotCount(minRows: Int = 2, columns: Int = 4) -> Int {
        precondition(columns > 0)
        let minimum = max(minRows, 1) * columns
        let occupied = (resolvedSlotMap().keys.max() ?? -1) + 1
        let needed = max(minimum, occupied)
        let remainder = needed % columns
        return remainder == 0 ? needed : (needed + (columns - remainder))
    }

    mutating func selectItem(id: UUID?) {
        selectedItemID = id
    }

    mutating func moveItem(id: UUID, toSlot targetSlot: Int) -> Bool {
        guard targetSlot >= 0 else { return false }
        var itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let map = resolvedSlotMap()

        guard let moving = itemsByID[id] else { return false }
        let sourceSlot = map.first(where: { $0.value.id == id })?.key
        let targetItem = map[targetSlot]

        var updatedMoving = moving
        updatedMoving.slotIndex = targetSlot
        itemsByID[id] = updatedMoving

        if let targetItem, let sourceSlot {
            var swapped = targetItem
            swapped.slotIndex = sourceSlot
            itemsByID[targetItem.id] = swapped
        }

        items = Array(itemsByID.values)
        return true
    }

    mutating func removeItem(id: UUID) -> Bool {
        guard items.contains(where: { $0.id == id }) else { return false }
        items.removeAll { $0.id == id }
        if selectedItemID == id {
            selectedItemID = items.first?.id
        }
        return true
    }
}

enum PatternPlacementPhase: Sendable, Equatable {
    case idle
    case armed(itemID: UUID)
    case dragging(PatternPlacementDraft)
}

struct PatternPlacementDraft: Sendable, Equatable {
    var itemID: UUID
    var startCanvasPoint: CGPoint
    var currentCanvasPoint: CGPoint
    var destinationRect: CGRect

    init(
        itemID: UUID,
        startCanvasPoint: CGPoint,
        currentCanvasPoint: CGPoint,
        destinationRect: CGRect
    ) {
        self.itemID = itemID
        self.startCanvasPoint = startCanvasPoint
        self.currentCanvasPoint = currentCanvasPoint
        self.destinationRect = destinationRect
    }
}

struct PatternImportSheetState: Sendable, Equatable {
    var isPresented: Bool
    var selectedFileURLs: [URL]
    var previewFileURL: URL?
    var recipe: PatternImportRecipe

    init(
        isPresented: Bool = false,
        selectedFileURLs: [URL] = [],
        previewFileURL: URL? = nil,
        recipe: PatternImportRecipe = PatternImportRecipe()
    ) {
        self.isPresented = isPresented
        self.selectedFileURLs = selectedFileURLs
        self.previewFileURL = previewFileURL
        self.recipe = recipe
    }
}

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
    var colorTag: BrushColorTag?
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
        colorTag: BrushColorTag? = nil,
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
        self.colorTag = colorTag
        self.importRecipe = importRecipe
        self.originalFilename = originalFilename
        self.sourcePixelWidth = sourcePixelWidth
        self.sourcePixelHeight = sourcePixelHeight
        self.renderAssetLocation = renderAssetLocation
        self.thumbnailLocation = thumbnailLocation
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case slotIndex
        case colorTag
        case importRecipe
        case originalFilename
        case sourcePixelWidth
        case sourcePixelHeight
        case renderAssetLocation
        case thumbnailLocation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        slotIndex = try container.decodeIfPresent(Int.self, forKey: .slotIndex)
        colorTag = try container.decodeIfPresent(BrushColorTag.self, forKey: .colorTag)
        importRecipe = try container.decode(PatternImportRecipe.self, forKey: .importRecipe)
        originalFilename = try container.decode(String.self, forKey: .originalFilename)
        sourcePixelWidth = try container.decode(Int.self, forKey: .sourcePixelWidth)
        sourcePixelHeight = try container.decode(Int.self, forKey: .sourcePixelHeight)
        renderAssetLocation = try container.decode(PatternAssetLocation.self, forKey: .renderAssetLocation)
        thumbnailLocation = try container.decode(PatternAssetLocation.self, forKey: .thumbnailLocation)
    }
}

struct PatternLibraryState: Codable, Sendable, Equatable {
    var items: [PatternLibraryItem]
    var selectedItemID: UUID?
    var recentItemIDs: [UUID]

    init(
        items: [PatternLibraryItem] = [],
        selectedItemID: UUID? = nil,
        recentItemIDs: [UUID] = []
    ) {
        self.items = items
        self.selectedItemID = selectedItemID
        self.recentItemIDs = recentItemIDs
    }

    private enum CodingKeys: String, CodingKey {
        case items
        case selectedItemID
        case recentItemIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([PatternLibraryItem].self, forKey: .items)
        selectedItemID = try container.decodeIfPresent(UUID.self, forKey: .selectedItemID)
        recentItemIDs = try container.decodeIfPresent([UUID].self, forKey: .recentItemIDs) ?? []
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

    mutating func setColorTag(_ tag: BrushColorTag?, forItemID id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].colorTag = tag
    }

    mutating func noteItemUsed(_ id: UUID, limit: Int = 4) {
        guard items.contains(where: { $0.id == id }) else { return }
        recentItemIDs.removeAll { $0 == id }
        recentItemIDs.insert(id, at: 0)
        if recentItemIDs.count > limit {
            recentItemIDs.removeLast(recentItemIDs.count - limit)
        }
    }

    func recentItems(limit: Int = 4) -> [PatternLibraryItem] {
        Array(recentItemIDs.prefix(limit)).compactMap { id in
            item(id: id)
        }
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
        recentItemIDs.removeAll { $0 == id }
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

    var itemID: UUID? {
        switch self {
        case .idle:
            return nil
        case .armed(let itemID):
            return itemID
        case .dragging(let draft):
            return draft.itemID
        }
    }

    var draft: PatternPlacementDraft? {
        guard case .dragging(let draft) = self else { return nil }
        return draft
    }
}

struct PatternPlacementDraft: Sendable, Equatable {
    var itemID: UUID
    var startCanvasPoint: CanvasPoint
    var currentCanvasPoint: CanvasPoint
    var destinationRect: CGRect
    var placementModeAtDragStart: PatternPlacementModeAtDragStart

    init(
        itemID: UUID,
        startCanvasPoint: CanvasPoint,
        currentCanvasPoint: CanvasPoint,
        destinationRect: CGRect,
        placementModeAtDragStart: PatternPlacementModeAtDragStart = .currentLayer
    ) {
        self.itemID = itemID
        self.startCanvasPoint = startCanvasPoint
        self.currentCanvasPoint = currentCanvasPoint
        self.destinationRect = destinationRect
        self.placementModeAtDragStart = placementModeAtDragStart
    }

    var flipsHorizontally: Bool {
        currentCanvasPoint.x < startCanvasPoint.x
    }

    static func destinationRect(
        startCanvasPoint: CanvasPoint,
        currentCanvasPoint: CanvasPoint
    ) -> CGRect {
        CGRect(
            x: min(startCanvasPoint.x, currentCanvasPoint.x),
            y: min(startCanvasPoint.y, currentCanvasPoint.y),
            width: abs(currentCanvasPoint.x - startCanvasPoint.x),
            height: abs(currentCanvasPoint.y - startCanvasPoint.y)
        )
    }
}

enum PatternPlacementModeAtDragStart: Sendable, Equatable {
    case currentLayer
    case newLayer
}

struct PatternImportSheetState: Sendable, Equatable {
    var isPresented: Bool
    var selectedFileURLs: [URL]
    var previewFileURL: URL?
    var recipe: PatternImportRecipe
    var eraserRadius: Float
    var usesSoftEdgeEraser: Bool
    var softEdgeEraserAmount: Float

    init(
        isPresented: Bool = false,
        selectedFileURLs: [URL] = [],
        previewFileURL: URL? = nil,
        recipe: PatternImportRecipe = PatternImportRecipe(),
        eraserRadius: Float = 18,
        usesSoftEdgeEraser: Bool = false,
        softEdgeEraserAmount: Float = 0.75
    ) {
        self.isPresented = isPresented
        self.selectedFileURLs = selectedFileURLs
        self.previewFileURL = previewFileURL
        self.recipe = recipe
        self.eraserRadius = eraserRadius
        self.usesSoftEdgeEraser = usesSoftEdgeEraser
        self.softEdgeEraserAmount = softEdgeEraserAmount
    }
}

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
    var isFavorite: Bool
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
        isFavorite: Bool = false,
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
        self.isFavorite = isFavorite
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
        case isFavorite
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
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
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
    var deletedItems: [PatternLibraryItem]

    init(
        items: [PatternLibraryItem] = [],
        selectedItemID: UUID? = nil,
        recentItemIDs: [UUID] = [],
        deletedItems: [PatternLibraryItem] = []
    ) {
        self.items = items
        self.selectedItemID = selectedItemID
        self.recentItemIDs = recentItemIDs
        self.deletedItems = deletedItems
    }

    private enum CodingKeys: String, CodingKey {
        case items
        case selectedItemID
        case recentItemIDs
        case deletedItems
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([PatternLibraryItem].self, forKey: .items)
        selectedItemID = try container.decodeIfPresent(UUID.self, forKey: .selectedItemID)
        recentItemIDs = try container.decodeIfPresent([UUID].self, forKey: .recentItemIDs) ?? []
        deletedItems = try container.decodeIfPresent([PatternLibraryItem].self, forKey: .deletedItems) ?? []
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

    mutating func setFavorite(_ isFavorite: Bool, forItemID id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isFavorite = isFavorite
    }

    mutating func renameItem(id: UUID, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = items.firstIndex(where: { $0.id == id }) else {
            return false
        }
        items[index].displayName = trimmed
        return true
    }

    mutating func duplicateItem(id: UUID) -> PatternLibraryItem? {
        guard var duplicate = item(id: id) else { return nil }
        duplicate.id = UUID()
        duplicate.displayName += " 副本"
        duplicate.slotIndex = firstEmptySlotIndex()
        duplicate.isFavorite = false
        items.append(duplicate)
        selectedItemID = duplicate.id
        return duplicate
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
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        deletedItems.append(items.remove(at: index))
        if deletedItems.count > 12 {
            deletedItems.removeFirst(deletedItems.count - 12)
        }
        recentItemIDs.removeAll { $0 == id }
        if selectedItemID == id {
            selectedItemID = items.first?.id
        }
        return true
    }

    mutating func restoreMostRecentlyDeletedItem() -> PatternLibraryItem? {
        guard var restoredItem = deletedItems.popLast() else { return nil }
        if let slotIndex = restoredItem.slotIndex, item(atSlot: slotIndex) != nil {
            restoredItem.slotIndex = firstEmptySlotIndex()
        }
        items.append(restoredItem)
        selectedItemID = restoredItem.id
        return restoredItem
    }
}

enum PatternPlacementPhase: Sendable, Equatable {
    case idle
    case armed(itemID: UUID)
    case dragging(PatternPlacementDraft)
    case adjusting(PatternPlacementDraft)
    case transforming(PatternPlacementTransformSession)

    var itemID: UUID? {
        switch self {
        case .idle:
            return nil
        case .armed(let itemID):
            return itemID
        case .dragging(let draft):
            return draft.itemID
        case .adjusting(let draft):
            return draft.itemID
        case .transforming(let session):
            return session.currentDraft.itemID
        }
    }

    var draft: PatternPlacementDraft? {
        switch self {
        case .dragging(let draft), .adjusting(let draft):
            return draft
        case .transforming(let session):
            return session.currentDraft
        case .idle, .armed:
            return nil
        }
    }

    var isAdjusting: Bool {
        switch self {
        case .adjusting, .transforming:
            return true
        case .idle, .armed, .dragging:
            return false
        }
    }
}

struct PatternPlacementDraft: Sendable, Equatable {
    var itemID: UUID
    var startCanvasPoint: CanvasPoint
    var currentCanvasPoint: CanvasPoint
    var destinationRect: CGRect
    var placementModeAtDragStart: PatternPlacementModeAtDragStart
    var sourceAspectRatio: Double
    var flipHorizontally: Bool
    var flipVertically: Bool
    var rotationDegrees: Double
    var opacity: Float

    init(
        itemID: UUID,
        startCanvasPoint: CanvasPoint,
        currentCanvasPoint: CanvasPoint,
        destinationRect: CGRect,
        placementModeAtDragStart: PatternPlacementModeAtDragStart = .currentLayer,
        sourceAspectRatio: Double = 1,
        flipHorizontally: Bool? = nil,
        flipVertically: Bool? = nil,
        rotationDegrees: Double = 0,
        opacity: Float = 1
    ) {
        self.itemID = itemID
        self.startCanvasPoint = startCanvasPoint
        self.currentCanvasPoint = currentCanvasPoint
        self.destinationRect = destinationRect
        self.placementModeAtDragStart = placementModeAtDragStart
        self.sourceAspectRatio = max(sourceAspectRatio, 0.000_001)
        self.flipHorizontally = flipHorizontally ?? (currentCanvasPoint.x < startCanvasPoint.x)
        self.flipVertically = flipVertically ?? (currentCanvasPoint.y < startCanvasPoint.y)
        self.rotationDegrees = rotationDegrees
        self.opacity = min(max(opacity, 0.05), 1)
    }

    var flipsHorizontally: Bool {
        flipHorizontally
    }

    static func destinationRect(
        startCanvasPoint: CanvasPoint,
        currentCanvasPoint: CanvasPoint,
        preservingAspectRatio aspectRatio: Double? = nil
    ) -> CGRect {
        let rawWidth = abs(currentCanvasPoint.x - startCanvasPoint.x)
        let rawHeight = abs(currentCanvasPoint.y - startCanvasPoint.y)
        let resolvedSize: (width: Double, height: Double)
        if let aspectRatio, aspectRatio.isFinite, aspectRatio > 0 {
            if rawWidth / aspectRatio >= rawHeight {
                resolvedSize = (rawWidth, rawWidth / aspectRatio)
            } else {
                resolvedSize = (rawHeight * aspectRatio, rawHeight)
            }
        } else {
            resolvedSize = (rawWidth, rawHeight)
        }

        return CGRect(
            x: currentCanvasPoint.x < startCanvasPoint.x
                ? startCanvasPoint.x - resolvedSize.width
                : startCanvasPoint.x,
            y: currentCanvasPoint.y < startCanvasPoint.y
                ? startCanvasPoint.y - resolvedSize.height
                : startCanvasPoint.y,
            width: resolvedSize.width,
            height: resolvedSize.height
        )
    }

    var rotatedCorners: [CanvasPoint] {
        let rect = destinationRect.standardized
        let center = CanvasPoint(x: rect.midX, y: rect.midY)
        let radians = rotationDegrees * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        return [
            CanvasPoint(x: rect.minX, y: rect.minY),
            CanvasPoint(x: rect.maxX, y: rect.minY),
            CanvasPoint(x: rect.maxX, y: rect.maxY),
            CanvasPoint(x: rect.minX, y: rect.maxY)
        ].map { point in
            let dx = point.x - center.x
            let dy = point.y - center.y
            return CanvasPoint(
                x: center.x + (dx * cosine) - (dy * sine),
                y: center.y + (dx * sine) + (dy * cosine)
            )
        }
    }
}

enum PatternPlacementTransformMode: Sendable, Equatable {
    case move
    case resize(oppositeAnchor: CanvasPoint)
}

struct PatternPlacementTransformSession: Sendable, Equatable {
    var originalDraft: PatternPlacementDraft
    var startCanvasPoint: CanvasPoint
    var currentDraft: PatternPlacementDraft
    var mode: PatternPlacementTransformMode
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

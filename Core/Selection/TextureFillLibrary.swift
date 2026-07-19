import Foundation

struct TextureFillLibraryItem: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var displayName: String
    var slotIndex: Int?
    var colorTag: BrushColorTag?
    var isFavorite: Bool
    var settings: TextureFillTipSettings
    var sourceBrush: BrushSettings?

    init(
        id: UUID = UUID(),
        displayName: String,
        slotIndex: Int? = nil,
        colorTag: BrushColorTag? = nil,
        isFavorite: Bool = false,
        settings: TextureFillTipSettings,
        sourceBrush: BrushSettings?
    ) {
        self.id = id
        self.displayName = displayName
        self.slotIndex = slotIndex
        self.colorTag = colorTag
        self.isFavorite = isFavorite
        self.settings = settings
        self.sourceBrush = sourceBrush
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case slotIndex
        case colorTag
        case isFavorite
        case settings
        case sourceBrush
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        slotIndex = try container.decodeIfPresent(Int.self, forKey: .slotIndex)
        colorTag = try container.decodeIfPresent(BrushColorTag.self, forKey: .colorTag)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        settings = try container.decode(TextureFillTipSettings.self, forKey: .settings)
        sourceBrush = try container.decodeIfPresent(BrushSettings.self, forKey: .sourceBrush)
    }
}

struct TextureFillLibraryState: Codable, Sendable, Equatable {
    var items: [TextureFillLibraryItem]
    var selectedItemID: UUID?
    var recentItemIDs: [UUID]
    var deletedItems: [TextureFillLibraryItem]

    init(
        items: [TextureFillLibraryItem] = [],
        selectedItemID: UUID? = nil,
        recentItemIDs: [UUID] = [],
        deletedItems: [TextureFillLibraryItem] = []
    ) {
        self.items = items
        self.selectedItemID = selectedItemID
        self.recentItemIDs = []
        self.deletedItems = deletedItems
        self.recentItemIDs = sanitizedRecentItemIDs(recentItemIDs)
    }

    private enum CodingKeys: String, CodingKey {
        case items
        case selectedItemID
        case recentItemIDs
        case deletedItems
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            items: try container.decodeIfPresent([TextureFillLibraryItem].self, forKey: .items) ?? [],
            selectedItemID: try container.decodeIfPresent(UUID.self, forKey: .selectedItemID),
            recentItemIDs: try container.decodeIfPresent([UUID].self, forKey: .recentItemIDs) ?? [],
            deletedItems: try container.decodeIfPresent([TextureFillLibraryItem].self, forKey: .deletedItems) ?? []
        )
    }

    func item(id: UUID) -> TextureFillLibraryItem? {
        items.first(where: { $0.id == id })
    }

    func resolvedSlotMap() -> [Int: TextureFillLibraryItem] {
        var result: [Int: TextureFillLibraryItem] = [:]
        var nextFree = 0

        let sorted = items.sorted { lhs, rhs in
            let leftSlot = lhs.slotIndex ?? Int.max
            let rightSlot = rhs.slotIndex ?? Int.max
            if leftSlot != rightSlot { return leftSlot < rightSlot }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        for item in sorted {
            if let requestedSlot = item.slotIndex,
               requestedSlot >= 0,
               result[requestedSlot] == nil {
                result[requestedSlot] = item
                nextFree = max(nextFree, requestedSlot + 1)
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

    func item(atSlot slotIndex: Int) -> TextureFillLibraryItem? {
        resolvedSlotMap()[slotIndex]
    }

    func firstEmptySlotIndex() -> Int {
        let occupied = Set(resolvedSlotMap().keys)
        var candidate = 0
        while occupied.contains(candidate) {
            candidate += 1
        }
        return candidate
    }

    func slotCount(minRows: Int = 2, columns: Int = 4) -> Int {
        precondition(columns > 0)
        let minimum = max(minRows, 1) * columns
        let occupied = (resolvedSlotMap().keys.max() ?? -1) + 1
        let needed = max(minimum, occupied)
        let remainder = needed % columns
        return remainder == 0 ? needed : needed + (columns - remainder)
    }

    mutating func saveCurrentTexture(
        settings: TextureFillTipSettings,
        sourceBrush: BrushSettings?
    ) -> TextureFillLibraryItem {
        if let existing = items.first(where: {
            $0.settings == settings && $0.sourceBrush == sourceBrush
        }) {
            selectedItemID = existing.id
            return existing
        }

        let item = TextureFillLibraryItem(
            displayName: "纹理 \(items.count + 1)",
            slotIndex: firstEmptySlotIndex(),
            settings: settings,
            sourceBrush: sourceBrush
        )
        items.append(item)
        selectedItemID = item.id
        return item
    }

    mutating func saveTextureAsNew(
        settings: TextureFillTipSettings,
        sourceBrush: BrushSettings?,
        name: String? = nil
    ) -> TextureFillLibraryItem {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedName: String
        if trimmedName.isEmpty {
            var candidate = items.count + 1
            while items.contains(where: { $0.displayName == "纹理 \(candidate)" }) {
                candidate += 1
            }
            resolvedName = "纹理 \(candidate)"
        } else {
            resolvedName = trimmedName
        }

        let item = TextureFillLibraryItem(
            displayName: resolvedName,
            slotIndex: firstEmptySlotIndex(),
            settings: settings,
            sourceBrush: sourceBrush
        )
        items.append(item)
        selectedItemID = item.id
        return item
    }

    mutating func selectItem(id: UUID?) {
        selectedItemID = id
    }

    mutating func noteItemUsed(_ id: UUID, limit: Int = 4) {
        guard items.contains(where: { $0.id == id }) else { return }
        recentItemIDs.removeAll { $0 == id }
        recentItemIDs.insert(id, at: 0)
        if recentItemIDs.count > limit {
            recentItemIDs = Array(recentItemIDs.prefix(limit))
        }
    }

    func recentItems(limit: Int = 4) -> [TextureFillLibraryItem] {
        Array(recentItemIDs.prefix(limit)).compactMap { item(id: $0) }
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

    mutating func duplicateItem(id: UUID) -> TextureFillLibraryItem? {
        guard var duplicate = item(id: id) else { return nil }
        duplicate.id = UUID()
        duplicate.displayName += " 副本"
        duplicate.slotIndex = firstEmptySlotIndex()
        duplicate.isFavorite = false
        items.append(duplicate)
        selectedItemID = duplicate.id
        return duplicate
    }

    mutating func replaceItem(
        id: UUID,
        settings: TextureFillTipSettings,
        sourceBrush: BrushSettings?
    ) -> TextureFillLibraryItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        items[index].settings = settings
        items[index].sourceBrush = sourceBrush
        selectedItemID = id
        return items[index]
    }

    mutating func moveItem(id: UUID, toSlot targetSlot: Int) -> Bool {
        guard targetSlot >= 0,
              let movingIndex = items.firstIndex(where: { $0.id == id }) else {
            return false
        }

        let slotMap = resolvedSlotMap()
        let sourceSlot = slotMap.first(where: { $0.value.id == id })?.key ?? targetSlot
        let targetItemID = slotMap[targetSlot]?.id
        items[movingIndex].slotIndex = targetSlot

        if let targetItemID,
           targetItemID != id,
           let targetIndex = items.firstIndex(where: { $0.id == targetItemID }) {
            items[targetIndex].slotIndex = sourceSlot
        }
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

    mutating func restoreMostRecentlyDeletedItem() -> TextureFillLibraryItem? {
        guard var restoredItem = deletedItems.popLast() else { return nil }
        if let slotIndex = restoredItem.slotIndex, item(atSlot: slotIndex) != nil {
            restoredItem.slotIndex = firstEmptySlotIndex()
        }
        items.append(restoredItem)
        selectedItemID = restoredItem.id
        return restoredItem
    }

    private func sanitizedRecentItemIDs(_ candidateIDs: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return candidateIDs.filter { id in
            guard items.contains(where: { $0.id == id }), seen.insert(id).inserted else {
                return false
            }
            return true
        }
    }
}

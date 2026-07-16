import Foundation

struct TextureFillLibraryItem: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var displayName: String
    var slotIndex: Int?
    var colorTag: BrushColorTag?
    var settings: TextureFillTipSettings
    var sourceBrush: BrushSettings?

    init(
        id: UUID = UUID(),
        displayName: String,
        slotIndex: Int? = nil,
        colorTag: BrushColorTag? = nil,
        settings: TextureFillTipSettings,
        sourceBrush: BrushSettings?
    ) {
        self.id = id
        self.displayName = displayName
        self.slotIndex = slotIndex
        self.colorTag = colorTag
        self.settings = settings
        self.sourceBrush = sourceBrush
    }
}

struct TextureFillLibraryState: Codable, Sendable, Equatable {
    var items: [TextureFillLibraryItem]
    var selectedItemID: UUID?
    var recentItemIDs: [UUID]

    init(
        items: [TextureFillLibraryItem] = [],
        selectedItemID: UUID? = nil,
        recentItemIDs: [UUID] = []
    ) {
        self.items = items
        self.selectedItemID = selectedItemID
        self.recentItemIDs = []
        self.recentItemIDs = sanitizedRecentItemIDs(recentItemIDs)
    }

    private enum CodingKeys: String, CodingKey {
        case items
        case selectedItemID
        case recentItemIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            items: try container.decodeIfPresent([TextureFillLibraryItem].self, forKey: .items) ?? [],
            selectedItemID: try container.decodeIfPresent(UUID.self, forKey: .selectedItemID),
            recentItemIDs: try container.decodeIfPresent([UUID].self, forKey: .recentItemIDs) ?? []
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
        guard items.contains(where: { $0.id == id }) else { return false }
        items.removeAll { $0.id == id }
        recentItemIDs.removeAll { $0 == id }
        if selectedItemID == id {
            selectedItemID = items.first?.id
        }
        return true
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

import Foundation

struct BrushPreset: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var name: String
    var brush: BrushSettings
    var isBuiltIn: Bool
    var slotIndex: Int? = nil
}

struct BrushLibraryState: Codable, Sendable, Equatable {
    var presets: [BrushPreset]
    var selectedPresetID: String?

    static let stageOneDefault = BrushLibraryState(
        presets: [],
        selectedPresetID: nil
    )

    func preset(id: String) -> BrushPreset? {
        presets.first(where: { $0.id == id })
    }

    mutating func selectPreset(id: String?) {
        selectedPresetID = id
    }

    mutating func saveCurrentPreset(brush: BrushSettings) -> BrushPreset {
        let nextCustomIndex = presets.filter { !$0.isBuiltIn }.count + 1
        let nextSlot = firstEmptySlotIndex()
        let preset = BrushPreset(
            id: UUID().uuidString,
            name: "笔刷 \(nextCustomIndex)",
            brush: brush,
            isBuiltIn: false,
            slotIndex: nextSlot
        )
        presets.append(preset)
        selectedPresetID = preset.id
        return preset
    }

    mutating func deletePreset(id: String) -> Bool {
        guard let index = presets.firstIndex(where: { $0.id == id }) else {
            return false
        }

        presets.remove(at: index)
        if selectedPresetID == id {
            selectedPresetID = presets.first?.id
        }
        return true
    }

    func resolvedSlotMap() -> [String: Int] {
        var assignments: [String: Int] = [:]
        var occupied = Set<Int>()

        for preset in presets {
            guard let slotIndex = preset.slotIndex, slotIndex >= 0, !occupied.contains(slotIndex) else {
                continue
            }
            assignments[preset.id] = slotIndex
            occupied.insert(slotIndex)
        }

        var nextFreeSlot = 0
        for preset in presets where assignments[preset.id] == nil {
            while occupied.contains(nextFreeSlot) {
                nextFreeSlot += 1
            }
            assignments[preset.id] = nextFreeSlot
            occupied.insert(nextFreeSlot)
        }

        return assignments
    }

    func firstEmptySlotIndex() -> Int {
        let occupied = Set(resolvedSlotMap().values)
        var candidate = 0
        while occupied.contains(candidate) {
            candidate += 1
        }
        return candidate
    }

    func preset(atSlot slotIndex: Int) -> BrushPreset? {
        let slotMap = resolvedSlotMap()
        return presets.first { slotMap[$0.id] == slotIndex }
    }

    mutating func movePreset(id: String, toSlot targetSlotIndex: Int) -> Bool {
        guard targetSlotIndex >= 0,
              let sourceIndex = presets.firstIndex(where: { $0.id == id }) else {
            return false
        }

        let slotMap = resolvedSlotMap()
        let sourceSlotIndex = slotMap[id] ?? targetSlotIndex
        let targetPresetID = slotMap.first { $0.value == targetSlotIndex }?.key

        presets[sourceIndex].slotIndex = targetSlotIndex

        if let targetPresetID, targetPresetID != id,
           let targetIndex = presets.firstIndex(where: { $0.id == targetPresetID }) {
            presets[targetIndex].slotIndex = sourceSlotIndex
        }

        return true
    }
}

struct BrushLibraryArchive: Codable, Sendable, Equatable {
    var version: Int = 1
    var library: BrushLibraryState
}

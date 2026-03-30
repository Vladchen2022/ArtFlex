import Foundation

struct BrushPreset: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var name: String
    var brush: BrushSettings
    var isBuiltIn: Bool
    var slotIndex: Int? = nil
}

extension BrushPreset {
    static let builtInDualTipPhaseOneDemoPresets: [BrushPreset] = [
        makeBuiltInDualTipPhaseOnePreset(
            id: "builtin-dual-tip-tighten",
            name: "Dual Tip · 收口型",
            slotIndex: 4,
            primaryTip: .hardRound,
            secondaryTip: .hardRound,
            strength: 0.84,
            sizeRatio: 0.56
        ),
        makeBuiltInDualTipPhaseOnePreset(
            id: "builtin-dual-tip-soft-compress",
            name: "Dual Tip · 柔边压缩",
            slotIndex: 5,
            primaryTip: .softRound,
            secondaryTip: .softRound,
            strength: 0.58,
            sizeRatio: 0.72
        ),
        makeBuiltInDualTipPhaseOnePreset(
            id: "builtin-dual-tip-strong-modulate",
            name: "Dual Tip · 强调制",
            slotIndex: 6,
            primaryTip: .hardRound,
            secondaryTip: .softRound,
            strength: 1.0,
            sizeRatio: 0.34
        )
    ]

    static let builtInDualTipPhaseOneDemoPresetIDs = Set(
        builtInDualTipPhaseOneDemoPresets.map(\.id)
    )

    var isDualTipPhaseOneDemoPreset: Bool {
        Self.builtInDualTipPhaseOneDemoPresetIDs.contains(id)
    }

    private static func makeBuiltInDualTipPhaseOnePreset(
        id: String,
        name: String,
        slotIndex: Int,
        primaryTip: BrushTipShape,
        secondaryTip: BrushTipShape,
        strength: Float,
        sizeRatio: Float
    ) -> BrushPreset {
        var brush = BrushSettings.stageOneDefault
        brush.tipShape = primaryTip
        brush.dualTipEnabled = true
        brush.secondaryTipDescriptor = SecondaryTipDescriptor(tipShape: secondaryTip)
        brush.dualTipCombineMode = .multiply
        brush.dualTipStrength = strength
        brush.secondarySizeRatio = sizeRatio

        return BrushPreset(
            id: id,
            name: name,
            brush: brush,
            isBuiltIn: true,
            slotIndex: slotIndex
        )
    }
}

struct BrushLibraryState: Codable, Sendable, Equatable {
    var presets: [BrushPreset]
    var selectedPresetID: String?

    static let stageOneDefault = BrushLibraryState(
        presets: BrushPreset.builtInDualTipPhaseOneDemoPresets,
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

    func ensuringBuiltInDualTipPhaseOneDemoPresets() -> BrushLibraryState {
        var mergedPresets = BrushPreset.builtInDualTipPhaseOneDemoPresets
        var seenIDs = Set(mergedPresets.map(\.id))

        for preset in presets where !BrushPreset.builtInDualTipPhaseOneDemoPresetIDs.contains(preset.id) {
            guard seenIDs.insert(preset.id).inserted else {
                continue
            }
            mergedPresets.append(preset)
        }

        let resolvedSelectedPresetID: String?
        if let selectedPresetID,
           mergedPresets.contains(where: { $0.id == selectedPresetID }) {
            resolvedSelectedPresetID = selectedPresetID
        } else {
            resolvedSelectedPresetID = nil
        }

        return BrushLibraryState(
            presets: mergedPresets,
            selectedPresetID: resolvedSelectedPresetID
        )
    }
}

struct BrushLibraryArchive: Codable, Sendable, Equatable {
    var version: Int = 2
    var library: BrushLibraryState
    var tipImageAssets: [BrushTipImageAsset]

    init(
        version: Int = 2,
        library: BrushLibraryState,
        tipImageAssets: [BrushTipImageAsset]? = nil
    ) {
        self.version = version
        if let tipImageAssets {
            self.library = library
            self.tipImageAssets = tipImageAssets
        } else {
            let normalized = BrushTipImageAssetSystem.archivedLibrary(library)
            self.library = normalized.library
            self.tipImageAssets = normalized.assets
        }
    }

    enum CodingKeys: String, CodingKey {
        case version
        case library
        case tipImageAssets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        library = try container.decode(BrushLibraryState.self, forKey: .library)
        tipImageAssets = try container.decodeIfPresent([BrushTipImageAsset].self, forKey: .tipImageAssets) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(library, forKey: .library)
        try container.encode(tipImageAssets, forKey: .tipImageAssets)
    }

    var resolvedLibrary: BrushLibraryState {
        BrushTipImageAssetSystem.resolveLibrary(library, assets: tipImageAssets)
    }
}

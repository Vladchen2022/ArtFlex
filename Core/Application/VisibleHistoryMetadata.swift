import Foundation

/// User-facing metadata for one action. Pixel/workspace snapshots remain owned by HistoryController.
struct VisibleHistoryEntryMetadata: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var actionKey: String
    var createdAt: Date
    var affectedLayerIDs: [LayerID]

    init(
        id: UUID = UUID(),
        actionKey: String,
        createdAt: Date = Date(),
        affectedLayerIDs: [LayerID] = []
    ) {
        self.id = id
        self.actionKey = actionKey
        self.createdAt = createdAt

        var seen: Set<LayerID> = []
        self.affectedLayerIDs = affectedLayerIDs.filter { seen.insert($0).inserted }
    }

    var displayName: String {
        switch actionKey {
        case let key where key.hasPrefix("brush.commit"):
            return "画笔"
        case let key where key.hasPrefix("eraser.commit"):
            return "橡皮擦"
        case let key where key.hasPrefix("smudge.commit"):
            return "涂抹"
        case let key where key.hasPrefix("layerMask.stroke"):
            return "编辑图层蒙版"
        case let key where key.hasPrefix("layer"):
            return "图层操作"
        case let key where key.contains("selection") || key.contains("lasso"):
            return "选区操作"
        case let key where key.contains("transform"):
            return "自由变形"
        case let key where key.contains("fill"):
            return "填充"
        case let key where key.contains("gradient"):
            return "渐变"
        case let key where key.contains("color") || key.contains("curve"):
            return "色彩调整"
        case let key where key.contains("generator"):
            return "生成器"
        case let key where key.contains("paste") || key.contains("import"):
            return "粘贴或导入"
        case let key where key.contains("crop"):
            return "裁剪画布"
        case let key where key.contains("blockReference"):
            return "体块参考"
        case "generic.checkpoint":
            return "编辑操作"
        default:
            return actionKey
                .split(separator: ".")
                .last
                .map(String.init) ?? "编辑操作"
        }
    }
}

enum VisibleHistoryNavigationDirection: String, Codable, Sendable, Equatable {
    case none
    case undo
    case redo
}

/// A sequential navigation request. Undo and redo counts are mutually exclusive.
struct VisibleHistoryNavigationPlan: Codable, Sendable, Equatable {
    var targetEntryID: UUID
    var undoStepCount: Int
    var redoStepCount: Int

    init?(
        targetEntryID: UUID,
        undoStepCount: Int,
        redoStepCount: Int
    ) {
        guard undoStepCount >= 0, redoStepCount >= 0 else { return nil }
        guard undoStepCount == 0 || redoStepCount == 0 else { return nil }
        self.targetEntryID = targetEntryID
        self.undoStepCount = undoStepCount
        self.redoStepCount = redoStepCount
    }

    var direction: VisibleHistoryNavigationDirection {
        if undoStepCount > 0 { return .undo }
        if redoStepCount > 0 { return .redo }
        return .none
    }

    var totalStepCount: Int {
        undoStepCount + redoStepCount
    }

    private enum CodingKeys: String, CodingKey {
        case targetEntryID
        case undoStepCount
        case redoStepCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let targetEntryID = try container.decode(UUID.self, forKey: .targetEntryID)
        let undoStepCount = try container.decode(Int.self, forKey: .undoStepCount)
        let redoStepCount = try container.decode(Int.self, forKey: .redoStepCount)
        guard let validated = VisibleHistoryNavigationPlan(
            targetEntryID: targetEntryID,
            undoStepCount: undoStepCount,
            redoStepCount: redoStepCount
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .undoStepCount,
                in: container,
                debugDescription: "A history navigation plan cannot navigate undo and redo simultaneously."
            )
        }
        self = validated
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(targetEntryID, forKey: .targetEntryID)
        try container.encode(undoStepCount, forKey: .undoStepCount)
        try container.encode(redoStepCount, forKey: .redoStepCount)
    }
}

/// A presentation-only timeline.
/// - `appliedEntries`: oldest to newest; each row represents the state after that action.
/// - `redoEntries`: next redo action first, farthest redo action last.
struct VisibleHistoryTimeline: Codable, Sendable, Equatable {
    var appliedEntries: [VisibleHistoryEntryMetadata]
    var redoEntries: [VisibleHistoryEntryMetadata]

    init(
        appliedEntries: [VisibleHistoryEntryMetadata] = [],
        redoEntries: [VisibleHistoryEntryMetadata] = []
    ) {
        self.appliedEntries = appliedEntries
        self.redoEntries = redoEntries
    }

    var totalEntryCount: Int {
        appliedEntries.count + redoEntries.count
    }

    var currentAppliedEntryCount: Int {
        appliedEntries.count
    }

    var chronologicalEntries: [VisibleHistoryEntryMetadata] {
        appliedEntries + redoEntries
    }

    var newestFirstEntries: [VisibleHistoryEntryMetadata] {
        chronologicalEntries.reversed()
    }

    func navigationPlan(toAppliedEntryCount targetCount: Int) -> VisibleHistoryNavigationPlan? {
        guard (0...totalEntryCount).contains(targetCount) else { return nil }
        let currentCount = currentAppliedEntryCount
        let entries = chronologicalEntries
        let targetEntryID: UUID
        if targetCount > 0 {
            targetEntryID = entries[targetCount - 1].id
        } else {
            targetEntryID = entries.first?.id ?? UUID()
        }
        if targetCount < currentCount {
            return VisibleHistoryNavigationPlan(
                targetEntryID: targetEntryID,
                undoStepCount: currentCount - targetCount,
                redoStepCount: 0
            )
        }
        return VisibleHistoryNavigationPlan(
            targetEntryID: targetEntryID,
            undoStepCount: 0,
            redoStepCount: targetCount - currentCount
        )
    }

    func navigationPlan(to targetEntryID: UUID) -> VisibleHistoryNavigationPlan? {
        if let appliedIndex = appliedEntries.firstIndex(where: { $0.id == targetEntryID }) {
            return VisibleHistoryNavigationPlan(
                targetEntryID: targetEntryID,
                undoStepCount: appliedEntries.count - appliedIndex - 1,
                redoStepCount: 0
            )
        }

        if let redoIndex = redoEntries.firstIndex(where: { $0.id == targetEntryID }) {
            return VisibleHistoryNavigationPlan(
                targetEntryID: targetEntryID,
                undoStepCount: 0,
                redoStepCount: redoIndex + 1
            )
        }
        return nil
    }
}

import Foundation

struct BrushTipDraftSnapshot: Sendable, Equatable {
    var maskData: Data?
    var sourceSemantic: TipSourceSemantic
    var assetID: BrushTipImageAssetID?
    var sourceInfo: ImportedTipSourceInfo?

    static let procedural = BrushTipDraftSnapshot(
        maskData: nil,
        sourceSemantic: .procedural,
        assetID: nil,
        sourceInfo: nil
    )
}

struct BrushTipDraftHistory: Sendable, Equatable {
    private(set) var undoStack: [BrushTipDraftSnapshot] = []
    private(set) var redoStack: [BrushTipDraftSnapshot] = []
    let capacity: Int

    init(capacity: Int = 32) {
        self.capacity = max(capacity, 1)
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    mutating func record(current: BrushTipDraftSnapshot, next: BrushTipDraftSnapshot) {
        guard current != next else { return }
        undoStack.append(current)
        if undoStack.count > capacity {
            undoStack.removeFirst(undoStack.count - capacity)
        }
        redoStack.removeAll(keepingCapacity: true)
    }

    mutating func undo(current: BrushTipDraftSnapshot) -> BrushTipDraftSnapshot? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    mutating func redo(current: BrushTipDraftSnapshot) -> BrushTipDraftSnapshot? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }

    mutating func reset() {
        undoStack.removeAll(keepingCapacity: true)
        redoStack.removeAll(keepingCapacity: true)
    }
}

enum BrushTipImageInterpretation: String, CaseIterable, Sendable, Equatable {
    case automatic
    case luminance
    case alpha

    var displayName: String {
        switch self {
        case .automatic: "自动"
        case .luminance: "明度"
        case .alpha: "Alpha"
        }
    }
}

struct BrushTipImageImportOptions: Sendable, Equatable {
    var interpretation: BrushTipImageInterpretation = .automatic
    var isInverted = false
    var usesThreshold = false
    var threshold: Double = 0.5
    var cropsToContent = true
}

/// Tool activity observed at a persistence boundary. This module has no UI or rendering dependency.
public struct PersistenceEditingActivity: OptionSet, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let historyPreview = Self(rawValue: 1 << 0)
    public static let pixelCommit = Self(rawValue: 1 << 1)
    public static let transform = Self(rawValue: 1 << 2)
    public static let snapshotOrExport = Self(rawValue: 1 << 3)
    public static let pattern = Self(rawValue: 1 << 4)
    public static let gradient = Self(rawValue: 1 << 5)
    public static let crop = Self(rawValue: 1 << 6)
    public static let gesture = Self(rawValue: 1 << 7)
    public static let adjustment = Self(rawValue: 1 << 8)
    public static let pendingLine = Self(rawValue: 1 << 9)
    public static let brushInput = Self(rawValue: 1 << 10)
}

public enum PersistenceEditingBlocker: Sendable, Equatable {
    case historyPreview, pixelCommit, transform, snapshotOrExport, pattern, gradient, crop, gesture
}

public enum DocumentPersistencePolicy {
    /// Manual saves may resolve adjustment, line and retained brush sessions in their existing way.
    public static func manualBlocker(for activity: PersistenceEditingActivity) -> PersistenceEditingBlocker? {
        if activity.contains(.historyPreview) { return .historyPreview }
        if activity.contains(.pixelCommit) { return .pixelCommit }
        if activity.contains(.transform) { return .transform }
        if activity.contains(.snapshotOrExport) { return .snapshotOrExport }
        if activity.contains(.pattern) { return .pattern }
        if activity.contains(.gradient) { return .gradient }
        if activity.contains(.crop) { return .crop }
        if activity.contains(.gesture) { return .gesture }
        return nil
    }

    /// Autosave must not confirm an in-progress tool on the user's behalf.
    /// Retained, completed brush jobs have a separate maximum-deferral rule in the caller.
    public static func blocksAutomaticCapture(_ activity: PersistenceEditingActivity) -> Bool {
        manualBlocker(for: activity) != nil || !activity.intersection([.adjustment, .pendingLine, .brushInput]).isEmpty
    }
}

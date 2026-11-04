import Foundation

public struct DocumentVersion: Sendable, Equatable {
    public var generation: UInt64
    public var editRevision: UInt64
    public init(generation: UInt64, editRevision: UInt64) {
        self.generation = generation
        self.editRevision = editRevision
    }
}

public enum DocumentTransitionDecision: Sendable { case save, discard, cancel }

/// Owns document identity, dirty state, file identity and transition authorization.
/// UI adapters supply decisions; this module has no window, workspace or GPU dependency.
@MainActor
public final class DocumentLifecycleCoordinator {
    public private(set) var version = DocumentVersion(generation: 0, editRevision: 0)
    public private(set) var isDirty = false
    public var projectURL: URL? { didSet { onStateChange?() } }
    public var isChoosingOpenLocation = false { didSet { onStateChange?() } }
    public var isChoosingSaveLocation = false { didSet { onStateChange?() } }
    public var onStateChange: (() -> Void)?
    public var onDirtyStateChange: ((Bool) -> Void)?
    private var transitionID: UUID? { didSet { onStateChange?() } }
    public var isTransitionPending: Bool { transitionID != nil }

    public init() {}

    public func setDirty(_ dirty: Bool) {
        isDirty = dirty
        if dirty { version.editRevision &+= 1 }
        onDirtyStateChange?(dirty)
        onStateChange?()
    }

    public func didReplaceDocument() {
        version.generation &+= 1
        onStateChange?()
    }

    /// A saved older revision may establish the path, but must not mark new edits saved.
    @discardableResult
    public func acceptSave(of captured: DocumentVersion, to url: URL) -> Bool {
        guard captured.generation == version.generation else { return false }
        projectURL = url
        if captured == version { setDirty(false) }
        return !isDirty
    }

    public func confirmTransition(
        hasPendingEdits: Bool,
        isBusy: Bool,
        presentDecision: (@escaping (DocumentTransitionDecision) -> Void) -> Void,
        save: @escaping (@escaping (Bool) -> Void) -> Void,
        completion: @escaping (Bool) -> Void
    ) {
        guard !isTransitionPending, !isBusy else { completion(false); return }
        guard isDirty || hasPendingEdits else { completion(true); return }
        let id = UUID()
        let captured = version
        transitionID = id
        var responded = false
        var finished = false
        let finish: (Bool) -> Void = { [weak self] allowed in
            guard !finished else { return }
            finished = true
            guard let self else { completion(false); return }
            guard self.transitionID == id else { return }
            self.transitionID = nil
            completion(allowed && self.version.generation == captured.generation)
        }
        presentDecision { [weak self] decision in
            guard !responded else { return }
            responded = true
            guard let self, self.transitionID == id,
                  self.version == captured else { finish(false); return }
            switch decision {
            case .save: save { [weak self] saved in finish(saved && self?.isDirty == false) }
            case .discard: finish(true)
            case .cancel: finish(false)
            }
        }
    }
}

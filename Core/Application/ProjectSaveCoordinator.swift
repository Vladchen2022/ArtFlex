import Foundation

/// Identity is separate from edit revision: a completed older save must not mark new edits saved.
struct ProjectSaveRequest: Sendable {
    var url: URL
    var capture: FrozenProjectCapture
    var savedDocumentName: String
    var editRevision: UInt64
    var documentGeneration: UInt64
}

/// Owns the single formal-save task. Panels, tool resolution and UI remain in the platform layer.
/// An accepted write is drained even if its caller disappears; it is never abandoned mid-archive.
@MainActor
final class ProjectSaveCoordinator {
    typealias Writer = @Sendable (FrozenProjectCapture, URL) throws -> ProjectWriteOutcome
    private let writer: Writer
    private var task: Task<Void, Never>?
    var onStateChange: (() -> Void)?
    var isSaving: Bool { task != nil }

    init(writer: @escaping Writer) { self.writer = writer }

    convenience init(persistenceController: PersistenceController) {
        let worker = ProjectSaveWorker(controller: persistenceController)
        self.init { capture, url in
            let payload = try worker.controller.materializeProjectPayload(from: capture)
            return try worker.controller.writeCapturedProject(payload, to: url)
        }
    }

    @discardableResult
    func start(
        _ request: ProjectSaveRequest,
        completion: @escaping (Result<ProjectWriteOutcome, Error>) -> Void
    ) -> Bool {
        guard task == nil else { return false }
        let writer = self.writer
        task = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { try writer(request.capture, request.url) }
            }.value
            self?.task = nil
            self?.onStateChange?()
            completion(result)
        }
        onStateChange?()
        return true
    }
}

/// The worker only reads frozen captures and writes archives. It never reads live workspace state.
private final class ProjectSaveWorker: @unchecked Sendable {
    let controller: PersistenceController
    init(controller: PersistenceController) { self.controller = controller }
}

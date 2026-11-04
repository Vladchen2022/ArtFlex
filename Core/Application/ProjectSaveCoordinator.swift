import Foundation

/// Identity is separate from edit revision: a completed older save must not mark new edits saved.
struct ProjectSaveRequest: Sendable {
    var url: URL
    var capture: QueuedProjectCapture
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
    private var saving = false
    var onStateChange: (() -> Void)?
    var isSaving: Bool { saving }

    init(writer: @escaping Writer) { self.writer = writer }

    convenience init(persistenceController: PersistenceController) {
        let worker = ProjectSaveWorker(controller: persistenceController)
        self.init { capture, url in
            let audit = PerformanceAuditStore.shared
            let recording = audit.isRecordingEnabled
            let start = recording ? DispatchTime.now().uptimeNanoseconds : 0
            let payload = try worker.controller.materializeProjectPayload(from: capture, reuseEncodedLayers: true)
            let materialized = recording ? DispatchTime.now().uptimeNanoseconds : 0
            let result = try worker.controller.writeCapturedProject(payload, to: url)
            if recording {
                audit.recordDuration("ProjectSave.materialize", ms: Double(materialized - start) / 1_000_000)
                audit.recordDuration("ProjectSave.write", ms: Double(DispatchTime.now().uptimeNanoseconds - materialized) / 1_000_000)
            }
            return result
        }
    }

    @discardableResult
    func start(
        _ request: ProjectSaveRequest,
        completion: @escaping @MainActor @Sendable (Result<ProjectWriteOutcome, Error>) -> Void
    ) -> Bool {
        guard !saving else { return false }
        saving = true
        let writer = self.writer
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result {
                let capture = try request.capture.waitUntilReady()
                return try writer(capture, request.url)
            }
            MainRunLoopDelivery.perform {
                self?.saving = false
                self?.onStateChange?()
                completion(result)
            }
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

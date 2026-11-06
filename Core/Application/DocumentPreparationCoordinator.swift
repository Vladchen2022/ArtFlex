import Foundation

/// Owns one cancellable preparation. Only its current request may publish a result.
/// Each document has its own worker; one expensive crop cannot delay another tab's previews.
@MainActor
final class DocumentPreparationCoordinator {
    private var task: Task<Void, Never>?
    private var cancellation: WorkCancellation?
    private var request = UUID()
    private let worker = PreviewWorker()
    var isRunning: Bool { cancellation != nil }

    func cancel() {
        cancellation?.cancel()
        task?.cancel()
        cancellation = nil
        task = nil
        request = UUID()
    }

    func submit<Value: Sendable>(operation: @escaping @Sendable (WorkCancellation) throws -> Value,
                                completion: @escaping @MainActor (Result<Value, Error>) -> Void) {
        cancel()
        let token = WorkCancellation(), id = UUID(), worker = worker
        cancellation = token; request = id
        task = Task { [weak self] in
            let result = await worker.evaluate(token) { try operation(token) }
            guard let self, self.request == id, !token.isCancelled else { return }
            self.task = nil; self.cancellation = nil
            completion(result)
        }
    }

    deinit { cancellation?.cancel(); task?.cancel() }
}

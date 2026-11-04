import Foundation

/// All expensive preview operations are serialized; cancelled queued jobs allocate nothing.
/// Committed editing/rendering uses its own path and does not wait for this worker.
actor PreviewWorker {
    static let shared = PreviewWorker()
    func evaluate<Value: Sendable>(_ cancellation: WorkCancellation,
        operation: @Sendable () throws -> Value) -> Result<Value, Error> {
        Result {
            try cancellation.check()
            let value = try operation()
            try cancellation.check()
            return value
        }
    }
}

@MainActor
final class LatestPreviewCoordinator<Value: Sendable> {
    private var task: Task<Void, Never>?
    private var cancellation: WorkCancellation?
    private var request = UUID()

    func cancel() {
        cancellation?.cancel()
        task?.cancel()
        cancellation = nil
        task = nil
        request = UUID()
    }

    func submit(delay: Duration = .milliseconds(80),
                operation: @escaping @Sendable (WorkCancellation) throws -> Value,
                completion: @escaping @MainActor (Result<Value, Error>) -> Void) {
        cancel()
        let token = WorkCancellation(), id = UUID()
        cancellation = token
        request = id
        task = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            let result = await PreviewWorker.shared.evaluate(token) { try operation(token) }
            guard let self, self.request == id, !token.isCancelled else { return }
            self.task = nil
            completion(result)
        }
    }
}

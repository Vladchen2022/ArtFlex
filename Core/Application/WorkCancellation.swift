import Foundation

/// Shared by a Swift task and its synchronous worker. Cancelling the waiter must
/// also stop expensive work which is already running on a queue or detached task.
final class WorkCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws { if isCancelled { throw CancellationError() } }
}

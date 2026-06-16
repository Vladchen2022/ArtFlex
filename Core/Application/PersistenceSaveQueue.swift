import Foundation

final class PersistenceSaveQueue: @unchecked Sendable {
    private let queue: DispatchQueue

    init(label: String, qos: DispatchQoS = .utility) {
        queue = DispatchQueue(label: label, qos: qos)
    }

    func enqueue(
        _ operation: @escaping @Sendable () throws -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) {
        queue.async {
            do {
                try operation()
            } catch {
                onError(error)
            }
        }
    }
}

import Foundation

final class PersistenceSaveQueue: @unchecked Sendable {
    private let queue: DispatchQueue
    private var failures: [String: String] = [:] // accessed only on queue

    init(label: String, qos: DispatchQoS = .utility) {
        queue = DispatchQueue(label: label, qos: qos)
    }

    func enqueue(
        key: String = "default",
        _ operation: @escaping @Sendable () throws -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) {
        queue.async {
            do {
                try operation()
                self.failures[key] = nil
            } catch {
                self.failures[key] = error.localizedDescription
                onError(error)
            }
        }
    }

    func drain(_ completion: @escaping @Sendable (String?) -> Void) {
        queue.async { completion(self.failures.isEmpty ? nil : self.failures.values.sorted().joined(separator: "；")) }
    }
}

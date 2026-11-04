import Foundation

/// Admission for work which has not finished allocating its scratch resources.
/// Native resident usage remains authoritative; reservations add conservative headroom.
final class WorkingResourceBudget: @unchecked Sendable {
    let maximumBytes: Int
    private let lock = NSLock()
    private var reservations: [UUID: Int] = [:]
    var reservedBytes: Int { lock.withLock { reservations.values.reduce(0, +) } }

    init(maximumBytes: Int) { self.maximumBytes = max(0, maximumBytes) }

    func reserve(bytes: Int, residentBytes: Int) throws -> Reservation {
        try lock.withLock {
            let used = reservations.values.reduce(0, +)
            guard bytes >= 0, residentBytes >= 0, residentBytes <= maximumBytes,
                  used <= maximumBytes - residentBytes,
                  bytes <= maximumBytes - residentBytes - used else {
                throw CanvasResourceError(message: "当前并行操作需要的临时内存超过预算，请等待其他操作完成")
            }
            let id = UUID()
            reservations[id] = bytes
            return Reservation(budget: self, id: id)
        }
    }

    final class Reservation: @unchecked Sendable {
        private let budget: WorkingResourceBudget
        private let id: UUID
        fileprivate init(budget: WorkingResourceBudget, id: UUID) { self.budget = budget; self.id = id }
        deinit { budget.lock.withLock { _ = budget.reservations.removeValue(forKey: id) } }
    }
}

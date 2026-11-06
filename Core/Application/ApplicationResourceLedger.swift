import Foundation

/// Main-actor owners report retained CPU payloads. Metal's device-wide allocation counter
/// supplies the GPU side; background reservations read the last published CPU total.
/// Weak ownership means closed documents and discarded branches leave the next assessment.
final class ApplicationResourceLedger: @unchecked Sendable {
    private final class Account {
        weak var owner: AnyObject?
        let measure: @MainActor () -> Int
        let reclaim: @MainActor (Bool) -> Void
        init(owner: AnyObject, measure: @escaping @MainActor () -> Int, reclaim: @escaping @MainActor (Bool) -> Void) {
            self.owner = owner; self.measure = measure; self.reclaim = reclaim
        }
    }
    private let budget: WorkingResourceBudget
    private let lock = NSLock()
    private var accounts: [ObjectIdentifier: Account] = [:]
    private var measured: [ObjectIdentifier: Int] = [:]

    init(budget: WorkingResourceBudget) { self.budget = budget }

    @MainActor func register(owner: AnyObject, reclaim: @escaping @MainActor (Bool) -> Void = { _ in }, measure: @escaping @MainActor () -> Int) {
        lock.withLock { accounts[ObjectIdentifier(owner)] = Account(owner: owner, measure: measure, reclaim: reclaim) }
    }

    @MainActor @discardableResult func refresh(excluding owner: AnyObject? = nil) -> Int {
        let live = lock.withLock { accounts = accounts.filter { $0.value.owner != nil }; return accounts }
        let usage = live.mapValues { max(0, $0.measure()) }
        lock.withLock { measured = usage }
        budget.setResidentCPUBytes(usage.values.reduce(0, Self.add))
        let excluded = owner.map(ObjectIdentifier.init)
        return usage.filter { $0.key != excluded }.values.reduce(0, Self.add)
    }

    @MainActor func relieveMemoryPressure(critical: Bool) {
        let live = lock.withLock { accounts.values.filter { $0.owner != nil } }
        for account in live { account.reclaim(critical) }
        refresh()
    }

    var residentCPUBytes: Int { lock.withLock { measured.values.reduce(0, Self.add) } }
    static func multiply(_ a: Int, _ b: Int) -> Int {
        guard a >= 0, b >= 0 else { return Int.max }
        let result = a.multipliedReportingOverflow(by: b); return result.overflow ? Int.max : result.partialValue
    }
    static func add(_ a: Int, _ b: Int) -> Int {
        let result = a.addingReportingOverflow(b); return result.overflow ? Int.max : result.partialValue
    }
}

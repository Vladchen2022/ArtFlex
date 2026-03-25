import Foundation

struct PerformanceAuditSnapshot: Sendable {
    var durationsMs: [String: [Double]]
    var integerSamples: [String: [Int]]

    func durations(for key: String) -> [Double] {
        durationsMs[key] ?? []
    }

    func latestDuration(_ key: String) -> Double? {
        durationsMs[key]?.last
    }

    func averageDuration(_ key: String) -> Double? {
        let values = durations(for: key)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    func latestInt(_ key: String) -> Int? {
        integerSamples[key]?.last
    }

    func maxInt(_ key: String) -> Int? {
        integerSamples[key]?.max()
    }

    func ints(for key: String) -> [Int] {
        integerSamples[key] ?? []
    }
}

final class PerformanceAuditStore: @unchecked Sendable {
    static let shared = PerformanceAuditStore()

    private let lock = NSLock()
    private var durationsMs: [String: [Double]] = [:]
    private var integerSamples: [String: [Int]] = [:]

    func reset() {
        lock.lock()
        durationsMs.removeAll()
        integerSamples.removeAll()
        lock.unlock()
    }

    func recordDuration(_ key: String, ms: Double) {
        lock.lock()
        durationsMs[key, default: []].append(ms)
        lock.unlock()
    }

    func recordInt(_ key: String, value: Int) {
        lock.lock()
        integerSamples[key, default: []].append(value)
        lock.unlock()
    }

    func snapshot() -> PerformanceAuditSnapshot {
        lock.lock()
        let snapshot = PerformanceAuditSnapshot(
            durationsMs: durationsMs,
            integerSamples: integerSamples
        )
        lock.unlock()
        return snapshot
    }
}

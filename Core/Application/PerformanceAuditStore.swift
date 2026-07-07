import Foundation

enum HistoryEligibilityIneligibleReason: String, Sendable, CaseIterable {
    case noComparisonWorkspace
    case canvasSizeChanged
    case layerCountChanged
    case orderedLayerIDsChanged
    case candidateChangedLayersUnknown
    case multiLayerWrite
    case topologyOperation
}

enum HistoryEligibilityPhase: String, Sendable, Hashable {
    case warmup
    case steadyState
}

private struct HistoryEligibilitySummaryKey: Hashable {
    var operationKind: String
    var canvasSizeBucket: String
    var layerCountBucket: String
    var warmupOrSteadyState: HistoryEligibilityPhase
}

struct HistoryEligibilityAuditRecord: Sendable {
    var operationKind: String
    var eligible: Bool
    var ineligibleReason: HistoryEligibilityIneligibleReason?
    var canvasSizeBucket: String
    var layerCountBucket: String
    var warmupOrSteadyState: HistoryEligibilityPhase
    var topologyStable: Bool
    var candidateChangedLayerIDs: [LayerID]
    var fullSnapshotLayerCount: Int
    var dirtyCandidateLayerCount: Int
    var fullEntryBytes: Int
    var projectedDirtyEntryBytes: Int
    var projectedByteSavings: Int
    var projectedLayerSavings: Int
    var fullCheckpointMs: Double
    var overBudget: Bool
}

struct HistoryEligibilityAuditSummaryRow: Sendable {
    var operationKind: String
    var canvasSizeBucket: String
    var layerCountBucket: String
    var warmupOrSteadyState: HistoryEligibilityPhase
    var count: Int
    var eligibleCount: Int
    var fullEntryBytes: Int
    var projectedDirtyEntryBytes: Int
    var savedBytes: Int
    var fullLayers: Int
    var dirtyLayers: Int
    var savedLayers: Int
    var overBudgetCount: Int
    var ineligibleReasonCounts: [HistoryEligibilityIneligibleReason: Int]

    var eligibleRatio: Double {
        guard count > 0 else { return 0 }
        return Double(eligibleCount) / Double(count)
    }
}

struct PerformanceAuditSnapshot: Sendable {
    var durationsMs: [String: [Double]]
    var integerSamples: [String: [Int]]
    var historyEligibilityRecords: [HistoryEligibilityAuditRecord]

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

    func historyEligibilitySummaryRows() -> [HistoryEligibilityAuditSummaryRow] {
        let grouped = Dictionary(
            grouping: historyEligibilityRecords,
            by: {
                HistoryEligibilitySummaryKey(
                    operationKind: $0.operationKind,
                    canvasSizeBucket: $0.canvasSizeBucket,
                    layerCountBucket: $0.layerCountBucket,
                    warmupOrSteadyState: $0.warmupOrSteadyState
                )
            }
        )
        return grouped.keys.sorted {
            if $0.operationKind != $1.operationKind { return $0.operationKind < $1.operationKind }
            if $0.canvasSizeBucket != $1.canvasSizeBucket { return $0.canvasSizeBucket < $1.canvasSizeBucket }
            if $0.layerCountBucket != $1.layerCountBucket { return $0.layerCountBucket < $1.layerCountBucket }
            return $0.warmupOrSteadyState.rawValue < $1.warmupOrSteadyState.rawValue
        }.compactMap { key in
            guard let records = grouped[key] else { return nil }
            var reasonCounts: [HistoryEligibilityIneligibleReason: Int] = [:]
            for record in records {
                if let reason = record.ineligibleReason {
                    reasonCounts[reason, default: 0] += 1
                }
            }
            return HistoryEligibilityAuditSummaryRow(
                operationKind: key.operationKind,
                canvasSizeBucket: key.canvasSizeBucket,
                layerCountBucket: key.layerCountBucket,
                warmupOrSteadyState: key.warmupOrSteadyState,
                count: records.count,
                eligibleCount: records.filter(\.eligible).count,
                fullEntryBytes: records.reduce(0) { $0 + $1.fullEntryBytes },
                projectedDirtyEntryBytes: records.reduce(0) { $0 + $1.projectedDirtyEntryBytes },
                savedBytes: records.reduce(0) { $0 + $1.projectedByteSavings },
                fullLayers: records.reduce(0) { $0 + $1.fullSnapshotLayerCount },
                dirtyLayers: records.reduce(0) { $0 + $1.dirtyCandidateLayerCount },
                savedLayers: records.reduce(0) { $0 + $1.projectedLayerSavings },
                overBudgetCount: records.filter(\.overBudget).count,
                ineligibleReasonCounts: reasonCounts
            )
        }
    }
}

final class PerformanceAuditStore: @unchecked Sendable {
    static let shared = PerformanceAuditStore()

    private static let maxSamplesPerKey = 2000
    private static let maxHistoryEligibilityRecords = 500

    private let lock = NSLock()
    private var recordingEnabled = false
    private var durationsMs: [String: [Double]] = [:]
    private var integerSamples: [String: [Int]] = [:]
    private var historyEligibilityRecords: [HistoryEligibilityAuditRecord] = []

    var isRecordingEnabled: Bool {
        recordingEnabled
    }

    func reset() {
        lock.lock()
        recordingEnabled = true
        durationsMs.removeAll()
        integerSamples.removeAll()
        historyEligibilityRecords.removeAll()
        lock.unlock()
    }

    func setRecordingEnabled(_ isEnabled: Bool) {
        lock.lock()
        recordingEnabled = isEnabled
        lock.unlock()
    }

    func recordDuration(_ key: String, ms: Double) {
        guard recordingEnabled else { return }
        lock.lock()
        guard recordingEnabled else {
            lock.unlock()
            return
        }
        var samples = durationsMs[key, default: []]
        if samples.count >= Self.maxSamplesPerKey {
            samples.removeFirst(samples.count / 2)
        }
        samples.append(ms)
        durationsMs[key] = samples
        lock.unlock()
    }

    func recordInt(_ key: String, value: Int) {
        guard recordingEnabled else { return }
        lock.lock()
        guard recordingEnabled else {
            lock.unlock()
            return
        }
        var samples = integerSamples[key, default: []]
        if samples.count >= Self.maxSamplesPerKey {
            samples.removeFirst(samples.count / 2)
        }
        samples.append(value)
        integerSamples[key] = samples
        lock.unlock()
    }

    func recordHistoryEligibility(_ record: HistoryEligibilityAuditRecord) {
        guard recordingEnabled else { return }
        lock.lock()
        guard recordingEnabled else {
            lock.unlock()
            return
        }
        if historyEligibilityRecords.count >= Self.maxHistoryEligibilityRecords {
            historyEligibilityRecords.removeFirst(historyEligibilityRecords.count / 2)
        }
        historyEligibilityRecords.append(record)
        lock.unlock()
    }

    func snapshot() -> PerformanceAuditSnapshot {
        lock.lock()
        let snapshot = PerformanceAuditSnapshot(
            durationsMs: durationsMs,
            integerSamples: integerSamples,
            historyEligibilityRecords: historyEligibilityRecords
        )
        lock.unlock()
        return snapshot
    }
}

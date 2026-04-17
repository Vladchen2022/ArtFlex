import Foundation
import Metal

struct BrushStrokeContext: Sendable, Equatable {
    let layerID: LayerID
    let tool: ToolKind
    let color: RGBAColor
    let brush: BrushSettings
    let selectionShape: SelectionShape?
}

enum BrushInteractiveState: Sendable, Equatable {
    case idle
    case activeStroke
    case warmIdle(untilUptimeNs: UInt64)
}

enum BrushLiveEvent: Sendable, Equatable {
    case begin(layerID: LayerID, enqueuedAt: UInt64)
    case packet(StrokeDescriptor, layerID: LayerID, enqueuedAt: UInt64)
    case end(layerID: LayerID, enqueuedAt: UInt64)
}

enum BrushCommitDrainMode: Sendable, Equatable {
    case interactiveBudget(maxJobs: Int, maxCpuMs: Double)
    case forced
}

struct BrushCommitDrainResult: Sendable, Equatable {
    let drainedJobs: Int
    let skippedForInteractiveFrame: Bool
    let remainingQueueDepth: Int
}

struct BrushCommitJob: Sendable, Equatable {
    let layerID: LayerID
    let packets: [StrokeDescriptor]
    let needsTailFlush: Bool
    let commitRevision: UInt64
}

struct BrushLiveSession {
    let layerID: LayerID
    let workingTexture: MTLTexture
    var displayRevision: UInt64
    var committedRevision: UInt64
    var alphaLockTexture: MTLTexture?
    var liveEvents: [BrushLiveEvent] = []
    var currentStrokePackets: [StrokeDescriptor] = []
    var brushSamplingState: BrushStrokeSamplingState?
    var opacityCapSession: OpacityCapSessionResources?
    var interactiveState: BrushInteractiveState = .idle
    var lastInputUptimeNs: UInt64 = 0
    var shouldRetainWorkingTexture: Bool = true
    var strokeBeganAtUptimeNs: UInt64?
}

final class BrushCommitQueue {
    private var jobs: [BrushCommitJob] = []
    private var headIndex = 0

    var isEmpty: Bool { count == 0 }
    var count: Int { jobs.count - headIndex }

    func snapshot() -> [BrushCommitJob] {
        guard headIndex < jobs.count else { return [] }
        return Array(jobs[headIndex...])
    }

    func enqueue(_ job: BrushCommitJob) {
        jobs.append(job)
    }

    func dequeue() -> BrushCommitJob? {
        guard headIndex < jobs.count else { return nil }
        let job = jobs[headIndex]
        headIndex += 1
        compactStorageIfNeeded()
        return job
    }

    func removeAll() {
        jobs.removeAll(keepingCapacity: true)
        headIndex = 0
    }

    private func compactStorageIfNeeded() {
        guard headIndex > 32, headIndex * 2 >= jobs.count else {
            return
        }
        jobs.removeFirst(headIndex)
        headIndex = 0
    }
}

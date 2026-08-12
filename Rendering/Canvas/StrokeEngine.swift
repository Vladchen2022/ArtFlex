import Foundation
@preconcurrency import Metal

struct BrushStrokeStreamID: RawRepresentable, Codable, Hashable, Sendable, Equatable {
    var rawValue: UInt8

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    static let primary = BrushStrokeStreamID(rawValue: 0)
}

struct StrokePoint: Sendable, Equatable {
    var x: Double
    var y: Double
    var pressure: Float
}

struct StrokeDescriptor: Sendable, Equatable {
    var tool: ToolKind
    var color: RGBAColor
    var brush: BrushSettings
    var points: [StrokePoint]
    var selectionShape: SelectionShape?
    var alphaLockEnabled: Bool = false
    var skipLeadingStamp: Bool = false
    var paintVariationSeed: UInt32 = 0
    /// Frozen brush-reservoir colors for deterministic oil-paint replay.
    var pigmentPalette: BrushPigmentPalette = .empty
    var brushStreamID: BrushStrokeStreamID = .primary
}

struct BrushFlushMetrics: Sendable, Equatable {
    let packetQueuedCount: Int
    let flushedPacketCount: Int
    let enqueueToFlushMs: Double
    let flushEncodeMs: Double
    let usedSameFrameFlush: Bool
}

protocol StrokeEngine {
    func beginStrokeIfNeeded(
        toolSession: ToolSessionState,
        layerID: LayerID
    )

    @discardableResult
    func applyStroke(_ stroke: StrokeDescriptor, to layerID: LayerID) -> Int

    func endStroke()

    var hasPendingBrushWork: Bool { get }

    var hasPendingBrushCommitJobs: Bool { get }

    func canOpportunisticallyDrainPendingBrushCommitJobs(
        hadLiveBrushWorkThisFrame: Bool,
        retainedRecentBrushCommitJobs: Int
    ) -> Bool

    @discardableResult
    func flushPendingStrokePackets(into commandBuffer: MTLCommandBuffer) -> BrushFlushMetrics?

    func displayTexture(for layerID: LayerID) -> MTLTexture?

    func drainPendingBrushCommitJobs(beforeEachCommit: (BrushCommitJob) throws -> Void) throws

    @discardableResult
    func opportunisticDrainPendingBrushCommitJobs(
        hadLiveBrushWorkThisFrame: Bool,
        maxJobs: Int,
        maxCpuMs: Double,
        beforeEachCommit: (BrushCommitJob) throws -> Void
    ) throws -> BrushCommitDrainResult

    func resetBrushPipelineState()
}

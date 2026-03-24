import Foundation
@preconcurrency import Metal

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
    var skipLeadingStamp: Bool = false
}

struct BrushFlushMetrics: Sendable, Equatable {
    let packetQueuedCount: Int
    let flushedPacketCount: Int
    let enqueueToFlushMs: Double
    let flushEncodeMs: Double
    let usedSameFrameFlush: Bool
}

protocol StrokeEngine {
    @discardableResult
    func applyStroke(_ stroke: StrokeDescriptor, to layerID: LayerID) -> Int

    var hasPendingBrushWork: Bool { get }

    @discardableResult
    func flushPendingStrokePackets(into commandBuffer: MTLCommandBuffer) -> BrushFlushMetrics?
}

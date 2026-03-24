import Foundation
import Metal
import os

final class MetalStrokeEngine: StrokeEngine {
    private struct OpacityCapStrokeSession {
        let layerID: LayerID
        let resources: OpacityCapSessionResources
    }

    private struct QueuedStrokePacket {
        let stroke: StrokeDescriptor
        let layerID: LayerID
        let enqueuedAt: UInt64
    }

    private struct PendingStrokeContext {
        let layerID: LayerID
        let tool: ToolKind
        let color: RGBAColor
        let brush: BrushSettings
        let selectionShape: SelectionShape?
    }

    private let metalContext: MetalDeviceContext
    private let layerSurfaceStore: StageOneLayerSurfaceStore
    private let brushRenderer: StageOneBrushRenderer
    private let logger = Logger(subsystem: "ArtFlex", category: "BrushStroke")
    private var opacityCapSession: OpacityCapStrokeSession?
    private var brushSamplingState: BrushStrokeSamplingState?
    private var pendingStrokeContext: PendingStrokeContext?
    private var pendingStrokePackets: [QueuedStrokePacket] = []
    private var pendingStrokeEnd = false

    init(
        metalContext: MetalDeviceContext,
        layerSurfaceStore: StageOneLayerSurfaceStore
    ) {
        self.metalContext = metalContext
        self.layerSurfaceStore = layerSurfaceStore
        self.brushRenderer = StageOneBrushRenderer(device: metalContext.device)
    }

    func beginStrokeIfNeeded(
        toolSession: ToolSessionState,
        layerID: LayerID
    ) {
        brushSamplingState = nil
        pendingStrokeContext = nil
        guard
            (toolSession.activeTool == .brush || toolSession.activeTool == .eraser),
            toolSession.brush.buildMode == .opacityCap,
            let surfaceID = layerSurfaceStore.surfaceID(for: layerID),
            let texture = layerSurfaceStore.texture(for: surfaceID)
        else {
            opacityCapSession = nil
            return
        }

        if opacityCapSession?.layerID == layerID {
            return
        }

        guard
            let resources = brushRenderer.makeOpacityCapSession(
                for: texture,
                commandQueue: metalContext.commandQueue
            )
        else {
            opacityCapSession = nil
            return
        }

        opacityCapSession = OpacityCapStrokeSession(
            layerID: layerID,
            resources: resources
        )
    }

    func endStroke() {
        pendingStrokeEnd = true
    }

    @discardableResult
    func applyStroke(_ stroke: StrokeDescriptor, to layerID: LayerID) -> Int {
        if stroke.tool == .brush || stroke.tool == .eraser {
            pendingStrokeContext = PendingStrokeContext(
                layerID: layerID,
                tool: stroke.tool,
                color: stroke.color,
                brush: stroke.brush,
                selectionShape: stroke.selectionShape
            )

            if stroke.brush.buildMode == .opacityCap, opacityCapSession?.layerID != layerID {
                beginStrokeIfNeeded(
                    toolSession: ToolSessionState(
                        activeTool: stroke.tool,
                        brush: stroke.brush,
                        selectedColor: stroke.color
                    ),
                    layerID: layerID
                )
            }

            pendingStrokePackets.append(
                QueuedStrokePacket(
                    stroke: stroke,
                    layerID: layerID,
                    enqueuedAt: DispatchTime.now().uptimeNanoseconds
                )
            )
            logger.debug("[brush-feel] packetQueuedCount=\(self.pendingStrokePackets.count, privacy: .public)")
            logger.debug("[brush-feel] livePathMode=frameFlush")
            return pendingStrokePackets.count
        }

        logger.debug("[brush-feel] livePathMode=immediate")

        guard
            let surfaceID = layerSurfaceStore.surfaceID(for: layerID),
            let texture = layerSurfaceStore.texture(for: surfaceID)
        else {
            return 0
        }

        pendingStrokeContext = PendingStrokeContext(
            layerID: layerID,
            tool: stroke.tool,
            color: stroke.color,
            brush: stroke.brush,
            selectionShape: stroke.selectionShape
        )

        if (stroke.tool == .brush || stroke.tool == .eraser), stroke.brush.buildMode == .opacityCap {
            if opacityCapSession?.layerID != layerID {
                beginStrokeIfNeeded(
                    toolSession: ToolSessionState(
                        activeTool: stroke.tool,
                        brush: stroke.brush,
                        selectedColor: stroke.color
                    ),
                    layerID: layerID
                )
            }

            guard let opacityCapSession else {
                return brushRenderer.render(
                    stroke: stroke,
                    into: texture,
                    commandQueue: metalContext.commandQueue,
                    samplingState: &brushSamplingState
                )
            }

            return brushRenderer.renderOpacityCap(
                stroke: stroke,
                session: opacityCapSession.resources,
                into: texture,
                commandQueue: metalContext.commandQueue,
                samplingState: &brushSamplingState
            )
        }

        return brushRenderer.render(
            stroke: stroke,
            into: texture,
            commandQueue: metalContext.commandQueue,
            samplingState: &brushSamplingState
        )
    }

    var hasPendingBrushWork: Bool {
        !pendingStrokePackets.isEmpty || pendingStrokeEnd
    }

    @discardableResult
    func flushPendingStrokePackets(into commandBuffer: MTLCommandBuffer) -> BrushFlushMetrics? {
        let queuedPackets = pendingStrokePackets
        let queuedCount = queuedPackets.count
        let hadPendingEnd = pendingStrokeEnd

        guard queuedCount > 0 || hadPendingEnd else {
            return nil
        }

        let flushStartNs = DispatchTime.now().uptimeNanoseconds
        let oldestEnqueueNs = queuedPackets.first?.enqueuedAt ?? flushStartNs
        var flushedPacketCount = 0

        for packet in queuedPackets {
            guard
                let surfaceID = layerSurfaceStore.surfaceID(for: packet.layerID),
                let texture = layerSurfaceStore.texture(for: surfaceID)
            else {
                continue
            }

            pendingStrokeContext = PendingStrokeContext(
                layerID: packet.layerID,
                tool: packet.stroke.tool,
                color: packet.stroke.color,
                brush: packet.stroke.brush,
                selectionShape: packet.stroke.selectionShape
            )

            if (packet.stroke.tool == .brush || packet.stroke.tool == .eraser),
               packet.stroke.brush.buildMode == .opacityCap,
               let opacityCapSession,
               opacityCapSession.layerID == packet.layerID {
                _ = brushRenderer.encodeOpacityCapStroke(
                    stroke: packet.stroke,
                    session: opacityCapSession.resources,
                    into: texture,
                    commandBuffer: commandBuffer,
                    samplingState: &brushSamplingState
                )
            } else {
                _ = brushRenderer.encodeStroke(
                    stroke: packet.stroke,
                    into: texture,
                    commandQueue: metalContext.commandQueue,
                    commandBuffer: commandBuffer,
                    samplingState: &brushSamplingState
                )
            }
            flushedPacketCount += 1
        }

        if hadPendingEnd,
           let context = pendingStrokeContext,
           let surfaceID = layerSurfaceStore.surfaceID(for: context.layerID),
           let texture = layerSurfaceStore.texture(for: surfaceID) {
            var samplingState = brushSamplingState
            samplingState?.isFlushing = true
            let flushStroke = StrokeDescriptor(
                tool: context.tool,
                color: context.color,
                brush: context.brush,
                points: [],
                selectionShape: context.selectionShape,
                skipLeadingStamp: true
            )

            if (flushStroke.tool == .brush || flushStroke.tool == .eraser),
               flushStroke.brush.buildMode == .opacityCap,
               let opacityCapSession,
               opacityCapSession.layerID == context.layerID {
                _ = brushRenderer.encodeOpacityCapStroke(
                    stroke: flushStroke,
                    session: opacityCapSession.resources,
                    into: texture,
                    commandBuffer: commandBuffer,
                    samplingState: &samplingState
                )
            } else {
                _ = brushRenderer.encodeStroke(
                    stroke: flushStroke,
                    into: texture,
                    commandQueue: metalContext.commandQueue,
                    commandBuffer: commandBuffer,
                    samplingState: &samplingState
                )
            }
            brushSamplingState = samplingState
            logger.debug("[flush] didFlush=true emittedStamps=1")
        }

        pendingStrokePackets.removeAll(keepingCapacity: true)
        pendingStrokeEnd = false
        if hadPendingEnd {
            opacityCapSession = nil
            brushSamplingState = nil
            pendingStrokeContext = nil
        }

        let encodeEndNs = DispatchTime.now().uptimeNanoseconds
        let enqueueToFlushMs = Double(flushStartNs - oldestEnqueueNs) / 1_000_000
        let flushEncodeMs = Double(encodeEndNs - flushStartNs) / 1_000_000
        let metrics = BrushFlushMetrics(
            packetQueuedCount: queuedCount,
            flushedPacketCount: flushedPacketCount,
            enqueueToFlushMs: enqueueToFlushMs,
            flushEncodeMs: flushEncodeMs,
            usedSameFrameFlush: enqueueToFlushMs <= 16.7
        )

        logger.debug("[brush-feel] flushPacketsThisFrame=\(flushedPacketCount, privacy: .public)")
        logger.debug("[brush-feel] enqueueToFlushMs=\(enqueueToFlushMs, privacy: .public)")
        logger.debug("[brush-feel] flushEncodeMs=\(flushEncodeMs, privacy: .public)")
        logger.debug("[brush-feel] usedSameFrameFlush=\(metrics.usedSameFrameFlush, privacy: .public)")

        commandBuffer.addCompletedHandler { [logger] _ in
            let flushToPresentMs = Double(DispatchTime.now().uptimeNanoseconds - flushStartNs) / 1_000_000
            let didProduceToPresentMs = Double(DispatchTime.now().uptimeNanoseconds - oldestEnqueueNs) / 1_000_000
            logger.debug("[brush-feel] flushToPresentMs=\(flushToPresentMs, privacy: .public)")
            logger.debug("[brush-feel] didProduceToPresentMs=\(didProduceToPresentMs, privacy: .public)")
        }

        return metrics
    }
}

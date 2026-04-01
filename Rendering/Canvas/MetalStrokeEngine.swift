import Foundation
import Metal
import os

final class MetalStrokeEngine: StrokeEngine {
    private enum LiveSessionReuseState: Equatable {
        case created
        case reusedExisting
        case warmReused
    }

    private let metalContext: MetalDeviceContext
    private let layerSurfaceStore: StageOneLayerSurfaceStore
    private let brushRenderer: StageOneBrushRenderer
    private let logger = Logger(subsystem: "ArtFlex", category: "BrushStroke")
    private let warmIdleDurationNs: UInt64 = 300_000_000

    private var liveSession: BrushLiveSession?
    private let commitQueue = BrushCommitQueue()
    private var nextCommitRevision: UInt64 = 0
    private(set) var debugLastFlushSmudgeFullSizeCopyCount = 0
    private(set) var debugLastCommitSmudgeFullSizeCopyCount = 0

    init(
        metalContext: MetalDeviceContext,
        layerSurfaceStore: StageOneLayerSurfaceStore
    ) throws {
        self.metalContext = metalContext
        self.layerSurfaceStore = layerSurfaceStore
        self.brushRenderer = try StageOneBrushRenderer(device: metalContext.device)
    }

    func beginStrokeIfNeeded(
        toolSession: ToolSessionState,
        layerID: LayerID
    ) {
        guard isBrushLike(toolSession.activeTool) else {
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        let reuseState = ensureLiveSession(for: layerID, now: now)
        guard reuseState != nil else {
            return
        }
        liveSession?.interactiveState = .activeStroke
        liveSession?.lastInputUptimeNs = now
        liveSession?.shouldRetainWorkingTexture = true
        liveSession?.strokeBeganAtUptimeNs = now
        liveSession?.liveEvents.append(
            .begin(layerID: layerID, enqueuedAt: now)
        )
        logger.debug("[brush-live] sessionWarmReused=\(reuseState == .warmReused, privacy: .public)")
        logger.debug("[brush-live] commitQueueDepth=\(self.commitQueue.count, privacy: .public)")
    }

    @discardableResult
    func applyStroke(_ stroke: StrokeDescriptor, to layerID: LayerID) -> Int {
        if isBrushLike(stroke.tool) {
            let now = DispatchTime.now().uptimeNanoseconds
            guard ensureLiveSession(for: layerID, now: now) != nil else {
                return 0
            }
            liveSession?.interactiveState = .activeStroke
            liveSession?.lastInputUptimeNs = now
            liveSession?.shouldRetainWorkingTexture = true
            liveSession?.liveEvents.append(
                .packet(stroke, layerID: layerID, enqueuedAt: now)
            )
            let queuedPackets = liveSession?.liveEvents.reduce(into: 0) { count, event in
                if case .packet = event {
                    count += 1
                }
            } ?? 0
            logger.debug("[brush-feel] packetQueuedCount=\(queuedPackets, privacy: .public)")
            logger.debug("[brush-feel] livePathMode=workingTexture")
            return queuedPackets
        }

        logger.debug("[brush-feel] livePathMode=immediate")

        guard
            let surfaceID = layerSurfaceStore.surfaceID(for: layerID),
            let texture = layerSurfaceStore.texture(for: surfaceID)
        else {
            return 0
        }

        var samplingState: BrushStrokeSamplingState?
        return brushRenderer.render(
            stroke: stroke,
            into: texture,
            commandQueue: metalContext.commandQueue,
            samplingState: &samplingState
        )
    }

    func endStroke() {
        guard var session = liveSession else {
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        session.lastInputUptimeNs = now
        session.shouldRetainWorkingTexture = true
        session.interactiveState = .warmIdle(untilUptimeNs: now + warmIdleDurationNs)
        session.liveEvents.append(
            .end(layerID: session.layerID, enqueuedAt: now)
        )
        liveSession = session
    }

    var hasPendingBrushWork: Bool {
        !(liveSession?.liveEvents.isEmpty ?? true)
    }

    var hasPendingBrushCommitJobs: Bool {
        !commitQueue.isEmpty
    }

    @discardableResult
    func flushPendingStrokePackets(into commandBuffer: MTLCommandBuffer) -> BrushFlushMetrics? {
        let startNs = DispatchTime.now().uptimeNanoseconds
        defer {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000
            PerformanceAuditStore.shared.recordDuration("MetalStrokeEngine.flushPendingStrokePackets", ms: ms)
        }
        guard var session = liveSession, !session.liveEvents.isEmpty else {
            return nil
        }

        let queuedEvents = session.liveEvents
        session.liveEvents = []

        let flushStartNs = DispatchTime.now().uptimeNanoseconds
        let oldestEnqueueNs = queuedEvents.compactMap { event -> UInt64? in
            switch event {
            case .begin(_, let enqueuedAt), .packet(_, _, let enqueuedAt), .end(_, let enqueuedAt):
                return enqueuedAt
            }
        }.min() ?? flushStartNs
        let liveAlphaLockTexture = layerSurfaceStore.surfaceID(for: session.layerID)
            .flatMap(layerSurfaceStore.texture(for:))

        var flushedPacketCount = 0
        debugLastFlushSmudgeFullSizeCopyCount = 0

        for event in queuedEvents {
            switch event {
            case .begin(let layerID, _):
                guard session.layerID == layerID else { continue }
                session.brushSamplingState = nil
                session.currentStrokePackets = []
                session.opacityCapSession = nil

            case .packet(let stroke, let layerID, _):
                guard session.layerID == layerID else { continue }
                if requiresOpacityCap(stroke), session.opacityCapSession == nil {
                    session.opacityCapSession = brushRenderer.makeOpacityCapSession(
                        for: session.workingTexture,
                        commandQueue: metalContext.commandQueue
                    )
                }

                if requiresOpacityCap(stroke), let opacityCapSession = session.opacityCapSession {
                    _ = brushRenderer.encodeOpacityCapStroke(
                        stroke: stroke,
                        session: opacityCapSession,
                        into: session.workingTexture,
                        commandBuffer: commandBuffer,
                        alphaLockTexture: stroke.alphaLockEnabled ? liveAlphaLockTexture : nil,
                        samplingState: &session.brushSamplingState
                    )
                } else {
                    _ = brushRenderer.encodeStroke(
                        stroke: stroke,
                        into: session.workingTexture,
                        commandQueue: metalContext.commandQueue,
                        commandBuffer: commandBuffer,
                        alphaLockTexture: stroke.alphaLockEnabled ? liveAlphaLockTexture : nil,
                        samplingState: &session.brushSamplingState
                    )
                }

                session.currentStrokePackets.append(stroke)
                PerformanceAuditStore.shared.recordInt(
                    "MetalStrokeEngine.currentStrokePackets.count",
                    value: session.currentStrokePackets.count
                )
                flushedPacketCount += 1
                if let strokeBeganAtUptimeNs = session.strokeBeganAtUptimeNs {
                    let beginToFirstLiveEncodeMs = Double(flushStartNs - strokeBeganAtUptimeNs) / 1_000_000
                    logger.debug("[brush-live] beginToFirstLiveEncodeMs=\(beginToFirstLiveEncodeMs, privacy: .public)")
                    session.strokeBeganAtUptimeNs = nil
                }

            case .end(let layerID, _):
                guard session.layerID == layerID else { continue }
                guard let lastStroke = session.currentStrokePackets.last else {
                    session.brushSamplingState = nil
                    session.opacityCapSession = nil
                    session.strokeBeganAtUptimeNs = nil
                    continue
                }

                var flushSamplingState = session.brushSamplingState
                flushSamplingState?.isFlushing = true
                let flushStroke = StrokeDescriptor(
                    tool: lastStroke.tool,
                    color: lastStroke.color,
                    brush: lastStroke.brush,
                    points: [],
                    selectionShape: lastStroke.selectionShape,
                    alphaLockEnabled: lastStroke.alphaLockEnabled,
                    skipLeadingStamp: true
                )

                if requiresOpacityCap(lastStroke), let opacityCapSession = session.opacityCapSession {
                    _ = brushRenderer.encodeOpacityCapStroke(
                        stroke: flushStroke,
                        session: opacityCapSession,
                        into: session.workingTexture,
                        commandBuffer: commandBuffer,
                        alphaLockTexture: lastStroke.alphaLockEnabled ? liveAlphaLockTexture : nil,
                        samplingState: &flushSamplingState
                    )
                } else {
                    _ = brushRenderer.encodeStroke(
                        stroke: flushStroke,
                        into: session.workingTexture,
                        commandQueue: metalContext.commandQueue,
                        commandBuffer: commandBuffer,
                        alphaLockTexture: lastStroke.alphaLockEnabled ? liveAlphaLockTexture : nil,
                        samplingState: &flushSamplingState
                    )
                }

                session.brushSamplingState = nil
                session.opacityCapSession = nil
                session.displayRevision &+= 1
                nextCommitRevision &+= 1
                commitQueue.enqueue(
                    BrushCommitJob(
                        layerID: layerID,
                        packets: session.currentStrokePackets,
                        needsTailFlush: true,
                        commitRevision: nextCommitRevision
                    )
                )
                PerformanceAuditStore.shared.recordInt(
                    "MetalStrokeEngine.stroke.packetCount",
                    value: session.currentStrokePackets.count
                )
                PerformanceAuditStore.shared.recordInt(
                    "MetalStrokeEngine.commitQueue.depth",
                    value: commitQueue.count
                )
                session.currentStrokePackets = []
                logger.debug("[brush-live] commitQueueDepth=\(self.commitQueue.count, privacy: .public)")
            }
        }

        liveSession = session

        let encodeEndNs = DispatchTime.now().uptimeNanoseconds
        let enqueueToFlushMs = Double(flushStartNs - oldestEnqueueNs) / 1_000_000
        let flushEncodeMs = Double(encodeEndNs - flushStartNs) / 1_000_000
        let metrics = BrushFlushMetrics(
            packetQueuedCount: queuedEvents.reduce(into: 0) { count, event in
                if case .packet = event {
                    count += 1
                }
            },
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

    func displayTexture(for layerID: LayerID) -> MTLTexture? {
        guard liveSession?.layerID == layerID, liveSession?.shouldRetainWorkingTexture == true else {
            return nil
        }
        return liveSession?.workingTexture
    }

    func drainPendingBrushCommitJobs(beforeEachCommit: (BrushCommitJob) throws -> Void) throws {
        _ = try drainPendingBrushCommitJobs(
            mode: .forced,
            hadLiveBrushWorkThisFrame: false,
            beforeEachCommit: beforeEachCommit
        )
    }

    @discardableResult
    func opportunisticDrainPendingBrushCommitJobs(
        hadLiveBrushWorkThisFrame: Bool,
        maxJobs: Int,
        maxCpuMs: Double,
        beforeEachCommit: (BrushCommitJob) throws -> Void
    ) throws -> BrushCommitDrainResult {
        try drainPendingBrushCommitJobs(
            mode: .interactiveBudget(maxJobs: maxJobs, maxCpuMs: maxCpuMs),
            hadLiveBrushWorkThisFrame: hadLiveBrushWorkThisFrame,
            beforeEachCommit: beforeEachCommit
        )
    }

    func resetBrushPipelineState() {
        liveSession?.shouldRetainWorkingTexture = false
        liveSession = nil
    }

    private func ensureLiveSession(for layerID: LayerID, now: UInt64) -> LiveSessionReuseState? {
        let startNs = DispatchTime.now().uptimeNanoseconds
        defer {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000
            PerformanceAuditStore.shared.recordDuration("MetalStrokeEngine.ensureLiveSession", ms: ms)
        }
        if let liveSession,
           liveSession.layerID == layerID,
           let sourceSurfaceID = layerSurfaceStore.surfaceID(for: layerID),
           let sourceTexture = layerSurfaceStore.texture(for: sourceSurfaceID),
           liveSession.workingTexture.width == sourceTexture.width,
           liveSession.workingTexture.height == sourceTexture.height,
           liveSession.workingTexture.pixelFormat == sourceTexture.pixelFormat {
            if case .warmIdle(let untilUptimeNs) = liveSession.interactiveState, now <= untilUptimeNs {
                return .warmReused
            }
            return .reusedExisting
        }

        guard
            let sourceSurfaceID = layerSurfaceStore.surfaceID(for: layerID),
            let sourceTexture = layerSurfaceStore.texture(for: sourceSurfaceID),
            let workingTexture = layerSurfaceStore.makeTexture(
                width: sourceTexture.width,
                height: sourceTexture.height,
                pixelFormat: sourceTexture.pixelFormat,
                metal: metalContext
            )
        else {
            return nil
        }

        layerSurfaceStore.copyTextureAsync(
            from: sourceTexture,
            to: workingTexture,
            metal: metalContext
        )

        liveSession = BrushLiveSession(
            layerID: layerID,
            workingTexture: workingTexture,
            displayRevision: nextCommitRevision,
            committedRevision: nextCommitRevision
        )
        liveSession?.lastInputUptimeNs = now
        return .created
    }

    private func drainPendingBrushCommitJobs(
        mode: BrushCommitDrainMode,
        hadLiveBrushWorkThisFrame: Bool,
        beforeEachCommit: (BrushCommitJob) throws -> Void
    ) throws -> BrushCommitDrainResult {
        let now = DispatchTime.now().uptimeNanoseconds
        updateInteractiveState(now: now)

        let warmIdleHit = liveSession.map { session in
            if case .warmIdle(let untilUptimeNs) = session.interactiveState {
                return now <= untilUptimeNs
            }
            return false
        } ?? false
        let activeStroke = liveSession.map { session in
            if case .activeStroke = session.interactiveState {
                return true
            }
            return false
        } ?? false

        let shouldSkipForInteractiveFrame: Bool
        let maxJobs: Int
        let maxCpuNs: UInt64

        switch mode {
        case .forced:
            shouldSkipForInteractiveFrame = false
            maxJobs = Int.max
            maxCpuNs = .max
        case .interactiveBudget(let jobs, let cpuMs):
            shouldSkipForInteractiveFrame = hadLiveBrushWorkThisFrame || activeStroke || warmIdleHit
            maxJobs = max(jobs, 0)
            maxCpuNs = cpuMs <= 0 ? 0 : UInt64(cpuMs * 1_000_000)
        }

        logger.debug("[brush-live] warmIdleHit=\(warmIdleHit, privacy: .public)")
        logger.debug("[brush-live] commitQueueDepth=\(self.commitQueue.count, privacy: .public)")
        logger.debug("[brush-live] commitDrainSkippedForInteractiveFrame=\(shouldSkipForInteractiveFrame, privacy: .public)")
        PerformanceAuditStore.shared.recordInt(
            "MetalStrokeEngine.commitQueue.depth",
            value: commitQueue.count
        )

        guard !shouldSkipForInteractiveFrame, maxJobs > 0 else {
            return BrushCommitDrainResult(
                drainedJobs: 0,
                skippedForInteractiveFrame: shouldSkipForInteractiveFrame,
                remainingQueueDepth: commitQueue.count
            )
        }

        let drainStartNs = DispatchTime.now().uptimeNanoseconds
        var drainedJobs = 0

        while drainedJobs < maxJobs, let job = commitQueue.dequeue() {
            try beforeEachCommit(job)
            try commit(job: job)
            if liveSession?.layerID == job.layerID {
                liveSession?.committedRevision = job.commitRevision
            }
            drainedJobs += 1

            if maxCpuNs != .max {
                let elapsedNs = DispatchTime.now().uptimeNanoseconds - drainStartNs
                if elapsedNs >= maxCpuNs {
                    break
                }
            }
        }

        logger.debug("[brush-live] commitQueueDepth=\(self.commitQueue.count, privacy: .public)")
        return BrushCommitDrainResult(
            drainedJobs: drainedJobs,
            skippedForInteractiveFrame: false,
            remainingQueueDepth: commitQueue.count
        )
    }

    private func updateInteractiveState(now: UInt64) {
        guard var session = liveSession else {
            return
        }
        if case .warmIdle(let untilUptimeNs) = session.interactiveState, now > untilUptimeNs {
            session.interactiveState = .idle
        }
        liveSession = session
    }

    private func commit(job: BrushCommitJob) throws {
        let startNs = DispatchTime.now().uptimeNanoseconds
        defer {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000
            PerformanceAuditStore.shared.recordDuration("MetalStrokeEngine.commit(job:)", ms: ms)
        }
        guard
            let surfaceID = layerSurfaceStore.surfaceID(for: job.layerID),
            let texture = layerSurfaceStore.texture(for: surfaceID),
            let commandBuffer = metalContext.commandQueue.makeCommandBuffer()
        else {
            return
        }

        var samplingState: BrushStrokeSamplingState?
        var opacityCapSession: OpacityCapSessionResources?
        debugLastCommitSmudgeFullSizeCopyCount = 0
        let usesAlphaLock = job.packets.contains(where: \.alphaLockEnabled)
        let commitAlphaLockTexture = usesAlphaLock ? makeAlphaLockTextureCopy(from: texture) : nil

        for packet in job.packets {
            if requiresOpacityCap(packet), opacityCapSession == nil {
                opacityCapSession = brushRenderer.makeOpacityCapSession(
                    for: texture,
                    commandQueue: metalContext.commandQueue
                )
            }

            if requiresOpacityCap(packet), let opacityCapSession {
                _ = brushRenderer.encodeOpacityCapStroke(
                    stroke: packet,
                    session: opacityCapSession,
                    into: texture,
                    commandBuffer: commandBuffer,
                    alphaLockTexture: packet.alphaLockEnabled ? commitAlphaLockTexture : nil,
                    samplingState: &samplingState
                )
            } else {
                _ = brushRenderer.encodeStroke(
                    stroke: packet,
                    into: texture,
                    commandQueue: metalContext.commandQueue,
                    commandBuffer: commandBuffer,
                    alphaLockTexture: packet.alphaLockEnabled ? commitAlphaLockTexture : nil,
                    samplingState: &samplingState
                )
            }
        }

        if job.needsTailFlush, let lastStroke = job.packets.last {
            var flushSamplingState = samplingState
            flushSamplingState?.isFlushing = true
            let flushStroke = StrokeDescriptor(
                tool: lastStroke.tool,
                color: lastStroke.color,
                brush: lastStroke.brush,
                points: [],
                selectionShape: lastStroke.selectionShape,
                alphaLockEnabled: lastStroke.alphaLockEnabled,
                skipLeadingStamp: true
            )

            if requiresOpacityCap(lastStroke), let opacityCapSession {
                _ = brushRenderer.encodeOpacityCapStroke(
                    stroke: flushStroke,
                    session: opacityCapSession,
                    into: texture,
                    commandBuffer: commandBuffer,
                    alphaLockTexture: lastStroke.alphaLockEnabled ? commitAlphaLockTexture : nil,
                    samplingState: &flushSamplingState
                )
            } else {
                _ = brushRenderer.encodeStroke(
                    stroke: flushStroke,
                    into: texture,
                    commandQueue: metalContext.commandQueue,
                    commandBuffer: commandBuffer,
                    alphaLockTexture: lastStroke.alphaLockEnabled ? commitAlphaLockTexture : nil,
                    samplingState: &flushSamplingState
                )
            }
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func isBrushLike(_ tool: ToolKind) -> Bool {
        tool == .brush || tool == .eraser || tool == .smudge
    }

    private func requiresOpacityCap(_ stroke: StrokeDescriptor) -> Bool {
        (stroke.tool == .brush || stroke.tool == .eraser) && stroke.brush.buildMode == .opacityCap
    }

    private func makeAlphaLockTextureCopy(from sourceTexture: MTLTexture) -> MTLTexture? {
        guard let alphaLockTexture = layerSurfaceStore.makeTexture(
            width: sourceTexture.width,
            height: sourceTexture.height,
            pixelFormat: sourceTexture.pixelFormat,
            usage: [.shaderRead],
            storageMode: .private,
            metal: metalContext
        ) else {
            return nil
        }

        layerSurfaceStore.copyTexture(
            from: sourceTexture,
            to: alphaLockTexture,
            metal: metalContext
        )
        return alphaLockTexture
    }
}

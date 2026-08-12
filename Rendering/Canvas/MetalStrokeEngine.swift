import Foundation
import Metal
import os

final class MetalStrokeEngine: StrokeEngine {
    private enum LiveSessionReuseState: Equatable {
        case created
        case reusedExisting
        case warmReused
    }

    private struct RecentBrushAdjustmentState: Equatable {
        let layerID: LayerID
        var selectedRecentCount: Int
        var opacity: Float
        var brightness: Float
        var saturation: Float
        var showsSelectionHighlight: Bool
    }

    private struct RecentBrushPreviewKey: Equatable {
        let layerID: LayerID
        let selectedRecentCount: Int
        let opacity: Float
        let brightness: Float
        let saturation: Float
        let showsSelectionHighlight: Bool
        let committedRevision: UInt64
        let displayRevision: UInt64
        let pendingCommitRevisions: [UInt64]
    }

    private struct RecentBrushPreviewBaseKey: Equatable {
        let layerID: LayerID
        let selectedRecentCount: Int
        let committedRevision: UInt64
        let displayRevision: UInt64
        let pendingCommitRevisions: [UInt64]
    }

    private let metalContext: MetalDeviceContext
    private let layerSurfaceStore: StageOneLayerSurfaceStore
    private let brushRenderer: StageOneBrushRenderer
    private let logger = Logger(subsystem: "ArtFlex", category: "BrushStroke")
    private let warmIdleDurationNs: UInt64 = 300_000_000
    private let maxRetainedRecentBrushCommitJobs = 20
    private let recentBrushHighlightColor = RGBAColor(red: 0.22, green: 0.58, blue: 1, alpha: 1)

    private var liveSession: BrushLiveSession?
    private let commitQueue = BrushCommitQueue()
    private var nextCommitRevision: UInt64 = 0
    private var recentBrushAdjustmentState: RecentBrushAdjustmentState?
    private var recentBrushPreviewBaseTexture: MTLTexture?
    private var recentBrushPreviewBaseKey: RecentBrushPreviewBaseKey?
    private var recentBrushPreviewTexture: MTLTexture?
    private var recentBrushPreviewKey: RecentBrushPreviewKey?
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
        invalidateRecentBrushPreviewCache()
        if RuntimeDiagnostics.brushHotPathLoggingEnabled {
            logger.debug("[brush-live] sessionWarmReused=\(reuseState == .warmReused, privacy: .public)")
            logger.debug("[brush-live] commitQueueDepth=\(self.commitQueue.count, privacy: .public)")
        }
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
            liveSession?.pendingPacketCount += 1
            invalidateRecentBrushPreviewCache()
            let queuedPackets = liveSession?.pendingPacketCount ?? 0
            if RuntimeDiagnostics.brushHotPathLoggingEnabled {
                logger.debug("[brush-feel] packetQueuedCount=\(queuedPackets, privacy: .public)")
                logger.debug("[brush-feel] livePathMode=workingTexture")
            }
            return queuedPackets
        }

        if RuntimeDiagnostics.brushHotPathLoggingEnabled {
            logger.debug("[brush-feel] livePathMode=immediate")
        }

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
        invalidateRecentBrushPreviewCache()
    }

    var hasPendingBrushWork: Bool {
        !(liveSession?.liveEvents.isEmpty ?? true)
    }

    var hasPendingBrushCommitJobs: Bool {
        !commitQueue.isEmpty
    }

    func canOpportunisticallyDrainPendingBrushCommitJobs(
        hadLiveBrushWorkThisFrame: Bool,
        retainedRecentBrushCommitJobs: Int
    ) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        updateInteractiveState(now: now)
        let queueSnapshot = commitQueue.snapshot()
        guard !queueSnapshot.isEmpty else { return false }

        let activeStroke = liveSession.map {
            if case .activeStroke = $0.interactiveState { return true }
            return false
        } ?? false
        let warmIdleHit = liveSession.map {
            if case .warmIdle(let untilUptimeNs) = $0.interactiveState {
                return now <= untilUptimeNs
            }
            return false
        } ?? false
        let protectedRecentBrushCommits = protectedRecentBrushCommitCount(
            in: queueSnapshot,
            retainedRecentBrushCommitJobs: retainedRecentBrushCommitJobs
        )
        return shouldScheduleInteractiveBrushCommitDrain(
            queueDepth: queueSnapshot.count,
            protectedCommitCount: protectedRecentBrushCommits,
            hadLiveBrushWorkThisFrame: hadLiveBrushWorkThisFrame,
            hasActiveStroke: activeStroke,
            hasWarmIdleSession: warmIdleHit
        )
    }

    var recentAdjustableBrushCommitLimit: Int {
        maxRetainedRecentBrushCommitJobs
    }

    func recentAdjustableBrushCommitCount(for layerID: LayerID) -> Int {
        min(
            maxRetainedRecentBrushCommitJobs,
            commitQueue.snapshot().filter {
                $0.layerID == layerID && $0.packets.last?.tool == .brush
            }.count
        )
    }

    func setRecentBrushAdjustment(
        layerID: LayerID,
        selectedRecentCount: Int,
        opacity: Float,
        brightness: Float,
        saturation: Float,
        showsSelectionHighlight: Bool
    ) {
        let previousState = recentBrushAdjustmentState
        let clampedCount = max(selectedRecentCount, 0)
        let clampedOpacity = min(max(opacity, 0), 1)
        let clampedBrightness = min(max(brightness, -1), 1)
        let clampedSaturation = min(max(saturation, -1), 1)
        let isNeutralAdjustment =
            clampedOpacity >= 0.999
            && abs(clampedBrightness) < 0.001
            && abs(clampedSaturation) < 0.001
        if clampedCount == 0 || (isNeutralAdjustment && showsSelectionHighlight == false) {
            recentBrushAdjustmentState = nil
        } else {
            recentBrushAdjustmentState = RecentBrushAdjustmentState(
                layerID: layerID,
                selectedRecentCount: clampedCount,
                opacity: clampedOpacity,
                brightness: clampedBrightness,
                saturation: clampedSaturation,
                showsSelectionHighlight: showsSelectionHighlight
            )
        }
        let shouldInvalidateBase =
            previousState?.layerID != recentBrushAdjustmentState?.layerID
            || previousState?.selectedRecentCount != recentBrushAdjustmentState?.selectedRecentCount
        if shouldInvalidateBase {
            invalidateRecentBrushPreviewCache()
        } else {
            invalidateRecentBrushPreviewResult()
        }
    }

    func clearRecentBrushAdjustment() {
        recentBrushAdjustmentState = nil
        invalidateRecentBrushPreviewCache()
    }

    @discardableResult
    func flushPendingStrokePackets(into commandBuffer: MTLCommandBuffer) -> BrushFlushMetrics? {
        let diagnosticsEnabled = RuntimeDiagnostics.brushHotPathLoggingEnabled
        let auditEnabled = PerformanceAuditStore.shared.isRecordingEnabled
        let startNs = auditEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if auditEnabled {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000
                PerformanceAuditStore.shared.recordDuration("MetalStrokeEngine.flushPendingStrokePackets", ms: ms)
            }
        }
        guard var session = liveSession, !session.liveEvents.isEmpty else {
            return nil
        }

        let queuedEvents = session.liveEvents
        let queuedPacketCount = session.pendingPacketCount
        session.liveEvents = []
        session.pendingPacketCount = 0

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
                session.brushSamplingStates.removeAll(keepingCapacity: true)
                session.currentStrokePackets = []
                session.opacityCapSessions.removeAll(keepingCapacity: true)

            case .packet(let stroke, let layerID, _):
                guard session.layerID == layerID else { continue }
                let streamID = stroke.brushStreamID
                if requiresStrokeMaskSession(stroke), session.opacityCapSessions[streamID] == nil,
                   let opacityCapSession = brushRenderer.makeOpacityCapSession(
                        for: session.workingTexture,
                        commandQueue: metalContext.commandQueue,
                        reusesCachedTextures: streamID == .primary
                   ) {
                    session.opacityCapSessions[streamID] = opacityCapSession
                }

                var streamSamplingState = session.brushSamplingStates[streamID]
                if requiresStrokeMaskSession(stroke), let opacityCapSession = session.opacityCapSessions[streamID] {
                    _ = brushRenderer.encodeOpacityCapStroke(
                        stroke: stroke,
                        session: opacityCapSession,
                        into: session.workingTexture,
                        commandBuffer: commandBuffer,
                        alphaLockTexture: stroke.alphaLockEnabled ? liveAlphaLockTexture : nil,
                        samplingState: &streamSamplingState
                    )
                } else {
                    _ = brushRenderer.encodeStroke(
                        stroke: stroke,
                        into: session.workingTexture,
                        commandQueue: metalContext.commandQueue,
                        commandBuffer: commandBuffer,
                        alphaLockTexture: stroke.alphaLockEnabled ? liveAlphaLockTexture : nil,
                        samplingState: &streamSamplingState
                    )
                }
                if let streamSamplingState {
                    session.brushSamplingStates[streamID] = streamSamplingState
                } else {
                    session.brushSamplingStates.removeValue(forKey: streamID)
                }

                session.currentStrokePackets.append(stroke)
                if auditEnabled {
                    PerformanceAuditStore.shared.recordInt(
                        "MetalStrokeEngine.currentStrokePackets.count",
                        value: session.currentStrokePackets.count
                    )
                }
                flushedPacketCount += 1
                if let strokeBeganAtUptimeNs = session.strokeBeganAtUptimeNs {
                    if diagnosticsEnabled {
                        let beginToFirstLiveEncodeMs = Double(flushStartNs - strokeBeganAtUptimeNs) / 1_000_000
                        logger.debug("[brush-live] beginToFirstLiveEncodeMs=\(beginToFirstLiveEncodeMs, privacy: .public)")
                    }
                    session.strokeBeganAtUptimeNs = nil
                }

            case .end(let layerID, _):
                guard session.layerID == layerID else { continue }
                guard !session.currentStrokePackets.isEmpty else {
                    session.brushSamplingStates.removeAll(keepingCapacity: true)
                    session.opacityCapSessions.removeAll(keepingCapacity: true)
                    session.strokeBeganAtUptimeNs = nil
                    continue
                }

                let orderedStreamIDs = session.currentStrokePackets.reduce(into: [BrushStrokeStreamID]()) { result, stroke in
                    guard !result.contains(stroke.brushStreamID) else { return }
                    result.append(stroke.brushStreamID)
                }
                var renderedPixelBounds: BrushPixelBounds?
                for streamID in orderedStreamIDs {
                    guard let lastStroke = session.currentStrokePackets.last(where: {
                        $0.brushStreamID == streamID
                    }) else { continue }
                    var flushSamplingState = session.brushSamplingStates[streamID]
                    flushSamplingState?.isFlushing = true
                    var flushStroke = StrokeDescriptor(
                        tool: lastStroke.tool,
                        color: lastStroke.color,
                        brush: lastStroke.brush,
                        points: [],
                        selectionShape: lastStroke.selectionShape,
                        alphaLockEnabled: lastStroke.alphaLockEnabled,
                        skipLeadingStamp: true,
                        paintVariationSeed: lastStroke.paintVariationSeed,
                        pigmentPalette: lastStroke.pigmentPalette
                    )
                    flushStroke.brushStreamID = streamID

                    if requiresStrokeMaskSession(lastStroke), let opacityCapSession = session.opacityCapSessions[streamID] {
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
                    if let bounds = flushSamplingState?.renderedPixelBounds {
                        renderedPixelBounds = renderedPixelBounds.map { $0.union(bounds) } ?? bounds
                    }
                }

                session.brushSamplingStates.removeAll(keepingCapacity: true)
                session.opacityCapSessions.removeAll(keepingCapacity: true)
                session.displayRevision &+= 1
                nextCommitRevision &+= 1
                commitQueue.enqueue(
                    BrushCommitJob(
                        layerID: layerID,
                        packets: session.currentStrokePackets,
                        needsTailFlush: true,
                        commitRevision: nextCommitRevision,
                        renderedPixelBounds: renderedPixelBounds
                    )
                )
                if auditEnabled {
                    PerformanceAuditStore.shared.recordInt(
                        "MetalStrokeEngine.stroke.packetCount",
                        value: session.currentStrokePackets.count
                    )
                    PerformanceAuditStore.shared.recordInt(
                        "MetalStrokeEngine.commitQueue.depth",
                        value: commitQueue.count
                    )
                }
                session.currentStrokePackets = []
                invalidateRecentBrushPreviewCache()
                if diagnosticsEnabled {
                    logger.debug("[brush-live] commitQueueDepth=\(self.commitQueue.count, privacy: .public)")
                }
            }
        }

        liveSession = session

        let encodeEndNs = DispatchTime.now().uptimeNanoseconds
        let enqueueToFlushMs = Double(flushStartNs - oldestEnqueueNs) / 1_000_000
        let flushEncodeMs = Double(encodeEndNs - flushStartNs) / 1_000_000
        let metrics = BrushFlushMetrics(
            packetQueuedCount: queuedPacketCount,
            flushedPacketCount: flushedPacketCount,
            enqueueToFlushMs: enqueueToFlushMs,
            flushEncodeMs: flushEncodeMs,
            usedSameFrameFlush: enqueueToFlushMs <= 16.7
        )

        if diagnosticsEnabled {
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
        }

        return metrics
    }

    func displayTexture(for layerID: LayerID) -> MTLTexture? {
        guard liveSession?.layerID == layerID, liveSession?.shouldRetainWorkingTexture == true else {
            return nil
        }
        if let previewTexture = recentBrushPreviewTextureIfNeeded(for: layerID) {
            return previewTexture
        }
        return liveSession?.workingTexture
    }

    func drainPendingBrushCommitJobs(beforeEachCommit: (BrushCommitJob) throws -> Void) throws {
        _ = try drainPendingBrushCommitJobs(
            retainedRecentBrushCommitJobs: 0,
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
            retainedRecentBrushCommitJobs: 0,
            mode: .interactiveBudget(maxJobs: maxJobs, maxCpuMs: maxCpuMs),
            hadLiveBrushWorkThisFrame: hadLiveBrushWorkThisFrame,
            beforeEachCommit: beforeEachCommit
        )
    }

    @discardableResult
    func opportunisticDrainPendingBrushCommitJobs(
        hadLiveBrushWorkThisFrame: Bool,
        maxJobs: Int,
        maxCpuMs: Double,
        retainedRecentBrushCommitJobs: Int,
        beforeEachCommit: (BrushCommitJob) throws -> Void
    ) throws -> BrushCommitDrainResult {
        try drainPendingBrushCommitJobs(
            retainedRecentBrushCommitJobs: retainedRecentBrushCommitJobs,
            mode: .interactiveBudget(maxJobs: maxJobs, maxCpuMs: maxCpuMs),
            hadLiveBrushWorkThisFrame: hadLiveBrushWorkThisFrame,
            beforeEachCommit: beforeEachCommit
        )
    }

    func resetBrushPipelineState() {
        liveSession?.shouldRetainWorkingTexture = false
        liveSession = nil
        clearRecentBrushAdjustment()
    }

    func makeOpacityCapSessionForImmediateStroke(texture: MTLTexture) -> OpacityCapSessionResources? {
        brushRenderer.makeOpacityCapSession(
            for: texture,
            commandQueue: metalContext.commandQueue
        )
    }

    @discardableResult
    func renderImmediateStroke(
        _ stroke: StrokeDescriptor,
        to texture: MTLTexture,
        alphaLockTexture: MTLTexture? = nil,
        preservesAlphaWhenAlphaLocked: Bool = true,
        samplingState: inout BrushStrokeSamplingState?
    ) -> Int {
        brushRenderer.render(
            stroke: stroke,
            into: texture,
            commandQueue: metalContext.commandQueue,
            alphaLockTexture: alphaLockTexture,
            preservesAlphaWhenAlphaLocked: preservesAlphaWhenAlphaLocked,
            samplingState: &samplingState
        )
    }

    @discardableResult
    func renderImmediateOpacityCapStroke(
        _ stroke: StrokeDescriptor,
        session: OpacityCapSessionResources,
        to texture: MTLTexture,
        alphaLockTexture: MTLTexture? = nil,
        preservesAlphaWhenAlphaLocked: Bool = true,
        samplingState: inout BrushStrokeSamplingState?
    ) -> Int {
        brushRenderer.renderOpacityCap(
            stroke: stroke,
            session: session,
            into: texture,
            commandQueue: metalContext.commandQueue,
            alphaLockTexture: alphaLockTexture,
            preservesAlphaWhenAlphaLocked: preservesAlphaWhenAlphaLocked,
            samplingState: &samplingState
        )
    }

    private func ensureLiveSession(for layerID: LayerID, now: UInt64) -> LiveSessionReuseState? {
        let auditEnabled = PerformanceAuditStore.shared.isRecordingEnabled
        let startNs = auditEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if auditEnabled {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000
                PerformanceAuditStore.shared.recordDuration("MetalStrokeEngine.ensureLiveSession", ms: ms)
            }
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
        retainedRecentBrushCommitJobs: Int,
        mode: BrushCommitDrainMode,
        hadLiveBrushWorkThisFrame: Bool,
        beforeEachCommit: (BrushCommitJob) throws -> Void
    ) throws -> BrushCommitDrainResult {
        let now = DispatchTime.now().uptimeNanoseconds
        updateInteractiveState(now: now)
        let queueSnapshot = commitQueue.snapshot()
        let selectedRecentCommitRevisions = selectedRecentCommitRevisions(in: queueSnapshot)

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

        if RuntimeDiagnostics.brushHotPathLoggingEnabled {
            logger.debug("[brush-live] warmIdleHit=\(warmIdleHit, privacy: .public)")
            logger.debug("[brush-live] commitQueueDepth=\(self.commitQueue.count, privacy: .public)")
            logger.debug("[brush-live] commitDrainSkippedForInteractiveFrame=\(shouldSkipForInteractiveFrame, privacy: .public)")
        }
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
        var lastCommittedRevisionForLiveLayer: UInt64?
        let protectedRecentBrushCommits = protectedRecentBrushCommitCount(
            in: queueSnapshot,
            retainedRecentBrushCommitJobs: retainedRecentBrushCommitJobs
        )

        while drainedJobs < maxJobs {
            if case .interactiveBudget = mode,
               protectedRecentBrushCommits > 0,
               commitQueue.count <= protectedRecentBrushCommits {
                break
            }
            guard let job = commitQueue.dequeue() else {
                break
            }
            try beforeEachCommit(job)
            // History checkpoints are captured before each commit. We must advance the
            // texture one job at a time here so the next checkpoint sees the latest
            // committed pixels rather than the original pre-drain texture.
            try commit(
                job: job,
                selectedRecentCommitRevisions: selectedRecentCommitRevisions,
                waitForCompletion: mode == .forced
            )
            if job.layerID == liveSession?.layerID {
                lastCommittedRevisionForLiveLayer = job.commitRevision
            }
            drainedJobs += 1

            if maxCpuNs != .max {
                let elapsedNs = DispatchTime.now().uptimeNanoseconds - drainStartNs
                if elapsedNs >= maxCpuNs {
                    break
                }
            }
        }

        if drainedJobs > 0 {
            if let lastCommittedRevisionForLiveLayer {
                liveSession?.committedRevision = lastCommittedRevisionForLiveLayer
            }
            invalidateRecentBrushPreviewCache()
        }

        if RuntimeDiagnostics.brushHotPathLoggingEnabled {
            logger.debug("[brush-live] commitQueueDepth=\(self.commitQueue.count, privacy: .public)")
        }
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

    private func commit(
        job: BrushCommitJob,
        selectedRecentCommitRevisions: Set<UInt64>,
        waitForCompletion: Bool
    ) throws {
        try commitBatch(
            [job],
            selectedRecentCommitRevisions: selectedRecentCommitRevisions,
            waitForCompletion: waitForCompletion
        )
    }

    private func commitBatch(
        _ jobs: [BrushCommitJob],
        selectedRecentCommitRevisions: Set<UInt64>,
        waitForCompletion: Bool
    ) throws {
        let auditEnabled = PerformanceAuditStore.shared.isRecordingEnabled
        let startNs = auditEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if auditEnabled {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000
                PerformanceAuditStore.shared.recordDuration("MetalStrokeEngine.commit(job:)", ms: ms)
            }
        }
        guard let commandBuffer = metalContext.commandQueue.makeCommandBuffer() else {
            return
        }

        debugLastCommitSmudgeFullSizeCopyCount = 0
        for job in jobs {
            guard
                let surfaceID = layerSurfaceStore.surfaceID(for: job.layerID),
                let texture = layerSurfaceStore.texture(for: surfaceID)
            else {
                continue
            }

            let opacityMultiplier = selectedRecentCommitRevisions.contains(job.commitRevision)
                ? recentBrushAdjustmentState?.opacity ?? 1
                : 1
            let brightnessAdjustment = selectedRecentCommitRevisions.contains(job.commitRevision)
                ? recentBrushAdjustmentState?.brightness ?? 0
                : 0
            let saturationAdjustment = selectedRecentCommitRevisions.contains(job.commitRevision)
                ? recentBrushAdjustmentState?.saturation ?? 0
                : 0
            encode(
                job: job,
                into: texture,
                commandBuffer: commandBuffer,
                opacityMultiplier: opacityMultiplier,
                brightnessAdjustment: brightnessAdjustment,
                saturationAdjustment: saturationAdjustment
            )
        }

        commandBuffer.commit()
        if waitForCompletion {
            commandBuffer.waitUntilCompleted()
        }
    }

    private func recentBrushPreviewTextureIfNeeded(for layerID: LayerID) -> MTLTexture? {
        guard let liveSession,
              liveSession.layerID == layerID,
              liveSession.liveEvents.isEmpty,
              let adjustmentState = recentBrushAdjustmentState,
              adjustmentState.layerID == layerID else {
            return nil
        }

        let queueSnapshot = commitQueue.snapshot().filter { $0.layerID == layerID }
        let selectedRecentCommitRevisions = selectedRecentCommitRevisions(in: queueSnapshot)
        guard !selectedRecentCommitRevisions.isEmpty,
              let sourceSurfaceID = layerSurfaceStore.surfaceID(for: layerID),
              let sourceTexture = layerSurfaceStore.texture(for: sourceSurfaceID) else {
            return nil
        }

        let previewKey = RecentBrushPreviewKey(
            layerID: layerID,
            selectedRecentCount: adjustmentState.selectedRecentCount,
            opacity: adjustmentState.opacity,
            brightness: adjustmentState.brightness,
            saturation: adjustmentState.saturation,
            showsSelectionHighlight: adjustmentState.showsSelectionHighlight,
            committedRevision: liveSession.committedRevision,
            displayRevision: liveSession.displayRevision,
            pendingCommitRevisions: queueSnapshot.map(\.commitRevision)
        )
        if recentBrushPreviewKey == previewKey, let recentBrushPreviewTexture {
            return recentBrushPreviewTexture
        }

        guard let previewBaseTexture = recentBrushPreviewBaseTextureIfNeeded(
            for: layerID,
            sourceTexture: sourceTexture,
            queueSnapshot: queueSnapshot,
            selectedRecentCommitRevisions: selectedRecentCommitRevisions,
            committedRevision: liveSession.committedRevision,
            displayRevision: liveSession.displayRevision
        ), let previewTexture = layerSurfaceStore.makeTexture(
            width: sourceTexture.width,
            height: sourceTexture.height,
            pixelFormat: sourceTexture.pixelFormat,
            metal: metalContext
        ), let commandBuffer = metalContext.commandQueue.makeCommandBuffer() else {
            return nil
        }

        layerSurfaceStore.copyTexture(from: previewBaseTexture, to: previewTexture, metal: metalContext)
        for job in queueSnapshot where selectedRecentCommitRevisions.contains(job.commitRevision) {
            encode(
                job: job,
                into: previewTexture,
                commandBuffer: commandBuffer,
                opacityMultiplier: adjustmentState.opacity,
                brightnessAdjustment: adjustmentState.brightness,
                saturationAdjustment: adjustmentState.saturation,
                colorTint: adjustmentState.showsSelectionHighlight ? recentBrushHighlightColor : nil,
                colorTintAmount: adjustmentState.showsSelectionHighlight ? 0.22 : 0
            )
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        recentBrushPreviewTexture = previewTexture
        recentBrushPreviewKey = previewKey
        return previewTexture
    }

    private func recentBrushPreviewBaseTextureIfNeeded(
        for layerID: LayerID,
        sourceTexture: MTLTexture,
        queueSnapshot: [BrushCommitJob],
        selectedRecentCommitRevisions: Set<UInt64>,
        committedRevision: UInt64,
        displayRevision: UInt64
    ) -> MTLTexture? {
        let baseKey = RecentBrushPreviewBaseKey(
            layerID: layerID,
            selectedRecentCount: recentBrushAdjustmentState?.selectedRecentCount ?? 0,
            committedRevision: committedRevision,
            displayRevision: displayRevision,
            pendingCommitRevisions: queueSnapshot.map(\.commitRevision)
        )
        if recentBrushPreviewBaseKey == baseKey, let recentBrushPreviewBaseTexture {
            return recentBrushPreviewBaseTexture
        }

        guard let previewBaseTexture = layerSurfaceStore.makeTexture(
            width: sourceTexture.width,
            height: sourceTexture.height,
            pixelFormat: sourceTexture.pixelFormat,
            metal: metalContext
        ), let commandBuffer = metalContext.commandQueue.makeCommandBuffer() else {
            return nil
        }

        layerSurfaceStore.copyTexture(from: sourceTexture, to: previewBaseTexture, metal: metalContext)
        for job in queueSnapshot where !selectedRecentCommitRevisions.contains(job.commitRevision) {
            encode(
                job: job,
                into: previewBaseTexture,
                commandBuffer: commandBuffer,
                opacityMultiplier: 1
            )
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        recentBrushPreviewBaseTexture = previewBaseTexture
        recentBrushPreviewBaseKey = baseKey
        return previewBaseTexture
    }

    private func encode(
        job: BrushCommitJob,
        into texture: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        opacityMultiplier: Float,
        brightnessAdjustment: Float = 0,
        saturationAdjustment: Float = 0,
        colorOverride: RGBAColor? = nil,
        colorTint: RGBAColor? = nil,
        colorTintAmount: Float = 0
    ) {
        var samplingStates: [BrushStrokeStreamID: BrushStrokeSamplingState] = [:]
        var opacityCapSessions: [BrushStrokeStreamID: OpacityCapSessionResources] = [:]
        let usesAlphaLock = job.packets.contains(where: \.alphaLockEnabled)
        let alphaLockTexture = usesAlphaLock ? makeAlphaLockTextureCopy(from: texture) : nil

        for packet in job.packets {
            let adjustedPacket = adjustedStroke(
                packet,
                opacityMultiplier: opacityMultiplier,
                brightnessAdjustment: brightnessAdjustment,
                saturationAdjustment: saturationAdjustment,
                colorOverride: colorOverride,
                colorTint: colorTint,
                colorTintAmount: colorTintAmount
            )
            let streamID = adjustedPacket.brushStreamID
            if requiresStrokeMaskSession(adjustedPacket), opacityCapSessions[streamID] == nil,
               let opacityCapSession = brushRenderer.makeOpacityCapSession(
                    for: texture,
                    commandQueue: metalContext.commandQueue,
                    reusesCachedTextures: streamID == .primary
               ) {
                opacityCapSessions[streamID] = opacityCapSession
            }

            var streamSamplingState = samplingStates[streamID]
            if requiresStrokeMaskSession(adjustedPacket), let opacityCapSession = opacityCapSessions[streamID] {
                _ = brushRenderer.encodeOpacityCapStroke(
                    stroke: adjustedPacket,
                    session: opacityCapSession,
                    into: texture,
                    commandBuffer: commandBuffer,
                    alphaLockTexture: adjustedPacket.alphaLockEnabled ? alphaLockTexture : nil,
                    samplingState: &streamSamplingState
                )
            } else {
                _ = brushRenderer.encodeStroke(
                    stroke: adjustedPacket,
                    into: texture,
                    commandQueue: metalContext.commandQueue,
                    commandBuffer: commandBuffer,
                    alphaLockTexture: adjustedPacket.alphaLockEnabled ? alphaLockTexture : nil,
                    samplingState: &streamSamplingState
                )
            }
            if let streamSamplingState {
                samplingStates[streamID] = streamSamplingState
            } else {
                samplingStates.removeValue(forKey: streamID)
            }
        }

        if job.needsTailFlush {
            let orderedStreamIDs = job.packets.reduce(into: [BrushStrokeStreamID]()) { result, stroke in
                guard !result.contains(stroke.brushStreamID) else { return }
                result.append(stroke.brushStreamID)
            }
            for streamID in orderedStreamIDs {
                guard let lastStroke = job.packets.last(where: {
                    $0.brushStreamID == streamID
                }) else { continue }
                let adjustedLastStroke = adjustedStroke(
                    lastStroke,
                    opacityMultiplier: opacityMultiplier,
                    brightnessAdjustment: brightnessAdjustment,
                    saturationAdjustment: saturationAdjustment,
                    colorOverride: colorOverride,
                    colorTint: colorTint,
                    colorTintAmount: colorTintAmount
                )
                var flushSamplingState = samplingStates[streamID]
                flushSamplingState?.isFlushing = true
                var flushStroke = StrokeDescriptor(
                    tool: adjustedLastStroke.tool,
                    color: adjustedLastStroke.color,
                    brush: adjustedLastStroke.brush,
                    points: [],
                    selectionShape: adjustedLastStroke.selectionShape,
                    alphaLockEnabled: adjustedLastStroke.alphaLockEnabled,
                    skipLeadingStamp: true,
                    paintVariationSeed: adjustedLastStroke.paintVariationSeed,
                    pigmentPalette: adjustedLastStroke.pigmentPalette
                )
                flushStroke.brushStreamID = streamID

                if requiresStrokeMaskSession(adjustedLastStroke), let opacityCapSession = opacityCapSessions[streamID] {
                    _ = brushRenderer.encodeOpacityCapStroke(
                        stroke: flushStroke,
                        session: opacityCapSession,
                        into: texture,
                        commandBuffer: commandBuffer,
                        alphaLockTexture: adjustedLastStroke.alphaLockEnabled ? alphaLockTexture : nil,
                        samplingState: &flushSamplingState
                    )
                } else {
                    _ = brushRenderer.encodeStroke(
                        stroke: flushStroke,
                        into: texture,
                        commandQueue: metalContext.commandQueue,
                        commandBuffer: commandBuffer,
                        alphaLockTexture: adjustedLastStroke.alphaLockEnabled ? alphaLockTexture : nil,
                        samplingState: &flushSamplingState
                    )
                }
            }
        }
    }

    private func adjustedStroke(
        _ stroke: StrokeDescriptor,
        opacityMultiplier: Float,
        brightnessAdjustment: Float,
        saturationAdjustment: Float,
        colorOverride: RGBAColor?,
        colorTint: RGBAColor?,
        colorTintAmount: Float
    ) -> StrokeDescriptor {
        var adjustedStroke = stroke
        adjustedStroke.brush.opacity = min(max(stroke.brush.opacity * opacityMultiplier, 0), 1)
        var adjustedColor = stroke.color
        if let colorOverride {
            adjustedColor = colorOverride.withAlpha(stroke.color.alpha)
        } else if let colorTint, colorTintAmount > 0 {
            adjustedColor = blendedColor(
                from: stroke.color,
                toward: colorTint,
                amount: colorTintAmount
            )
        }
        adjustedStroke.color = applyRecentBrushColorAdjustments(
            to: adjustedColor,
            brightnessAdjustment: brightnessAdjustment,
            saturationAdjustment: saturationAdjustment
        )
        if !stroke.pigmentPalette.components.isEmpty {
            adjustedStroke.pigmentPalette = BrushPigmentPalette(
                components: stroke.pigmentPalette.components.map { component in
                    var componentColor = component.color
                    if let colorOverride {
                        componentColor = colorOverride.withAlpha(component.color.alpha)
                    } else if let colorTint, colorTintAmount > 0 {
                        componentColor = blendedColor(
                            from: component.color,
                            toward: colorTint,
                            amount: colorTintAmount
                        )
                    }
                    componentColor = applyRecentBrushColorAdjustments(
                        to: componentColor,
                        brightnessAdjustment: brightnessAdjustment,
                        saturationAdjustment: saturationAdjustment
                    )
                    return BrushPigmentComponent(color: componentColor, weight: component.weight)
                }
            )
        }
        return adjustedStroke
    }

    private func blendedColor(from source: RGBAColor, toward target: RGBAColor, amount: Float) -> RGBAColor {
        let clampedAmount = min(max(amount, 0), 1)
        let inverseAmount = 1 - clampedAmount
        return RGBAColor(
            red: (source.red * inverseAmount) + (target.red * clampedAmount),
            green: (source.green * inverseAmount) + (target.green * clampedAmount),
            blue: (source.blue * inverseAmount) + (target.blue * clampedAmount),
            alpha: source.alpha
        )
    }

    private func applyRecentBrushColorAdjustments(
        to color: RGBAColor,
        brightnessAdjustment: Float,
        saturationAdjustment: Float
    ) -> RGBAColor {
        guard abs(brightnessAdjustment) > 0.001 || abs(saturationAdjustment) > 0.001 else {
            return color
        }

        var hsv = ColorBlocksEngine.rgbToHsv(color)
        hsv.v = min(max(hsv.v + brightnessAdjustment, 0), 1)
        hsv.s = min(max(hsv.s + saturationAdjustment, 0), 1)
        return ColorBlocksEngine.hsvToRgb(hsv, alpha: color.alpha)
    }

    private func selectedRecentCommitRevisions(in queueSnapshot: [BrushCommitJob]) -> Set<UInt64> {
        guard let adjustmentState = recentBrushAdjustmentState else {
            return []
        }
        let recentBrushJobs = queueSnapshot
            .filter { $0.layerID == adjustmentState.layerID && $0.packets.last?.tool == .brush }
        guard !recentBrushJobs.isEmpty, adjustmentState.selectedRecentCount > 0 else {
            return []
        }
        let selectedJobs = recentBrushJobs.suffix(adjustmentState.selectedRecentCount)
        return Set(selectedJobs.map(\.commitRevision))
    }

    private func protectedRecentBrushCommitCount(
        in queueSnapshot: [BrushCommitJob],
        retainedRecentBrushCommitJobs: Int
    ) -> Int {
        guard retainedRecentBrushCommitJobs > 0 else {
            return 0
        }
        let protectedBrushCount = min(
            retainedRecentBrushCommitJobs,
            queueSnapshot.reversed().prefix {
                $0.packets.last?.tool == .brush
            }.count
        )
        return max(protectedBrushCount, selectedRecentCommitRevisions(in: queueSnapshot).count)
    }

    private func invalidateRecentBrushPreviewCache() {
        recentBrushPreviewBaseTexture = nil
        recentBrushPreviewBaseKey = nil
        invalidateRecentBrushPreviewResult()
    }

    private func invalidateRecentBrushPreviewResult() {
        recentBrushPreviewTexture = nil
        recentBrushPreviewKey = nil
    }

    private func isBrushLike(_ tool: ToolKind) -> Bool {
        tool == .brush || tool == .eraser || tool == .smudge
    }

    private func requiresStrokeMaskSession(_ stroke: StrokeDescriptor) -> Bool {
        (stroke.tool == .brush || stroke.tool == .eraser) && stroke.brush.requiresStrokeMaskSession
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

        layerSurfaceStore.copyTextureAsync(
            from: sourceTexture,
            to: alphaLockTexture,
            metal: metalContext
        )
        return alphaLockTexture
    }
}

func shouldScheduleInteractiveBrushCommitDrain(
    queueDepth: Int,
    protectedCommitCount: Int,
    hadLiveBrushWorkThisFrame: Bool,
    hasActiveStroke: Bool,
    hasWarmIdleSession: Bool
) -> Bool {
    guard queueDepth > max(protectedCommitCount, 0) else { return false }
    return !hadLiveBrushWorkThisFrame && !hasActiveStroke && !hasWarmIdleSession
}

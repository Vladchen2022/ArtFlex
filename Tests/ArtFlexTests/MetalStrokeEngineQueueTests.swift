import Metal
import Testing
@testable import ArtFlex

struct MetalStrokeEngineQueueTests {
    @Test
    func brushPacketsEnqueueAndFlushFromFrameCommandBuffer() {
        guard
            let metalContext = MetalDeviceContext(),
            let commandBuffer = metalContext.commandQueue.makeCommandBuffer()
        else {
            Issue.record("Metal unavailable")
            return
        }

        let surfaceStore = StageOneLayerSurfaceStore()
        let document = ArtDocument.stageOneDefault()
        surfaceStore.prepareTextures(for: document, metal: metalContext)
        let layerID = document.activeLayerID

        let engine = MetalStrokeEngine(
            metalContext: metalContext,
            layerSurfaceStore: surfaceStore
        )

        engine.beginStrokeIfNeeded(
            toolSession: .stageOneDefault,
            layerID: layerID
        )

        let queuedCount = engine.applyStroke(
            StrokeDescriptor(
                tool: .brush,
                color: .black,
                brush: .stageOneDefault,
                points: [
                    .init(x: 10, y: 10, pressure: 1),
                    .init(x: 40, y: 20, pressure: 1)
                ],
                selectionShape: nil,
                skipLeadingStamp: false
            ),
            to: layerID
        )

        #expect(queuedCount == 1)
        #expect(engine.hasPendingBrushWork)

        let metrics = engine.flushPendingStrokePackets(into: commandBuffer)
        #expect(metrics != nil)
        #expect(metrics?.packetQueuedCount == 1)
        #expect(metrics?.flushedPacketCount == 1)
        #expect(engine.hasPendingBrushWork == false)
    }

    @Test
    func endStrokeFlushesPendingTailWithinFlushPass() {
        guard
            let metalContext = MetalDeviceContext(),
            let commandBuffer = metalContext.commandQueue.makeCommandBuffer()
        else {
            Issue.record("Metal unavailable")
            return
        }

        let surfaceStore = StageOneLayerSurfaceStore()
        let document = ArtDocument.stageOneDefault()
        surfaceStore.prepareTextures(for: document, metal: metalContext)
        let layerID = document.activeLayerID

        let engine = MetalStrokeEngine(
            metalContext: metalContext,
            layerSurfaceStore: surfaceStore
        )

        engine.beginStrokeIfNeeded(
            toolSession: .stageOneDefault,
            layerID: layerID
        )

        _ = engine.applyStroke(
            StrokeDescriptor(
                tool: .brush,
                color: .black,
                brush: .stageOneDefault,
                points: [
                    .init(x: 20, y: 20, pressure: 1)
                ],
                selectionShape: nil,
                skipLeadingStamp: false
            ),
            to: layerID
        )

        engine.endStroke()
        #expect(engine.hasPendingBrushWork)

        let metrics = engine.flushPendingStrokePackets(into: commandBuffer)
        #expect(metrics != nil)
        #expect(engine.hasPendingBrushWork == false)
    }

    @Test
    func endingStrokeFreezesCommitJobAndKeepsWorkingTextureAvailable() throws {
        guard
            let metalContext = MetalDeviceContext(),
            let commandBuffer = metalContext.commandQueue.makeCommandBuffer()
        else {
            Issue.record("Metal unavailable")
            return
        }

        let surfaceStore = StageOneLayerSurfaceStore()
        let document = ArtDocument.stageOneDefault()
        surfaceStore.prepareTextures(for: document, metal: metalContext)
        let layerID = document.activeLayerID

        let engine = MetalStrokeEngine(
            metalContext: metalContext,
            layerSurfaceStore: surfaceStore
        )

        engine.beginStrokeIfNeeded(
            toolSession: .stageOneDefault,
            layerID: layerID
        )

        _ = engine.applyStroke(
            StrokeDescriptor(
                tool: .brush,
                color: .black,
                brush: .stageOneDefault,
                points: [
                    .init(x: 12, y: 12, pressure: 1),
                    .init(x: 48, y: 28, pressure: 1)
                ],
                selectionShape: nil,
                skipLeadingStamp: false
            ),
            to: layerID
        )

        engine.endStroke()
        _ = engine.flushPendingStrokePackets(into: commandBuffer)

        #expect(engine.displayTexture(for: layerID) != nil)
        #expect(engine.hasPendingBrushCommitJobs)

        var checkpointCount = 0
        try engine.drainPendingBrushCommitJobs {
            checkpointCount += 1
        }

        #expect(checkpointCount == 1)
        #expect(engine.hasPendingBrushCommitJobs == false)
    }

    @Test
    func warmIdleSessionReusesWorkingTextureAndSkipsInteractiveDrain() throws {
        guard
            let metalContext = MetalDeviceContext(),
            let commandBuffer = metalContext.commandQueue.makeCommandBuffer()
        else {
            Issue.record("Metal unavailable")
            return
        }

        let surfaceStore = StageOneLayerSurfaceStore()
        let document = ArtDocument.stageOneDefault()
        surfaceStore.prepareTextures(for: document, metal: metalContext)
        let layerID = document.activeLayerID

        let engine = MetalStrokeEngine(
            metalContext: metalContext,
            layerSurfaceStore: surfaceStore
        )

        engine.beginStrokeIfNeeded(
            toolSession: .stageOneDefault,
            layerID: layerID
        )
        _ = engine.applyStroke(
            StrokeDescriptor(
                tool: .brush,
                color: .black,
                brush: .stageOneDefault,
                points: [
                    .init(x: 18, y: 18, pressure: 1),
                    .init(x: 36, y: 36, pressure: 1)
                ],
                selectionShape: nil,
                skipLeadingStamp: false
            ),
            to: layerID
        )
        engine.endStroke()
        _ = engine.flushPendingStrokePackets(into: commandBuffer)

        guard let beforeBeginTexture = engine.displayTexture(for: layerID) else {
            Issue.record("Expected working texture before next stroke")
            return
        }

        let interactiveDrain = try engine.opportunisticDrainPendingBrushCommitJobs(
            hadLiveBrushWorkThisFrame: false,
            maxJobs: 1,
            maxCpuMs: 0.75
        ) {}

        #expect(interactiveDrain.drainedJobs == 0)
        #expect(interactiveDrain.skippedForInteractiveFrame)
        #expect(engine.hasPendingBrushCommitJobs)

        engine.beginStrokeIfNeeded(
            toolSession: .stageOneDefault,
            layerID: layerID
        )

        guard let afterBeginTexture = engine.displayTexture(for: layerID) else {
            Issue.record("Expected reused working texture after next stroke begin")
            return
        }
        #expect(ObjectIdentifier(beforeBeginTexture as AnyObject) == ObjectIdentifier(afterBeginTexture as AnyObject))
    }
}

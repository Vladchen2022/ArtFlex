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
}

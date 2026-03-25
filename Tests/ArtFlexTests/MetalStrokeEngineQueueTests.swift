import Metal
import Testing
@testable import ArtFlex

struct MetalStrokeEngineQueueTests {
    @Test
    func brushPacketsEnqueueAndFlushFromFrameCommandBuffer() throws {
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

        let engine = try MetalStrokeEngine(
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
    func endStrokeFlushesPendingTailWithinFlushPass() throws {
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

        let engine = try MetalStrokeEngine(
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

        let engine = try MetalStrokeEngine(
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
        try engine.drainPendingBrushCommitJobs { _ in
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

        let engine = try MetalStrokeEngine(
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
        ) { _ in }

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

    @Test
    func smudgeLiveSessionReusesSingleFullSizeSourceTextureAcrossPackets() throws {
        guard
            let metalContext = MetalDeviceContext(),
            let firstCommandBuffer = metalContext.commandQueue.makeCommandBuffer(),
            let secondCommandBuffer = metalContext.commandQueue.makeCommandBuffer()
        else {
            Issue.record("Metal unavailable")
            return
        }

        let surfaceStore = StageOneLayerSurfaceStore()
        let document = ArtDocument.stageOneDefault()
        surfaceStore.prepareTextures(for: document, metal: metalContext)
        let layerID = document.activeLayerID

        let engine = try MetalStrokeEngine(
            metalContext: metalContext,
            layerSurfaceStore: surfaceStore
        )

        let smudgeSession = ToolSessionState(
            activeTool: .smudge,
            brush: .stageOneDefault,
            selectedColor: .black
        )

        engine.beginStrokeIfNeeded(
            toolSession: smudgeSession,
            layerID: layerID
        )

        _ = engine.applyStroke(
            StrokeDescriptor(
                tool: .smudge,
                color: .black,
                brush: .stageOneDefault,
                points: [
                    .init(x: 16, y: 24, pressure: 1),
                    .init(x: 32, y: 40, pressure: 1),
                    .init(x: 48, y: 48, pressure: 1)
                ],
                selectionShape: nil,
                skipLeadingStamp: false
            ),
            to: layerID
        )
        _ = engine.flushPendingStrokePackets(into: firstCommandBuffer)
        firstCommandBuffer.commit()
        firstCommandBuffer.waitUntilCompleted()

        guard let firstSmudgeSourceTextureIdentifier = engine.debugLiveSmudgeSourceTextureIdentifier else {
            Issue.record("Expected live smudge source texture after first flush")
            return
        }

        _ = engine.applyStroke(
            StrokeDescriptor(
                tool: .smudge,
                color: .black,
                brush: .stageOneDefault,
                points: [
                    .init(x: 40, y: 28, pressure: 1),
                    .init(x: 56, y: 44, pressure: 1),
                    .init(x: 72, y: 56, pressure: 1)
                ],
                selectionShape: nil,
                skipLeadingStamp: false
            ),
            to: layerID
        )
        _ = engine.flushPendingStrokePackets(into: secondCommandBuffer)
        secondCommandBuffer.commit()
        secondCommandBuffer.waitUntilCompleted()

        #expect(engine.debugLiveSmudgeSourceTextureIdentifier == firstSmudgeSourceTextureIdentifier)
    }

    @Test
    func smudgeCommitReplayReusesSingleFullSizeSourceTextureAcrossPackets() throws {
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

        let engine = try MetalStrokeEngine(
            metalContext: metalContext,
            layerSurfaceStore: surfaceStore
        )

        let smudgeSession = ToolSessionState(
            activeTool: .smudge,
            brush: .stageOneDefault,
            selectedColor: .black
        )

        engine.beginStrokeIfNeeded(
            toolSession: smudgeSession,
            layerID: layerID
        )

        for offset in 0..<2 {
            _ = engine.applyStroke(
                StrokeDescriptor(
                    tool: .smudge,
                    color: .black,
                    brush: .stageOneDefault,
                    points: [
                        .init(x: Double(20 + offset * 22), y: 20, pressure: 1),
                        .init(x: Double(38 + offset * 22), y: 34, pressure: 1),
                        .init(x: Double(50 + offset * 22), y: 46, pressure: 1)
                    ],
                    selectionShape: nil,
                    skipLeadingStamp: false
                ),
                to: layerID
            )
        }

        engine.endStroke()
        _ = engine.flushPendingStrokePackets(into: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        try engine.drainPendingBrushCommitJobs { _ in }

        #expect(engine.debugLastCommitSmudgeSourceTextureAllocationCount == 1)
    }

    @Test
    func smudgeReusableSourceTextureMatchesFreshAllocationOutput() throws {
        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal unavailable")
            return
        }

        let surfaceStore = StageOneLayerSurfaceStore()
        let serializer = LayerTextureSerializer(metalContext: metalContext)
        let renderer = try StageOneBrushRenderer(device: metalContext.device)

        guard
            let reusedTexture = surfaceStore.makeTexture(width: 96, height: 96, metal: metalContext),
            let freshTexture = surfaceStore.makeTexture(width: 96, height: 96, metal: metalContext),
            let commandBufferA = metalContext.commandQueue.makeCommandBuffer(),
            let commandBufferB = metalContext.commandQueue.makeCommandBuffer()
        else {
            Issue.record("Texture unavailable")
            return
        }

        let seedSnapshot = gradientSnapshot(width: 96, height: 96)
        try serializer.restore(snapshot: seedSnapshot, into: reusedTexture)
        try serializer.restore(snapshot: seedSnapshot, into: freshTexture)

        let packets: [StrokeDescriptor] = [
            StrokeDescriptor(
                tool: .smudge,
                color: .black,
                brush: .stageOneDefault,
                points: [
                    .init(x: 18, y: 18, pressure: 1),
                    .init(x: 36, y: 30, pressure: 1),
                    .init(x: 50, y: 42, pressure: 1)
                ],
                selectionShape: nil,
                skipLeadingStamp: false
            ),
            StrokeDescriptor(
                tool: .smudge,
                color: .black,
                brush: .stageOneDefault,
                points: [
                    .init(x: 46, y: 44, pressure: 1),
                    .init(x: 58, y: 56, pressure: 1),
                    .init(x: 70, y: 70, pressure: 1)
                ],
                selectionShape: nil,
                skipLeadingStamp: false
            )
        ]

        var reusedSamplingState: BrushStrokeSamplingState?
        var reusedSmudgeSourceTexture: MTLTexture?
        for packet in packets {
            _ = renderer.encodeStroke(
                stroke: packet,
                into: reusedTexture,
                commandQueue: metalContext.commandQueue,
                commandBuffer: commandBufferA,
                samplingState: &reusedSamplingState,
                reusableSmudgeSourceTexture: &reusedSmudgeSourceTexture
            )
        }

        if let lastPacket = packets.last {
            var flushSamplingState = reusedSamplingState
            flushSamplingState?.isFlushing = true
            _ = renderer.encodeStroke(
                stroke: StrokeDescriptor(
                    tool: .smudge,
                    color: lastPacket.color,
                    brush: lastPacket.brush,
                    points: [],
                    selectionShape: nil,
                    skipLeadingStamp: true
                ),
                into: reusedTexture,
                commandQueue: metalContext.commandQueue,
                commandBuffer: commandBufferA,
                samplingState: &flushSamplingState,
                reusableSmudgeSourceTexture: &reusedSmudgeSourceTexture
            )
        }

        var freshSamplingState: BrushStrokeSamplingState?
        for packet in packets {
            var freshSmudgeSourceTexture: MTLTexture?
            _ = renderer.encodeStroke(
                stroke: packet,
                into: freshTexture,
                commandQueue: metalContext.commandQueue,
                commandBuffer: commandBufferB,
                samplingState: &freshSamplingState,
                reusableSmudgeSourceTexture: &freshSmudgeSourceTexture
            )
        }

        if let lastPacket = packets.last {
            var flushSamplingState = freshSamplingState
            flushSamplingState?.isFlushing = true
            var freshSmudgeSourceTexture: MTLTexture?
            _ = renderer.encodeStroke(
                stroke: StrokeDescriptor(
                    tool: .smudge,
                    color: lastPacket.color,
                    brush: lastPacket.brush,
                    points: [],
                    selectionShape: nil,
                    skipLeadingStamp: true
                ),
                into: freshTexture,
                commandQueue: metalContext.commandQueue,
                commandBuffer: commandBufferB,
                samplingState: &flushSamplingState,
                reusableSmudgeSourceTexture: &freshSmudgeSourceTexture
            )
        }

        commandBufferA.commit()
        commandBufferB.commit()
        commandBufferA.waitUntilCompleted()
        commandBufferB.waitUntilCompleted()

        let reusedSnapshot = try serializer.snapshot(texture: reusedTexture)
        let freshSnapshot = try serializer.snapshot(texture: freshTexture)

        #expect(reusedSnapshot == freshSnapshot)
    }
}

private func gradientSnapshot(width: Int, height: Int) -> LayerTextureSnapshot {
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * bytesPerRow) + (x * 4)
            pixels[offset] = UInt8((x * 255) / max(width - 1, 1))
            pixels[offset + 1] = UInt8((y * 255) / max(height - 1, 1))
            pixels[offset + 2] = UInt8(((x + y) * 255) / max(width + height - 2, 1))
            pixels[offset + 3] = 255
        }
    }
    return LayerTextureSnapshot(
        width: width,
        height: height,
        bytesPerRow: bytesPerRow,
        pixelData: Data(pixels)
    )
}

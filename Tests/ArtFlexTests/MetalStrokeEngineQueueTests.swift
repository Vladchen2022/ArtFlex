import Metal
import Testing
@testable import ArtFlex

struct MetalStrokeEngineQueueTests {
    @Test
    func paintJitterSeedIsDeterministicVariedAndAlphaNeutral() throws {
        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal unavailable")
            return
        }
        let renderer = try StageOneBrushRenderer(device: metalContext.device)

        let first = try renderPaintJitterSnapshot(
            metalContext: metalContext,
            renderer: renderer,
            seed: 0x1234_5678,
            amount: 1,
            buildMode: .buildUp
        )
        let replay = try renderPaintJitterSnapshot(
            metalContext: metalContext,
            renderer: renderer,
            seed: 0x1234_5678,
            amount: 1,
            buildMode: .buildUp
        )
        let variant = try renderPaintJitterSnapshot(
            metalContext: metalContext,
            renderer: renderer,
            seed: 0x9ABC_DEF0,
            amount: 1,
            buildMode: .buildUp
        )

        #expect(first.pixelData == replay.pixelData)
        #expect(first.pixelData != variant.pixelData)
        #expect(alphaBytes(in: first) == alphaBytes(in: variant))

        let zeroFirst = try renderPaintJitterSnapshot(
            metalContext: metalContext,
            renderer: renderer,
            seed: 1,
            amount: 0,
            buildMode: .buildUp
        )
        let zeroVariant = try renderPaintJitterSnapshot(
            metalContext: metalContext,
            renderer: renderer,
            seed: UInt32.max,
            amount: 0,
            buildMode: .buildUp
        )
        #expect(zeroFirst.pixelData == zeroVariant.pixelData)

        let seventyFivePercent = try renderPaintJitterSnapshot(
            metalContext: metalContext,
            renderer: renderer,
            seed: 0x1234_5678,
            amount: 0.75,
            buildMode: .buildUp
        )
        #expect(seventyFivePercent.pixelData != first.pixelData)

        let opacityCapFirst = try renderPaintJitterSnapshot(
            metalContext: metalContext,
            renderer: renderer,
            seed: 0x1234_5678,
            amount: 1,
            buildMode: .opacityCap
        )
        let opacityCapVariant = try renderPaintJitterSnapshot(
            metalContext: metalContext,
            renderer: renderer,
            seed: 0x9ABC_DEF0,
            amount: 1,
            buildMode: .opacityCap
        )
        #expect(opacityCapFirst.pixelData != opacityCapVariant.pixelData)
        #expect(alphaBytes(in: opacityCapFirst) == alphaBytes(in: opacityCapVariant))
    }

    @Test
    func interactiveCommitDrainSchedulingRejectsFutileMainThreadWork() {
        #expect(shouldScheduleInteractiveBrushCommitDrain(
            queueDepth: 0,
            protectedCommitCount: 0,
            hadLiveBrushWorkThisFrame: false,
            hasActiveStroke: false,
            hasWarmIdleSession: false
        ) == false)
        #expect(shouldScheduleInteractiveBrushCommitDrain(
            queueDepth: 1,
            protectedCommitCount: 1,
            hadLiveBrushWorkThisFrame: false,
            hasActiveStroke: false,
            hasWarmIdleSession: false
        ) == false)
        #expect(shouldScheduleInteractiveBrushCommitDrain(
            queueDepth: 2,
            protectedCommitCount: 0,
            hadLiveBrushWorkThisFrame: true,
            hasActiveStroke: false,
            hasWarmIdleSession: false
        ) == false)
        #expect(shouldScheduleInteractiveBrushCommitDrain(
            queueDepth: 2,
            protectedCommitCount: 0,
            hadLiveBrushWorkThisFrame: false,
            hasActiveStroke: false,
            hasWarmIdleSession: true
        ) == false)
        #expect(shouldScheduleInteractiveBrushCommitDrain(
            queueDepth: 2,
            protectedCommitCount: 1,
            hadLiveBrushWorkThisFrame: false,
            hasActiveStroke: false,
            hasWarmIdleSession: false
        ))
    }

    @Test
    func commitJobBoundsContainScatteredBrushOutput() throws {
        guard
            let metalContext = MetalDeviceContext(),
            let commandBuffer = metalContext.commandQueue.makeCommandBuffer()
        else {
            Issue.record("Metal unavailable")
            return
        }

        let surfaceStore = StageOneLayerSurfaceStore()
        var document = ArtDocument.stageOneDefault()
        document.canvasSize = .init(width: 256, height: 256)
        surfaceStore.prepareTextures(for: document, metal: metalContext)
        let layerID = document.activeLayerID
        let engine = try MetalStrokeEngine(
            metalContext: metalContext,
            layerSurfaceStore: surfaceStore
        )
        var brush = BrushSettings.stageOneDefault
        brush.size = 48
        brush.scatterAmount = 1
        brush.jitterAmount = 1

        engine.beginStrokeIfNeeded(
            toolSession: ToolSessionState(activeTool: .brush, brush: brush, selectedColor: .black),
            layerID: layerID
        )
        _ = engine.applyStroke(
            StrokeDescriptor(
                tool: .brush,
                color: .black,
                brush: brush,
                points: [
                    .init(x: 72, y: 80, pressure: 0.4),
                    .init(x: 128, y: 118, pressure: 0.75),
                    .init(x: 184, y: 168, pressure: 1)
                ],
                selectionShape: nil,
                skipLeadingStamp: false
            ),
            to: layerID
        )
        engine.endStroke()
        _ = engine.flushPendingStrokePackets(into: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var renderedBounds: BrushPixelBounds?
        try engine.drainPendingBrushCommitJobs { job in
            renderedBounds = job.renderedPixelBounds
        }
        let bounds = try #require(renderedBounds)
        #expect(bounds.width < document.canvasSize.width)
        #expect(bounds.height < document.canvasSize.height)

        guard
            let surfaceID = surfaceStore.surfaceID(for: layerID),
            let texture = surfaceStore.texture(for: surfaceID)
        else {
            Issue.record("Texture unavailable")
            return
        }
        let snapshot = try LayerTextureSerializer(metalContext: metalContext).snapshot(texture: texture)
        var actualMinX = snapshot.width
        var actualMinY = snapshot.height
        var actualMaxX = -1
        var actualMaxY = -1
        snapshot.pixelData.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for y in 0..<snapshot.height {
                for x in 0..<snapshot.width where bytes[(y * snapshot.bytesPerRow) + (x * 4) + 3] > 0 {
                    actualMinX = min(actualMinX, x)
                    actualMinY = min(actualMinY, y)
                    actualMaxX = max(actualMaxX, x)
                    actualMaxY = max(actualMaxY, y)
                }
            }
        }
        #expect(actualMaxX >= actualMinX)
        #expect(actualMaxY >= actualMinY)
        #expect(actualMinX >= bounds.originX)
        #expect(actualMinY >= bounds.originY)
        #expect(actualMaxX < bounds.originX + bounds.width)
        #expect(actualMaxY < bounds.originY + bounds.height)
    }

    @Test
    func commitJobBoundsContainLargeSizeJitterOutput() throws {
        guard
            let metalContext = MetalDeviceContext(),
            let commandBuffer = metalContext.commandQueue.makeCommandBuffer()
        else {
            Issue.record("Metal unavailable")
            return
        }

        let surfaceStore = StageOneLayerSurfaceStore()
        var document = ArtDocument.stageOneDefault()
        document.canvasSize = .init(width: 1024, height: 1024)
        surfaceStore.prepareTextures(for: document, metal: metalContext)
        let layerID = document.activeLayerID
        let engine = try MetalStrokeEngine(
            metalContext: metalContext,
            layerSurfaceStore: surfaceStore
        )
        var brush = BrushSettings.stageOneDefault
        brush.size = 300
        brush.sizeJitterAmount = 1

        engine.beginStrokeIfNeeded(
            toolSession: ToolSessionState(activeTool: .brush, brush: brush, selectedColor: .black),
            layerID: layerID
        )
        _ = engine.applyStroke(
            StrokeDescriptor(
                tool: .brush,
                color: .black,
                brush: brush,
                points: [
                    .init(x: 432, y: 539, pressure: 1),
                    .init(x: 433, y: 539, pressure: 1)
                ],
                selectionShape: nil,
                skipLeadingStamp: false
            ),
            to: layerID
        )
        engine.endStroke()
        _ = engine.flushPendingStrokePackets(into: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var renderedBounds: BrushPixelBounds?
        try engine.drainPendingBrushCommitJobs { job in
            renderedBounds = job.renderedPixelBounds
        }
        let bounds = try #require(renderedBounds)

        guard
            let surfaceID = surfaceStore.surfaceID(for: layerID),
            let texture = surfaceStore.texture(for: surfaceID)
        else {
            Issue.record("Texture unavailable")
            return
        }
        let snapshot = try LayerTextureSerializer(metalContext: metalContext).snapshot(texture: texture)
        var actualMinX = snapshot.width
        var actualMinY = snapshot.height
        var actualMaxX = -1
        var actualMaxY = -1
        snapshot.pixelData.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for y in 0..<snapshot.height {
                for x in 0..<snapshot.width where bytes[(y * snapshot.bytesPerRow) + (x * 4) + 3] > 0 {
                    actualMinX = min(actualMinX, x)
                    actualMinY = min(actualMinY, y)
                    actualMaxX = max(actualMaxX, x)
                    actualMaxY = max(actualMaxY, y)
                }
            }
        }
        #expect(actualMaxX >= actualMinX)
        #expect(actualMaxY >= actualMinY)
        #expect(actualMinX >= bounds.originX)
        #expect(actualMinY >= bounds.originY)
        #expect(actualMaxX < bounds.originX + bounds.width)
        #expect(actualMaxY < bounds.originY + bounds.height)
    }

    @Test
    func repeatedCustomTipPacketsReuseResampledTexture() throws {
        guard
            let metalContext = MetalDeviceContext(),
            let firstCommandBuffer = metalContext.commandQueue.makeCommandBuffer(),
            let secondCommandBuffer = metalContext.commandQueue.makeCommandBuffer()
        else {
            Issue.record("Metal unavailable")
            return
        }
        let surfaceStore = StageOneLayerSurfaceStore()
        guard let texture = surfaceStore.makeTexture(width: 128, height: 128, metal: metalContext) else {
            Issue.record("Texture unavailable")
            return
        }
        let renderer = try StageOneBrushRenderer(device: metalContext.device)
        var brush = BrushSettings.stageOneDefault
        brush.tipShape = .customRound
        brush.customTipMaskData = Data(repeating: 255, count: 16 * 16)
        let stroke = StrokeDescriptor(
            tool: .brush,
            color: .black,
            brush: brush,
            points: [
                .init(x: 50, y: 64, pressure: 1),
                .init(x: 78, y: 64, pressure: 1)
            ],
            selectionShape: nil,
            skipLeadingStamp: false
        )

        var firstSamplingState: BrushStrokeSamplingState?
        _ = renderer.encodeStroke(
            stroke: stroke,
            into: texture,
            commandQueue: metalContext.commandQueue,
            commandBuffer: firstCommandBuffer,
            samplingState: &firstSamplingState
        )
        firstCommandBuffer.commit()
        firstCommandBuffer.waitUntilCompleted()

        var secondSamplingState: BrushStrokeSamplingState?
        _ = renderer.encodeStroke(
            stroke: stroke,
            into: texture,
            commandQueue: metalContext.commandQueue,
            commandBuffer: secondCommandBuffer,
            samplingState: &secondSamplingState
        )
        secondCommandBuffer.commit()
        secondCommandBuffer.waitUntilCompleted()

        #expect(renderer.debugCustomTipResampleCount == 1)
    }

    @Test
    func layerContentBoundsDetectorFindsExactOpaqueRegion() throws {
        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal unavailable")
            return
        }
        let surfaceStore = StageOneLayerSurfaceStore()
        var document = ArtDocument.stageOneDefault()
        document.canvasSize = .init(width: 128, height: 128)
        surfaceStore.prepareTextures(for: document, metal: metalContext)
        guard
            let surfaceID = surfaceStore.surfaceID(for: document.activeLayerID),
            let texture = surfaceStore.texture(for: surfaceID)
        else {
            Issue.record("Texture unavailable")
            return
        }
        let detector = try LayerContentBoundsDetector(device: metalContext.device)
        #expect(
            try detector.detect(texture: texture, commandQueue: metalContext.commandQueue) == .empty
        )

        try LayerTextureSerializer(metalContext: metalContext).restore(
            snapshot: gradientSnapshot(width: 12, height: 9),
            into: texture,
            destinationX: 31,
            destinationY: 47
        )
        let detected = try detector.detect(
            texture: texture,
            commandQueue: metalContext.commandQueue
        )
        #expect(
            detected == .bounds(
                CanvasRect(
                    origin: .init(x: 31, y: 47),
                    size: .init(x: 12, y: 9)
                )
            )
        )
    }

    @Test
    func opacityCapStrokeOutsideCanvasSkipsInvalidScissorRect() throws {
        guard
            let metalContext = MetalDeviceContext(),
            let commandBuffer = metalContext.commandQueue.makeCommandBuffer()
        else {
            Issue.record("Metal unavailable")
            return
        }

        let surfaceStore = StageOneLayerSurfaceStore()
        let renderer = try StageOneBrushRenderer(device: metalContext.device)
        let canvasSize = CanvasSize.stageOneDefault

        guard
            let texture = surfaceStore.makeTexture(
                width: canvasSize.width,
                height: canvasSize.height,
                metal: metalContext
            ),
            let session = renderer.makeOpacityCapSession(
                for: texture,
                commandQueue: metalContext.commandQueue
            )
        else {
            Issue.record("Texture unavailable")
            return
        }

        var brush = BrushSettings.stageOneDefault
        brush.buildMode = .opacityCap
        brush.size = 80

        let stroke = StrokeDescriptor(
            tool: .brush,
            color: .black,
            brush: brush,
            points: [
                .init(x: Double(canvasSize.width) * 0.5, y: Double(canvasSize.height) + 120, pressure: 1),
                .init(x: Double(canvasSize.width) * 0.5, y: Double(canvasSize.height) + 240, pressure: 1)
            ],
            selectionShape: nil,
            skipLeadingStamp: false
        )

        var samplingState: BrushStrokeSamplingState?
        let emitted = renderer.encodeOpacityCapStroke(
            stroke: stroke,
            session: session,
            into: texture,
            commandBuffer: commandBuffer,
            samplingState: &samplingState
        )

        #expect(emitted == 0)

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

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
    func queuedBrushPacketCountTracksPendingPacketsWithoutRescanningEvents() throws {
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
        let stroke = StrokeDescriptor(
            tool: .brush,
            color: .black,
            brush: .stageOneDefault,
            points: [.init(x: 10, y: 10, pressure: 1)],
            selectionShape: nil,
            skipLeadingStamp: false
        )

        engine.beginStrokeIfNeeded(toolSession: .stageOneDefault, layerID: layerID)
        #expect(engine.applyStroke(stroke, to: layerID) == 1)
        #expect(engine.applyStroke(stroke, to: layerID) == 2)
        #expect(engine.applyStroke(stroke, to: layerID) == 3)

        let metrics = engine.flushPendingStrokePackets(into: commandBuffer)
        #expect(metrics?.packetQueuedCount == 3)
        #expect(metrics?.flushedPacketCount == 3)
    }

    @Test
    func highFrequencySinglePointPacketsRenderAContinuousStroke() throws {
        guard
            let metalContext = MetalDeviceContext(),
            let commandBuffer = metalContext.commandQueue.makeCommandBuffer()
        else {
            Issue.record("Metal unavailable")
            return
        }

        let surfaceStore = StageOneLayerSurfaceStore()
        var document = ArtDocument.stageOneDefault()
        document.canvasSize = .init(width: 256, height: 128)
        surfaceStore.prepareTextures(for: document, metal: metalContext)
        let layerID = document.activeLayerID
        let engine = try MetalStrokeEngine(
            metalContext: metalContext,
            layerSurfaceStore: surfaceStore
        )
        var brush = BrushSettings.stageOneDefault
        brush.size = 18
        brush.spacingPercent = 10
        brush.scatterAmount = 0
        brush.jitterAmount = 0

        engine.beginStrokeIfNeeded(
            toolSession: ToolSessionState(activeTool: .brush, brush: brush, selectedColor: .black),
            layerID: layerID
        )
        for (index, x) in stride(from: 16, through: 240, by: 2).enumerated() {
            _ = engine.applyStroke(
                StrokeDescriptor(
                    tool: .brush,
                    color: .black,
                    brush: brush,
                    points: [.init(x: Double(x), y: 64, pressure: 1)],
                    selectionShape: nil,
                    skipLeadingStamp: index > 0
                ),
                to: layerID
            )
        }
        engine.endStroke()
        _ = engine.flushPendingStrokePackets(into: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let displayTexture = try #require(engine.displayTexture(for: layerID))
        let snapshot = try LayerTextureSerializer(metalContext: metalContext).snapshot(texture: displayTexture)
        snapshot.pixelData.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for x in 18...238 {
                let alphaOffset = (64 * snapshot.bytesPerRow) + (x * 4) + 3
                #expect(bytes[alphaOffset] > 0)
            }
        }
    }

    @Test
    func opacityCapThreePointStrokeStaysContinuousAcrossFrameCommandBuffers() throws {
        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal unavailable")
            return
        }

        let surfaceStore = StageOneLayerSurfaceStore()
        var document = ArtDocument.stageOneDefault()
        document.canvasSize = .init(width: 512, height: 128)
        surfaceStore.prepareTextures(for: document, metal: metalContext)
        let layerID = document.activeLayerID
        let engine = try MetalStrokeEngine(
            metalContext: metalContext,
            layerSurfaceStore: surfaceStore
        )
        var brush = BrushSettings.stageOneDefault
        brush.buildMode = .opacityCap
        brush.size = 26
        brush.spacingPercent = 10
        brush.pressureSizeAmount = 0
        brush.pressureOpacityAmount = 0

        engine.beginStrokeIfNeeded(
            toolSession: ToolSessionState(activeTool: .brush, brush: brush, selectedColor: .black),
            layerID: layerID
        )

        let points = [32.0, 256.0, 480.0]
        for (index, x) in points.enumerated() {
            _ = engine.applyStroke(
                StrokeDescriptor(
                    tool: .brush,
                    color: .black,
                    brush: brush,
                    points: [.init(x: x, y: 64, pressure: 1)],
                    selectionShape: nil,
                    skipLeadingStamp: index > 0
                ),
                to: layerID
            )
            if index == points.indices.last {
                engine.endStroke()
            }
            let commandBuffer = try #require(metalContext.commandQueue.makeCommandBuffer())
            _ = engine.flushPendingStrokePackets(into: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }

        let displayTexture = try #require(engine.displayTexture(for: layerID))
        let snapshot = try LayerTextureSerializer(metalContext: metalContext).snapshot(texture: displayTexture)
        snapshot.pixelData.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            let missingPixels = (36...476).filter { x in
                let alphaOffset = (64 * snapshot.bytesPerRow) + (x * 4) + 3
                return bytes[alphaOffset] == 0
            }
            #expect(
                missingPixels.isEmpty,
                "Missing opacity-cap centerline pixels: \(missingPixels)"
            )
        }
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
    func interactiveDrainRetainsMostRecentBrushCommitJobsForAdjustment() throws {
        guard
            let metalContext = MetalDeviceContext(),
            let firstCommandBuffer = metalContext.commandQueue.makeCommandBuffer(),
            let secondCommandBuffer = metalContext.commandQueue.makeCommandBuffer(),
            let thirdCommandBuffer = metalContext.commandQueue.makeCommandBuffer()
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

        try enqueueBrushCommitJob(
            engine: engine,
            layerID: layerID,
            point: .init(x: 24, y: 24, pressure: 1),
            commandBuffer: firstCommandBuffer
        )
        try enqueueBrushCommitJob(
            engine: engine,
            layerID: layerID,
            point: .init(x: 96, y: 96, pressure: 1),
            commandBuffer: secondCommandBuffer
        )
        try enqueueBrushCommitJob(
            engine: engine,
            layerID: layerID,
            point: .init(x: 168, y: 168, pressure: 1),
            commandBuffer: thirdCommandBuffer
        )

        #expect(engine.recentAdjustableBrushCommitCount(for: layerID) == 3)
        engine.resetBrushPipelineState()

        let drainResult = try engine.opportunisticDrainPendingBrushCommitJobs(
            hadLiveBrushWorkThisFrame: false,
            maxJobs: 10,
            maxCpuMs: 5,
            retainedRecentBrushCommitJobs: 2
        ) { _ in }

        #expect(drainResult.drainedJobs == 1)
        #expect(drainResult.remainingQueueDepth == 2)
        #expect(engine.recentAdjustableBrushCommitCount(for: layerID) == 2)
    }

    @Test
    func forcedDrainAppliesOpacityToSelectedRecentBrushCommitJobs() throws {
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

        try enqueueBrushCommitJob(
            engine: engine,
            layerID: layerID,
            point: .init(x: 96, y: 96, pressure: 1),
            commandBuffer: firstCommandBuffer
        )
        try enqueueBrushCommitJob(
            engine: engine,
            layerID: layerID,
            point: .init(x: 320, y: 320, pressure: 1),
            commandBuffer: secondCommandBuffer
        )

        engine.setRecentBrushAdjustment(
            layerID: layerID,
            selectedRecentCount: 1,
            opacity: 0.2,
            brightness: 0,
            saturation: 0,
            showsSelectionHighlight: false
        )

        try engine.drainPendingBrushCommitJobs { _ in }

        let serializer = LayerTextureSerializer(metalContext: metalContext)
        guard
            let surfaceID = surfaceStore.surfaceID(for: layerID),
            let texture = surfaceStore.texture(for: surfaceID)
        else {
            Issue.record("Texture unavailable")
            return
        }

        let earlierStrokeAlpha = try serializer.samplePixel(texture: texture, x: 96, y: 96).alpha
        let adjustedRecentStrokeAlpha = try serializer.samplePixel(texture: texture, x: 320, y: 320).alpha

        #expect(earlierStrokeAlpha > 0.25)
        #expect(adjustedRecentStrokeAlpha > 0.01)
        #expect(adjustedRecentStrokeAlpha < earlierStrokeAlpha * 0.5)
        #expect(engine.hasPendingBrushCommitJobs == false)
    }

    @Test
    func forcedDrainAppliesBrightnessAndSaturationToSelectedRecentBrushCommitJobs() throws {
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

        let strokeColor = RGBAColor(red: 0.82, green: 0.42, blue: 0.12, alpha: 1)

        try enqueueBrushCommitJob(
            engine: engine,
            layerID: layerID,
            point: .init(x: 96, y: 96, pressure: 1),
            color: strokeColor,
            commandBuffer: firstCommandBuffer
        )
        try enqueueBrushCommitJob(
            engine: engine,
            layerID: layerID,
            point: .init(x: 320, y: 320, pressure: 1),
            color: strokeColor,
            commandBuffer: secondCommandBuffer
        )

        engine.setRecentBrushAdjustment(
            layerID: layerID,
            selectedRecentCount: 1,
            opacity: 1,
            brightness: -0.35,
            saturation: -0.6,
            showsSelectionHighlight: false
        )

        try engine.drainPendingBrushCommitJobs { _ in }

        let serializer = LayerTextureSerializer(metalContext: metalContext)
        guard
            let surfaceID = surfaceStore.surfaceID(for: layerID),
            let texture = surfaceStore.texture(for: surfaceID)
        else {
            Issue.record("Texture unavailable")
            return
        }

        let earlierStrokePixel = try serializer.samplePixel(texture: texture, x: 96, y: 96)
        let adjustedRecentStrokePixel = try serializer.samplePixel(texture: texture, x: 320, y: 320)

        #expect(adjustedRecentStrokePixel.red < earlierStrokePixel.red - 0.08)
        #expect(abs(adjustedRecentStrokePixel.red - adjustedRecentStrokePixel.green) < abs(earlierStrokePixel.red - earlierStrokePixel.green))
        #expect(abs(adjustedRecentStrokePixel.green - adjustedRecentStrokePixel.blue) < abs(earlierStrokePixel.green - earlierStrokePixel.blue))
    }

    @Test
    func smudgeLiveSessionDoesNotUseFullSizeSnapshotCopiesAcrossPackets() throws {
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
        #expect(engine.debugLastFlushSmudgeFullSizeCopyCount == 0)

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
        #expect(engine.debugLastFlushSmudgeFullSizeCopyCount == 0)
    }

    @Test
    func smudgeCommitReplayDoesNotUseFullSizeSnapshotCopiesAcrossPackets() throws {
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

        #expect(engine.debugLastCommitSmudgeFullSizeCopyCount == 0)
    }

    @Test
    func smudgeGatheredColorsMatchFrozenSourceTextureOutput() throws {
        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal unavailable")
            return
        }

        let surfaceStore = StageOneLayerSurfaceStore()
        let serializer = LayerTextureSerializer(metalContext: metalContext)
        let renderer = try StageOneBrushRenderer(device: metalContext.device)

        guard
            let gatheredTexture = surfaceStore.makeTexture(width: 96, height: 96, metal: metalContext),
            let frozenTextureTarget = surfaceStore.makeTexture(width: 96, height: 96, metal: metalContext),
            let commandBufferA = metalContext.commandQueue.makeCommandBuffer(),
            let commandBufferB = metalContext.commandQueue.makeCommandBuffer(),
            let frozenSourceTexture = surfaceStore.makeTexture(width: 96, height: 96, metal: metalContext)
        else {
            Issue.record("Texture unavailable")
            return
        }

        let seedSnapshot = gradientSnapshot(width: 96, height: 96)
        try serializer.restore(snapshot: seedSnapshot, into: gatheredTexture)
        try serializer.restore(snapshot: seedSnapshot, into: frozenTextureTarget)
        try serializer.restore(snapshot: seedSnapshot, into: frozenSourceTexture)

        let packet = StrokeDescriptor(
            tool: .smudge,
            color: .black,
            brush: .stageOneDefault,
            points: [
                .init(x: 18, y: 18, pressure: 1),
                .init(x: 28, y: 24, pressure: 1),
                .init(x: 36, y: 30, pressure: 1),
                .init(x: 44, y: 36, pressure: 1),
                .init(x: 52, y: 42, pressure: 1),
                .init(x: 60, y: 50, pressure: 1),
                .init(x: 68, y: 58, pressure: 1),
                .init(x: 76, y: 68, pressure: 1)
            ],
            selectionShape: nil,
            skipLeadingStamp: false
        )

        var gatheredSamplingState: BrushStrokeSamplingState?
        _ = renderer.encodeStroke(
            stroke: packet,
            into: gatheredTexture,
            commandQueue: metalContext.commandQueue,
            commandBuffer: commandBufferA,
            samplingState: &gatheredSamplingState
        )

        surfaceStore.copyTexture(
            from: frozenTextureTarget,
            to: frozenSourceTexture,
            metal: metalContext
        )
        var frozenSamplingState: BrushStrokeSamplingState?
        _ = renderer.debugEncodeSmudgeStrokeUsingFrozenTexture(
            stroke: packet,
            frozenSourceTexture: frozenSourceTexture,
            into: frozenTextureTarget,
            commandBuffer: commandBufferB,
            samplingState: &frozenSamplingState
        )

        commandBufferA.commit()
        commandBufferB.commit()
        commandBufferA.waitUntilCompleted()
        commandBufferB.waitUntilCompleted()

        let gatheredSnapshot = try serializer.snapshot(texture: gatheredTexture)
        let frozenSnapshot = try serializer.snapshot(texture: frozenTextureTarget)
        let maxDelta = maxByteDelta(gatheredSnapshot.pixelData, frozenSnapshot.pixelData)

        #expect(maxDelta <= 1)
    }

    @Test
    func smudgingTransparentPixelsDoesNotPaintDisplayBackgroundColor() throws {
        guard
            let metalContext = MetalDeviceContext(),
            let commandBuffer = metalContext.commandQueue.makeCommandBuffer()
        else {
            Issue.record("Metal unavailable")
            return
        }

        let surfaceStore = StageOneLayerSurfaceStore()
        let serializer = LayerTextureSerializer(metalContext: metalContext)
        let renderer = try StageOneBrushRenderer(device: metalContext.device)
        guard let texture = surfaceStore.makeTexture(width: 64, height: 64, metal: metalContext) else {
            Issue.record("Texture unavailable")
            return
        }

        try serializer.restore(
            snapshot: LayerTextureSnapshot(
                width: 64,
                height: 64,
                bytesPerRow: 64 * 4,
                pixelData: Data(repeating: 0, count: 64 * 64 * 4)
            ),
            into: texture
        )

        var brush = BrushSettings.stageOneDefault
        brush.size = 18
        brush.opacity = 1
        var samplingState: BrushStrokeSamplingState?
        _ = renderer.encodeStroke(
            stroke: StrokeDescriptor(
                tool: .smudge,
                color: .black,
                brush: brush,
                points: [
                    .init(x: 18, y: 18, pressure: 1),
                    .init(x: 30, y: 26, pressure: 1),
                    .init(x: 42, y: 34, pressure: 1)
                ],
                selectionShape: nil,
                skipLeadingStamp: false
            ),
            into: texture,
            commandQueue: metalContext.commandQueue,
            commandBuffer: commandBuffer,
            samplingState: &samplingState
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let snapshot = try serializer.snapshot(texture: texture)
        let alphaBytes = stride(from: 3, to: snapshot.pixelData.count, by: 4).map {
            snapshot.pixelData[$0]
        }
        #expect(alphaBytes.allSatisfy { $0 == 0 })
    }
}

private func renderPaintJitterSnapshot(
    metalContext: MetalDeviceContext,
    renderer: StageOneBrushRenderer,
    seed: UInt32,
    amount: Float,
    buildMode: BrushBuildMode
) throws -> LayerTextureSnapshot {
    let surfaceStore = StageOneLayerSurfaceStore()
    let serializer = LayerTextureSerializer(metalContext: metalContext)
    guard
        let texture = surfaceStore.makeTexture(width: 192, height: 96, metal: metalContext),
        let commandBuffer = metalContext.commandQueue.makeCommandBuffer()
    else {
        throw PaintJitterTestError.textureUnavailable
    }
    try serializer.restore(
        snapshot: LayerTextureSnapshot(
            width: 192,
            height: 96,
            bytesPerRow: 192 * 4,
            pixelData: Data(repeating: 0, count: 192 * 96 * 4)
        ),
        into: texture
    )

    var brush = BrushSettings.stageOneDefault
    brush.size = 64
    brush.spacingPercent = 8
    brush.opacity = 1
    brush.paintJitterAmount = amount
    brush.buildMode = buildMode
    let stroke = StrokeDescriptor(
        tool: .brush,
        color: .init(red: 0.78, green: 0.16, blue: 0.08, alpha: 1),
        brush: brush,
        points: [
            .init(x: 28, y: 48, pressure: 1),
            .init(x: 72, y: 48, pressure: 1),
            .init(x: 120, y: 48, pressure: 1),
            .init(x: 164, y: 48, pressure: 1)
        ],
        selectionShape: nil,
        paintVariationSeed: seed
    )
    var samplingState: BrushStrokeSamplingState?
    if buildMode == .opacityCap {
        guard let session = renderer.makeOpacityCapSession(
            for: texture,
            commandQueue: metalContext.commandQueue
        ) else {
            throw PaintJitterTestError.textureUnavailable
        }
        _ = renderer.encodeOpacityCapStroke(
            stroke: stroke,
            session: session,
            into: texture,
            commandBuffer: commandBuffer,
            samplingState: &samplingState
        )
    } else {
        _ = renderer.encodeStroke(
            stroke: stroke,
            into: texture,
            commandQueue: metalContext.commandQueue,
            commandBuffer: commandBuffer,
            samplingState: &samplingState
        )
    }
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    return try serializer.snapshot(texture: texture)
}

private func alphaBytes(in snapshot: LayerTextureSnapshot) -> [UInt8] {
    stride(from: 3, to: snapshot.pixelData.count, by: 4).map { snapshot.pixelData[$0] }
}

private enum PaintJitterTestError: Error {
    case textureUnavailable
}

private func enqueueBrushCommitJob(
    engine: MetalStrokeEngine,
    layerID: LayerID,
    point: StrokePoint,
    color: RGBAColor = .black,
    commandBuffer: MTLCommandBuffer
) throws {
    var brush = BrushSettings.stageOneDefault
    brush.size = 24
    brush.opacity = 1

    engine.beginStrokeIfNeeded(
        toolSession: .stageOneDefault,
        layerID: layerID
    )
    _ = engine.applyStroke(
        StrokeDescriptor(
            tool: .brush,
            color: color,
            brush: brush,
            points: [point],
            selectionShape: nil,
            skipLeadingStamp: false
        ),
        to: layerID
    )
    engine.endStroke()
    _ = engine.flushPendingStrokePackets(into: commandBuffer)
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
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

private func maxByteDelta(_ lhs: Data, _ rhs: Data) -> Int {
    precondition(lhs.count == rhs.count)
    return zip(lhs, rhs).map { abs(Int($0) - Int($1)) }.max() ?? 0
}

import Foundation
import Metal
import Testing
@testable import ArtFlex

struct BrushPipelineOptimizationTests {
    @Test(arguments: BrushPipelineCase.allCases, [false, true])
    func sparseLiveAndCommitMatchDenseForBrushModes(kind: BrushPipelineCase, highPrecision: Bool) throws {
        let metal = try #require(MetalDeviceContext())
        guard SparseLayerTexture.isSupported(by: metal.device) else { return }
        let standard: ArtColorStandard = highPrecision ? .highPrecision : .stageOneDefault
        var results: [(live: Data, committed: Data, bytes: Int, staging: Int)] = []
        for sparse in [false, true] {
            let fixture = try BrushPipelineFixture(metal: metal, sparse: sparse, standard: standard)
            var base = BrushSettings.stageOneDefault
            base.size = 96
            base.buildMode = .buildUp
            try fixture.stroke(brush: base)
            try fixture.engine.drainPendingBrushCommitJobs { _ in }
            fixture.engine.resetBrushPipelineState()
            var brush = kind == .v2 ? BrushSettings.v2Default : .stageOneDefault
            brush.size = 34
            brush.opacity = 0.6
            brush.buildMode = kind == .opacityCap ? .opacityCap : .buildUp
            brush.scatterAmount = 0.12
            brush.sizeJitterAmount = 0.15
            brush.paintJitterAmount = 0.4
            if kind == .compound {
                brush.compoundBrush.enabled = true
                brush.compoundBrush.mode = .overlay
            }
            try fixture.stroke(brush: brush, tool: kind == .eraser ? .eraser : kind == .smudge ? .smudge : .brush,
                               alphaLock: kind == .alphaLock)
            let live = try #require(fixture.engine.displayTexture(for: fixture.document.activeLayerID))
            let liveBytes = fixture.engine.debugLiveTargetAllocatedBytes
            let pixels = try fixture.serializer.snapshot(texture: live).pixelData
            try fixture.engine.drainPendingBrushCommitJobs { _ in }
            results.append((pixels, try fixture.pixels(), liveBytes, fixture.engine.debugLastCommitStagingBytes))
        }
        #expect(results[0].live == results[1].live)
        #expect(results[0].committed == results[1].committed)
        #expect(results[1].bytes < results[0].bytes / 4)
        #expect(results[1].staging < results[0].staging / 4)
    }

    @Test func interactiveCommitWaitsForGPUAndHistoryWithoutBlockingOrPublishingEarly() throws {
        let metal = try #require(MetalDeviceContext())
        let fixture = try BrushPipelineFixture(metal: metal, sparse: false)
        try fixture.stroke(brush: .stageOneDefault)
        fixture.engine.resetBrushPipelineState()
        let original = try fixture.pixels()
        var historyReady = false
        var checkpointCount = 0
        fixture.engine.prepareInteractiveCheckpoint = { _ in
            .init(isReady: { historyReady }, commit: { checkpointCount += 1 })
        }
        let event = try #require(metal.device.makeSharedEvent())
        let gate = try #require(metal.commandQueue.makeCommandBuffer())
        gate.encodeWaitForEvent(event, value: 1)
        gate.commit()
        let lifetime = BrushPipelineTestEvent(event)
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(300)) {
            lifetime.event.signaledValue = 1
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let submitted = try fixture.engine.opportunisticDrainPendingBrushCommitJobs(
            hadLiveBrushWorkThisFrame: false, maxJobs: 1, maxCpuMs: 0.75) { _ in
                Issue.record("Interactive path must use its asynchronous checkpoint")
            }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        #expect(ms < 150)
        #expect(submitted.drainedJobs == 0)
        #expect(checkpointCount == 0)
        let fence = try #require(metal.commandQueue.makeCommandBuffer())
        fence.commit(); fence.waitUntilCompleted()
        _ = try fixture.engine.opportunisticDrainPendingBrushCommitJobs(
            hadLiveBrushWorkThisFrame: false, maxJobs: 1, maxCpuMs: 0.75) { _ in }
        #expect(checkpointCount == 0)
        #expect(try fixture.pixels() == original)
        historyReady = true
        let finished = try fixture.engine.opportunisticDrainPendingBrushCommitJobs(
            hadLiveBrushWorkThisFrame: false, maxJobs: 1, maxCpuMs: 0.75) { _ in }
        #expect(finished.drainedJobs == 1)
        #expect(checkpointCount == 1)
        #expect(try fixture.pixels() != original)
        try fixture.engine.drainPendingBrushCommitJobs { _ in Issue.record("Already committed") }
        #expect(checkpointCount == 1)
    }

    @Test func forcedBoundaryConsumesSamePendingCheckpointExactlyOnce() throws {
        let metal = try #require(MetalDeviceContext())
        let fixture = try BrushPipelineFixture(metal: metal, sparse: true)
        try fixture.stroke(brush: .stageOneDefault)
        fixture.engine.resetBrushPipelineState()
        var prepared = 0
        var committed = 0
        fixture.engine.prepareInteractiveCheckpoint = { _ in
            prepared += 1
            return .init(isReady: { false }, commit: { committed += 1 })
        }
        _ = try fixture.engine.opportunisticDrainPendingBrushCommitJobs(
            hadLiveBrushWorkThisFrame: false, maxJobs: 1, maxCpuMs: 0.75) { _ in }
        #expect(prepared == 1)
        try fixture.engine.drainPendingBrushCommitJobs { _ in Issue.record("Must consume the pending checkpoint") }
        #expect(committed == 1)
        #expect(!fixture.engine.hasPendingBrushCommitJobs)
        try fixture.engine.drainPendingBrushCommitJobs { _ in Issue.record("No duplicate checkpoint") }
        #expect(committed == 1)
    }

    @Test func failedHistoryLeavesPixelsAndQueuedInputForRetry() throws {
        let metal = try #require(MetalDeviceContext())
        let fixture = try BrushPipelineFixture(metal: metal, sparse: true)
        let before = try fixture.pixels()
        try fixture.stroke(brush: .stageOneDefault)
        fixture.engine.resetBrushPipelineState()
        fixture.engine.prepareInteractiveCheckpoint = { _ in
            .init(isReady: { true }, commit: { throw CanvasResourceError(message: "injected history rejection") })
        }
        _ = try fixture.engine.opportunisticDrainPendingBrushCommitJobs(
            hadLiveBrushWorkThisFrame: false, maxJobs: 1, maxCpuMs: 0.75) { _ in }
        #expect(throws: CanvasResourceError.self) {
            try fixture.engine.drainPendingBrushCommitJobs { _ in }
        }
        #expect(try fixture.pixels() == before)
        #expect(fixture.engine.hasPendingBrushCommitJobs)
        var checkpoints = 0
        try fixture.engine.drainPendingBrushCommitJobs { _ in checkpoints += 1 }
        #expect(checkpoints == 1)
        #expect(try fixture.pixels() != before)
    }

    @Test func replacedSourceRejectsLateResultBeforeCheckpoint() throws {
        let metal = try #require(MetalDeviceContext())
        let fixture = try BrushPipelineFixture(metal: metal, sparse: true)
        try fixture.stroke(brush: .stageOneDefault)
        fixture.engine.resetBrushPipelineState()
        var checkpoints = 0
        fixture.engine.prepareInteractiveCheckpoint = { _ in
            .init(isReady: { true }, commit: { checkpoints += 1 })
        }
        _ = try fixture.engine.opportunisticDrainPendingBrushCommitJobs(
            hadLiveBrushWorkThisFrame: false, maxJobs: 1, maxCpuMs: 0.75) { _ in }
        let replacement = try #require(fixture.surfaces.makeTexture(width: fixture.document.canvasSize.width,
            height: fixture.document.canvasSize.height, metal: metal))
        // Use a valid initialized texture; replacing it invalidates the pending identity.
        let blank = try fixture.serializer.snapshot(texture: #require(fixture.surfaces.readTexture(for: fixture.surfaceID)))
        try fixture.serializer.restore(snapshot: blank, into: replacement)
        fixture.surfaces.swapTexture(for: fixture.surfaceID, with: replacement)
        #expect(throws: CanvasResourceError.self) { try fixture.engine.drainPendingBrushCommitJobs { _ in } }
        #expect(checkpoints == 0)
        #expect(fixture.surfaces.readTexture(for: fixture.surfaceID) === replacement)
        #expect(fixture.engine.hasPendingBrushCommitJobs)
    }

    /// This bounded fixture is shared by the before/after runs. It measures only
    /// the live target allocation, not all opacity-mask or device allocations.
    @Test func liveWorkingTargetAndCommitBaseline() throws {
        guard ProcessInfo.processInfo.environment["ARTFLEX_RUN_BRUSH_PIPELINE_BENCHMARK"] == "1" else { return }
        let metal = try #require(MetalDeviceContext())
        for standard in [ArtColorStandard.stageOneDefault, .highPrecision] {
            for sparse in [false, true] {
                var document = ArtDocument.stageOneDefault()
                document.canvasSize = .init(width: 4096, height: 4096)
                document.colorStandard = standard
                let surfaces = StageOneLayerSurfaceStore(usesSparseStorage: sparse)
                surfaces.prepareTextures(for: document, metal: metal)
                let engine = try MetalStrokeEngine(metalContext: metal, layerSurfaceStore: surfaces)
                let serializer = LayerTextureSerializer(metalContext: metal)
                var brush = BrushSettings.stageOneDefault
                brush.size = 32
                brush.buildMode = .buildUp
                let start = DispatchTime.now().uptimeNanoseconds
                engine.beginStrokeIfNeeded(toolSession: .stageOneDefault, layerID: document.activeLayerID)
                _ = engine.applyStroke(.init(tool: .brush, color: .black, brush: brush,
                    points: [.init(x: 90, y: 110, pressure: 1), .init(x: 150, y: 130, pressure: 0.7),
                             .init(x: 210, y: 140, pressure: 1)], selectionShape: nil,
                    paintVariationSeed: 42), to: document.activeLayerID)
                engine.endStroke()
                let command = try #require(metal.commandQueue.makeCommandBuffer())
                _ = engine.flushPendingStrokePackets(into: command)
                command.commit()
                command.waitUntilCompleted()
                let live = try #require(engine.displayTexture(for: document.activeLayerID))
                let liveBytes = live.heap?.size ?? live.allocatedSize
                let liveMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                let commitStart = DispatchTime.now().uptimeNanoseconds
                try engine.drainPendingBrushCommitJobs { _ in }
                let commitMs = Double(DispatchTime.now().uptimeNanoseconds - commitStart) / 1_000_000
                let id = try #require(surfaces.surfaceID(for: document.activeLayerID))
                let texture = try #require(surfaces.readTexture(for: id))
                #expect(try serializer.samplePixel(texture: texture, x: 90, y: 110).alpha > 0)
                print("ArtFlexBrushPipeline format=\(standard.pixelFormat) sparse=\(sparse) liveTargetBytes=\(liveBytes) liveMs=\(liveMs) commitMs=\(commitMs)")
            }
        }
    }
}

enum BrushPipelineCase: String, CaseIterable, Sendable {
    case buildUp, opacityCap, compound, alphaLock, eraser, smudge, v2
}

private final class BrushPipelineTestEvent: @unchecked Sendable {
    let event: MTLSharedEvent
    init(_ event: MTLSharedEvent) { self.event = event }
}

private struct BrushPipelineFixture {
    let metal: MetalDeviceContext
    let document: ArtDocument
    let surfaces: StageOneLayerSurfaceStore
    let engine: MetalStrokeEngine
    let serializer: LayerTextureSerializer
    let surfaceID: LayerSurfaceID

    init(metal: MetalDeviceContext, sparse: Bool, standard: ArtColorStandard = .stageOneDefault) throws {
        self.metal = metal
        var document = ArtDocument.stageOneDefault()
        document.canvasSize = .init(width: 1152, height: 1152)
        document.colorStandard = standard
        self.document = document
        surfaces = StageOneLayerSurfaceStore(usesSparseStorage: sparse)
        surfaces.prepareTextures(for: document, metal: metal)
        surfaceID = try #require(surfaces.surfaceID(for: document.activeLayerID))
        engine = try MetalStrokeEngine(metalContext: metal, layerSurfaceStore: surfaces)
        serializer = LayerTextureSerializer(metalContext: metal)
    }

    func pixels() throws -> Data {
        try serializer.snapshot(texture: #require(surfaces.readTexture(for: surfaceID))).pixelData
    }

    func stroke(brush: BrushSettings, tool: ToolKind = .brush, alphaLock: Bool = false) throws {
        var toolSession = ToolSessionState.stageOneDefault
        toolSession.activeTool = tool
        engine.beginStrokeIfNeeded(toolSession: toolSession, layerID: document.activeLayerID)
        for packet in 0..<3 {
            _ = engine.applyStroke(.init(tool: tool, color: .init(red: 0.8, green: 0.2, blue: 0.1, alpha: 1),
                brush: brush, points: (0..<3).map { point in
                    .init(x: Double(80 + packet * 55 + point * 15),
                          y: Double(90 + packet * 20 + point * 6), pressure: Float(point + 1) / 3)
                }, selectionShape: nil, alphaLockEnabled: alphaLock,
                skipLeadingStamp: packet != 0, paintVariationSeed: 0x1234_5678), to: document.activeLayerID)
            let command = try #require(metal.commandQueue.makeCommandBuffer())
            _ = engine.flushPendingStrokePackets(into: command)
            command.commit(); command.waitUntilCompleted()
            #expect(command.status == .completed)
        }
        engine.endStroke()
        let tail = try #require(metal.commandQueue.makeCommandBuffer())
        _ = engine.flushPendingStrokePackets(into: tail)
        tail.commit(); tail.waitUntilCompleted()
        #expect(tail.status == .completed)
    }
}

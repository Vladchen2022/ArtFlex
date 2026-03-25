import Darwin
import Metal
import Testing
@testable import ArtFlex

struct PerformanceAuditFactTests {
    @Test
    @MainActor
    func performanceAuditMeasurementRun() throws {
        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal unavailable")
            return
        }

        let baselineBootstrap = try AppBootstrap(
            metalContext: metalContext,
            layerSurfaceStore: StageOneLayerSurfaceStore()
        )
        let baselineViewModel = WorkspaceViewModel(
            bootstrap: baselineBootstrap,
            installsZoomKeyboardMonitor: false
        )

        let interactiveMetrics = try measureInteractiveTimings(
            viewModel: baselineViewModel,
            metalContext: metalContext
        )
        let serializerMetrics = try measureSerializerAndExportTimings(
            bootstrap: baselineBootstrap,
            metalContext: metalContext
        )
        let brushPeakBytes = try measureBrushPeakMemoryBytes(canvasSize: .init(width: 4096, height: 4096))
        let smudge4096Metrics = try measureSmudgeMetrics(canvasSize: .init(width: 4096, height: 4096))
        let smudge8192Metrics = try measureSmudgeMetrics(canvasSize: .init(width: 8192, height: 8192))

        for (label, value) in interactiveMetrics.sorted(by: { $0.key < $1.key }) {
            print("[audit-timing] \(label)=\(String(format: "%.3f", value))ms")
        }
        for (label, value) in serializerMetrics.sorted(by: { $0.key < $1.key }) {
            print("[audit-timing] \(label)=\(String(format: "%.3f", value))ms")
        }
        print("[audit-memory] brush4096.peakBytes=\(brushPeakBytes)")
        print("[audit-memory] smudge4096.peakBytes=\(smudge4096Metrics.peakBytes)")
        print("[audit-memory] smudge8192.peakBytes=\(smudge8192Metrics.peakBytes)")
        print("[audit-timing] StageOneBrushRenderer.makeSmudgeSourceTexture.4096=\(String(format: "%.3f", smudge4096Metrics.makeSmudgeSourceTextureMs))ms")
        print("[audit-timing] StageOneBrushRenderer.makeSmudgeSourceTexture.8192=\(String(format: "%.3f", smudge8192Metrics.makeSmudgeSourceTextureMs))ms")
    }
}

@MainActor
private func measureInteractiveTimings(
    viewModel: WorkspaceViewModel,
    metalContext: MetalDeviceContext
) throws -> [String: Double] {
    PerformanceAuditStore.shared.reset()

    viewModel.beginStrokeIfNeeded()
    for packetIndex in 0..<48 {
        let x0 = Double(20 + (packetIndex * 8))
        let x1 = x0 + 6
        let y = Double(24 + (packetIndex % 6) * 3)
        viewModel.applyStroke(
            samples: [
                CanvasStrokeSample(location: .init(x: x0, y: y), pressure: 1),
                CanvasStrokeSample(location: .init(x: x1, y: y + 2), pressure: 1)
            ]
        )
        try flushPendingBrushWork(viewModel: viewModel, metalContext: metalContext)
    }
    viewModel.endStroke()
    try flushPendingBrushWork(viewModel: viewModel, metalContext: metalContext)
    viewModel.opportunisticallyDrainBrushCommits(hadLiveBrushWorkThisFrame: false)
    viewModel.undo()
    viewModel.redo()

    let snapshot = PerformanceAuditStore.shared.snapshot()
    return [
        "HistoryController.captureCheckpoint": snapshot.averageDuration("HistoryController.captureCheckpoint") ?? 0,
        "WorkspaceViewModel.undo": snapshot.averageDuration("WorkspaceViewModel.undo") ?? 0,
        "WorkspaceViewModel.redo": snapshot.averageDuration("WorkspaceViewModel.redo") ?? 0
    ]
}

@MainActor
private func measureSerializerAndExportTimings(
    bootstrap: AppBootstrap,
    metalContext: MetalDeviceContext
) throws -> [String: Double] {
    guard
        let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: bootstrap.workspaceStore.state.document.activeLayerID),
        let texture = bootstrap.layerSurfaceStore.texture(for: surfaceID)
    else {
        throw AuditHarnessError.textureUnavailable
    }

    let serializer = bootstrap.textureSerializer
    let pngExporter = bootstrap.pngExporter
    let snapshotForRestore = try serializer.snapshot(texture: texture)
    guard let restoreTexture = bootstrap.layerSurfaceStore.makeTexture(
        width: snapshotForRestore.width,
        height: snapshotForRestore.height,
        metal: metalContext
    ) else {
        throw AuditHarnessError.textureUnavailable
    }

    PerformanceAuditStore.shared.reset()
    for _ in 0..<5 {
        _ = try serializer.snapshot(texture: texture)
    }
    let snapshotAudit = PerformanceAuditStore.shared.snapshot()
    let snapshotMs = snapshotAudit.averageDuration("LayerTextureSerializer.snapshot") ?? 0

    PerformanceAuditStore.shared.reset()
    for _ in 0..<5 {
        try serializer.restore(snapshot: snapshotForRestore, into: restoreTexture)
    }
    let restoreAudit = PerformanceAuditStore.shared.snapshot()
    let restoreMs = restoreAudit.averageDuration("LayerTextureSerializer.restore") ?? 0

    PerformanceAuditStore.shared.reset()
    for _ in 0..<20 {
        _ = try serializer.samplePixel(texture: texture, x: 8, y: 8)
    }
    let sampleAudit = PerformanceAuditStore.shared.snapshot()
    let sampleMs = sampleAudit.averageDuration("LayerTextureSerializer.samplePixel") ?? 0

    PerformanceAuditStore.shared.reset()
    for index in 0..<3 {
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ArtFlex-Serializer-Audit-\(index)-\(UUID().uuidString).png")
        try pngExporter.export(texture: texture, to: outputURL)
        try? FileManager.default.removeItem(at: outputURL)
    }
    let exportAudit = PerformanceAuditStore.shared.snapshot()
    let exportMs = exportAudit.averageDuration("PNGExporter.makeFlattenedRGBABytes") ?? 0
    let transformMs = exportAudit.averageDuration("PNGExporter.transformBGRABytesForPNG") ?? 0
    let writeMs = exportAudit.averageDuration("PNGExporter.writePNG") ?? 0

    return [
        "LayerTextureSerializer.snapshot": snapshotMs,
        "LayerTextureSerializer.restore": restoreMs,
        "LayerTextureSerializer.samplePixel": sampleMs,
        "PNGExporter.makeFlattenedRGBABytes": exportMs,
        "PNGExporter.transformBGRABytesForPNG": transformMs,
        "PNGExporter.writePNG": writeMs
    ]
}

@MainActor
private func measureBrushPeakMemoryBytes(canvasSize: CanvasSize) throws -> UInt64 {
    guard let metalContext = MetalDeviceContext() else {
        throw AuditHarnessError.metalUnavailable
    }

    let workspaceStore = WorkspaceStore(state: makeWorkspaceState(canvasSize: canvasSize))
    let bootstrap = try AppBootstrap(
        workspaceStore: workspaceStore,
        metalContext: metalContext,
        layerSurfaceStore: StageOneLayerSurfaceStore()
    )
    let viewModel = WorkspaceViewModel(bootstrap: bootstrap, installsZoomKeyboardMonitor: false)
    var peakBytes = currentPhysFootprintBytes()

    for strokeIndex in 0..<10 {
        viewModel.beginStrokeIfNeeded()
        peakBytes = max(peakBytes, currentPhysFootprintBytes())
        for packetIndex in 0..<12 {
            let baseX = Double(64 + packetIndex * 28 + strokeIndex * 12)
            let baseY = Double(96 + strokeIndex * 26 + (packetIndex % 3) * 6)
            viewModel.applyStroke(
                samples: [
                    CanvasStrokeSample(location: .init(x: baseX, y: baseY), pressure: 1),
                    CanvasStrokeSample(location: .init(x: baseX + 18, y: baseY + 12), pressure: 1)
                ]
            )
            try flushPendingBrushWork(viewModel: viewModel, metalContext: metalContext)
            peakBytes = max(peakBytes, currentPhysFootprintBytes())
        }
        viewModel.endStroke()
        try flushPendingBrushWork(viewModel: viewModel, metalContext: metalContext)
        peakBytes = max(peakBytes, currentPhysFootprintBytes())
        viewModel.opportunisticallyDrainBrushCommits(hadLiveBrushWorkThisFrame: false)
        peakBytes = max(peakBytes, currentPhysFootprintBytes())
    }

    return peakBytes
}

@MainActor
private func measureSmudgeMetrics(canvasSize: CanvasSize) throws -> (peakBytes: UInt64, makeSmudgeSourceTextureMs: Double) {
    guard let metalContext = MetalDeviceContext() else {
        throw AuditHarnessError.metalUnavailable
    }

    let document = makeDocument(canvasSize: canvasSize)
    let layerSurfaceStore = StageOneLayerSurfaceStore()
    layerSurfaceStore.prepareTextures(for: document, metal: metalContext)

    let engine = try MetalStrokeEngine(
        metalContext: metalContext,
        layerSurfaceStore: layerSurfaceStore
    )
    let smudgeBrush = BrushSettings.stageOneDefault
    let session = ToolSessionState(
        activeTool: .smudge,
        brush: smudgeBrush,
        selectedColor: .black
    )
    let layerID = document.activeLayerID
    var peakBytes = currentPhysFootprintBytes()
    PerformanceAuditStore.shared.reset()

    for strokeIndex in 0..<10 {
        engine.beginStrokeIfNeeded(toolSession: session, layerID: layerID)
        peakBytes = max(peakBytes, currentPhysFootprintBytes())
        for packetIndex in 0..<6 {
            let baseX = Double(80 + packetIndex * 44 + strokeIndex * 9)
            let baseY = Double(120 + strokeIndex * 28 + (packetIndex % 2) * 10)
            _ = engine.applyStroke(
                StrokeDescriptor(
                    tool: .smudge,
                    color: .black,
                    brush: smudgeBrush,
                    points: [
                        .init(x: baseX, y: baseY, pressure: 1),
                        .init(x: baseX + 16, y: baseY + 10, pressure: 1),
                        .init(x: baseX + 32, y: baseY + 18, pressure: 1)
                    ],
                    selectionShape: nil
                ),
                to: layerID
            )
            try flushPendingStrokePackets(engine: engine, metalContext: metalContext)
            peakBytes = max(peakBytes, currentPhysFootprintBytes())
        }
        engine.endStroke()
        try flushPendingStrokePackets(engine: engine, metalContext: metalContext)
        peakBytes = max(peakBytes, currentPhysFootprintBytes())
        try engine.drainPendingBrushCommitJobs { _ in }
        peakBytes = max(peakBytes, currentPhysFootprintBytes())
    }

    let audit = PerformanceAuditStore.shared.snapshot()
    return (
        peakBytes: peakBytes,
        makeSmudgeSourceTextureMs: audit.averageDuration("StageOneBrushRenderer.makeSmudgeSourceTexture") ?? 0
    )
}

@MainActor
private func flushPendingBrushWork(
    viewModel: WorkspaceViewModel,
    metalContext: MetalDeviceContext
) throws {
    guard let commandBuffer = metalContext.commandQueue.makeCommandBuffer() else {
        throw AuditHarnessError.commandBufferUnavailable
    }

    _ = viewModel.flushPendingBrushWork(into: commandBuffer)
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
}

private func flushPendingStrokePackets(
    engine: MetalStrokeEngine,
    metalContext: MetalDeviceContext
) throws {
    guard let commandBuffer = metalContext.commandQueue.makeCommandBuffer() else {
        throw AuditHarnessError.commandBufferUnavailable
    }

    _ = engine.flushPendingStrokePackets(into: commandBuffer)
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
}

private func makeWorkspaceState(canvasSize: CanvasSize) -> WorkspaceState {
    var state = WorkspaceState.stageOneDefault
    state.document = makeDocument(canvasSize: canvasSize)
    return state
}

private func makeDocument(canvasSize: CanvasSize) -> ArtDocument {
    let layer = LayerRecord.stageOneDefault()
    let now = Date()
    return ArtDocument(
        metadata: DocumentMetadata(
            name: "Audit",
            createdAt: now,
            updatedAt: now
        ),
        canvasSize: canvasSize,
        layers: [layer],
        activeLayerID: layer.id
    )
}

private func currentPhysFootprintBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<natural_t>.size)
    let result: kern_return_t = withUnsafeMutablePointer(to: &info) { infoPointer in
        infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
            task_info(
                mach_task_self_,
                task_flavor_t(TASK_VM_INFO),
                reboundPointer,
                &count
            )
        }
    }

    guard result == KERN_SUCCESS else {
        return 0
    }

    return info.phys_footprint
}

private enum AuditHarnessError: Error {
    case metalUnavailable
    case commandBufferUnavailable
    case textureUnavailable
}

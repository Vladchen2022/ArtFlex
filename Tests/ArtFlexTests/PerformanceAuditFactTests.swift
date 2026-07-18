import Darwin
import Foundation
import Metal
import Testing
@testable import ArtFlex

private final class CompletionDurationBox: @unchecked Sendable {
    var value = 0.0
}

private let heavyPerformanceAuditEnvironmentKey = "ARTFLEX_RUN_HEAVY_PERF_TESTS"

private var heavyPerformanceAuditEnabled: Bool {
    let value = ProcessInfo.processInfo.environment[heavyPerformanceAuditEnvironmentKey]?.lowercased()
    return value == "1" || value == "true" || value == "yes"
}

private let quickFillAtPointDirtyPilotCases: [(CanvasSize, Int)] = [
    (.init(width: 1024, height: 1024), 4)
]

private let heavyDirtyPilotCases: [(CanvasSize, Int)] = [
    (.init(width: 4096, height: 4096), 4),
    (.init(width: 4096, height: 4096), 8),
    (.init(width: 8192, height: 8192), 4),
    (.init(width: 8192, height: 8192), 8)
]

struct PerformanceAuditFactTests {
    @Test
    @MainActor
    func brushCommitRenderedRegionMeasurementOnly() throws {
        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal unavailable")
            return
        }
        let harness = try makePixelOperationHistoryMeasurementHarness(
            canvasSize: .init(width: 4096, height: 4096),
            layerCount: 4
        )
        let viewModel = harness.viewModel
        viewModel.selectTool(.brush)
        viewModel.setBrushSize(72)
        viewModel.setBrushScatterAmount(1)
        viewModel.setBrushJitterAmount(1)
        harness.bootstrap.historyController.resetHistory()
        PerformanceAuditStore.shared.reset()

        viewModel.beginStrokeIfNeeded()
        viewModel.applyStroke(samples: [
            .init(location: .init(x: 1900, y: 1950), pressure: 0.4),
            .init(location: .init(x: 2048, y: 2048), pressure: 0.7),
            .init(location: .init(x: 2200, y: 2160), pressure: 1)
        ])
        viewModel.endStroke()
        try flushPendingBrushWork(viewModel: viewModel, metalContext: metalContext)
        _ = viewModel.flushBrushEditingBoundary(reason: "performance measurement")

        let entryBytes = harness.bootstrap.historyController.debugUndoEntryApproxByteCounts.last ?? 0
        let checkpointMs = PerformanceAuditStore.shared.snapshot()
            .averageDuration("HistoryController.captureCheckpoint") ?? 0
        print(
            "[brush-rendered-region] canvas=4096x4096 layers=4 " +
            "checkpoint=\(String(format: "%.3f", checkpointMs))ms entryBytes=\(entryBytes)"
        )
        #expect(entryBytes > 0)
        #expect(entryBytes < 2 * 1024 * 1024)
    }

    @Test
    @MainActor
    func pngExportTransformMeasurementOnly() throws {
        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal unavailable")
            return
        }
        let bootstrap = try AppBootstrap(
            metalContext: metalContext,
            layerSurfaceStore: StageOneLayerSurfaceStore()
        )
        bootstrap.layerSurfaceStore.prepareTextures(
            for: bootstrap.workspaceStore.state.document,
            metal: metalContext
        )
        let metrics = try measureSerializerAndExportTimings(
            bootstrap: bootstrap,
            metalContext: metalContext
        )
        let transformMs = metrics["PNGExporter.transformBGRABytesForPNG"] ?? 0
        print("[png-export-transform] canvas=2048x2048 transform=\(String(format: "%.3f", transformMs))ms")
        #expect(transformMs > 0)
    }

    @Test
    func layerContentBoundsMeasurementOnly() throws {
        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal unavailable")
            return
        }
        let surfaceStore = StageOneLayerSurfaceStore()
        var document = ArtDocument.stageOneDefault()
        document.canvasSize = .init(width: 4096, height: 4096)
        surfaceStore.prepareTextures(for: document, metal: metalContext)
        guard
            let surfaceID = surfaceStore.surfaceID(for: document.activeLayerID),
            let texture = surfaceStore.texture(for: surfaceID)
        else {
            Issue.record("Texture unavailable")
            return
        }
        try LayerTextureSerializer(metalContext: metalContext).restore(
            snapshot: LayerTextureSnapshot(
                width: 64,
                height: 48,
                bytesPerRow: 64 * 4,
                pixelData: Data(repeating: 255, count: 64 * 48 * 4)
            ),
            into: texture,
            destinationX: 1900,
            destinationY: 2000
        )
        let detector = try LayerContentBoundsDetector(device: metalContext.device)
        var durations: [Double] = []
        for _ in 0..<5 {
            let startedAt = DispatchTime.now().uptimeNanoseconds
            let result = try detector.detect(
                texture: texture,
                commandQueue: metalContext.commandQueue
            )
            durations.append(Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
            #expect(
                result == .bounds(
                    CanvasRect(
                        origin: .init(x: 1900, y: 2000),
                        size: .init(x: 64, y: 48)
                    )
                )
            )
        }
        let averageMs = durations.reduce(0, +) / Double(durations.count)
        print("[layer-content-bounds] canvas=4096x4096 sparseAverage=\(String(format: "%.3f", averageMs))ms")

        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = texture
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].storeAction = .store
        renderPass.colorAttachments[0].clearColor = MTLClearColorMake(1, 1, 1, 1)
        guard
            let commandBuffer = metalContext.commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass)
        else {
            Issue.record("Unable to clear the texture")
            return
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        durations.removeAll(keepingCapacity: true)
        for _ in 0..<5 {
            let startedAt = DispatchTime.now().uptimeNanoseconds
            let result = try detector.detect(
                texture: texture,
                commandQueue: metalContext.commandQueue
            )
            durations.append(Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
            #expect(
                result == .bounds(
                    CanvasRect(
                        origin: .init(x: 0, y: 0),
                        size: .init(x: 4096, y: 4096)
                    )
                )
            )
        }
        let denseAverageMs = durations.reduce(0, +) / Double(durations.count)
        print("[layer-content-bounds] canvas=4096x4096 denseAverage=\(String(format: "%.3f", denseAverageMs))ms")
    }

    @Test
    @MainActor
    func performanceAuditMeasurementRun() throws {
        guard heavyPerformanceAuditEnabled else {
            print("[audit-skip] Set \(heavyPerformanceAuditEnvironmentKey)=1 to run the full performance audit.")
            return
        }

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
        let historyEligibilityRows = try measureHistoryEligibilitySummary(metalContext: metalContext)
        let historyCostRows = try measureHistoryCostByCanvasAndLayerCount(metalContext: metalContext)
        let brushDirtyPilotRows = try measureBrushDirtyHistoryPilot(metalContext: metalContext)
        let eraserDirtyPilotRows = try measureEraserDirtyHistoryPilot(metalContext: metalContext)
        let pixelOperationDirtyPilotRows = try measureApplyPixelOperationDirtyPilot(metalContext: metalContext)
        let fillAtPointDirtyPilotRows = try measureFillAtPointDirtyPilot(metalContext: metalContext)
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
        for row in historyEligibilityRows {
            let reasons = row.ineligibleReasonCounts
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue):\($0.value)" }
                .joined(separator: ",")
            print(
                "[history-eligibility] kind=\(row.operationKind) canvas=\(row.canvasSizeBucket) " +
                "layers=\(row.layerCountBucket) phase=\(row.warmupOrSteadyState.rawValue) " +
                "count=\(row.count) eligibleCount=\(row.eligibleCount) " +
                "eligibleRatio=\(String(format: "%.3f", row.eligibleRatio)) " +
                "fullBytes=\(row.fullEntryBytes) dirtyBytes=\(row.projectedDirtyEntryBytes) " +
                "savedBytes=\(row.savedBytes) fullLayers=\(row.fullLayers) " +
                "dirtyLayers=\(row.dirtyLayers) savedLayers=\(row.savedLayers) " +
                "overBudgetCount=\(row.overBudgetCount) reasons=\(reasons)"
            )
        }
        for row in historyCostRows {
            print(
                "[history-cost] canvas=\(row.canvasWidth)x\(row.canvasHeight) layers=\(row.layerCount) " +
                "entryBytes=\(row.entryBytes) checkpointMs=\(String(format: "%.3f", row.checkpointMs))"
            )
        }
        for row in brushDirtyPilotRows {
            print(
                "[\(row.toolLabel)-dirty-pilot] canvas=\(row.canvasWidth)x\(row.canvasHeight) layers=\(row.layerCount) " +
                "capture.full=\(String(format: "%.3f", row.fullCaptureCheckpointMs))ms " +
                "capture.dirty=\(String(format: "%.3f", row.dirtyCaptureCheckpointMs))ms " +
                "undo.full=\(String(format: "%.3f", row.fullUndoMs))ms " +
                "undo.dirty=\(String(format: "%.3f", row.dirtyUndoMs))ms " +
                "redo.full=\(String(format: "%.3f", row.fullRedoMs))ms " +
                "redo.dirty=\(String(format: "%.3f", row.dirtyRedoMs))ms " +
                "entryBytes.full=\(row.fullEntryBytes) entryBytes.dirty=\(row.dirtyEntryBytes) " +
                "retained.full=\(row.fullRetainedHistoryPoints) retained.dirty=\(row.dirtyRetainedHistoryPoints)"
            )
        }
        for row in eraserDirtyPilotRows {
            print(
                "[\(row.toolLabel)-dirty-pilot] canvas=\(row.canvasWidth)x\(row.canvasHeight) layers=\(row.layerCount) " +
                "capture.full=\(String(format: "%.3f", row.fullCaptureCheckpointMs))ms " +
                "capture.dirty=\(String(format: "%.3f", row.dirtyCaptureCheckpointMs))ms " +
                "undo.full=\(String(format: "%.3f", row.fullUndoMs))ms " +
                "undo.dirty=\(String(format: "%.3f", row.dirtyUndoMs))ms " +
                "redo.full=\(String(format: "%.3f", row.fullRedoMs))ms " +
                "redo.dirty=\(String(format: "%.3f", row.dirtyRedoMs))ms " +
                "entryBytes.full=\(row.fullEntryBytes) entryBytes.dirty=\(row.dirtyEntryBytes) " +
                "retained.full=\(row.fullRetainedHistoryPoints) retained.dirty=\(row.dirtyRetainedHistoryPoints)"
            )
        }
        for row in pixelOperationDirtyPilotRows {
            print(
                "[\(row.toolLabel)-dirty-pilot] canvas=\(row.canvasWidth)x\(row.canvasHeight) layers=\(row.layerCount) " +
                "capture.full=\(String(format: "%.3f", row.fullCaptureCheckpointMs))ms " +
                "capture.dirty=\(String(format: "%.3f", row.dirtyCaptureCheckpointMs))ms " +
                "undo.full=\(String(format: "%.3f", row.fullUndoMs))ms " +
                "undo.dirty=\(String(format: "%.3f", row.dirtyUndoMs))ms " +
                "redo.full=\(String(format: "%.3f", row.fullRedoMs))ms " +
                "redo.dirty=\(String(format: "%.3f", row.dirtyRedoMs))ms " +
                "entryBytes.full=\(row.fullEntryBytes) entryBytes.dirty=\(row.dirtyEntryBytes) " +
                "retained.full=\(row.fullRetainedHistoryPoints) retained.dirty=\(row.dirtyRetainedHistoryPoints)"
            )
        }
        for row in fillAtPointDirtyPilotRows {
            print(
                "[\(row.toolLabel)-dirty-pilot] canvas=\(row.canvasWidth)x\(row.canvasHeight) layers=\(row.layerCount) " +
                "capture.full=\(String(format: "%.3f", row.fullCaptureCheckpointMs))ms " +
                "capture.dirty=\(String(format: "%.3f", row.dirtyCaptureCheckpointMs))ms " +
                "undo.full=\(String(format: "%.3f", row.fullUndoMs))ms " +
                "undo.dirty=\(String(format: "%.3f", row.dirtyUndoMs))ms " +
                "redo.full=\(String(format: "%.3f", row.fullRedoMs))ms " +
                "redo.dirty=\(String(format: "%.3f", row.dirtyRedoMs))ms " +
                "entryBytes.full=\(row.fullEntryBytes) entryBytes.dirty=\(row.dirtyEntryBytes) " +
                "retained.full=\(row.fullRetainedHistoryPoints) retained.dirty=\(row.dirtyRetainedHistoryPoints)"
            )
        }
        for (label, value) in serializerMetrics.sorted(by: { $0.key < $1.key }) {
            print("[audit-timing] \(label)=\(String(format: "%.3f", value))ms")
        }
        print("[audit-memory] brush4096.peakBytes=\(brushPeakBytes)")
        print("[audit-memory] smudge4096.peakBytes=\(smudge4096Metrics.peakBytes)")
        print("[audit-memory] smudge8192.peakBytes=\(smudge8192Metrics.peakBytes)")
        print("[audit-timing] StageOneBrushRenderer.smudgeGatherPass.4096=\(String(format: "%.3f", smudge4096Metrics.smudgeGatherPassMs))ms")
        print("[audit-timing] StageOneBrushRenderer.smudgeGatherPass.8192=\(String(format: "%.3f", smudge8192Metrics.smudgeGatherPassMs))ms")
        print("[audit-timing] MetalStrokeEngine.smudgeStrokeWallTime.4096=\(String(format: "%.3f", smudge4096Metrics.strokeWallMs))ms")
        print("[audit-timing] MetalStrokeEngine.smudgeStrokeWallTime.8192=\(String(format: "%.3f", smudge8192Metrics.strokeWallMs))ms")
        print("[audit-timing] MetalStrokeEngine.smudgeFlushCommandBufferCompletion.4096=\(String(format: "%.3f", smudge4096Metrics.commandBufferCompletionMs))ms")
        print("[audit-timing] MetalStrokeEngine.smudgeFlushCommandBufferCompletion.8192=\(String(format: "%.3f", smudge8192Metrics.commandBufferCompletionMs))ms")
    }

    @Test
    @MainActor
    func fillAtPointDirtyPilotMeasurementOnly() throws {
        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal unavailable")
            return
        }

        let rows = try measureFillAtPointDirtyPilot(
            metalContext: metalContext,
            cases: quickFillAtPointDirtyPilotCases
        )
        var outputLines: [String] = []
        for row in rows {
            let line =
                "[\(row.toolLabel)-dirty-pilot] canvas=\(row.canvasWidth)x\(row.canvasHeight) layers=\(row.layerCount) " +
                "capture.full=\(String(format: "%.3f", row.fullCaptureCheckpointMs))ms " +
                "capture.dirty=\(String(format: "%.3f", row.dirtyCaptureCheckpointMs))ms " +
                "undo.full=\(String(format: "%.3f", row.fullUndoMs))ms " +
                "undo.dirty=\(String(format: "%.3f", row.dirtyUndoMs))ms " +
                "redo.full=\(String(format: "%.3f", row.fullRedoMs))ms " +
                "redo.dirty=\(String(format: "%.3f", row.dirtyRedoMs))ms " +
                "entryBytes.full=\(row.fullEntryBytes) entryBytes.dirty=\(row.dirtyEntryBytes) " +
                "retained.full=\(row.fullRetainedHistoryPoints) retained.dirty=\(row.dirtyRetainedHistoryPoints)"
            print(line)
            outputLines.append(line)
        }
        try outputLines.joined(separator: "\n").write(
            to: URL(fileURLWithPath: "/tmp/fill_at_point_dirty_pilot.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    @Test
    @MainActor
    func fillAtPointDirtyPilot4096x4096_4Layers() throws {
        guard heavyPerformanceAuditEnabled else {
            print("[audit-skip] Set \(heavyPerformanceAuditEnvironmentKey)=1 to run fillAtPointDirtyPilot4096x4096_4Layers.")
            return
        }
        try measureAndWriteSingleFillAtPointDirtyPilotCase(
            canvasSize: .init(width: 4096, height: 4096),
            layerCount: 4,
            outputPath: "/tmp/fill_at_point_dirty_pilot_4096_4.txt"
        )
    }

    @Test
    @MainActor
    func fillAtPointDirtyPilot4096x4096_8Layers() throws {
        guard heavyPerformanceAuditEnabled else {
            print("[audit-skip] Set \(heavyPerformanceAuditEnvironmentKey)=1 to run fillAtPointDirtyPilot4096x4096_8Layers.")
            return
        }
        try measureAndWriteSingleFillAtPointDirtyPilotCase(
            canvasSize: .init(width: 4096, height: 4096),
            layerCount: 8,
            outputPath: "/tmp/fill_at_point_dirty_pilot_4096_8.txt"
        )
    }

    @Test
    @MainActor
    func fillAtPointDirtyPilot8192x8192_4Layers() throws {
        guard heavyPerformanceAuditEnabled else {
            print("[audit-skip] Set \(heavyPerformanceAuditEnvironmentKey)=1 to run fillAtPointDirtyPilot8192x8192_4Layers.")
            return
        }
        try measureAndWriteSingleFillAtPointDirtyPilotCase(
            canvasSize: .init(width: 8192, height: 8192),
            layerCount: 4,
            outputPath: "/tmp/fill_at_point_dirty_pilot_8192_4.txt"
        )
    }

    @Test
    @MainActor
    func fillAtPointDirtyPilot8192x8192_8Layers() throws {
        guard heavyPerformanceAuditEnabled else {
            print("[audit-skip] Set \(heavyPerformanceAuditEnvironmentKey)=1 to run fillAtPointDirtyPilot8192x8192_8Layers.")
            return
        }
        try measureAndWriteSingleFillAtPointDirtyPilotCase(
            canvasSize: .init(width: 8192, height: 8192),
            layerCount: 8,
            outputPath: "/tmp/fill_at_point_dirty_pilot_8192_8.txt"
        )
    }

    @Test
    @MainActor
    func selectionFillProfilingBreakdown() throws {
        guard heavyPerformanceAuditEnabled else {
            print("[audit-skip] Set \(heavyPerformanceAuditEnvironmentKey)=1 to run selectionFillProfilingBreakdown.")
            return
        }

        let selectionFill = try measureSelectionPixelOperationBreakdown(
            operation: .selectionFill,
            canvasSize: .init(width: 3000, height: 3000),
            layerCount: 4
        )
        let lassoFill = try measureSelectionPixelOperationBreakdown(
            operation: .lassoFill,
            canvasSize: .init(width: 3000, height: 3000),
            layerCount: 4
        )

        print("[selection-fill-profile] kind=selection.fill canvas=3000x3000 layers=4 historyCheckpoint=\(String(format: "%.3f", selectionFill.historyCheckpointMs))ms maskPreparation=\(String(format: "%.3f", selectionFill.maskPreparationMs))ms snapshot=\(String(format: "%.3f", selectionFill.snapshotMs))ms pixelMutation=\(String(format: "%.3f", selectionFill.pixelMutationMs))ms restore=\(String(format: "%.3f", selectionFill.restoreMs))ms uiConfirm=\(String(format: "%.3f", selectionFill.uiConfirmMs))ms total=\(String(format: "%.3f", selectionFill.totalMs))ms")
        print("[selection-fill-profile] kind=lasso.fill canvas=3000x3000 layers=4 historyCheckpoint=\(String(format: "%.3f", lassoFill.historyCheckpointMs))ms maskPreparation=\(String(format: "%.3f", lassoFill.maskPreparationMs))ms snapshot=\(String(format: "%.3f", lassoFill.snapshotMs))ms pixelMutation=\(String(format: "%.3f", lassoFill.pixelMutationMs))ms restore=\(String(format: "%.3f", lassoFill.restoreMs))ms uiConfirm=\(String(format: "%.3f", lassoFill.uiConfirmMs))ms total=\(String(format: "%.3f", lassoFill.totalMs))ms")
    }
}

private struct HistoryCostAuditRow {
    var canvasWidth: Int
    var canvasHeight: Int
    var layerCount: Int
    var entryBytes: Int
    var checkpointMs: Double
}

private struct BrushDirtyHistoryPilotRow {
    var toolLabel: String
    var canvasWidth: Int
    var canvasHeight: Int
    var layerCount: Int
    var fullCaptureCheckpointMs: Double
    var dirtyCaptureCheckpointMs: Double
    var fullUndoMs: Double
    var dirtyUndoMs: Double
    var fullRedoMs: Double
    var dirtyRedoMs: Double
    var fullEntryBytes: Int
    var dirtyEntryBytes: Int
    var fullRetainedHistoryPoints: Int
    var dirtyRetainedHistoryPoints: Int
}

private struct SelectionPixelOperationProfileRow {
    var historyCheckpointMs: Double
    var maskPreparationMs: Double
    var snapshotMs: Double
    var pixelMutationMs: Double
    var restoreMs: Double
    var uiConfirmMs: Double
    var totalMs: Double
}

private enum SelectionPixelOperationProfileKind {
    case selectionFill
    case lassoFill
}

@MainActor
private func measureAndWriteSingleFillAtPointDirtyPilotCase(
    canvasSize: CanvasSize,
    layerCount: Int,
    outputPath: String
) throws {
    let fullCapture = try measureFillAtPointCheckpoint(
        canvasSize: canvasSize,
        layerCount: layerCount,
        captureMode: .full
    )
    let dirtyCapture = try measureFillAtPointCheckpoint(
        canvasSize: canvasSize,
        layerCount: layerCount,
        captureMode: .inPlaceChangedLayers([LayerID()])
    )
    let fullHistoryNavigation = try measureFillAtPointUndoRedo(
        canvasSize: canvasSize,
        layerCount: layerCount,
        captureMode: .full
    )
    let dirtyHistoryNavigation = try measureFillAtPointUndoRedo(
        canvasSize: canvasSize,
        layerCount: layerCount,
        captureMode: .inPlaceChangedLayers([LayerID()])
    )

    let row = BrushDirtyHistoryPilotRow(
        toolLabel: "fill-at-point",
        canvasWidth: canvasSize.width,
        canvasHeight: canvasSize.height,
        layerCount: layerCount,
        fullCaptureCheckpointMs: fullCapture.checkpointMs,
        dirtyCaptureCheckpointMs: dirtyCapture.checkpointMs,
        fullUndoMs: fullHistoryNavigation.undoMs,
        dirtyUndoMs: dirtyHistoryNavigation.undoMs,
        fullRedoMs: fullHistoryNavigation.redoMs,
        dirtyRedoMs: dirtyHistoryNavigation.redoMs,
        fullEntryBytes: fullCapture.entryBytes,
        dirtyEntryBytes: dirtyCapture.entryBytes,
        fullRetainedHistoryPoints: retainedHistoryPointsForBudget(entryBytes: fullCapture.entryBytes),
        dirtyRetainedHistoryPoints: retainedHistoryPointsForBudget(entryBytes: dirtyCapture.entryBytes)
    )

    let line =
        "[\(row.toolLabel)-dirty-pilot] canvas=\(row.canvasWidth)x\(row.canvasHeight) layers=\(row.layerCount) " +
        "capture.full=\(String(format: "%.3f", row.fullCaptureCheckpointMs))ms " +
        "capture.dirty=\(String(format: "%.3f", row.dirtyCaptureCheckpointMs))ms " +
        "undo.full=\(String(format: "%.3f", row.fullUndoMs))ms " +
        "undo.dirty=\(String(format: "%.3f", row.dirtyUndoMs))ms " +
        "redo.full=\(String(format: "%.3f", row.fullRedoMs))ms " +
        "redo.dirty=\(String(format: "%.3f", row.dirtyRedoMs))ms " +
        "entryBytes.full=\(row.fullEntryBytes) entryBytes.dirty=\(row.dirtyEntryBytes) " +
        "retained.full=\(row.fullRetainedHistoryPoints) retained.dirty=\(row.dirtyRetainedHistoryPoints)"
    print(line)
    try line.write(to: URL(fileURLWithPath: outputPath), atomically: true, encoding: .utf8)
}

@MainActor
private func measureSelectionPixelOperationBreakdown(
    operation: SelectionPixelOperationProfileKind,
    canvasSize: CanvasSize,
    layerCount: Int
) throws -> SelectionPixelOperationProfileRow {
    let harness = try makePixelOperationHistoryMeasurementHarness(
        canvasSize: canvasSize,
        layerCount: layerCount
    )
    PerformanceAuditStore.shared.reset()

    switch operation {
    case .selectionFill:
        applySelectionFill(on: harness.viewModel, rect: (8, 8, 2800, 2800))
    case .lassoFill:
        harness.viewModel.selectTool(.lassoSelection)
        createCommittedLassoSelection(
            on: harness.viewModel,
            points: [
                .init(x: 8, y: 8),
                .init(x: 2800, y: 8),
                .init(x: 2800, y: 2800),
                .init(x: 8, y: 2800),
                .init(x: 8, y: 8)
            ]
        )
        harness.viewModel.fillLassoContents()
    }

    let snapshot = PerformanceAuditStore.shared.snapshot()
    return SelectionPixelOperationProfileRow(
        historyCheckpointMs: snapshot.averageDuration("WorkspaceViewModel.applyPixelOperation.historyCheckpoint") ?? 0,
        maskPreparationMs: snapshot.averageDuration("WorkspaceViewModel.applyPixelOperation.maskPreparation") ?? 0,
        snapshotMs: snapshot.averageDuration("WorkspaceViewModel.applyPixelOperation.snapshot") ?? 0,
        pixelMutationMs: snapshot.averageDuration("WorkspaceViewModel.applyPixelOperation.pixelMutation") ?? 0,
        restoreMs: snapshot.averageDuration("WorkspaceViewModel.applyPixelOperation.restore") ?? 0,
        uiConfirmMs: snapshot.averageDuration("WorkspaceViewModel.applyPixelOperation.uiConfirm") ?? 0,
        totalMs: snapshot.averageDuration("WorkspaceViewModel.applyPixelOperation.total") ?? 0
    )
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
private func measureHistoryEligibilitySummary(
    metalContext: MetalDeviceContext
) throws -> [HistoryEligibilityAuditSummaryRow] {
    let bootstrap = try AppBootstrap(
        metalContext: metalContext,
        layerSurfaceStore: StageOneLayerSurfaceStore()
    )
    let viewModel = WorkspaceViewModel(
        bootstrap: bootstrap,
        installsZoomKeyboardMonitor: false
    )

    viewModel.addLayer()
    viewModel.addLayer()
    viewModel.addLayer()

    bootstrap.historyController.resetHistory()
    PerformanceAuditStore.shared.reset()

    viewModel.selectTool(.brush)
    viewModel.beginStrokeIfNeeded()
    viewModel.applyStroke(
        samples: [
            .init(location: .init(x: 10, y: 10), pressure: 1),
            .init(location: .init(x: 20, y: 18), pressure: 1)
        ]
    )
    viewModel.endStroke()
    try flushPendingBrushWork(viewModel: viewModel, metalContext: metalContext)
    viewModel.opportunisticallyDrainBrushCommits(hadLiveBrushWorkThisFrame: false)

    viewModel.selectTool(.eraser)
    viewModel.beginStrokeIfNeeded()
    viewModel.applyStroke(
        samples: [
            .init(location: .init(x: 12, y: 12), pressure: 1),
            .init(location: .init(x: 22, y: 20), pressure: 1)
        ]
    )
    viewModel.endStroke()
    try flushPendingBrushWork(viewModel: viewModel, metalContext: metalContext)
    viewModel.opportunisticallyDrainBrushCommits(hadLiveBrushWorkThisFrame: false)

    viewModel.selectTool(.smudge)
    viewModel.beginStrokeIfNeeded()
    viewModel.applyStroke(
        samples: [
            .init(location: .init(x: 14, y: 14), pressure: 1),
            .init(location: .init(x: 24, y: 22), pressure: 1)
        ]
    )
    viewModel.endStroke()
    try flushPendingBrushWork(viewModel: viewModel, metalContext: metalContext)
    viewModel.opportunisticallyDrainBrushCommits(hadLiveBrushWorkThisFrame: false)

    viewModel.selectTool(.brush)
    viewModel.beginStrokeIfNeeded()
    viewModel.applyStroke(
        samples: [
            .init(location: .init(x: 18, y: 18), pressure: 1),
            .init(location: .init(x: 28, y: 26), pressure: 1)
        ]
    )
    viewModel.endStroke()
    try flushPendingBrushWork(viewModel: viewModel, metalContext: metalContext)
    viewModel.opportunisticallyDrainBrushCommits(hadLiveBrushWorkThisFrame: false)

    viewModel.fillAtPoint(.init(x: 14, y: 14))

    viewModel.selectTool(.lassoSelection)
    createCommittedLassoSelection(
        on: viewModel,
        points: [
            .init(x: 8, y: 8),
            .init(x: 36, y: 8),
            .init(x: 36, y: 36),
            .init(x: 8, y: 36),
            .init(x: 8, y: 8)
        ]
    )
    viewModel.fillSelectionContents()

    viewModel.selectTool(.lassoSelection)
    createCommittedLassoSelection(
        on: viewModel,
        points: [
            .init(x: 16, y: 16),
            .init(x: 32, y: 16),
            .init(x: 32, y: 32),
            .init(x: 16, y: 32),
            .init(x: 16, y: 16)
        ]
    )
    viewModel.fillLassoContents()

    viewModel.selectTool(.lassoSelection)
    createCommittedLassoSelection(
        on: viewModel,
        points: [
            .init(x: 20, y: 20),
            .init(x: 28, y: 20),
            .init(x: 28, y: 28),
            .init(x: 20, y: 28),
            .init(x: 20, y: 20)
        ]
    )
    viewModel.eraseLassoContents()

    viewModel.undo()
    viewModel.redo()

    try recordEligibilityAuditOnly(
        metalContext: metalContext,
        canvasSize: .init(width: 4096, height: 4096),
        layerCount: 1,
        operationKind: "brush.commit",
        candidateChangedLayerIDsKnown: true
    )
    try recordEligibilityAuditOnly(
        metalContext: metalContext,
        canvasSize: .init(width: 4096, height: 4096),
        layerCount: 8,
        operationKind: "brush.commit",
        candidateChangedLayerIDsKnown: true
    )
    try recordEligibilityAuditOnly(
        metalContext: metalContext,
        canvasSize: .init(width: 8192, height: 8192),
        layerCount: 4,
        operationKind: "brush.commit",
        candidateChangedLayerIDsKnown: true
    )
    try recordEligibilityAuditOnly(
        metalContext: metalContext,
        canvasSize: .init(width: 8192, height: 8192),
        layerCount: 8,
        operationKind: "brush.commit",
        candidateChangedLayerIDsKnown: true
    )

    return PerformanceAuditStore.shared.snapshot().historyEligibilitySummaryRows()
}

@MainActor
private func recordEligibilityAuditOnly(
    metalContext: MetalDeviceContext,
    canvasSize: CanvasSize,
    layerCount: Int,
    operationKind: String,
    candidateChangedLayerIDsKnown: Bool
) throws {
    var workspaceState = WorkspaceState.stageOneDefault
    workspaceState.document.canvasSize = canvasSize
    workspaceState.document.metadata.updatedAt = Date()

    let workspaceStore = WorkspaceStore(state: workspaceState)
    let layerSurfaceStore = StageOneLayerSurfaceStore()
    layerSurfaceStore.prepareTextures(for: workspaceState.document, metal: metalContext)
    let serializer = LayerTextureSerializer(metalContext: metalContext)
    let history = HistoryController(
        workspaceStore: workspaceStore,
        layerSurfaceStore: layerSurfaceStore,
        serializer: serializer,
        metalContext: metalContext
    )

    if layerCount > 1 {
        for _ in 1..<layerCount {
            workspaceStore.updateDocument { document in
                _ = document.addLayer()
            }
        }
        layerSurfaceStore.prepareTextures(for: workspaceStore.state.document, metal: metalContext)
    }

    let activeLayerID = workspaceStore.state.document.activeLayerID
    try history.captureCheckpoint(
        auditContext: HistoryEligibilityAuditContext(
            operationKind: operationKind,
            candidateChangedLayerIDs: candidateChangedLayerIDsKnown ? [activeLayerID] : [],
            candidateChangedLayerIDsKnown: candidateChangedLayerIDsKnown,
            comparisonWorkspace: workspaceStore.state
        )
    )
}

@MainActor
private func measureHistoryCostByCanvasAndLayerCount(
    metalContext: MetalDeviceContext
) throws -> [HistoryCostAuditRow] {
    let cases: [(CanvasSize, Int)] = [
        (.init(width: 4096, height: 4096), 1),
        (.init(width: 4096, height: 4096), 4),
        (.init(width: 4096, height: 4096), 8),
        (.init(width: 8192, height: 8192), 1),
        (.init(width: 8192, height: 8192), 4),
        (.init(width: 8192, height: 8192), 8)
    ]

    return try cases.map { canvasSize, layerCount in
        var workspaceState = WorkspaceState.stageOneDefault
        workspaceState.document.canvasSize = canvasSize
        workspaceState.document.metadata.updatedAt = Date()

        let workspaceStore = WorkspaceStore(state: workspaceState)
        let layerSurfaceStore = StageOneLayerSurfaceStore()
        layerSurfaceStore.prepareTextures(for: workspaceState.document, metal: metalContext)
        let serializer = LayerTextureSerializer(metalContext: metalContext)
        let history = HistoryController(
            workspaceStore: workspaceStore,
            layerSurfaceStore: layerSurfaceStore,
            serializer: serializer,
            metalContext: metalContext
        )

        if layerCount > 1 {
            for _ in 1..<layerCount {
                workspaceStore.updateDocument { document in
                    _ = document.addLayer()
                }
            }
            layerSurfaceStore.prepareTextures(for: workspaceStore.state.document, metal: metalContext)
        }

        let startNs = DispatchTime.now().uptimeNanoseconds
        try history.captureCheckpoint()
        let checkpointMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000
        let entry = try history.captureCurrentEntry()

        return HistoryCostAuditRow(
            canvasWidth: canvasSize.width,
            canvasHeight: canvasSize.height,
            layerCount: layerCount,
            entryBytes: entry.approxByteCount,
            checkpointMs: checkpointMs
        )
    }
}

@MainActor
private func measureBrushDirtyHistoryPilot(
    metalContext: MetalDeviceContext
) throws -> [BrushDirtyHistoryPilotRow] {
    try measureDirtyHistoryPilot(metalContext: metalContext, tool: .brush, toolLabel: "brush")
}

@MainActor
private func measureEraserDirtyHistoryPilot(
    metalContext: MetalDeviceContext
) throws -> [BrushDirtyHistoryPilotRow] {
    try measureDirtyHistoryPilot(metalContext: metalContext, tool: .eraser, toolLabel: "eraser")
}

@MainActor
private func measureApplyPixelOperationDirtyPilot(
    metalContext: MetalDeviceContext
) throws -> [BrushDirtyHistoryPilotRow] {
    let cases: [(CanvasSize, Int)] = [
        (.init(width: 4096, height: 4096), 4),
        (.init(width: 4096, height: 4096), 8),
        (.init(width: 8192, height: 8192), 4),
        (.init(width: 8192, height: 8192), 8)
    ]

    return try cases.map { canvasSize, layerCount in
        let fullCapture = try measureApplyPixelOperationCheckpoint(
            canvasSize: canvasSize,
            layerCount: layerCount,
            captureMode: .full
        )
        let dirtyCapture = try measureApplyPixelOperationCheckpoint(
            canvasSize: canvasSize,
            layerCount: layerCount,
            captureMode: .inPlaceChangedLayers([LayerID()])
        )
        let fullHistoryNavigation = try measureApplyPixelOperationUndoRedo(
            canvasSize: canvasSize,
            layerCount: layerCount,
            captureMode: .full
        )
        let dirtyHistoryNavigation = try measureApplyPixelOperationUndoRedo(
            canvasSize: canvasSize,
            layerCount: layerCount,
            captureMode: .inPlaceChangedLayers([LayerID()])
        )

        return BrushDirtyHistoryPilotRow(
            toolLabel: "apply-pixel-operation",
            canvasWidth: canvasSize.width,
            canvasHeight: canvasSize.height,
            layerCount: layerCount,
            fullCaptureCheckpointMs: fullCapture.checkpointMs,
            dirtyCaptureCheckpointMs: dirtyCapture.checkpointMs,
            fullUndoMs: fullHistoryNavigation.undoMs,
            dirtyUndoMs: dirtyHistoryNavigation.undoMs,
            fullRedoMs: fullHistoryNavigation.redoMs,
            dirtyRedoMs: dirtyHistoryNavigation.redoMs,
            fullEntryBytes: fullCapture.entryBytes,
            dirtyEntryBytes: dirtyCapture.entryBytes,
            fullRetainedHistoryPoints: retainedHistoryPointsForBudget(entryBytes: fullCapture.entryBytes),
            dirtyRetainedHistoryPoints: retainedHistoryPointsForBudget(entryBytes: dirtyCapture.entryBytes)
        )
    }
}

@MainActor
private func measureFillAtPointDirtyPilot(
    metalContext: MetalDeviceContext,
    cases: [(CanvasSize, Int)] = heavyDirtyPilotCases
) throws -> [BrushDirtyHistoryPilotRow] {
    return try cases.map { canvasSize, layerCount in
        print("[fill-at-point-dirty-pilot] measuring canvas=\(canvasSize.width)x\(canvasSize.height) layers=\(layerCount)")
        let fullCapture = try measureFillAtPointCheckpoint(
            canvasSize: canvasSize,
            layerCount: layerCount,
            captureMode: .full
        )
        let dirtyCapture = try measureFillAtPointCheckpoint(
            canvasSize: canvasSize,
            layerCount: layerCount,
            captureMode: .inPlaceChangedLayers([LayerID()])
        )
        let fullHistoryNavigation = try measureFillAtPointUndoRedo(
            canvasSize: canvasSize,
            layerCount: layerCount,
            captureMode: .full
        )
        let dirtyHistoryNavigation = try measureFillAtPointUndoRedo(
            canvasSize: canvasSize,
            layerCount: layerCount,
            captureMode: .inPlaceChangedLayers([LayerID()])
        )

        return BrushDirtyHistoryPilotRow(
            toolLabel: "fill-at-point",
            canvasWidth: canvasSize.width,
            canvasHeight: canvasSize.height,
            layerCount: layerCount,
            fullCaptureCheckpointMs: fullCapture.checkpointMs,
            dirtyCaptureCheckpointMs: dirtyCapture.checkpointMs,
            fullUndoMs: fullHistoryNavigation.undoMs,
            dirtyUndoMs: dirtyHistoryNavigation.undoMs,
            fullRedoMs: fullHistoryNavigation.redoMs,
            dirtyRedoMs: dirtyHistoryNavigation.redoMs,
            fullEntryBytes: fullCapture.entryBytes,
            dirtyEntryBytes: dirtyCapture.entryBytes,
            fullRetainedHistoryPoints: retainedHistoryPointsForBudget(entryBytes: fullCapture.entryBytes),
            dirtyRetainedHistoryPoints: retainedHistoryPointsForBudget(entryBytes: dirtyCapture.entryBytes)
        )
    }
}

@MainActor
private func measureDirtyHistoryPilot(
    metalContext: MetalDeviceContext,
    tool: ToolKind,
    toolLabel: String
) throws -> [BrushDirtyHistoryPilotRow] {
    let cases: [(CanvasSize, Int)] = [
        (.init(width: 4096, height: 4096), 4),
        (.init(width: 4096, height: 4096), 8),
        (.init(width: 8192, height: 8192), 4),
        (.init(width: 8192, height: 8192), 8)
    ]

    return try cases.map { canvasSize, layerCount in
        let fullCapture = try measureBrushCommitCheckpoint(
            canvasSize: canvasSize,
            layerCount: layerCount,
            captureMode: .full,
            tool: tool
        )
        let dirtyCapture = try measureBrushCommitCheckpoint(
            canvasSize: canvasSize,
            layerCount: layerCount,
            captureMode: .inPlaceChangedLayers([LayerID()]),
            tool: tool
        )
        let fullHistoryNavigation = try measureBrushUndoRedo(
            canvasSize: canvasSize,
            layerCount: layerCount,
            captureMode: .full,
            tool: tool
        )
        let dirtyHistoryNavigation = try measureBrushUndoRedo(
            canvasSize: canvasSize,
            layerCount: layerCount,
            captureMode: .inPlaceChangedLayers([LayerID()]),
            tool: tool
        )

        return BrushDirtyHistoryPilotRow(
            toolLabel: toolLabel,
            canvasWidth: canvasSize.width,
            canvasHeight: canvasSize.height,
            layerCount: layerCount,
            fullCaptureCheckpointMs: fullCapture.checkpointMs,
            dirtyCaptureCheckpointMs: dirtyCapture.checkpointMs,
            fullUndoMs: fullHistoryNavigation.undoMs,
            dirtyUndoMs: dirtyHistoryNavigation.undoMs,
            fullRedoMs: fullHistoryNavigation.redoMs,
            dirtyRedoMs: dirtyHistoryNavigation.redoMs,
            fullEntryBytes: fullCapture.entryBytes,
            dirtyEntryBytes: dirtyCapture.entryBytes,
            fullRetainedHistoryPoints: retainedHistoryPointsForBudget(entryBytes: fullCapture.entryBytes),
            dirtyRetainedHistoryPoints: retainedHistoryPointsForBudget(entryBytes: dirtyCapture.entryBytes)
        )
    }
}

@MainActor
private func measureBrushCommitCheckpoint(
    canvasSize: CanvasSize,
    layerCount: Int,
    captureMode: HistoryCaptureMode,
    tool: ToolKind
) throws -> (checkpointMs: Double, entryBytes: Int) {
    let harness = try makeBrushHistoryMeasurementHarness(
        canvasSize: canvasSize,
        layerCount: layerCount
    )
    let activeLayerID = harness.workspaceStore.state.document.activeLayerID
    let resolvedCaptureMode = resolvedBrushCaptureMode(
        captureMode,
        layerID: activeLayerID
    )

    let startNs = DispatchTime.now().uptimeNanoseconds
    try recordBrushStroke(
        with: harness,
        tool: tool,
        layerID: activeLayerID,
        captureMode: resolvedCaptureMode,
        pointSeed: 0
    )
    let checkpointMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000
    let entryBytes = harness.history.debugUndoEntryApproxByteCounts.last ?? 0
    return (checkpointMs: checkpointMs, entryBytes: entryBytes)
}

@MainActor
private func measureApplyPixelOperationCheckpoint(
    canvasSize: CanvasSize,
    layerCount: Int,
    captureMode: HistoryCaptureMode
) throws -> (checkpointMs: Double, entryBytes: Int) {
    let harness = try makePixelOperationHistoryMeasurementHarness(
        canvasSize: canvasSize,
        layerCount: layerCount
    )
    let activeLayerID = harness.viewModel.workspace.document.activeLayerID
    harness.viewModel.selectLayer(activeLayerID)
    harness.viewModel.debugPixelOperationHistoryCaptureModeOverride = resolvedBrushCaptureMode(captureMode, layerID: activeLayerID)

    let startNs = DispatchTime.now().uptimeNanoseconds
    applySelectionFill(on: harness.viewModel, rect: (8, 8, 40, 40))
    let checkpointMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000
    let entryBytes = harness.bootstrap.historyController.debugUndoEntryApproxByteCounts.last ?? 0
    return (checkpointMs: checkpointMs, entryBytes: entryBytes)
}

@MainActor
private func measureFillAtPointCheckpoint(
    canvasSize: CanvasSize,
    layerCount: Int,
    captureMode: HistoryCaptureMode
) throws -> (checkpointMs: Double, entryBytes: Int) {
    let harness = try makePixelOperationHistoryMeasurementHarness(
        canvasSize: canvasSize,
        layerCount: layerCount
    )
    let activeLayerID = harness.viewModel.workspace.document.activeLayerID
    harness.viewModel.selectLayer(activeLayerID)
    harness.viewModel.debugFillAtPointHistoryCaptureModeOverride = resolvedBrushCaptureMode(captureMode, layerID: activeLayerID)

    let startNs = DispatchTime.now().uptimeNanoseconds
    harness.viewModel.fillAtPoint(.init(x: 12, y: 12))
    let checkpointMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000
    let entryBytes = harness.bootstrap.historyController.debugUndoEntryApproxByteCounts.last ?? 0
    return (checkpointMs: checkpointMs, entryBytes: entryBytes)
}

@MainActor
private func measureBrushUndoRedo(
    canvasSize: CanvasSize,
    layerCount: Int,
    captureMode: HistoryCaptureMode,
    tool: ToolKind
) throws -> (undoMs: Double, redoMs: Double) {
    let harness = try makeBrushHistoryMeasurementHarness(
        canvasSize: canvasSize,
        layerCount: layerCount
    )
    let layerIDs = harness.workspaceStore.state.document.layers.map(\.id)
    let firstLayerID = layerIDs[0]
    let secondLayerID = layerIDs[min(1, layerIDs.count - 1)]

    try recordBrushStroke(
        with: harness,
        tool: .brush,
        layerID: firstLayerID,
        captureMode: .full,
        pointSeed: 0
    )
    try recordBrushStroke(
        with: harness,
        tool: .brush,
        layerID: secondLayerID,
        captureMode: .full,
        pointSeed: 1
    )
    try recordBrushStroke(
        with: harness,
        tool: tool,
        layerID: firstLayerID,
        captureMode: resolvedBrushCaptureMode(captureMode, layerID: firstLayerID),
        pointSeed: 2
    )
    try recordBrushStroke(
        with: harness,
        tool: tool,
        layerID: secondLayerID,
        captureMode: resolvedBrushCaptureMode(captureMode, layerID: secondLayerID),
        pointSeed: 3
    )

    let undoStartNs = DispatchTime.now().uptimeNanoseconds
    _ = try harness.history.undo()
    let undoMs = Double(DispatchTime.now().uptimeNanoseconds - undoStartNs) / 1_000_000

    let redoStartNs = DispatchTime.now().uptimeNanoseconds
    _ = try harness.history.redo()
    let redoMs = Double(DispatchTime.now().uptimeNanoseconds - redoStartNs) / 1_000_000

    return (undoMs: undoMs, redoMs: redoMs)
}

@MainActor
private func measureApplyPixelOperationUndoRedo(
    canvasSize: CanvasSize,
    layerCount: Int,
    captureMode: HistoryCaptureMode
) throws -> (undoMs: Double, redoMs: Double) {
    let harness = try makePixelOperationHistoryMeasurementHarness(
        canvasSize: canvasSize,
        layerCount: layerCount
    )
    let layerIDs = harness.viewModel.workspace.document.layers.map(\.id)
    let firstLayerID = layerIDs[0]
    let secondLayerID = layerIDs[min(1, layerIDs.count - 1)]

    harness.viewModel.debugPixelOperationHistoryCaptureModeOverride = resolvedBrushCaptureMode(captureMode, layerID: firstLayerID)
    harness.viewModel.selectLayer(firstLayerID)
    applySelectionFill(on: harness.viewModel, rect: (8, 8, 40, 40))

    harness.viewModel.debugPixelOperationHistoryCaptureModeOverride = resolvedBrushCaptureMode(captureMode, layerID: secondLayerID)
    harness.viewModel.selectLayer(secondLayerID)
    applySelectionFill(on: harness.viewModel, rect: (48, 48, 80, 80))

    let undoStartNs = DispatchTime.now().uptimeNanoseconds
    harness.viewModel.undo()
    let undoMs = Double(DispatchTime.now().uptimeNanoseconds - undoStartNs) / 1_000_000

    let redoStartNs = DispatchTime.now().uptimeNanoseconds
    harness.viewModel.redo()
    let redoMs = Double(DispatchTime.now().uptimeNanoseconds - redoStartNs) / 1_000_000

    return (undoMs: undoMs, redoMs: redoMs)
}

@MainActor
private func measureFillAtPointUndoRedo(
    canvasSize: CanvasSize,
    layerCount: Int,
    captureMode: HistoryCaptureMode
) throws -> (undoMs: Double, redoMs: Double) {
    let harness = try makePixelOperationHistoryMeasurementHarness(
        canvasSize: canvasSize,
        layerCount: layerCount
    )
    let layerIDs = harness.viewModel.workspace.document.layers.map(\.id)
    let firstLayerID = layerIDs[0]
    let secondLayerID = layerIDs[min(1, layerIDs.count - 1)]

    harness.viewModel.debugFillAtPointHistoryCaptureModeOverride = resolvedBrushCaptureMode(captureMode, layerID: firstLayerID)
    harness.viewModel.selectLayer(firstLayerID)
    harness.viewModel.fillAtPoint(.init(x: 12, y: 12))

    harness.viewModel.debugFillAtPointHistoryCaptureModeOverride = resolvedBrushCaptureMode(captureMode, layerID: secondLayerID)
    harness.viewModel.selectLayer(secondLayerID)
    harness.viewModel.fillAtPoint(.init(x: 46, y: 46))

    let undoStartNs = DispatchTime.now().uptimeNanoseconds
    harness.viewModel.undo()
    let undoMs = Double(DispatchTime.now().uptimeNanoseconds - undoStartNs) / 1_000_000

    let redoStartNs = DispatchTime.now().uptimeNanoseconds
    harness.viewModel.redo()
    let redoMs = Double(DispatchTime.now().uptimeNanoseconds - redoStartNs) / 1_000_000

    return (undoMs: undoMs, redoMs: redoMs)
}

@MainActor
private func makeBrushHistoryMeasurementHarness(
    canvasSize: CanvasSize,
    layerCount: Int
) throws -> (
    workspaceStore: WorkspaceStore,
    metalContext: MetalDeviceContext,
    layerSurfaceStore: StageOneLayerSurfaceStore,
    serializer: LayerTextureSerializer,
    history: HistoryController,
    engine: MetalStrokeEngine
) {
    guard let metalContext = MetalDeviceContext() else {
        throw AuditHarnessError.metalUnavailable
    }

    var workspaceState = WorkspaceState.stageOneDefault
    workspaceState.document.canvasSize = canvasSize
    workspaceState.document.metadata.updatedAt = Date()

    let workspaceStore = WorkspaceStore(state: workspaceState)
    let layerSurfaceStore = StageOneLayerSurfaceStore()
    layerSurfaceStore.prepareTextures(for: workspaceState.document, metal: metalContext)
    if layerCount > 1 {
        for _ in 1..<layerCount {
            workspaceStore.updateDocument { document in
                _ = document.addLayer()
            }
        }
        layerSurfaceStore.prepareTextures(for: workspaceStore.state.document, metal: metalContext)
    }

    let serializer = LayerTextureSerializer(metalContext: metalContext)
    let history = HistoryController(
        workspaceStore: workspaceStore,
        layerSurfaceStore: layerSurfaceStore,
        serializer: serializer,
        metalContext: metalContext
    )
    let engine = try MetalStrokeEngine(
        metalContext: metalContext,
        layerSurfaceStore: layerSurfaceStore
    )
    return (
        workspaceStore: workspaceStore,
        metalContext: metalContext,
        layerSurfaceStore: layerSurfaceStore,
        serializer: serializer,
        history: history,
        engine: engine
    )
}

@MainActor
private func makePixelOperationHistoryMeasurementHarness(
    canvasSize: CanvasSize,
    layerCount: Int
) throws -> (
    bootstrap: AppBootstrap,
    viewModel: WorkspaceViewModel
) {
    guard let metalContext = MetalDeviceContext() else {
        throw AuditHarnessError.metalUnavailable
    }
    let workspaceStore = WorkspaceStore(state: .stageOneDefault)
    workspaceStore.updateDocument { document in
        document.canvasSize = canvasSize
    }
    let bootstrap = try AppBootstrap(
        workspaceStore: workspaceStore,
        metalContext: metalContext,
        layerSurfaceStore: StageOneLayerSurfaceStore()
    )
    let viewModel = WorkspaceViewModel(bootstrap: bootstrap, installsZoomKeyboardMonitor: false)
    if layerCount > 1 {
        for _ in 1..<layerCount {
            viewModel.addLayer()
        }
    }
    return (bootstrap: bootstrap, viewModel: viewModel)
}

@MainActor
private func applySelectionFill(
    on viewModel: WorkspaceViewModel,
    rect: (minX: Double, minY: Double, maxX: Double, maxY: Double)
) {
    viewModel.selectTool(.lassoSelection)
    let points: [CanvasPoint] = [
        .init(x: rect.minX, y: rect.minY),
        .init(x: rect.maxX, y: rect.minY),
        .init(x: rect.maxX, y: rect.maxY),
        .init(x: rect.minX, y: rect.maxY),
        .init(x: rect.minX, y: rect.minY)
    ]
    guard let first = points.first else { return }
    viewModel.beginSelection(kind: .lasso, at: first)
    for point in points.dropFirst().dropLast() {
        viewModel.updateSelection(to: point)
    }
    viewModel.commitSelection(at: points.last ?? first)
    viewModel.fillSelectionContents()
}

@MainActor
private func recordBrushStroke(
    with harness: (
        workspaceStore: WorkspaceStore,
        metalContext: MetalDeviceContext,
        layerSurfaceStore: StageOneLayerSurfaceStore,
        serializer: LayerTextureSerializer,
        history: HistoryController,
        engine: MetalStrokeEngine
    ),
    tool: ToolKind = .brush,
    layerID: LayerID,
    captureMode: HistoryCaptureMode,
    pointSeed: Int
) throws {
    harness.engine.beginStrokeIfNeeded(
        toolSession: .stageOneDefault,
        layerID: layerID
    )
    let x0 = Double(40 + pointSeed * 24)
    let y0 = Double(48 + pointSeed * 18)
    _ = harness.engine.applyStroke(
        StrokeDescriptor(
            tool: tool,
            color: .black,
            brush: .stageOneDefault,
            points: [
                .init(x: x0, y: y0, pressure: 1),
                .init(x: x0 + 12, y: y0 + 8, pressure: 1)
            ],
            selectionShape: nil,
            skipLeadingStamp: false
        ),
        to: layerID
    )
    harness.engine.endStroke()
    try flushPendingStrokePackets(
        engine: harness.engine,
        metalContext: harness.metalContext
    )
    try harness.engine.drainPendingBrushCommitJobs { job in
        try harness.history.captureCheckpoint(
            captureMode: resolvedBrushCaptureMode(captureMode, layerID: job.layerID)
        )
    }
}

private func resolvedBrushCaptureMode(
    _ captureMode: HistoryCaptureMode,
    layerID: LayerID
) -> HistoryCaptureMode {
    switch captureMode {
    case .full:
        return .full
    case .inPlaceChangedLayers:
        return .inPlaceChangedLayers([layerID])
    case .workspaceOnly:
        return .workspaceOnly
    case .metadataOnly:
        return .metadataOnly
    }
}

private func retainedHistoryPointsForBudget(
    entryBytes: Int,
    maxEntries: Int = 8,
    maxResidentBytes: Int = 512 * 1024 * 1024
) -> Int {
    guard entryBytes > 0 else { return 0 }
    if entryBytes > maxResidentBytes {
        return 1
    }
    return min(maxEntries, max(1, maxResidentBytes / entryBytes))
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
private func measureSmudgeMetrics(
    canvasSize: CanvasSize
) throws -> (
    peakBytes: UInt64,
    smudgeGatherPassMs: Double,
    strokeWallMs: Double,
    commandBufferCompletionMs: Double
) {
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

    var strokeDurationsMs: [Double] = []
    var commandBufferCompletionDurationsMs: [Double] = []

    for strokeIndex in 0..<10 {
        let strokeStartNs = DispatchTime.now().uptimeNanoseconds
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
            try flushPendingStrokePackets(
                engine: engine,
                metalContext: metalContext,
                completionDurationsMs: &commandBufferCompletionDurationsMs
            )
            peakBytes = max(peakBytes, currentPhysFootprintBytes())
        }
        engine.endStroke()
        try flushPendingStrokePackets(
            engine: engine,
            metalContext: metalContext,
            completionDurationsMs: &commandBufferCompletionDurationsMs
        )
        peakBytes = max(peakBytes, currentPhysFootprintBytes())
        try engine.drainPendingBrushCommitJobs { _ in }
        peakBytes = max(peakBytes, currentPhysFootprintBytes())
        let strokeDurationMs = Double(DispatchTime.now().uptimeNanoseconds - strokeStartNs) / 1_000_000
        strokeDurationsMs.append(strokeDurationMs)
    }

    let audit = PerformanceAuditStore.shared.snapshot()
    return (
        peakBytes: peakBytes,
        smudgeGatherPassMs: audit.averageDuration("StageOneBrushRenderer.smudgeGatherPass") ?? 0,
        strokeWallMs: average(strokeDurationsMs),
        commandBufferCompletionMs: average(commandBufferCompletionDurationsMs)
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

@MainActor
private func createCommittedLassoSelection(
    on viewModel: WorkspaceViewModel,
    points: [CanvasPoint]
) {
    guard let first = points.first, points.count > 1 else { return }
    viewModel.beginSelection(kind: .lasso, at: first)
    for point in points.dropFirst().dropLast() {
        viewModel.updateSelection(to: point)
    }
    viewModel.commitSelection(at: points.last ?? first)
}

private func flushPendingStrokePackets(
    engine: MetalStrokeEngine,
    metalContext: MetalDeviceContext
) throws {
    var ignoredDurations: [Double] = []
    try flushPendingStrokePackets(
        engine: engine,
        metalContext: metalContext,
        completionDurationsMs: &ignoredDurations
    )
}

private func flushPendingStrokePackets(
    engine: MetalStrokeEngine,
    metalContext: MetalDeviceContext,
    completionDurationsMs: inout [Double]
) throws {
    guard let commandBuffer = metalContext.commandQueue.makeCommandBuffer() else {
        throw AuditHarnessError.commandBufferUnavailable
    }

    _ = engine.flushPendingStrokePackets(into: commandBuffer)
    let commitStartNs = DispatchTime.now().uptimeNanoseconds
    let completionDurationBox = CompletionDurationBox()
    commandBuffer.addCompletedHandler { _ in
        completionDurationBox.value = Double(DispatchTime.now().uptimeNanoseconds - commitStartNs) / 1_000_000
    }
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    completionDurationsMs.append(completionDurationBox.value)
}

private func average(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    return values.reduce(0, +) / Double(values.count)
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

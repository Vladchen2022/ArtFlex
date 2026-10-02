import AppKit
import Darwin
import Foundation
import Metal
import Testing
@testable import ArtFlex

/// Bounded opt-in workload; run alone with Release optimization and DEBUG test hooks.
@MainActor
struct InteractiveWorkloadPerformanceTests {
    @Test func drawingSelectionHistoryAndSaveSamples() async throws {
        guard ProcessInfo.processInfo.environment["ARTFLEX_RUN_WORKLOAD_BENCHMARK"] == "1" else { return }
        _ = NSApplication.shared
        let metal = try #require(MetalDeviceContext())
        let audit = PerformanceAuditStore.shared
        let wasRecording = audit.isRecordingEnabled
        audit.setRecordingEnabled(true)
        defer { audit.setRecordingEnabled(wasRecording) }
        for side in [2048, 4096] {
            for standard in [ArtColorStandard.stageOneDefault, .highPrecision] {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArtFlex-Workload-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let store = WorkspaceStore()
                store.updateDocument { document in
                    document.canvasSize = .init(width: side, height: side)
                    document.colorStandard = standard
                    while document.paintLayers.count < 4 { _ = document.addLayer() }
                    let index = document.layers.firstIndex { $0.id == document.activeLayerID }!
                    document.layers[index].mask = .init(isEnabled: true)
                }
                store.updateToolSession { session in
                    session.brush = .stageOneDefault
                    session.brush.size = 32
                    session.selectedColor = .init(red: 0.7, green: 0.2, blue: 0.1, alpha: 1)
                }
                let surfaces = StageOneLayerSurfaceStore(usesSparseStorage: true)
                let bootstrap = try AppBootstrap(workspaceStore: store, metalContext: metal, layerSurfaceStore: surfaces,
                    persistenceRecoveryRootURL: root.appendingPathComponent("Recovery"))
                let viewModel = WorkspaceViewModel(bootstrap: bootstrap, installsZoomKeyboardMonitor: false)
                bootstrap.filePanelService.selectURLsForTesting = { _, finish in finish([root.appendingPathComponent("workload.artflex")]) }
                func flush() throws {
                    let command = try #require(metal.commandQueue.makeCommandBuffer())
                    _ = viewModel.flushPendingBrushWork(into: command)
                    command.commit(); command.waitUntilCompleted()
                    #expect(command.status == .completed)
                }
                func ms(_ start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
                for sample in 0..<6 {
                    audit.reset()
                    viewModel.selectTool(.brush)
                    let beforeGPU = metal.device.currentAllocatedSize
                    let start = DispatchTime.now().uptimeNanoseconds
                    viewModel.beginStrokeIfNeeded()
                    for packet in 0..<8 {
                        viewModel.applyStroke(samples: (0..<3).map { point in
                            .init(location: .init(x: Double(80 + packet * 12 + point * 4),
                                y: Double(80 + sample * 20 + point * 2)), pressure: 0.75)
                        })
                        try flush()
                    }
                    let strokeMs = ms(start)
                    let liveGPU = metal.device.currentAllocatedSize
                    let commitStart = DispatchTime.now().uptimeNanoseconds
                    viewModel.endStroke()
                    _ = viewModel.flushBrushEditingBoundary(reason: "workload.measure")
                    try flush()
                    let commitMs = ms(commitStart)
                    let undoStart = DispatchTime.now().uptimeNanoseconds
                    viewModel.undo()
                    let undoMs = ms(undoStart)
                    let redoStart = DispatchTime.now().uptimeNanoseconds
                    viewModel.redo()
                    let redoMs = ms(redoStart)
                    viewModel.selectTool(.rectangleSelection)
                    viewModel.debugSetCommittedSelectionShapeForTests(.init(kind: .rectangle,
                        bounds: .init(origin: .init(x: Double(side / 2), y: Double(side / 2)), size: .init(x: 64, y: 64)), pathPoints: []))
                    viewModel.fillSelectionContents()
                    let fillAudit = audit.snapshot()
                    var saved: Bool?
                    let saveStart = DispatchTime.now().uptimeNanoseconds
                    #expect(viewModel.saveProject { saved = $0 })
                    for _ in 0..<3000 {
                        if saved != nil { break }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    #expect(saved == true)
                    let saveMs = ms(saveStart)
                    let measured = audit.snapshot()
                    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
                    let row: [String: Any] = ["side": side, "format": standard.pixelFormat.encoding.metalPixelFormat.rawValue,
                        "sample": sample, "stroke_ms": strokeMs, "commit_ms": commitMs, "undo_ms": undoMs, "redo_ms": redoMs,
                        "selection_ms": fillAudit.latestDuration("WorkspaceViewModel.applyPixelOperation.total") ?? -1,
                        "selection_copy_ms": fillAudit.latestDuration("WorkspaceViewModel.applyPixelOperation.stagingCopy") ?? -1,
                        "selection_staging_bytes": fillAudit.latestInt("WorkspaceViewModel.applyPixelOperation.stagingBytes") ?? -1,
                        "save_ms": saveMs, "save_prepare_ms": measured.latestDuration("ProjectSave.prepareOnMain") ?? -1,
                        "save_readback_ms": measured.latestDuration("ProjectSave.materialize") ?? -1,
                        "save_write_ms": measured.latestDuration("ProjectSave.write") ?? -1,
                        "gpu_before_stroke": beforeGPU, "gpu_live_stroke": liveGPU,
                        "gpu_after_save": metal.device.currentAllocatedSize,
                        "layer_allocated_bytes": surfaces.allocatedPixelBytes,
                        "history_resident_bytes": bootstrap.historyController.residentByteCount,
                        "rss_peak_bytes": usage.ru_maxrss]
                    let data = try JSONSerialization.data(withJSONObject: row, options: .sortedKeys)
                    print("WORKLOAD_BENCH \(String(decoding: data, as: UTF8.self))")
                }
                let reopened = try bootstrap.persistenceController.openProject(from: root.appendingPathComponent("workload.artflex"))
                #expect(reopened.workspace.document.paintLayers.count == 4)
                #expect(reopened.workspace.document.colorStandard == standard)
            }
        }
    }
}

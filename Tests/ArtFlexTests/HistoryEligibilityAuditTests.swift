import Metal
import Testing
@testable import ArtFlex

struct HistoryEligibilityAuditTests {
    @Test
    @MainActor
    func workspaceOperationsEmitHistoryEligibilityAuditSummary() throws {
        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal unavailable")
            return
        }

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
                .init(location: .init(x: 12, y: 12), pressure: 1),
                .init(location: .init(x: 24, y: 20), pressure: 1)
            ]
        )
        viewModel.endStroke()
        try flushPendingBrushWork(viewModel: viewModel, metalContext: metalContext)
        viewModel.opportunisticallyDrainBrushCommits(hadLiveBrushWorkThisFrame: false)

        viewModel.selectTool(.eraser)
        viewModel.beginStrokeIfNeeded()
        viewModel.applyStroke(
            samples: [
                .init(location: .init(x: 14, y: 14), pressure: 1),
                .init(location: .init(x: 26, y: 22), pressure: 1)
            ]
        )
        viewModel.endStroke()
        try flushPendingBrushWork(viewModel: viewModel, metalContext: metalContext)
        viewModel.opportunisticallyDrainBrushCommits(hadLiveBrushWorkThisFrame: false)

        viewModel.selectTool(.smudge)
        viewModel.beginStrokeIfNeeded()
        viewModel.applyStroke(
            samples: [
                .init(location: .init(x: 16, y: 16), pressure: 1),
                .init(location: .init(x: 28, y: 24), pressure: 1)
            ]
        )
        viewModel.endStroke()
        try flushPendingBrushWork(viewModel: viewModel, metalContext: metalContext)
        viewModel.opportunisticallyDrainBrushCommits(hadLiveBrushWorkThisFrame: false)

        viewModel.selectTool(.brush)
        viewModel.beginStrokeIfNeeded()
        viewModel.applyStroke(
            samples: [
                .init(location: .init(x: 30, y: 18), pressure: 1),
                .init(location: .init(x: 42, y: 26), pressure: 1)
            ]
        )
        viewModel.endStroke()
        try flushPendingBrushWork(viewModel: viewModel, metalContext: metalContext)
        viewModel.opportunisticallyDrainBrushCommits(hadLiveBrushWorkThisFrame: false)

        viewModel.setSelectedColor(.init(red: 0.9, green: 0.12, blue: 0.04, alpha: 1))
        viewModel.fillAtPoint(.init(x: 18, y: 18))

        viewModel.selectTool(.lassoSelection)
        createCommittedLassoSelection(
            on: viewModel,
            points: [
                .init(x: 8, y: 8),
                .init(x: 40, y: 8),
                .init(x: 40, y: 40),
                .init(x: 8, y: 40),
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

        let snapshot = PerformanceAuditStore.shared.snapshot()
        let summaryRows = snapshot.historyEligibilitySummaryRows()
        let operationKinds = Set(summaryRows.map(\.operationKind))

        #expect(operationKinds.contains("brush.commit"))
        #expect(operationKinds.contains("eraser.commit"))
        #expect(operationKinds.contains("smudge.commit"))
        #expect(operationKinds.contains("fillAtPoint"))
        #expect(operationKinds.contains("applyPixelOperation"))
        #expect(operationKinds.contains("selection.fill"))
        #expect(operationKinds.contains("lasso.fill"))
        #expect(operationKinds.contains("lasso.erase"))
        #expect(operationKinds.contains("undo.currentEntryCapture"))
        #expect(operationKinds.contains("redo.currentEntryCapture"))

        let brushWarmupRow = try #require(summaryRows.first {
            $0.operationKind == "brush.commit" && $0.warmupOrSteadyState == .warmup
        })
        #expect(brushWarmupRow.count >= 1)
        #expect(brushWarmupRow.ineligibleReasonCounts[.noComparisonWorkspace] == 1)

        let brushSteadyRow = try #require(summaryRows.first {
            $0.operationKind == "brush.commit" && $0.warmupOrSteadyState == .steadyState
        })
        #expect(brushSteadyRow.eligibleCount >= 1)
        #expect(brushSteadyRow.savedBytes > 0)
        #expect(brushSteadyRow.savedLayers > 0)

        let pixelOpRow = try #require(summaryRows.first(where: { $0.operationKind == "applyPixelOperation" }))
        #expect(pixelOpRow.eligibleCount >= 1)
    }
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

@MainActor
private func flushPendingBrushWork(
    viewModel: WorkspaceViewModel,
    metalContext: MetalDeviceContext
) throws {
    guard let commandBuffer = metalContext.commandQueue.makeCommandBuffer() else {
        Issue.record("Command buffer unavailable")
        return
    }
    _ = viewModel.flushPendingBrushWork(into: commandBuffer)
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
}

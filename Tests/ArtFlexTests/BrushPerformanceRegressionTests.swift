import Metal
import Testing
@testable import ArtFlex

struct BrushPerformanceRegressionTests {
    @Test
    @MainActor
    func completedBrushStrokeDoesNotRescanUnchangedTimelapseDocumentContext() throws {
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
        let initialSyncCount = viewModel.debugTimelapseDocumentContextSyncCount

        viewModel.beginStrokeIfNeeded()
        viewModel.applyStroke(samples: [
            .init(location: .init(x: 32, y: 32), pressure: 1),
            .init(location: .init(x: 48, y: 48), pressure: 1)
        ])
        viewModel.endStroke()

        #expect(initialSyncCount == 1)
        #expect(viewModel.debugTimelapseDocumentContextSyncCount == initialSyncCount)
    }
}

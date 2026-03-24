import Testing
@testable import ArtFlex

@MainActor
struct GradientInteractionStateTests {
    @Test
    func linearGradientLatchMovesFromLeg1ToLeg2() {
        let viewModel = WorkspaceViewModel(bootstrap: AppBootstrap(), installsZoomKeyboardMonitor: false)
        viewModel.selectTool(.linearGradient)

        viewModel.beginGradientDrag(at: .init(x: 100, y: 100))
        viewModel.updateGradientDrag(to: .init(x: 180, y: 100))
        viewModel.updateGradientDrag(to: .init(x: 180, y: 160))

        #expect(viewModel.linearGradientState.phase == .drawingLeg2)
        #expect(viewModel.linearGradientState.pointB == .init(x: 180, y: 100))
        #expect(viewModel.linearGradientState.pointC == .init(x: 180, y: 160))
    }

    @Test
    func linearGradientReleaseWithoutLatchFallsBackToEditing() {
        let viewModel = WorkspaceViewModel(bootstrap: AppBootstrap(), installsZoomKeyboardMonitor: false)
        viewModel.selectTool(.linearGradient)

        viewModel.beginGradientDrag(at: .init(x: 50, y: 50))
        viewModel.updateGradientDrag(to: .init(x: 140, y: 50))
        viewModel.endGradientDrag(at: .init(x: 140, y: 50))

        #expect(viewModel.linearGradientState.phase == .editing)
        #expect(viewModel.linearGradientState.geometry != nil)
    }

    @Test
    func sectorGradientLatchMovesFromLeg1ToLeg2() {
        let viewModel = WorkspaceViewModel(bootstrap: AppBootstrap(), installsZoomKeyboardMonitor: false)
        viewModel.selectTool(.sectorGradient)

        viewModel.beginGradientDrag(at: .init(x: 200, y: 200))
        viewModel.updateGradientDrag(to: .init(x: 260, y: 200))
        viewModel.updateGradientDrag(to: .init(x: 250, y: 255))

        #expect(viewModel.sectorGradientState.phase == .drawingLeg2)
        #expect(viewModel.sectorGradientState.startPoint == .init(x: 260, y: 200))
        #expect(viewModel.sectorGradientState.endPoint == .init(x: 250, y: 255))
    }

    @Test
    func sectorGradientReleaseWithoutLatchFallsBackToEditing() {
        let viewModel = WorkspaceViewModel(bootstrap: AppBootstrap(), installsZoomKeyboardMonitor: false)
        viewModel.selectTool(.sectorGradient)

        viewModel.beginGradientDrag(at: .init(x: 200, y: 200))
        viewModel.updateGradientDrag(to: .init(x: 260, y: 200))
        viewModel.endGradientDrag(at: .init(x: 260, y: 200))

        #expect(viewModel.sectorGradientState.phase == .editing)
        #expect(viewModel.sectorGradientState.geometry != nil)
        #expect(abs((viewModel.sectorGradientState.geometry?.sweepAngle ?? 0)) > 0.1)
    }
}

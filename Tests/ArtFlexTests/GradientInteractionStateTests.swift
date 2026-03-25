import Testing
@testable import ArtFlex

@MainActor
struct GradientInteractionStateTests {
    @Test
    func linearGradientLatchMovesFromLeg1ToLeg2() throws {
        let viewModel = WorkspaceViewModel(bootstrap: try AppBootstrap(), installsZoomKeyboardMonitor: false)
        viewModel.selectTool(.linearGradient)

        viewModel.beginGradientDrag(at: .init(x: 100, y: 100))
        viewModel.updateGradientDrag(to: .init(x: 180, y: 100))
        viewModel.updateGradientDrag(to: .init(x: 180, y: 160))

        #expect(viewModel.linearGradientState.phase == .drawingLeg2)
        #expect(viewModel.linearGradientState.pointB == .init(x: 180, y: 100))
        #expect(viewModel.linearGradientState.pointC == .init(x: 180, y: 160))
    }

    @Test
    func linearGradientReleaseWithoutLatchFallsBackToEditing() throws {
        let viewModel = WorkspaceViewModel(bootstrap: try AppBootstrap(), installsZoomKeyboardMonitor: false)
        viewModel.selectTool(.linearGradient)

        viewModel.beginGradientDrag(at: .init(x: 50, y: 50))
        viewModel.updateGradientDrag(to: .init(x: 140, y: 50))
        viewModel.endGradientDrag(at: .init(x: 140, y: 50))

        #expect(viewModel.linearGradientState.phase == .pendingPreview)
        #expect(viewModel.linearGradientState.geometry != nil)
    }

    @Test
    func sectorGradientLatchMovesFromLeg1ToLeg2() throws {
        let viewModel = WorkspaceViewModel(bootstrap: try AppBootstrap(), installsZoomKeyboardMonitor: false)
        viewModel.selectTool(.sectorGradient)

        viewModel.beginGradientDrag(at: .init(x: 200, y: 200))
        viewModel.updateGradientDrag(to: .init(x: 260, y: 200))
        viewModel.updateGradientDrag(to: .init(x: 250, y: 255))

        #expect(viewModel.sectorGradientState.phase == .drawingLeg2)
        #expect(viewModel.sectorGradientState.startPoint == .init(x: 260, y: 200))
        #expect(viewModel.sectorGradientState.endPoint == .init(x: 250, y: 255))
    }

    @Test
    func sectorGradientReleaseWithoutLatchFallsBackToEditing() throws {
        let viewModel = WorkspaceViewModel(bootstrap: try AppBootstrap(), installsZoomKeyboardMonitor: false)
        viewModel.selectTool(.sectorGradient)

        viewModel.beginGradientDrag(at: .init(x: 200, y: 200))
        viewModel.updateGradientDrag(to: .init(x: 260, y: 200))
        viewModel.endGradientDrag(at: .init(x: 260, y: 200))

        #expect(viewModel.sectorGradientState.phase == .pendingPreview)
        #expect(viewModel.sectorGradientState.geometry != nil)
        #expect(abs((viewModel.sectorGradientState.geometry?.sweepAngle ?? 0)) > 0.1)
    }

    @Test
    func shiftPromotesPendingPreviewToEditing() throws {
        let viewModel = WorkspaceViewModel(bootstrap: try AppBootstrap(), installsZoomKeyboardMonitor: false)
        viewModel.selectTool(.linearGradient)

        viewModel.beginGradientDrag(at: .init(x: 50, y: 50))
        viewModel.updateGradientDrag(to: .init(x: 140, y: 50))
        viewModel.endGradientDrag(at: .init(x: 140, y: 50))
        #expect(viewModel.linearGradientState.phase == .pendingPreview)
        #expect(shouldShowGradientAnnotator(phase: viewModel.linearGradientState.phase) == false)

        viewModel.enterGradientEditingViaShift()

        #expect(viewModel.linearGradientState.phase == .editing)
        #expect(shouldShowGradientAnnotator(phase: viewModel.linearGradientState.phase) == true)
    }

    @Test
    func toolSwitchAutoAppliesPendingPreview() async throws {
        let viewModel = WorkspaceViewModel(bootstrap: try AppBootstrap(), installsZoomKeyboardMonitor: false)
        viewModel.selectTool(.linearGradient)

        viewModel.beginGradientDrag(at: .init(x: 40, y: 40))
        viewModel.updateGradientDrag(to: .init(x: 120, y: 40))
        viewModel.endGradientDrag(at: .init(x: 120, y: 40))
        #expect(viewModel.linearGradientState.phase == .pendingPreview)

        viewModel.selectTool(.brush)
        #expect(viewModel.isApplyingGradientCommit == true)

        for _ in 0..<100 {
            if viewModel.workspace.toolSession.activeTool == .brush,
               viewModel.linearGradientState.phase == .idle,
               viewModel.isApplyingGradientCommit == false {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(viewModel.workspace.toolSession.activeTool == .brush)
        #expect(viewModel.linearGradientState.phase == .idle)
        #expect(viewModel.isApplyingGradientCommit == false)
    }

    @Test
    func startingNextGradientAutoAppliesAndReplaysDeferredBegin() async throws {
        let viewModel = WorkspaceViewModel(bootstrap: try AppBootstrap(), installsZoomKeyboardMonitor: false)
        viewModel.selectTool(.linearGradient)

        viewModel.beginGradientDrag(at: .init(x: 40, y: 40))
        viewModel.updateGradientDrag(to: .init(x: 120, y: 40))
        viewModel.endGradientDrag(at: .init(x: 120, y: 40))
        #expect(viewModel.linearGradientState.phase == .pendingPreview)

        let nextStart = CanvasPoint(x: 200, y: 220)
        viewModel.beginGradientDrag(at: nextStart)
        #expect(viewModel.isApplyingGradientCommit == true)

        for _ in 0..<100 {
            if viewModel.linearGradientState.phase == .drawingLeg1,
               viewModel.linearGradientState.pointA == nextStart {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(viewModel.linearGradientState.phase == .drawingLeg1)
        #expect(viewModel.linearGradientState.pointA == nextStart)
    }
}

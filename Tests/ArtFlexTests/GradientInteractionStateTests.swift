import Testing
@testable import ArtFlex

@MainActor
struct GradientInteractionStateTests {
    @Test
    func linearGradientReleaseRetainsEditableControls() throws {
        let viewModel = WorkspaceViewModel(
            bootstrap: try AppBootstrap(),
            installsZoomKeyboardMonitor: false
        )
        viewModel.selectTool(.linearGradient)

        viewModel.beginGradientDrag(at: .init(x: 40, y: 50))
        viewModel.updateGradientDrag(to: .init(x: 140, y: 50))
        viewModel.endGradientDrag(at: .init(x: 140, y: 50))

        let geometry = try #require(viewModel.linearGradientState.geometry)
        #expect(viewModel.linearGradientState.phase == .editing)
        #expect(geometry.pointA == .init(x: 40, y: 50))
        #expect(geometry.pointB == .init(x: 140, y: 50))
        #expect(geometry.transitionMidpoint == 0.5)
        #expect(geometry.transitionMidpointPoint == .init(x: 90, y: 50))
        #expect(shouldShowGradientAnnotator(phase: viewModel.linearGradientState.phase))
    }

    @Test
    func linearGradientHandlesAdjustEndpointsMidpointAndWholePosition() throws {
        let viewModel = WorkspaceViewModel(
            bootstrap: try AppBootstrap(),
            installsZoomKeyboardMonitor: false
        )
        viewModel.selectTool(.linearGradient)
        viewModel.beginGradientDrag(at: .init(x: 40, y: 50))
        viewModel.updateGradientDrag(to: .init(x: 140, y: 50))
        viewModel.endGradientDrag(at: .init(x: 140, y: 50))

        viewModel.beginGradientDrag(at: .init(x: 40, y: 50))
        viewModel.updateGradientDrag(to: .init(x: 30, y: 60))
        viewModel.endGradientDrag(at: .init(x: 30, y: 60))
        #expect(viewModel.linearGradientState.pointA == .init(x: 30, y: 60))
        #expect(viewModel.linearGradientState.pointB == .init(x: 140, y: 50))

        let midpointBeforeAdjustment = try #require(
            viewModel.linearGradientState.geometry?.transitionMidpointPoint
        )
        viewModel.beginGradientDrag(at: midpointBeforeAdjustment)
        viewModel.updateGradientDrag(to: .init(x: 57.5, y: 57.5))
        viewModel.endGradientDrag(at: .init(x: 57.5, y: 57.5))
        #expect(abs(viewModel.linearGradientState.transitionMidpoint - 0.25) < 0.0001)

        let lineBodyPoint = CanvasPoint(x: 112.5, y: 52.5)
        viewModel.beginGradientDrag(at: lineBodyPoint, handleHitRadius: 6)
        viewModel.updateGradientDrag(to: .init(x: 122.5, y: 72.5))
        viewModel.endGradientDrag(at: .init(x: 122.5, y: 72.5))

        #expect(viewModel.linearGradientState.phase == .editing)
        #expect(viewModel.linearGradientState.pointA == .init(x: 40, y: 80))
        #expect(viewModel.linearGradientState.pointB == .init(x: 150, y: 70))
        #expect(abs(viewModel.linearGradientState.transitionMidpoint - 0.25) < 0.0001)
    }

    @Test
    func linearGradientControlHitRadiusStaysConstantAcrossZoomLevels() {
        #expect(gradientHandleHitRadiusCanvasDistance(actualDisplayScale: 0.5) == 28)
        #expect(gradientHandleHitRadiusCanvasDistance(actualDisplayScale: 2) == 7)
    }

    @Test
    func bucketSidebarGroupExposesLinearAndSectorGradient() throws {
        let bucketGroup = try #require(ToolSidebarGroup.group(forShortcutKey: "G"))
        #expect(bucketGroup.tools == [.bucket, .linearGradient, .sectorGradient])
    }

    @Test
    func selectingSectorGradientKeepsGradientToolsAvailable() throws {
        let viewModel = WorkspaceViewModel(bootstrap: try AppBootstrap(), installsZoomKeyboardMonitor: false)
        viewModel.selectTool(.linearGradient)
        #expect(viewModel.workspace.toolSession.activeTool == .linearGradient)

        viewModel.selectTool(.sectorGradient)
        #expect(viewModel.workspace.toolSession.activeTool == .sectorGradient)
    }

    @Test
    func persistedSectorGradientRemainsAvailable() throws {
        let bootstrap = try AppBootstrap()
        bootstrap.workspaceStore.updateToolSession { session in
            session.activeTool = .sectorGradient
        }

        let viewModel = WorkspaceViewModel(bootstrap: bootstrap, installsZoomKeyboardMonitor: false)
        #expect(viewModel.workspace.toolSession.activeTool == .sectorGradient)
    }

    @Test
    func sectorGradientPreviewResolvesClosedLassoRegion() throws {
        let center = CanvasPoint(x: 12, y: 20)
        let preview = SectorGradientPreview(
            center: center,
            pathPoints: [
                center,
                .init(x: 28, y: 8),
                .init(x: 44, y: 20),
                .init(x: 28, y: 38)
            ],
            hoverPoint: .init(x: 14, y: 22)
        )

        let geometry = try #require(resolvedSectorGradientPreviewGeometry(preview: preview))
        #expect(geometry.center == center)
        #expect(geometry.pathPoints.first == center)
        #expect(geometry.pathPoints.last == center)
        #expect(geometry.maxRadius > 10)
        #expect(geometry.bounds.contains(.init(x: 28, y: 20)))
        #expect(geometry.pathPoints.count > preview.pathPoints.count * 2)
    }

    @Test
    func sectorGradientTriangleFanUsesCenterAndBoundarySegments() {
        let center = CanvasPoint(x: 10, y: 10)
        let pathPoints: [CanvasPoint] = [
            center,
            .init(x: 20, y: 8),
            .init(x: 28, y: 16),
            .init(x: 18, y: 24),
            center
        ]

        let vertices = sectorGradientTriangleFanVertexPositions(
            center: center,
            pathPoints: pathPoints
        )

        #expect(vertices.count == 6)
        #expect(vertices[0] == center)
        #expect(vertices[1] == .init(x: 20, y: 8))
        #expect(vertices[2] == .init(x: 28, y: 16))
        #expect(vertices[3] == center)
        #expect(vertices[4] == .init(x: 28, y: 16))
        #expect(vertices[5] == .init(x: 18, y: 24))
    }
}

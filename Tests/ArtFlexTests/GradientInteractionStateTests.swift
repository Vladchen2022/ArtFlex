import Testing
@testable import ArtFlex

@MainActor
struct GradientInteractionStateTests {
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

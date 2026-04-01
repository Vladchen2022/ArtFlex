import Testing
@testable import ArtFlex

@MainActor
struct GradientInteractionStateTests {
    @Test
    func bucketSidebarGroupNoLongerExposesGradientTools() throws {
        let bucketGroup = try #require(ToolSidebarGroup.group(forShortcutKey: "G"))
        #expect(bucketGroup.tools == [.bucket])
    }

    @Test
    func selectingDisabledGradientToolsFallsBackToBucket() throws {
        let viewModel = WorkspaceViewModel(bootstrap: try AppBootstrap(), installsZoomKeyboardMonitor: false)
        viewModel.selectTool(.linearGradient)
        #expect(viewModel.workspace.toolSession.activeTool == .bucket)

        viewModel.selectTool(.sectorGradient)
        #expect(viewModel.workspace.toolSession.activeTool == .bucket)
    }

    @Test
    func persistedDisabledGradientToolNormalizesToBucket() throws {
        let bootstrap = try AppBootstrap()
        bootstrap.workspaceStore.updateToolSession { session in
            session.activeTool = .sectorGradient
        }

        let viewModel = WorkspaceViewModel(bootstrap: bootstrap, installsZoomKeyboardMonitor: false)
        #expect(viewModel.workspace.toolSession.activeTool == .bucket)
    }
}

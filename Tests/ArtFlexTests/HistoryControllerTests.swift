import Testing
@testable import ArtFlex

struct HistoryControllerTests {
    @Test
    func historyNavigationPreservesTransientToolSettings() {
        var restored = WorkspaceState.stageOneDefault
        var current = WorkspaceState.stageOneDefault

        restored.selection = .empty
        current.toolSession.brush.buildMode = .opacityCap
        current.toolSession.brush.pressureOpacityAmount = 0.42
        current.viewport.zoomScale = 2.5

        let merged = HistoryController.mergedWorkspaceForHistoryNavigation(
            restored: restored,
            current: current
        )

        #expect(merged.document == restored.document)
        #expect(merged.selection == restored.selection)
        #expect(merged.toolSession == current.toolSession)
        #expect(merged.viewport == current.viewport)
    }
}

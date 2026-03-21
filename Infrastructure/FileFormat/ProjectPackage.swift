import Foundation

struct ProjectPackage: Codable, Sendable, Equatable {
    var document: ArtDocument
    var toolSession: ToolSessionState
    var colorPanel: ColorPanelState
    var brushLibrary: BrushLibraryState
    var generator: GeneratorSettings
    var viewport: CanvasViewport
    var selection: SelectionState
    var layerSnapshots: [LayerHistorySnapshot]

    static func fromWorkspace(
        _ state: WorkspaceState,
        layerSnapshots: [LayerHistorySnapshot]
    ) -> ProjectPackage {
        ProjectPackage(
            document: state.document,
            toolSession: state.toolSession,
            colorPanel: state.colorPanel,
            brushLibrary: state.brushLibrary,
            generator: state.generator,
            viewport: state.viewport,
            selection: state.selection,
            layerSnapshots: layerSnapshots
        )
    }

    var workspaceState: WorkspaceState {
        WorkspaceState(
            document: document,
            toolSession: toolSession,
            colorPanel: colorPanel,
            brushLibrary: brushLibrary,
            generator: generator,
            viewport: viewport,
            selection: selection
        )
    }
}

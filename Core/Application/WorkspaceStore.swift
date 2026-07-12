import Foundation

struct WorkspaceState: Codable, Sendable, Equatable {
    var document: ArtDocument
    var toolSession: ToolSessionState
    var colorPanel: ColorPanelState
    var brushLibrary: BrushLibraryState
    var patternLibrary: PatternLibraryState
    var tipImageLibrary: TipImageLibraryState
    var generator: GeneratorSettings
    var viewport: CanvasViewport
    var selection: SelectionState

    init(
        document: ArtDocument,
        toolSession: ToolSessionState,
        colorPanel: ColorPanelState,
        brushLibrary: BrushLibraryState,
        patternLibrary: PatternLibraryState = .init(),
        tipImageLibrary: TipImageLibraryState = .empty,
        generator: GeneratorSettings,
        viewport: CanvasViewport,
        selection: SelectionState
    ) {
        self.document = document
        self.toolSession = toolSession
        self.colorPanel = colorPanel
        self.brushLibrary = brushLibrary
        self.patternLibrary = patternLibrary
        self.tipImageLibrary = tipImageLibrary
        self.generator = generator
        self.viewport = viewport
        self.selection = selection
    }

    static let stageOneDefault = WorkspaceState(
        document: .stageOneDefault(),
        toolSession: .stageOneDefault,
        colorPanel: .stageOneDefault,
        brushLibrary: .stageOneDefault,
        patternLibrary: .init(),
        tipImageLibrary: .empty,
        generator: .stageOneDefault,
        viewport: .stageOneDefault,
        selection: .empty
    )
}

final class WorkspaceStore {
    private(set) var state: WorkspaceState

    init(state: WorkspaceState = .stageOneDefault) {
        self.state = state
    }

    func updateDocument(_ transform: (inout ArtDocument) -> Void) {
        transform(&state.document)
        state.document.metadata.updatedAt = Date()
    }

    func updateToolSession(_ transform: (inout ToolSessionState) -> Void) {
        transform(&state.toolSession)
    }

    func updateColorPanel(_ transform: (inout ColorPanelState) -> Void) {
        transform(&state.colorPanel)
    }

    func updateViewport(_ transform: (inout CanvasViewport) -> Void) {
        transform(&state.viewport)
    }

    func updateBrushLibrary(_ transform: (inout BrushLibraryState) -> Void) {
        transform(&state.brushLibrary)
    }

    func updatePatternLibrary(_ transform: (inout PatternLibraryState) -> Void) {
        transform(&state.patternLibrary)
    }

    func updateTipImageLibrary(_ transform: (inout TipImageLibraryState) -> Void) {
        transform(&state.tipImageLibrary)
    }

    func updateGenerator(_ transform: (inout GeneratorSettings) -> Void) {
        transform(&state.generator)
    }

    func updateSelection(_ transform: (inout SelectionState) -> Void) {
        transform(&state.selection)
    }

    func replaceState(_ newState: WorkspaceState) {
        state = newState
    }
}

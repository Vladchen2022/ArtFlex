import Foundation

struct WorkspaceState: Codable, Sendable, Equatable {
    var document: ArtDocument
    var toolSession: ToolSessionState
    var colorPanel: ColorPanelState
    var brushLibrary: BrushLibraryState
    var patternLibrary: PatternLibraryState
    var textureFillLibrary: TextureFillLibraryState
    var blockReferenceModuleLibrary: BlockReferenceModuleLibraryState
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
        textureFillLibrary: TextureFillLibraryState = .init(),
        blockReferenceModuleLibrary: BlockReferenceModuleLibraryState = .empty,
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
        self.textureFillLibrary = textureFillLibrary
        self.blockReferenceModuleLibrary = blockReferenceModuleLibrary
        self.tipImageLibrary = tipImageLibrary
        self.generator = generator
        self.viewport = viewport
        self.selection = selection
    }

    private enum CodingKeys: String, CodingKey {
        case document
        case toolSession
        case colorPanel
        case brushLibrary
        case patternLibrary
        case textureFillLibrary
        case blockReferenceModuleLibrary
        case tipImageLibrary
        case generator
        case viewport
        case selection
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            document: try container.decode(ArtDocument.self, forKey: .document),
            toolSession: try container.decode(ToolSessionState.self, forKey: .toolSession),
            colorPanel: try container.decode(ColorPanelState.self, forKey: .colorPanel),
            brushLibrary: try container.decode(BrushLibraryState.self, forKey: .brushLibrary),
            patternLibrary: try container.decodeIfPresent(PatternLibraryState.self, forKey: .patternLibrary) ?? .init(),
            textureFillLibrary: try container.decodeIfPresent(
                TextureFillLibraryState.self,
                forKey: .textureFillLibrary
            ) ?? .init(),
            blockReferenceModuleLibrary: try container.decodeIfPresent(
                BlockReferenceModuleLibraryState.self,
                forKey: .blockReferenceModuleLibrary
            ) ?? .empty,
            tipImageLibrary: try container.decodeIfPresent(TipImageLibraryState.self, forKey: .tipImageLibrary) ?? .empty,
            generator: try container.decode(GeneratorSettings.self, forKey: .generator),
            viewport: try container.decode(CanvasViewport.self, forKey: .viewport),
            selection: try container.decode(SelectionState.self, forKey: .selection)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(document, forKey: .document)
        try container.encode(toolSession, forKey: .toolSession)
        try container.encode(colorPanel, forKey: .colorPanel)
        try container.encode(brushLibrary, forKey: .brushLibrary)
        try container.encode(patternLibrary, forKey: .patternLibrary)
        try container.encode(textureFillLibrary, forKey: .textureFillLibrary)
        try container.encode(blockReferenceModuleLibrary, forKey: .blockReferenceModuleLibrary)
        try container.encode(tipImageLibrary, forKey: .tipImageLibrary)
        try container.encode(generator, forKey: .generator)
        try container.encode(viewport, forKey: .viewport)
        try container.encode(selection, forKey: .selection)
    }

    static let stageOneDefault = WorkspaceState(
        document: .stageOneDefault(),
        toolSession: .stageOneDefault,
        colorPanel: .stageOneDefault,
        brushLibrary: .stageOneDefault,
        patternLibrary: .init(),
        textureFillLibrary: .init(),
        blockReferenceModuleLibrary: .empty,
        tipImageLibrary: .empty,
        generator: .stageOneDefault,
        viewport: .stageOneDefault,
        selection: .empty
    )
}

final class WorkspaceStore {
    private var localState: WorkspaceState
    var sharedLibraries: SharedLibraryStore?
    var onLibrariesChanged: (() -> Void)?
    var state: WorkspaceState {
        var result = localState
        sharedLibraries?.resources.apply(to: &result)
        return result
    }

    init(state: WorkspaceState = .stageOneDefault) {
        self.localState = state
    }

    func updateDocument(_ transform: (inout ArtDocument) -> Void) {
        transform(&localState.document)
        localState.document.metadata.updatedAt = Date()
    }

    func updateToolSession(_ transform: (inout ToolSessionState) -> Void) {
        transform(&localState.toolSession)
    }

    func updateColorPanel(_ transform: (inout ColorPanelState) -> Void) {
        transform(&localState.colorPanel)
    }

    func updateViewport(_ transform: (inout CanvasViewport) -> Void) {
        transform(&localState.viewport)
    }

    func updateBrushLibrary(_ transform: (inout BrushLibraryState) -> Void) {
        var value = state.brushLibrary; transform(&value)
        localState.brushLibrary = value
        sharedLibraries?.update { $0.brushes = value }
    }

    func updatePatternLibrary(_ transform: (inout PatternLibraryState) -> Void) {
        var value = state.patternLibrary; transform(&value)
        localState.patternLibrary = value
        sharedLibraries?.update { $0.patterns = value }
    }

    func updateTextureFillLibrary(_ transform: (inout TextureFillLibraryState) -> Void) {
        var value = state.textureFillLibrary; transform(&value)
        localState.textureFillLibrary = value
        sharedLibraries?.update { $0.textures = value }
    }

    func updateBlockReferenceModuleLibrary(_ transform: (inout BlockReferenceModuleLibraryState) -> Void) {
        var value = state.blockReferenceModuleLibrary; transform(&value)
        localState.blockReferenceModuleLibrary = value
        sharedLibraries?.update { $0.blocks = value }
    }

    func updateTipImageLibrary(_ transform: (inout TipImageLibraryState) -> Void) {
        var value = state.tipImageLibrary; transform(&value)
        localState.tipImageLibrary = value
        sharedLibraries?.update { $0.tips = value }
    }

    func updateGenerator(_ transform: (inout GeneratorSettings) -> Void) {
        transform(&localState.generator)
    }

    func updateSelection(_ transform: (inout SelectionState) -> Void) {
        transform(&localState.selection)
    }

    func replaceState(_ newState: WorkspaceState) {
        localState = newState
    }
}

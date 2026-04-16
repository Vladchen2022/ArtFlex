import Foundation

struct ProjectPackage: Codable, Sendable, Equatable {
    var document: ArtDocument
    var toolSession: ToolSessionState
    var colorPanel: ColorPanelState
    var brushLibrary: BrushLibraryState
    var patternLibrary: PatternLibraryState
    var tipImageLibrary: TipImageLibraryState
    var generator: GeneratorSettings
    var creativeShapeGenerator: CreativeShapeGeneratorState
    var viewport: CanvasViewport
    var selection: SelectionState
    var tipImageAssets: [BrushTipImageAsset]
    var layerSnapshots: [LayerHistorySnapshot]

    enum CodingKeys: String, CodingKey {
        case document
        case toolSession
        case colorPanel
        case brushLibrary
        case patternLibrary
        case tipImageLibrary
        case generator
        case creativeShapeGenerator
        case viewport
        case selection
        case tipImageAssets
        case layerSnapshots
    }

    init(
        document: ArtDocument,
        toolSession: ToolSessionState,
        colorPanel: ColorPanelState,
        brushLibrary: BrushLibraryState,
        patternLibrary: PatternLibraryState = .init(),
        tipImageLibrary: TipImageLibraryState,
        generator: GeneratorSettings,
        creativeShapeGenerator: CreativeShapeGeneratorState = .stageOneDefault,
        viewport: CanvasViewport,
        selection: SelectionState,
        tipImageAssets: [BrushTipImageAsset] = [],
        layerSnapshots: [LayerHistorySnapshot]
    ) {
        self.document = document
        self.toolSession = toolSession
        self.colorPanel = colorPanel
        self.brushLibrary = brushLibrary
        self.patternLibrary = patternLibrary
        self.tipImageLibrary = tipImageLibrary
        self.generator = generator
        self.creativeShapeGenerator = creativeShapeGenerator
        self.viewport = viewport
        self.selection = selection
        self.tipImageAssets = tipImageAssets
        self.layerSnapshots = layerSnapshots
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        document = try container.decode(ArtDocument.self, forKey: .document)
        toolSession = try container.decode(ToolSessionState.self, forKey: .toolSession)
        colorPanel = try container.decode(ColorPanelState.self, forKey: .colorPanel)
        brushLibrary = try container.decode(BrushLibraryState.self, forKey: .brushLibrary)
        patternLibrary = try container.decodeIfPresent(PatternLibraryState.self, forKey: .patternLibrary) ?? .init()
        tipImageLibrary = try container.decodeIfPresent(TipImageLibraryState.self, forKey: .tipImageLibrary) ?? .empty
        generator = try container.decode(GeneratorSettings.self, forKey: .generator)
        creativeShapeGenerator = try container.decodeIfPresent(CreativeShapeGeneratorState.self, forKey: .creativeShapeGenerator) ?? .stageOneDefault
        viewport = try container.decode(CanvasViewport.self, forKey: .viewport)
        selection = try container.decode(SelectionState.self, forKey: .selection)
        tipImageAssets = try container.decodeIfPresent([BrushTipImageAsset].self, forKey: .tipImageAssets) ?? []
        layerSnapshots = try container.decode([LayerHistorySnapshot].self, forKey: .layerSnapshots)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(document, forKey: .document)
        try container.encode(toolSession, forKey: .toolSession)
        try container.encode(colorPanel, forKey: .colorPanel)
        try container.encode(brushLibrary, forKey: .brushLibrary)
        try container.encode(patternLibrary, forKey: .patternLibrary)
        try container.encode(tipImageLibrary, forKey: .tipImageLibrary)
        try container.encode(generator, forKey: .generator)
        try container.encode(creativeShapeGenerator, forKey: .creativeShapeGenerator)
        try container.encode(viewport, forKey: .viewport)
        try container.encode(selection, forKey: .selection)
        try container.encode(tipImageAssets, forKey: .tipImageAssets)
        try container.encode(layerSnapshots, forKey: .layerSnapshots)
    }

    static func fromWorkspace(
        _ state: WorkspaceState,
        layerSnapshots: [LayerHistorySnapshot]
    ) -> ProjectPackage {
        let normalized = BrushTipImageAssetSystem.archivedWorkspace(state)
        return ProjectPackage(
            document: normalized.workspace.document,
            toolSession: normalized.workspace.toolSession,
            colorPanel: normalized.workspace.colorPanel,
            brushLibrary: normalized.workspace.brushLibrary,
            patternLibrary: normalized.workspace.patternLibrary,
            tipImageLibrary: normalized.workspace.tipImageLibrary,
            generator: normalized.workspace.generator,
            creativeShapeGenerator: normalized.workspace.creativeShapeGenerator,
            viewport: normalized.workspace.viewport,
            selection: normalized.workspace.selection,
            tipImageAssets: normalized.assets,
            layerSnapshots: layerSnapshots
        )
    }

    var workspaceState: WorkspaceState {
        BrushTipImageAssetSystem.resolveWorkspace(
            WorkspaceState(
                document: document,
                toolSession: toolSession,
                colorPanel: colorPanel,
                brushLibrary: brushLibrary,
                patternLibrary: patternLibrary,
                tipImageLibrary: tipImageLibrary,
                generator: generator,
                creativeShapeGenerator: creativeShapeGenerator,
                viewport: viewport,
                selection: selection
            ),
            assets: tipImageAssets
        )
    }
}

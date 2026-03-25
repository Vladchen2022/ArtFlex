import Foundation

struct AppBootstrap {
    let workspaceStore: WorkspaceStore
    let metalContext: MetalDeviceContext
    let layerSurfaceStore: StageOneLayerSurfaceStore
    let interactionController: CanvasInteractionController
    let strokeEngine: MetalStrokeEngine
    let linearGradientRenderer: LinearGradientRenderer
    let sectorGradientRenderer: SectorGradientRenderer
    let smudgeEngine: SmudgeEngine
    let eyedropperSampler: EyedropperSampler
    let bucketFillEngine: BucketFillEngine
    let layerMergeController: LayerMergeController
    let textureSerializer: LayerTextureSerializer
    let pngExporter: PNGExporter
    let exportController: ExportController
    let persistenceController: PersistenceController
    let historyController: HistoryController
    let filePanelService: FilePanelService
    let brushLibraryPersistenceController: BrushLibraryPersistenceController
    let imagePaletteExtractor: ImagePaletteExtractor
    let timelapseRecorder: TimelapseRecorderController

    @MainActor
    init(
        workspaceStore: WorkspaceStore = WorkspaceStore(),
        metalContext: MetalDeviceContext? = MetalDeviceContext(),
        layerSurfaceStore: StageOneLayerSurfaceStore = StageOneLayerSurfaceStore()
    ) throws {
        guard let metalContext else {
            fatalError("Metal is required to launch ArtFlex.")
        }

        self.workspaceStore = workspaceStore
        self.metalContext = metalContext
        self.layerSurfaceStore = layerSurfaceStore
        self.interactionController = CanvasInteractionController(workspaceStore: workspaceStore)
        self.strokeEngine = try MetalStrokeEngine(
            metalContext: metalContext,
            layerSurfaceStore: layerSurfaceStore
        )
        self.linearGradientRenderer = LinearGradientRenderer(device: metalContext.device)
        self.sectorGradientRenderer = SectorGradientRenderer(device: metalContext.device)
        let textureSerializer = LayerTextureSerializer(metalContext: metalContext)
        self.textureSerializer = textureSerializer
        let pngExporter = PNGExporter(serializer: textureSerializer)
        self.pngExporter = pngExporter
        self.smudgeEngine = SmudgeEngine(serializer: textureSerializer)
        self.eyedropperSampler = EyedropperSampler(serializer: textureSerializer)
        self.bucketFillEngine = BucketFillEngine(serializer: textureSerializer)
        self.layerMergeController = LayerMergeController(serializer: textureSerializer)
        self.exportController = ExportController(
            workspaceStore: workspaceStore,
            layerSurfaceStore: layerSurfaceStore,
            pngExporter: pngExporter
        )
        self.persistenceController = PersistenceController(
            workspaceStore: workspaceStore,
            layerSurfaceStore: layerSurfaceStore,
            serializer: textureSerializer
        )
        self.historyController = HistoryController(
            workspaceStore: workspaceStore,
            layerSurfaceStore: layerSurfaceStore,
            serializer: textureSerializer,
            metalContext: metalContext
        )
        self.filePanelService = FilePanelService()
        self.brushLibraryPersistenceController = BrushLibraryPersistenceController()
        self.imagePaletteExtractor = ImagePaletteExtractor()
        self.timelapseRecorder = TimelapseRecorderController(
            workspaceStore: workspaceStore,
            layerSurfaceStore: layerSurfaceStore,
            serializer: textureSerializer
        )
    }
}

import Foundation

final class AppSharedMetalServices {
    let canvasPresenter: StageOneCanvasPresenter
    let linearGradientRenderer: LinearGradientRenderer
    let sectorGradientRenderer: SectorGradientRenderer
    let selectionFillRenderer: SelectionFillRenderer
    let colorAdjustmentRenderer: ColorAdjustmentRenderer
    let creativeShapeGeneratorRenderer: CreativeShapeGeneratorRenderer
    let visibleDeltaRenderer: VisibleDeltaRenderer
    let textureSerializer: LayerTextureSerializer
    let pngExporter: PNGExporter
    let smudgeEngine: SmudgeEngine
    let eyedropperSampler: EyedropperSampler
    let bucketFillEngine: BucketFillEngine
    let layerMergeController: LayerMergeController
    let pixelClipboardController: PixelClipboardController

    init(metalContext: MetalDeviceContext) throws {
        self.canvasPresenter = try StageOneCanvasPresenter(device: metalContext.device)
        self.linearGradientRenderer = LinearGradientRenderer(device: metalContext.device)
        self.sectorGradientRenderer = SectorGradientRenderer(device: metalContext.device)
        self.selectionFillRenderer = SelectionFillRenderer(device: metalContext.device)
        self.colorAdjustmentRenderer = try ColorAdjustmentRenderer(device: metalContext.device)
        self.creativeShapeGeneratorRenderer = CreativeShapeGeneratorRenderer(device: metalContext.device)
        self.visibleDeltaRenderer = try VisibleDeltaRenderer(device: metalContext.device)
        let textureSerializer = LayerTextureSerializer(metalContext: metalContext)
        self.textureSerializer = textureSerializer
        self.pngExporter = PNGExporter(serializer: textureSerializer)
        self.smudgeEngine = SmudgeEngine(serializer: textureSerializer)
        self.eyedropperSampler = EyedropperSampler(serializer: textureSerializer)
        self.bucketFillEngine = BucketFillEngine(serializer: textureSerializer)
        self.layerMergeController = LayerMergeController(
            metalContext: metalContext,
            canvasPresenter: canvasPresenter
        )
        self.pixelClipboardController = PixelClipboardController()
    }
}

struct AppBootstrap {
    let workspaceStore: WorkspaceStore
    let metalContext: MetalDeviceContext
    let layerSurfaceStore: StageOneLayerSurfaceStore
    let sharedMetalServices: AppSharedMetalServices
    let canvasPresenter: StageOneCanvasPresenter
    let interactionController: CanvasInteractionController
    let strokeEngine: MetalStrokeEngine
    let linearGradientRenderer: LinearGradientRenderer
    let sectorGradientRenderer: SectorGradientRenderer
    let selectionFillRenderer: SelectionFillRenderer
    let colorAdjustmentRenderer: ColorAdjustmentRenderer
    let creativeShapeGeneratorRenderer: CreativeShapeGeneratorRenderer
    let visibleDeltaRenderer: VisibleDeltaRenderer
    let smudgeEngine: SmudgeEngine
    let eyedropperSampler: EyedropperSampler
    let bucketFillEngine: BucketFillEngine
    let layerMergeController: LayerMergeController
    let pixelClipboardController: PixelClipboardController
    let textureSerializer: LayerTextureSerializer
    let pngExporter: PNGExporter
    let exportController: ExportController
    let persistenceController: PersistenceController
    let historyController: HistoryController
    let filePanelService: FilePanelService
    let brushLibraryPersistenceController: BrushLibraryPersistenceController
    let imagePaletteExtractor: ImagePaletteExtractor
    let timelapseRecorder: TimelapseRecorderController
    let drawingStatsController: DrawingStatsController

    @MainActor
    init(
        workspaceStore: WorkspaceStore = WorkspaceStore(),
        metalContext: MetalDeviceContext? = MetalDeviceContext(),
        layerSurfaceStore: StageOneLayerSurfaceStore = StageOneLayerSurfaceStore(),
        brushLibraryPersistenceController: BrushLibraryPersistenceController? = nil,
        sharedMetalServices: AppSharedMetalServices? = nil,
        drawingStatsController: DrawingStatsController? = nil
    ) throws {
        guard let metalContext else {
            fatalError("Metal is required to launch ArtFlex.")
        }

        let resolvedSharedMetalServices = try sharedMetalServices ?? AppSharedMetalServices(metalContext: metalContext)
        self.workspaceStore = workspaceStore
        self.metalContext = metalContext
        self.layerSurfaceStore = layerSurfaceStore
        self.sharedMetalServices = resolvedSharedMetalServices
        self.canvasPresenter = resolvedSharedMetalServices.canvasPresenter
        self.interactionController = CanvasInteractionController(workspaceStore: workspaceStore)
        self.strokeEngine = try MetalStrokeEngine(
            metalContext: metalContext,
            layerSurfaceStore: layerSurfaceStore
        )
        self.linearGradientRenderer = resolvedSharedMetalServices.linearGradientRenderer
        self.sectorGradientRenderer = resolvedSharedMetalServices.sectorGradientRenderer
        self.selectionFillRenderer = resolvedSharedMetalServices.selectionFillRenderer
        self.colorAdjustmentRenderer = resolvedSharedMetalServices.colorAdjustmentRenderer
        self.creativeShapeGeneratorRenderer = resolvedSharedMetalServices.creativeShapeGeneratorRenderer
        self.visibleDeltaRenderer = resolvedSharedMetalServices.visibleDeltaRenderer
        let textureSerializer = resolvedSharedMetalServices.textureSerializer
        self.textureSerializer = textureSerializer
        let pngExporter = resolvedSharedMetalServices.pngExporter
        self.pngExporter = pngExporter
        self.smudgeEngine = resolvedSharedMetalServices.smudgeEngine
        self.eyedropperSampler = resolvedSharedMetalServices.eyedropperSampler
        self.bucketFillEngine = resolvedSharedMetalServices.bucketFillEngine
        self.layerMergeController = resolvedSharedMetalServices.layerMergeController
        self.pixelClipboardController = resolvedSharedMetalServices.pixelClipboardController
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
        self.brushLibraryPersistenceController = brushLibraryPersistenceController ?? BrushLibraryPersistenceController()
        self.imagePaletteExtractor = ImagePaletteExtractor()
        self.timelapseRecorder = TimelapseRecorderController(
            workspaceStore: workspaceStore,
            layerSurfaceStore: layerSurfaceStore,
            serializer: textureSerializer
        )
        self.drawingStatsController = drawingStatsController ?? DrawingStatsController()
    }
}

import Foundation

final class AppSharedMetalServices {
    let canvasPresenter: StageOneCanvasPresenter
    let patternPlacementRenderer: PatternPlacementRenderer
    let linearGradientRenderer: LinearGradientRenderer
    let sectorGradientRenderer: SectorGradientRenderer
    let selectionFillRenderer: SelectionFillRenderer
    let selectionPixelOperationRenderer: SelectionPixelOperationRenderer
    let colorAdjustmentRenderer: ColorAdjustmentRenderer
    let curveAdjustmentRenderer: CurveAdjustmentRenderer
    let visibleDeltaRenderer: VisibleDeltaRenderer
    let layerContentBoundsDetector: LayerContentBoundsDetector
    let textureSerializer: LayerTextureSerializer
    let pngExporter: PNGExporter
    let smudgeEngine: SmudgeEngine
    let eyedropperSampler: EyedropperSampler
    let bucketFillEngine: BucketFillEngine
    let layerMergeController: LayerMergeController
    let pixelClipboardController: PixelClipboardController

    init(metalContext: MetalDeviceContext) throws {
        self.canvasPresenter = try StageOneCanvasPresenter(device: metalContext.device)
        self.patternPlacementRenderer = try PatternPlacementRenderer(device: metalContext.device)
        self.linearGradientRenderer = LinearGradientRenderer(device: metalContext.device)
        self.sectorGradientRenderer = SectorGradientRenderer(device: metalContext.device)
        self.selectionFillRenderer = SelectionFillRenderer(device: metalContext.device)
        self.selectionPixelOperationRenderer = SelectionPixelOperationRenderer(device: metalContext.device)
        self.colorAdjustmentRenderer = try ColorAdjustmentRenderer(device: metalContext.device)
        self.curveAdjustmentRenderer = try CurveAdjustmentRenderer(device: metalContext.device)
        self.visibleDeltaRenderer = try VisibleDeltaRenderer(device: metalContext.device)
        self.layerContentBoundsDetector = try LayerContentBoundsDetector(device: metalContext.device)
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
    let patternPlacementRenderer: PatternPlacementRenderer
    let interactionController: CanvasInteractionController
    let strokeEngine: MetalStrokeEngine
    let linearGradientRenderer: LinearGradientRenderer
    let sectorGradientRenderer: SectorGradientRenderer
    let selectionFillRenderer: SelectionFillRenderer
    let selectionPixelOperationRenderer: SelectionPixelOperationRenderer
    let colorAdjustmentRenderer: ColorAdjustmentRenderer
    let curveAdjustmentRenderer: CurveAdjustmentRenderer
    let visibleDeltaRenderer: VisibleDeltaRenderer
    let layerContentBoundsDetector: LayerContentBoundsDetector
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
    let patternLibraryPersistenceController: PatternLibraryPersistenceController
    let textureFillLibraryPersistenceController: TextureFillLibraryPersistenceController
    let imagePaletteExtractor: ImagePaletteExtractor
    let timelapseRecorder: TimelapseRecorderController
    let drawingStatsController: DrawingStatsController

    @MainActor
    init(
        workspaceStore: WorkspaceStore = WorkspaceStore(),
        metalContext: MetalDeviceContext? = MetalDeviceContext(),
        layerSurfaceStore: StageOneLayerSurfaceStore = StageOneLayerSurfaceStore(),
        brushLibraryPersistenceController: BrushLibraryPersistenceController? = nil,
        patternLibraryPersistenceController: PatternLibraryPersistenceController? = nil,
        textureFillLibraryPersistenceController: TextureFillLibraryPersistenceController? = nil,
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
        self.patternPlacementRenderer = resolvedSharedMetalServices.patternPlacementRenderer
        self.interactionController = CanvasInteractionController(workspaceStore: workspaceStore)
        self.strokeEngine = try MetalStrokeEngine(
            metalContext: metalContext,
            layerSurfaceStore: layerSurfaceStore
        )
        self.linearGradientRenderer = resolvedSharedMetalServices.linearGradientRenderer
        self.sectorGradientRenderer = resolvedSharedMetalServices.sectorGradientRenderer
        self.selectionFillRenderer = resolvedSharedMetalServices.selectionFillRenderer
        self.selectionPixelOperationRenderer = resolvedSharedMetalServices.selectionPixelOperationRenderer
        self.colorAdjustmentRenderer = resolvedSharedMetalServices.colorAdjustmentRenderer
        self.curveAdjustmentRenderer = resolvedSharedMetalServices.curveAdjustmentRenderer
        self.visibleDeltaRenderer = resolvedSharedMetalServices.visibleDeltaRenderer
        self.layerContentBoundsDetector = resolvedSharedMetalServices.layerContentBoundsDetector
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
        let testPersistenceRoot = Self.testPersistenceRootURL()
        self.brushLibraryPersistenceController = brushLibraryPersistenceController ?? BrushLibraryPersistenceController(
            rootDirectoryURL: testPersistenceRoot
        )
        self.patternLibraryPersistenceController = patternLibraryPersistenceController ?? PatternLibraryPersistenceController(
            rootDirectoryURL: testPersistenceRoot
        )
        self.textureFillLibraryPersistenceController = textureFillLibraryPersistenceController
            ?? TextureFillLibraryPersistenceController(rootDirectoryURL: testPersistenceRoot)
        self.imagePaletteExtractor = ImagePaletteExtractor()
        self.timelapseRecorder = TimelapseRecorderController(
            workspaceStore: workspaceStore,
            layerSurfaceStore: layerSurfaceStore,
            serializer: textureSerializer
        )
        self.drawingStatsController = drawingStatsController ?? DrawingStatsController()
    }

    private static func testPersistenceRootURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["XCTestConfigurationFilePath"] != nil else {
            return nil
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtFlexTests-\(ProcessInfo.processInfo.globallyUniqueString)", isDirectory: true)
            .appendingPathComponent("ApplicationSupport", isDirectory: true)
            .appendingPathComponent("ArtFlex", isDirectory: true)
    }
}

import Foundation

enum AppBootstrapError: LocalizedError {
    case metalUnavailable

    var errorDescription: String? {
        switch self {
        case .metalUnavailable:
            return "当前设备无法创建 Metal 渲染环境，ArtFlex 不能安全启动。请检查系统图形支持后重试。"
        }
    }
}

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
    let magicWandSelectionEngine: MagicWandSelectionEngine
    let layerMergeController: LayerMergeController
    let pixelClipboardController: PixelClipboardController
    let layerMaskStrokeRenderer: LayerMaskStrokeRenderer

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
        self.magicWandSelectionEngine = MagicWandSelectionEngine(serializer: textureSerializer)
        self.layerMergeController = LayerMergeController(
            metalContext: metalContext,
            canvasPresenter: canvasPresenter
        )
        self.pixelClipboardController = PixelClipboardController()
        self.layerMaskStrokeRenderer = try LayerMaskStrokeRenderer(device: metalContext.device)
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
    let magicWandSelectionEngine: MagicWandSelectionEngine
    let layerMergeController: LayerMergeController
    let pixelClipboardController: PixelClipboardController
    let layerMaskStrokeRenderer: LayerMaskStrokeRenderer
    let textureSerializer: LayerTextureSerializer
    let pngExporter: PNGExporter
    let rasterExporter: RasterExporter
    let exportController: ExportController
    let persistenceController: PersistenceController
    let historyController: HistoryController
    let filePanelService: FilePanelService
    let brushLibraryPersistenceController: BrushLibraryPersistenceController
    let patternLibraryPersistenceController: PatternLibraryPersistenceController
    let textureFillLibraryPersistenceController: TextureFillLibraryPersistenceController
    let blockReferenceModuleLibraryPersistenceController: BlockReferenceModuleLibraryPersistenceController
    let imagePaletteExtractor: ImagePaletteExtractor
    let timelapseRecorder: TimelapseRecorderController
    let drawingStatsController: DrawingStatsController

    var canvasCapacityPolicy: CanvasCapacityPolicy {
        .standard(recommendedMaxWorkingSetSize: metalContext.device.recommendedMaxWorkingSetSize)
    }

    var archiveReadLimits: ProjectArchiveReadLimits {
        .adaptive(
            recommendedMaxWorkingSetSize: metalContext.device.recommendedMaxWorkingSetSize,
            canvasCapacityPolicy: canvasCapacityPolicy
        )
    }

    var documentResourceBudgetPolicy: DocumentResourceBudgetPolicy {
        .standard(
            recommendedMaxWorkingSetSize: metalContext.device.recommendedMaxWorkingSetSize,
            archiveLimits: archiveReadLimits
        )
    }

    @MainActor
    init(
        workspaceStore: WorkspaceStore = WorkspaceStore(),
        metalContext: MetalDeviceContext? = MetalDeviceContext(),
        layerSurfaceStore: StageOneLayerSurfaceStore = StageOneLayerSurfaceStore(),
        brushLibraryPersistenceController: BrushLibraryPersistenceController? = nil,
        patternLibraryPersistenceController: PatternLibraryPersistenceController? = nil,
        textureFillLibraryPersistenceController: TextureFillLibraryPersistenceController? = nil,
        blockReferenceModuleLibraryPersistenceController: BlockReferenceModuleLibraryPersistenceController? = nil,
        sharedMetalServices: AppSharedMetalServices? = nil,
        drawingStatsController: DrawingStatsController? = nil,
        persistenceRecoveryRootURL: URL? = nil
    ) throws {
        guard let metalContext else {
            throw AppBootstrapError.metalUnavailable
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
        self.rasterExporter = RasterExporter()
        self.smudgeEngine = resolvedSharedMetalServices.smudgeEngine
        self.eyedropperSampler = resolvedSharedMetalServices.eyedropperSampler
        self.bucketFillEngine = resolvedSharedMetalServices.bucketFillEngine
        self.magicWandSelectionEngine = resolvedSharedMetalServices.magicWandSelectionEngine
        self.layerMergeController = resolvedSharedMetalServices.layerMergeController
        self.pixelClipboardController = resolvedSharedMetalServices.pixelClipboardController
        self.layerMaskStrokeRenderer = resolvedSharedMetalServices.layerMaskStrokeRenderer
        self.exportController = ExportController(
            workspaceStore: workspaceStore,
            layerSurfaceStore: layerSurfaceStore,
            pngExporter: pngExporter
        )
        let testPersistenceRoot = Self.testPersistenceRootURL()
        let isolatedDefaults = testPersistenceRoot.flatMap(Self.isolatedUserDefaults(for:))
        self.persistenceController = PersistenceController(
            workspaceStore: workspaceStore,
            layerSurfaceStore: layerSurfaceStore,
            serializer: textureSerializer,
            canvasCapacityPolicy: .standard(
                recommendedMaxWorkingSetSize: metalContext.device.recommendedMaxWorkingSetSize
            ),
            recommendedMaxWorkingSetSize: metalContext.device.recommendedMaxWorkingSetSize,
            recoveryRootURL: persistenceRecoveryRootURL
                ?? testPersistenceRoot?.appendingPathComponent("Recovery", isDirectory: true)
        )
        self.historyController = HistoryController(
            workspaceStore: workspaceStore,
            layerSurfaceStore: layerSurfaceStore,
            serializer: textureSerializer,
            metalContext: metalContext,
            maxResidentBytes: HistoryController.adaptiveMaxResidentBytes(
                recommendedMaxWorkingSetSize: metalContext.device.recommendedMaxWorkingSetSize
            )
        )
        self.filePanelService = FilePanelService()
        self.brushLibraryPersistenceController = brushLibraryPersistenceController ?? BrushLibraryPersistenceController(
            rootDirectoryURL: testPersistenceRoot
        )
        self.patternLibraryPersistenceController = patternLibraryPersistenceController ?? PatternLibraryPersistenceController(
            rootDirectoryURL: testPersistenceRoot
        )
        self.textureFillLibraryPersistenceController = textureFillLibraryPersistenceController
            ?? TextureFillLibraryPersistenceController(rootDirectoryURL: testPersistenceRoot)
        self.blockReferenceModuleLibraryPersistenceController = blockReferenceModuleLibraryPersistenceController
            ?? BlockReferenceModuleLibraryPersistenceController(rootDirectoryURL: testPersistenceRoot)
        self.imagePaletteExtractor = ImagePaletteExtractor()
        self.timelapseRecorder = TimelapseRecorderController(
            workspaceStore: workspaceStore,
            layerSurfaceStore: layerSurfaceStore,
            serializer: textureSerializer,
            defaults: isolatedDefaults ?? .standard
        )
        if let drawingStatsController {
            self.drawingStatsController = drawingStatsController
        } else if let testPersistenceRoot {
            self.drawingStatsController = DrawingStatsController(
                persistenceController: DrawingStatsPersistenceController(
                    baseDirectoryURL: testPersistenceRoot.deletingLastPathComponent()
                )
            )
        } else {
            self.drawingStatsController = DrawingStatsController()
        }
    }

    private static func testPersistenceRootURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let explicitPath = environment["ARTFLEX_TEST_APPLICATION_SUPPORT_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicitPath.isEmpty {
            return URL(fileURLWithPath: explicitPath, isDirectory: true)
                .standardizedFileURL
        }
        let executablePath = CommandLine.arguments.first ?? ""
        let isRunningTests = environment["XCTestConfigurationFilePath"] != nil
            || Bundle.main.bundleURL.pathExtension.lowercased() == "xctest"
            || executablePath.contains(".xctest/")
            || executablePath.hasSuffix(".xctest")
            || CommandLine.arguments.contains("--test-bundle-path")
            || CommandLine.arguments.contains(where: { $0.contains(".xctest/") })
        guard isRunningTests else {
            return nil
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtFlexTests-\(ProcessInfo.processInfo.globallyUniqueString)", isDirectory: true)
            .appendingPathComponent("ApplicationSupport", isDirectory: true)
            .appendingPathComponent("ArtFlex", isDirectory: true)
    }

    private static func isolatedUserDefaults(for rootURL: URL) -> UserDefaults? {
        let identifier = UInt(bitPattern: rootURL.standardizedFileURL.path.hashValue)
        return UserDefaults(suiteName: "com.vladchen.ArtFlex.Isolated.\(identifier)")
    }
}

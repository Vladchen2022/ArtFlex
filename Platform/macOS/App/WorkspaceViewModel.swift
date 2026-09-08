import AppKit
import SwiftUI
import os
@preconcurrency import Metal

func resolvedRecoveryAutosaveDeadline(
    now: ContinuousClock.Instant,
    delay: Duration,
    forcedDeadline: ContinuousClock.Instant?,
    scheduledDeadline: ContinuousClock.Instant? = nil
) -> ContinuousClock.Instant {
    let requestedDeadline = now.advanced(by: delay)
    guard let forcedDeadline, forcedDeadline > now else {
        // An expired maximum-deferral deadline is a signal to try autosaving now,
        // not a deadline that should be reused for every retry. Reusing it creates
        // an immediate task loop whenever the document is temporarily unsafe.
        // Keep an already scheduled retry from being postponed by every new stroke.
        if let scheduledDeadline, scheduledDeadline > now {
            return min(requestedDeadline, scheduledDeadline)
        }
        return requestedDeadline
    }
    return min(requestedDeadline, forcedDeadline)
}

private func emitSelectionTraceViewModel(_ message: String) {
    appendSelectionTrace(message)
}

private typealias SelectionPolygonShape = [[CGPoint]]

private struct SelectionGeometryOptions {
    var constrainsProportions: Bool
    var drawsFromCenter: Bool
}

private struct SelectionInputShape {
    var polygonShapes: [SelectionPolygonShape]
    var preferredDisplayShape: SelectionShape?
}

private struct WholeLayerInteractionBoundsKey: Equatable {
    let surfaceID: LayerSurfaceID
    let canvasContentRevision: UInt64
}

private struct RecentBrushAdjustmentSyncState: Equatable {
    let layerID: LayerID?
    let selectionLimit: Int
    let selectionCount: Int
    let opacity: Float
    let brightness: Float
    let saturation: Float
    let showsSelectionHighlight: Bool
}

private struct TimelapseDocumentContext: Equatable {
    let documentID: UUID
    let documentName: String
    let documentFileURL: URL?
}

private enum WholeLayerInteractionBoundsCacheEntry: Equatable {
    case ready(CanvasRect)
    case empty
}

enum BrightnessAdjustmentEditorMode: Equatable {
    case colorParameters
    case curves
}

struct PreparedAdjustmentLayerContext {
    let layerID: LayerID
    let sourceTexture: MTLTexture
}

enum ProjectSaveIndicatorState: Equatable {
    case unsaved
    case saved
    case notYetSaved
    case saving
}

private final class PatternPlacementTextureCacheEntry {
    let texture: MTLTexture

    init(texture: MTLTexture) {
        self.texture = texture
    }
}

@MainActor
final class QuickColorPickerPresentationProxy: ObservableObject {
    @Published fileprivate(set) var state: QuickColorPickerState?
}

@MainActor
final class WorkspaceViewModel: ObservableObject {
    var canvasCapacityPolicy: CanvasCapacityPolicy {
        bootstrap.canvasCapacityPolicy
    }

    struct TipImageLibraryReferenceSummary: Equatable {
        var currentBrushUsesPrimary = false
        var currentBrushUsesCompoundSecondary = false
        var smudgeBrushUsesPrimary = false
        var currentTextureFillUsesImportedTip = false
        var presetPrimaryNames: [String] = []
        var presetCompoundSecondaryNames: [String] = []

        var currentBrushPrimaryCount: Int {
            currentBrushUsesPrimary ? 1 : 0
        }

        var smudgeBrushPrimaryCount: Int {
            smudgeBrushUsesPrimary ? 1 : 0
        }

        var presetPrimaryCount: Int {
            presetPrimaryNames.count
        }

        var currentBrushCount: Int {
            currentBrushPrimaryCount + (currentBrushUsesCompoundSecondary ? 1 : 0)
        }

        var smudgeBrushCount: Int {
            smudgeBrushPrimaryCount
        }

        var currentTextureFillCount: Int {
            currentTextureFillUsesImportedTip ? 1 : 0
        }

        var presetCount: Int {
            presetPrimaryCount + presetCompoundSecondaryNames.count
        }

        var totalCount: Int {
            currentBrushCount + smudgeBrushCount + currentTextureFillCount + presetCount
        }

        var isReferenced: Bool {
            totalCount > 0
        }
    }

    private static let runSamePathCommitTest = false
    private static let runSamplingTruthTest = false
    private static let brushTipMaskResolution = 256
    private static let brushTipMaskThreshold: UInt8 = 16
    private static let brushTipCanonicalPadding = 4
    private static let brushTipGuideMassThresholdFraction = 0.08
    private static let brushTipEnvelopeDilationPasses = 6
    private static let brushTipEnvelopeErosionPasses = 3
    private static let maxSavedSnapshotCount = 6
    private static let savedSnapshotThumbnailDimension = 92
    private static let snapshotComparePreviewDimension = 960
    private static let maxReferenceImageSlotCount = 5
    private static let luminosityReferenceAutoRefreshDelay: Duration = .seconds(2)
    private static let luminosityReferenceVisibleResumeDelay: Duration = .milliseconds(150)
    static let navigatorPreviewMinimumRefreshIntervalNanoseconds: UInt64 = 250_000_000
    static let navigatorPreviewCoalescingDelayNanoseconds: UInt64 = 100_000_000

    static func navigatorPreviewRefreshDelayNanoseconds(
        now: UInt64,
        lastRefresh: UInt64?
    ) -> UInt64 {
        guard let lastRefresh, now >= lastRefresh else {
            return navigatorPreviewCoalescingDelayNanoseconds
        }
        let elapsed = now - lastRefresh
        let rateLimitDelay = elapsed >= navigatorPreviewMinimumRefreshIntervalNanoseconds
            ? 0
            : navigatorPreviewMinimumRefreshIntervalNanoseconds - elapsed
        return max(rateLimitDelay, navigatorPreviewCoalescingDelayNanoseconds)
    }

    private static func makeDefaultReferenceImageSlots() -> [ReferenceImageSlotState] {
        (0..<maxReferenceImageSlotCount).map { ReferenceImageSlotState(id: $0) }
    }

    private static func normalizedAvailableTool(_ tool: ToolKind) -> ToolKind {
        tool
    }

    @Published private(set) var workspace: WorkspaceState
    @Published private(set) var sceneSnapshot: CanvasSceneSnapshot
    @Published private(set) var status: WorkspaceStatus?
    @Published private(set) var isPanModeActive = false
    @Published private(set) var isCanvasViewportLocked = false
    @Published private(set) var canvasCropState = CanvasCropInteractionState()
    @Published var showsTransparencyCheckerboard = true
    @Published var isPixelGridEnabled = true
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var visibleHistoryPreviewTargetCount: Int?
    // Content edits and autosave scheduling are separate clocks. Rescheduling a
    // backup (for example on app deactivation) must not invalidate a completed save.
    private var documentEditRevision: UInt64 = 0
    @Published private(set) var hasUnsavedChanges = false {
        didSet {
            if hasUnsavedChanges {
                documentEditRevision &+= 1
                if !isSuppressingRecoveryAutosaveScheduling {
                    scheduleRecoveryAutosave()
                }
            } else {
                recoveryAutosaveInvalidationGeneration &+= 1
                recoveryAutosaveGeneration &+= 1
                recoveryAutosaveTask?.cancel()
                recoveryAutosaveTask = nil
                recoveryAutosaveForcedDeadline = nil
                recoveryAutosaveScheduledDeadline = nil
            }
        }
    }
    private var visibleHistoryPreviewOriginCount: Int?
    private var visibleHistoryPreviewOriginWasDirty = false
    private var visibleHistoryPreviewOriginSelection: SelectionState?
    @Published private(set) var hasRecoveryProject = false
    @Published private(set) var isProjectSaving = false
    @Published var isNewCanvasSheetPresented = false
    @Published var isRasterExportSheetPresented = false
    @Published private(set) var isRasterExporting = false
    @Published private(set) var rasterExportSourceBounds: RasterExportPixelBounds?
    @Published private(set) var isPreparingRasterExportBounds = false
    @Published private(set) var rasterExportBoundsError: String?
    @Published private(set) var rasterExportError: String?
    @Published private(set) var patternImportSheetState = PatternImportSheetState()
    @Published private(set) var patternImportPreviewAsset: PatternImportPreviewAsset?
    @Published private(set) var patternImportCurrentEraseMaskData: Data?
    @Published private(set) var isPatternImportPreviewLoading = false
    @Published private(set) var isPatternImporting = false
    @Published private(set) var patternPlacementPhase = PatternPlacementPhase.idle
    @Published private(set) var isApplyingPatternPlacementCommit = false
    @Published private(set) var brushLibraryRevealRequestID: UInt64 = 0
    @Published private(set) var isTransformingSelection = false
    @Published private(set) var canMergeDown = false
    @Published private(set) var canMergeVisible = false
    @Published private(set) var strokeResetToken = 0
    /// Advances only when the entire document and its GPU surface graph are replaced.
    /// Canvas hosts use this identity to discard coordinators that still retain the
    /// previous document's surface IDs or drawable state.
    @Published private(set) var documentRenderGeneration: UInt64 = 0
    @Published private(set) var isGeneratorRegionSelectionArmed = false
    @Published private(set) var isGeneratorStrokeModeEnabled = false
    @Published private(set) var activeMaskEditingLayerID: LayerID?
    @Published private(set) var straightLineState = StraightLineInteractionState()
    @Published private(set) var linearGradientState = LinearGradientInteractionState()
    @Published private(set) var sectorGradientState = SectorGradientInteractionState()
    @Published private(set) var gradientSettings = GradientSettings.currentColorToTransparent(.black)
    @Published private(set) var gradientFollowsSelectedColor = true
    @Published private(set) var polygonSelectionState = PolygonSelectionInteractionState()
    @Published private(set) var toolGroupSurfaceTools = ToolSidebarGroup.defaultSurfaceTools
    @Published private(set) var transformPreviewOffset = CanvasPoint(x: 0, y: 0)
    @Published private(set) var freeTransformPreview = FreeTransformPreview.identity
    @Published private(set) var freeTransformToolMode = FreeTransformToolMode.standard
    @Published private(set) var preciseTransformLocksAspectRatio = true
    @Published private(set) var freeTransformMeshWarpGrid: MeshWarpGrid?
    @Published private(set) var selectedMeshWarpControlPointIndices: Set<Int> = []
    @Published private(set) var selectedPerspectiveAnchorID: UUID?
    @Published var blockReferenceEditorState = BlockReferenceEditorState()
    @Published var blockReferenceWorkflow = BlockReferenceWorkflowState()
    @Published var perspectiveGuideMatchState = PerspectiveGuideMatchState()
    @Published var isBlockReferenceCameraNavigating = false
    var blockReferenceCameraPreview: BlockReferenceCamera?
    let blockReferenceCameraRenderState = BlockReferenceCameraRenderState()
    @Published private(set) var isApplyingGradientCommit = false
    @Published private(set) var isBucketFillInProgress = false
    @Published private(set) var fillSettings = FillSettings.stageOneDefault
    @Published private(set) var smartSelectionSettings = SmartSelectionSettings.stageOneDefault
    @Published private(set) var smartSelectionDisplayMode: SmartSelectionDisplayMode = .tint
    @Published private(set) var isRefiningSelection = false
    @Published private(set) var isSavingSnapshot = false
    @Published private(set) var isPreparingSnapshotCompare = false
    @Published private(set) var isProjectOpening = false
    @Published private(set) var isLuminosityPreviewEnabled = false
    @Published private(set) var isFreeTransformDragging = false
    @Published private(set) var activeFreeTransformInteractionMode: FreeTransformInteractionMode?
    @Published private(set) var isBrushTipCanvasFocused = false
    @Published private(set) var isBrushTipEditorVisible = false
    @Published private(set) var brushTipEditorBrushSize: Float = 28
    @Published private(set) var isColorBlocksPanelFocused = false
    @Published private(set) var brushTipDraftMaskData: Data?
    @Published private(set) var hasPendingBrushTipDraft = false
    @Published private(set) var canUndoBrushTipDraft = false
    @Published private(set) var canRedoBrushTipDraft = false
    private(set) var lassoSamplingDebugPoints: [CanvasPoint] = []
    private(set) var samePathCommittedDebugShape: SelectionShape?
    private(set) var samePathPreviewDebugShape: SelectionShape?

    private let bootstrap: AppBootstrap
    private let brushLibraryPersistenceQueue = PersistenceSaveQueue(label: "ArtFlex.BrushLibraryPersistence")
    private let patternLibraryPersistenceQueue = PersistenceSaveQueue(label: "ArtFlex.PatternLibraryPersistence")
    private let textureFillLibraryPersistenceQueue = PersistenceSaveQueue(label: "ArtFlex.TextureFillLibraryPersistence")
    private let blockReferenceModuleLibraryPersistenceQueue = PersistenceSaveQueue(
        label: "ArtFlex.BlockReferenceModuleLibraryPersistence"
    )
    var ideationBranchActivityHandler: (() -> Void)?
    var ideationOperationHandler: ((IdeationCanvasOperation) -> Void)?
    var ideationUndoHandler: (() -> Bool)?
    var ideationRedoHandler: (() -> Bool)?
    var canvasContentChangeHandler: (() -> Void)?
    private var isApplyingMirroredIdeationOperation = false
    private var brushTipDraftSnapshot: BrushTipDraftSnapshot?
    private var brushTipDraftHistory = BrushTipDraftHistory()
    private var statusDismissTask: Task<Void, Never>?
    private var rasterExportTask: Task<Void, Never>?
    private var rasterExportBoundsRequest: UUID?
    private var isAdjustingLayerOpacity = false
    private var activeLayerOpacityChangeDidMutate = false
    private var transformState = TransformInteractionState()
    private var activeMeshWarpDragControlPointIndices: Set<Int>?
    private var perspectiveGuideInteractionTarget: PerspectiveGuideInteractionTarget?
    private var perspectiveGuideInteractionLastPoint: CanvasPoint?
    private var perspectiveGuideInteractionHasCheckpoint = false
    private var isAdjustingPerspectiveGuideStyle = false
    var blockReferenceInteractionStartPoint: CanvasPoint?
    var blockReferenceInteractionStartWorldPoint: BlockVector3?
    var blockReferenceMoveStartPosition: BlockVector3?
    var blockReferenceMoveStartPositions: [UUID: BlockVector3] = [:]
    var blockReferenceMoveStartModuleBasePoints: [UUID: BlockVector3] = [:]
    var blockReferenceMoveStartCustomPivot: BlockVector3?
    var blockReferenceInteractionHasCheckpoint = false
    var blockReferenceGizmoDragSession: BlockReferenceGizmoDragSession?
    var blockReferenceHumanJointDragSession: BlockHumanJointDragSession?
    var isAdjustingBlockReferenceParameters = false
    var blockReferenceCameraNavigationMode: BlockReferenceNavigationMode?
    var blockReferenceCameraNavigationStart: BlockReferenceCamera?
    var blockReferenceCameraZoomCommitTask: Task<Void, Never>?
    private var layerThumbnailCache: [LayerID: CGImage] = [:]
    private var generatorStrokeSession = GeneratorStrokeSessionState()
    private var activeLassoRawPoints: [CanvasPoint] = []
    private var activeLassoPreviewPoints: [CanvasPoint] = []
    private var activeLassoBounds: CanvasRect?
    private var textureFillGestureState: TextureFillGestureState?
    private var textureFillSeedSequence: UInt64 = 0
    private var bucketFillRequestID: UInt64 = 0
    private var bucketFillTask: Task<Void, Never>?
    private var bucketFillCancellation: WorkCancellation?
    private var isChoosingPaletteImage = false
    var imagePaletteExtractor: ImagePaletteExtractor { bootstrap.imagePaletteExtractor }
    private var snapshotSaveRequestID: UInt64 = 0
    private var snapshotSaveTask: Task<Void, Never>?
    private var snapshotComparePreparationRequestID: UInt64 = 0
    private var snapshotComparePreparationTask: Task<Void, Never>?
    private var adjustmentLayerCheckpointResetTask: Task<Void, Never>?
    private var adjustmentLayerCheckpointLayerID: LayerID?
    private var lastLassoOverlayRefreshUptime: TimeInterval = 0
    private var freeTransformUsesImplicitSelection = false
    private var implicitFreeTransformSelectionShape: SelectionShape?
    @Published private(set) var isApplyingTransformCommit = false
    @Published private(set) var canvasContentRevision: UInt64 = 0
    @Published private(set) var selectionRevision: UInt64 = 0
    @Published private(set) var viewportRevision: UInt64 = 0
    @Published private(set) var canvasViewportMetricsRevision: UInt64 = 0
    @Published private(set) var layerThumbnailRevision: UInt64 = 0
    @Published private(set) var transformPreviewRevision: UInt64 = 0
    @Published private(set) var savedSnapshots: [CanvasSavedSnapshot] = []
    @Published private(set) var ideationSession: IdeationSessionState?
    @Published private(set) var snapshotCompareSession: SnapshotCompareSessionState?
    let quickColorPickerPresentation = QuickColorPickerPresentationProxy()
    private(set) var quickColorPickerState: QuickColorPickerState? {
        didSet {
            quickColorPickerPresentation.state = quickColorPickerState
        }
    }
    @Published var recentBrushAdjustmentRedrawRevision: UInt64 = 0
    @Published private(set) var isWorkspaceChromeHidden = false
    @Published var colorAdjustmentOverlayState = ColorAdjustmentOverlayState.inactive
    @Published var curveAdjustmentOverlayState = CurveAdjustmentOverlayState.inactive
    @Published var colorAdjustmentRedrawRevision: UInt64 = 0
    @Published private(set) var referenceImageSlots = WorkspaceViewModel.makeDefaultReferenceImageSlots()
    @Published private(set) var selectedReferenceImageSlotID: Int?
    @Published private(set) var referenceImagePreviewColor: RGBAColor?
    @Published private(set) var referenceImagePreviousPickedColor: RGBAColor?
    @Published private(set) var referenceImageLoadingSlotIDs: Set<Int> = []
    @Published private(set) var isReferenceImageFloatingPanelPresented = false
    private var currentProjectURL: URL?

    var projectSaveIndicatorState: ProjectSaveIndicatorState {
        if isProjectSaving {
            return .saving
        }
        if hasUnsavedChanges {
            return .unsaved
        }
        return currentProjectURL == nil ? .notYetSaved : .saved
    }
    private var lastSyncedTimelapseDocumentContext: TimelapseDocumentContext?
    private var shouldResumeTimelapseAfterIdeation = false
    private var shouldResumeTimelapseAfterSnapshotCompare = false
    private var isChoosingTimelapseDirectory = false
    private var isChoosingProjectToOpen = false
    private var isChoosingProjectSaveLocation = false
    private var isDocumentTransitionPending = false
    private var snapshotPreviewPreparationTasks: [UUID: Task<Void, Never>] = [:]
    private var frozenSnapshotPreviewPreparationTask: Task<Void, Never>?
    private let patternPlacementTextureCache: NSCache<NSUUID, PatternPlacementTextureCacheEntry> = {
        let cache = NSCache<NSUUID, PatternPlacementTextureCacheEntry>()
        cache.countLimit = 8
        cache.totalCostLimit = 256 * 1024 * 1024
        cache.name = "ArtFlex.PatternPlacementTextures"
        return cache
    }()
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var referenceImageUpgradeTasks: [Int: Task<Void, Never>] = [:]
    private var recoveryAutosaveTask: Task<Void, Never>?
    private var recoveryAutosaveWriteTask: Task<Void, Never>?
    private var projectSaveTask: Task<Void, Never>?
    private var projectOpenTask: Task<Void, Never>?
    private var pendingManualSaveAfterRecoveryAutosave = false
    private var pendingManualSaveAfterTimelapse = false
    private var recoveryAutosaveWaitingForTimelapse = false
    private var recoveryAutosaveGeneration: UInt64 = 0
    /// Changes only when a completed capture must no longer be installed, not for new strokes.
    private var recoveryAutosaveInvalidationGeneration: UInt64 = 0
    private var recoveryAutosaveForcedDeadline: ContinuousClock.Instant?
    private var recoveryAutosaveScheduledDeadline: ContinuousClock.Instant?
    private var isSuppressingRecoveryAutosaveScheduling = false
    private static let recoveryAutosaveMaximumDeferral: Duration = .seconds(120)
    private var deferredGradientAction: DeferredGradientAction?
    private let selectionTraceLogger = Logger(subsystem: "ArtFlex", category: "SelectionTrace")
    private let brushStrokeLogger = Logger(subsystem: "ArtFlex", category: "BrushStroke")
    private let transformLogger = Logger(subsystem: "ArtFlex", category: "Transform")
    private var latestCanvasViewportSize: CGSize = .zero
    private var lastCanvasHoverPoint: CanvasPoint?
    private var isQuickColorPickerShortcutActive = false
    private var quickColorPickerDraftState: QuickColorPickerState?
    private var previousToolBeforeEyedropper: ToolKind?
    private var recentBrushAdjustmentSelectedCount = 0
    private var recentBrushAdjustmentOpacity: Float = 1
    private var recentBrushAdjustmentBrightness: Float = 0
    private var recentBrushAdjustmentSaturation: Float = 0
    private var isRecentBrushSelectionHighlightActive = false
    private var lastRecentBrushAdjustmentSyncState: RecentBrushAdjustmentSyncState?
    private var documentChangeRevision: UInt64 = 0
    private var strokePacketCount = 0
    private var activePaintVariationSeed: UInt32 = 0
    private var lastLayerMaskStrokeSample: CanvasStrokeSample?
    var colorAdjustmentSession: ColorAdjustmentSession?
    var curveAdjustmentSession: CurveAdjustmentSession?
    var brightnessAdjustmentEditorMode: BrightnessAdjustmentEditorMode = .colorParameters
    var colorAdjustmentBrushMode: ColorAdjustmentBrushMode = .paint
    var colorAdjustmentStrokePacketCount = 0
    var colorAdjustmentPreviewRenderInFlight = false
    var colorAdjustmentPreviewRenderNeedsResubmit = false
    var colorAdjustmentPreviewToken: UInt64 = 0
    var colorAdjustmentAllowsIdleModeHotkeys = false
    var curveAdjustmentBrushMode: CurveAdjustmentBrushMode = .paint
    var curveAdjustmentStrokePacketCount = 0
    var curveAdjustmentPreviewRenderInFlight = false
    var curveAdjustmentPreviewRenderNeedsResubmit = false
    var curveAdjustmentPreviewToken: UInt64 = 0
    var curveAdjustmentAllowsIdleModeHotkeys = false
#if DEBUG
    var debugColorAdjustmentResolutionDecisionOverride: ColorAdjustmentResolutionDecision?
    var debugCurveAdjustmentResolutionDecisionOverride: CurveAdjustmentResolutionDecision?
    var debugPixelOperationHistoryCaptureModeOverride: HistoryCaptureMode?
    var debugFillAtPointHistoryCaptureModeOverride: HistoryCaptureMode?
    private(set) var debugTimelapseDocumentContextSyncCount = 0

    func debugSetCommittedSelectionShapeForTests(_ shape: SelectionShape?) {
        bootstrap.workspaceStore.updateSelection { selection in
            selection.committedShape = shape
            selection.inProgressShape = nil
            selection.anchorPoint = nil
            selection.activeKind = nil
            selection.activeCombineMode = .replace
        }
        refresh(reason: "debugSetCommittedSelectionShapeForTests")
    }

    func debugPerformRecoveryAutosaveNowForTests() {
        recoveryAutosaveTask?.cancel()
        recoveryAutosaveTask = nil
        recoveryAutosaveGeneration &+= 1
        performRecoveryAutosave(generation: recoveryAutosaveGeneration)
    }

    func debugExpireRecoveryAutosaveDeadlineForTests() {
        recoveryAutosaveForcedDeadline = ContinuousClock().now.advanced(by: .seconds(-1))
    }

    var debugRecoveryAutosaveBeforeInstall: (() -> Void)?

    var debugRecoveryAutosaveWriteInFlight: Bool { recoveryAutosaveWriteTask != nil }
#endif

    private static let textureFillMinimumSliceDistance: Double = 2.5
    private var freeTransformMoveLogCount = 0
    private var wholeLayerInteractionBoundsCacheKey: WholeLayerInteractionBoundsKey?
    private var wholeLayerInteractionBoundsCacheEntry: WholeLayerInteractionBoundsCacheEntry?
    private var wholeLayerInteractionBoundsBuildingKey: WholeLayerInteractionBoundsKey?
    private var wholeLayerInteractionBoundsTask: Task<WholeLayerInteractionBoundsCacheEntry?, Never>?
    private var lastLoggedWholeLayerOverlayUsesInteractionBounds: Bool?
    private lazy var transformPreviewSessionBuilder = TransformPreviewSessionBuilder(device: bootstrap.metalContext.device)
    private lazy var transformGPUCompositorResult: Result<TransformGPUCompositor, Error> = Result {
        try TransformGPUCompositor(device: bootstrap.metalContext.device)
    }
    private lazy var referenceImageFloatingPanelController = ReferenceImageFloatingPanelController()
    @Published private(set) var isCanvasLuminosityReferenceActive = false
    let shortcutSettings = AppShortcutSettingsStore()
    private var luminosityReferenceSlotID: Int?
    private var luminosityCaptureTask: Task<Void, Never>?
    private var luminosityReferenceSourceRevision: UInt64 = 0
    private var lastLuminosityCaptureRevision: UInt64 = 0
    private var isReferenceImageInspectorVisible = false
    private var luminosityReferenceHasPendingRefresh = false
    private var navigatorPreviewRefreshTask: Task<Void, Never>?
    private var isNavigatorPreviewVisible = false
    private var navigatorPreviewHasPendingRefresh = false
    private var navigatorPreviewRequestRevision: UInt64 = 0
    private var lastNavigatorPreviewRefreshUptimeNanoseconds: UInt64?
    private var patternImportPreviewTask: Task<Void, Never>?
    private var patternImportPreviewSourceFileURL: URL?
    private var patternImportPreviewSourceAsset: PatternImportPreviewSourceAsset?
    private var patternImportEraseMasksByFileURL: [URL: Data] = [:]
    private lazy var luminosityPresenter: StageOneCanvasPresenter? = {
        try? StageOneCanvasPresenter(device: bootstrap.metalContext.device)
    }()
    private lazy var luminosityPostProcessor: LABLuminosityPostProcessor? = {
        try? LABLuminosityPostProcessor(device: bootstrap.metalContext.device)
    }()
    init(
        bootstrap: AppBootstrap,
        installsZoomKeyboardMonitor: Bool = true,
        preparesInitialTextures: Bool = true
    ) {
        self.bootstrap = bootstrap
        resetSelectionTraceLog()
        let didSanitizePersistedBrushResources = Self.restorePersistedBrushLibraryIfAvailable(in: bootstrap)
        let didSanitizePersistedPatternLibrary = Self.restorePersistedPatternLibraryIfAvailable(in: bootstrap)
        Self.restorePersistedTextureFillLibraryIfAvailable(in: bootstrap)
        Self.restorePersistedBlockReferenceModuleLibraryIfAvailable(in: bootstrap)
        Self.normalizeLegacySelectionIfNeeded(in: bootstrap.workspaceStore)
        Self.normalizeDisabledToolsIfNeeded(in: bootstrap.workspaceStore)
        let didApplyLaunchDefaultBrushPreset = Self.applyLaunchDefaultBrushPresetIfNeeded(in: bootstrap.workspaceStore)
        let state = bootstrap.workspaceStore.state
        if preparesInitialTextures {
            bootstrap.layerSurfaceStore.prepareTextures(
                for: state.document,
                metal: bootstrap.metalContext
            )
        }
        self.workspace = state
        self.gradientSettings = .currentColorToTransparent(state.toolSession.selectedColor)
        self.sceneSnapshot = WorkspaceViewModel.makeSceneSnapshot(
            workspace: state,
            bootstrap: bootstrap,
            canvasContentRevision: 0,
            selectionRevision: 0,
            viewportRevision: 0
        )
        if let group = ToolSidebarGroup.group(containing: state.toolSession.activeTool) {
            toolGroupSurfaceTools[group.id] = state.toolSession.activeTool
        }
        if preparesInitialTextures {
            seedDefaultBackgroundLayerIfNeeded(for: state.document)
        }
        bootstrap.timelapseRecorder.compositeTextureProvider = { [weak self] in
            guard let self else {
                throw CocoaError(.userCancelled)
            }
            return try self.makeVisibleCompositeTexture(waitUntilCompleted: false, includesLiveBrushContent: true)
        }
        bootstrap.timelapseRecorder.shouldDeferCapture = { [weak self] in
            guard let self else { return true }
            return self.isProjectSaving
                || self.isProjectOpening
                || self.recoveryAutosaveWriteTask != nil
                || self.snapshotSaveTask != nil
                || self.isRasterExporting
                || self.pendingManualSaveAfterTimelapse
                || self.recoveryAutosaveWaitingForTimelapse
                || self.bootstrap.strokeEngine.hasPendingBrushWork
        }
        bootstrap.timelapseRecorder.onBecameIdle = { [weak self] in
            self?.resumePersistenceAfterTimelapseBecameIdle()
        }
        syncTimelapseDocumentContext()
        syncDrawingStatsDocumentContext()
        if installsZoomKeyboardMonitor {
            setupZoomKeyboardMonitor()
            setupMemoryPressureMonitor()
        }
        if didSanitizePersistedBrushResources || didApplyLaunchDefaultBrushPreset {
            persistBrushLibrary()
        }
        if didSanitizePersistedPatternLibrary {
            persistPatternLibrary()
        }
        hasRecoveryProject = bootstrap.persistenceController.hasRecoveryProject
        if hasRecoveryProject {
            status = .init(kind: .info, message: "检测到自动恢复工程，可从顶部工具栏恢复")
        }
        let libraryLoadFailures = [
            bootstrap.brushLibraryPersistenceController.loadFailureDescription,
            bootstrap.patternLibraryPersistenceController.loadFailureDescription,
            bootstrap.textureFillLibraryPersistenceController.loadFailureDescription,
            bootstrap.blockReferenceModuleLibraryPersistenceController.loadFailureDescription
        ].compactMap { $0 }
        if !libraryLoadFailures.isEmpty {
            status = .init(kind: .error, message: libraryLoadFailures.joined(separator: "；"))
        }
    }

    deinit {
        projectOpenTask?.cancel()
        memoryPressureSource?.cancel()
    }

    private func setupMemoryPressureMonitor() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            let events = source?.data ?? []
            Task { @MainActor [weak self] in
                self?.handleMemoryPressure(events)
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    private func handleMemoryPressure(_ events: DispatchSource.MemoryPressureEvent) {
        let isCritical = events.contains(.critical)
        bootstrap.textureSerializer.trimStagingPool(
            toMaxResidentBytes: isCritical ? 0 : 8 * 1024 * 1024
        )
        patternPlacementTextureCache.removeAllObjects()
        StageOneBrushPreviewRasterizer.resetCache()
        bootstrap.strokeEngine.purgeTransientPreviewTexturesIfIdle()
        bootstrap.historyController.relieveMemoryPressure(critical: isCritical)

        cancelPendingSnapshotComparePreparation(resumeTimelapseIfNeeded: false)
        cancelSnapshotPreviewPreparationTasks()
        if snapshotCompareSession == nil {
            var trimmedSnapshots = savedSnapshots
            for index in trimmedSnapshots.indices {
                trimmedSnapshots[index].previewImage = nil
            }
            savedSnapshots = trimmedSnapshots
        }
        if isCritical {
            layerThumbnailCache.removeAll(keepingCapacity: false)
            layerThumbnailRevision &+= 1
            if hasUnsavedChanges {
                scheduleRecoveryAutosave(delay: .seconds(10))
            }
            showStatus(.init(
                kind: .info,
                message: "系统内存紧张，已释放可重建缓存和较旧历史；画布内容未受影响"
            ))
        }
        canUndo = bootstrap.historyController.canUndo
        canRedo = bootstrap.historyController.canRedo
    }

    // Cmd+= / Cmd+- 完全绕过菜单系统，直接本地拦截
    // 菜单快捷键会在系统事件队列里积压，松开按键后仍持续触发
    // addLocalMonitorForEvents 在事件到达菜单前拦截，返回 nil 消费掉事件
    private func setupZoomKeyboardMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if NSApp.keyWindow?.identifier?.rawValue == "ReferenceImageFloatingPanel" {
                return event
            }
            if self.workspace.toolSession.activeTool == .blockReference,
               !Self.isEditingTextInKeyWindow,
               self.handleBlockReferenceKeyDown(event) {
                return nil
            }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard modifiers == .command || modifiers == [.command, .shift] else { return event }
            let chars = event.charactersIgnoringModifiers
            if chars == "=" || chars == "+" {
                self.zoomIn()
                return nil
            }
            if chars == "-" {
                self.zoomOut()
                return nil
            }
            if chars == "0" {
                self.fitCanvasToWindow()
                return nil
            }
            if chars == "1" {
                self.setCanvasToActualPixels()
                return nil
            }
            return event
        }
    }

    private static var isEditingTextInKeyWindow: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if let textView = responder as? NSTextView {
            return textView.isEditable
        }
        return responder is NSTextField
    }

    func selectTool(_ tool: ToolKind) {
        ideationBranchActivityHandler?()
        let normalizedTool = Self.normalizedAvailableTool(tool)
        let currentTool = workspace.toolSession.activeTool
        let shouldRevealBrushLibrary = normalizedTool == .brush
        if currentTool == normalizedTool {
            if isGeneratorStrokeModeEnabled {
                exitGeneratorMode(showFeedback: false)
                if shouldRevealBrushLibrary {
                    revealBrushLibraryPanel()
                }
                showToolSelectionStatus(for: normalizedTool)
                return
            }
            if patternPlacementPhase != .idle {
                cancelPatternPlacement(keepSelection: true)
            }
            if shouldRevealBrushLibrary {
                revealBrushLibraryPanel()
            }
            return
        }
        if currentTool == .straightLine, straightLineState.phase == .pending {
            guard commitPendingStraightLine() else { return }
        } else if currentTool == .straightLine, straightLineState.phase != .idle {
            cancelStraightLineInteraction()
        }
        if currentTool != normalizedTool
            && !resolveColorAdjustmentSessionIfNeeded(reason: .toolChange) {
            return
        }
        if currentTool != normalizedTool
            && !resolveCurveAdjustmentSessionIfNeeded(reason: .toolChange) {
            return
        }
        if patternPlacementPhase != .idle {
            cancelPatternPlacement(keepSelection: true)
        }
        if shouldAutoApplyGradientBeforeSelectingTool(normalizedTool) {
            deferredGradientAction = .toolSwitch(normalizedTool)
            transformLogger.debug("[gradient] autoApplyOnToolSwitch=true sessionState=\(self.gradientSessionStateDescription(), privacy: .public)")
            transformLogger.debug("[gradient] deferredToolSwitch=true sessionTool=\(String(describing: self.activeGradientTool()), privacy: .public)")
            guard !isApplyingGradientCommit else { return }
            applyActiveGradientSession()
            return
        }
        if (currentTool == .brush && normalizedTool != .brush)
            || (currentTool != .brush && isBrushLikeTool(currentTool) && !isBrushLikeTool(normalizedTool)) {
            _ = drainPendingBrushCommitsIfNeeded(resetLiveSession: true)
        }
        if currentTool == .textureFill, normalizedTool != .textureFill {
            resetTextureFillGesture(reason: "toolChange")
        }
        if currentTool == .canvasCrop, normalizedTool != .canvasCrop {
            canvasCropState.cancel()
        }
        performToolSelection(normalizedTool)
        if shouldRevealBrushLibrary {
            revealBrushLibraryPanel()
        }
    }

    func selectToolFromUI(_ tool: ToolKind, shortcutLabel: String? = nil) {
        let previousTool = workspace.toolSession.activeTool
        let requestedTool = Self.normalizedAvailableTool(tool)
        selectTool(requestedTool)
        let selectedTool = workspace.toolSession.activeTool
        if selectedTool == requestedTool,
           selectedTool != previousTool || shortcutLabel != nil {
            showToolSelectionStatus(for: requestedTool, shortcutLabel: shortcutLabel)
        }
    }

    private func showToolSelectionStatus(for tool: ToolKind, shortcutLabel: String? = nil) {
        let resolvedShortcutLabel = shortcutLabel
            ?? ToolSidebarGroup.group(containing: tool).map { shortcutSettings.shortcutDisplayTitle(for: $0) }
        showStatus(.init(
            kind: .info,
            message: "选择了\(tool.displayName)",
            shortcutLabel: resolvedShortcutLabel
        ))
    }

    private func nextSidebarGroupTool(_ group: ToolSidebarGroup) -> ToolKind {
        guard group.tools.count > 1 else {
            return displayedTool(for: group)
        }

        let current = displayedTool(for: group)
        let currentIndex = group.tools.firstIndex(of: current) ?? 0
        let nextIndex = (currentIndex + 1) % group.tools.count
        return group.tools[nextIndex]
    }

    private func performToolSelection(_ tool: ToolKind) {
        let tool = Self.normalizedAvailableTool(tool)
        let previousTool = workspace.toolSession.activeTool
        if tool == .eyedropper, previousTool != .eyedropper {
            previousToolBeforeEyedropper = previousTool
        } else if previousTool == .eyedropper, tool != .eyedropper {
            previousToolBeforeEyedropper = nil
        }
        if workspace.toolSession.activeTool != tool {
            resolveTransformSession(reason: .toolChange)
        }
        if tool != .brush, tool != .eraser {
            activeMaskEditingLayerID = nil
            lastLayerMaskStrokeSample = nil
        }
        if previousTool == .freeTransform, tool != .freeTransform, freeTransformUsesImplicitSelection {
            freeTransformUsesImplicitSelection = false
            implicitFreeTransformSelectionShape = nil
        }
        isGeneratorRegionSelectionArmed = false
        isGeneratorStrokeModeEnabled = false
        generatorStrokeSession = .init()
        activeLassoRawPoints = []
        activeLassoPreviewPoints = []
        lassoSamplingDebugPoints = []
        samePathCommittedDebugShape = nil
        samePathPreviewDebugShape = nil
        straightLineState = .init()
        linearGradientState = .init()
        sectorGradientState = .init()
        polygonSelectionState = .init()
        if tool == .canvasCrop {
            canvasCropState.cancel()
        }
        bootstrap.workspaceStore.updateToolSession { session in
            session.activeTool = tool
        }
        if previousTool == .perspective, tool != .perspective {
            lockPerspectiveGuideForPainting()
        } else if tool == .perspective {
            activatePerspectiveGuideForEditing()
        }
        if previousTool == .blockReference, tool != .blockReference {
            freezeBlockReferenceForPainting()
        } else if tool == .blockReference {
            activateBlockReferenceForEditing()
        }
        syncBrightnessAdjustmentHotkeyState(for: tool)
        if let group = ToolSidebarGroup.group(containing: tool) {
            toolGroupSurfaceTools[group.id] = tool
        }
        if tool == .freeTransform {
            primeWholeLayerFreeTransformIdleStateIfNeeded(for: bootstrap.workspaceStore.state)
        } else {
            setFreeTransformPreview(.identity)
        }
        refreshLightweight()
    }

    private func syncBrightnessAdjustmentHotkeyState(for activeTool: ToolKind? = nil) {
        let resolvedTool = activeTool ?? workspace.toolSession.activeTool
        colorAdjustmentAllowsIdleModeHotkeys =
            resolvedTool == .brightnessAdjust
            && brightnessAdjustmentEditorMode == .colorParameters
        curveAdjustmentAllowsIdleModeHotkeys =
            resolvedTool == .brightnessAdjust
            && brightnessAdjustmentEditorMode == .curves
    }

    private func revealBrushLibraryPanel() {
        brushLibraryRevealRequestID &+= 1
    }

    func presentNewCanvasSheet() {
        guard !isDocumentTransitionPending,
              canBeginDocumentPersistence(action: "新建画布") else { return }
        isNewCanvasSheetPresented = true
    }

    func dismissNewCanvasSheet() {
        isNewCanvasSheetPresented = false
    }

    var timelapseRecorder: TimelapseRecorderController {
        bootstrap.timelapseRecorder
    }

    var drawingStatsController: DrawingStatsController {
        bootstrap.drawingStatsController
    }

    var savedSnapshotCount: Int {
        savedSnapshots.count
    }

    var isSnapshotCompareActive: Bool {
        snapshotCompareSession != nil
    }

    func chooseTimelapseOutputDirectory(startAfterSelection: Bool = false) {
        guard !timelapseRecorder.isRecording, !timelapseRecorder.isBusy else {
            showStatus(.init(kind: .info, message: "请先停止录制并等待写入完成，再更换录像目录"))
            return
        }
        guard !isChoosingTimelapseDirectory else { return }
        isChoosingTimelapseDirectory = true
        bootstrap.filePanelService.presentDirectorySelectionPanel(
            title: "选择录像数据文件夹",
            prompt: "选择文件夹"
        ) { [weak self] url in
            guard let self else { return }
            self.isChoosingTimelapseDirectory = false
            guard let url else {
                self.showStatus(.init(kind: .info, message: "已取消选择录像目录"))
                return
            }
            self.timelapseRecorder.outputDirectory = url
            self.syncTimelapseDocumentContext()
            self.showStatus(.init(kind: .success, message: "已设置录像目录：\(url.lastPathComponent)"))
            if startAfterSelection && !self.timelapseRecorder.isRecording {
                self.toggleTimelapseRecording()
            }
        }
    }

    func toggleTimelapseRecording() {
        guard snapshotCompareSession == nil else {
            showStatus(.init(kind: .info, message: "快照对比期间录像已暂停"))
            return
        }
        guard ideationSession == nil else {
            showStatus(.init(kind: .info, message: "方案试探期间录像已暂停"))
            return
        }

        if timelapseRecorder.isRecording {
            _ = flushBrushEditingBoundary(reason: "stopTimelapse")
            timelapseRecorder.stopRecording(suppressAutoStart: true)
            showStatus(.init(kind: .info, message: timelapseRecorder.isBusy ? "已停止录制，正在保存最后画面" : "已停止录制"))
            return
        }

        if timelapseRecorder.outputDirectory == nil {
            chooseTimelapseOutputDirectory(startAfterSelection: true)
            return
        }

        do {
            _ = flushBrushEditingBoundary(reason: "startTimelapse")
            let sessionDirectory = try timelapseRecorder.startRecording(
                documentName: workspace.document.metadata.name,
                documentFileURL: currentProjectURL
            )
            showStatus(.init(kind: .success, message: "已开始录制：\(sessionDirectory.lastPathComponent)"))
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func exportTimelapseVideo(fps: Int) {
        syncTimelapseDocumentContext()
        guard timelapseRecorder.canExportVideo else {
            showStatus(.init(kind: .info, message: "当前没有可导出的视频帧"))
            return
        }

        let defaultName = "\(workspace.document.metadata.name)-timelapse"
        bootstrap.filePanelService.presentVideoExportPanel(defaultName: defaultName) { [weak self] outputURL in
            guard let self else { return }
            guard let outputURL else {
                self.showStatus(.init(kind: .info, message: "已取消导出视频"))
                return
            }
            self.timelapseRecorder.exportCurrentSessionVideo(
                to: outputURL,
                fps: fps,
                leadInSeconds: self.timelapseRecorder.exportLeadInSeconds,
                tailHoldSeconds: self.timelapseRecorder.exportTailHoldSeconds
            ) { [weak self] result in
                guard let self else { return }
                Task { @MainActor in
                    switch result {
                    case .success(let url):
                        self.showStatus(.init(kind: .success, message: "已导出视频：\(url.lastPathComponent)"))
                    case .failure(let error):
                        self.showStatus(.init(kind: .error, message: error.localizedDescription))
                    }
                }
            }
        }
    }

    func revealTimelapseSessionInFinder() {
        syncTimelapseDocumentContext()
        let session = timelapseRecorder.currentSessionDirectory
        let existingSession = session.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        guard let url = existingSession ?? timelapseRecorder.outputDirectory else {
            showStatus(.init(kind: .info, message: "当前还没有录像目录"))
            return
        }
        bootstrap.filePanelService.revealInFinder(url)
    }

    func openLastExportedTimelapseVideo() {
        guard let url = timelapseRecorder.lastExportedVideoURL else {
            showStatus(.init(kind: .info, message: "当前没有可打开的导出视频"))
            return
        }
        _ = bootstrap.filePanelService.openURL(url)
    }

    func displayedTool(for group: ToolSidebarGroup) -> ToolKind {
        toolGroupSurfaceTools[group.id] ?? group.defaultTool
    }

    func sidebarDisplayedTool(for group: ToolSidebarGroup) -> ToolKind {
        group.id == "lasso-fill" ? .lassoFill : displayedTool(for: group)
    }

    var lassoFillMode: LassoFillMode {
        workspace.toolSession.activeTool == .textureFill ? .texture : .color
    }

    func setLassoFillMode(_ mode: LassoFillMode) {
        guard workspace.toolSession.activeTool == .lassoFill
                || workspace.toolSession.activeTool == .textureFill else { return }
        let tool: ToolKind = mode == .texture ? .textureFill : .lassoFill
        guard workspace.toolSession.activeTool != tool else { return }
        selectToolFromUI(tool)
    }

    func isSelected(group: ToolSidebarGroup) -> Bool {
        group.contains(workspace.toolSession.activeTool)
    }

    func activateSidebarGroup(_ group: ToolSidebarGroup) {
        selectToolFromUI(displayedTool(for: group))
    }

    func cycleSidebarGroup(_ group: ToolSidebarGroup) {
        guard group.isGrouped else {
            activateSidebarGroup(group)
            return
        }
        selectToolFromUI(nextSidebarGroupTool(group))
    }

    func handleToolShortcutKey(_ key: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        let normalized = modifiers.intersection(.deviceIndependentFlagsMask)
        guard normalized.isDisjoint(with: [.command, .option, .control]) else { return false }
        guard let group = shortcutSettings.toolGroup(forShortcutKey: key) else { return false }
        let shortcutTitle = shortcutSettings.shortcutDisplayTitle(for: group)

        if normalized.contains(.shift), group.isGrouped {
            selectToolFromUI(nextSidebarGroupTool(group), shortcutLabel: "Shift+\(shortcutTitle)")
        } else {
            selectToolFromUI(displayedTool(for: group), shortcutLabel: shortcutTitle)
        }
        return true
    }

    var perspectiveGuide: PerspectiveGuideState? {
        workspace.document.perspectiveGuide
    }

    private func activatePerspectiveGuideForEditing() {
        selectedPerspectiveAnchorID = nil
        perspectiveGuideInteractionTarget = nil
        perspectiveGuideInteractionLastPoint = nil
        perspectiveGuideInteractionHasCheckpoint = false

        if bootstrap.workspaceStore.state.document.perspectiveGuide == nil {
            createPerspectiveGuide()
            return
        }

        var didChange = false
        bootstrap.workspaceStore.updateDocument { document in
            guard var guide = document.perspectiveGuide else { return }
            if !guide.isVisible {
                guide.isVisible = true
                didChange = true
            }
            if guide.isLocked {
                guide.isLocked = false
                didChange = true
            }
            document.perspectiveGuide = guide
        }
        if didChange {
            notePerspectiveGuideChanged()
        }
    }

    func createPerspectiveGuide() {
        guard perspectiveGuide == nil else { return }
        guard capturePerspectiveGuideCheckpoint(operationKind: "perspective.create") else { return }
        let canvasSize = bootstrap.workspaceStore.state.document.canvasSize
        bootstrap.workspaceStore.updateDocument { document in
            document.perspectiveGuide = .initial(canvasSize: canvasSize)
        }
        selectedPerspectiveAnchorID = nil
        notePerspectiveGuideChanged()
    }

    private func lockPerspectiveGuideForPainting() {
        perspectiveGuideMatchState.isActive = false
        perspectiveGuideMatchState.draftLine = nil
        selectedPerspectiveAnchorID = nil
        perspectiveGuideInteractionTarget = nil
        perspectiveGuideInteractionLastPoint = nil
        perspectiveGuideInteractionHasCheckpoint = false
        isAdjustingPerspectiveGuideStyle = false

        var didChange = false
        bootstrap.workspaceStore.updateDocument { document in
            guard var guide = document.perspectiveGuide, !guide.isLocked else { return }
            guide.isLocked = true
            document.perspectiveGuide = guide
            didChange = true
        }
        if didChange {
            notePerspectiveGuideChanged()
        }
    }

    func setPerspectiveGuideMode(_ mode: PerspectiveGuideMode) {
        guard var guide = perspectiveGuide, guide.mode != mode else { return }
        guard capturePerspectiveGuideCheckpoint(operationKind: "perspective.mode") else { return }
        guide.setMode(mode, canvasSize: workspace.document.canvasSize)
        replacePerspectiveGuide(guide)
    }

    func setPerspectiveVerticalDirection(_ direction: PerspectiveVerticalDirection) {
        guard var guide = perspectiveGuide, guide.verticalDirection != direction else { return }
        guard capturePerspectiveGuideCheckpoint(operationKind: "perspective.verticalDirection") else { return }
        guide.setVerticalDirection(direction, canvasSize: workspace.document.canvasSize)
        replacePerspectiveGuide(guide)
    }

    func setPerspectiveGuideVisibility(_ isVisible: Bool) {
        guard var guide = perspectiveGuide, guide.isVisible != isVisible else { return }
        guard capturePerspectiveGuideCheckpoint(operationKind: "perspective.visibility") else { return }
        guide.isVisible = isVisible
        replacePerspectiveGuide(guide)
    }

    func setPerspectiveGuideLocked(_ isLocked: Bool) {
        guard var guide = perspectiveGuide, guide.isLocked != isLocked else { return }
        guard capturePerspectiveGuideCheckpoint(operationKind: "perspective.lock") else { return }
        guide.isLocked = isLocked
        replacePerspectiveGuide(guide)
        if isLocked {
            perspectiveGuideInteractionTarget = nil
            perspectiveGuideInteractionLastPoint = nil
            perspectiveGuideInteractionHasCheckpoint = false
        }
    }

    func setPerspectiveGuideStyleEditing(_ isEditing: Bool) {
        if isEditing {
            guard !isAdjustingPerspectiveGuideStyle else { return }
            isAdjustingPerspectiveGuideStyle = capturePerspectiveGuideCheckpoint(
                operationKind: "perspective.style"
            )
        } else {
            isAdjustingPerspectiveGuideStyle = false
        }
    }

    func setPerspectiveGuideOpacity(_ opacity: Float) {
        guard var guide = perspectiveGuide else { return }
        let resolved = min(max(opacity, 0.05), 1)
        guard abs(guide.opacity - resolved) > 0.0001 else { return }
        guide.opacity = resolved
        replacePerspectiveGuide(guide)
    }

    func setPerspectiveGuideLineWidth(_ lineWidth: Float) {
        guard var guide = perspectiveGuide else { return }
        let resolved = min(max(lineWidth, 0.5), 4)
        guard abs(guide.lineWidth - resolved) > 0.0001 else { return }
        guide.lineWidth = resolved
        replacePerspectiveGuide(guide)
    }

    func setPerspectiveGuideColor(_ color: RGBAColor) {
        guard var guide = perspectiveGuide, guide.color != color else { return }
        guard capturePerspectiveGuideCheckpoint(operationKind: "perspective.color") else { return }
        guide.color = color.withAlpha(1)
        guide.normalizeStyle()
        replacePerspectiveGuide(guide)
    }

    func resetPerspectiveGuide() {
        guard perspectiveGuide != nil else { return }
        guard capturePerspectiveGuideCheckpoint(operationKind: "perspective.reset") else { return }
        replacePerspectiveGuide(.initial(canvasSize: workspace.document.canvasSize))
        selectedPerspectiveAnchorID = nil
    }

    func clearPerspectiveGuide() {
        guard perspectiveGuide != nil else { return }
        guard capturePerspectiveGuideCheckpoint(operationKind: "perspective.clear") else { return }
        selectedPerspectiveAnchorID = nil
        perspectiveGuideInteractionTarget = nil
        perspectiveGuideInteractionLastPoint = nil
        perspectiveGuideInteractionHasCheckpoint = false
        isAdjustingPerspectiveGuideStyle = false
        bootstrap.workspaceStore.updateDocument { document in
            document.perspectiveGuide = nil
        }
        notePerspectiveGuideChanged()
    }

    func deleteSelectedPerspectiveGuideAnchor() {
        guard let selectedPerspectiveAnchorID,
              var guide = perspectiveGuide,
              guide.anchors.contains(where: { $0.id == selectedPerspectiveAnchorID }) else { return }
        guard capturePerspectiveGuideCheckpoint(operationKind: "perspective.deleteAnchor") else { return }
        guide.anchors.removeAll { $0.id == selectedPerspectiveAnchorID }
        self.selectedPerspectiveAnchorID = nil
        replacePerspectiveGuide(guide)
    }

    func setSelectedPerspectiveAnchorConnection(
        _ isEnabled: Bool,
        role: PerspectiveVanishingPointRole
    ) {
        guard let selectedPerspectiveAnchorID,
              var guide = perspectiveGuide,
              let index = guide.anchors.firstIndex(where: { $0.id == selectedPerspectiveAnchorID }),
              guide.anchors[index].connects(to: role) != isEnabled else { return }
        guard capturePerspectiveGuideCheckpoint(operationKind: "perspective.anchorConnection") else { return }
        guide.anchors[index].setConnection(isEnabled, to: role)
        replacePerspectiveGuide(guide)
    }

    func beginPerspectiveGuideInteraction(at point: CanvasPoint, hitRadius: Double) {
        guard workspace.toolSession.activeTool == .perspective,
              var guide = perspectiveGuide,
              guide.isVisible,
              !guide.isLocked else { return }

        perspectiveGuideInteractionHasCheckpoint = false
        perspectiveGuideInteractionLastPoint = point

        if let target = perspectiveGuideHitTarget(
            state: guide,
            point: point,
            hitRadius: hitRadius,
            canvasSize: workspace.document.canvasSize
        ) {
            perspectiveGuideInteractionTarget = target
            if case .anchor(let anchorID) = target {
                selectedPerspectiveAnchorID = anchorID
            } else {
                selectedPerspectiveAnchorID = nil
            }
            return
        }

        guard point.x >= 0,
              point.y >= 0,
              point.x <= Double(workspace.document.canvasSize.width),
              point.y <= Double(workspace.document.canvasSize.height),
              capturePerspectiveGuideCheckpoint(operationKind: "perspective.addAnchor") else {
            perspectiveGuideInteractionTarget = nil
            perspectiveGuideInteractionLastPoint = nil
            return
        }

        let anchor = guide.makeAnchor(at: point)
        guide.anchors.append(anchor)
        perspectiveGuideInteractionTarget = .anchor(anchor.id)
        selectedPerspectiveAnchorID = anchor.id
        perspectiveGuideInteractionHasCheckpoint = true
        replacePerspectiveGuide(guide)
    }

    func updatePerspectiveGuideInteraction(to point: CanvasPoint) {
        guard let target = perspectiveGuideInteractionTarget,
              let lastPoint = perspectiveGuideInteractionLastPoint,
              var guide = perspectiveGuide else { return }
        let delta = CanvasPoint(x: point.x - lastPoint.x, y: point.y - lastPoint.y)
        guard abs(delta.x) > 0.0001 || abs(delta.y) > 0.0001 else { return }

        if !perspectiveGuideInteractionHasCheckpoint {
            guard capturePerspectiveGuideCheckpoint(operationKind: "perspective.moveControl") else { return }
            perspectiveGuideInteractionHasCheckpoint = true
        }

        switch target {
        case .vanishingPoint(let role):
            let current = guide.vanishingPoint(for: role)
            guide.setVanishingPoint(
                CanvasPoint(x: current.x + delta.x, y: current.y + delta.y),
                for: role
            )
        case .horizon:
            guide.leftVanishingPoint = CanvasPoint(
                x: guide.leftVanishingPoint.x + delta.x,
                y: guide.leftVanishingPoint.y + delta.y
            )
            if guide.mode != .onePoint {
                guide.rightVanishingPoint = CanvasPoint(
                    x: guide.rightVanishingPoint.x + delta.x,
                    y: guide.rightVanishingPoint.y + delta.y
                )
            }
        case .anchor(let anchorID):
            guard let index = guide.anchors.firstIndex(where: { $0.id == anchorID }) else { return }
            let current = guide.anchors[index].position
            guide.anchors[index].position = CanvasPoint(
                x: current.x + delta.x,
                y: current.y + delta.y
            )
        }

        perspectiveGuideInteractionLastPoint = point
        replacePerspectiveGuide(guide)
    }

    func endPerspectiveGuideInteraction() {
        perspectiveGuideInteractionTarget = nil
        perspectiveGuideInteractionLastPoint = nil
        perspectiveGuideInteractionHasCheckpoint = false
    }

    private func capturePerspectiveGuideCheckpoint(operationKind: String) -> Bool {
        checkpointHistoryIfPossible(
            operationKind: operationKind,
            captureMode: .workspaceOnly
        )
    }

    private func replacePerspectiveGuide(_ guide: PerspectiveGuideState) {
        var normalized = guide
        normalized.normalizeStyle()
        bootstrap.workspaceStore.updateDocument { document in
            document.perspectiveGuide = normalized
        }
        notePerspectiveGuideChanged()
    }

    /// Shared document bridge used by the 3D block-reference subsystem. Keeping
    /// the store mutation here avoids coupling block geometry code to AppBootstrap.
    func replacePerspectiveGuideFromBlockReference(_ guide: PerspectiveGuideState) {
        guard capturePerspectiveGuideCheckpoint(operationKind: "perspective.fromBlockCamera") else { return }
        replacePerspectiveGuide(guide)
    }

    @discardableResult
    func replacePerspectiveGuideFromMatch(_ guide: PerspectiveGuideState) -> Bool {
        guard capturePerspectiveGuideCheckpoint(operationKind: "perspective.match") else { return false }
        selectedPerspectiveAnchorID = nil
        replacePerspectiveGuide(guide)
        return true
    }

    private func notePerspectiveGuideChanged() {
        hasUnsavedChanges = true
        refreshPerspectiveGuideOnly()
    }

    @discardableResult
    func captureBlockReferenceHistoryCheckpoint(operationKind: String) -> Bool {
        checkpointHistoryIfPossible(
            operationKind: operationKind,
            captureMode: .workspaceOnly
        )
    }

    @discardableResult
    func updateBlockReferenceDocument(
        operationKind: String? = nil,
        normalizesScene: Bool = true,
        _ transform: (inout BlockReferenceScene?) -> Void
    ) -> Bool {
        if blockReferenceWorkflow.interactionPreview != nil, operationKind == nil {
            transform(&blockReferenceWorkflow.interactionPreview)
            if normalizesScene { blockReferenceWorkflow.interactionPreview?.normalize() }
            return true
        }
        var candidate = workspace.document.blockReferenceScene
            ?? (workspace.toolSession.activeTool == .blockReference ? .empty : nil)
        transform(&candidate)
        if normalizesScene { candidate?.normalize() }
        guard candidate != workspace.document.blockReferenceScene else { return true }
        if let operationKind,
           !captureBlockReferenceHistoryCheckpoint(operationKind: operationKind) {
            return false
        }
        bootstrap.workspaceStore.updateDocument { document in
            document.blockReferenceScene = candidate
        }
        hasUnsavedChanges = true
        refreshDocumentOverlayOnly()
        return true
    }

    /// Updates the global reusable module library without marking the current drawing dirty.
    func updateBlockReferenceModuleLibrary(
        _ transform: (inout BlockReferenceModuleLibraryState) -> Void
    ) {
        bootstrap.workspaceStore.updateBlockReferenceModuleLibrary { library in
            transform(&library)
            library.normalize()
        }
        persistBlockReferenceModuleLibrary()
        refreshLightweight(reason: "block-reference-module-library")
    }

    func setBrushSize(_ size: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.size = max(1, size)
        }
        refreshToolSessionOnly()
    }

    func adjustBrushSize(by delta: Float) {
        let currentSize = workspace.toolSession.brush.size
        let direction: Float = delta == 0 ? 0 : (delta > 0 ? 1 : -1)
        let step = BrushSizeShortcut.step(for: currentSize)
        setBrushSize(currentSize + (direction * step))
    }

    func setBrushOpacity(_ opacity: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.opacity = min(max(0, opacity), 1)
        }
        refreshToolSessionOnly()
    }

    func setBrushBuildMode(_ mode: BrushBuildMode) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.buildMode = mode
        }
        refreshToolSessionOnly()
    }

    func setBrushSpacingPercent(_ percent: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.quickSpacingPercent = min(max(percent, 1), 1_000)
        }
        refreshToolSessionOnly()
    }

    func setBrushScatterAmount(_ amount: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.scatterAmount = min(max(amount, 0), 5)
        }
        refreshToolSessionOnly()
    }

    func setBrushJitterAmount(_ amount: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.jitterAmount = min(max(amount, 0), 1)
        }
        refreshToolSessionOnly()
    }

    func setBrushSizeJitterAmount(_ amount: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.quickSizeJitterAmount = min(max(amount, 0), 1)
        }
        refreshToolSessionOnly()
    }

    func setBrushAngleJitterAmount(_ amount: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.angleJitterAmount = min(max(amount, 0), 1)
        }
        refreshToolSessionOnly()
    }

    func setBrushColorJitterAmount(_ amount: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.colorJitterAmount = min(max(amount, 0), 1)
        }
        refreshToolSessionOnly()
    }

    func setPaintJitterAmount(_ amount: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            let clamped = min(max(amount, 0), 1)
            if session.brush.compoundBrush.enabled {
                session.brush.compoundBrush.globalPaintJitterAmount = clamped
            } else {
                session.brush.paintJitterAmount = clamped
            }
            if clamped <= 0.001 {
                session.brush.oilPaint.isEnabled = false
            }
        }
        refreshToolSessionOnly()
    }

    func setOilPaintEnabled(_ enabled: Bool) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.oilPaint.isEnabled = enabled && session.brush.effectivePaintJitterAmount > 0.001
        }
        refreshToolSessionOnly()
    }

    func setOilPaintNewColorLoad(_ amount: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.oilPaint.newColorLoad = min(max(amount, 0), 1)
        }
        refreshToolSessionOnly()
    }

    func setOilPaintLightnessFollow(_ amount: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.oilPaint.lightnessFollow = min(max(amount, 0), 1)
        }
        refreshToolSessionOnly()
    }

    func setOilPaintOutputMode(_ mode: OilPaintOutputMode) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.oilPaintOutputMode = mode
        }
        refreshToolSessionOnly()
    }

    func setOilPaintPigmentBoundary(after componentIndex: Int, cumulativeWeight: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.oilPaintReservoir.setBoundary(
                after: componentIndex,
                cumulativeWeight: cumulativeWeight
            )
        }
        refreshToolSessionOnly()
    }

    func loadSelectedColorIntoOilPaintBrush() {
        var didLoad = false
        bootstrap.workspaceStore.updateToolSession { session in
            didLoad = session.loadSelectedColorIntoOilPaintReservoir()
        }
        refreshToolSessionOnly()
        guard didLoad else {
            showStatus(.init(kind: .info, message: "请先开启仿真油画笔并提高杂色"))
            return
        }
        let percentage = Int((workspace.toolSession.brush.oilPaint.newColorLoad * 100).rounded())
        showStatus(.init(kind: .success, message: "已按 \(percentage)% 装载当前颜色"))
    }

    func washOilPaintBrush() {
        bootstrap.workspaceStore.updateToolSession { session in
            session.washOilPaintReservoir()
        }
        refreshToolSessionOnly()
        showStatus(.init(kind: .success, message: "已洗净笔头并载入当前颜色"))
    }

    var oilPaintPigmentPreviewComponents: [BrushPigmentComponent] {
        workspace.toolSession.oilPaintReservoir.palette(
            lightnessFollow: workspace.toolSession.brush.oilPaint.lightnessFollow
        ).components
    }

    func setPaintContrastAmount(_ amount: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            let clamped = min(max(amount, 0), 1)
            if session.brush.compoundBrush.enabled {
                session.brush.compoundBrush.globalPaintContrastAmount = clamped
            } else {
                session.brush.paintContrastAmount = clamped
            }
        }
        refreshToolSessionOnly()
    }

    func setBrushStampRotationDegrees(_ angleDegrees: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            var normalized = angleDegrees.truncatingRemainder(dividingBy: 360)
            if normalized < 0 {
                normalized += 360
            }
            session.brush.stampRotationDegrees = normalized
        }
        refreshToolSessionOnly()
    }

    func setBrushFollowsStrokeDirection(_ follows: Bool) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.followsStrokeDirection = follows
        }
        refreshToolSessionOnly()
    }

    func setPressureSensitivity(_ amount: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.pressureSensitivity = min(max(amount, 0), 2)
        }
        refreshToolSessionOnly()
    }

    func setSizeLowerBound(_ amount: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.sizeLowerBound = min(max(amount, 0), 1)
        }
        refreshToolSessionOnly()
    }

    func setPressureSizeAmount(_ amount: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            let clamped = min(max(amount, 0), 1)
            if session.brush.compoundBrush.enabled {
                session.brush.compoundBrush.globalPressureSizeAmount = clamped
            } else {
                session.brush.pressureSizeAmount = clamped
            }
        }
        refreshToolSessionOnly()
    }

    func setPressureOpacityAmount(_ amount: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            let clamped = min(max(amount, 0), 1)
            if session.brush.compoundBrush.enabled {
                session.brush.compoundBrush.globalPressureOpacityAmount = clamped
            } else {
                session.brush.pressureOpacityAmount = clamped
            }
        }
        refreshToolSessionOnly()
    }

    func setBuildUpOpacityCompensationAmount(_ amount: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.buildUpOpacityCompensationAmount = min(max(amount, 0), 1)
        }
        refreshToolSessionOnly()
    }

    func setCompoundPrimaryPressureSizeAmount(_ amount: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.pressureSizeAmount = min(max(amount, 0), 1)
        }
        refreshToolSessionOnly()
    }

    func setCompoundPrimaryPressureOpacityAmount(_ amount: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.pressureOpacityAmount = min(max(amount, 0), 1)
        }
        refreshToolSessionOnly()
    }

    var displayedPressureSizeAmount: Float {
        let brush = workspace.toolSession.brush
        return brush.compoundBrush.enabled
            ? brush.compoundBrush.globalPressureSizeAmount
            : brush.pressureSizeAmount
    }

    var displayedPressureOpacityAmount: Float {
        let brush = workspace.toolSession.brush
        return brush.compoundBrush.enabled
            ? brush.compoundBrush.globalPressureOpacityAmount
            : brush.pressureOpacityAmount
    }

    var displayedBuildUpOpacityCompensationAmount: Float {
        workspace.toolSession.brush.buildUpOpacityCompensationAmount
    }

    var displayedPaintJitterAmount: Float {
        workspace.toolSession.brush.effectivePaintJitterAmount
    }

    var displayedPaintContrastAmount: Float {
        workspace.toolSession.brush.effectivePaintContrastAmount
    }

    var sizePressureCurveState: CurveChannelState {
        workspace.toolSession.brush.resolvedSizePressureCurveState
    }

    var opacityPressureCurveState: CurveChannelState {
        workspace.toolSession.brush.resolvedOpacityPressureCurveState
    }

    func setSizePressureCurveState(_ state: CurveChannelState) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.setSizePressureCurveState(state)
        }
        refreshToolSessionOnly()
    }

    func setOpacityPressureCurveState(_ state: CurveChannelState) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.setOpacityPressureCurveState(state)
        }
        refreshToolSessionOnly()
    }

    func setSizeCurveValues(low: Float, mid: Float, high: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.setLegacySizeCurveValues(low: low, mid: mid, high: high)
        }
        refreshToolSessionOnly()
    }

    func setSizeCurveLow(_ value: Float) {
        let brush = workspace.toolSession.brush
        setSizeCurveValues(low: value, mid: brush.sizeCurveMid, high: brush.sizeCurveHigh)
    }

    func setSizeCurveMid(_ value: Float) {
        let brush = workspace.toolSession.brush
        setSizeCurveValues(low: brush.sizeCurveLow, mid: value, high: brush.sizeCurveHigh)
    }

    func setSizeCurveHigh(_ value: Float) {
        let brush = workspace.toolSession.brush
        setSizeCurveValues(low: brush.sizeCurveLow, mid: brush.sizeCurveMid, high: value)
    }

    func setOpacityCurveValues(low: Float, mid: Float, high: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.setLegacyOpacityCurveValues(low: low, mid: mid, high: high)
        }
        refreshToolSessionOnly()
    }

    func setOpacityCurveLow(_ value: Float) {
        let brush = workspace.toolSession.brush
        setOpacityCurveValues(low: value, mid: brush.opacityCurveMid, high: brush.opacityCurveHigh)
    }

    func setOpacityCurveMid(_ value: Float) {
        let brush = workspace.toolSession.brush
        setOpacityCurveValues(low: brush.opacityCurveLow, mid: value, high: brush.opacityCurveHigh)
    }

    func setOpacityCurveHigh(_ value: Float) {
        let brush = workspace.toolSession.brush
        setOpacityCurveValues(low: brush.opacityCurveLow, mid: brush.opacityCurveMid, high: value)
    }

    func applyOpacityCurvePreset(_ preset: PressureCurvePreset) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.setOpacityPressureCurveState(preset.opacityCurveState)
        }
        refreshToolSessionOnly()
    }

    func resetOpacityCurveToDefault() {
        let defaults = BrushSettings.stageOneDefault
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.setOpacityPressureCurveState(defaults.resolvedOpacityPressureCurveState)
        }
        refreshToolSessionOnly()
    }

    func applySizeCurvePreset(_ preset: PressureCurvePreset) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.setSizePressureCurveState(preset.sizeCurveState)
        }
        refreshToolSessionOnly()
    }

    func resetSizeCurveToDefault() {
        let defaults = BrushSettings.stageOneDefault
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.setSizePressureCurveState(defaults.resolvedSizePressureCurveState)
        }
        refreshToolSessionOnly()
    }

    func setBrushTipShape(_ tipShape: BrushTipShape) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.tipShape = tipShape
        }
        notePrimaryBrushTipDefinitionChanged()
        refreshToolSessionOnly()
    }

    func reactivatePrimaryCustomTipSourceIfAvailable() {
        var didReactivate = false
        bootstrap.workspaceStore.updateToolSession { session in
            let hasDormantCustomTip =
                session.brush.customTipMaskData != nil ||
                (session.brush.customTipSourceSemantic == .importedImage && session.brush.customTipAssetID != nil)
            guard hasDormantCustomTip else { return }
            session.brush.tipShape = .customRound
            didReactivate = true
        }
        guard didReactivate else { return }
        notePrimaryBrushTipDefinitionChanged()
        refreshToolSessionOnly()
    }

    func setCustomTipSoftness(_ softness: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.customTipSoftness = min(max(softness, 0), 1)
        }
        notePrimaryBrushTipDefinitionChanged()
        refreshToolSessionOnly()
    }

    func setCustomTipRoundness(_ roundness: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.customTipRoundness = min(max(roundness, 0.25), 1)
        }
        notePrimaryBrushTipDefinitionChanged()
        refreshToolSessionOnly()
    }

    func setCustomTipAngleDegrees(_ angleDegrees: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            var normalized = angleDegrees.truncatingRemainder(dividingBy: 180)
            if normalized < 0 {
                normalized += 180
            }
            session.brush.customTipAngleDegrees = normalized
        }
        notePrimaryBrushTipDefinitionChanged()
        refreshToolSessionOnly()
    }

    func updateCustomTipMask(_ data: Data?) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.tipShape = .customRound
            session.brush.customTipSourceSemantic = data == nil ? .procedural : .customMask
            session.brush.customTipAssetID = nil
            session.brush.customTipImportedSourceInfo = nil
            session.brush.customTipMaskData = data
            session.brush.customTipEnvelopeMaskData = makeEnvelopeMaskData(from: data)
        }
        discardPendingBrushTipDraft()
        notePrimaryBrushTipDefinitionChanged()
        refreshToolSessionOnly()
    }

    func clearCustomTipMask() {
        updateCustomTipMask(nil)
    }

    func updateBrushTipDraft(_ data: Data?) {
        setBrushTipDraftSnapshot(
            BrushTipDraftSnapshot(
                maskData: data,
                sourceSemantic: data == nil ? .procedural : .customMask,
                assetID: nil,
                sourceInfo: nil
            )
        )
    }

    func clearBrushTipDraft() {
        updateBrushTipDraft(nil)
    }

    func undoBrushTipDraft() {
        let current = activeBrushTipDraftSnapshot
        guard let previous = brushTipDraftHistory.undo(current: current) else { return }
        restoreBrushTipDraftSnapshot(previous)
    }

    func redoBrushTipDraft() {
        let current = activeBrushTipDraftSnapshot
        guard let next = brushTipDraftHistory.redo(current: current) else { return }
        restoreBrushTipDraftSnapshot(next)
    }

    func discardBrushTipDraft() {
        discardPendingBrushTipDraft()
    }

    @discardableResult
    func applyBrushTipDraft() -> Bool {
        guard hasPendingBrushTipDraft, let draft = brushTipDraftSnapshot else { return false }
        if workspace.toolSession.activeTool != .brush {
            selectTool(.brush)
            guard bootstrap.workspaceStore.state.toolSession.activeTool == .brush else {
                showStatus(.init(kind: .info, message: "请先结束当前编辑，再应用笔尖"))
                return false
            }
        }
        var disabledCompoundBrush = false
        bootstrap.workspaceStore.updateToolSession { session in
            disabledCompoundBrush = session.brush.compoundBrush.enabled
            session.brush.compoundBrush.enabled = false
            session.brush.tipShape = .customRound
            session.brush.customTipSourceSemantic = draft.sourceSemantic
            session.brush.customTipAssetID = draft.assetID
            session.brush.customTipImportedSourceInfo = draft.sourceInfo
            session.brush.customTipMaskData = draft.maskData
            session.brush.customTipEnvelopeMaskData = makeEnvelopeMaskData(from: draft.maskData)
        }
        discardPendingBrushTipDraft()
        notePrimaryBrushTipDefinitionChanged()
        StageOneBrushPreviewRasterizer.resetCache()
        persistBrushLibrary()
        refreshToolSessionOnly()
        let message = disabledCompoundBrush
            ? "已应用新笔尖、关闭组合笔刷并切换到画笔"
            : "已应用新笔尖并切换到画笔"
        showStatus(.init(kind: .success, message: message))
        return true
    }

    func setCompoundBrushEnabled(_ enabled: Bool) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.setCompoundBrushEnabledUsingArtistDefault(enabled)
        }
        refreshToolSessionOnly()
    }

    func setCompoundBrushMode(_ mode: CompoundBrushMode) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.compoundBrush.mode = mode
        }
        refreshToolSessionOnly()
    }

    func restoreCompoundBrushEditingSnapshot(_ brush: BrushSettings) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush = brush
        }
        StageOneBrushPreviewRasterizer.resetCache()
        refreshToolSessionOnly()
    }

    func copyCompoundPrimaryTipToSecondary() {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.copyPrimaryTipToCompoundSecondary()
        }
        StageOneBrushPreviewRasterizer.resetCache()
        refreshToolSessionOnly()
    }

    func copyCompoundSecondaryTipToPrimary() {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.copyCompoundSecondaryTipToPrimary()
        }
        StageOneBrushPreviewRasterizer.resetCache()
        refreshToolSessionOnly()
    }

    func swapCompoundPrimaryAndSecondaryTips() {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.swapCompoundPrimaryAndSecondaryTips()
        }
        StageOneBrushPreviewRasterizer.resetCache()
        refreshToolSessionOnly()
    }

    func setCompoundSecondaryTipShape(_ tipShape: BrushTipShape) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.compoundBrush.secondary.tipShape = tipShape
            if tipShape != .customRound {
                session.brush.compoundBrush.secondary.sourceSemantic = .procedural
                session.brush.compoundBrush.secondary.tipAssetID = nil
                session.brush.compoundBrush.secondary.importedSourceInfo = nil
                session.brush.compoundBrush.secondary.customTipMaskData = nil
            }
        }
        refreshToolSessionOnly()
    }

    func setCompoundSecondaryTipSoftness(_ softness: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.compoundBrush.secondary.softness = min(max(softness, 0), 1)
        }
        refreshToolSessionOnly()
    }

    func setCompoundSecondaryTipRoundness(_ roundness: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.compoundBrush.secondary.roundness = min(max(roundness, 0.25), 1)
        }
        refreshToolSessionOnly()
    }

    func setCompoundSecondaryTipAngleDegrees(_ angle: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            var normalized = angle.truncatingRemainder(dividingBy: 180)
            if normalized < 0 {
                normalized += 180
            }
            session.brush.compoundBrush.secondary.angleDegrees = normalized
        }
        refreshToolSessionOnly()
    }

    func setCompoundSecondaryFollowsStrokeDirection(_ value: Bool) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.compoundBrush.secondary.followsStrokeDirection = value
        }
        refreshToolSessionOnly()
    }

    func updateCompoundSecondaryTipMask(_ data: Data?) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.compoundBrush.secondary.tipShape = .customRound
            session.brush.compoundBrush.secondary.sourceSemantic = data == nil ? .procedural : .customMask
            session.brush.compoundBrush.secondary.tipAssetID = nil
            session.brush.compoundBrush.secondary.importedSourceInfo = nil
            session.brush.compoundBrush.secondary.customTipMaskData = data
        }
        refreshToolSessionOnly()
    }

    func clearCompoundSecondaryTipMask() {
        updateCompoundSecondaryTipMask(nil)
    }

    func setCompoundSecondarySize(_ size: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.compoundBrush.secondary.size = min(max(size, 1), 512)
        }
        refreshToolSessionOnly()
    }

    func setCompoundSecondaryUsesRelativeSize(_ usesRelativeSize: Bool) {
        bootstrap.workspaceStore.updateToolSession { session in
            let primarySize = max(session.brush.size, 1)
            let resolvedCurrentSize = session.brush.compoundBrush.secondary.resolvedBaseSize(for: primarySize)
            session.brush.compoundBrush.secondary.sizeMode = usesRelativeSize ? .relativeToPrimary : .absolutePixels
            if usesRelativeSize {
                session.brush.compoundBrush.secondary.relativeSizeRatio = min(max(resolvedCurrentSize / primarySize, 0.05), 4.0)
            } else {
                session.brush.compoundBrush.secondary.size = min(max(resolvedCurrentSize, 1), 512)
            }
        }
        refreshToolSessionOnly()
    }

    func setCompoundSecondaryRelativeSizeRatio(_ ratio: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.compoundBrush.secondary.relativeSizeRatio = min(max(ratio, 0.05), 4.0)
        }
        refreshToolSessionOnly()
    }

    func setCompoundSecondarySpacingPercent(_ percent: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.compoundBrush.secondary.spacingPercent = min(max(percent, 1), 400)
        }
        refreshToolSessionOnly()
    }

    func setCompoundSecondaryPressureSizeAmount(_ amount: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.compoundBrush.secondary.pressureSizeAmount = min(max(amount, 0), 1)
        }
        refreshToolSessionOnly()
    }

    func setCompoundSecondaryPressureOpacityAmount(_ amount: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.compoundBrush.secondary.pressureOpacityAmount = min(max(amount, 0), 1)
        }
        refreshToolSessionOnly()
    }

    func setCompoundSecondaryTileRandomRotation(_ amount: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.compoundBrush.secondary.tileRandomRotation = min(max(amount, 0), 1)
        }
        refreshToolSessionOnly()
    }

    func setCompoundSecondarySizeCurve(low: Float, mid: Float, high: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.compoundBrush.secondary.sizeCurveLow = min(max(low, 0), 0.85)
            session.brush.compoundBrush.secondary.sizeCurveMid = min(max(mid, session.brush.compoundBrush.secondary.sizeCurveLow), 0.95)
            session.brush.compoundBrush.secondary.sizeCurveHigh = min(max(high, session.brush.compoundBrush.secondary.sizeCurveMid), 1)
        }
        refreshToolSessionOnly()
    }

    func setCompoundSecondaryOpacityCurve(low: Float, mid: Float, high: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.compoundBrush.secondary.opacityCurveLow = min(max(low, 0), 0.85)
            session.brush.compoundBrush.secondary.opacityCurveMid = min(max(mid, session.brush.compoundBrush.secondary.opacityCurveLow), 0.95)
            session.brush.compoundBrush.secondary.opacityCurveHigh = min(max(high, session.brush.compoundBrush.secondary.opacityCurveMid), 1)
            session.brush.compoundBrush.secondary.opacityPressureCurve = nil
        }
        refreshToolSessionOnly()
    }

    func setCompoundPrimaryMixAtLowPressure(_ value: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.compoundBrush.pressureMix.primaryAtLowPressure = min(max(value, 0), 1)
        }
        refreshToolSessionOnly()
    }

    func setCompoundPrimaryMixAtMidPressure(_ value: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.compoundBrush.pressureMix.primaryAtMidPressure = min(max(value, 0), 1)
        }
        refreshToolSessionOnly()
    }

    func setCompoundPrimaryMixAtHighPressure(_ value: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.compoundBrush.pressureMix.primaryAtHighPressure = min(max(value, 0), 1)
        }
        refreshToolSessionOnly()
    }

    func setCompoundPressureMix(_ settings: CompoundPressureMixSettings) {
        bootstrap.workspaceStore.updateToolSession { session in
            let low = min(max(settings.primaryAtLowPressure, 0), 1)
            let mid = min(max(settings.primaryAtMidPressure, 0), 1)
            let high = min(max(settings.primaryAtHighPressure, 0), 1)
            session.brush.compoundBrush.pressureMix = CompoundPressureMixSettings(
                primaryAtLowPressure: low,
                primaryAtMidPressure: mid,
                primaryAtHighPressure: high
            )
        }
        refreshToolSessionOnly()
    }

    func setBrushTipCanvasFocused(_ focused: Bool) {
        guard isBrushTipCanvasFocused != focused else { return }
        isBrushTipCanvasFocused = focused
        if focused {
            isColorBlocksPanelFocused = false
        }
    }

    func setBrushTipEditorVisible(_ visible: Bool) {
        guard isBrushTipEditorVisible != visible else { return }
        isBrushTipEditorVisible = visible
        if !visible {
            setBrushTipCanvasFocused(false)
        }
    }

    func setBrushTipEditorBrushSize(_ size: Float) {
        brushTipEditorBrushSize = min(max(size, 2), 128)
    }

    func adjustBrushTipEditorBrushSize(by delta: Float) {
        let direction: Float = delta == 0 ? 0 : (delta > 0 ? 1 : -1)
        let step = BrushSizeShortcut.step(for: brushTipEditorBrushSize)
        setBrushTipEditorBrushSize(brushTipEditorBrushSize + (direction * step))
    }

    func setColorBlocksPanelFocused(_ focused: Bool) {
        guard isColorBlocksPanelFocused != focused else { return }
        isColorBlocksPanelFocused = focused
        if focused {
            isBrushTipCanvasFocused = false
        }
    }

    func importBrushTipImageFromDisk() {
        selectBrushTipImageURLFromDisk { [weak self] url in
            if let url { _ = self?.importBrushTipImage(from: url) }
        }
    }

    private func documentScopedFileSelection<Value>(
        _ action: @escaping (WorkspaceViewModel, Value?) -> Void
    ) -> (Value?) -> Void {
        let generation = documentRenderGeneration
        return { [weak self] value in
            guard let self, self.documentRenderGeneration == generation else { return }
            action(self, value)
        }
    }

    func selectBrushTipImageURLFromDisk(completion: @escaping (URL?) -> Void) {
        bootstrap.filePanelService.presentImageOpenPanel(completion: documentScopedFileSelection { _, url in
            completion(url)
        })
    }

    func selectKritaBrushURLFromDisk(completion: @escaping (URL?) -> Void) {
        bootstrap.filePanelService.presentKritaBrushOpenPanel(completion: documentScopedFileSelection { _, url in
            completion(url)
        })
    }

    @discardableResult
    func importBrushTipImage(fromPasteboard pasteboard: NSPasteboard = .general) -> Bool {
        if let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage {
            return importBrushTipImage(from: image, sourceDescription: "剪贴板")
        }

        if let item = pasteboard.pasteboardItems?.first {
            for type in [NSPasteboard.PasteboardType.png, .tiff] {
                if let data = item.data(forType: type), let image = NSImage(data: data) {
                    return importBrushTipImage(from: image, sourceDescription: "剪贴板")
                }
            }
        }

        showStatus(.init(kind: .info, message: "剪贴板中没有可用图片"))
        return false
    }

    @discardableResult
    func importBrushTipImage(from url: URL) -> Bool {
        guard let image = NSImage(contentsOf: url) else {
            showStatus(.init(kind: .error, message: "无法读取图片"))
            return false
        }
        return importBrushTipImage(from: image, sourceDescription: url.deletingPathExtension().lastPathComponent)
    }

    @discardableResult
    func importBrushTipImage(from image: NSImage, sourceDescription: String = "图片") -> Bool {
        guard let importedTip = importTipImageLibraryItem(from: image, sourceDescription: sourceDescription) else {
            showStatus(.init(kind: .error, message: "无法将图片转换为笔尖"))
            return false
        }

        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.tipShape = .customRound
            session.brush.customTipSourceSemantic = .importedImage
            session.brush.customTipAssetID = importedTip.item.id
            session.brush.customTipImportedSourceInfo = importedTip.item.sourceInfo
            session.brush.customTipMaskData = importedTip.item.maskData
            session.brush.customTipEnvelopeMaskData = importedTip.envelopeMaskData
        }
        discardPendingBrushTipDraft()
        notePrimaryBrushTipDefinitionChanged()
        StageOneBrushPreviewRasterizer.resetCache()
        persistBrushLibrary()
        refresh()
        showStatus(.init(kind: .success, message: "已从\(sourceDescription)导入笔尖"))
        return true
    }

    func brushTipImportPreviewMask(
        from image: NSImage,
        options: BrushTipImageImportOptions
    ) -> Data? {
        makeBrushTipMaskPair(from: image, options: options)?.detail
    }

    @discardableResult
    func stageImportedBrushTipImage(
        _ image: NSImage,
        sourceDescription: String,
        options: BrushTipImageImportOptions
    ) -> Bool {
        guard let maskPair = makeBrushTipMaskPair(from: image, options: options) else {
            showStatus(.init(kind: .error, message: "当前设置无法生成有效笔尖"))
            return false
        }

        let sourceInfo = makeImportedTipSourceInfo(
            from: image,
            sourceDescription: sourceDescription
        )
        let item = upsertTipImageLibraryItem(maskData: maskPair.detail, sourceInfo: sourceInfo)
        setBrushTipDraftSnapshot(
            BrushTipDraftSnapshot(
                maskData: item.maskData,
                sourceSemantic: .importedImage,
                assetID: item.id,
                sourceInfo: item.sourceInfo
            )
        )
        persistBrushLibrary()
        refreshToolSessionOnly()
        showStatus(.init(kind: .success, message: "已载入笔尖草稿，确认后应用"))
        return true
    }

    func importCompoundSecondaryTipImageFromDisk() {
        bootstrap.filePanelService.presentImageOpenPanel(completion: documentScopedFileSelection { owner, url in
            if let url { _ = owner.importCompoundSecondaryTipImage(from: url) }
        })
    }

    @discardableResult
    func importCompoundSecondaryTipImage(from url: URL) -> Bool {
        guard let image = NSImage(contentsOf: url) else {
            showStatus(.init(kind: .error, message: "无法读取图片"))
            return false
        }
        return importCompoundSecondaryTipImage(from: image, sourceDescription: url.deletingPathExtension().lastPathComponent)
    }

    @discardableResult
    func importCompoundSecondaryTipImage(from image: NSImage, sourceDescription: String = "图片") -> Bool {
        guard let importedTip = importTipImageLibraryItem(from: image, sourceDescription: sourceDescription) else {
            showStatus(.init(kind: .error, message: "无法将图片转换为笔尖"))
            return false
        }

        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.compoundBrush.secondary.tipShape = .customRound
            session.brush.compoundBrush.secondary.sourceSemantic = .importedImage
            session.brush.compoundBrush.secondary.tipAssetID = importedTip.item.id
            session.brush.compoundBrush.secondary.importedSourceInfo = importedTip.item.sourceInfo
            session.brush.compoundBrush.secondary.customTipMaskData = importedTip.item.maskData
        }
        StageOneBrushPreviewRasterizer.resetCache()
        persistBrushLibrary()
        refresh()
        showStatus(.init(kind: .success, message: "已为组合笔刷次笔尖导入\(sourceDescription)"))
        return true
    }

    func importTipImageLibraryItemsFromDisk(completion: @escaping ([BrushTipImageAssetID]?) -> Void) {
        bootstrap.filePanelService.presentImageOpenPanelURLs(
            allowsMultipleSelection: true,
            completion: documentScopedFileSelection { owner, urls in
                guard let urls, !urls.isEmpty else { completion(nil); return }
                completion(owner.importTipImageLibraryItems(from: urls))
            }
        )
    }

    @discardableResult
    func importTipImageLibraryItems(from urls: [URL]) -> [BrushTipImageAssetID] {
        var importedItems: [ImportedTipPayload] = []
        var failedCount = 0

        for url in urls {
            guard let image = NSImage(contentsOf: url),
                  let item = importTipImageLibraryItem(
                    from: image,
                    sourceDescription: url.deletingPathExtension().lastPathComponent
                  ) else {
                failedCount += 1
                continue
            }
            importedItems.append(item)
        }

        guard importedItems.isEmpty == false else {
            let message = urls.count == 1 ? "无法导入所选图片" : "所选图片都无法导入到资料库"
            showStatus(.init(kind: .error, message: message))
            return []
        }

        StageOneBrushPreviewRasterizer.resetCache()
        persistBrushLibrary()
        refresh()

        let successCount = importedItems.count
        let message: String
        if failedCount == 0 {
            message = successCount == 1 ? "已导入 1 张笔尖图片" : "已导入 \(successCount) 张笔尖图片"
            showStatus(.init(kind: .success, message: message))
        } else {
            message = "已导入 \(successCount) 张笔尖图片，\(failedCount) 张失败"
            showStatus(.init(kind: .info, message: message))
        }

        return importedItems.map(\.item.id)
    }

    private struct ImportedTipPayload {
        let item: TipImageLibraryItem
        let envelopeMaskData: Data
    }

    private func makeBrushTipMaskData(from image: NSImage) -> Data? {
        makeBrushTipMaskPair(from: image)?.detail
    }

    private func makeBrushTipMaskPair(from image: NSImage) -> (detail: Data, envelope: Data)? {
        makeBrushTipMaskPair(from: image, options: BrushTipImageImportOptions())
    }

    private func makeBrushTipMaskPair(
        from image: NSImage,
        options: BrushTipImageImportOptions
    ) -> (detail: Data, envelope: Data)? {
        guard
            let source = extractedMaskBytes(from: image, options: options)
        else {
            return nil
        }

        let cropped: (bytes: [UInt8], width: Int, height: Int)
        if options.cropsToContent,
           let detectedBounds = contentBoundsIgnoringThinGuides(
               mask: source.bytes,
               width: source.width,
               height: source.height
           ) {
            let expandedBounds = detectedBounds.insetBy(
                dx: -CGFloat(Self.brushTipCanonicalPadding),
                dy: -CGFloat(Self.brushTipCanonicalPadding)
            )
            cropped = cropMaskBytes(
                source.bytes,
                width: source.width,
                height: source.height,
                bounds: expandedBounds
            )
        } else {
            cropped = source
        }

        guard let detail = resampledSquareMaskData(
            from: cropped.bytes,
            width: cropped.width,
            height: cropped.height,
            targetResolution: Self.brushTipMaskResolution
        ) else {
            return nil
        }
        guard let envelope = makeEnvelopeMaskData(from: detail) else {
            return nil
        }
        return (detail: detail, envelope: envelope)
    }

    private func resolvedToolSessionForCanvasStrokes() -> ToolSessionState {
        return bootstrap.workspaceStore.state.toolSession
    }

    var colorAdjustmentRenderer: ColorAdjustmentRenderer {
        bootstrap.colorAdjustmentRenderer
    }

    var curveAdjustmentRenderer: CurveAdjustmentRenderer {
        bootstrap.curveAdjustmentRenderer
    }

    var colorAdjustmentStrokeEngine: MetalStrokeEngine {
        bootstrap.strokeEngine
    }

    func activeEditableAdjustmentLayerContext() -> PreparedAdjustmentLayerContext? {
        guard
            let layerID = bootstrap.interactionController.activeEditableLayerID(),
            let surfaceID = layerSurfaceStore.surfaceID(for: layerID),
            let texture = layerSurfaceStore.texture(for: surfaceID)
        else {
            return nil
        }

        return PreparedAdjustmentLayerContext(
            layerID: layerID,
            sourceTexture: texture
        )
    }

    func preparedEditableAdjustmentLayerContext(reason: String) -> PreparedAdjustmentLayerContext? {
        _ = flushBrushEditingBoundary(reason: reason)
        return activeEditableAdjustmentLayerContext()
    }

    func activeEditableLayerIDForColorAdjustment() -> LayerID? {
        activeEditableAdjustmentLayerContext()?.layerID
    }

    func activeEditableLayerIDForCurveAdjustment() -> LayerID? {
        activeEditableLayerIDForColorAdjustment()
    }

    func selectionMaskBytesForColorAdjustment(
        shape: SelectionShape?,
        canvasSize: CanvasSize
    ) -> [UInt8] {
        selectionMaskBytes(for: shape, canvasSize: canvasSize)
    }

    func selectionMaskBytesForCurveAdjustment(
        shape: SelectionShape?,
        canvasSize: CanvasSize
    ) -> [UInt8] {
        selectionMaskBytes(for: shape, canvasSize: canvasSize)
    }

    func activeEditableLayerEffectBoundsForColorAdjustment() -> CanvasRect? {
        guard let layerID = activeEditableLayerIDForColorAdjustment(),
              let surfaceID = layerSurfaceStore.surfaceID(for: layerID) else {
            return nil
        }

        let key = WholeLayerInteractionBoundsKey(
            surfaceID: surfaceID,
            canvasContentRevision: canvasContentRevision
        )
        if wholeLayerInteractionBoundsCacheKey == key,
           case .ready(let bounds) = wholeLayerInteractionBoundsCacheEntry {
            return bounds
        }

        guard let texture = layerSurfaceStore.texture(for: surfaceID),
              let detected = try? bootstrap.layerContentBoundsDetector.detect(
                texture: texture,
                commandQueue: bootstrap.metalContext.commandQueue
              ) else {
            return nil
        }

        let entry = Self.wholeLayerInteractionBounds(from: detected)
        wholeLayerInteractionBoundsCacheKey = key
        wholeLayerInteractionBoundsCacheEntry = entry
        switch entry {
        case .ready(let bounds):
            return bounds
        case .empty:
            return nil
        }
    }

    func activeEditableLayerEffectBoundsForCurveAdjustment() -> CanvasRect? {
        activeEditableLayerEffectBoundsForColorAdjustment()
    }

    private func discardPendingBrushTipDraft() {
        brushTipDraftSnapshot = nil
        brushTipDraftMaskData = nil
        hasPendingBrushTipDraft = false
        brushTipDraftHistory.reset()
        syncBrushTipDraftHistoryAvailability()
    }

    private var committedBrushTipSnapshot: BrushTipDraftSnapshot {
        let brush = workspace.toolSession.brush
        return BrushTipDraftSnapshot(
            maskData: brush.customTipMaskData,
            sourceSemantic: effectiveBrushTipSourceSemantic(for: brush),
            assetID: brush.customTipAssetID,
            sourceInfo: brush.customTipImportedSourceInfo
        )
    }

    private var activeBrushTipDraftSnapshot: BrushTipDraftSnapshot {
        brushTipDraftSnapshot ?? committedBrushTipSnapshot
    }

    private func effectiveBrushTipSourceSemantic(for brush: BrushSettings) -> TipSourceSemantic {
        if brush.customTipMaskData == nil {
            return .procedural
        }
        return brush.customTipSourceSemantic
    }

    private func setBrushTipDraftSnapshot(_ snapshot: BrushTipDraftSnapshot) {
        let current = activeBrushTipDraftSnapshot
        guard current != snapshot else { return }
        brushTipDraftHistory.record(current: current, next: snapshot)
        restoreBrushTipDraftSnapshot(snapshot)
    }

    private func restoreBrushTipDraftSnapshot(_ snapshot: BrushTipDraftSnapshot) {
        let baseline = committedBrushTipSnapshot
        if snapshot == baseline {
            brushTipDraftSnapshot = nil
            brushTipDraftMaskData = nil
            hasPendingBrushTipDraft = false
        } else {
            brushTipDraftSnapshot = snapshot
            brushTipDraftMaskData = snapshot.maskData
            hasPendingBrushTipDraft = true
        }
        syncBrushTipDraftHistoryAvailability()
        StageOneBrushPreviewRasterizer.resetCache()
    }

    private func syncBrushTipDraftHistoryAvailability() {
        canUndoBrushTipDraft = brushTipDraftHistory.canUndo
        canRedoBrushTipDraft = brushTipDraftHistory.canRedo
    }

    private func extractedMaskBytes(
        from image: NSImage,
        options: BrushTipImageImportOptions = BrushTipImageImportOptions()
    ) -> (bytes: [UInt8], width: Int, height: Int)? {
        guard
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else {
            return nil
        }

        let width = max(cgImage.width, 1)
        let height = max(cgImage.height, 1)
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var rgba = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        guard let context = CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var darknessMask = [UInt8](repeating: 0, count: width * height)
        var alphaMask = [UInt8](repeating: 0, count: width * height)
        var darknessMass = 0.0
        var alphaMass = 0.0
        var hasMeaningfulTransparency = false
        for index in 0..<(width * height) {
            let offset = index * bytesPerPixel
            let red = Double(rgba[offset])
            let green = Double(rgba[offset + 1])
            let blue = Double(rgba[offset + 2])
            let alpha = Double(rgba[offset + 3]) / 255.0
            let luminance = (0.299 * red) + (0.587 * green) + (0.114 * blue)
            let darkness = (255.0 - luminance) * alpha
            let darknessByte = UInt8(clamping: Int(darkness.rounded()))
            let alphaByte = rgba[offset + 3]
            darknessMask[index] = darknessByte
            alphaMask[index] = alphaByte
            darknessMass += Double(darknessByte)
            alphaMass += Double(alphaByte)
            hasMeaningfulTransparency = hasMeaningfulTransparency || alphaByte < 250
        }

        let interpretation: BrushTipImageInterpretation
        switch options.interpretation {
        case .automatic:
            interpretation = hasMeaningfulTransparency && darknessMass < alphaMass * 0.35
                ? .alpha
                : .luminance
        case .luminance, .alpha:
            interpretation = options.interpretation
        }

        var mask = interpretation == .alpha ? alphaMask : darknessMask
        if options.isInverted {
            for index in mask.indices {
                let alpha = alphaMask[index]
                if interpretation == .luminance {
                    mask[index] = UInt8(clamping: max(0, Int(alpha) - Int(mask[index])))
                } else {
                    mask[index] = 255 - mask[index]
                }
            }
        }
        if options.usesThreshold {
            let threshold = UInt8(clamping: Int((min(max(options.threshold, 0), 1) * 255).rounded()))
            for index in mask.indices {
                mask[index] = mask[index] >= threshold ? 255 : 0
            }
        }

        return (mask, width, height)
    }

    private func extractedMaskBytes(from snapshot: LayerTextureSnapshot) -> (bytes: [UInt8], width: Int, height: Int)? {
        let width = snapshot.width
        let height = snapshot.height
        guard
            width > 0,
            height > 0,
            snapshot.bytesPerRow >= width * 4,
            snapshot.pixelData.count >= snapshot.bytesPerRow * height
        else {
            return nil
        }

        var mask = [UInt8](repeating: 0, count: width * height)
        snapshot.pixelData.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for y in 0..<height {
                let rowOffset = y * snapshot.bytesPerRow
                let maskRowOffset = y * width
                for x in 0..<width {
                    let offset = rowOffset + (x * 4)
                    let blue = Double(bytes[offset])
                    let green = Double(bytes[offset + 1])
                    let red = Double(bytes[offset + 2])
                    let alpha = Double(bytes[offset + 3]) / 255.0
                    let luminance = (0.299 * red) + (0.587 * green) + (0.114 * blue)
                    let darkness = (255.0 - luminance) * alpha
                    mask[maskRowOffset + x] = UInt8(clamping: Int(darkness.rounded()))
                }
            }
        }

        return (mask, width, height)
    }

    private func contentBoundsIgnoringThinGuides(
        mask: [UInt8],
        width: Int,
        height: Int
    ) -> CGRect? {
        guard
            width > 0,
            height > 0,
            mask.count == width * height
        else {
            return nil
        }

        var rowMass = [Double](repeating: 0, count: height)
        var colMass = [Double](repeating: 0, count: width)

        for y in 0..<height {
            let rowOffset = y * width
            for x in 0..<width {
                let value = Double(mask[rowOffset + x])
                rowMass[y] += value
                colMass[x] += value
            }
        }

        guard
            let maxRowMass = rowMass.max(), maxRowMass > 0,
            let maxColMass = colMass.max(), maxColMass > 0
        else {
            return nil
        }

        let rowThreshold = maxRowMass * Self.brushTipGuideMassThresholdFraction
        let colThreshold = maxColMass * Self.brushTipGuideMassThresholdFraction

        guard
            let rowRange = dominantMassRun(in: rowMass, threshold: rowThreshold),
            let colRange = dominantMassRun(in: colMass, threshold: colThreshold)
        else {
            return nil
        }

        return CGRect(
            x: colRange.lowerBound,
            y: rowRange.lowerBound,
            width: colRange.upperBound - colRange.lowerBound + 1,
            height: rowRange.upperBound - rowRange.lowerBound + 1
        )
    }

    private func dominantMassRun(in masses: [Double], threshold: Double) -> ClosedRange<Int>? {
        var bestRange: ClosedRange<Int>?
        var bestLength = 0
        var bestMass = 0.0
        var index = 0

        while index < masses.count {
            guard masses[index] > threshold else {
                index += 1
                continue
            }

            let start = index
            var totalMass = 0.0
            while index < masses.count, masses[index] > threshold {
                totalMass += masses[index]
                index += 1
            }

            let end = index - 1
            let length = end - start + 1
            if length > bestLength || (length == bestLength && totalMass > bestMass) {
                bestRange = start...end
                bestLength = length
                bestMass = totalMass
            }
        }

        return bestRange
    }

    private func cropMaskBytes(
        _ bytes: [UInt8],
        width: Int,
        height: Int,
        bounds: CGRect
    ) -> (bytes: [UInt8], width: Int, height: Int) {
        guard width > 0, height > 0 else {
            return (bytes, width, height)
        }

        let minX = max(0, Int(floor(bounds.minX)))
        let minY = max(0, Int(floor(bounds.minY)))
        let maxX = min(width - 1, Int(ceil(bounds.maxX)) - 1)
        let maxY = min(height - 1, Int(ceil(bounds.maxY)) - 1)
        guard maxX >= minX, maxY >= minY else {
            return (bytes, width, height)
        }
        let croppedWidth = maxX - minX + 1
        let croppedHeight = maxY - minY + 1
        var cropped = [UInt8](repeating: 0, count: croppedWidth * croppedHeight)

        for y in 0..<croppedHeight {
            let sourceOffset = (minY + y) * width
            let destinationOffset = y * croppedWidth
            for x in 0..<croppedWidth {
                cropped[destinationOffset + x] = bytes[sourceOffset + minX + x]
            }
        }

        return (cropped, croppedWidth, croppedHeight)
    }

    private func resampledSquareMaskData(
        from bytes: [UInt8],
        width: Int,
        height: Int,
        targetResolution: Int
    ) -> Data? {
        guard width > 0, height > 0, targetResolution > 0 else {
            return nil
        }

        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
            let provider = CGDataProvider(data: Data(bytes) as CFData),
            let sourceImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
        else {
            return nil
        }

        let scale = min(Double(targetResolution) / Double(width), Double(targetResolution) / Double(height))
        let drawWidth = max(1, min(targetResolution, Int(round(Double(width) * scale))))
        let drawHeight = max(1, min(targetResolution, Int(round(Double(height) * scale))))
        let offsetX = (targetResolution - drawWidth) / 2
        let offsetY = (targetResolution - drawHeight) / 2
        var destination = [UInt8](repeating: 0, count: targetResolution * targetResolution)

        guard let context = CGContext(
            data: &destination,
            width: targetResolution,
            height: targetResolution,
            bitsPerComponent: 8,
            bytesPerRow: targetResolution,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: targetResolution, height: targetResolution))
        context.interpolationQuality = .high
        context.draw(
            sourceImage,
            in: CGRect(x: offsetX, y: offsetY, width: drawWidth, height: drawHeight)
        )

        return Data(destination)
    }

    private func makeEnvelopeMaskData(from detailMaskData: Data?) -> Data? {
        guard let detailMaskData else { return nil }
        let resolution = Self.brushTipMaskResolution
        let detailBytes = [UInt8](detailMaskData)
        guard detailBytes.count == resolution * resolution else {
            return nil
        }

        var binary = detailBytes.map { $0 > Self.brushTipMaskThreshold ? UInt8(255) : 0 }
        for _ in 0..<Self.brushTipEnvelopeDilationPasses {
            binary = dilatedMask(binary, resolution: resolution)
        }
        for _ in 0..<Self.brushTipEnvelopeErosionPasses {
            binary = erodedMask(binary, resolution: resolution)
        }
        return Data(boxBlurredMask(binary, resolution: resolution))
    }

    private func dilatedMask(_ bytes: [UInt8], resolution: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: bytes.count)
        for y in 0..<resolution {
            for x in 0..<resolution {
                var value: UInt8 = 0
                for sampleY in max(0, y - 1)...min(resolution - 1, y + 1) {
                    for sampleX in max(0, x - 1)...min(resolution - 1, x + 1) {
                        value = max(value, bytes[(sampleY * resolution) + sampleX])
                    }
                }
                result[(y * resolution) + x] = value
            }
        }
        return result
    }

    private func erodedMask(_ bytes: [UInt8], resolution: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: bytes.count)
        for y in 0..<resolution {
            for x in 0..<resolution {
                var value: UInt8 = 255
                for sampleY in max(0, y - 1)...min(resolution - 1, y + 1) {
                    for sampleX in max(0, x - 1)...min(resolution - 1, x + 1) {
                        value = min(value, bytes[(sampleY * resolution) + sampleX])
                    }
                }
                result[(y * resolution) + x] = value
            }
        }
        return result
    }

    private func boxBlurredMask(_ bytes: [UInt8], resolution: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: bytes.count)
        for y in 0..<resolution {
            for x in 0..<resolution {
                var total = 0
                var count = 0
                for sampleY in max(0, y - 1)...min(resolution - 1, y + 1) {
                    for sampleX in max(0, x - 1)...min(resolution - 1, x + 1) {
                        total += Int(bytes[(sampleY * resolution) + sampleX])
                        count += 1
                    }
                }
                result[(y * resolution) + x] = UInt8(clamping: Int(round(Double(total) / Double(max(count, 1)))))
            }
        }
        return result
    }

    private func canonicalMaskFingerprint(_ maskData: Data) -> BrushTipImageAssetID {
        BrushTipImageAssetID(maskData: maskData)
    }

    private func makeImportedTipSourceInfo(from image: NSImage, sourceDescription: String) -> ImportedTipSourceInfo {
        let pixelSize = resolvedPixelSize(for: image)
        return ImportedTipSourceInfo(
            sourceLabel: sourceDescription,
            pixelWidth: pixelSize.width,
            pixelHeight: pixelSize.height
        )
    }

    private func resolvedPixelSize(for image: NSImage) -> (width: Int, height: Int) {
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return (max(cgImage.width, 1), max(cgImage.height, 1))
        }

        if let representation = image.representations.first {
            return (max(representation.pixelsWide, 1), max(representation.pixelsHigh, 1))
        }

        return (
            max(Int(image.size.width.rounded()), 1),
            max(Int(image.size.height.rounded()), 1)
        )
    }

    private func importTipImageLibraryItem(
        from image: NSImage,
        sourceDescription: String
    ) -> ImportedTipPayload? {
        guard let maskPair = makeBrushTipMaskPair(from: image) else {
            return nil
        }
        let importedSourceInfo = makeImportedTipSourceInfo(from: image, sourceDescription: sourceDescription)
        let item = upsertTipImageLibraryItem(maskData: maskPair.detail, sourceInfo: importedSourceInfo)
        return ImportedTipPayload(item: item, envelopeMaskData: maskPair.envelope)
    }

    @discardableResult
    private func upsertTipImageLibraryItem(
        maskData: Data,
        sourceInfo: ImportedTipSourceInfo
    ) -> TipImageLibraryItem {
        let assetID = canonicalMaskFingerprint(maskData)
        var resolvedItem = TipImageLibraryItem(
            id: assetID,
            sourceInfo: sourceInfo,
            maskData: maskData
        )

        bootstrap.workspaceStore.updateTipImageLibrary { library in
            resolvedItem = library.upsertImportedItem(
                id: assetID,
                sourceInfo: sourceInfo,
                maskData: maskData
            )
        }

        return resolvedItem
    }

    func applyPrimaryTipImageLibraryItem(_ assetID: BrushTipImageAssetID) {
        guard let item = bootstrap.workspaceStore.state.tipImageLibrary.item(id: assetID),
              let maskData = item.maskData else {
            showStatus(.init(kind: .error, message: "无法读取该笔尖图片"))
            return
        }

        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.tipShape = .customRound
            session.brush.customTipSourceSemantic = .importedImage
            session.brush.customTipAssetID = item.id
            session.brush.customTipImportedSourceInfo = item.sourceInfo
            session.brush.customTipMaskData = maskData
            session.brush.customTipEnvelopeMaskData = makeEnvelopeMaskData(from: maskData)
        }
        discardPendingBrushTipDraft()
        notePrimaryBrushTipDefinitionChanged()
        StageOneBrushPreviewRasterizer.resetCache()
        refresh()
        showStatus(.init(kind: .success, message: "已应用共享笔尖图片"))
    }

    /// Resolves a library tip into an isolated brush draft without changing the
    /// active tool session. Compound-brush editing uses this to keep Cancel truly
    /// side-effect free.
    func brushDraft(
        _ source: BrushSettings,
        applyingPrimaryTipImageLibraryItem assetID: BrushTipImageAssetID
    ) -> BrushSettings? {
        guard let item = bootstrap.workspaceStore.state.tipImageLibrary.item(id: assetID),
              let maskData = item.maskData else {
            return nil
        }
        var brush = source
        brush.tipShape = .customRound
        brush.customTipSourceSemantic = .importedImage
        brush.customTipAssetID = item.id
        brush.customTipImportedSourceInfo = item.sourceInfo
        brush.customTipMaskData = maskData
        brush.customTipEnvelopeMaskData = makeEnvelopeMaskData(from: maskData)
        return brush
    }

    func applyCompoundSecondaryTipImageLibraryItem(_ assetID: BrushTipImageAssetID) {
        guard let item = bootstrap.workspaceStore.state.tipImageLibrary.item(id: assetID),
              let maskData = item.maskData else {
            showStatus(.init(kind: .error, message: "无法读取该笔尖图片"))
            return
        }

        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.compoundBrush.secondary.tipShape = .customRound
            session.brush.compoundBrush.secondary.sourceSemantic = .importedImage
            session.brush.compoundBrush.secondary.tipAssetID = item.id
            session.brush.compoundBrush.secondary.importedSourceInfo = item.sourceInfo
            session.brush.compoundBrush.secondary.customTipMaskData = maskData
        }
        StageOneBrushPreviewRasterizer.resetCache()
        refresh()
        showStatus(.init(kind: .success, message: "已应用组合笔刷次笔尖"))
    }

    func brushDraft(
        _ source: BrushSettings,
        applyingCompoundSecondaryTipImageLibraryItem assetID: BrushTipImageAssetID
    ) -> BrushSettings? {
        guard let item = bootstrap.workspaceStore.state.tipImageLibrary.item(id: assetID),
              let maskData = item.maskData else {
            return nil
        }
        var brush = source
        brush.compoundBrush.secondary.tipShape = .customRound
        brush.compoundBrush.secondary.sourceSemantic = .importedImage
        brush.compoundBrush.secondary.tipAssetID = item.id
        brush.compoundBrush.secondary.importedSourceInfo = item.sourceInfo
        brush.compoundBrush.secondary.customTipMaskData = maskData
        return brush
    }

    func brushDraft(
        _ source: BrushSettings,
        applyingCompoundPrimaryTipImageLibraryItem assetID: BrushTipImageAssetID
    ) -> BrushSettings? {
        guard let item = bootstrap.workspaceStore.state.tipImageLibrary.item(id: assetID),
              let maskData = item.maskData else {
            return nil
        }
        var brush = source
        brush.materializeCompoundPrimaryTipIfNeeded()
        brush.compoundBrush.primary?.tipShape = .customRound
        brush.compoundBrush.primary?.sourceSemantic = .importedImage
        brush.compoundBrush.primary?.tipAssetID = item.id
        brush.compoundBrush.primary?.importedSourceInfo = item.sourceInfo
        brush.compoundBrush.primary?.customTipMaskData = maskData
        return brush
    }

    func applyTextureFillTipImageLibraryItem(_ assetID: BrushTipImageAssetID) {
        guard let item = bootstrap.workspaceStore.state.tipImageLibrary.item(id: assetID),
              let maskData = item.maskData else {
            showStatus(.init(kind: .error, message: "无法读取该笔尖图片"))
            return
        }

        bootstrap.workspaceStore.updateToolSession { session in
            session.textureFillTip.sourceSemantic = .importedImage
            session.textureFillTip.tipAssetID = item.id
            session.textureFillTip.importedSourceInfo = item.sourceInfo
            session.textureFillTip.customTipMaskData = maskData
            session.textureFillBrushOverride = nil
        }
        refresh()
        if workspace.toolSession.activeTool == .colorVitalization {
            refreshColorVitalizationMaterialFromCurrentTexture()
        }
        showStatus(.init(kind: .success, message: "已应用纹理填充素材"))
    }

    func resetTextureFillTipToProcedural() {
        bootstrap.workspaceStore.updateToolSession { session in
            let arrangement = session.textureFillTip.arrangement
            let scale = session.textureFillTip.materialScale
            let coverage = session.textureFillTip.coverage
            let variation = session.textureFillTip.variation
            let paintJitterAmount = session.textureFillTip.paintJitterAmount
            session.textureFillTip = .proceduralDefault
            session.textureFillTip.arrangement = arrangement
            session.textureFillTip.materialScale = scale
            session.textureFillTip.coverage = coverage
            session.textureFillTip.variation = variation
            session.textureFillTip.paintJitterAmount = paintJitterAmount
            session.textureFillBrushOverride = nil
        }
        refresh()
        if workspace.toolSession.activeTool == .colorVitalization {
            refreshColorVitalizationMaterialFromCurrentTexture()
        }
        showStatus(.init(kind: .success, message: "已切回当前画笔纹理"))
    }

    func setTextureFillArrangement(_ arrangement: TextureFillArrangement) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.textureFillTip.arrangement = arrangement
        }
        refreshToolSessionOnly()
        refreshColorVitalizationMaterialFromCurrentTexture()
    }

    func setTextureFillMaterialScale(_ scale: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.textureFillTip.materialScale = min(max(scale, 0.25), 3)
        }
        refreshToolSessionOnly()
        refreshColorVitalizationMaterialFromCurrentTexture()
    }

    func setTextureFillCoverage(_ coverage: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.textureFillTip.coverage = min(max(coverage, 0.1), 1)
        }
        refreshToolSessionOnly()
        refreshColorVitalizationMaterialFromCurrentTexture()
    }

    func setTextureFillVariation(_ variation: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.textureFillTip.variation = min(max(variation, 0), 1)
        }
        refreshToolSessionOnly()
        refreshColorVitalizationMaterialFromCurrentTexture()
    }

    func setTextureFillPaintJitterAmount(_ amount: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.textureFillTip.paintJitterAmount = min(max(amount, 0), 1)
        }
        refreshToolSessionOnly()
    }

    func saveCurrentTextureFillPreset() {
        let state = bootstrap.workspaceStore.state
        let settings = state.toolSession.textureFillTip
        let sourceBrush = state.toolSession.textureFillBrushOverride
            ?? state.toolSession.drawingBrush

        var savedItem: TextureFillLibraryItem?
        bootstrap.workspaceStore.updateTextureFillLibrary { library in
            savedItem = library.saveCurrentTexture(
                settings: settings,
                sourceBrush: sourceBrush
            )
        }
        guard let savedItem else { return }
        persistTextureFillLibrary()
        refreshLightweight()
        showStatus(.init(kind: .success, message: "已保存纹理：\(savedItem.displayName)"))
    }

    func saveCurrentTextureFillPresetAsNew() {
        let state = bootstrap.workspaceStore.state
        let settings = state.toolSession.textureFillTip
        let sourceBrush = state.toolSession.textureFillBrushOverride
            ?? state.toolSession.drawingBrush

        var savedItem: TextureFillLibraryItem?
        bootstrap.workspaceStore.updateTextureFillLibrary { library in
            savedItem = library.saveTextureAsNew(
                settings: settings,
                sourceBrush: sourceBrush
            )
        }
        guard let savedItem else { return }
        persistTextureFillLibrary()
        refreshLightweight()
        showStatus(.init(kind: .success, message: "已另存纹理：\(savedItem.displayName)"))
    }

    func updateSelectedTextureFillPreset() {
        let state = bootstrap.workspaceStore.state
        guard let itemID = state.textureFillLibrary.selectedItemID else { return }
        let settings = state.toolSession.textureFillTip
        let sourceBrush = state.toolSession.textureFillBrushOverride
            ?? state.toolSession.drawingBrush

        var updated: TextureFillLibraryItem?
        bootstrap.workspaceStore.updateTextureFillLibrary { library in
            updated = library.replaceItem(id: itemID, settings: settings, sourceBrush: sourceBrush)
        }
        guard let updated else { return }
        persistTextureFillLibrary()
        refreshLightweight()
        showStatus(.init(kind: .success, message: "已更新纹理：\(updated.displayName)"))
    }

    func applyTextureFillLibraryItem(_ itemID: UUID) {
        guard let item = workspace.textureFillLibrary.item(id: itemID) else {
            showStatus(.init(kind: .info, message: "未找到纹理预设"))
            return
        }

        let appliesToColorVitalization =
            workspace.toolSession.activeTool == .colorVitalization
        if workspace.toolSession.activeTool != .textureFill,
           !appliesToColorVitalization {
            selectTool(.textureFill)
        }
        bootstrap.workspaceStore.updateToolSession { session in
            session.textureFillTip = item.settings
            session.textureFillBrushOverride = item.sourceBrush
        }
        bootstrap.workspaceStore.updateTextureFillLibrary { library in
            library.selectItem(id: itemID)
            library.noteItemUsed(itemID)
        }
        persistTextureFillLibrary()
        refreshLightweight()
        if appliesToColorVitalization {
            refreshColorVitalizationMaterialFromCurrentTexture()
        }
        showStatus(.init(kind: .success, message: "已应用 \(item.displayName)"))
    }

    func moveTextureFillLibraryItem(_ itemID: UUID, toSlot targetSlotIndex: Int) {
        var moved = false
        bootstrap.workspaceStore.updateTextureFillLibrary { library in
            moved = library.moveItem(id: itemID, toSlot: targetSlotIndex)
        }
        guard moved else { return }
        persistTextureFillLibrary()
        refreshLightweight()
    }

    func setTextureFillLibraryItemColorTag(_ tag: BrushColorTag?, forItemID itemID: UUID) {
        bootstrap.workspaceStore.updateTextureFillLibrary { library in
            library.setColorTag(tag, forItemID: itemID)
        }
        persistTextureFillLibrary()
        refreshLightweight()
    }

    func setTextureFillLibraryItemFavorite(_ isFavorite: Bool, forItemID itemID: UUID) {
        bootstrap.workspaceStore.updateTextureFillLibrary { library in
            library.setFavorite(isFavorite, forItemID: itemID)
        }
        persistTextureFillLibrary()
        refreshLightweight()
    }

    func renameTextureFillLibraryItem(_ itemID: UUID, to name: String) {
        var renamed = false
        bootstrap.workspaceStore.updateTextureFillLibrary { library in
            renamed = library.renameItem(id: itemID, to: name)
        }
        guard renamed else { return }
        persistTextureFillLibrary()
        refreshLightweight()
        showStatus(.init(kind: .success, message: "已重命名纹理"))
    }

    func duplicateTextureFillLibraryItem(_ itemID: UUID) {
        var duplicate: TextureFillLibraryItem?
        bootstrap.workspaceStore.updateTextureFillLibrary { library in
            duplicate = library.duplicateItem(id: itemID)
        }
        guard let duplicate else { return }
        persistTextureFillLibrary()
        refreshLightweight()
        showStatus(.init(kind: .success, message: "已复制纹理：\(duplicate.displayName)"))
    }

    func deleteTextureFillLibraryItem(_ itemID: UUID) {
        var didDelete = false
        bootstrap.workspaceStore.updateTextureFillLibrary { library in
            didDelete = library.removeItem(id: itemID)
        }
        guard didDelete else { return }
        persistTextureFillLibrary()
        refreshLightweight()
        showStatus(.init(kind: .success, message: "已删除纹理预设"))
    }

    func restoreLastDeletedTextureFillLibraryItem() {
        var restored: TextureFillLibraryItem?
        bootstrap.workspaceStore.updateTextureFillLibrary { library in
            restored = library.restoreMostRecentlyDeletedItem()
        }
        guard let restored else { return }
        persistTextureFillLibrary()
        refreshLightweight()
        showStatus(.init(kind: .success, message: "已恢复纹理：\(restored.displayName)"))
    }

    func moveTipImageLibraryItem(_ assetID: BrushTipImageAssetID, to targetIndex: Int) {
        var moved = false
        bootstrap.workspaceStore.updateTipImageLibrary { library in
            moved = library.moveItem(id: assetID, to: targetIndex)
        }
        guard moved else { return }
        persistBrushLibrary()
        refresh()
    }

    @discardableResult
    func deleteTipImageLibraryItem(_ assetID: BrushTipImageAssetID) -> Bool {
        let referenceSummary = tipImageLibraryReferenceSummary(for: assetID)
        let referenceCount = referenceSummary.totalCount
        guard referenceCount == 0 else {
            showStatus(.init(kind: .info, message: tipImageLibraryBlockedDeleteMessage(for: referenceSummary)))
            return false
        }

        var didDelete = false
        bootstrap.workspaceStore.updateTipImageLibrary { library in
            didDelete = library.deleteItem(id: assetID)
        }
        guard didDelete else {
            showStatus(.init(kind: .info, message: "未找到该笔尖图片"))
            return false
        }

        StageOneBrushPreviewRasterizer.resetCache()
        persistBrushLibrary()
        refresh()
        showStatus(.init(kind: .success, message: "已删除笔尖图片"))
        return true
    }

    func tipImageLibraryReferenceSummary(for assetID: BrushTipImageAssetID) -> TipImageLibraryReferenceSummary {
        var summary = TipImageLibraryReferenceSummary()
        let state = bootstrap.workspaceStore.state

        let currentBrush = state.toolSession.drawingBrush
        if currentBrush.customTipSourceSemantic == .importedImage, currentBrush.customTipAssetID == assetID {
            summary.currentBrushUsesPrimary = true
        }
        if currentBrush.compoundBrush.secondary.sourceSemantic == .importedImage,
           currentBrush.compoundBrush.secondary.tipAssetID == assetID {
            summary.currentBrushUsesCompoundSecondary = true
        }

        if state.toolSession.smudgeBrushUsesIndependentSettings {
            let smudgeBrush = state.toolSession.smudgeBrush
            if smudgeBrush.customTipSourceSemantic == .importedImage, smudgeBrush.customTipAssetID == assetID {
                summary.smudgeBrushUsesPrimary = true
            }
        }

        if state.toolSession.textureFillTip.sourceSemantic == .importedImage,
           state.toolSession.textureFillTip.tipAssetID == assetID {
            summary.currentTextureFillUsesImportedTip = true
        }

        for preset in state.brushLibrary.presets {
            if preset.brush.customTipSourceSemantic == .importedImage,
               preset.brush.customTipAssetID == assetID {
                summary.presetPrimaryNames.append(preset.name)
            }
            if preset.brush.compoundBrush.secondary.sourceSemantic == .importedImage,
               preset.brush.compoundBrush.secondary.tipAssetID == assetID {
                summary.presetCompoundSecondaryNames.append(preset.name)
            }
        }

        return summary
    }

    private func tipImageLibraryBlockedDeleteMessage(
        for summary: TipImageLibraryReferenceSummary
    ) -> String {
        guard summary.isReferenced else {
            return "该笔尖图片未被引用"
        }

        var parts: [String] = []
        if summary.currentBrushUsesPrimary {
            parts.append("当前主笔尖")
        }
        if summary.currentBrushUsesCompoundSecondary {
            parts.append("当前组合笔刷次笔尖")
        }
        if summary.smudgeBrushUsesPrimary {
            parts.append("涂抹主笔尖")
        }
        if summary.currentTextureFillUsesImportedTip {
            parts.append("当前纹理填充素材")
        }
        if summary.presetCount > 0 {
            let previewNames = Array((summary.presetPrimaryNames + summary.presetCompoundSecondaryNames).prefix(3))
            let suffix = summary.presetCount > previewNames.count ? " 等 \(summary.presetCount) 个预设" : ""
            parts.append("预设 \(previewNames.joined(separator: "、"))\(suffix)")
        }
        return "该笔尖图片仍被\(parts.joined(separator: "、"))引用，无法删除"
    }

    func setGeneratorKind(_ kind: GeneratorKind) {
        bootstrap.strokeEngine.endStroke()
        strokeResetToken &+= 1
        let support = GeneratorFeatureSupport.support(for: kind)
        isGeneratorStrokeModeEnabled = support.supports(.directStroke)
        isGeneratorRegionSelectionArmed = false
        generatorStrokeSession = .init(kind: kind)
        bootstrap.workspaceStore.updateGenerator { generator in
            generator.kind = kind
        }
        bootstrap.workspaceStore.updateToolSession { session in
            session.activeTool = .brush
        }
        refresh()
        let message = support.supports(.directStroke)
            ? "已切换到\(kind.displayName)，可直接绘制或使用区域生成"
            : "已切换到\(kind.displayName)，请使用圈选区域生成"
        showStatus(.init(kind: .info, message: message))
    }

    func exitGeneratorMode(showFeedback: Bool = true) {
        guard isGeneratorStrokeModeEnabled || isGeneratorRegionSelectionArmed else { return }
        _ = drainPendingBrushCommitsIfNeeded(resetLiveSession: true)
        isGeneratorStrokeModeEnabled = false
        isGeneratorRegionSelectionArmed = false
        generatorStrokeSession = .init()
        if workspace.toolSession.activeTool == .lassoSelection {
            bootstrap.workspaceStore.updateToolSession { session in
                session.activeTool = .brush
            }
        }
        refreshLightweight()
        if showFeedback {
            showStatus(.init(kind: .info, message: "已退出生成器"))
        }
    }

    func setGeneratorScale(_ scale: Float) {
        bootstrap.workspaceStore.updateGenerator { generator in
            generator.density = min(max(scale, 0), 1)
        }
        refresh()
    }

    func setGeneratorOpacity(_ opacity: Float) {
        bootstrap.workspaceStore.updateGenerator { generator in
            generator.opacity = min(max(opacity, 0.05), 1)
        }
        refresh()
    }

    func setGeneratorDensity(_ density: Float) {
        bootstrap.workspaceStore.updateGenerator { generator in
            generator.density = min(max(density, 0), 1)
        }
        refresh()
    }

    func setGeneratorDrift(_ drift: Float) {
        bootstrap.workspaceStore.updateGenerator { generator in
            generator.drift = min(max(drift, 0), 1)
        }
        refresh()
    }

    func setGeneratorBranch(_ branch: Float) {
        bootstrap.workspaceStore.updateGenerator { generator in
            generator.branch = min(max(branch, 0), 1)
        }
        refresh()
    }

    func beginGeneratorRegionSelection() {
        isGeneratorRegionSelectionArmed = true
        isGeneratorStrokeModeEnabled = false
        generatorStrokeSession = .init(kind: workspace.generator.kind)
        bootstrap.workspaceStore.updateToolSession { session in
            session.activeTool = .lassoSelection
        }
        refresh()
        showStatus(.init(kind: .info, message: "请在画布上圈选区域以生成\(workspace.generator.kind.displayName)"))
    }

    func setSelectedColor(_ color: RGBAColor) {
        ideationBranchActivityHandler?()
        bootstrap.workspaceStore.updateToolSession { session in
            session.commitSelectedColor(color)
        }
        refreshLightweight()
    }

    var selectedReferenceImageSlot: ReferenceImageSlotState? {
        guard let selectedReferenceImageSlotID else { return nil }
        return referenceImageSlots.first(where: { $0.id == selectedReferenceImageSlotID })
    }

    var referenceImagePreviewSwiftUIColor: Color {
        let resolved = referenceImagePreviewColor ?? workspace.toolSession.selectedColor
        return Color(
            red: Double(resolved.red),
            green: Double(resolved.green),
            blue: Double(resolved.blue),
            opacity: Double(resolved.alpha)
        )
    }

    var referenceImagePreviousSwiftUIColor: Color {
        let resolved = referenceImagePreviousPickedColor ?? workspace.toolSession.selectedColor
        return Color(
            red: Double(resolved.red),
            green: Double(resolved.green),
            blue: Double(resolved.blue),
            opacity: Double(resolved.alpha)
        )
    }

    func activateReferenceImageSlot(_ slotID: Int) {
        guard referenceImageSlots.indices.contains(slotID) else { return }
        guard referenceImageLoadingSlotIDs.contains(slotID) == false else { return }

        if referenceImageSlots[slotID].asset != nil {
            selectReferenceImageSlot(slotID)
            return
        }

        if slotID == luminosityReferenceSlotID { return }

        importReferenceImageIntoSlot(slotID)
    }

    func clearReferenceImageSlot(_ slotID: Int) {
        guard referenceImageSlots.indices.contains(slotID) else { return }
        guard referenceImageSlots[slotID].asset != nil else { return }

        if slotID == luminosityReferenceSlotID {
            luminosityCaptureTask?.cancel()
            luminosityCaptureTask = nil
            luminosityReferenceHasPendingRefresh = false
            isCanvasLuminosityReferenceActive = false
            luminosityReferenceSlotID = nil
        }

        referenceImageUpgradeTasks[slotID]?.cancel()
        referenceImageUpgradeTasks[slotID] = nil

        let nextSelectedSlotID: Int?
        if selectedReferenceImageSlotID == slotID {
            nextSelectedSlotID = nextLoadedReferenceImageSlotID(afterClearing: slotID)
        } else {
            nextSelectedSlotID = selectedReferenceImageSlotID
        }

        replaceReferenceImageSlotAsset(nil, at: slotID)
        referenceImagePreviewColor = nil
        selectedReferenceImageSlotID = nextSelectedSlotID

        if nextSelectedSlotID == nil, isReferenceImageFloatingPanelPresented {
            closeReferenceImageFloatingPanel()
        }
        noteProjectReferenceImagesChanged()
    }

    func clearSelectedReferenceImage() {
        guard let selectedReferenceImageSlotID else { return }
        clearReferenceImageSlot(selectedReferenceImageSlotID)
    }

    func updateReferenceImagePreviewColor(_ color: RGBAColor?) {
        referenceImagePreviewColor = color
    }

    func confirmReferenceImagePickedColor(_ color: RGBAColor) {
        rememberReferenceImagePreviousColor(before: color)
        setSelectedColor(color)
        referenceImagePreviewColor = color
    }

    func openReferenceImageFloatingPanel() {
        guard selectedReferenceImageSlot?.asset != nil else {
            showStatus(.init(kind: .info, message: "请先载入参考图"))
            return
        }

        isReferenceImageFloatingPanelPresented = true
        referenceImageFloatingPanelController.show(for: self)
        promoteSelectedReferenceImageForFloatingPanelIfNeeded()
        scheduleLuminosityCaptureIfNeeded(after: Self.luminosityReferenceVisibleResumeDelay)
    }

    func closeReferenceImageFloatingPanel() {
        isReferenceImageFloatingPanelPresented = false
        referenceImageFloatingPanelController.close()
        cancelScheduledLuminosityCaptureIfNotVisible()
    }

    func referenceImageFloatingPanelDidClose() {
        isReferenceImageFloatingPanelPresented = false
        cancelScheduledLuminosityCaptureIfNotVisible()
    }

    func replaceReferenceImageSlotAsset(
        _ asset: ReferenceImageAsset?,
        at slotID: Int,
        selectAfterUpdate: Bool = false
    ) {
        guard referenceImageSlots.indices.contains(slotID) else { return }

        var updated = referenceImageSlots
        updated[slotID].asset = asset
        referenceImageSlots = updated

        if selectAfterUpdate {
            selectReferenceImageSlot(slotID)
        }
    }

    private func noteProjectReferenceImagesChanged() {
        hasUnsavedChanges = true
    }

    private func selectReferenceImageSlot(_ slotID: Int) {
        guard referenceImageSlots.indices.contains(slotID) else { return }
        guard referenceImageSlots[slotID].asset != nil else { return }
        selectedReferenceImageSlotID = slotID
        referenceImagePreviewColor = nil
        if slotID == luminosityReferenceSlotID {
            scheduleLuminosityCaptureIfNeeded(after: Self.luminosityReferenceVisibleResumeDelay)
        } else {
            cancelScheduledLuminosityCaptureIfNotVisible()
        }
    }

    private func importReferenceImageIntoSlot(_ slotID: Int) {
        bootstrap.filePanelService.presentImageOpenPanel(completion: documentScopedFileSelection { owner, url in
            if let url { owner.loadReferenceImage(from: url, into: slotID) }
        })
    }

    @discardableResult
    func importDroppedReferenceImages(from urls: [URL]) -> Int {
        guard urls.isEmpty == false else { return 0 }

        var reservedSlotIDs = referenceImageLoadingSlotIDs
        if let luminosityReferenceSlotID {
            reservedSlotIDs.insert(luminosityReferenceSlotID)
        }
        let destinationSlotIDs = referenceImageDropDestinationSlotIDs(
            slots: referenceImageSlots,
            reservedSlotIDs: reservedSlotIDs,
            maximumCount: urls.count
        )

        guard destinationSlotIDs.isEmpty == false else {
            showStatus(.init(kind: .info, message: "5 个参考图位置已满"))
            return 0
        }

        for (url, slotID) in zip(urls, destinationSlotIDs) {
            loadReferenceImage(from: url, into: slotID)
        }
        return destinationSlotIDs.count
    }

    @discardableResult
    func importDroppedReferenceImage(
        from image: NSImage,
        fileName: String = "拖入的参考图"
    ) -> Bool {
        var reservedSlotIDs = referenceImageLoadingSlotIDs
        if let luminosityReferenceSlotID {
            reservedSlotIDs.insert(luminosityReferenceSlotID)
        }
        guard let slotID = referenceImageDropDestinationSlotIDs(
            slots: referenceImageSlots,
            reservedSlotIDs: reservedSlotIDs,
            maximumCount: 1
        ).first else {
            showStatus(.init(kind: .info, message: "5 个参考图位置已满"))
            return false
        }
        guard let imageData = image.tiffRepresentation else {
            showStatus(.init(kind: .error, message: "无法读取参考图"))
            return false
        }

        loadReferenceImage(from: imageData, fileName: fileName, into: slotID)
        return true
    }

    private func loadReferenceImage(from url: URL, into slotID: Int) {
        referenceImageUpgradeTasks[slotID]?.cancel()
        referenceImageUpgradeTasks[slotID] = nil
        referenceImageLoadingSlotIDs.insert(slotID)
        let fileName = url.lastPathComponent

        Task.detached(priority: .userInitiated) { [weak self] in
            let asset = ReferenceImageAsset.decode(from: url, maxDimension: 768)

            await MainActor.run {
                guard let self else { return }
                self.referenceImageLoadingSlotIDs.remove(slotID)

                guard let asset else {
                    self.showStatus(.init(kind: .error, message: "无法读取参考图"))
                    return
                }
                guard self.ensureDocumentResourceBudget(
                    replacingReferenceImageAt: slotID,
                    with: asset,
                    action: "载入参考图"
                ) else { return }

                self.replaceReferenceImageSlotAsset(asset, at: slotID, selectAfterUpdate: true)
                self.noteProjectReferenceImagesChanged()
                self.showStatus(.init(kind: .success, message: "已载入\(fileName)"))
            }
        }
    }

    private func loadReferenceImage(
        from imageData: Data,
        fileName: String,
        into slotID: Int
    ) {
        referenceImageUpgradeTasks[slotID]?.cancel()
        referenceImageUpgradeTasks[slotID] = nil
        referenceImageLoadingSlotIDs.insert(slotID)

        Task.detached(priority: .userInitiated) { [weak self] in
            let asset = ReferenceImageAsset.decode(
                from: imageData,
                fileName: fileName,
                maxDimension: 768
            )

            await MainActor.run {
                guard let self else { return }
                self.referenceImageLoadingSlotIDs.remove(slotID)

                guard let asset else {
                    self.showStatus(.init(kind: .error, message: "无法读取参考图"))
                    return
                }
                guard self.ensureDocumentResourceBudget(
                    replacingReferenceImageAt: slotID,
                    with: asset,
                    action: "载入参考图"
                ) else { return }

                self.replaceReferenceImageSlotAsset(asset, at: slotID, selectAfterUpdate: true)
                self.noteProjectReferenceImagesChanged()
                self.showStatus(.init(kind: .success, message: "已载入\(fileName)"))
            }
        }
    }

    private func promoteSelectedReferenceImageForFloatingPanelIfNeeded() {
        guard let slotID = selectedReferenceImageSlotID else { return }
        guard referenceImageUpgradeTasks[slotID] == nil else { return }
        guard let asset = selectedReferenceImageSlot?.asset else { return }
        guard asset.decodedMaxDimension < 3072, let sourceURL = asset.sourceURL else { return }

        let sourceIdentifier = sourceURL.standardizedFileURL

        referenceImageUpgradeTasks[slotID] = Task.detached(priority: .utility) { [weak self] in
            let upgraded = ReferenceImageAsset.decode(from: sourceIdentifier, maxDimension: 3072)

            await MainActor.run {
                guard let self else { return }
                self.referenceImageUpgradeTasks[slotID] = nil

                guard let upgraded else { return }
                guard self.referenceImageSlots.indices.contains(slotID) else { return }
                guard self.referenceImageSlots[slotID].asset?.sourceURL?.standardizedFileURL == sourceIdentifier else { return }
                guard self.ensureDocumentResourceBudget(
                    replacingReferenceImageAt: slotID,
                    with: upgraded,
                    action: "放大参考图预览"
                ) else { return }

                self.replaceReferenceImageSlotAsset(
                    upgraded,
                    at: slotID,
                    selectAfterUpdate: false
                )
            }
        }
    }

    private func nextLoadedReferenceImageSlotID(afterClearing slotID: Int) -> Int? {
        guard referenceImageSlots.isEmpty == false else { return nil }

        let allIDs = referenceImageSlots.map(\.id)
        guard let startIndex = allIDs.firstIndex(of: slotID) else { return nil }

        for offset in 1..<allIDs.count {
            let candidateIndex = (startIndex + offset) % allIDs.count
            let candidateSlot = referenceImageSlots[candidateIndex]
            if candidateSlot.asset != nil, candidateSlot.id != slotID {
                return candidateSlot.id
            }
        }

        return nil
    }

    // MARK: - Canvas Luminosity Reference (黑白模式参考)

    func toggleCanvasLuminosityReference() {
        if isCanvasLuminosityReferenceActive {
            disableCanvasLuminosityReference()
        } else {
            enableCanvasLuminosityReference()
        }
    }

    private func enableCanvasLuminosityReference() {
        guard let slot = referenceImageSlots.first(where: { $0.asset == nil }) else {
            showStatus(.init(kind: .info, message: "请先腾出一个参考图位置"))
            return
        }

        isCanvasLuminosityReferenceActive = true
        luminosityReferenceSlotID = slot.id
        lastLuminosityCaptureRevision = luminosityReferenceSourceRevision
        luminosityReferenceHasPendingRefresh = false
        captureCanvasLuminositySnapshot()
    }

    func disableCanvasLuminosityReference() {
        luminosityCaptureTask?.cancel()
        luminosityCaptureTask = nil
        luminosityReferenceHasPendingRefresh = false

        if let slotID = luminosityReferenceSlotID {
            referenceImageUpgradeTasks[slotID]?.cancel()
            referenceImageUpgradeTasks[slotID] = nil

            let nextSelectedSlotID: Int?
            if selectedReferenceImageSlotID == slotID {
                nextSelectedSlotID = nextLoadedReferenceImageSlotID(afterClearing: slotID)
            } else {
                nextSelectedSlotID = selectedReferenceImageSlotID
            }

            replaceReferenceImageSlotAsset(nil, at: slotID)
            referenceImagePreviewColor = nil
            selectedReferenceImageSlotID = nextSelectedSlotID

            if nextSelectedSlotID == nil, isReferenceImageFloatingPanelPresented {
                closeReferenceImageFloatingPanel()
            }
        }

        isCanvasLuminosityReferenceActive = false
        luminosityReferenceSlotID = nil
    }

    func scheduleLuminosityCaptureIfNeeded() {
        scheduleLuminosityCaptureIfNeeded(after: Self.luminosityReferenceAutoRefreshDelay)
    }

    private func captureCanvasLuminositySnapshot() {
        guard isCanvasLuminosityReferenceActive,
              let slotID = luminosityReferenceSlotID,
              let presenter = luminosityPresenter,
              let labProcessor = luminosityPostProcessor
        else { return }

        let device = metalContext.device
        let snapshot = currentSceneSnapshot(for: workspace)
        let canvasWidth = snapshot.renderSnapshot.document.canvasSize.width
        let canvasHeight = snapshot.renderSnapshot.document.canvasSize.height
        guard canvasWidth > 0, canvasHeight > 0 else { return }

        let maxDim = 1024
        let scale = min(Double(maxDim) / Double(max(canvasWidth, canvasHeight)), 1.0)
        let outWidth = max(Int(Double(canvasWidth) * scale), 1)
        let outHeight = max(Int(Double(canvasHeight) * scale), 1)

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: outWidth,
            height: outHeight,
            mipmapped: false
        )
        texDesc.usage = [.shaderRead, .renderTarget]
        texDesc.storageMode = .shared

        let tempDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: outWidth,
            height: outHeight,
            mipmapped: false
        )
        tempDesc.usage = [.shaderRead, .renderTarget]
        tempDesc.storageMode = .private

        guard let offscreen = device.makeTexture(descriptor: texDesc),
              let tempTexture = device.makeTexture(descriptor: tempDesc),
              let commandBuffer = metalContext.commandQueue.makeCommandBuffer()
        else { return }

        let layerTextures: [(texture: MTLTexture, opacity: Float)] = snapshot.layerSurfaces.compactMap { surface in
            guard surface.isVisible,
                  let texture = layerSurfaceStore.texture(for: surface.surfaceID)
            else { return nil }
            return (texture, surface.opacity)
        }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = offscreen
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store

        presenter.encode(
            layerTextures: layerTextures,
            into: rpd,
            commandBuffer: commandBuffer
        )

        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(from: offscreen, to: tempTexture)
            blit.endEncoding()
        }

        let labRPD = MTLRenderPassDescriptor()
        labRPD.colorAttachments[0].texture = offscreen
        labRPD.colorAttachments[0].loadAction = .dontCare
        labRPD.colorAttachments[0].storeAction = .store

        labProcessor.encode(
            sourceTexture: tempTexture,
            into: labRPD,
            commandBuffer: commandBuffer
        )

        let capturedSlotID = slotID
        commandBuffer.addCompletedHandler { [weak self] _ in
            let bytesPerRow = 4 * outWidth
            var pixels = [UInt8](repeating: 0, count: bytesPerRow * outHeight)
            offscreen.getBytes(
                &pixels,
                bytesPerRow: bytesPerRow,
                from: MTLRegion(
                    origin: MTLOrigin(x: 0, y: 0, z: 0),
                    size: MTLSize(width: outWidth, height: outHeight, depth: 1)
                ),
                mipmapLevel: 0
            )

            for i in 0..<(outWidth * outHeight) {
                let offset = i * 4
                let b = pixels[offset]
                let r = pixels[offset + 2]
                pixels[offset] = r
                pixels[offset + 2] = b
            }

            let rgbaData = Data(pixels)

            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let provider = CGDataProvider(data: rgbaData as CFData),
                  let cgImage = CGImage(
                      width: outWidth,
                      height: outHeight,
                      bitsPerComponent: 8,
                      bitsPerPixel: 32,
                      bytesPerRow: bytesPerRow,
                      space: colorSpace,
                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                      provider: provider,
                      decode: nil,
                      shouldInterpolate: true,
                      intent: .defaultIntent
                  )
            else { return }

            let asset = ReferenceImageAsset(
                fileName: "画布黑白预览",
                width: outWidth,
                height: outHeight,
                rgbaPixels: rgbaData,
                cgImage: cgImage,
                sourceURL: nil,
                decodedMaxDimension: maxDim
            )

            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.isCanvasLuminosityReferenceActive,
                      self.luminosityReferenceSlotID == capturedSlotID
                else { return }

                self.replaceReferenceImageSlotAsset(asset, at: capturedSlotID, selectAfterUpdate: true)
            }
        }

        commandBuffer.commit()
    }

    func setColorPanelMode(_ mode: ColorPanelMode) {
        imagePaletteExtractor.cancel()
        let selectedColor = workspace.toolSession.selectedColor
        bootstrap.workspaceStore.updateColorPanel { panel in
            panel.mode = mode
            if mode == .blocks, panel.basePaletteHSV == nil {
                panel.baseHSV = ColorBlocksEngine.rgbToHsv(selectedColor)
                panel.baseSource = .synced
                panel.baseName = ""
                panel.basePaletteHSV = ColorBlocksEngine.defaultBasePalette(baseHSV: panel.baseHSV)
            }
        }
        refreshLightweight()
    }

    func toggleColorPanelMode() {
        setColorPanelMode(workspace.colorPanel.mode == .picker ? .blocks : .picker)
    }

    func toggleGrayscaleMode() {
        setColorPanelMode(workspace.colorPanel.mode == .grayscale ? .picker : .grayscale)
    }

    func setGrayscaleBlockCount(_ count: Int) {
        bootstrap.workspaceStore.updateColorPanel { panel in
            panel.grayscaleBlockCount = count
        }
        refreshColorPanelOnly()
    }

    func selectGrayscaleBlock(at index: Int, count: Int) {
        guard count >= 2 else { return }
        let t = Float(index) / Float(count - 1)
        let value = 1.0 - t
        let color = RGBAColor(red: value, green: value, blue: value, alpha: 1)
        rememberReferenceImagePreviousColor(before: color)
        bootstrap.workspaceStore.updateToolSession { session in
            session.commitSelectedColor(color)
        }
        refreshColorPanelOnly(includeSelectedColor: true)
    }

    func syncColorPanelFromSelectedColor() {
        imagePaletteExtractor.cancel()
        let selectedColor = workspace.toolSession.selectedColor
        let baseHSV = ColorBlocksEngine.rgbToHsv(selectedColor)

        bootstrap.workspaceStore.updateColorPanel { panel in
            panel.baseHSV = baseHSV
            panel.baseSource = .synced
            panel.baseName = ""
            panel.basePaletteHSV = ColorBlocksEngine.defaultBasePalette(baseHSV: baseHSV)
            ColorBlocksEngine.syncPicker(to: selectedColor, state: &panel)
        }
        refreshLightweight()
        showStatus(.init(kind: .success, message: "已同步当前颜色"))
    }

    func refreshColorPanelBlocks() {
        imagePaletteExtractor.cancel()
        bootstrap.workspaceStore.updateColorPanel { panel in
            guard panel.baseSource != .image else { return }
            panel.basePaletteHSV = ColorBlocksEngine.makeRandomBasePalette(
                baseHSV: panel.baseHSV,
                state: panel
            )
        }
        refreshLightweight()
        showStatus(.init(kind: .success, message: "已刷新色块"))
    }

    func loadColorPanelPaletteFromImage() {
        guard !isChoosingPaletteImage else { return }
        isChoosingPaletteImage = true
        imagePaletteExtractor.cancel()
        let documentID = bootstrap.workspaceStore.state.document.metadata.drawingStatsID
        bootstrap.filePanelService.presentPaletteImageOpenPanel { [weak self] url in
            guard let self else { return }
            self.isChoosingPaletteImage = false
            guard self.bootstrap.workspaceStore.state.document.metadata.drawingStatsID == documentID,
                  let url else { return }
            self.importColorPanelPalette(from: url)
        }
    }

    @discardableResult
    func importColorPanelPalette(fromPasteboard pasteboard: NSPasteboard = .general) -> Bool {
        imagePaletteExtractor.start(from: pasteboard, completion: paletteImportCompletion())
    }

    @discardableResult
    func importColorPanelPalette(from url: URL) -> Bool {
        imagePaletteExtractor.start(from: .file(url), name: url.deletingPathExtension().lastPathComponent,
                                    completion: paletteImportCompletion())
        return true
    }

    @discardableResult
    func importColorPanelPalette(from providers: [NSItemProvider]) -> Bool {
        imagePaletteExtractor.start(from: providers, completion: paletteImportCompletion())
    }

    private func paletteImportCompletion() -> ImagePaletteExtractor.Completion {
        let documentID = bootstrap.workspaceStore.state.document.metadata.drawingStatsID
        return { [weak self] colors, name in
            guard let self,
                  self.bootstrap.workspaceStore.state.document.metadata.drawingStatsID == documentID else { return }
            self.applyImportedColorPanelPalette(colors, sourceName: name)
        }
    }

    @discardableResult
    private func applyImportedColorPanelPalette(_ colors: [RGBAColor], sourceName: String) -> Bool {
        let paletteHSV = ColorBlocksEngine.paletteFromImageColors(colors)
        let baseHSV = paletteHSV.first ?? .black

        bootstrap.workspaceStore.updateColorPanel { panel in
            panel.mode = .blocks
            panel.baseSource = .image
            panel.baseName = sourceName
            panel.baseHSV = baseHSV
            panel.basePaletteHSV = paletteHSV
            // Neutral controls show the extracted colors, not the previous palette's lighting treatment.
            panel.blocksLightness = 50
            panel.blocksSaturation = 50
            panel.contrast = 50
            panel.contrastHue = 0
            panel.lightingStrength = 0
        }
        refreshLightweight()
        showStatus(.init(kind: .success, message: "已从图片提取色块"))
        return true
    }

    func setColorPanelLightness(_ value: Float) {
        bootstrap.workspaceStore.updateColorPanel { panel in
            let snapped = ColorBlocksEngine.snapValue(value, enabled: panel.snapThreeStops)
            if panel.mode == .picker {
                panel.pickerLightness = min(max(snapped, 0), 100)
            } else {
                panel.blocksLightness = min(max(snapped, 0), 100)
            }
        }
        if workspace.colorPanel.mode == .picker {
            applyPickerColorFromPanel()
        } else {
            refreshColorPanelOnly()
        }
    }

    func setColorPanelSaturation(_ value: Float) {
        bootstrap.workspaceStore.updateColorPanel { panel in
            let snapped = ColorBlocksEngine.snapValue(value, enabled: panel.snapThreeStops)
            if panel.mode == .picker {
                panel.pickerSaturation = min(max(snapped, 0), 100)
            } else {
                panel.blocksSaturation = min(max(snapped, 0), 100)
            }
        }
        if workspace.colorPanel.mode == .picker {
            applyPickerColorFromPanel()
        } else {
            refreshColorPanelOnly()
        }
    }

    func setColorPanelContrast(_ value: Float) {
        bootstrap.workspaceStore.updateColorPanel { panel in
            panel.contrast = min(max(value, 0), 100)
        }
        refreshColorPanelOnly()
    }

    func setColorPanelContrastHue(_ value: Float) {
        bootstrap.workspaceStore.updateColorPanel { panel in
            panel.contrastHue = min(max(value, 0), 100)
        }
        refreshColorPanelOnly()
    }

    func setColorPanelLightingHue(_ value: Float) {
        bootstrap.workspaceStore.updateColorPanel { panel in
            panel.lightingHue = ColorBlocksEngine.wrapHue(value)
        }
        if workspace.colorPanel.mode == .picker {
            applyPickerColorFromPanel()
        } else {
            refreshColorPanelOnly()
        }
    }

    func setColorPanelLightingStrength(_ value: Float) {
        bootstrap.workspaceStore.updateColorPanel { panel in
            panel.lightingStrength = min(max(value, 0), 100)
        }
        if workspace.colorPanel.mode == .picker {
            applyPickerColorFromPanel()
        } else {
            refreshColorPanelOnly()
        }
    }

    func setColorPanelSnapThreeStops(_ enabled: Bool) {
        bootstrap.workspaceStore.updateColorPanel { panel in
            panel.snapThreeStops = enabled
            panel.pickerLightness = ColorBlocksEngine.snapValue(panel.pickerLightness, enabled: enabled)
            panel.pickerSaturation = ColorBlocksEngine.snapValue(panel.pickerSaturation, enabled: enabled)
            panel.blocksLightness = ColorBlocksEngine.snapValue(panel.blocksLightness, enabled: enabled)
            panel.blocksSaturation = ColorBlocksEngine.snapValue(panel.blocksSaturation, enabled: enabled)
        }
        if workspace.colorPanel.mode == .picker {
            applyPickerColorFromPanel()
        } else {
            refreshColorPanelOnly()
        }
    }

    func setColorPickerHue(_ hue: Float) {
        bootstrap.workspaceStore.updateColorPanel { panel in
            panel.pickerHue = ColorBlocksEngine.wrapHue(hue)
        }
        applyPickerColorFromPanel()
    }

    func setColorPickerPoint(x: Float, y: Float) {
        bootstrap.workspaceStore.updateColorPanel { panel in
            panel.pickerX = min(max(x, 0), 1)
            panel.pickerY = min(max(y, 0), 1)
        }
        applyPickerColorFromPanel()
    }

    func setQuickColorPickerHue(_ hue: Float) {
        guard var state = quickColorPickerDraftState ?? quickColorPickerState else { return }
        state.panel.pickerHue = ColorBlocksEngine.wrapHue(hue)
        previewQuickColorPickerState(state)
    }

    func setQuickColorPickerPoint(x: Float, y: Float) {
        guard var state = quickColorPickerDraftState ?? quickColorPickerState else { return }
        state.panel.pickerX = min(max(x, 0), 1)
        state.panel.pickerY = min(max(y, 0), 1)
        previewQuickColorPickerState(state)
    }

    func setQuickColorPickerRecentBrushSelectionCount(_ count: Int) {
        let clampedCount = max(count, 0)
        guard recentBrushAdjustmentSelectedCount != clampedCount else {
            return
        }
        recentBrushAdjustmentSelectedCount = clampedCount
        syncRecentBrushAdjustmentState()
    }

    func setQuickColorPickerRecentBrushOpacity(_ opacity: Float) {
        let clampedOpacity = min(max(opacity, 0), 1)
        guard !recentBrushAdjustmentValuesMatch(recentBrushAdjustmentOpacity, clampedOpacity) else {
            return
        }
        recentBrushAdjustmentOpacity = clampedOpacity
        syncRecentBrushAdjustmentState(showsSelectionHighlight: false)
    }

    func setQuickColorPickerRecentBrushBrightness(_ brightness: Float) {
        let clampedBrightness = min(max(brightness, -1), 1)
        guard !recentBrushAdjustmentValuesMatch(recentBrushAdjustmentBrightness, clampedBrightness) else {
            return
        }
        recentBrushAdjustmentBrightness = clampedBrightness
        syncRecentBrushAdjustmentState(showsSelectionHighlight: false)
    }

    func setQuickColorPickerRecentBrushSaturation(_ saturation: Float) {
        let clampedSaturation = min(max(saturation, -1), 1)
        guard !recentBrushAdjustmentValuesMatch(recentBrushAdjustmentSaturation, clampedSaturation) else {
            return
        }
        recentBrushAdjustmentSaturation = clampedSaturation
        syncRecentBrushAdjustmentState(showsSelectionHighlight: false)
    }

    func setQuickColorPickerRecentBrushSelectionEditing(_ isEditing: Bool) {
        guard isRecentBrushSelectionHighlightActive != isEditing else {
            return
        }
        isRecentBrushSelectionHighlightActive = isEditing
        syncRecentBrushAdjustmentState(showsSelectionHighlight: isEditing)
    }

    func setQuickColorPickerRecentBrushOpacityEditing(_ isEditing: Bool) {
        guard isEditing || isRecentBrushSelectionHighlightActive else {
            return
        }
        if isEditing {
            isRecentBrushSelectionHighlightActive = false
        }
        syncRecentBrushAdjustmentState(showsSelectionHighlight: false)
    }

    func resetColorPanel() {
        imagePaletteExtractor.cancel()
        bootstrap.workspaceStore.updateColorPanel { state in
            if state.mode == .picker {
                let selectedColor = workspace.toolSession.selectedColor
                var panel = ColorPanelState.stageOneDefault
                ColorBlocksEngine.syncPicker(to: selectedColor, state: &panel)
                panel.baseHSV = ColorBlocksEngine.rgbToHsv(selectedColor)
                panel.mode = .picker
                state = panel
            } else {
                state.blocksLightness = 50
                state.blocksSaturation = 50
                state.contrast = 50
                state.contrastHue = 0
                state.lightingHue = 0
                state.lightingStrength = 0
            }
        }
        refreshColorPanelOnly()
        showStatus(.init(kind: .success, message: "已重置色彩面板"))
    }

    func selectColorBlock(at index: Int) {
        let palette = ColorBlocksEngine.renderPalette(for: workspace.colorPanel)
        guard palette.indices.contains(index) else { return }
        rememberReferenceImagePreviousColor(before: palette[index])
        bootstrap.workspaceStore.updateToolSession { session in
            session.commitSelectedColor(palette[index])
        }
        refreshColorPanelOnly(includeSelectedColor: true)
    }

    func sampleColor(at point: CanvasPoint) {
        ideationBranchActivityHandler?()
        do {
            let eyedropperSettings = workspace.toolSession.eyedropper
            let sampledColor = try bootstrap.eyedropperSampler.sampleVisibleColor(
                at: point,
                document: workspace.document,
                layerSurfaceStore: bootstrap.layerSurfaceStore,
                settings: eyedropperSettings,
                contentTextureForLayer: { [weak self] layerID in
                    self?.bootstrap.strokeEngine.displayTexture(for: layerID)
                },
                displayTextureForLayer: { [weak self] layerID in
                    self?.brushDisplayTexture(for: layerID)
                }
            )
            rememberReferenceImagePreviousColor(before: sampledColor)
            bootstrap.workspaceStore.updateToolSession { session in
                session.commitSelectedColor(sampledColor)
            }
            bootstrap.workspaceStore.updateColorPanel { panel in
                ColorBlocksEngine.syncPicker(to: sampledColor, state: &panel)
                if panel.mode == .picker {
                    panel.baseHSV = ColorBlocksEngine.rgbToHsv(sampledColor)
                    panel.baseSource = .synced
                    panel.baseName = ""
                }
            }
            refreshColorPanelOnly(includeSelectedColor: true)
            let isOilPaintCandidate = workspace.toolSession.brush.oilPaint.isEnabled
                && workspace.toolSession.brush.effectivePaintJitterAmount > 0.001
            showStatus(.init(
                kind: .success,
                message: isOilPaintCandidate ? "已吸取颜色并设为待沾色" : "已吸取颜色"
            ))
            if eyedropperSettings.returnsToPreviousTool,
               workspace.toolSession.activeTool == .eyedropper {
                selectTool(previousToolBeforeEyedropper ?? .brush)
            }
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func setEyedropperSampleSize(_ sampleSize: EyedropperSampleSize) {
        guard workspace.toolSession.eyedropper.sampleSize != sampleSize else { return }
        bootstrap.workspaceStore.updateToolSession { session in
            session.eyedropper.sampleSize = sampleSize
        }
        refreshLightweight()
    }

    func setEyedropperSampleStatistic(_ statistic: EyedropperSampleStatistic) {
        guard workspace.toolSession.eyedropper.statistic != statistic else { return }
        bootstrap.workspaceStore.updateToolSession { session in
            session.eyedropper.statistic = statistic
        }
        refreshLightweight()
    }

    func setEyedropperSampleSource(_ source: EyedropperSampleSource) {
        guard workspace.toolSession.eyedropper.source != source else { return }
        bootstrap.workspaceStore.updateToolSession { session in
            session.eyedropper.source = source
        }
        refreshLightweight()
    }

    func setEyedropperPreservesTransparency(_ enabled: Bool) {
        guard workspace.toolSession.eyedropper.preservesTransparency != enabled else { return }
        bootstrap.workspaceStore.updateToolSession { session in
            session.eyedropper.preservesTransparency = enabled
        }
        refreshLightweight()
    }

    func setEyedropperReturnsToPreviousTool(_ enabled: Bool) {
        guard workspace.toolSession.eyedropper.returnsToPreviousTool != enabled else { return }
        bootstrap.workspaceStore.updateToolSession { session in
            session.eyedropper.returnsToPreviousTool = enabled
        }
        refreshLightweight()
    }

    func applyBrushPreset(_ presetID: String) {
        applyBrushPreset(presetID, showFeedback: true)
    }

    private func applyBrushPreset(_ presetID: String, showFeedback: Bool) {
        ideationBranchActivityHandler?()
        guard let preset = workspace.brushLibrary.preset(id: presetID) else {
            if showFeedback {
                showStatus(.init(kind: .info, message: "未找到画笔预设"))
            }
            return
        }

        bootstrap.strokeEngine.endStroke()
        strokeResetToken &+= 1

        let currentTool = workspace.toolSession.activeTool

        let keepsCurrentTool = currentTool == .smudge || currentTool == .eraser
            || currentTool == .brightnessAdjust || currentTool == .colorVitalization
        if !keepsCurrentTool, currentTool != .brush {
            selectTool(.brush)
        }
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush = preset.brush
            session.washOilPaintReservoir()
        }

        bootstrap.workspaceStore.updateBrushLibrary { library in
            library.selectPreset(id: presetID)
            library.notePresetUsed(presetID)
        }
        persistBrushLibrary()
        _ = synchronizeTipImageLibraryFromWorkspace(persistIfChanged: true)
        refresh()
        if showFeedback {
            showStatus(.init(kind: .success, message: "已应用 \(preset.name)"))
        }
    }

    func saveCurrentBrushPreset() {
        bootstrap.workspaceStore.updateBrushLibrary { library in
            _ = library.saveCurrentPreset(
                brush: workspace.toolSession.brush
            )
        }
        _ = synchronizeTipImageLibraryFromWorkspace(persistIfChanged: false)
        persistBrushLibrary()
        refresh()
        showStatus(.init(kind: .success, message: "已保存画笔"))
    }

    @discardableResult
    func saveNamedBrushPreset(
        name: String,
        colorTag: BrushColorTag?,
        replacingPresetID: String?,
        allowsDuplicate: Bool
    ) -> BrushPresetSaveResult {
        saveNamedBrushPreset(
            brush: workspace.toolSession.brush,
            name: name,
            colorTag: colorTag,
            replacingPresetID: replacingPresetID,
            allowsDuplicate: allowsDuplicate
        )
    }

    /// Saves an explicit brush value. Editors with an isolated draft can use
    /// this without first mutating the active brush in the workspace.
    @discardableResult
    func saveNamedBrushPreset(
        brush: BrushSettings,
        name: String,
        colorTag: BrushColorTag?,
        replacingPresetID: String?,
        allowsDuplicate: Bool
    ) -> BrushPresetSaveResult {
        var result: BrushPresetSaveResult?
        bootstrap.workspaceStore.updateBrushLibrary { library in
            result = library.saveNamedPreset(
                brush: brush,
                name: name,
                colorTag: colorTag,
                replacingPresetID: replacingPresetID,
                allowsDuplicate: allowsDuplicate
            )
        }
        _ = synchronizeTipImageLibraryFromWorkspace(persistIfChanged: false)
        persistBrushLibrary()
        refresh()

        guard let resolved = result else {
            preconditionFailure("Brush library update did not return a save result")
        }
        let message: String
        switch resolved.disposition {
        case .created:
            message = "已新建画笔“\(resolved.preset.name)”"
        case .replaced:
            message = "已替换画笔“\(resolved.preset.name)”"
        case .selectedExisting:
            message = "相同画笔已存在，已选中“\(resolved.preset.name)”"
        }
        showStatus(.init(kind: .success, message: message))
        return resolved
    }

    @discardableResult
    func prepareTipImageLibraryForBrowser() -> Bool {
        let restored = restorePersistedTipImageLibraryIfAvailable()
        let synchronized = synchronizeTipImageLibraryFromWorkspace(persistIfChanged: true)
        let changed = restored || synchronized
        if changed {
            refreshLightweight()
        }
        return changed
    }

    func deleteBrushPreset(_ presetID: String) {
        var deletedName: String?
        var didDelete = false
        let previousSelectedPresetID = bootstrap.workspaceStore.state.brushLibrary.selectedPresetID
        bootstrap.workspaceStore.updateBrushLibrary { library in
            deletedName = library.preset(id: presetID)?.name
            didDelete = library.deletePreset(id: presetID)
        }
        if didDelete {
            _ = synchronizeCurrentBrushToSelectedPresetIfNeeded(
                previousSelectedPresetID: previousSelectedPresetID
            )
            persistBrushLibrary()
        }
        refresh()
        if didDelete, let deletedName {
            showStatus(.init(kind: .success, message: "已删除 \(deletedName)"))
        } else {
            showStatus(.init(kind: .info, message: "无法删除该预设"))
        }
    }

    func renameBrushPreset(_ presetID: String, to name: String) {
        var renamed = false
        bootstrap.workspaceStore.updateBrushLibrary { library in
            renamed = library.renamePreset(id: presetID, to: name)
        }
        guard renamed else { return }
        persistBrushLibrary()
        refreshLightweight()
        showStatus(.init(kind: .success, message: "已重命名画笔"))
    }

    func duplicateBrushPreset(_ presetID: String) {
        var duplicate: BrushPreset?
        bootstrap.workspaceStore.updateBrushLibrary { library in
            duplicate = library.duplicatePreset(id: presetID)
        }
        guard let duplicate else { return }
        persistBrushLibrary()
        refresh()
        showStatus(.init(kind: .success, message: "已复制画笔：\(duplicate.name)"))
    }

    func setBrushPresetFavorite(_ isFavorite: Bool, forPresetID presetID: String) {
        bootstrap.workspaceStore.updateBrushLibrary { library in
            library.setFavorite(isFavorite, forPresetID: presetID)
        }
        persistBrushLibrary()
        refreshLightweight()
    }

    func updateSelectedBrushPresetFromCurrent() {
        guard let presetID = workspace.brushLibrary.selectedPresetID,
              let preset = workspace.brushLibrary.preset(id: presetID),
              !preset.isBuiltIn else {
            showStatus(.init(kind: .info, message: "内置画笔不能覆盖，请另存为新画笔"))
            return
        }
        _ = saveNamedBrushPreset(
            name: preset.name,
            colorTag: preset.colorTag,
            replacingPresetID: presetID,
            allowsDuplicate: true
        )
    }

    func saveCurrentBrushPresetAsNew() {
        let customCount = workspace.brushLibrary.presets.filter { !$0.isBuiltIn }.count + 1
        _ = saveNamedBrushPreset(
            name: "笔刷 \(customCount)",
            colorTag: nil,
            replacingPresetID: nil,
            allowsDuplicate: true
        )
    }

    func restoreLastDeletedBrushPreset() {
        var restored: BrushPreset?
        bootstrap.workspaceStore.updateBrushLibrary { library in
            restored = library.restoreMostRecentlyDeletedPreset()
        }
        guard let restored else { return }
        persistBrushLibrary()
        refresh()
        showStatus(.init(kind: .success, message: "已恢复画笔：\(restored.name)"))
    }

    func moveBrushPreset(_ presetID: String, toSlot targetSlotIndex: Int) {
        var moved = false
        bootstrap.workspaceStore.updateBrushLibrary { library in
            moved = library.movePreset(id: presetID, toSlot: targetSlotIndex)
        }
        if moved {
            persistBrushLibrary()
            refresh()
        }
    }

    func setBrushPresetColorTag(_ tag: BrushColorTag?, forPresetID presetID: String) {
        bootstrap.workspaceStore.updateBrushLibrary { library in
            library.setColorTag(tag, forPresetID: presetID)
        }
        persistBrushLibrary()
        refresh()
    }

    func selectPatternLibraryItem(_ itemID: UUID) {
        guard workspace.patternLibrary.item(id: itemID) != nil else { return }
        bootstrap.workspaceStore.updatePatternLibrary { library in
            library.selectItem(id: itemID)
        }
        patternPlacementPhase = .armed(itemID: itemID)
        _ = patternPlacementTexture(for: itemID)
        refreshLightweight()
        showStatus(.init(kind: .info, message: "已准备放置图案"))
    }

    func movePatternLibraryItem(_ itemID: UUID, toSlot targetSlotIndex: Int) {
        var moved = false
        bootstrap.workspaceStore.updatePatternLibrary { library in
            moved = library.moveItem(id: itemID, toSlot: targetSlotIndex)
        }
        if moved {
            persistPatternLibrary()
            refreshLightweight()
        }
    }

    func setPatternLibraryItemColorTag(_ tag: BrushColorTag?, forItemID itemID: UUID) {
        bootstrap.workspaceStore.updatePatternLibrary { library in
            library.setColorTag(tag, forItemID: itemID)
        }
        persistPatternLibrary()
        refreshLightweight()
    }

    func setPatternLibraryItemFavorite(_ isFavorite: Bool, forItemID itemID: UUID) {
        bootstrap.workspaceStore.updatePatternLibrary { library in
            library.setFavorite(isFavorite, forItemID: itemID)
        }
        persistPatternLibrary()
        refreshLightweight()
    }

    func renamePatternLibraryItem(_ itemID: UUID, to name: String) {
        var renamed = false
        bootstrap.workspaceStore.updatePatternLibrary { library in
            renamed = library.renameItem(id: itemID, to: name)
        }
        guard renamed else { return }
        persistPatternLibrary()
        refreshLightweight()
        showStatus(.init(kind: .success, message: "已重命名图案"))
    }

    func duplicatePatternLibraryItem(_ itemID: UUID) {
        var duplicate: PatternLibraryItem?
        bootstrap.workspaceStore.updatePatternLibrary { library in
            duplicate = library.duplicateItem(id: itemID)
        }
        guard let duplicate else { return }
        persistPatternLibrary()
        refreshLightweight()
        showStatus(.init(kind: .success, message: "已复制图案：\(duplicate.displayName)"))
    }

    func deletePatternLibraryItem(_ itemID: UUID) {
        let deletedItem = workspace.patternLibrary.item(id: itemID)
        var didDelete = false
        bootstrap.workspaceStore.updatePatternLibrary { library in
            didDelete = library.removeItem(id: itemID)
        }
        if didDelete {
            patternPlacementTextureCache.removeObject(forKey: itemID as NSUUID)
            if patternPlacementPhase.itemID == itemID {
                patternPlacementPhase = .idle
            }
            persistPatternLibrary()
            refreshLightweight()
            if let deletedItem {
                showStatus(.init(kind: .success, message: "已删除图案：\(deletedItem.displayName)，可撤销"))
            }
        }
    }

    func restoreLastDeletedPatternLibraryItem() {
        var restored: PatternLibraryItem?
        bootstrap.workspaceStore.updatePatternLibrary { library in
            restored = library.restoreMostRecentlyDeletedItem()
        }
        guard let restored else { return }
        persistPatternLibrary()
        refreshLightweight()
        showStatus(.init(kind: .success, message: "已恢复图案：\(restored.displayName)"))
    }

    func revealPatternLibraryItemInFinder(_ itemID: UUID) {
        guard let item = workspace.patternLibrary.item(id: itemID),
              let url = bootstrap.patternLibraryPersistenceController.revealableURL(for: item) else {
            showStatus(.init(kind: .info, message: "未找到图案资源"))
            return
        }

        bootstrap.filePanelService.revealInFinder(url)
    }

    func rebuildPatternLibraryThumbnail(_ itemID: UUID) {
        guard let item = workspace.patternLibrary.item(id: itemID) else {
            showStatus(.init(kind: .info, message: "未找到图案"))
            return
        }

        do {
            try bootstrap.patternLibraryPersistenceController.rebuildThumbnail(for: item)
            refreshLightweight()
            showStatus(.init(kind: .success, message: "已重建缩略图"))
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func rebuildAllPatternLibraryThumbnails() {
        do {
            try bootstrap.patternLibraryPersistenceController.rebuildAllThumbnails(in: workspace.patternLibrary)
            refreshLightweight()
            showStatus(.init(kind: .success, message: "已重建全部图案缩略图"))
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func patternPlacementTexture(for itemID: UUID) -> MTLTexture? {
        let cacheKey = itemID as NSUUID
        if let cached = patternPlacementTextureCache.object(forKey: cacheKey) {
            return cached.texture
        }

        guard let item = workspace.patternLibrary.item(id: itemID),
              let decodedImage = bootstrap.patternLibraryPersistenceController.loadRenderImage(for: item)
        else {
            return nil
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb,
            width: decodedImage.width,
            height: decodedImage.height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared

        guard let texture = bootstrap.metalContext.device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        decodedImage.rgbaBytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, decodedImage.width, decodedImage.height),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: decodedImage.width * 4
            )
        }
        texture.label = "PatternPlacement-\(itemID.uuidString)"
        let textureCost = decodedImage.width * decodedImage.height * 4
        patternPlacementTextureCache.setObject(
            PatternPlacementTextureCacheEntry(texture: texture),
            forKey: cacheKey,
            cost: textureCost
        )
        return texture
    }

#if DEBUG
    var debugPatternPlacementTextureCacheLimits: (count: Int, cost: Int) {
        (
            count: patternPlacementTextureCache.countLimit,
            cost: patternPlacementTextureCache.totalCostLimit
        )
    }
#endif

    func beginPatternPlacementDrag(at point: CanvasPoint, placeIntoNewLayer: Bool = false) {
        if case .adjusting(let draft) = patternPlacementPhase {
            let rect = draft.destinationRect.standardized
            let corners = [
                CanvasPoint(x: rect.minX, y: rect.minY),
                CanvasPoint(x: rect.maxX, y: rect.minY),
                CanvasPoint(x: rect.maxX, y: rect.maxY),
                CanvasPoint(x: rect.minX, y: rect.maxY)
            ]
            let hitRadius = max(12, min(rect.width, rect.height) * 0.08)
            if let cornerIndex = corners.indices.min(by: {
                Self.patternPlacementDistance(from: point, to: corners[$0])
                    < Self.patternPlacementDistance(from: point, to: corners[$1])
            }), Self.patternPlacementDistance(from: point, to: corners[cornerIndex]) <= hitRadius {
                let oppositeAnchor = corners[(cornerIndex + 2) % 4]
                patternPlacementPhase = .transforming(
                    PatternPlacementTransformSession(
                        originalDraft: draft,
                        startCanvasPoint: point,
                        currentDraft: draft,
                        mode: .resize(oppositeAnchor: oppositeAnchor)
                    )
                )
            } else if rect.contains(CGPoint(x: point.x, y: point.y)) {
                patternPlacementPhase = .transforming(
                    PatternPlacementTransformSession(
                        originalDraft: draft,
                        startCanvasPoint: point,
                        currentDraft: draft,
                        mode: .move
                    )
                )
            }
            return
        }

        guard case .armed(let itemID) = patternPlacementPhase,
              workspace.patternLibrary.item(id: itemID) != nil else { return }

        if !placeIntoNewLayer,
           bootstrap.interactionController.activeEditableLayerID() == nil {
            showStatus(.init(kind: .info, message: "当前图层已锁定"))
            return
        }

        _ = flushBrushEditingBoundary(reason: "beginPatternPlacementDrag")

        guard let sourceTexture = patternPlacementTexture(for: itemID) else {
            showStatus(.init(kind: .error, message: "无法加载图案素材"))
            return
        }

        let aspectRatio = Double(sourceTexture.width) / Double(max(sourceTexture.height, 1))

        patternPlacementPhase = .dragging(
            PatternPlacementDraft(
                itemID: itemID,
                startCanvasPoint: point,
                currentCanvasPoint: point,
                destinationRect: PatternPlacementDraft.destinationRect(
                    startCanvasPoint: point,
                    currentCanvasPoint: point,
                    preservingAspectRatio: aspectRatio
                ),
                placementModeAtDragStart: placeIntoNewLayer ? .newLayer : .currentLayer,
                sourceAspectRatio: aspectRatio
            )
        )
    }

    func updatePatternPlacementDrag(to point: CanvasPoint) {
        switch patternPlacementPhase {
        case .dragging(let draft):
            patternPlacementPhase = .dragging(
                PatternPlacementDraft(
                    itemID: draft.itemID,
                    startCanvasPoint: draft.startCanvasPoint,
                    currentCanvasPoint: point,
                    destinationRect: PatternPlacementDraft.destinationRect(
                        startCanvasPoint: draft.startCanvasPoint,
                        currentCanvasPoint: point,
                        preservingAspectRatio: draft.sourceAspectRatio
                    ),
                    placementModeAtDragStart: draft.placementModeAtDragStart,
                    sourceAspectRatio: draft.sourceAspectRatio,
                    flipHorizontally: point.x < draft.startCanvasPoint.x,
                    flipVertically: point.y < draft.startCanvasPoint.y,
                    rotationDegrees: draft.rotationDegrees,
                    opacity: draft.opacity
                )
            )

        case .transforming(var session):
            var updated = session.originalDraft
            switch session.mode {
            case .move:
                let dx = point.x - session.startCanvasPoint.x
                let dy = point.y - session.startCanvasPoint.y
                updated.destinationRect = session.originalDraft.destinationRect.offsetBy(dx: dx, dy: dy)
                updated.startCanvasPoint = CanvasPoint(
                    x: session.originalDraft.startCanvasPoint.x + dx,
                    y: session.originalDraft.startCanvasPoint.y + dy
                )
                updated.currentCanvasPoint = CanvasPoint(
                    x: session.originalDraft.currentCanvasPoint.x + dx,
                    y: session.originalDraft.currentCanvasPoint.y + dy
                )

            case .resize(let oppositeAnchor):
                updated.startCanvasPoint = oppositeAnchor
                updated.currentCanvasPoint = point
                updated.destinationRect = PatternPlacementDraft.destinationRect(
                    startCanvasPoint: oppositeAnchor,
                    currentCanvasPoint: point,
                    preservingAspectRatio: updated.sourceAspectRatio
                )
                updated.flipHorizontally = point.x < oppositeAnchor.x
                updated.flipVertically = point.y < oppositeAnchor.y
            }
            session.currentDraft = updated
            patternPlacementPhase = .transforming(session)

        case .idle, .armed, .adjusting:
            return
        }
    }

    func endPatternPlacementDrag(at point: CanvasPoint) {
        updatePatternPlacementDrag(to: point)
        guard let finalizedDraft = patternPlacementPhase.draft else { return }

        guard finalizedDraft.destinationRect.width >= 4, finalizedDraft.destinationRect.height >= 4 else {
            patternPlacementPhase = .armed(itemID: finalizedDraft.itemID)
            return
        }

        patternPlacementPhase = .adjusting(finalizedDraft)
        showStatus(.init(kind: .info, message: "可移动或缩放图案，确认后再放入画面"))
    }

    func commitActivePatternPlacement() {
        guard patternPlacementPhase.isAdjusting,
              let draft = patternPlacementPhase.draft else { return }
        commitPatternPlacement(draft)
    }

    func rotateActivePatternPlacement(by degrees: Double) {
        guard var draft = patternPlacementPhase.draft else { return }
        draft.rotationDegrees = (draft.rotationDegrees + degrees).truncatingRemainder(dividingBy: 360)
        patternPlacementPhase = .adjusting(draft)
    }

    func flipActivePatternPlacementHorizontally() {
        guard var draft = patternPlacementPhase.draft else { return }
        draft.flipHorizontally.toggle()
        patternPlacementPhase = .adjusting(draft)
    }

    func flipActivePatternPlacementVertically() {
        guard var draft = patternPlacementPhase.draft else { return }
        draft.flipVertically.toggle()
        patternPlacementPhase = .adjusting(draft)
    }

    func setActivePatternPlacementOpacity(_ opacity: Float) {
        guard var draft = patternPlacementPhase.draft else { return }
        draft.opacity = min(max(opacity, 0.05), 1)
        patternPlacementPhase = .adjusting(draft)
    }

    nonisolated private static func patternPlacementDistance(
        from lhs: CanvasPoint,
        to rhs: CanvasPoint
    ) -> Double {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    func cancelPatternPlacement(keepSelection: Bool) {
        guard patternPlacementPhase != .idle else { return }
        patternPlacementPhase = .idle
        if !keepSelection {
            bootstrap.workspaceStore.updatePatternLibrary { library in
                library.selectItem(id: nil)
            }
            refreshLightweight()
        }
        showStatus(.init(kind: .info, message: "已取消图案放置"))
    }

    private func commitPatternPlacement(_ draft: PatternPlacementDraft) {
        guard let item = workspace.patternLibrary.item(id: draft.itemID) else {
            patternPlacementPhase = .idle
            showStatus(.init(kind: .info, message: "当前图案已不存在"))
            return
        }

        guard let sourceTexture = patternPlacementTexture(for: draft.itemID) else {
            patternPlacementPhase = .armed(itemID: draft.itemID)
            showStatus(.init(kind: .error, message: "无法加载图案素材"))
            return
        }

        guard let commandBuffer = bootstrap.metalContext.commandQueue.makeCommandBuffer() else {
            patternPlacementPhase = .armed(itemID: draft.itemID)
            showStatus(.init(kind: .error, message: "无法创建图案命令缓冲"))
            return
        }

        let targetLayerID: LayerID
        let targetTexture: MTLTexture
        let successMessage: String

        switch draft.placementModeAtDragStart {
        case .currentLayer:
            guard let layerID = bootstrap.interactionController.activeEditableLayerID() else {
                patternPlacementPhase = .armed(itemID: draft.itemID)
                showStatus(.init(kind: .info, message: "当前图层已锁定"))
                return
            }

            guard
                let texture = bootstrap.layerSurfaceStore.surfaceID(for: layerID).flatMap(bootstrap.layerSurfaceStore.texture(for:))
            else {
                patternPlacementPhase = .armed(itemID: draft.itemID)
                showStatus(.init(kind: .error, message: "无法访问当前图层"))
                return
            }

            guard checkpointSingleLayerHistoryIfPossible(
                layerID: layerID,
                operationKind: "patternPlacement.apply"
            ) else {
                patternPlacementPhase = .armed(itemID: draft.itemID)
                return
            }
            targetLayerID = layerID
            targetTexture = texture
            successMessage = "已贴入当前图层：\(item.displayName)"

        case .newLayer:
            guard ensureDocumentResourceBudget(
                additionalPaintLayers: 1,
                action: "新建图案图层"
            ) else {
                patternPlacementPhase = .armed(itemID: draft.itemID)
                return
            }
            guard checkpointHistoryIfPossible(
                operationKind: "patternPlacement.apply",
                topologyOperation: true,
                additionalOperationKinds: ["document.addLayer"],
                captureMode: .topologyDelta(changedLayerIDs: [])
            ) else {
                patternPlacementPhase = .armed(itemID: draft.itemID)
                return
            }

            var addedLayer: LayerRecord?
            bootstrap.workspaceStore.updateDocument { document in
                addedLayer = document.addLayer(named: item.displayName)
            }
            let updatedDocument = bootstrap.workspaceStore.state.document
            bootstrap.layerSurfaceStore.prepareTextures(
                for: updatedDocument,
                metal: bootstrap.metalContext
            )

            guard let addedLayer,
                  let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: addedLayer.id),
                  let texture = bootstrap.layerSurfaceStore.texture(for: surfaceID) else {
                patternPlacementPhase = .armed(itemID: draft.itemID)
                refresh()
                showStatus(.init(kind: .error, message: "无法创建图案图层"))
                return
            }

            targetLayerID = addedLayer.id
            targetTexture = texture
            successMessage = "已新建图层并放置图案：\(item.displayName)"
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = targetTexture
        renderPassDescriptor.colorAttachments[0].loadAction = .load
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        bootstrap.patternPlacementRenderer.encode(
            into: renderPassDescriptor,
            commandBuffer: commandBuffer,
            sourceTexture: sourceTexture,
            canvasSize: workspace.document.canvasSize,
            destinationRect: draft.destinationRect,
            flipHorizontally: draft.flipsHorizontally,
            flipVertically: draft.flipVertically,
            rotationDegrees: draft.rotationDegrees,
            opacity: draft.opacity
        )

        isApplyingPatternPlacementCommit = true
        patternPlacementPhase = .armed(itemID: draft.itemID)
        commandBuffer.addCompletedHandler { [weak self] completedBuffer in
            Task { @MainActor in
                guard let self else { return }
                self.isApplyingPatternPlacementCommit = false

                guard completedBuffer.status == .completed else {
                    let message = completedBuffer.error?.localizedDescription ?? "无法完成图案放置"
                    self.showStatus(.init(kind: .error, message: message))
                    return
                }

                self.bootstrap.workspaceStore.updatePatternLibrary { library in
                    library.noteItemUsed(draft.itemID)
                }
                self.persistPatternLibrary()

                switch draft.placementModeAtDragStart {
                case .currentLayer:
                    self.finalizeCommittedSingleLayerMutation(targetLayerID)
                case .newLayer:
                    self.noteCanvasContentChanged(changedLayerIDs: [targetLayerID])
                    self.refresh(invalidatedLayerIDs: [targetLayerID])
                    self.recordDrawingActivityIfNeeded()
                }
                self.showStatus(.init(kind: .success, message: successMessage))
            }
        }
        commandBuffer.commit()
    }

    var isPatternImportSheetPresented: Bool {
        patternImportSheetState.isPresented
    }

    func setPatternImportSheetPresented(_ isPresented: Bool) {
        if isPresented {
            presentPatternImportSheet()
        } else {
            dismissPatternImportSheet()
        }
    }

    func presentPatternImportSheet() {
        patternImportPreviewTask?.cancel()
        patternImportPreviewTask = nil
        patternImportSheetState = .init(isPresented: true)
        patternImportPreviewAsset = nil
        patternImportPreviewSourceFileURL = nil
        patternImportPreviewSourceAsset = nil
        patternImportEraseMasksByFileURL = [:]
        patternImportCurrentEraseMaskData = nil
        isPatternImportPreviewLoading = false
        isPatternImporting = false
    }

    func dismissPatternImportSheet() {
        patternImportPreviewTask?.cancel()
        patternImportPreviewTask = nil
        patternImportSheetState = .init()
        patternImportPreviewAsset = nil
        patternImportPreviewSourceFileURL = nil
        patternImportPreviewSourceAsset = nil
        patternImportEraseMasksByFileURL = [:]
        patternImportCurrentEraseMaskData = nil
        isPatternImportPreviewLoading = false
        isPatternImporting = false
    }

    func appendPatternImportFilesFromPanel() {
        bootstrap.filePanelService.presentImageOpenPanelURLs(
            allowsMultipleSelection: true,
            completion: documentScopedFileSelection { owner, urls in
                if let urls { owner.appendPatternImportFiles(urls) }
            }
        )
    }

    func appendPatternImportFolderFromPanel() {
        bootstrap.filePanelService.presentDirectorySelectionPanel(
            title: "选择图案素材文件夹",
            prompt: "加入",
            completion: documentScopedFileSelection { owner, url in
                if let url { owner.appendPatternImportFolder(at: url) }
            }
        )
    }

    private func appendPatternImportFolder(at directoryURL: URL) {
        let fileURLs = patternImportImageURLs(in: directoryURL)
        guard !fileURLs.isEmpty else {
            showStatus(.init(kind: .info, message: "所选文件夹中没有可导入的图片"))
            return
        }

        appendPatternImportFiles(fileURLs)
    }

    func clearPatternImportFiles() {
        patternImportSheetState.selectedFileURLs = []
        patternImportSheetState.previewFileURL = nil
        patternImportPreviewTask?.cancel()
        patternImportPreviewTask = nil
        patternImportPreviewAsset = nil
        patternImportPreviewSourceFileURL = nil
        patternImportPreviewSourceAsset = nil
        patternImportEraseMasksByFileURL = [:]
        patternImportCurrentEraseMaskData = nil
        isPatternImportPreviewLoading = false
    }

    func selectPatternImportPreviewFile(_ url: URL) {
        guard patternImportSheetState.selectedFileURLs.contains(url) else { return }
        patternImportSheetState.previewFileURL = url
        patternImportCurrentEraseMaskData = patternImportEraseMasksByFileURL[url]
        refreshPatternImportPreview()
    }

    func setPatternImportMode(_ mode: PatternImportMode) {
        guard patternImportSheetState.recipe.mode != mode else { return }
        patternImportSheetState.recipe.mode = mode
        refreshPatternImportPreview()
    }

    func setPatternImportContrast(_ value: Float) {
        let clamped = min(max(value, -1), 1)
        guard patternImportSheetState.recipe.contrast != clamped else { return }
        patternImportSheetState.recipe.contrast = clamped
        refreshPatternImportPreview()
    }

    func setPatternImportUsesSoftEdgeEraser(_ usesSoftEdge: Bool) {
        guard patternImportSheetState.usesSoftEdgeEraser != usesSoftEdge else { return }
        patternImportSheetState.usesSoftEdgeEraser = usesSoftEdge
    }

    func setPatternImportEraserRadius(_ value: Float) {
        let clamped = min(max(value, 6), 48)
        guard patternImportSheetState.eraserRadius != clamped else { return }
        patternImportSheetState.eraserRadius = clamped
    }

    func setPatternImportSoftEdgeEraserAmount(_ value: Float) {
        let clamped = min(max(value, 0), 1)
        guard patternImportSheetState.softEdgeEraserAmount != clamped else { return }
        patternImportSheetState.softEdgeEraserAmount = clamped
    }

    func updatePatternImportEraseMask(_ data: Data?) {
        guard let previewFileURL = patternImportSheetState.previewFileURL else { return }
        if let data, !data.isEmpty {
            patternImportEraseMasksByFileURL[previewFileURL] = data
            patternImportCurrentEraseMaskData = data
        } else {
            patternImportEraseMasksByFileURL.removeValue(forKey: previewFileURL)
            patternImportCurrentEraseMaskData = nil
        }
    }

    func clearPatternImportEraseMask() {
        guard let previewFileURL = patternImportSheetState.previewFileURL else { return }
        patternImportEraseMasksByFileURL.removeValue(forKey: previewFileURL)
        patternImportCurrentEraseMaskData = nil
        refreshPatternImportPreview()
    }

    func importPatternsFromSheet() {
        let selectedFileURLs = patternImportSheetState.selectedFileURLs
        guard !selectedFileURLs.isEmpty else {
            showStatus(.init(kind: .info, message: "请先选择至少一张图片"))
            return
        }

        let recipe = patternImportSheetState.recipe
        let controller = bootstrap.patternLibraryPersistenceController
        let currentLibrary = workspace.patternLibrary
        let eraseMaskDataByFileURL = patternImportEraseMasksByFileURL
        isPatternImporting = true

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let result = try controller.importFiles(
                    selectedFileURLs,
                    recipe: recipe,
                    eraseMaskDataByFileURL: eraseMaskDataByFileURL,
                    into: currentLibrary,
                    persistsLibrary: false
                )
                await MainActor.run {
                    guard let self else { return }
                    let mergedResult = Self.mergedPatternImportResult(
                        result,
                        into: self.bootstrap.workspaceStore.state.patternLibrary
                    )
                    let libraryDidChange = mergedResult.updatedLibrary != self.bootstrap.workspaceStore.state.patternLibrary
                    self.bootstrap.workspaceStore.updatePatternLibrary { library in
                        library = mergedResult.updatedLibrary
                    }
                    if libraryDidChange {
                        self.persistPatternLibrary()
                    }
                    self.isPatternImporting = false
                    self.patternImportPreviewTask?.cancel()
                    self.patternImportPreviewTask = nil
                    self.patternImportSheetState = .init()
                    self.patternImportPreviewAsset = nil
                    self.patternImportPreviewSourceFileURL = nil
                    self.patternImportPreviewSourceAsset = nil
                    self.patternImportEraseMasksByFileURL = [:]
                    self.patternImportCurrentEraseMaskData = nil
                    self.isPatternImportPreviewLoading = false
                    self.refreshLightweight()
                    self.showPatternImportResultStatus(mergedResult)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isPatternImporting = false
                    self.showStatus(.init(kind: .error, message: error.localizedDescription))
                }
            }
        }
    }

    func patternLibraryThumbnailURL(for item: PatternLibraryItem) -> URL? {
        bootstrap.patternLibraryPersistenceController.resolveAssetURL(for: item.thumbnailLocation)
    }

    private func appendPatternImportFiles(_ urls: [URL]) {
        let normalizedURLs = uniqueNormalizedPatternImportURLs(
            patternImportSheetState.selectedFileURLs + urls
        )
        patternImportSheetState.selectedFileURLs = normalizedURLs
        patternImportEraseMasksByFileURL = patternImportEraseMasksByFileURL.filter { normalizedURLs.contains($0.key) }

        if let previewFileURL = patternImportSheetState.previewFileURL,
           normalizedURLs.contains(previewFileURL) == false {
            patternImportSheetState.previewFileURL = normalizedURLs.first
        } else if patternImportSheetState.previewFileURL == nil {
            patternImportSheetState.previewFileURL = normalizedURLs.first
        }

        patternImportCurrentEraseMaskData = patternImportSheetState.previewFileURL.flatMap {
            patternImportEraseMasksByFileURL[$0]
        }
        refreshPatternImportPreview()
    }

    private func refreshPatternImportPreview() {
        patternImportPreviewTask?.cancel()
        patternImportPreviewTask = nil

        guard let previewFileURL = patternImportSheetState.previewFileURL else {
            patternImportPreviewAsset = nil
            patternImportCurrentEraseMaskData = nil
            isPatternImportPreviewLoading = false
            return
        }

        let recipe = patternImportSheetState.recipe
        let controller = bootstrap.patternLibraryPersistenceController
        let cachedSourceFileURL = patternImportPreviewSourceFileURL
        let cachedSourceAsset = patternImportPreviewSourceAsset
        isPatternImportPreviewLoading = true
        patternImportCurrentEraseMaskData = patternImportEraseMasksByFileURL[previewFileURL]

        patternImportPreviewTask = Task.detached(priority: .userInitiated) { [weak self] in
            let sourceAsset: PatternImportPreviewSourceAsset?
            if cachedSourceFileURL == previewFileURL, let cachedSourceAsset {
                sourceAsset = cachedSourceAsset
            } else {
                sourceAsset = controller.makePreviewSource(for: previewFileURL)
            }
            let preview = sourceAsset.flatMap {
                controller.makePreview(from: $0, recipe: recipe)
            }
            await MainActor.run {
                guard let self else { return }
                guard self.patternImportSheetState.previewFileURL == previewFileURL else { return }
                if let sourceAsset {
                    self.patternImportPreviewSourceFileURL = previewFileURL
                    self.patternImportPreviewSourceAsset = sourceAsset
                } else {
                    self.patternImportPreviewSourceFileURL = nil
                    self.patternImportPreviewSourceAsset = nil
                }
                self.patternImportPreviewAsset = preview
                self.isPatternImportPreviewLoading = false
            }
        }
    }

    nonisolated static func mergedPatternImportResult(
        _ result: PatternLibraryImportBatchResult,
        into currentLibrary: PatternLibraryState
    ) -> PatternLibraryImportBatchResult {
        var mergedLibrary = currentLibrary
        var mergedImportedItems: [PatternLibraryItem] = []
        var skippedDuplicateCount = result.skippedDuplicateCount

        for item in result.importedItems {
            let alreadyPresent = mergedLibrary.items.contains { existing in
                existing.id == item.id || existing.renderAssetLocation == item.renderAssetLocation
            }
            guard !alreadyPresent else {
                skippedDuplicateCount += 1
                continue
            }

            var mergedItem = item
            mergedItem.slotIndex = mergedLibrary.firstEmptySlotIndex()
            mergedLibrary.items.append(mergedItem)
            mergedImportedItems.append(mergedItem)
        }

        if let firstImportedID = mergedImportedItems.first?.id {
            mergedLibrary.selectedItemID = firstImportedID
        }

        return PatternLibraryImportBatchResult(
            updatedLibrary: mergedLibrary,
            importedItems: mergedImportedItems,
            skippedDuplicateCount: skippedDuplicateCount,
            failedFileNames: result.failedFileNames
        )
    }

    private func showPatternImportResultStatus(_ result: PatternLibraryImportBatchResult) {
        let importedCount = result.importedItems.count
        let skippedCount = result.skippedDuplicateCount
        let failedCount = result.failedFileNames.count

        if importedCount == 0, skippedCount == 0, failedCount > 0 {
            showStatus(.init(kind: .error, message: "图案导入失败，共 \(failedCount) 个文件未能处理"))
            return
        }

        var fragments: [String] = []
        if importedCount > 0 {
            fragments.append("已导入 \(importedCount) 个图案")
        }
        if skippedCount > 0 {
            fragments.append("跳过 \(skippedCount) 个重复图案")
        }
        if failedCount > 0 {
            fragments.append("\(failedCount) 个文件处理失败")
        }

        let message = fragments.joined(separator: "，")
        showStatus(.init(
            kind: failedCount > 0 ? .info : .success,
            message: message.isEmpty ? "没有可导入的图案" : message
        ))
    }

    private func patternImportImageURLs(in directoryURL: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentTypeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [URL] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let contentType = values.contentType,
                  contentType.conforms(to: .image) else {
                continue
            }
            results.append(url)
        }

        return results.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    private func uniqueNormalizedPatternImportURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []

        for url in urls {
            let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
            if seen.insert(normalized.path).inserted {
                result.append(normalized)
            }
        }

        return result
    }

    func exportBrushLibrary() {
        let defaultName = workspace.document.metadata.name.isEmpty ? "ArtFlex-BrushLibrary" : workspace.document.metadata.name
        bootstrap.filePanelService.presentBrushLibraryExportPanel(
            defaultName: defaultName,
            completion: documentScopedFileSelection { owner, url in
                if let url { owner.exportBrushLibrary(to: url) }
            }
        )
    }

    private func exportBrushLibrary(to url: URL) {
        do {
            try bootstrap.brushLibraryPersistenceController.exportLibrary(
                workspace.brushLibrary,
                tipImageLibrary: workspace.tipImageLibrary,
                to: url
            )
            showStatus(.init(kind: .success, message: "已导出画笔库"))
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func importBrushLibraryReplacing() {
        importBrushLibrary(mode: .replace)
    }

    func importBrushLibraryAppending() {
        importBrushLibrary(mode: .append)
    }

    func setFillTolerance(_ tolerance: Float) {
        fillSettings.tolerance = tolerance.isFinite ? min(max(tolerance, 0), 1) : 0
    }

    func setFillContiguous(_ isContiguous: Bool) {
        fillSettings.isContiguous = isContiguous
    }

    func setFillSampleSource(_ source: FillSampleSource) {
        fillSettings.sampleSource = source
    }

    func setFillCloseGapPixels(_ value: Int) {
        fillSettings.closeGapPixels = min(max(value, 0), 16)
    }

    func setFillExpandPixels(_ value: Int) {
        fillSettings.expandPixels = min(max(value, 0), 8)
    }

    func resetFillSettings() {
        fillSettings = .stageOneDefault
    }

    func setSmartSelectionTolerance(_ tolerance: Int) {
        mutateSmartSelectionSettings { $0.tolerance = min(max(tolerance, 0), 255) }
    }

    func setSmartSelectionSampleSize(_ sampleSize: MagicWandSampleSize) {
        mutateSmartSelectionSettings { $0.sampleSize = sampleSize }
    }

    func setSmartSelectionAntiAliased(_ isEnabled: Bool) {
        mutateSmartSelectionSettings { $0.isAntiAliased = isEnabled }
    }

    func setSmartSelectionContiguous(_ isEnabled: Bool) {
        mutateSmartSelectionSettings { $0.isContiguous = isEnabled }
    }

    func setSmartSelectionSampleSource(_ source: MagicWandSampleSource) {
        mutateSmartSelectionSettings { $0.sampleSource = source }
    }

    func setSmartSelectionMode(_ mode: MagicWandSelectionMode) {
        mutateSmartSelectionSettings { $0.selectionMode = mode }
    }

    private func mutateSmartSelectionSettings(_ mutation: (inout SmartSelectionSettings) -> Void) {
        var settings = smartSelectionSettings
        mutation(&settings)
        smartSelectionSettings = SmartSelectionSettings(
            tolerance: settings.tolerance,
            sampleSize: settings.sampleSize,
            isAntiAliased: settings.isAntiAliased,
            isContiguous: settings.isContiguous,
            sampleSource: settings.sampleSource,
            selectionMode: settings.selectionMode
        )
    }

    func resetSmartSelectionSettings() {
        smartSelectionSettings = .stageOneDefault
    }

    @discardableResult
    private func toggleSmartSelectionDisplayModeIfPossible(_ event: NSEvent) -> Bool {
        guard workspace.toolSession.activeTool == .smartSelection else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isEmpty,
              event.keyCode == 36 || event.keyCode == 76,
              workspace.selection.inProgressShape == nil,
              !isRefiningSelection,
              workspace.selection.committedShape?.kind == .mask else {
            return false
        }
        smartSelectionDisplayMode = smartSelectionDisplayMode == .tint ? .marchingAnts : .tint
        syncSelectionOverlayProxy()
        showStatus(.init(
            kind: .info,
            message: smartSelectionDisplayMode == .tint
                ? "魔棒选区显示为半透明覆盖"
                : "魔棒选区显示为蚂蚁线",
            shortcutLabel: "Enter"
        ))
        return true
    }

    @discardableResult
    private func applySmartSelectionThresholdShortcut(_ event: NSEvent) -> Bool {
        guard workspace.toolSession.activeTool == .smartSelection else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isEmpty,
              let characters = event.charactersIgnoringModifiers,
              characters.count == 1,
              let digit = Int(characters),
              (0...9).contains(digit) else {
            return false
        }
        let percent = digit == 0 ? 100 : digit * 10
        setSmartSelectionTolerance(Int((Double(percent) * 2.55).rounded()))
        showStatus(.init(
            kind: .info,
            message: "魔棒容差已设为 \(smartSelectionSettings.tolerance)（\(percent)%）",
            shortcutLabel: characters
        ))
        return true
    }

    func fillAtPoint(_ point: CanvasPoint) {
        ideationBranchActivityHandler?()
        guard let layerID = bootstrap.interactionController.activeEditableLayerID() else {
            showStatus(.init(kind: .info, message: "当前图层已锁定"))
            return
        }

        do {
            _ = flushBrushEditingBoundary(reason: "fillAtPoint.makePlan")
            guard let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: layerID),
                  let destinationTexture = bootstrap.layerSurfaceStore.texture(for: surfaceID) else {
                showStatus(.init(kind: .error, message: "无法访问当前图层"))
                return
            }
            let topology = try makeFillTopologyReference(for: fillSettings.sampleSource)
            guard topology.isAvailable else {
                showStatus(.init(kind: .info, message: "当前没有可见的填充参考图层"))
                return
            }
            let referenceTexture = topology.texture
            let fillPlan: BucketFillPlan?
            if let referenceTexture {
                fillPlan = try bootstrap.bucketFillEngine.makeReferencedFillPlan(
                    layerID: layerID,
                    destinationTexture: destinationTexture,
                    referenceTexture: referenceTexture,
                    at: point,
                    color: workspace.toolSession.selectedColor,
                    alphaLockEnabled: layerTransparentPixelLockEnabled(layerID),
                    selectionShape: workspace.selection.committedShape,
                    settings: fillSettings
                )
            } else {
                fillPlan = try bootstrap.bucketFillEngine.makeFillPlan(
                    layerID: layerID,
                    at: point,
                    color: workspace.toolSession.selectedColor,
                    alphaLockEnabled: layerTransparentPixelLockEnabled(layerID),
                    selectionShape: workspace.selection.committedShape,
                    layerSurfaceStore: bootstrap.layerSurfaceStore,
                    settings: fillSettings
                )
            }
            guard let fillPlan else {
                showStatus(.init(kind: .info, message: "填充无变化"))
                return
            }
            try applyBucketFillPlan(fillPlan, layerID: layerID, point: point)
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func requestFillAtPoint(_ point: CanvasPoint) {
        ideationBranchActivityHandler?()
        guard !isBucketFillInProgress else { return }
        if fillSettings.closeGapPixels > 0 || fillSettings.expandPixels > 0 {
            guard ensureDocumentResourceBudget(
                additionalWorkingBytes: workspace.document.canvasSize.width * workspace.document.canvasSize.height * 40,
                action: "线稿填色"
            ) else { return }
        }
        _ = flushBrushEditingBoundary(reason: "requestFillAtPoint.makePlan")
        guard !bootstrap.strokeEngine.hasPendingBrushWork,
              !bootstrap.strokeEngine.hasPendingBrushCommitJobs else { return }
        guard let layerID = bootstrap.interactionController.activeEditableLayerID() else {
            showStatus(.init(kind: .info, message: "当前图层已锁定"))
            return
        }
        guard
            let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: layerID),
            let texture = bootstrap.layerSurfaceStore.texture(for: surfaceID)
        else {
            showStatus(.init(kind: .error, message: "无法访问当前图层"))
            return
        }

        let capturedRevision = canvasContentRevision
        let capturedColor = workspace.toolSession.selectedColor
        let capturedAlphaLock = layerTransparentPixelLockEnabled(layerID)
        let capturedSelection = workspace.selection.committedShape
        let capturedKnownTransparent = bootstrap.layerSurfaceStore.isKnownTransparent(layerID: layerID)
        let referenceTexture: MTLTexture?
        do {
            let topology = try makeFillTopologyReference(for: fillSettings.sampleSource)
            guard topology.isAvailable else {
                showStatus(.init(kind: .info, message: "当前没有可见的填充参考图层"))
                return
            }
            referenceTexture = topology.texture
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
            return
        }
        let engineBox = WorkspaceUncheckedBox(bootstrap.bucketFillEngine)
        let textureBox = WorkspaceUncheckedBox(texture)
        let referenceTextureBox = referenceTexture.map(WorkspaceUncheckedBox.init)
        let capturedFillSettings = fillSettings
        let cancellation = WorkCancellation()
        bucketFillCancellation = cancellation

        bucketFillRequestID &+= 1
        let requestID = bucketFillRequestID
        isBucketFillInProgress = true
        showStatus(.init(kind: .info, message: referenceTexture == nil ? "正在填充区域…" : "正在按参考图层填充区域…"))

        bucketFillTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    if let referenceTextureBox {
                        try engineBox.value.makeReferencedFillPlan(
                            layerID: layerID,
                            destinationTexture: textureBox.value,
                            referenceTexture: referenceTextureBox.value,
                            at: point,
                            color: capturedColor,
                            alphaLockEnabled: capturedAlphaLock,
                            selectionShape: capturedSelection,
                            settings: capturedFillSettings, cancellation: cancellation
                        )
                    } else {
                        try engineBox.value.makeFillPlan(
                            layerID: layerID,
                            texture: textureBox.value,
                            at: point,
                            color: capturedColor,
                            alphaLockEnabled: capturedAlphaLock,
                            selectionShape: capturedSelection,
                            isKnownTransparent: capturedKnownTransparent,
                            settings: capturedFillSettings, cancellation: cancellation
                        )
                    }
                }
            }.value

            guard let self, self.bucketFillRequestID == requestID else { return }
            self.bucketFillTask = nil
            self.bucketFillCancellation = nil
            self.isBucketFillInProgress = false
            guard !Task.isCancelled else { return }

            guard
                self.canvasContentRevision == capturedRevision,
                self.bootstrap.layerSurfaceStore.surfaceID(for: layerID) == surfaceID,
                let currentTexture = self.bootstrap.layerSurfaceStore.texture(for: surfaceID),
                ObjectIdentifier(currentTexture as AnyObject) == ObjectIdentifier(textureBox.value as AnyObject)
            else {
                self.showStatus(.init(kind: .info, message: "画布已变化，已取消本次填充"))
                return
            }

            do {
                guard let fillPlan = try result.get() else {
                    self.showStatus(.init(kind: .info, message: "填充无变化"))
                    return
                }
                try self.applyBucketFillPlan(fillPlan, layerID: layerID, point: point)
            } catch {
                self.showStatus(.init(kind: .error, message: error.localizedDescription))
            }
        }
    }

    func cancelBucketFill() {
        bucketFillCancellation?.cancel()
        bucketFillCancellation = nil
        bucketFillTask?.cancel()
        bucketFillTask = nil
        bucketFillRequestID &+= 1
        isBucketFillInProgress = false
        showStatus(.init(kind: .info, message: "已取消填充，画布未改变"))
    }

    private func applyBucketFillPlan(
        _ fillPlan: BucketFillPlan,
        layerID: LayerID,
        point: CanvasPoint
    ) throws {
        let captureMode: HistoryCaptureMode
#if DEBUG
        captureMode = debugFillAtPointHistoryCaptureModeOverride ?? .inPlaceChangedLayers([layerID])
#else
        captureMode = .inPlaceChangedLayers([layerID])
#endif

        let auditContext = HistoryEligibilityAuditContext(
            operationKind: "fillAtPoint",
            candidateChangedLayerIDs: [layerID],
            candidateChangedLayerIDsKnown: true,
            comparisonWorkspace: captureHistoryEligibilityComparisonWorkspace()
        )
        if let historySnapshot = fillPlan.historySnapshot {
            try bootstrap.historyController.captureCheckpoint(
                captureMode: captureMode,
                providedLayerSnapshots: [historySnapshot],
                auditContext: auditContext
            )
            hasUnsavedChanges = true
            canUndo = bootstrap.historyController.canUndo
            canRedo = bootstrap.historyController.canRedo
        } else {
            checkpointHistoryIfPossible(
                operationKind: "fillAtPoint",
                candidateChangedLayerIDs: [layerID],
                captureMode: captureMode
            )
        }

        try bootstrap.bucketFillEngine.apply(fillPlan, layerSurfaceStore: bootstrap.layerSurfaceStore)
        layerThumbnailCache.removeValue(forKey: layerID)
        bootstrap.strokeEngine.resetBrushPipelineState()
        clearRecentBrushAdjustmentState()
        refresh(invalidatedLayerIDs: [layerID])
        noteCanvasContentChanged(changedLayerIDs: [layerID])
        recordDrawingActivityIfNeeded()
        showStatus(.init(kind: .success, message: "已填充区域"))
        relayIdeationOperation(.fillAtPoint(point))
    }

    func resetViewport() {
        fitCanvasToWindow()
    }

    func fitCanvasToWindow() {
        guard !isCanvasViewportLocked else { return }
        bootstrap.workspaceStore.updateViewport { viewport in
            viewport = .stageOneDefault
        }
        refreshLightweight()
    }

    func setCanvasToActualPixels() {
        guard !isCanvasViewportLocked, let transform = currentCanvasViewportTransform else { return }
        let targetZoomScale = 1 / max(transform.fitScale, 0.000_001)
        bootstrap.workspaceStore.updateViewport { viewport in
            viewport.zoomScale = min(max(targetZoomScale, 0.01), 256)
            viewport.contentOffset = .init(x: 0, y: 0)
        }
        refreshLightweight()
    }

    func setCanvasViewportLocked(_ isLocked: Bool) {
        guard isCanvasViewportLocked != isLocked else { return }
        isCanvasViewportLocked = isLocked
        if isLocked {
            isPanModeActive = false
        }
    }

    func toggleLuminosityPreview() {
        isLuminosityPreviewEnabled.toggle()
    }

    func toggleCanvasHorizontalFlip() {
        bootstrap.workspaceStore.updateViewport { viewport in
            viewport.isHorizontallyFlipped.toggle()
        }
        refreshLightweight()
        showStatus(.init(
            kind: .info,
            message: workspace.viewport.isHorizontallyFlipped ? "已水平翻转画布" : "已恢复画布方向"
        ))
    }

    func updateCanvasViewportSize(_ size: CGSize) {
        guard size.width.isFinite, size.height.isFinite else { return }
        guard abs(size.width - latestCanvasViewportSize.width) > 0.5 ||
                abs(size.height - latestCanvasViewportSize.height) > 0.5 else { return }
        latestCanvasViewportSize = size
        canvasViewportMetricsRevision &+= 1
    }

    private func makeNavigatorSceneSnapshot(from snapshot: CanvasSceneSnapshot) -> CanvasSceneSnapshot {
        var navigatorSnapshot = snapshot
        navigatorSnapshot.renderSnapshot.viewport = .stageOneDefault
        navigatorSnapshot.renderSnapshot.viewportRevision = 0
        navigatorSnapshot.selectionShape = nil
        navigatorSnapshot.selectionRevision = 0
        return navigatorSnapshot
    }

    var navigatorSceneSnapshot: CanvasSceneSnapshot {
        makeNavigatorSceneSnapshot(from: sceneSnapshot)
    }

    var navigatorZoomPercent: Double {
        currentCanvasViewportTransform?.actualZoomPercent ?? workspace.viewport.zoomScale * 100
    }

    func setNavigatorZoomPercent(_ percent: Double) {
        let clampedPercent = min(max(percent, 5), 3200)
        guard let transform = currentCanvasViewportTransform else {
            setViewportZoomScale(clampedPercent / 100)
            return
        }
        setViewportZoomScale((clampedPercent / 100) / max(transform.fitScale, 0.000_001))
    }

    private var currentCanvasViewportTransform: CanvasViewportTransform? {
        guard latestCanvasViewportSize.width > 0, latestCanvasViewportSize.height > 0 else { return nil }
        return CanvasViewportTransform(
            canvasSize: workspace.document.canvasSize,
            viewport: workspace.viewport,
            availableWidth: latestCanvasViewportSize.width,
            availableHeight: latestCanvasViewportSize.height
        )
    }

    func navigatorVisibleCanvasPolygon() -> [CanvasPoint]? {
        guard
            let transform = currentCanvasViewportTransform,
            workspace.document.canvasSize.width > 0,
            workspace.document.canvasSize.height > 0
        else {
            return nil
        }

        let viewportCorners = [
            CanvasPoint(x: 0, y: 0),
            CanvasPoint(x: latestCanvasViewportSize.width, y: 0),
            CanvasPoint(x: latestCanvasViewportSize.width, y: latestCanvasViewportSize.height),
            CanvasPoint(x: 0, y: latestCanvasViewportSize.height)
        ]

        let canvasPolygon = viewportCorners.map { point in
            transform.viewportToCanvas(point, clamped: false)
        }
        let clipped = NavigatorGeometry.clippedCanvasPolygon(
            canvasPolygon,
            canvasSize: workspace.document.canvasSize
        )
        return clipped.count >= 3 ? clipped : nil
    }

    func setNavigatorPreviewVisible(_ isVisible: Bool) {
        guard isNavigatorPreviewVisible != isVisible else { return }
        isNavigatorPreviewVisible = isVisible

        if isVisible {
            if navigatorPreviewHasPendingRefresh {
                schedulePendingNavigatorPreviewRefreshIfNeeded()
            } else {
                syncNavigatorPreviewProxy()
            }
        } else {
            navigatorPreviewRefreshTask?.cancel()
            navigatorPreviewRefreshTask = nil
        }
    }

    func setReferenceImageInspectorVisible(_ isVisible: Bool) {
        guard isReferenceImageInspectorVisible != isVisible else { return }
        isReferenceImageInspectorVisible = isVisible

        if isVisible {
            scheduleLuminosityCaptureIfNeeded(after: Self.luminosityReferenceVisibleResumeDelay)
        } else {
            cancelScheduledLuminosityCaptureIfNotVisible()
        }
    }

    func refreshNavigatorPreviewNow() {
        navigatorPreviewRefreshTask?.cancel()
        navigatorPreviewRefreshTask = nil
        performNavigatorPreviewRefresh()
    }

#if DEBUG
    var debugNavigatorPreviewHasPendingRefresh: Bool {
        navigatorPreviewHasPendingRefresh
    }
#endif

    private func performNavigatorPreviewRefresh() {
        syncNavigatorPreviewProxy()
        navigatorPreviewProxy.redrawRevision &+= 1
        navigatorPreviewHasPendingRefresh = false
        lastNavigatorPreviewRefreshUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
    }

    private var isLuminosityReferencePreviewVisible: Bool {
        guard isCanvasLuminosityReferenceActive,
              selectedReferenceImageSlotID == luminosityReferenceSlotID
        else {
            return false
        }

        return isReferenceImageInspectorVisible || isReferenceImageFloatingPanelPresented
    }

    private func cancelScheduledLuminosityCaptureIfNotVisible() {
        guard isLuminosityReferencePreviewVisible == false else { return }
        luminosityCaptureTask?.cancel()
        luminosityCaptureTask = nil
    }

    private func scheduleLuminosityCaptureIfSourceChanged(
        previousSceneSnapshot: CanvasSceneSnapshot,
        currentSceneSnapshot: CanvasSceneSnapshot
    ) {
        guard previousSceneSnapshot.renderSnapshot.document != currentSceneSnapshot.renderSnapshot.document ||
                previousSceneSnapshot.layerSurfaces != currentSceneSnapshot.layerSurfaces
        else {
            return
        }

        luminosityReferenceSourceRevision &+= 1
        scheduleLuminosityCaptureIfNeeded(after: Self.luminosityReferenceAutoRefreshDelay)
    }

    private func scheduleLuminosityCaptureIfNeeded(
        after delay: Duration = WorkspaceViewModel.luminosityReferenceAutoRefreshDelay
    ) {
        guard isCanvasLuminosityReferenceActive else { return }

        let currentRevision = luminosityReferenceSourceRevision
        guard currentRevision != lastLuminosityCaptureRevision else {
            if isLuminosityReferencePreviewVisible {
                luminosityReferenceHasPendingRefresh = false
            }
            return
        }

        luminosityReferenceHasPendingRefresh = true
        guard isLuminosityReferencePreviewVisible else { return }

        luminosityCaptureTask?.cancel()
        luminosityCaptureTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard self.isLuminosityReferencePreviewVisible else { return }

            let scheduledRevision = self.luminosityReferenceSourceRevision
            guard scheduledRevision != self.lastLuminosityCaptureRevision else {
                self.luminosityReferenceHasPendingRefresh = false
                self.luminosityCaptureTask = nil
                return
            }

            self.lastLuminosityCaptureRevision = scheduledRevision
            self.luminosityReferenceHasPendingRefresh = false
            self.luminosityCaptureTask = nil
            self.captureCanvasLuminositySnapshot()
        }
    }

    private func scheduleNavigatorPreviewRefresh() {
        navigatorPreviewRequestRevision &+= 1
        navigatorPreviewHasPendingRefresh = true
        schedulePendingNavigatorPreviewRefreshIfNeeded()
    }

    private func schedulePendingNavigatorPreviewRefreshIfNeeded() {
        guard isNavigatorPreviewVisible else { return }
        guard navigatorPreviewRefreshTask == nil else { return }

        let now = DispatchTime.now().uptimeNanoseconds
        let remainingNanoseconds = Self.navigatorPreviewRefreshDelayNanoseconds(
            now: now,
            lastRefresh: lastNavigatorPreviewRefreshUptimeNanoseconds
        )

        let scheduledRequestRevision = navigatorPreviewRequestRevision
        navigatorPreviewRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .nanoseconds(Int64(remainingNanoseconds)))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.navigatorPreviewRefreshTask = nil
            guard self.isNavigatorPreviewVisible else { return }
            guard self.navigatorPreviewHasPendingRefresh else { return }

            let needsTrailingRefresh = self.navigatorPreviewRequestRevision != scheduledRequestRevision
            self.performNavigatorPreviewRefresh()
            if needsTrailingRefresh {
                self.navigatorPreviewHasPendingRefresh = true
                self.schedulePendingNavigatorPreviewRefreshIfNeeded()
            }
        }
    }

    private func scheduleNavigatorPreviewRefreshIfSourceChanged(
        previousSceneSnapshot: CanvasSceneSnapshot,
        currentSceneSnapshot: CanvasSceneSnapshot
    ) {
        let previousNavigatorSnapshot = makeNavigatorSceneSnapshot(from: previousSceneSnapshot)
        let currentNavigatorSnapshot = makeNavigatorSceneSnapshot(from: currentSceneSnapshot)
        guard previousNavigatorSnapshot != currentNavigatorSnapshot else { return }
        scheduleNavigatorPreviewRefresh()
    }

    func zoomIn() {
        setViewportZoomScale(workspace.viewport.zoomScale * 1.2)
    }

    func zoomOut() {
        setViewportZoomScale(workspace.viewport.zoomScale / 1.2)
    }

    func adjustViewportZoom(byScaleMultiplier multiplier: Double) {
        adjustViewportZoom(byScaleMultiplier: multiplier, anchoredAt: lastCanvasHoverPoint)
    }

    func adjustViewportZoom(
        byScaleMultiplier multiplier: Double,
        anchoredAt anchorPoint: CanvasPoint?
    ) {
        guard multiplier.isFinite, multiplier > 0 else { return }
        setViewportZoomScale(workspace.viewport.zoomScale * multiplier, anchoredAt: anchorPoint)
    }

    private func setViewportZoomScale(
        _ newZoomScale: Double,
        anchoredAt explicitAnchorPoint: CanvasPoint? = nil
    ) {
        guard !isCanvasViewportLocked else { return }
        let anchorPoint = explicitAnchorPoint ?? lastCanvasHoverPoint
        let canvasSize = workspace.document.canvasSize
        let viewportSize = latestCanvasViewportSize
        bootstrap.workspaceStore.updateViewport { viewport in
            viewport.setZoomScale(
                newZoomScale,
                anchoredAt: anchorPoint,
                canvasSize: canvasSize,
                availableWidth: viewportSize.width,
                availableHeight: viewportSize.height
            )
        }
        refreshLightweight()
    }

    func centerViewport(on canvasPoint: CanvasPoint) {
        guard !isCanvasViewportLocked, let transform = currentCanvasViewportTransform else { return }
        let clampedPoint = transform.clampToCanvas(canvasPoint)
        let offset = transform.viewportOffsetCentering(on: clampedPoint)
        setViewportOffset(x: offset.x, y: offset.y)
    }

    func panViewport(deltaX: Double, deltaY: Double) {
        guard !isCanvasViewportLocked else { return }
        bootstrap.workspaceStore.updateViewport { viewport in
            viewport.contentOffset.x += deltaX
            viewport.contentOffset.y += deltaY
        }
        refreshLightweight()
    }

    func setViewportOffset(x: Double, y: Double) {
        guard !isCanvasViewportLocked else { return }
        bootstrap.workspaceStore.updateViewport { viewport in
            viewport.contentOffset = CanvasPoint(x: x, y: y)
        }
        refreshLightweight()
    }

    func setViewportRotation(_ angleDegrees: Double) {
        guard !isCanvasViewportLocked else { return }
        bootstrap.workspaceStore.updateViewport { viewport in
            viewport.rotationDegrees = Self.normalizedViewportRotation(angleDegrees)
        }
        refreshLightweight()
    }

    func setPanModeActive(_ isActive: Bool) {
        guard !isCanvasViewportLocked || !isActive else { return }
        isPanModeActive = isActive
        if isActive {
            showStatus(.init(kind: .info, message: "已开启平移模式"))
        } else {
            showStatus(.init(kind: .info, message: "已关闭平移模式"))
        }
    }

    func beginCanvasCrop(at point: CanvasPoint, handleRadius: Double) {
        guard workspace.toolSession.activeTool == .canvasCrop else { return }
        canvasCropState.begin(
            at: point,
            canvasSize: workspace.document.canvasSize,
            handleRadius: handleRadius
        )
    }

    func updateCanvasCrop(to point: CanvasPoint) {
        guard workspace.toolSession.activeTool == .canvasCrop else { return }
        canvasCropState.update(to: point, canvasSize: workspace.document.canvasSize)
    }

    func endCanvasCrop(at point: CanvasPoint) {
        guard workspace.toolSession.activeTool == .canvasCrop else { return }
        canvasCropState.end(at: point, canvasSize: workspace.document.canvasSize)
    }

    func cancelCanvasCrop() {
        guard canvasCropState.bounds != nil || canvasCropState.isDragging else { return }
        canvasCropState.cancel()
        showStatus(.init(kind: .info, message: "已取消画布裁剪"))
    }

    func applyCanvasCrop() {
        guard workspace.toolSession.activeTool == .canvasCrop else { return }
        guard let cropBounds = canvasCropState.pixelBounds(in: workspace.document.canvasSize) else {
            showStatus(.init(kind: .info, message: "请先拖出裁剪区域"))
            return
        }
        let sourceX = Int(cropBounds.minX), sourceY = Int(cropBounds.minY)
        let targetSize = CanvasSize(width: Int(cropBounds.size.x), height: Int(cropBounds.size.y))
        guard targetSize.width > 0, targetSize.height > 0 else { return }
        guard sourceX != 0 || sourceY != 0 || targetSize != workspace.document.canvasSize else {
            showStatus(.init(kind: .info, message: "裁剪区域与当前画布相同"))
            return
        }
        _ = flushBrushEditingBoundary(reason: "canvasCrop")
        guard !bootstrap.strokeEngine.hasPendingBrushWork,
              !bootstrap.strokeEngine.hasPendingBrushCommitJobs else {
            showStatus(.init(kind: .error, message: "仍有笔触未完成，暂不能裁剪"))
            return
        }
        guard ensureDocumentResourceBudget(
            additionalWorkingBytes: targetSize.width * targetSize.height
                * (workspace.document.paintLayers.count * 4 + workspace.document.paintLayers.filter { $0.mask != nil }.count),
            action: "裁剪画布"
        ) else { return }
        do {
            let prepared = try LayerSurfaceTransfer.prepare(
                document: workspace.document, source: bootstrap.layerSurfaceStore,
                metal: bootstrap.metalContext, targetSize: targetSize, originX: sourceX, originY: sourceY
            )
            let layerIDs = workspace.document.paintLayers.map(\.id)
            guard checkpointHistoryIfPossible(
                operationKind: "canvas.crop", candidateChangedLayerIDs: layerIDs,
                topologyOperation: true, captureMode: .full
            ) else { return }
            ideationBranchActivityHandler?()
            bootstrap.workspaceStore.updateDocument { document in
                document.perspectiveGuide = document.perspectiveGuide?.cropped(originX: sourceX, originY: sourceY)
                document.canvasSize = targetSize
            }
            bootstrap.workspaceStore.updateSelection { $0 = .empty }
            bootstrap.workspaceStore.updateViewport { $0 = .stageOneDefault }
            bootstrap.layerSurfaceStore.adoptContents(of: prepared)
            canvasCropState.cancel()
            bootstrap.strokeEngine.resetBrushPipelineState()
            clearRecentBrushAdjustmentState()
            invalidateWholeLayerInteractionBoundsCache()
            refresh()
            noteCanvasContentChanged(changedLayerIDs: Set(layerIDs))
            relayIdeationOperation(.applyCanvasCrop(cropBounds))
            showStatus(.init(kind: .success, message: "已调整画布为 \(targetSize.width) × \(targetSize.height)，图层与蒙版均已保留"))
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func addLayer() {
        guard ensureDocumentResourceBudget(
            additionalPaintLayers: 1,
            action: "新增图层"
        ) else { return }
        guard checkpointHistoryIfPossible(
            operationKind: "layer.add",
            topologyOperation: true,
            captureMode: .topologyDelta(changedLayerIDs: [])
        ) else { return }
        var addedLayerID: LayerID?
        bootstrap.workspaceStore.updateDocument { document in
            addedLayerID = document.addLayer().id
        }
        refresh()
        noteCanvasContentChanged()
        if let addedLayerID {
            bootstrap.layerSurfaceStore.markKnownTransparent(for: addedLayerID)
        }
        showStatus(.init(kind: .success, message: "已新增图层"))
    }

    func addCurveAdjustmentLayer() {
        guard ensureDocumentResourceBudget(
            additionalPaintLayers: 1,
            action: "新增调整层"
        ) else { return }
        guard checkpointHistoryIfPossible(
            operationKind: "layer.addCurveAdjustment",
            topologyOperation: true,
            captureMode: .topologyDelta(changedLayerIDs: [])
        ) else { return }
        var addedLayerID: LayerID?
        bootstrap.workspaceStore.updateDocument { document in
            addedLayerID = document.addCurveAdjustmentLayer().id
        }
        refresh()
        if let addedLayerID {
            bootstrap.layerSurfaceStore.markKnownTransparent(for: addedLayerID)
        }
        noteCanvasContentChanged(changedLayerIDs: [])
        showStatus(.init(kind: .success, message: "已新增非破坏式曲线调整层"))
    }

    var activeCurveAdjustmentLayerParameters: CurveAdjustmentParameters? {
        guard let layer = workspace.document.layer(workspace.document.activeLayerID),
              case .curves(let parameters)? = layer.adjustment else {
            return nil
        }
        return parameters
    }

    func setActiveCurveAdjustmentLayerChannel(_ channel: CurveChannel) {
        let layerID = workspace.document.activeLayerID
        bootstrap.workspaceStore.updateDocument { document in
            guard let index = document.layers.firstIndex(where: { $0.id == layerID }),
                  case .curves(var parameters)? = document.layers[index].adjustment else { return }
            parameters.selectedChannel = channel
            document.layers[index].adjustment = .curves(parameters)
        }
        hasUnsavedChanges = true
        refreshLightweight()
    }

    func updateActiveCurveAdjustmentLayer(
        _ state: CurveChannelState,
        channel: CurveChannel
    ) {
        let layerID = workspace.document.activeLayerID
        guard workspace.document.layer(layerID)?.isAdjustmentLayer == true else { return }
        beginAdjustmentLayerHistoryGestureIfNeeded(layerID: layerID)
        bootstrap.workspaceStore.updateDocument { document in
            guard let index = document.layers.firstIndex(where: { $0.id == layerID }),
                  case .curves(var parameters)? = document.layers[index].adjustment else { return }
            parameters.setState(state, for: channel)
            document.layers[index].adjustment = .curves(parameters)
        }
        refresh(invalidatedLayerIDs: [layerID])
        noteCanvasContentChanged(changedLayerIDs: [])
    }

    func resetActiveCurveAdjustmentLayer() {
        let layerID = workspace.document.activeLayerID
        guard let parameters = activeCurveAdjustmentLayerParameters,
              !parameters.isNeutral else { return }
        adjustmentLayerCheckpointResetTask?.cancel()
        adjustmentLayerCheckpointLayerID = nil
        guard checkpointHistoryIfPossible(
            operationKind: "layer.curveAdjustment.reset",
            candidateChangedLayerIDs: [layerID],
            captureMode: .inPlaceChangedLayers([layerID])
        ) else { return }
        bootstrap.workspaceStore.updateDocument { document in
            guard let index = document.layers.firstIndex(where: { $0.id == layerID }) else { return }
            document.layers[index].adjustment = .curves(.neutral)
        }
        refresh(invalidatedLayerIDs: [layerID])
        noteCanvasContentChanged(changedLayerIDs: [])
    }

    private func beginAdjustmentLayerHistoryGestureIfNeeded(layerID: LayerID) {
        if adjustmentLayerCheckpointLayerID != layerID {
            _ = checkpointHistoryIfPossible(
                operationKind: "layer.curveAdjustment.edit",
                candidateChangedLayerIDs: [layerID],
                captureMode: .inPlaceChangedLayers([layerID])
            )
            adjustmentLayerCheckpointLayerID = layerID
        }
        adjustmentLayerCheckpointResetTask?.cancel()
        adjustmentLayerCheckpointResetTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            self?.adjustmentLayerCheckpointLayerID = nil
            self?.adjustmentLayerCheckpointResetTask = nil
        }
    }

    func addLayer(toGroup groupID: LayerID) {
        guard workspace.document.layer(groupID)?.isGroup == true else { return }
        guard ensureDocumentResourceBudget(
            additionalPaintLayers: 1,
            action: "新增图层"
        ) else { return }
        guard checkpointHistoryIfPossible(
            operationKind: "layer.addToGroup",
            topologyOperation: true,
            captureMode: .topologyDelta(changedLayerIDs: [])
        ) else { return }
        var addedLayerID: LayerID?
        bootstrap.workspaceStore.updateDocument { document in
            let layer = document.addLayer()
            addedLayerID = layer.id
            _ = document.setParent(Set([layer.id]), groupID: groupID)
        }
        refresh()
        if let addedLayerID {
            bootstrap.layerSurfaceStore.markKnownTransparent(for: addedLayerID)
            noteCanvasContentChanged(changedLayerIDs: [addedLayerID])
        }
        showStatus(.init(kind: .success, message: "已在图层组中新建图层"))
    }

    func addLayerGroup(containing layerIDs: Set<LayerID> = []) {
        guard checkpointHistoryIfPossible(
            operationKind: "layerGroup.add",
            topologyOperation: true,
            captureMode: .topologyDelta(changedLayerIDs: [])
        ) else { return }
        bootstrap.workspaceStore.updateDocument { document in
            _ = document.addGroup(named: "图层组", containing: layerIDs)
        }
        refresh()
        noteCanvasContentChanged(changedLayerIDs: [])
        showStatus(.init(kind: .success, message: "已新增图层组"))
    }

    func ungroupLayerGroup(_ groupID: LayerID) {
        guard workspace.document.layer(groupID)?.isGroup == true else { return }
        guard checkpointHistoryIfPossible(
            operationKind: "layerGroup.ungroup",
            topologyOperation: true,
            captureMode: .topologyDelta(changedLayerIDs: [])
        ) else { return }
        var changed = false
        bootstrap.workspaceStore.updateDocument { document in
            changed = document.removeGroupKeepingChildren(groupID)
        }
        refresh()
        if changed {
            noteCanvasContentChanged(changedLayerIDs: [])
            showStatus(.init(kind: .success, message: "已解散图层组"))
        }
    }

    func removeActiveLayer() {
        guard !isApplyingTransformCommit else {
            showStatus(.init(kind: .info, message: "正在应用变形，请稍候再删除图层"))
            return
        }

        if isTransformingSelection {
            cancelSelectionTransform(clearSelectionAfterCancel: true)
        }

        let removedLayerID = workspace.document.activeLayerID
        guard checkpointHistoryIfPossible(
            operationKind: "layer.delete",
            candidateChangedLayerIDs: [removedLayerID],
            topologyOperation: true,
            captureMode: .topologyDelta(changedLayerIDs: [removedLayerID])
        ) else { return }
        let initialCount = workspace.document.layers.count
        bootstrap.workspaceStore.updateDocument { document in
            document.removeActiveLayer()
        }
        refresh()

        if workspace.document.layers.count < initialCount {
            noteCanvasContentChanged()
            showStatus(.init(kind: .success, message: "已删除当前图层"))
        } else {
            showStatus(.init(kind: .info, message: "至少需要保留一个图层"))
        }
    }

    func duplicateActiveLayer() {
        let activeLayerAddsSurface = workspace.document.layer(
            workspace.document.activeLayerID
        )?.isPaintLayer == true
        guard ensureDocumentResourceBudget(
            additionalPaintLayers: activeLayerAddsSurface ? 1 : 0,
            additionalMasks: workspace.document.layer(
                workspace.document.activeLayerID
            )?.mask == nil ? 0 : 1,
            action: "复制图层"
        ) else { return }
        guard checkpointHistoryIfPossible(
            operationKind: "layer.duplicate",
            topologyOperation: true,
            captureMode: .topologyDelta(changedLayerIDs: [])
        ) else { return }

        let sourceLayerID = workspace.document.activeLayerID
        var duplicatedLayerID: LayerID?
        bootstrap.workspaceStore.updateDocument { document in
            duplicatedLayerID = document.duplicateActiveLayer()?.id
        }
        refresh()

        if let duplicatedLayerID {
            bootstrap.layerSurfaceStore.copyTexture(
                from: sourceLayerID,
                to: duplicatedLayerID,
                metal: bootstrap.metalContext
            )
            bootstrap.layerSurfaceStore.copyMaskTexture(
                from: sourceLayerID,
                to: duplicatedLayerID,
                metal: bootstrap.metalContext
            )
            refresh()
            noteCanvasContentChanged()
            showStatus(.init(kind: .success, message: "已复制图层"))
        } else {
            showStatus(.init(kind: .error, message: "无法复制图层"))
        }
    }

    func mergeActiveLayerDown() {
        guard !isTransformingSelection else {
            showStatus(.init(kind: .info, message: "请先应用或取消变形"))
            return
        }

        guard let context = workspace.document.activeMergeDownContext else {
            showStatus(.init(kind: .info, message: "没有可向下合并的图层"))
            return
        }

        guard !context.source.isLocked, !context.destination.isLocked else {
            showStatus(.init(kind: .info, message: "锁定图层无法合并"))
            return
        }
        guard !context.destination.isAdjustmentLayer else {
            showStatus(.init(kind: .info, message: "绘画图层不能直接向下合并到调整层；请先合并调整层"))
            return
        }

        guard
            let sourceSurfaceID = bootstrap.layerSurfaceStore.surfaceID(for: context.source.id),
            let destinationSurfaceID = bootstrap.layerSurfaceStore.surfaceID(for: context.destination.id),
            let sourceTexture = bootstrap.layerSurfaceStore.texture(for: sourceSurfaceID),
            let destinationTexture = bootstrap.layerSurfaceStore.texture(for: destinationSurfaceID)
        else {
            showStatus(.init(kind: .error, message: "无法访问合并纹理"))
            return
        }

        guard checkpointHistoryIfPossible(
            operationKind: "layer.mergeDown",
            candidateChangedLayerIDs: [context.source.id, context.destination.id],
            topologyOperation: true,
            captureMode: .topologyDelta(
                changedLayerIDs: [context.source.id, context.destination.id]
            )
        ) else { return }

        do {
            try bootstrap.layerMergeController.merge(
                sourceTexture: sourceTexture,
                sourceOpacity: workspace.document.effectiveLayerOpacity(context.source.id),
                sourceVisible: context.source.isVisible,
                sourceBlendMode: context.source.blendMode,
                sourceClipsDestination: context.source.clipTargetLayerID == context.destination.id,
                sourceMaskTexture: context.source.mask?.isEnabled == true
                    ? bootstrap.layerSurfaceStore.maskTexture(for: context.source.id)
                    : nil,
                sourceCurveAdjustmentLUTs: context.source.adjustment?.curveLUTs,
                into: destinationTexture,
                destinationOpacity: workspace.document.effectiveLayerOpacity(context.destination.id),
                destinationVisible: context.destination.isVisible,
                destinationBlendMode: context.destination.blendMode,
                destinationMaskTexture: context.destination.mask?.isEnabled == true
                    ? bootstrap.layerSurfaceStore.maskTexture(for: context.destination.id)
                    : nil
            )

            bootstrap.workspaceStore.updateDocument { document in
                _ = document.completeMergeDown(
                    using: context,
                    mergedVisibility: context.source.isVisible || context.destination.isVisible,
                    mergedOpacity: 1
                )
                if let destinationIndex = document.layers.firstIndex(where: { $0.id == context.destination.id }) {
                    document.layers[destinationIndex].mask = nil
                    document.layers[destinationIndex].adjustment = nil
                }
            }
            bootstrap.layerSurfaceStore.removeMaskTexture(for: context.destination.id)

            refresh()
            noteCanvasContentChanged()
            showStatus(.init(kind: .success, message: "已向下合并图层"))
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func mergeVisibleLayers() {
        guard !isTransformingSelection else {
            showStatus(.init(kind: .info, message: "请先应用或取消变形"))
            return
        }

        guard let context = workspace.document.mergeVisibleContext else {
            showStatus(.init(kind: .info, message: "至少需要两个可见图层"))
            return
        }

        guard context.visibleLayers.allSatisfy({ !$0.isLocked }) else {
            showStatus(.init(kind: .info, message: "锁定图层无法合并"))
            return
        }

        var textureByLayerID: [LayerID: MTLTexture] = [:]
        var enabledMaskTextureByLayerID: [LayerID: MTLTexture] = [:]
        for layer in context.visibleLayers {
            guard let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: layer.id),
                  let texture = bootstrap.layerSurfaceStore.texture(for: surfaceID) else { continue }
            textureByLayerID[layer.id] = texture
            if layer.mask?.isEnabled == true,
               let maskTexture = bootstrap.layerSurfaceStore.maskTexture(for: layer.id) {
                enabledMaskTextureByLayerID[layer.id] = maskTexture
            }
        }
        let textureEntries: [CanvasLayerCompositeInput] = context.visibleLayers.compactMap { layer -> CanvasLayerCompositeInput? in
            guard
                let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: layer.id),
                let texture = bootstrap.layerSurfaceStore.texture(for: surfaceID)
            else {
                return nil
            }

            return CanvasLayerCompositeInput(
                texture: texture,
                opacity: workspace.document.effectiveLayerOpacity(layer.id),
                blendMode: layer.blendMode,
                clipMaskTexture: layer.clipTargetLayerID.flatMap { textureByLayerID[$0] },
                clipLayerMaskTexture: layer.clipTargetLayerID.flatMap { enabledMaskTextureByLayerID[$0] },
                layerMaskTexture: enabledMaskTextureByLayerID[layer.id],
                curveAdjustmentLUTs: layer.adjustment?.curveLUTs
            )
        }

        guard
            textureEntries.count == context.visibleLayers.count,
            let targetSurfaceID = bootstrap.layerSurfaceStore.surfaceID(for: context.target.id),
            let targetTexture = bootstrap.layerSurfaceStore.texture(for: targetSurfaceID)
        else {
            showStatus(.init(kind: .error, message: "无法访问合并纹理"))
            return
        }

        let mergedLayerIDs = context.visibleLayers.map(\.id)
        guard checkpointHistoryIfPossible(
            operationKind: "layer.mergeVisible",
            candidateChangedLayerIDs: mergedLayerIDs,
            topologyOperation: true,
            captureMode: .topologyDelta(changedLayerIDs: mergedLayerIDs)
        ) else { return }

        do {
            try bootstrap.layerMergeController.mergeVisible(
                layers: textureEntries,
                into: targetTexture
            )

            bootstrap.workspaceStore.updateDocument { document in
                _ = document.completeMergeVisible(
                    using: context,
                    mergedVisibility: true,
                    mergedOpacity: 1
                )
                if let targetIndex = document.layers.firstIndex(where: { $0.id == context.target.id }) {
                    document.layers[targetIndex].mask = nil
                    document.layers[targetIndex].adjustment = nil
                }
            }
            bootstrap.layerSurfaceStore.removeMaskTexture(for: context.target.id)

            refresh()
            noteCanvasContentChanged()
            showStatus(.init(kind: .success, message: "已合并可见图层"))
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func stampVisibleLayers() {
        guard !isTransformingSelection else {
            showStatus(.init(kind: .info, message: "请先应用或取消变形"))
            return
        }

        _ = flushBrushEditingBoundary(reason: "stampVisibleLayers")
        guard workspace.document.layers.contains(where: { $0.isVisible && $0.opacity > 0 }) else {
            showStatus(.init(kind: .info, message: "当前没有可盖印的可见图层"))
            return
        }
        guard ensureDocumentResourceBudget(
            additionalPaintLayers: 1,
            action: "盖印可见图层"
        ) else { return }

        do {
            let stampedTexture = try makeVisibleCompositeTexture()
            guard checkpointHistoryIfPossible(
                operationKind: "layer.stampVisible",
                topologyOperation: true,
                additionalOperationKinds: ["layer.composite"],
                captureMode: .topologyDelta(changedLayerIDs: [])
            ) else { return }

            var createdLayerID: LayerID?
            bootstrap.workspaceStore.updateDocument { document in
                createdLayerID = document.addLayer(named: "盖印图层").id
            }

            let state = bootstrap.workspaceStore.state
            bootstrap.layerSurfaceStore.prepareTextures(
                for: state.document,
                metal: bootstrap.metalContext
            )
            guard
                let createdLayerID,
                let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: createdLayerID)
            else {
                throw CocoaError(.fileWriteUnknown)
            }

            bootstrap.layerSurfaceStore.swapTexture(for: surfaceID, with: stampedTexture)
            refresh(invalidatedLayerIDs: [createdLayerID])
            noteCanvasContentChanged(changedLayerIDs: [createdLayerID])
            recordDrawingActivityIfNeeded()
            showStatus(.init(kind: .success, message: "已盖印所有可见图层"))
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func selectLayer(_ layerID: LayerID) {
        if straightLineState.phase == .pending,
           !commitPendingStraightLine() {
            return
        }
        _ = flushBrushEditingBoundary(reason: "selectLayer")
        adjustmentLayerCheckpointResetTask?.cancel()
        adjustmentLayerCheckpointResetTask = nil
        adjustmentLayerCheckpointLayerID = nil
        if workspace.document.activeLayerID != layerID {
            activeMaskEditingLayerID = nil
            lastLayerMaskStrokeSample = nil
            guard resolveColorAdjustmentSessionIfNeeded(reason: .layerChange) else { return }
            guard resolveCurveAdjustmentSessionIfNeeded(reason: .layerChange) else { return }
            resolveTransformSession(reason: .layerChange)
            if workspace.toolSession.activeTool == .textureFill {
                resetTextureFillGesture(reason: "layerChange")
            }
        }
        bootstrap.workspaceStore.updateDocument { document in
            document.setActiveLayer(layerID)
        }
        refreshLightweight()
    }

    func addMaskToActiveLayer(revealsAll: Bool = true) {
        let layerID = workspace.document.activeLayerID
        guard workspace.document.layer(layerID)?.isPaintLayer == true else {
            showStatus(.init(kind: .info, message: "只有绘画图层可以添加蒙版"))
            return
        }
        guard workspace.document.layer(layerID)?.mask == nil else {
            beginEditingActiveLayerMask()
            return
        }
        guard ensureDocumentResourceBudget(
            additionalMasks: 1,
            action: "添加图层蒙版"
        ) else { return }
        guard checkpointHistoryIfPossible(
            operationKind: "layerMask.add",
            candidateChangedLayerIDs: [layerID],
            topologyOperation: true,
            captureMode: .topologyDelta(changedLayerIDs: [layerID])
        ) else { return }
        bootstrap.workspaceStore.updateDocument { document in
            guard let index = document.layers.firstIndex(where: { $0.id == layerID }) else { return }
            document.layers[index].mask = LayerMaskDescriptor(isEnabled: true)
        }
        bootstrap.layerSurfaceStore.prepareTextures(for: bootstrap.workspaceStore.state.document, metal: bootstrap.metalContext)
        bootstrap.layerSurfaceStore.fillMaskTexture(
            for: layerID,
            value: revealsAll ? 1 : 0,
            metal: bootstrap.metalContext
        )
        activeMaskEditingLayerID = layerID
        selectTool(.brush)
        noteCanvasContentChanged(changedLayerIDs: [layerID])
        refresh(invalidatedLayerIDs: [layerID])
        showStatus(.init(kind: .success, message: revealsAll ? "已添加显示全部蒙版" : "已添加隐藏全部蒙版"))
    }

    func beginEditingActiveLayerMask() {
        let layerID = workspace.document.activeLayerID
        guard workspace.document.layer(layerID)?.mask != nil else {
            showStatus(.init(kind: .info, message: "当前图层没有蒙版"))
            return
        }
        activeMaskEditingLayerID = layerID
        selectTool(.brush)
        showStatus(.init(kind: .info, message: "正在编辑图层蒙版：白色显示，黑色隐藏，灰色部分显示；橡皮擦隐藏"))
    }

    func stopEditingLayerMask() {
        activeMaskEditingLayerID = nil
        lastLayerMaskStrokeSample = nil
        showStatus(.init(kind: .info, message: "已返回图层内容编辑"))
    }

    func toggleActiveLayerMaskEnabled() {
        let layerID = workspace.document.activeLayerID
        guard let mask = workspace.document.layer(layerID)?.mask else { return }
        guard checkpointHistoryIfPossible(
            operationKind: "layerMask.toggle",
            candidateChangedLayerIDs: [],
            captureMode: .metadataOnly
        ) else { return }
        bootstrap.workspaceStore.updateDocument { document in
            guard let index = document.layers.firstIndex(where: { $0.id == layerID }) else { return }
            document.layers[index].mask?.isEnabled = !mask.isEnabled
        }
        noteCanvasContentChanged(changedLayerIDs: [])
        refreshLightweight()
    }

    func invertActiveLayerMask() {
        let layerID = workspace.document.activeLayerID
        guard workspace.document.layer(layerID)?.mask != nil,
              let texture = bootstrap.layerSurfaceStore.maskTexture(for: layerID) else { return }
        guard checkpointHistoryIfPossible(
            operationKind: "layerMask.invert",
            candidateChangedLayerIDs: [layerID],
            captureMode: .inPlaceChangedLayers([layerID])
        ) else { return }
        do {
            let snapshot = try bootstrap.textureSerializer.snapshot(texture: texture)
            let inverted = Data(snapshot.pixelData.map { 255 &- $0 })
            try bootstrap.textureSerializer.restore(
                snapshot: LayerTextureSnapshot(
                    width: snapshot.width,
                    height: snapshot.height,
                    bytesPerRow: snapshot.bytesPerRow,
                    pixelData: inverted
                ),
                into: texture
            )
            noteCanvasContentChanged(changedLayerIDs: [layerID])
            refresh(invalidatedLayerIDs: [layerID])
            showStatus(.init(kind: .success, message: "已反相图层蒙版"))
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func deleteActiveLayerMask() {
        let layerID = workspace.document.activeLayerID
        guard workspace.document.layer(layerID)?.mask != nil else { return }
        guard checkpointHistoryIfPossible(
            operationKind: "layerMask.delete",
            candidateChangedLayerIDs: [layerID],
            topologyOperation: true,
            captureMode: .topologyDelta(changedLayerIDs: [layerID])
        ) else { return }
        bootstrap.workspaceStore.updateDocument { document in
            guard let index = document.layers.firstIndex(where: { $0.id == layerID }) else { return }
            document.layers[index].mask = nil
        }
        bootstrap.layerSurfaceStore.removeMaskTexture(for: layerID)
        activeMaskEditingLayerID = nil
        lastLayerMaskStrokeSample = nil
        noteCanvasContentChanged(changedLayerIDs: [layerID])
        refresh(invalidatedLayerIDs: [layerID])
        showStatus(.init(kind: .success, message: "已删除图层蒙版"))
    }

    func setLayerBlendMode(_ layerID: LayerID, blendMode: LayerBlendMode) {
        guard workspace.document.layer(layerID)?.blendMode != blendMode else { return }
        checkpointHistoryIfPossible(captureMode: .metadataOnly)
        bootstrap.workspaceStore.updateDocument { document in
            document.setLayerBlendMode(layerID, blendMode: blendMode)
        }
        refreshLightweight()
        noteCanvasContentChanged(changedLayerIDs: [])
    }

    func toggleLayerClipping(_ layerID: LayerID) {
        checkpointHistoryIfPossible(captureMode: .metadataOnly)
        var changed = false
        bootstrap.workspaceStore.updateDocument { document in
            changed = document.toggleLayerClipping(layerID)
        }
        refreshLightweight()
        guard changed else {
            showStatus(.init(kind: .info, message: "当前图层下方没有可用的剪贴目标"))
            return
        }
        noteCanvasContentChanged(changedLayerIDs: [])
        let enabled = workspace.document.layer(layerID)?.clipTargetLayerID != nil
        showStatus(.init(kind: .info, message: enabled ? "已创建剪贴图层" : "已解除剪贴图层"))
    }

    func toggleLayerReference(_ layerID: LayerID) {
        checkpointHistoryIfPossible(captureMode: .metadataOnly)
        bootstrap.workspaceStore.updateDocument { document in
            document.toggleLayerReference(layerID)
        }
        refreshLightweight()
        let enabled = workspace.document.layer(layerID)?.isReference == true
        showStatus(.init(kind: .info, message: enabled ? "已设为填充参考图层" : "已取消填充参考图层"))
    }

    func moveLayers(_ layerIDs: Set<LayerID>, toGroup groupID: LayerID?) {
        checkpointHistoryIfPossible(captureMode: .metadataOnly)
        var changed = false
        bootstrap.workspaceStore.updateDocument { document in
            changed = document.setParent(layerIDs, groupID: groupID)
        }
        refreshLightweight()
        if changed {
            noteCanvasContentChanged(changedLayerIDs: [])
            showStatus(.init(kind: .success, message: groupID == nil ? "已移出图层组" : "已移入图层组"))
        }
    }

    func setLayerVisibility(_ layerID: LayerID, isVisible: Bool) {
        checkpointHistoryIfPossible(captureMode: .metadataOnly)
        bootstrap.workspaceStore.updateDocument { document in
            document.setLayerVisibility(layerID, isVisible: isVisible)
        }
        refreshLightweight()
        noteCanvasContentChanged(changedLayerIDs: [])
    }

    func toggleLayerLock(_ layerID: LayerID) {
        checkpointHistoryIfPossible(captureMode: .metadataOnly)
        bootstrap.workspaceStore.updateDocument { document in
            document.toggleLayerLock(layerID)
        }
        let updatedDocument = bootstrap.workspaceStore.state.document
        if workspace.toolSession.activeTool == .textureFill,
           updatedDocument.activeLayerID == layerID,
           updatedDocument.layers.first(where: { $0.id == layerID })?.isLocked == true {
            resetTextureFillGesture(reason: "layerLock")
        }
        refreshLightweight()
    }

    func toggleLayerTransparentPixelLock(_ layerID: LayerID) {
        checkpointHistoryIfPossible(captureMode: .metadataOnly)
        bootstrap.workspaceStore.updateDocument { document in
            document.toggleLayerTransparentPixelLock(layerID)
        }
        let updatedDocument = bootstrap.workspaceStore.state.document
        refreshLightweight()
        let isEnabled = updatedDocument.layers.first(where: { $0.id == layerID })?.locksTransparentPixels == true
        showStatus(.init(kind: .info, message: isEnabled ? "已锁定透明像素" : "已解除锁定透明像素"))
    }

    private func layerTransparentPixelLockEnabled(_ layerID: LayerID) -> Bool {
        workspace.document.layers.first(where: { $0.id == layerID })?.locksTransparentPixels == true
    }

    private func makeAlphaLockTextureCopyIfNeeded(
        for layerID: LayerID,
        sourceTexture: MTLTexture,
        force: Bool = false
    ) -> MTLTexture? {
        guard force || layerTransparentPixelLockEnabled(layerID) else {
            return nil
        }

        guard let alphaLockTexture = bootstrap.layerSurfaceStore.makeTexture(
            width: sourceTexture.width,
            height: sourceTexture.height,
            pixelFormat: sourceTexture.pixelFormat,
            usage: [.shaderRead],
            storageMode: .private,
            metal: bootstrap.metalContext
        ) else {
            return nil
        }

        bootstrap.layerSurfaceStore.copyTexture(
            from: sourceTexture,
            to: alphaLockTexture,
            metal: bootstrap.metalContext
        )
        return alphaLockTexture
    }

    func setActiveLayerOpacity(_ opacity: Float) {
        _ = flushBrushEditingBoundary(reason: "setActiveLayerOpacity")
        let activeLayerID = workspace.document.activeLayerID
        guard
            let currentOpacity = workspace.document.layers.first(where: { $0.id == activeLayerID })?.opacity,
            abs(currentOpacity - opacity) > 0.0001
        else {
            return
        }
        if isAdjustingLayerOpacity, !activeLayerOpacityChangeDidMutate {
            checkpointHistoryIfPossible(captureMode: .metadataOnly)
        } else if !isAdjustingLayerOpacity {
            checkpointHistoryIfPossible(captureMode: .metadataOnly)
        }
        bootstrap.workspaceStore.updateDocument { document in
            document.setLayerOpacity(activeLayerID, opacity: opacity)
        }
        refreshLightweight()
        if isAdjustingLayerOpacity {
            activeLayerOpacityChangeDidMutate = true
        } else {
            noteCanvasContentChanged(changedLayerIDs: [])
        }
    }

    func beginActiveLayerOpacityChange() {
        guard !isAdjustingLayerOpacity else { return }
        isAdjustingLayerOpacity = true
        activeLayerOpacityChangeDidMutate = false
    }

    func endActiveLayerOpacityChange() {
        guard isAdjustingLayerOpacity else { return }
        let didMutate = activeLayerOpacityChangeDidMutate
        isAdjustingLayerOpacity = false
        activeLayerOpacityChangeDidMutate = false
        if didMutate {
            noteCanvasContentChanged(changedLayerIDs: [])
        }
    }

    func moveActiveLayerUp() {
        checkpointHistoryIfPossible(captureMode: .metadataOnly)
        var moved = false
        bootstrap.workspaceStore.updateDocument { document in
            moved = document.moveActiveLayerUp()
        }
        refreshLightweight()
        showStatus(
            .init(
                kind: .info,
                message: moved ? "已上移图层" : "图层已经在最上方"
            )
        )
        if moved {
            noteCanvasContentChanged(changedLayerIDs: [])
        }
    }

    func moveActiveLayerDown() {
        checkpointHistoryIfPossible(captureMode: .metadataOnly)
        var moved = false
        bootstrap.workspaceStore.updateDocument { document in
            moved = document.moveActiveLayerDown()
        }
        refreshLightweight()
        showStatus(
            .init(
                kind: .info,
                message: moved ? "已下移图层" : "图层已经在最下方"
            )
        )
        if moved {
            noteCanvasContentChanged(changedLayerIDs: [])
        }
    }

    func moveLayer(_ layerID: LayerID, toDisplayIndex displayIndex: Int) {
        checkpointHistoryIfPossible(captureMode: .metadataOnly)
        var moved = false
        bootstrap.workspaceStore.updateDocument { document in
            let targetDocumentIndex = max(0, min(document.layers.count - 1, (document.layers.count - 1) - displayIndex))
            moved = document.moveLayer(layerID, toIndex: targetDocumentIndex)
        }
        refreshLightweight()
        if moved {
            noteCanvasContentChanged(changedLayerIDs: [])
            showStatus(.init(kind: .success, message: "已调整图层顺序"))
        }
    }

    func moveLayer(_ layerID: LayerID, toDisplayInsertionIndex insertionIndex: Int) {
        checkpointHistoryIfPossible(captureMode: .metadataOnly)
        var moved = false
        bootstrap.workspaceStore.updateDocument { document in
            moved = document.moveLayer(layerID, toDisplayInsertionIndex: insertionIndex)
        }
        refreshLightweight()
        if moved {
            noteCanvasContentChanged(changedLayerIDs: [])
            showStatus(.init(kind: .success, message: "已调整图层顺序"))
        }
    }

    func renameLayer(_ layerID: LayerID, to name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return
        }

        checkpointHistoryIfPossible(captureMode: .metadataOnly)
        var renamed = false
        bootstrap.workspaceStore.updateDocument { document in
            renamed = document.renameLayer(layerID, to: trimmedName)
        }
        refreshLightweight()
        if renamed {
            showStatus(.init(kind: .success, message: "已重命名图层"))
        }
    }

    func layerThumbnail(for layerID: LayerID, maxDimension: Int = 40) -> CGImage? {
        if let cached = layerThumbnailCache[layerID] {
            return cached
        }

        guard
            let layer = workspace.document.layers.first(where: { $0.id == layerID }),
            let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: layer.id),
            let contentTexture = bootstrap.layerSurfaceStore.texture(for: surfaceID),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else {
            return nil
        }

        do {
            let texture = layer.mask?.isEnabled == true
                ? try makeCompositeTexture(layers: [layer], document: workspace.document, waitUntilCompleted: true)
                : contentTexture
            let snapshot = try bootstrap.textureSerializer.snapshot(texture: texture)
            let image = Self.snapshotImage(
                from: snapshot,
                maxDimension: maxDimension,
                colorSpace: colorSpace
            )
            if let image {
                layerThumbnailCache[layerID] = image
            }
            return image
        } catch {
            return nil
        }
    }

    func loadLayerThumbnail(for layerID: LayerID, maxDimension: Int = 40) async -> CGImage? {
        if let cached = layerThumbnailCache[layerID] {
            return cached
        }

        guard
            let layer = workspace.document.layers.first(where: { $0.id == layerID }),
            let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: layerID),
            let contentTexture = bootstrap.layerSurfaceStore.texture(for: surfaceID)
        else {
            return nil
        }

        let usesMaskedComposite = layer.mask?.isEnabled == true
        let texture: MTLTexture
        if usesMaskedComposite {
            guard let composite = try? makeCompositeTexture(
                layers: [layer],
                document: workspace.document,
                waitUntilCompleted: false
            ) else { return nil }
            texture = composite
        } else {
            texture = contentTexture
        }

        let capturedRevision = layerThumbnailRevision
        let canvasSize = workspace.document.canvasSize
        let serializerBox = WorkspaceUncheckedBox(bootstrap.textureSerializer)
        let detectorBox = WorkspaceUncheckedBox(bootstrap.layerContentBoundsDetector)
        let commandQueueBox = WorkspaceUncheckedBox(bootstrap.metalContext.commandQueue)
        let textureBox = WorkspaceUncheckedBox(texture)
        let image = await Task.detached(priority: .utility) {
            guard let result = try? detectorBox.value.detect(
                texture: textureBox.value,
                commandQueue: commandQueueBox.value
            ) else {
                return nil as CGImage?
            }
            guard case .bounds(let bounds) = result else {
                return WorkspaceViewModel.positionedSnapshotImage(
                    from: LayerTextureSnapshot(
                        width: 1,
                        height: 1,
                        bytesPerRow: 4,
                        pixelData: Data(repeating: 0, count: 4)
                    ),
                    originX: 0,
                    originY: 0,
                    canvasSize: canvasSize,
                    maxDimension: maxDimension
                )
            }
            let originX = max(0, Int(bounds.minX.rounded(.down)))
            let originY = max(0, Int(bounds.minY.rounded(.down)))
            let width = min(
                textureBox.value.width - originX,
                max(1, Int(bounds.maxX.rounded(.up)) - originX)
            )
            let height = min(
                textureBox.value.height - originY,
                max(1, Int(bounds.maxY.rounded(.up)) - originY)
            )
            guard let snapshot = try? serializerBox.value.snapshot(
                texture: textureBox.value,
                originX: originX,
                originY: originY,
                width: width,
                height: height
            ) else { return nil }
            return WorkspaceViewModel.positionedSnapshotImage(
                from: snapshot,
                originX: originX,
                originY: originY,
                canvasSize: canvasSize,
                maxDimension: maxDimension
            )
        }.value

        guard !Task.isCancelled, capturedRevision == layerThumbnailRevision else {
            return nil
        }
        if !usesMaskedComposite {
            guard
                bootstrap.layerSurfaceStore.surfaceID(for: layerID) == surfaceID,
                let currentTexture = bootstrap.layerSurfaceStore.texture(for: surfaceID),
                ObjectIdentifier(currentTexture as AnyObject) == ObjectIdentifier(textureBox.value as AnyObject)
            else {
                return nil
            }
        }

        if let image {
            layerThumbnailCache[layerID] = image
        }
        return image
    }

    func savedSnapshot(with id: UUID) -> CanvasSavedSnapshot? {
        savedSnapshots.first { $0.id == id }
    }

    func savedSnapshotDisplayIndex(for id: UUID) -> Int? {
        guard let index = savedSnapshots.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        return index + 1
    }

    func beginSelection(kind: SelectionShapeKind, at start: CanvasPoint, modifiers: NSEvent.ModifierFlags = []) {
        ideationBranchActivityHandler?()
        let combineMode = selectionCombineMode(for: kind, modifiers: modifiers)
        if RuntimeDiagnostics.selectionTraceLoggingEnabled, kind == .lasso {
            let message = "[beginSelection] kind=lasso start=(\(start.x),\(start.y)) combine=\(combineMode.rawValue)"
            selectionTraceLogger.debug("\(message, privacy: .public)")
            emitSelectionTraceViewModel(message)
        }
        if kind == .lasso {
            activeLassoRawPoints = [start]
            activeLassoPreviewPoints = [start]
            activeLassoBounds = CanvasRect(origin: start, size: .init(x: 0, y: 0))
            lassoSamplingDebugPoints = [start]
            lastLassoOverlayRefreshUptime = 0
            samePathCommittedDebugShape = nil
            samePathPreviewDebugShape = nil
        } else {
            activeLassoRawPoints = []
            activeLassoPreviewPoints = []
            activeLassoBounds = nil
            lassoSamplingDebugPoints = []
            lastLassoOverlayRefreshUptime = 0
            samePathCommittedDebugShape = nil
            samePathPreviewDebugShape = nil
        }
        bootstrap.workspaceStore.updateSelection { selection in
            selection.anchorPoint = start
            selection.activeKind = kind
            selection.activeCombineMode = combineMode
            selection.inProgressShape = selectionPreviewShape(
                kind: kind,
                start: start,
                currentPoint: start,
                existingPoints: nil,
                modifiers: modifiers,
                combineMode: combineMode
            )
        }
        refreshSelectionOverlayOnly()
        relayIdeationOperation(.beginSelection(kind: kind, start: start, modifiers: .init(flags: modifiers)))
    }

    private var fillToolOpacity: Float {
        min(max(workspace.toolSession.brush.opacity, 0), 1)
    }

    private func resolvedFillToolColor(from color: RGBAColor) -> RGBAColor {
        let resolvedColor = resolvedGeneratorColor(from: color)
        return resolvedColor.withAlpha(resolvedColor.alpha * fillToolOpacity)
    }

    var gradientPreviewColor: RGBAColor {
        resolvedFillToolColor(from: workspace.toolSession.selectedColor)
    }

    var displayedGradientSettings: GradientSettings {
        guard gradientFollowsSelectedColor,
              let first = gradientSettings.stops.first,
              let last = gradientSettings.stops.last else {
            return gradientSettings
        }
        let color = workspace.toolSession.selectedColor
        return GradientSettings(stops: [
            GradientStop(id: first.id, position: 0, color: color),
            GradientStop(id: last.id, position: 1, color: color.withAlpha(0))
        ])
    }

    var gradientRenderSettings: GradientSettings {
        let opacity = fillToolOpacity
        return GradientSettings(stops: displayedGradientSettings.stops.map { stop in
            GradientStop(
                id: stop.id,
                position: stop.position,
                color: stop.color.withAlpha(stop.color.alpha * opacity)
            )
        })
    }

    func resetGradientSettingsToCurrentColor() {
        gradientFollowsSelectedColor = true
        gradientSettings = .currentColorToTransparent(workspace.toolSession.selectedColor)
        colorAdjustmentRedrawRevision &+= 1
    }

    func addGradientStop() {
        materializeGradientSettingsForEditing()
        let positions = gradientSettings.stops.map(\.position)
        let candidatePositions = zip(positions, positions.dropFirst()).map { lower, upper in
            (gap: upper - lower, position: (lower + upper) / 2)
        }
        let position = candidatePositions.max(by: { $0.gap < $1.gap })?.position ?? 0.5
        let color = gradientSettings.color(at: position)
        if gradientSettings.insertStop(at: position, color: color) {
            colorAdjustmentRedrawRevision &+= 1
        }
    }

    func updateGradientStop(id: UUID, position: Float? = nil, color: RGBAColor? = nil) {
        materializeGradientSettingsForEditing()
        if gradientSettings.updateStop(id: id, position: position, color: color) {
            colorAdjustmentRedrawRevision &+= 1
        }
    }

    func removeGradientStop(id: UUID) {
        materializeGradientSettingsForEditing()
        if gradientSettings.removeStop(id: id) {
            colorAdjustmentRedrawRevision &+= 1
        }
    }

    private func materializeGradientSettingsForEditing() {
        guard gradientFollowsSelectedColor else { return }
        gradientSettings = displayedGradientSettings
        gradientFollowsSelectedColor = false
    }

    var textureFillPreviewBrush: BrushSettings {
        workspace.toolSession.textureFillBrushOverride ?? workspace.toolSession.drawingBrush
    }

    var textureFillPreviewColor: RGBAColor {
        let drawingBrush = textureFillPreviewBrush
        return resolvedGeneratorColor(from: workspace.toolSession.selectedColor)
            .withAlpha(workspace.toolSession.selectedColor.alpha * min(max(drawingBrush.opacity, 0), 1))
    }

    func updateLinearGradientHover(to point: CanvasPoint) {
        guard workspace.toolSession.activeTool == .linearGradient else { return }
        mutateLinearGradientState { state in
            state.hoverPoint = point
        }
    }

    private func mutateLinearGradientState(
        _ mutate: (inout LinearGradientInteractionState) -> Void
    ) {
        var state = linearGradientState
        mutate(&state)
        linearGradientState = state
    }

    private func mutateSectorGradientState(
        _ mutate: (inout SectorGradientInteractionState) -> Void
    ) {
        var state = sectorGradientState
        mutate(&state)
        sectorGradientState = state
    }

    private func activeGradientTool() -> ToolKind? {
        switch workspace.toolSession.activeTool {
        case .linearGradient, .sectorGradient:
            return workspace.toolSession.activeTool
        default:
            return nil
        }
    }

    private func gradientSessionStateDescription() -> String {
        switch workspace.toolSession.activeTool {
        case .linearGradient:
            return String(describing: linearGradientState.phase)
        case .sectorGradient:
            return String(describing: sectorGradientState.phase)
        default:
            return "idle"
        }
    }

    private func shouldAutoApplyGradientBeforeSelectingTool(_ tool: ToolKind) -> Bool {
        guard tool != workspace.toolSession.activeTool else { return false }
        switch workspace.toolSession.activeTool {
        case .linearGradient:
            return shouldAutoApplyGradientForToolSwitch(phase: linearGradientState.phase)
        case .sectorGradient:
            return shouldAutoApplyGradientForToolSwitch(phase: sectorGradientState.phase)
        default:
            return false
        }
    }

    private func handleDeferredGradientActionIfNeeded() {
        guard let deferredGradientAction else { return }
        self.deferredGradientAction = nil
        switch deferredGradientAction {
        case .toolSwitch(let tool):
            performToolSelection(tool)
        case .gradientDrag(let drag):
            performDeferredGradientDrag(drag)
        }
    }

    private func commitGradientApplication(
        _ commandBuffer: MTLCommandBuffer,
        layerID: LayerID,
        resetInteractionState: () -> Void,
        successMessage: String,
        failureMessage: String,
        logTool: String? = nil,
        startedAt: UInt64? = nil
    ) {
        isApplyingGradientCommit = true
        resetInteractionState()
        commandBuffer.addCompletedHandler { [weak self] completedBuffer in
            Task { @MainActor in
                guard let self else { return }

                self.bootstrap.strokeEngine.resetBrushPipelineState()
                self.isApplyingGradientCommit = false
                defer { self.handleDeferredGradientActionIfNeeded() }

                guard completedBuffer.status == .completed else {
                    let message = completedBuffer.error?.localizedDescription ?? failureMessage
                    self.showStatus(.init(kind: .error, message: message))
                    return
                }

                self.layerThumbnailCache.removeValue(forKey: layerID)
                self.noteCanvasContentChanged(changedLayerIDs: [layerID])
                self.refresh(invalidatedLayerIDs: [layerID])
                self.recordDrawingActivityIfNeeded()

                if let logTool, let startedAt {
                    let gpuMs = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
                    self.transformLogger.debug("[gradient] applyGpuMs=\(gpuMs, privacy: .public) sessionTool=\(logTool, privacy: .public)")
                }

                self.showStatus(.init(kind: .success, message: successMessage))
            }
        }
        commandBuffer.commit()
    }

    private func performDeferredGradientDrag(_ drag: DeferredGradientDrag) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.activeTool = drag.tool
        }
        switch drag.tool {
        case .linearGradient, .sectorGradient:
            break
        default:
            return
        }
        guard let firstPoint = drag.points.first else { return }
        beginGradientDrag(at: firstPoint, modifiers: drag.modifiers)
        if drag.points.count >= 2 {
            let updatePoints = drag.didEnd ? Array(drag.points.dropFirst().dropLast()) : Array(drag.points.dropFirst())
            for point in updatePoints {
                updateGradientDrag(to: point, modifiers: drag.modifiers)
            }
            if drag.didEnd, let endPoint = drag.points.last {
                endGradientDrag(at: endPoint, modifiers: drag.modifiers)
            }
        }
    }

    private func queueDeferredGradientDragPoint(
        tool: ToolKind,
        point: CanvasPoint,
        modifiers: NSEvent.ModifierFlags,
        didEnd: Bool
    ) {
        guard tool == .linearGradient || tool == .sectorGradient else { return }
        if case .gradientDrag(var drag)? = deferredGradientAction, drag.tool == tool {
            if drag.points.last != point {
                drag.points.append(point)
            }
            drag.modifiers = modifiers
            drag.didEnd = drag.didEnd || didEnd
            deferredGradientAction = .gradientDrag(drag)
            return
        }
        deferredGradientAction = .gradientDrag(
            DeferredGradientDrag(
                tool: tool,
                points: [point],
                modifiers: modifiers,
                didEnd: didEnd
            )
        )
    }

    private func shouldAutoApplyGradientBeforeNewDrag(hitExistingEditorTarget: Bool) -> Bool {
        guard !hitExistingEditorTarget else { return false }
        switch workspace.toolSession.activeTool {
        case .linearGradient:
            return shouldAutoApplyGradientForToolSwitch(phase: linearGradientState.phase)
        case .sectorGradient:
            return shouldAutoApplyGradientForToolSwitch(phase: sectorGradientState.phase)
        default:
            return false
        }
    }

    func enterGradientEditingViaShift() {
        guard !isApplyingGradientCommit else { return }
        if workspace.toolSession.activeTool == .linearGradient,
           linearGradientState.phase == .pendingPreview {
            linearGradientState.phase = .editing
        }
        relayIdeationOperation(.enterGradientEditing)
    }

    func updateCanvasToolHover(to point: CanvasPoint) {
        lastCanvasHoverPoint = point
        if quickColorPickerState == nil,
           isQuickColorPickerShortcutActive {
            presentQuickColorPickerIfPossible()
        }
        switch workspace.toolSession.activeTool {
        case .straightLine:
            updateStraightLineHover(to: point)
        case .linearGradient:
            updateLinearGradientHover(to: point)
        case .sectorGradient:
            updateSectorGradientHover(to: point)
        case .polygonSelection:
            updatePolygonSelectionHover(to: point)
        default:
            break
        }
    }

    func beginGradientDrag(
        at point: CanvasPoint,
        modifiers: NSEvent.ModifierFlags = [],
        handleHitRadius: Double? = nil
    ) {
        ideationBranchActivityHandler?()
        if isApplyingGradientCommit {
            if let tool = activeGradientTool() {
                queueDeferredGradientDragPoint(tool: tool, point: point, modifiers: modifiers, didEnd: false)
            }
            return
        }
        switch workspace.toolSession.activeTool {
        case .linearGradient:
            beginLinearGradientDrag(
                at: point,
                modifiers: modifiers,
                handleHitRadius: handleHitRadius
            )
        case .sectorGradient:
            beginSectorGradientDrag(at: point, modifiers: modifiers)
        default:
            break
        }
        relayIdeationOperation(.beginGradientDrag(point: point, modifiers: .init(flags: modifiers)))
    }

    func updateGradientDrag(to point: CanvasPoint, modifiers: NSEvent.ModifierFlags = []) {
        ideationBranchActivityHandler?()
        if isApplyingGradientCommit {
            if let tool = activeGradientTool() {
                queueDeferredGradientDragPoint(tool: tool, point: point, modifiers: modifiers, didEnd: false)
            }
            return
        }
        switch workspace.toolSession.activeTool {
        case .linearGradient:
            updateLinearGradientDrag(to: point)
        case .sectorGradient:
            updateSectorGradientDrag(to: point)
        default:
            break
        }
        relayIdeationOperation(.updateGradientDrag(point: point, modifiers: .init(flags: modifiers)))
    }

    func endGradientDrag(at point: CanvasPoint, modifiers: NSEvent.ModifierFlags = []) {
        ideationBranchActivityHandler?()
        if isApplyingGradientCommit {
            if let tool = activeGradientTool() {
                queueDeferredGradientDragPoint(tool: tool, point: point, modifiers: modifiers, didEnd: true)
            }
            return
        }
        switch workspace.toolSession.activeTool {
        case .linearGradient:
            endLinearGradientDrag(at: point)
        case .sectorGradient:
            endSectorGradientDrag(at: point)
        default:
            break
        }
        relayIdeationOperation(.endGradientDrag(point: point, modifiers: .init(flags: modifiers)))
    }

    func applyActiveGradientSession() {
        guard !isApplyingGradientCommit else { return }
        relayIdeationOperation(.applyGradientSession)
        switch workspace.toolSession.activeTool {
        case .linearGradient:
            guard let geometry = linearGradientState.geometry else {
                showStatus(.init(kind: .info, message: "当前没有可应用的直线渐变"))
                return
            }
            applyLinearGradient(geometry: geometry)
        case .sectorGradient:
            guard let geometry = sectorGradientState.geometry else {
                showStatus(.init(kind: .info, message: "当前没有可应用的扇形渐变"))
                return
            }
            applySectorGradient(geometry: geometry)
        default:
            break
        }
    }

    func cancelLinearGradientInteraction() {
        guard workspace.toolSession.activeTool == .linearGradient else { return }
        guard linearGradientState.phase != .idle else { return }
        deferredGradientAction = nil
        linearGradientState = .init()
        relayIdeationOperation(.cancelGradientSession)
        showStatus(.init(kind: .info, message: "已取消直线渐变"))
    }

    func cancelCanvasToolInteraction() {
        if patternPlacementPhase != .idle {
            cancelPatternPlacement(keepSelection: true)
            return
        }
        switch workspace.toolSession.activeTool {
        case .canvasCrop:
            cancelCanvasCrop()
        case .textureFill:
            resetTextureFillGesture(reason: "cancel")
        case .straightLine:
            cancelStraightLineInteraction()
        case .linearGradient:
            cancelLinearGradientInteraction()
        case .sectorGradient:
            cancelSectorGradientInteraction()
        case .polygonSelection:
            cancelPolygonSelectionInteraction()
        case .perspective:
            stopPerspectiveGuideMatch()
            selectedPerspectiveAnchorID = nil
            endPerspectiveGuideInteraction()
        case .blockReference:
            cancelBlockReferenceInteraction()
        default:
            break
        }
    }

    private func beginLinearGradientDrag(
        at point: CanvasPoint,
        modifiers: NSEvent.ModifierFlags,
        handleHitRadius: Double?
    ) {
        let resolvedHitRadius = max(handleHitRadius ?? 14, 1)
        if linearGradientState.isEditingSession,
           let geometry = linearGradientState.geometry {
            if let handle = linearGradientHandleHitTest(
                geometry,
                point: point,
                hitRadius: resolvedHitRadius
            ) {
                linearGradientState.phase = .draggingHandle(handle)
                linearGradientState.dragStartPoint = point
                linearGradientState.dragReferenceGeometry = geometry
                return
            }
            if linearGradientPreviewContains(
                geometry,
                point: point,
                hitRadius: resolvedHitRadius
            ) {
                linearGradientState.phase = .movingWholeGradient
                linearGradientState.dragStartPoint = point
                linearGradientState.dragReferenceGeometry = geometry
                return
            }
        }

        if shouldAutoApplyGradientBeforeNewDrag(hitExistingEditorTarget: false) {
            deferredGradientAction = .gradientDrag(
                DeferredGradientDrag(
                    tool: .linearGradient,
                    points: [point],
                    modifiers: modifiers,
                    didEnd: false
                )
            )
            applyActiveGradientSession()
            return
        }

        linearGradientState = LinearGradientInteractionState(
            phase: .drawingLeg1,
            pointA: point,
            pointB: point,
            pointC: nil,
            dragStartPoint: point,
            dragReferenceGeometry: nil,
            leg1CandidatePoint: point,
            hoverPoint: point,
            transitionMidpoint: 0.5
        )
    }

    private func updateLinearGradientDrag(to point: CanvasPoint) {
        mutateLinearGradientState { state in
            state.hoverPoint = point

            switch state.phase {
        case .idle:
            break
        case .drawingLeg1:
            state.pointB = point
            state.pointC = nil
        case .drawingLeg2:
            state.pointB = point
            state.pointC = nil
        case .draggingHandle(let handle):
            guard let reference = state.dragReferenceGeometry else { return }
            switch handle {
            case .pointA:
                state.pointA = point
                state.pointB = reference.pointB
                state.pointC = defaultLinearGradientPointC(
                    pointA: point,
                    pointB: reference.pointB,
                    canvasSize: workspace.document.canvasSize
                )
            case .pointB:
                state.pointA = reference.pointA
                state.pointB = point
                state.pointC = defaultLinearGradientPointC(
                    pointA: reference.pointA,
                    pointB: point,
                    canvasSize: workspace.document.canvasSize
                )
            case .midpoint:
                state.pointA = reference.pointA
                state.pointB = reference.pointB
                state.pointC = reference.pointC
                state.transitionMidpoint = linearGradientTransitionMidpoint(
                    for: point,
                    geometry: reference
                )
            }
        case .movingWholeGradient:
            guard
                let reference = state.dragReferenceGeometry,
                let dragStartPoint = state.dragStartPoint
            else { return }
            let delta = CanvasPoint(x: point.x - dragStartPoint.x, y: point.y - dragStartPoint.y)
            state.pointA = CanvasPoint(x: reference.pointA.x + delta.x, y: reference.pointA.y + delta.y)
            state.pointB = CanvasPoint(x: reference.pointB.x + delta.x, y: reference.pointB.y + delta.y)
            state.pointC = CanvasPoint(x: reference.pointC.x + delta.x, y: reference.pointC.y + delta.y)
        case .editing, .pendingPreview:
            break
        }
        }
    }

    private func endLinearGradientDrag(at point: CanvasPoint) {
        defer {
            linearGradientState.dragStartPoint = nil
            linearGradientState.dragReferenceGeometry = nil
            linearGradientState.hoverPoint = point
        }

        switch linearGradientState.phase {
        case .idle:
            return
        case .drawingLeg1, .drawingLeg2:
            guard let pointA = linearGradientState.pointA else {
                linearGradientState = .init()
                return
            }
            let pointB = linearGradientState.pointB ?? point
            guard distanceBetween(pointA, pointB) > 0.5 else {
                linearGradientState = .init()
                showStatus(.init(kind: .info, message: "渐变长度太短"))
                return
            }
            linearGradientState.pointB = pointB
            linearGradientState.pointC = defaultLinearGradientPointC(
                pointA: pointA,
                pointB: pointB,
                canvasSize: workspace.document.canvasSize
            )
            linearGradientState.phase = .editing
            linearGradientState.leg1CandidatePoint = nil
            showStatus(.init(
                kind: .info,
                message: "拖动起点、终点或中点调整渐变；Enter 应用，Esc 取消"
            ))
        case .draggingHandle, .movingWholeGradient:
            linearGradientState.phase = .editing
        case .editing, .pendingPreview:
            break
        }
    }

    func updateStraightLineHover(to point: CanvasPoint) {
        guard workspace.toolSession.activeTool == .straightLine else { return }
        guard straightLineState.phase == .drawingLine else { return }
        _ = updateStraightLineState(along: [point])
    }

    func beginStraightLineDrag(
        at point: CanvasPoint,
        paintVariationSeed seedOverride: UInt32? = nil,
        initialBrushSize brushSizeOverride: Float? = nil,
        thicknessAdjustmentDeadZone deadZoneOverride: Double? = nil
    ) {
        guard workspace.toolSession.activeTool == .straightLine else { return }
        ideationBranchActivityHandler?()

        if straightLineState.phase == .pending,
           !commitPendingStraightLine() {
            return
        }

        let paintVariationSeed = seedOverride ?? makePaintVariationSeed()
        let brushSize = min(max(brushSizeOverride ?? workspace.toolSession.brush.size, 1), 1_000)
        let thicknessAdjustmentDeadZone = max(
            deadZoneOverride ?? straightLineDefaultThicknessDeadZoneScreenDistance,
            1
        )
        if brushSizeOverride != nil {
            setBrushSize(brushSize)
        }
        straightLineState.begin(
            at: point,
            brushSize: brushSize,
            paintVariationSeed: paintVariationSeed,
            thicknessAdjustmentDeadZone: thicknessAdjustmentDeadZone
        )
        relayIdeationOperation(.beginStraightLineDrag(
            point: point,
            brushSize: brushSize,
            paintVariationSeed: paintVariationSeed,
            thicknessAdjustmentDeadZone: thicknessAdjustmentDeadZone
        ))
        showStatus(.init(kind: .info, message: "拖动确定直线；末端垂直拖过约 50 px 可调整粗细"))
    }

    func updateStraightLineDrag(along points: [CanvasPoint]) {
        guard workspace.toolSession.activeTool == .straightLine, !points.isEmpty else { return }
        ideationBranchActivityHandler?()
        if let adjustedBrushSize = updateStraightLineState(along: points) {
            setBrushSize(adjustedBrushSize)
        }
        relayIdeationOperation(.updateStraightLineDrag(points))
    }

    func endStraightLineDrag(at point: CanvasPoint) {
        guard workspace.toolSession.activeTool == .straightLine else { return }
        ideationBranchActivityHandler?()
        if let adjustedBrushSize = updateStraightLineState(along: [point]) {
            setBrushSize(adjustedBrushSize)
        }

        var state = straightLineState
        let didFinish = state.finishDrag(at: point)
        straightLineState = state
        relayIdeationOperation(.endStraightLineDrag(point))

        if didFinish {
            showStatus(.init(
                kind: .info,
                message: "直线待应用：离开画布自动确认，Enter 立即确认，Esc 取消"
            ))
        } else {
            showStatus(.init(kind: .info, message: "直线长度太短"))
        }
    }

    @discardableResult
    func commitPendingStraightLine() -> Bool {
        guard straightLineState.phase == .pending,
              let pointA = straightLineState.pointA,
              let pointB = straightLineState.pointB else {
            return false
        }

        let pendingState = straightLineState
        straightLineState = .init()
        let didApply = applyStraightLine(
            pointA: pointA,
            pointB: pointB,
            paintVariationSeed: pendingState.paintVariationSeed
        )
        if didApply {
            relayIdeationOperation(.commitStraightLine)
        } else {
            straightLineState = pendingState
        }
        return didApply
    }

    func cancelStraightLineInteraction() {
        guard workspace.toolSession.activeTool == .straightLine else { return }
        guard straightLineState.phase != .idle else { return }
        straightLineState = .init()
        relayIdeationOperation(.cancelStraightLine)
        showStatus(.init(kind: .info, message: "已取消直线"))
    }

    func handleCanvasPointerExit() {
        guard workspace.toolSession.activeTool == .straightLine,
              straightLineState.phase == .pending else {
            return
        }
        _ = commitPendingStraightLine()
    }

    func handleStraightLineClick(at point: CanvasPoint, paintVariationSeed: UInt32? = nil) {
        guard workspace.toolSession.activeTool == .straightLine else { return }

        switch straightLineState.phase {
        case .idle, .pending:
            beginStraightLineDrag(at: point, paintVariationSeed: paintVariationSeed)
        case .drawingLine, .adjustingThickness:
            updateStraightLineDrag(along: [point])
            endStraightLineDrag(at: point)
            _ = commitPendingStraightLine()
        }
    }

    @discardableResult
    private func updateStraightLineState(along points: [CanvasPoint]) -> Float? {
        guard !points.isEmpty else { return nil }
        var state = straightLineState
        var adjustedBrushSize: Float?
        for point in points {
            if let size = state.updateDrag(to: point) {
                adjustedBrushSize = size
            }
        }
        straightLineState = state
        return adjustedBrushSize
    }

    func updateSectorGradientHover(to point: CanvasPoint) {
        guard workspace.toolSession.activeTool == .sectorGradient else { return }
        mutateSectorGradientState { state in
            state.hoverPoint = point
        }
    }

    func cancelSectorGradientInteraction() {
        guard workspace.toolSession.activeTool == .sectorGradient else { return }
        guard sectorGradientState.phase != .idle else { return }
        deferredGradientAction = nil
        sectorGradientState = .init()
        relayIdeationOperation(.cancelGradientSession)
        showStatus(.init(kind: .info, message: "已取消扇形渐变"))
    }

    func handleCanvasToolClick(
        at point: CanvasPoint,
        modifiers: NSEvent.ModifierFlags = [],
        clickCount: Int = 1,
        paintVariationSeed seedOverride: UInt32? = nil
    ) {
        ideationBranchActivityHandler?()
        let paintVariationSeed = seedOverride ?? makePaintVariationSeed()
        switch workspace.toolSession.activeTool {
        case .straightLine:
            handleStraightLineClick(at: point, paintVariationSeed: paintVariationSeed)
            return
        case .polygonSelection:
            handlePolygonSelectionClick(at: point, modifiers: modifiers, clickCount: clickCount)
        case .smartSelection:
            requestMagicWandSelection(at: point, modifiers: modifiers)
        default:
            break
        }
        relayIdeationOperation(.handleCanvasToolClick(
            point: point,
            modifiers: .init(flags: modifiers),
            clickCount: clickCount,
            paintVariationSeed: paintVariationSeed
        ))
    }

    private func beginSectorGradientDrag(at point: CanvasPoint, modifiers: NSEvent.ModifierFlags) {
        sectorGradientState = SectorGradientInteractionState(
            phase: .drawing,
            center: point,
            pathPoints: [point],
            hoverPoint: point
        )
    }

    private func updateSectorGradientDrag(to point: CanvasPoint) {
        mutateSectorGradientState { state in
            state.hoverPoint = point
            switch state.phase {
            case .idle:
                break
            case .drawing:
                appendSectorGradientPoint(point, to: &state.pathPoints)
            }
        }
    }

    private func endSectorGradientDrag(at point: CanvasPoint) {
        guard sectorGradientState.phase == .drawing else { return }
        guard let center = sectorGradientState.center else {
            sectorGradientState = .init()
            return
        }

        var rawPoints = sectorGradientState.pathPoints
        appendSectorGradientPoint(point, to: &rawPoints)
        let finalizedPoints = smoothedSectorGradientPoints(rawPoints: rawPoints, closingTo: center)
        sectorGradientState.hoverPoint = point

        guard let geometry = resolvedSectorGradientGeometry(center: center, pathPoints: finalizedPoints) else {
            sectorGradientState = .init()
            return
        }

        sectorGradientState = .init()
        applySectorGradient(geometry: geometry)
    }

    private func appendSectorGradientPoint(_ point: CanvasPoint, to points: inout [CanvasPoint]) {
        guard let last = points.last else {
            points = [point]
            return
        }

        // Append raw drag points at a moderate spacing; smoothing handles curve fitting.
        // Avoids dense 0.75px interpolation that creates thousands of points and causes lag.
        let distance = distanceBetween(last, point)
        if distance < 3.0 {
            return
        }
        let interpolated: [CanvasPoint] = []
        if interpolated.isEmpty {
            if last != point {
                points.append(point)
            }
            return
        }

        for interpolatedPoint in interpolated where points.last != interpolatedPoint {
            points.append(interpolatedPoint)
        }
    }

    func updatePolygonSelectionHover(to point: CanvasPoint) {
        guard workspace.toolSession.activeTool == .polygonSelection else { return }
        guard polygonSelectionState.phase == .building else { return }
        polygonSelectionState.hoverPoint = point
    }

    func cancelPolygonSelectionInteraction() {
        guard workspace.toolSession.activeTool == .polygonSelection else { return }
        guard polygonSelectionState.phase != .idle else { return }
        polygonSelectionState = .init()
        showStatus(.init(kind: .info, message: "已取消多边形选区"))
    }

    func handlePolygonSelectionClick(
        at point: CanvasPoint,
        modifiers: NSEvent.ModifierFlags,
        clickCount: Int
    ) {
        guard workspace.toolSession.activeTool == .polygonSelection else { return }

        switch polygonSelectionState.phase {
        case .idle:
            let combineMode = selectionCombineMode(for: .lasso, modifiers: modifiers)
            if combineMode == .replace {
                bootstrap.workspaceStore.updateSelection { selection in
                    selection.committedShape = nil
                    selection.inProgressShape = nil
                    selection.anchorPoint = nil
                    selection.activeKind = nil
                    selection.activeCombineMode = .replace
                }
                refreshLightweight()
            }
            polygonSelectionState.phase = .building
            polygonSelectionState.vertices = [point]
            polygonSelectionState.hoverPoint = point
            polygonSelectionState.combineMode = combineMode
            showStatus(.init(kind: .info, message: "已设置起点，继续点击添加拐点；点回起点或双击可闭合"))
        case .building:
            let normalizedPoint = point
            let vertices = polygonSelectionState.vertices
            guard let first = vertices.first else {
                polygonSelectionState = .init()
                return
            }

            let closesToFirst = vertices.count >= 3 && distanceBetween(first, normalizedPoint) <= 12
            if closesToFirst {
                commitPolygonSelection(points: vertices + [first], combineMode: polygonSelectionState.combineMode)
                return
            }

            if clickCount >= 2, vertices.count >= 2 {
                var finalPoints = vertices
                if distanceBetween(vertices.last ?? normalizedPoint, normalizedPoint) > 0.05 {
                    finalPoints.append(normalizedPoint)
                }
                commitPolygonSelection(points: finalPoints, combineMode: polygonSelectionState.combineMode)
                return
            }

            guard distanceBetween(vertices.last ?? normalizedPoint, normalizedPoint) > 0.05 else {
                return
            }
            polygonSelectionState.vertices.append(normalizedPoint)
            polygonSelectionState.hoverPoint = normalizedPoint
            let actionName: String = switch polygonSelectionState.combineMode {
            case .replace: "新建"
            case .add: "增选"
            case .subtract: "减选"
            case .intersect: "相交"
            }
            showStatus(.init(kind: .info, message: "已添加顶点，继续点击或双击闭合（当前：\(actionName)）"))
        }
    }

    private func commitPolygonSelection(points: [CanvasPoint], combineMode: SelectionCombineMode) {
        let canvasSize = workspace.document.canvasSize
        var clampedPoints = points.map {
            CanvasPoint(
                x: min(max($0.x, 0), Double(canvasSize.width)),
                y: min(max($0.y, 0), Double(canvasSize.height))
            )
        }
        if let first = clampedPoints.first, let last = clampedPoints.last, distanceBetween(first, last) > 0.05 {
            clampedPoints.append(first)
        }
        guard clampedPoints.count >= 3 else {
            polygonSelectionState = .init()
            showStatus(.init(kind: .info, message: "多边形至少需要 3 个点"))
            return
        }

        let preferredShape = SelectionShape(
            kind: .lasso,
            bounds: CanvasRect.bounding(points: clampedPoints),
            pathPoints: clampedPoints
        )
        let input = SelectionInputShape(
            polygonShapes: [[clampedPoints.map { CGPoint(x: $0.x, y: $0.y) }]],
            preferredDisplayShape: preferredShape
        )
        let previousCommittedShape = workspace.selection.committedShape?.clamped(to: canvasSize)
        let nextCommittedShape = committedSelectionShape(
            input: input,
            canvasSize: canvasSize,
            mode: combineMode,
            baseShape: previousCommittedShape
        )

        if combineMode == .replace, nextCommittedShape != previousCommittedShape {
            checkpointSelectionChangeIfPossible(previousCommittedShape: previousCommittedShape)
        }

        bootstrap.workspaceStore.updateSelection { selection in
            selection.committedShape = nextCommittedShape
            selection.inProgressShape = nil
            selection.anchorPoint = nil
            selection.activeKind = nil
            selection.activeCombineMode = .replace
        }
        polygonSelectionState = .init()
        refresh()

        if nextCommittedShape == nil {
            showStatus(.init(kind: .info, message: "选区为空"))
        } else {
            let actionName: String = switch combineMode {
            case .replace: "已创建多边形选区"
            case .add: "已增选多边形区域"
            case .subtract: "已减选多边形区域"
            case .intersect: "已保留多边形交集"
            }
            showStatus(.init(kind: .success, message: actionName))
        }
    }

    private func undoLastPolygonSelectionPoint() {
        guard workspace.toolSession.activeTool == .polygonSelection else { return }
        guard polygonSelectionState.phase == .building else { return }

        if !polygonSelectionState.vertices.isEmpty {
            polygonSelectionState.vertices.removeLast()
        }

        if polygonSelectionState.vertices.isEmpty {
            polygonSelectionState = .init()
            showStatus(.init(kind: .info, message: "已取消多边形选区"))
            return
        }

        polygonSelectionState.hoverPoint = polygonSelectionState.vertices.last
        showStatus(.init(kind: .info, message: "已撤回上一个顶点"))
    }

    func updateSelection(to point: CanvasPoint, modifiers: NSEvent.ModifierFlags = []) {
        ideationBranchActivityHandler?()
        let storeSelection = bootstrap.workspaceStore.state.selection
        let currentStart = storeSelection.anchorPoint ?? point
        let currentKind = storeSelection.activeKind ?? .rectangle
        if workspace.toolSession.activeTool == .textureFill {
            updateTextureFillGesture(to: point)
            relayIdeationOperation(.updateSelection(point: point, modifiers: .init(flags: modifiers)))
            return
        }
        var nextPreviewShape: SelectionShape?
        bootstrap.workspaceStore.updateSelection { selection in
            if currentKind == .lasso {
                if activeLassoRawPoints.isEmpty {
                    activeLassoRawPoints = [currentStart]
                    activeLassoPreviewPoints = [currentStart]
                    activeLassoBounds = CanvasRect(origin: currentStart, size: .init(x: 0, y: 0))
                }
                if activeLassoRawPoints.last != point {
                    activeLassoRawPoints.append(point)
                    activeLassoBounds = expandedBounds(activeLassoBounds, including: point)
                    appendActiveLassoPreviewPointIfNeeded(point)
                }
                // lassoSamplingDebugPoints 只在 debug overlay 开启时才需要每帧更新
                // 否则每帧把整个点数组赋给 @Published 属性会触发额外重绘
                // showsSelectionDebugOverlay は CanvasContainerView のデバッグフラグ
                // 通常は false なのでここでは更新しない（毎フレームの @Published 通知を避ける）
                if false {
                    lassoSamplingDebugPoints = activeLassoRawPoints
                }
                #if DEBUG
                if RuntimeDiagnostics.selectionTraceLoggingEnabled,
                   activeLassoRawPoints.count == 2 || activeLassoRawPoints.count % 24 == 0 {
                    let firstPoint = activeLassoRawPoints.first ?? point
                    let lastPoint = activeLassoRawPoints.last ?? point
                    let bounds = activeLassoBounds ?? CanvasRect.bounding(points: activeLassoRawPoints)
                    let message = "[updateSelection] rawPointCount=\(self.activeLassoRawPoints.count) firstRaw=(\(firstPoint.x),\(firstPoint.y)) lastRaw=(\(lastPoint.x),\(lastPoint.y)) current=(\(point.x),\(point.y)) boundsOrigin=(\(bounds.origin.x),\(bounds.origin.y)) boundsSize=(\(bounds.size.x),\(bounds.size.y))"
                    selectionTraceLogger.debug("\(message, privacy: .public)")
                    emitSelectionTraceViewModel(message)
                }
                #endif
            }
            let previewShape = selectionPreviewShape(
                kind: currentKind,
                start: currentStart,
                currentPoint: point,
                existingPoints: currentKind == .lasso
                    ? activeLassoPreviewPath(endingAt: point)
                    : selection.inProgressShape?.pathPoints,
                modifiers: modifiers,
                combineMode: selection.activeCombineMode,
                precomputedBounds: currentKind == .lasso ? activeLassoBounds : nil
            )
            selection.inProgressShape = previewShape
            nextPreviewShape = previewShape
        }
        if RuntimeDiagnostics.selectionTraceLoggingEnabled, currentKind == .lasso {
            samePathPreviewDebugShape = nextPreviewShape
        }
        if currentKind == .lasso {
            refreshLiveLassoOverlayIfNeeded()
        } else {
            refreshSelectionOverlayOnly()
        }
        relayIdeationOperation(.updateSelection(point: point, modifiers: .init(flags: modifiers)))
    }

    func updateSelection(to points: [CanvasPoint], modifiers: NSEvent.ModifierFlags = []) {
        guard points.isEmpty == false else { return }
        if workspace.toolSession.activeTool == .textureFill {
            updateTextureFillGesture(to: points)
            for point in points {
                relayIdeationOperation(.updateSelection(point: point, modifiers: .init(flags: modifiers)))
            }
            return
        }

        let storeSelection = bootstrap.workspaceStore.state.selection
        let currentKind = storeSelection.activeKind ?? .rectangle
        guard currentKind == .lasso else {
            updateSelection(to: points[points.count - 1], modifiers: modifiers)
            return
        }

        ideationBranchActivityHandler?()
        let currentStart = storeSelection.anchorPoint ?? points[0]
        if activeLassoRawPoints.isEmpty {
            activeLassoRawPoints = [currentStart]
            activeLassoPreviewPoints = [currentStart]
            activeLassoBounds = CanvasRect(origin: currentStart, size: .init(x: 0, y: 0))
        }
        for point in points where activeLassoRawPoints.last != point {
            activeLassoRawPoints.append(point)
            activeLassoBounds = expandedBounds(activeLassoBounds, including: point)
            appendActiveLassoPreviewPointIfNeeded(point)
        }
        guard let currentPoint = activeLassoRawPoints.last else { return }
        var nextPreviewShape: SelectionShape?
        bootstrap.workspaceStore.updateSelection { selection in
            let previewShape = selectionPreviewShape(
                kind: .lasso,
                start: currentStart,
                currentPoint: currentPoint,
                existingPoints: activeLassoPreviewPath(endingAt: currentPoint),
                modifiers: modifiers,
                combineMode: selection.activeCombineMode,
                precomputedBounds: activeLassoBounds
            )
            selection.inProgressShape = previewShape
            nextPreviewShape = previewShape
        }
        if RuntimeDiagnostics.selectionTraceLoggingEnabled {
            samePathPreviewDebugShape = nextPreviewShape
        }
        refreshLiveLassoOverlayIfNeeded()
        for point in points {
            relayIdeationOperation(.updateSelection(point: point, modifiers: .init(flags: modifiers)))
        }
    }

    func commitSelection(at end: CanvasPoint, modifiers: NSEvent.ModifierFlags = []) {
        ideationBranchActivityHandler?()
        let storeSelection = bootstrap.workspaceStore.state.selection
        let currentStart = storeSelection.anchorPoint ?? end
        let currentKind = storeSelection.activeKind ?? .rectangle
        let previousCommittedShape = storeSelection.committedShape
        let canvasSize = workspace.document.canvasSize
        if workspace.toolSession.activeTool == .textureFill {
            let didCommit = commitTextureFillGesture(at: end, modifiers: modifiers)
            if didCommit {
                relayIdeationOperation(.commitSelection(end: end, modifiers: .init(flags: modifiers)))
            }
            return
        }
        if currentKind == .lasso {
            let lastRaw = activeLassoRawPoints.last ?? end
            let firstRaw = activeLassoRawPoints.first ?? end
            let rawBounds = activeLassoBounds ?? CanvasRect.bounding(points: activeLassoRawPoints)
            let message = "[commitSelection:begin] kind=lasso end=(\(end.x),\(end.y)) rawPointCount=\(self.activeLassoRawPoints.count) firstRaw=(\(firstRaw.x),\(firstRaw.y)) lastRaw=(\(lastRaw.x),\(lastRaw.y)) rawBoundsOrigin=(\(rawBounds.origin.x),\(rawBounds.origin.y)) rawBoundsSize=(\(rawBounds.size.x),\(rawBounds.size.y))"
            selectionTraceLogger.debug("\(message, privacy: .public)")
            emitSelectionTraceViewModel(message)
        }
        if Self.runSamePathCommitTest,
           currentKind == .lasso,
           workspace.selection.activeCombineMode == .replace,
           let previewShape = workspace.selection.inProgressShape,
           previewShape.kind == .lasso,
           previewShape.pathPoints.count >= 3 {
            let committedShape = SelectionShape(
                kind: .lasso,
                bounds: previewShape.bounds,
                pathPoints: previewShape.pathPoints
            )
            let message = "[samePathCommitTest] committedDirectly pointCount=\(committedShape.pathPoints.count) boundsOrigin=(\(committedShape.bounds.origin.x),\(committedShape.bounds.origin.y)) boundsSize=(\(committedShape.bounds.size.x),\(committedShape.bounds.size.y))"
            selectionTraceLogger.debug("\(message, privacy: .public)")
            emitSelectionTraceViewModel(message)
            bootstrap.workspaceStore.updateSelection { selection in
                selection.committedShape = committedShape
                selection.inProgressShape = nil
                selection.anchorPoint = nil
                selection.activeKind = nil
                selection.activeCombineMode = .replace
            }
            samePathPreviewDebugShape = previewShape
            samePathCommittedDebugShape = committedShape
            activeLassoRawPoints = []
            activeLassoPreviewPoints = []
            activeLassoBounds = nil
            refresh()
            return
        }
        let combineMode: SelectionCombineMode
        if let savedMode = pendingCombineMode {
            combineMode = savedMode
            pendingCombineMode = nil
        } else {
            combineMode = storeSelection.activeCombineMode
        }
        let input = selectionInput(
            kind: currentKind,
            currentStart: currentStart,
            end: end,
            inProgressShape: storeSelection.inProgressShape,
            modifiers: modifiers,
            combineMode: combineMode
        )
        guard !input.polygonShapes.isEmpty else {
            activeLassoRawPoints = []
            activeLassoPreviewPoints = []
            activeLassoBounds = nil
            bootstrap.workspaceStore.updateSelection { selection in
                if combineMode == .replace {
                    selection.committedShape = nil
                }
                selection.inProgressShape = nil
                selection.anchorPoint = nil
                selection.activeKind = nil
                selection.activeCombineMode = .replace
            }
            refresh()
            showStatus(.init(kind: .info, message: "选区太小"))
            return
        }
        if workspace.toolSession.activeTool == .lassoFill,
           let preferredShape = input.preferredDisplayShape {
            let operation: SelectionPixelOperation = combineMode == .subtract
                ? .clear
                : .fill(premultipliedPixel(from: workspace.toolSession.selectedColor))
            let successMessage = combineMode == .subtract ? "已删除套索区域像素" : "已填充套索区域"

            // Clear selection BEFORE creating the history checkpoint so undo
            // restores to a state without a leftover selection outline.
            activeLassoRawPoints = []
            activeLassoPreviewPoints = []
            activeLassoBounds = nil
            lassoSamplingDebugPoints = []
            samePathPreviewDebugShape = nil
            samePathCommittedDebugShape = nil
            bootstrap.workspaceStore.updateSelection { selection in
                selection.committedShape = nil
                selection.inProgressShape = nil
                selection.anchorPoint = nil
                selection.activeKind = nil
                selection.activeCombineMode = .replace
            }

            let didApplyPixelOperation: Bool
            if combineMode == .subtract {
                didApplyPixelOperation = applyPixelOperation(
                    to: preferredShape,
                    operation: operation,
                    historyOperationKind: "lasso.erase",
                    successMessage: successMessage
                )
            } else {
                didApplyPixelOperation = applyLassoFill(
                    to: preferredShape,
                    historyOperationKind: "lasso.fill",
                    successMessage: successMessage
                )
            }
            refreshLightweight()
            if didApplyPixelOperation {
                relayIdeationOperation(.commitSelection(end: end, modifiers: .init(flags: modifiers)))
            }
            return
        }
        // 对于 lasso 且 replace 模式：直接提交平滑后的 lasso 形状。
        // 同时在后台预栅格化成 mask，避免后续自由变形/像素操作再临时现算。
        if currentKind == .lasso, combineMode == .replace, let preferredShape = input.preferredDisplayShape {
            let immediateShape = SelectionShape(
                kind: .lasso,
                bounds: preferredShape.bounds,
                pathPoints: preferredShape.pathPoints
            )

            if combineMode == .replace, immediateShape != previousCommittedShape {
                checkpointSelectionChangeIfPossible(previousCommittedShape: previousCommittedShape)
            }

            bootstrap.workspaceStore.updateSelection { selection in
                selection.committedShape = immediateShape
                selection.inProgressShape = nil
                selection.anchorPoint = nil
                selection.activeKind = nil
                selection.activeCombineMode = .replace
            }
            activeLassoRawPoints = []
            activeLassoPreviewPoints = []
            activeLassoBounds = nil
            lassoSamplingDebugPoints = []
            samePathPreviewDebugShape = nil
            samePathCommittedDebugShape = nil
            refreshLightweight()
            recordDrawingActivityIfNeeded()
            showStatus(.init(kind: .success, message: "已更新选区"))

            let polygonShapes = input.polygonShapes
            let capturedPreferredShape = preferredShape
            let capturedCanvasSize = canvasSize
            let capturedIsGeneratorArmed = isGeneratorRegionSelectionArmed
            selectionEpoch += 1
            let capturedEpoch = selectionEpoch
            cancelActiveRasterizationTask()
            activeRasterizationTask = Task { [weak self] in
                guard let self else { return }
                let rasterized = await Task.detached(priority: .userInitiated) {
                    self.selectionMaskShape(
                        from: polygonShapes,
                        canvasSize: capturedCanvasSize,
                        preferredDisplayShape: capturedPreferredShape
                    )
                }.value
                guard self.selectionEpoch == capturedEpoch else { return }
                self.bootstrap.workspaceStore.updateSelection { selection in
                    if selection.committedShape == immediateShape {
                        selection.committedShape = rasterized
                    }
                    selection.inProgressShape = nil
                    selection.anchorPoint = nil
                    selection.activeKind = nil
                    selection.activeCombineMode = .replace
                }
                self.refreshLightweight()
                if capturedIsGeneratorArmed {
                    self.isGeneratorRegionSelectionArmed = false
                    self.applyGeneratorToActiveLayer(clearSelectionAfterApply: true)
                }
            }
            relayIdeationOperation(.commitSelection(end: end, modifiers: .init(flags: modifiers)))
            return
        }

        // 同步路径：非 lasso 工具（rectangle/ellipse），直接同步处理
        // lasso 的 add/subtract 也做两步异步
        if currentKind == .lasso, let preferredShape = input.preferredDisplayShape {
            // 增减选时用保存的 base 选区（在 handleSelectionMouseDown 时保存）
            let baseShapeForCombine = (combineMode != .replace) ? pendingCombineBaseShape : nil
            pendingCombineBaseShape = nil
            let capturedCombineMode = combineMode

            let immediateShape: SelectionShape?
            if combineMode == .replace {
                immediateShape = SelectionShape(
                    kind: .lasso,
                    bounds: preferredShape.bounds,
                    pathPoints: preferredShape.pathPoints
                )
            } else {
                // add/subtract 时先保持旧选区显示，等异步完成再更新
                immediateShape = baseShapeForCombine
            }

            if combineMode == .replace, immediateShape != previousCommittedShape {
                checkpointSelectionChangeIfPossible(previousCommittedShape: previousCommittedShape)
            }

            bootstrap.workspaceStore.updateSelection { selection in
                selection.committedShape = immediateShape
                selection.inProgressShape = preferredShape
                selection.anchorPoint = nil
                selection.activeKind = nil
                selection.activeCombineMode = capturedCombineMode
            }
            activeLassoRawPoints = []
            activeLassoPreviewPoints = []
            activeLassoBounds = nil
            lassoSamplingDebugPoints = []
            samePathPreviewDebugShape = nil
            samePathCommittedDebugShape = nil
            refreshLightweight()
            recordDrawingActivityIfNeeded()
            showStatus(.init(kind: .success, message: "已更新选区"))

            let polygonShapes = input.polygonShapes
            let capturedPreferredShape = preferredShape
            let capturedCanvasSize = canvasSize
            let capturedBaseShape = baseShapeForCombine?.clamped(to: canvasSize)
            selectionEpoch += 1
            let capturedEpoch = selectionEpoch
            cancelActiveRasterizationTask()
            activeRasterizationTask = Task { [weak self] in
                guard let self else { return }
                let result = await Task.detached(priority: .userInitiated) {
                    self.committedSelectionShape(
                        input: SelectionInputShape(
                            polygonShapes: polygonShapes,
                            preferredDisplayShape: capturedPreferredShape
                        ),
                        canvasSize: capturedCanvasSize,
                        mode: capturedCombineMode,
                        baseShape: capturedBaseShape
                    )
                }.value
                guard self.selectionEpoch == capturedEpoch else { return }
                self.bootstrap.workspaceStore.updateSelection { selection in
                    if capturedCombineMode == .add {
                        selection.committedShape = result ?? capturedBaseShape
                    } else {
                        selection.committedShape = result
                    }
                    selection.inProgressShape = nil
                    selection.anchorPoint = nil
                    selection.activeKind = nil
                    selection.activeCombineMode = .replace
                }
                self.refresh()
            }
            relayIdeationOperation(.commitSelection(end: end, modifiers: .init(flags: modifiers)))
            return
        }

        // 非 lasso 工具（rectangle / ellipse）：两步异步处理，避免主线程卡顿
        // Step 1: 立即提交轻量几何形状（不含 mask），UI 可以立刻渲染选区边框
        let immediateShape = input.preferredDisplayShape.map { preferred in
            SelectionShape(
                kind: preferred.kind,
                bounds: preferred.bounds,
                pathPoints: preferred.pathPoints
            )
        }

        if combineMode == .replace, immediateShape != previousCommittedShape {
            checkpointSelectionChangeIfPossible(previousCommittedShape: previousCommittedShape)
        }

        let baseShapeForCombine = (combineMode != .replace) ? pendingCombineBaseShape : nil
        pendingCombineBaseShape = nil

        bootstrap.workspaceStore.updateSelection { selection in
            if combineMode == .replace {
                selection.committedShape = immediateShape
            } else {
                // add/subtract：先保持旧选区显示
                selection.committedShape = baseShapeForCombine
            }
            selection.inProgressShape = nil
            selection.anchorPoint = nil
            selection.activeKind = nil
            selection.activeCombineMode = combineMode
        }
        activeLassoRawPoints = []
        activeLassoPreviewPoints = []
        lassoSamplingDebugPoints = []
        samePathPreviewDebugShape = nil
        samePathCommittedDebugShape = nil

        refreshLightweight()
        relayIdeationOperation(.commitSelection(end: end, modifiers: .init(flags: modifiers)))

        let capturedIsGeneratorArmed = isGeneratorRegionSelectionArmed

        if immediateShape == nil {
            showStatus(.init(kind: .info, message: "选区为空"))
        } else {
            recordDrawingActivityIfNeeded()
            showStatus(.init(kind: .success, message: "已更新选区"))
        }

        // Step 2: 后台栅格化 mask
        let polygonShapes = input.polygonShapes
        let capturedPreferredShape = input.preferredDisplayShape
        let capturedCanvasSize = canvasSize
        let capturedBaseShape = baseShapeForCombine?.clamped(to: canvasSize)
        let capturedCombineMode = combineMode
        selectionEpoch += 1
        let capturedEpoch = selectionEpoch
        cancelActiveRasterizationTask()
        activeRasterizationTask = Task { [weak self] in
            guard let self else { return }
            let result = await Task.detached(priority: .userInitiated) {
                self.committedSelectionShape(
                    input: SelectionInputShape(
                        polygonShapes: polygonShapes,
                        preferredDisplayShape: capturedPreferredShape
                    ),
                    canvasSize: capturedCanvasSize,
                    mode: capturedCombineMode,
                    baseShape: capturedBaseShape
                )
            }.value
            guard self.selectionEpoch == capturedEpoch else { return }
            self.bootstrap.workspaceStore.updateSelection { selection in
                selection.committedShape = switch capturedCombineMode {
                case .replace, .subtract, .intersect:
                    result
                case .add:
                    result ?? capturedBaseShape
                }
                selection.inProgressShape = nil
                selection.anchorPoint = nil
                selection.activeKind = nil
                selection.activeCombineMode = .replace
            }
            self.refreshLightweight()

            if capturedIsGeneratorArmed, result != nil {
                self.isGeneratorRegionSelectionArmed = false
                self.applyGeneratorToActiveLayer(clearSelectionAfterApply: true)
            }
        }
    }

    private func beginTextureFillGesture(at point: CanvasPoint) -> Bool {
        guard let layerID = bootstrap.interactionController.activeEditableLayerID() else {
            showStatus(.init(kind: .info, message: "当前图层已锁定"))
            resetTextureFillGesture(reason: "beginLockedLayer")
            return false
        }

        _ = flushBrushEditingBoundary(reason: "beginTextureFillGesture")

        guard
            let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: layerID),
            let texture = bootstrap.layerSurfaceStore.texture(for: surfaceID)
        else {
            showStatus(.init(kind: .error, message: "无法访问当前图层"))
            resetTextureFillGesture(reason: "beginMissingSurface")
            return false
        }

        let tipSettings = workspace.toolSession.textureFillTip
        let drawingBrush = workspace.toolSession.textureFillBrushOverride
            ?? workspace.toolSession.drawingBrush
        let resolvedColor = resolvedGeneratorColor(from: workspace.toolSession.selectedColor)
            .withAlpha(workspace.toolSession.selectedColor.alpha * min(max(drawingBrush.opacity, 0), 1))
        textureFillSeedSequence &+= 1
        textureFillGestureState = TextureFillGestureState(
            layerID: layerID,
            surfaceID: surfaceID,
            anchorPoint: point,
            sessionSeed: TextureFillProceduralField.sessionSeed(
                anchorPoint: point,
                sequence: textureFillSeedSequence
            ),
            baseTexture: makeTextureFillReplayTextureCopy(from: texture),
            rawEdgePoints: [point],
            tipSettings: tipSettings,
            brush: drawingBrush,
            color: resolvedColor
        )
        bootstrap.workspaceStore.updateSelection { selection in
            selection.inProgressShape = nil
        }
        refreshSelectionOverlayOnly()
        return true
    }

    private func resetTextureFillGesture(reason: String) {
        _ = reason
        guard textureFillGestureState != nil else { return }
        textureFillGestureState = nil
        bootstrap.workspaceStore.updateSelection { selection in
            selection.inProgressShape = nil
        }
        refreshSelectionOverlayOnly()
    }

    private func updateTextureFillPreviewSelection(from state: TextureFillGestureState) {
        let canvasSize = workspace.document.canvasSize
        let previewShape = textureFillLiveSelectionShape(
            from: state.rawEdgePoints,
            canvasSize: canvasSize
        )
        bootstrap.workspaceStore.updateSelection { selection in
            selection.inProgressShape = previewShape
        }
        refreshSelectionOverlayOnly()
    }

    private func updateTextureFillGesture(to point: CanvasPoint) {
        guard var state = textureFillGestureState else { return }

        if let previousEdgePoint = state.lastEdgePoint {
            guard textureFillDistance(from: previousEdgePoint, to: point) >= Self.textureFillMinimumSliceDistance else {
                return
            }

            let didRender = renderTextureFillSlice(
                TextureFillSlice(
                    anchorPoint: state.anchorPoint,
                    previousEdgePoint: previousEdgePoint,
                    currentEdgePoint: point
                ),
                state: &state
            )
            state.lastEdgePoint = point
            state.rawEdgePoints.append(point)
            textureFillGestureState = state
            if didRender {
                updateTextureFillPreviewSelection(from: state)
            }
            return
        }

        guard textureFillDistance(from: state.anchorPoint, to: point) >= Self.textureFillMinimumSliceDistance else {
            return
        }

        state.lastEdgePoint = point
        state.rawEdgePoints.append(point)
        textureFillGestureState = state
        updateTextureFillPreviewSelection(from: state)
    }

    private func updateTextureFillGesture(to points: [CanvasPoint]) {
        guard var state = textureFillGestureState else { return }

        var slices: [TextureFillSlice] = []
        slices.reserveCapacity(points.count)

        for point in points {
            if let previousEdgePoint = state.lastEdgePoint {
                guard textureFillDistance(from: previousEdgePoint, to: point) >= Self.textureFillMinimumSliceDistance else {
                    continue
                }

                slices.append(
                    TextureFillSlice(
                        anchorPoint: state.anchorPoint,
                        previousEdgePoint: previousEdgePoint,
                        currentEdgePoint: point
                    )
                )
                state.lastEdgePoint = point
                state.rawEdgePoints.append(point)
                continue
            }

            guard textureFillDistance(from: state.anchorPoint, to: point) >= Self.textureFillMinimumSliceDistance else {
                continue
            }

            state.lastEdgePoint = point
            state.rawEdgePoints.append(point)
        }

        let didRender = slices.isEmpty == false
            ? renderTextureFillSliceBatch(slices, state: &state)
            : false
        textureFillGestureState = state
        if didRender {
            updateTextureFillPreviewSelection(from: state)
        }
    }

    private func commitTextureFillGesture(
        at point: CanvasPoint,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard var state = textureFillGestureState else { return false }
        defer { resetTextureFillGesture(reason: "commit") }

        if let previousEdgePoint = state.lastEdgePoint,
           textureFillDistance(from: previousEdgePoint, to: point) >= Self.textureFillMinimumSliceDistance {
            state.renderedSliceCount += 1
            state.rawEdgePoints.append(point)
        }

        guard state.renderedSliceCount > 0 else {
            return false
        }

        checkpointHistoryIfPossible(
            operationKind: "textureFill.drag",
            candidateChangedLayerIDs: [state.layerID],
            additionalOperationKinds: ["textureFillSliceRenderer"],
            captureMode: .inPlaceChangedLayers([state.layerID]),
            workspaceOverride: workspaceSnapshotClearingSelection(
                from: bootstrap.workspaceStore.state
            )
        )

        _ = rebuildTextureFillFinalResult(from: state)
        recordDrawingActivityIfNeeded()
        showStatus(.init(kind: .success, message: "已填充纹理区域"))
        return true
    }

    @discardableResult
    private func renderTextureFillSlice(
        _ slice: TextureFillSlice,
        state: inout TextureFillGestureState
    ) -> Bool {
        renderTextureFillSliceBatch([slice], state: &state)
    }

    @discardableResult
    private func renderTextureFillSliceBatch(
        _ slices: [TextureFillSlice],
        state: inout TextureFillGestureState
    ) -> Bool {
        guard !slices.isEmpty else { return false }
        state.renderedSliceCount += slices.count
        return true
    }

    private func rebuildTextureFillFinalResult(from state: TextureFillGestureState) -> Bool {
        guard
            let liveTexture = bootstrap.layerSurfaceStore.texture(for: state.surfaceID),
            let baseTexture = state.baseTexture,
            let replayTexture = makeTextureFillReplayTextureCopy(from: baseTexture)
        else {
            return false
        }

        if state.tipSettings.sourceSemantic == .importedImage,
           state.tipSettings.customTipMaskData != nil,
           applyTextureFillImportedFinalField(
               replayTexture: replayTexture,
               liveTexture: liveTexture,
               state: state
           ) {
            layerThumbnailCache.removeValue(forKey: state.layerID)
            bootstrap.strokeEngine.resetBrushPipelineState()
            clearRecentBrushAdjustmentState()
            noteCanvasContentChanged(changedLayerIDs: [state.layerID])
            refresh(invalidatedLayerIDs: [state.layerID])
            return true
        }

        if state.tipSettings.sourceSemantic != .importedImage,
           applyTextureFillBrushFinalField(
               replayTexture: replayTexture,
               liveTexture: liveTexture,
               state: state
           ) {
            layerThumbnailCache.removeValue(forKey: state.layerID)
            bootstrap.strokeEngine.resetBrushPipelineState()
            clearRecentBrushAdjustmentState()
            noteCanvasContentChanged(changedLayerIDs: [state.layerID])
            refresh(invalidatedLayerIDs: [state.layerID])
            return true
        }

        return false
    }

    private func applyTextureFillBrushFinalField(
        replayTexture: MTLTexture,
        liveTexture: MTLTexture,
        state: TextureFillGestureState
    ) -> Bool {
        guard let materialAlphaBytes = StageOneBrushPreviewRasterizer.materialFieldAlphaBytes(
            for: state.brush,
            resolution: 384
        ) else {
            return false
        }
        return applyTextureFillMaterialFinalField(
            replayTexture: replayTexture,
            liveTexture: liveTexture,
            state: state,
            materialTextureData: Data(materialAlphaBytes)
        )
    }

    private func applyTextureFillImportedFinalField(
        replayTexture: MTLTexture,
        liveTexture: MTLTexture,
        state: TextureFillGestureState
    ) -> Bool {
        guard let stampMaskData = state.tipSettings.customTipMaskData else {
            return false
        }
        return applyTextureFillMaterialFinalField(
            replayTexture: replayTexture,
            liveTexture: liveTexture,
            state: state,
            materialTextureData: stampMaskData
        )
    }

    private func applyTextureFillMaterialFinalField(
        replayTexture: MTLTexture,
        liveTexture: MTLTexture,
        state: TextureFillGestureState,
        materialTextureData: Data
    ) -> Bool {
        let canvasSize = CanvasSize(width: replayTexture.width, height: replayTexture.height)
        guard let smoothShape = textureFillSmoothFinalSelectionShape(
            from: state.rawEdgePoints,
            anchorPoint: state.anchorPoint,
            canvasSize: canvasSize
        ) else {
            return false
        }

        let minX = max(Int(smoothShape.bounds.minX.rounded(.down)), 0)
        let minY = max(Int(smoothShape.bounds.minY.rounded(.down)), 0)
        let maxX = min(Int(smoothShape.bounds.maxX.rounded(.up)), replayTexture.width)
        let maxY = min(Int(smoothShape.bounds.maxY.rounded(.up)), replayTexture.height)
        guard minX < maxX, minY < maxY else {
            return false
        }

        let boundedMask = selectionMaskRegion(
            for: smoothShape,
            canvasSize: canvasSize,
            originX: minX,
            originY: minY,
            width: maxX - minX,
            height: maxY - minY
        )
        guard boundedMask.width > 0, boundedMask.height > 0, !boundedMask.alphaBytes.isEmpty else {
            return false
        }

        let alphaLockTexture = makeAlphaLockTextureCopyIfNeeded(for: state.layerID, sourceTexture: replayTexture)
        guard alphaLockTexture != nil || !layerTransparentPixelLockEnabled(state.layerID) else {
            return false
        }
        guard let commandBuffer = bootstrap.metalContext.commandQueue.makeCommandBuffer() else {
            return false
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = replayTexture
        renderPassDescriptor.colorAttachments[0].loadAction = .load
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        bootstrap.selectionFillRenderer.encode(
            into: renderPassDescriptor,
            commandBuffer: commandBuffer,
            canvasSize: canvasSize,
            selectionMaskOriginX: boundedMask.originX,
            selectionMaskOriginY: boundedMask.originY,
            selectionMaskWidth: boundedMask.width,
            selectionMaskHeight: boundedMask.height,
            selectionMaskAlphaBytes: boundedMask.alphaBytes,
            fillCenter: state.anchorPoint,
            color: state.color,
            paintJitterAmount: state.tipSettings.paintJitterAmount,
            paintContrastAmount: state.brush.effectivePaintContrastAmount,
            distortionAmount: 0,
            alphaLockTexture: alphaLockTexture,
            materialTextureData: materialTextureData,
            materialScale: state.tipSettings.materialScale,
            materialCoverage: state.tipSettings.coverage,
            materialVariation: state.tipSettings.variation,
            materialSeed: state.sessionSeed,
            materialAngleRadians: textureFillMaterialAngle(from: state.rawEdgePoints),
            materialArrangement: state.tipSettings.arrangement
        )

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return false }
        bootstrap.layerSurfaceStore.copyTexture(
            from: replayTexture,
            to: liveTexture,
            metal: bootstrap.metalContext
        )
        return true
    }

    private func textureFillMaterialAngle(from points: [CanvasPoint]) -> Float {
        guard points.count >= 3 else { return 0 }
        let count = Double(points.count)
        let meanX = points.reduce(0) { $0 + $1.x } / count
        let meanY = points.reduce(0) { $0 + $1.y } / count
        var xx = 0.0
        var yy = 0.0
        var xy = 0.0
        for point in points {
            let dx = point.x - meanX
            let dy = point.y - meanY
            xx += dx * dx
            yy += dy * dy
            xy += dx * dy
        }
        return Float(0.5 * atan2(2 * xy, xx - yy))
    }

    private func applyTextureFillSmoothFinalMask(
        replayTexture: MTLTexture,
        baseTexture: MTLTexture,
        liveTexture: MTLTexture,
        state: TextureFillGestureState
    ) -> Bool {
        let canvasSize = CanvasSize(width: replayTexture.width, height: replayTexture.height)
        guard let smoothShape = textureFillSmoothFinalSelectionShape(
            from: state.rawEdgePoints,
            anchorPoint: state.anchorPoint,
            canvasSize: canvasSize
        ) else {
            return false
        }

        let minX = max(Int(smoothShape.bounds.minX.rounded(.down)), 0)
        let minY = max(Int(smoothShape.bounds.minY.rounded(.down)), 0)
        let maxX = min(Int(smoothShape.bounds.maxX.rounded(.up)), replayTexture.width)
        let maxY = min(Int(smoothShape.bounds.maxY.rounded(.up)), replayTexture.height)
        guard minX < maxX, minY < maxY else {
            return false
        }

        let boundedMask = selectionMaskRegion(
            for: smoothShape,
            canvasSize: canvasSize,
            originX: minX,
            originY: minY,
            width: maxX - minX,
            height: maxY - minY
        )
        guard boundedMask.width > 0, boundedMask.height > 0, !boundedMask.alphaBytes.isEmpty else {
            return false
        }

        do {
            let replaySnapshot = try bootstrap.textureSerializer.snapshot(
                texture: replayTexture,
                originX: minX,
                originY: minY,
                width: maxX - minX,
                height: maxY - minY
            )
            let baseSnapshot = try bootstrap.textureSerializer.snapshot(
                texture: baseTexture,
                originX: minX,
                originY: minY,
                width: maxX - minX,
                height: maxY - minY
            )
            let finalSnapshot = Self.maskCompositedSnapshot(
                base: baseSnapshot,
                overlay: replaySnapshot,
                using: boundedMask
            )
            try bootstrap.textureSerializer.restore(
                snapshot: finalSnapshot,
                into: liveTexture,
                destinationX: minX,
                destinationY: minY
            )
            return true
        } catch {
            return false
        }
    }

    private func textureFillSmoothFinalSelectionShape(
        from rawEdgePoints: [CanvasPoint],
        anchorPoint: CanvasPoint,
        canvasSize: CanvasSize
    ) -> SelectionShape? {
        let smoothedPoints = smoothedClosedLassoPoints(
            rawPoints: rawEdgePoints,
            closingTo: anchorPoint
        )
        guard smoothedPoints.count >= 3 else {
            return nil
        }
        return SelectionShape(
            kind: .lasso,
            bounds: CanvasRect.bounding(points: smoothedPoints),
            pathPoints: smoothedPoints
        ).clamped(to: canvasSize)
    }

    private func textureFillLiveSelectionShape(
        from rawEdgePoints: [CanvasPoint],
        canvasSize: CanvasSize
    ) -> SelectionShape? {
        guard rawEdgePoints.count >= 3 else {
            return nil
        }

        return SelectionShape(
            kind: .lasso,
            bounds: CanvasRect.bounding(points: rawEdgePoints),
            pathPoints: rawEdgePoints
        ).clamped(to: canvasSize)
    }

    private func makeTextureFillReplayTextureCopy(from sourceTexture: MTLTexture) -> MTLTexture? {
        guard let copyTexture = bootstrap.layerSurfaceStore.makeTexture(
            width: sourceTexture.width,
            height: sourceTexture.height,
            pixelFormat: sourceTexture.pixelFormat,
            usage: [.shaderRead, .shaderWrite, .renderTarget],
            storageMode: .private,
            metal: bootstrap.metalContext
        ) else {
            return nil
        }

        bootstrap.layerSurfaceStore.copyTexture(
            from: sourceTexture,
            to: copyTexture,
            metal: bootstrap.metalContext
        )
        return copyTexture
    }

    private func textureFillDistance(from start: CanvasPoint, to end: CanvasPoint) -> Double {
        hypot(end.x - start.x, end.y - start.y)
    }

    // MARK: - 选区鼠标交互

    // 每次开始新选区操作时递增，用于让过期的异步栅格化任务自动丢弃结果
    private var selectionEpoch: Int = 0
    private var activeRasterizationTask: Task<Void, Never>?
    private var selectionWorkCancellation: WorkCancellation?

    private func cancelActiveRasterizationTask() {
        selectionWorkCancellation?.cancel()
        selectionWorkCancellation = nil
        activeRasterizationTask?.cancel()
        activeRasterizationTask = nil
        isRefiningSelection = false
    }

    private func requestMagicWandSelection(
        at point: CanvasPoint,
        modifiers: NSEvent.ModifierFlags
    ) {
        let canvasSize = workspace.document.canvasSize
        guard point.x >= 0, point.y >= 0,
              point.x < Double(canvasSize.width), point.y < Double(canvasSize.height) else {
            return
        }

        cancelActiveRasterizationTask()
        selectionEpoch += 1
        let capturedEpoch = selectionEpoch
        let historyBaseShape = workspace.selection.committedShape?.clamped(to: canvasSize)
        let historyBaseMaskBytes = selectionMaskBytes(for: historyBaseShape, canvasSize: canvasSize)
        let mode = resolvedMagicWandSelectionMode(modifiers: modifiers)
        let settings = smartSelectionSettings
        let capturedRevision = canvasContentRevision

        _ = flushBrushEditingBoundary(reason: "magicWandSelection")
            bootstrap.layerSurfaceStore.prepareTextures(
                for: workspace.document,
                metal: bootstrap.metalContext
            )

            let samplingTexture: MTLTexture
            do {
                switch settings.sampleSource {
            case .currentLayer:
                let layerID = workspace.document.activeLayerID
                guard let layer = workspace.document.layer(layerID), layer.isPaintLayer else {
                    showStatus(.init(kind: .info, message: "当前层没有可采样的像素内容"))
                    return
                }
                    samplingTexture = try makeCompositeTexture(
                        layers: [layer],
                        document: workspace.document,
                        waitUntilCompleted: false
                    )
            case .allVisibleLayers:
                    samplingTexture = try makeVisibleCompositeTexture(waitUntilCompleted: false)
                }
            } catch {
                showStatus(.init(kind: .error, message: "无法建立魔棒采样：\(error.localizedDescription)"))
                return
            }

            let textureBox = WorkspaceUncheckedBox(samplingTexture)
            let engineBox = WorkspaceUncheckedBox(bootstrap.magicWandSelectionEngine)
            isRefiningSelection = true
            showStatus(.init(kind: .info, message: "正在按点击颜色建立魔棒选区…"))
            let cancellation = WorkCancellation()
            selectionWorkCancellation = cancellation

            activeRasterizationTask = Task { [weak self] in
                let result = await Task.detached(priority: .userInitiated) {
                    Result<SmartSelectionSegmentationResult?, Error> {
                        try engineBox.value.select(
                            texture: textureBox.value,
                            at: point,
                            settings: settings,
                            cancellation: cancellation
                        )
                    }
                }.value

                guard let self, self.selectionEpoch == capturedEpoch else { return }
                self.activeRasterizationTask = nil
                self.isRefiningSelection = false
                guard !Task.isCancelled else { return }
                guard self.canvasContentRevision == capturedRevision else {
                    self.showStatus(.init(kind: .info, message: "画布已变化，已取消过期魔棒结果"))
                    return
                }

                do {
                    guard let segmented = try result.get() else {
                        self.showStatus(.init(kind: .info, message: "点击位置没有可选择的相近颜色"))
                        return
                    }
                    let incoming = Self.fullCanvasSmartSelectionShape(
                        segmented,
                        canvasSize: canvasSize,
                        lassoPoints: [point]
                    )
                    let nextShape = Self.combinedMagicWandSelectionShape(
                        incomingShape: incoming,
                        canvasSize: canvasSize,
                        mode: mode,
                        baseShape: historyBaseShape,
                        baseMaskBytes: historyBaseMaskBytes
                    )
                    if nextShape != historyBaseShape {
                        self.checkpointSelectionChangeIfPossible(previousCommittedShape: historyBaseShape)
                    }
                    self.bootstrap.workspaceStore.updateSelection { selection in
                        selection.committedShape = nextShape
                        selection.inProgressShape = nil
                        selection.anchorPoint = nil
                        selection.activeKind = nil
                        selection.activeCombineMode = .replace
                    }
                    self.smartSelectionDisplayMode = .tint
                    self.refreshLightweight()
                    self.recordDrawingActivityIfNeeded()
                    self.showStatus(.init(kind: .success, message: self.magicWandSuccessMessage(for: mode)))
                } catch {
                    self.showStatus(.init(kind: .error, message: error.localizedDescription))
                }
        }
    }

    private func resolvedMagicWandSelectionMode(
        modifiers: NSEvent.ModifierFlags
    ) -> MagicWandSelectionMode {
        let normalized = modifiers.intersection(.deviceIndependentFlagsMask)
        if normalized.contains(.shift), normalized.contains(.option) { return .intersect }
        if normalized.contains(.option) { return .subtract }
        if normalized.contains(.shift) { return .add }
        return smartSelectionSettings.selectionMode
    }

    private func magicWandSuccessMessage(for mode: MagicWandSelectionMode) -> String {
        switch mode {
        case .replace: return "已创建魔棒选区"
        case .add: return "已增加魔棒选区"
        case .subtract: return "已减去魔棒选区"
        case .intersect: return "已保留魔棒交集"
        }
    }

    nonisolated private static func combinedMagicWandSelectionShape(
        incomingShape: SelectionShape,
        canvasSize: CanvasSize,
        mode: MagicWandSelectionMode,
        baseShape: SelectionShape?,
        baseMaskBytes: [UInt8]
    ) -> SelectionShape? {
        guard let incoming = incomingShape.maskData else { return baseShape }
        if mode == .replace { return incomingShape.isEmpty ? nil : incomingShape }
        let merged = SelectionMaskCombiner.combine(
            base: baseMaskBytes.isEmpty ? nil : baseMaskBytes,
            incoming: [UInt8](incoming.alphaBytes),
            mode: mode
        )
        let result = SelectionShape.mask(
            canvasWidth: canvasSize.width,
            canvasHeight: canvasSize.height,
            alphaBytes: merged
        )
        return result.isEmpty ? nil : result
    }

    nonisolated private static func fullCanvasSmartSelectionShape(
        _ segmented: SmartSelectionSegmentationResult,
        canvasSize: CanvasSize,
        lassoPoints: [CanvasPoint]
    ) -> SelectionShape {
        var canvasBytes = [UInt8](repeating: 0, count: canvasSize.width * canvasSize.height)
        guard
            segmented.width > 0,
            segmented.height > 0,
            segmented.alphaBytes.count == segmented.width * segmented.height
        else {
            return SelectionShape.mask(
                canvasWidth: canvasSize.width,
                canvasHeight: canvasSize.height,
                alphaBytes: canvasBytes
            )
        }
        for localY in 0..<segmented.height {
            let sourceStart = localY * segmented.width
            let destinationStart = ((segmented.originY + localY) * canvasSize.width) + segmented.originX
            canvasBytes.replaceSubrange(
                destinationStart..<(destinationStart + segmented.width),
                with: segmented.alphaBytes[sourceStart..<(sourceStart + segmented.width)]
            )
        }
        let maskData = SelectionMaskData(
            canvasWidth: canvasSize.width,
            canvasHeight: canvasSize.height,
            alphaBytes: Data(canvasBytes)
        )
        return SelectionShape(
            kind: .mask,
            bounds: segmented.selectedBounds.clamped(to: canvasSize),
            pathPoints: lassoPoints,
            maskData: maskData
        )
    }

    func handleSelectionMouseDown(at point: CanvasPoint, modifiers: NSEvent.ModifierFlags) -> SelectionMouseDownAction {
        let normalized = modifiers.intersection(.deviceIndependentFlagsMask)
        let hasModifier = normalized.contains(.shift) || normalized.contains(.option)

        if workspace.toolSession.activeTool == .smartSelection {
            requestMagicWandSelection(at: point, modifiers: modifiers)
            return .idle
        }

        if workspace.toolSession.activeTool == .polygonSelection {
            if polygonSelectionState.phase == .building {
                return .idle
            }

            if hasModifier {
                return .idle
            }

            if let committed = bootstrap.workspaceStore.state.selection.committedShape, committed.contains(point) {
                cancelActiveRasterizationTask()
                selectionEpoch += 1
                pendingCombineMode = nil
                selectionMoveBaseShape = committed
                selectionMoveAccumulatedDelta = CanvasPoint(x: 0, y: 0)
                selectionMovePreviewOffset = CanvasPoint(x: 0, y: 0)
                return .beginMoving
            }

            return .idle
        }

        if workspace.toolSession.activeTool == .lassoFill {
            cancelActiveRasterizationTask()
            selectionEpoch += 1
            pendingCombineMode = selectionCombineMode(for: .lasso, modifiers: normalized)
            pendingCombineBaseShape = nil
            activeLassoRawPoints = []
            activeLassoPreviewPoints = []
            lassoSamplingDebugPoints = []
            samePathPreviewDebugShape = nil
            samePathCommittedDebugShape = nil
            selectionMoveBaseShape = nil
            selectionMoveAccumulatedDelta = CanvasPoint(x: 0, y: 0)
            bootstrap.workspaceStore.updateSelection { selection in
                selection.committedShape = nil
                selection.inProgressShape = nil
                selection.anchorPoint = nil
                selection.activeKind = nil
                selection.activeCombineMode = .replace
            }
            beginSelection(kind: .lasso, at: point, modifiers: modifiers)
            return .beginDrawing
        }

        if workspace.toolSession.activeTool == .textureFill {
            cancelActiveRasterizationTask()
            selectionEpoch += 1
            pendingCombineMode = nil
            pendingCombineBaseShape = nil
            activeLassoRawPoints = []
            activeLassoPreviewPoints = []
            activeLassoBounds = nil
            lassoSamplingDebugPoints = []
            samePathPreviewDebugShape = nil
            samePathCommittedDebugShape = nil
            selectionMoveBaseShape = nil
            selectionMoveAccumulatedDelta = CanvasPoint(x: 0, y: 0)
            selectionMovePreviewOffset = CanvasPoint(x: 0, y: 0)
            bootstrap.workspaceStore.updateSelection { selection in
                selection.committedShape = nil
                selection.inProgressShape = nil
                selection.anchorPoint = nil
                selection.activeKind = nil
                selection.activeCombineMode = .replace
            }
            return beginTextureFillGesture(at: point) ? .beginDrawing : .idle
        }

        if hasModifier {
            // 增减选：保存当前选区作为 base，开始画新选区
            cancelActiveRasterizationTask()
            selectionMoveBaseShape = nil
            pendingCombineBaseShape = bootstrap.workspaceStore.state.selection.committedShape
            let kind = selectionKindForActiveTool()
            // 在 beginSelection 之前计算并保存 combineMode，因为 commitSelection 时 modifiers 可能已松开
            pendingCombineMode = selectionCombineMode(for: kind, modifiers: normalized)
            beginSelection(kind: kind, at: point, modifiers: modifiers)
            return .beginDrawing
        }

        if let committed = bootstrap.workspaceStore.state.selection.committedShape {
            if committed.contains(point) {
                cancelActiveRasterizationTask()
                selectionEpoch += 1
                pendingCombineMode = nil
                selectionMoveBaseShape = committed
                selectionMoveAccumulatedDelta = CanvasPoint(x: 0, y: 0)
                selectionMovePreviewOffset = CanvasPoint(x: 0, y: 0)
                return .beginMoving
            } else {
                cancelActiveRasterizationTask()
                selectionEpoch += 1
                pendingCombineMode = nil
                pendingCombineBaseShape = nil
                activeLassoRawPoints = []
                activeLassoPreviewPoints = []
                lassoSamplingDebugPoints = []
                samePathPreviewDebugShape = nil
                samePathCommittedDebugShape = nil
                selectionMoveBaseShape = nil
                selectionMoveAccumulatedDelta = CanvasPoint(x: 0, y: 0)
                selectionMovePreviewOffset = CanvasPoint(x: 0, y: 0)
                bootstrap.workspaceStore.updateSelection { selection in
                    selection.committedShape = nil
                    selection.inProgressShape = nil
                    selection.anchorPoint = nil
                    selection.activeKind = nil
                    selection.activeCombineMode = .replace
                }
                let kind = selectionKindForActiveTool()
                beginSelection(kind: kind, at: point, modifiers: modifiers)
                return .beginDrawing
            }
        }

        pendingCombineMode = nil
        pendingCombineBaseShape = nil
        selectionMovePreviewOffset = CanvasPoint(x: 0, y: 0)
        let kind = selectionKindForActiveTool()
        beginSelection(kind: kind, at: point, modifiers: modifiers)
        return .beginDrawing
    }

    // 增减选时保存的 base 选区，避免异步任务完成前状态被覆盖
    private var pendingCombineBaseShape: SelectionShape?
    // 增减选时保存的 combineMode，避免 commitSelection 时 activeCombineMode 已被重置
    private var pendingCombineMode: SelectionCombineMode?

    private func selectionKindForActiveTool() -> SelectionShapeKind {
        switch workspace.toolSession.activeTool {
        case .ellipseSelection: return .ellipse
        case .lassoSelection, .lassoFill, .textureFill: return .lasso
        default: return .rectangle
        }
    }

    private var selectionMoveBaseShape: SelectionShape?
    private var selectionMoveAccumulatedDelta = CanvasPoint(x: 0, y: 0)
    private(set) var selectionMovePreviewOffset = CanvasPoint(x: 0, y: 0)

    func moveSelectionPreview(by deltaX: Double, deltaY: Double) {
        ideationBranchActivityHandler?()
        guard let base = selectionMoveBaseShape else { return }
        selectionMoveAccumulatedDelta.x += deltaX
        selectionMoveAccumulatedDelta.y += deltaY
        let dx = selectionMoveAccumulatedDelta.x
        let dy = selectionMoveAccumulatedDelta.y
        _ = base
        selectionMovePreviewOffset = CanvasPoint(x: dx, y: dy)
        refreshSelectionOverlayOnly()
        relayIdeationOperation(.moveSelectionPreview(deltaX: deltaX, deltaY: deltaY))
    }

    func commitSelectionMove() {
        ideationBranchActivityHandler?()
        guard
            let base = selectionMoveBaseShape,
            selectionMoveAccumulatedDelta.x != 0 || selectionMoveAccumulatedDelta.y != 0
        else {
            selectionMoveBaseShape = nil
            selectionMoveAccumulatedDelta = CanvasPoint(x: 0, y: 0)
            selectionMovePreviewOffset = CanvasPoint(x: 0, y: 0)
            return
        }
        let dx = selectionMoveAccumulatedDelta.x
        let dy = selectionMoveAccumulatedDelta.y
        selectionMoveBaseShape = nil
        selectionMoveAccumulatedDelta = CanvasPoint(x: 0, y: 0)
        selectionMovePreviewOffset = CanvasPoint(x: 0, y: 0)
        let moved = base.translatedBy(x: dx, y: dy)
        bootstrap.workspaceStore.updateSelection { selection in
            selection.committedShape = moved
        }
        refreshLightweight()
        relayIdeationOperation(.commitSelectionMove)
    }

    func clearSelection() {
        switch transformState.clearBehavior() {
        case .apply:
            applySelectionTransform(clearSelectionAfterApply: true)
            return
        case .cancel:
            cancelSelectionTransform(clearSelectionAfterCancel: true)
            return
        case .none:
            break
        }

        let hadSelection = workspace.selection.displayRect != nil
        if hadSelection {
            checkpointHistoryIfPossible()
        }
        activeLassoRawPoints = []
        activeLassoPreviewPoints = []
        lassoSamplingDebugPoints = []
        samePathPreviewDebugShape = nil
        samePathCommittedDebugShape = nil
        bootstrap.workspaceStore.updateSelection { selection in
            selection = .empty
        }

        refresh()
        showStatus(.init(kind: .info, message: "已清除选区"))
    }

    func selectAllCanvas() {
        guard !isTransformingSelection else {
            showStatus(.init(kind: .info, message: "请先应用或取消变形"))
            return
        }
        let previousSelection = bootstrap.workspaceStore.state.selection.committedShape
        guard let fullCanvas = SelectionRefinement.fullCanvasShape(
            canvasSize: workspace.document.canvasSize
        ), previousSelection != fullCanvas else {
            return
        }
        checkpointSelectionChangeIfPossible(previousCommittedShape: previousSelection)
        bootstrap.workspaceStore.updateSelection { selection in
            selection.committedShape = fullCanvas
            selection.inProgressShape = nil
            selection.anchorPoint = nil
            selection.activeKind = nil
            selection.activeCombineMode = .replace
        }
        refreshLightweight()
        showStatus(.init(kind: .success, message: "已全选画布"))
    }

    func invertSelection() {
        refineSelection(.init(kind: .invert))
    }

    func expandSelection(radiusPixels: Int) {
        refineSelection(.init(kind: .expand, radiusPixels: radiusPixels))
    }

    func contractSelection(radiusPixels: Int) {
        refineSelection(.init(kind: .contract, radiusPixels: radiusPixels))
    }

    private func refineSelection(_ request: SelectionRefinementRequest) {
        guard !isTransformingSelection else {
            showStatus(.init(kind: .info, message: "请先应用或取消变形"))
            return
        }
        if request.kind != .invert, request.radiusPixels < 1 {
            showStatus(.init(kind: .info, message: "调整半径必须大于 0"))
            return
        }

        let capturedSelection = bootstrap.workspaceStore.state.selection.committedShape
        if request.kind != .invert, capturedSelection == nil {
            showStatus(.init(kind: .info, message: "没有可调整的选区"))
            return
        }

        _ = flushBrushEditingBoundary(reason: "refineSelection")
        cancelActiveRasterizationTask()
        selectionEpoch += 1
        let capturedEpoch = selectionEpoch
        let capturedCanvasSize = workspace.document.canvasSize
        showStatus(.init(kind: .info, message: "正在调整选区…"))
        isRefiningSelection = true

        activeRasterizationTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                switch request.kind {
                case .invert:
                    return SelectionRefinement.inverted(
                        capturedSelection,
                        canvasSize: capturedCanvasSize
                    )
                case .expand:
                    guard let capturedSelection else { return nil }
                    return SelectionRefinement.expanded(
                        capturedSelection,
                        canvasSize: capturedCanvasSize,
                        radiusPixels: request.radiusPixels
                    )
                case .contract:
                    guard let capturedSelection else { return nil }
                    return SelectionRefinement.contracted(
                        capturedSelection,
                        canvasSize: capturedCanvasSize,
                        radiusPixels: request.radiusPixels
                    )
                case .feather:
                    return nil
                }
            }.value

            guard let self, !Task.isCancelled, self.selectionEpoch == capturedEpoch else { return }
            self.activeRasterizationTask = nil
            self.isRefiningSelection = false
            guard self.bootstrap.workspaceStore.state.selection.committedShape == capturedSelection else { return }
            guard let result else {
                if request.kind == .contract, capturedSelection != nil {
                    self.checkpointSelectionChangeIfPossible(previousCommittedShape: capturedSelection)
                    self.bootstrap.workspaceStore.updateSelection { selection in
                        selection = .empty
                    }
                    self.refreshLightweight()
                    self.showStatus(.init(kind: .success, message: "选区已收缩为空"))
                } else {
                    self.showStatus(.init(kind: .info, message: "选区无变化"))
                }
                return
            }

            self.checkpointSelectionChangeIfPossible(previousCommittedShape: capturedSelection)
            self.bootstrap.workspaceStore.updateSelection { selection in
                selection.committedShape = result
                selection.inProgressShape = nil
                selection.anchorPoint = nil
                selection.activeKind = nil
                selection.activeCombineMode = .replace
            }
            self.refreshLightweight()
            let actionName = switch request.kind {
            case .invert: "反选"
            case .expand: "扩展"
            case .contract: "收缩"
            case .feather: "羽化"
            }
            self.showStatus(.init(
                kind: .success,
                message: request.kind == .invert ? "已反选" : "已\(actionName)选区 \(request.radiusPixels) px"
            ))
        }
    }

    func featherSelection(radiusPixels: Int) {
        guard !isTransformingSelection else {
            showStatus(.init(kind: .info, message: "请先应用或取消变形"))
            return
        }
        guard (1...512).contains(radiusPixels) else {
            showStatus(.init(kind: .info, message: "羽化半径必须在 1–512 像素之间"))
            return
        }
        guard let capturedSelection = bootstrap.workspaceStore.state.selection.committedShape else {
            showStatus(.init(kind: .info, message: "没有可羽化的选区"))
            return
        }

        _ = flushBrushEditingBoundary(reason: "featherSelection")
        cancelActiveRasterizationTask()
        selectionEpoch += 1
        let capturedEpoch = selectionEpoch
        let capturedCanvasSize = workspace.document.canvasSize
        showStatus(.init(kind: .info, message: "正在羽化选区…"))
        isRefiningSelection = true

        activeRasterizationTask = Task { [weak self] in
            guard let self else { return }
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try self.featheredSelectionShape(
                        capturedSelection,
                        canvasSize: capturedCanvasSize,
                        radiusPixels: radiusPixels
                    )
                }
            }.value

            guard !Task.isCancelled, self.selectionEpoch == capturedEpoch else { return }
            self.activeRasterizationTask = nil
            self.isRefiningSelection = false
            guard self.bootstrap.workspaceStore.state.selection.committedShape == capturedSelection else { return }

            do {
                let featheredSelection = try result.get()
                self.checkpointSelectionChangeIfPossible(previousCommittedShape: capturedSelection)
                self.bootstrap.workspaceStore.updateSelection { selection in
                    selection.committedShape = featheredSelection
                    selection.inProgressShape = nil
                    selection.anchorPoint = nil
                    selection.activeKind = nil
                    selection.activeCombineMode = .replace
                }
                self.refreshLightweight()
                self.showStatus(.init(kind: .success, message: "已羽化选区 \(radiusPixels) px"))
            } catch {
                self.showStatus(.init(kind: .error, message: error.localizedDescription))
            }
        }
    }

    func beginSelectionTransform(at start: CanvasPoint) {
        beginSelectionTransform(at: start, mode: .move)
    }

    func setFreeTransformToolMode(_ mode: FreeTransformToolMode) {
        guard workspace.toolSession.activeTool == .freeTransform else { return }
        guard !isApplyingTransformCommit, freeTransformToolMode != mode else { return }

        if mode == .standard,
           freeTransformMeshWarpGrid?.isIdentity == false {
            showStatus(.init(kind: .info, message: "请先应用或取消网格变形"))
            return
        }

        freeTransformToolMode = mode
        switch mode {
        case .standard:
            transformState.meshWarpGrid = nil
            transformState.dragStartMeshWarpGrid = nil
            setFreeTransformMeshWarpGrid(nil)
        case .mesh:
            ensureFreeTransformMeshWarpGridIfNeeded()
        }
        transformPreviewRevision &+= 1
        relayIdeationOperation(.setFreeTransformToolMode(mode))
    }

    func beginSelectionTransform(at start: CanvasPoint, mode: FreeTransformInteractionMode) {
        beginSelectionTransform(at: start, mode: mode, modifiers: [])
    }

    func beginSelectionTransform(
        at start: CanvasPoint,
        mode: FreeTransformInteractionMode,
        modifiers: NSEvent.ModifierFlags
    ) {
        ideationBranchActivityHandler?()
        ensureWholeLayerInteractionBoundsAvailableIfNeeded(for: bootstrap.workspaceStore.state)
        activateImplicitFreeTransformSelectionIfNeeded()
        guard effectiveTransformOperationShape != nil else { return }
        if freeTransformToolMode == .mesh {
            ensureFreeTransformMeshWarpGridIfNeeded()
            switch mode {
            case .meshPoint(let index):
                let wasSelected = selectedMeshWarpControlPointIndices.contains(index)
                let togglesSelection = modifiers.contains(.shift)
                selectedMeshWarpControlPointIndices = updatedMeshWarpControlPointSelection(
                    current: selectedMeshWarpControlPointIndices,
                    clickedIndex: index,
                    togglesSelection: togglesSelection
                )
                activeMeshWarpDragControlPointIndices = togglesSelection && wasSelected
                    ? []
                    : selectedMeshWarpControlPointIndices
            case .move:
                selectedMeshWarpControlPointIndices = []
                activeMeshWarpDragControlPointIndices = nil
            case .meshArea:
                selectedMeshWarpControlPointIndices = []
                activeMeshWarpDragControlPointIndices = nil
            case .scale, .rotate:
                activeMeshWarpDragControlPointIndices = nil
            }
        }

        if transformState.isActive {
            // 已经激活（freeTransform 工具多次拖动）：只开始新的拖动，不重置 accumulated offset
            transformState.beginDrag(at: start, mode: mode)
        } else {
            transformState.beginSession(at: start, mode: mode)
        }
        isFreeTransformDragging = true
        activeFreeTransformInteractionMode = mode
        freeTransformMoveLogCount = 0
        if mode == .move {
            transformLogger.debug("[transform] overlayHiddenDuringMove=true")
        }
        setFreeTransformPreview(transformState.preview)
        isTransformingSelection = transformState.isActive
        relayIdeationOperation(.beginSelectionTransform(
            start: start,
            mode: mode,
            modifiers: .init(flags: modifiers)
        ))
    }

    func updateSelectionTransform(to point: CanvasPoint) {
        updateSelectionTransform(to: point, modifiers: [])
    }

    func updateSelectionTransform(
        to point: CanvasPoint,
        modifiers: NSEvent.ModifierFlags
    ) {
        ideationBranchActivityHandler?()
        guard
            isTransformingSelection,
            let dragStartPoint = transformState.dragStartPoint
        else {
            return
        }

        switch transformState.interactionMode {
        case .move:
            if freeTransformToolMode == .mesh,
               let startGrid = transformState.dragStartMeshWarpGrid {
                let delta = CanvasPoint(
                    x: point.x - dragStartPoint.x,
                    y: point.y - dragStartPoint.y
                )
                let nextGrid = startGrid.translated(by: delta)
                transformState.meshWarpGrid = nextGrid
                setFreeTransformMeshWarpGrid(nextGrid)
                break
            }
            let nextPreview = freeTransformTranslatedPreview(
                dragStartPoint: dragStartPoint,
                currentPoint: point,
                startPreview: transformState.dragStartPreview
            )
            transformState.preview = nextPreview
            transformState.accumulatedOffset = nextPreview.translation
            if freeTransformMoveLogCount < 10 {
                transformLogger.debug(
                    "[transform] moveTranslation x=\(nextPreview.translation.x, privacy: .public) y=\(nextPreview.translation.y, privacy: .public)"
                )
                freeTransformMoveLogCount += 1
            }
            setFreeTransformPreview(nextPreview)
        case .scale(let handle):
            guard let shape = effectiveTransformInteractionShape else { return }
            let uniformScaleEnabled = modifiers.contains(.command)
            let nextPreview = freeTransformScaledPreview(
                bounds: shape.bounds,
                handle: handle,
                dragStartPoint: dragStartPoint,
                currentPoint: point,
                startPreview: transformState.dragStartPreview,
                uniformScale: uniformScaleEnabled
            )
            transformState.preview = nextPreview
            transformState.accumulatedOffset = nextPreview.translation
            transformLogger.debug(
                "[transform] uniformScaleEnabled=\(uniformScaleEnabled, privacy: .public) scaleX=\(nextPreview.scaleX, privacy: .public) scaleY=\(nextPreview.scaleY, privacy: .public)"
            )
            setFreeTransformPreview(nextPreview)
        case .rotate:
            guard let shape = effectiveTransformInteractionShape else { return }
            let nextPreview = rotatedPreview(
                for: shape.bounds,
                dragStartPoint: dragStartPoint,
                currentPoint: point,
                startPreview: transformState.dragStartPreview
            )
            transformState.preview = nextPreview
            transformState.accumulatedOffset = nextPreview.translation
            setFreeTransformPreview(nextPreview)
        case .meshPoint(let index):
            guard let startGrid = transformState.dragStartMeshWarpGrid else { return }
            let delta = CanvasPoint(
                x: point.x - dragStartPoint.x,
                y: point.y - dragStartPoint.y
            )
            let draggedIndices = activeMeshWarpDragControlPointIndices ?? [index]
            let nextGrid = startGrid.movingControlPoints(at: draggedIndices, by: delta)
            transformState.meshWarpGrid = nextGrid
            setFreeTransformMeshWarpGrid(nextGrid)
        case .meshArea(let parameter):
            guard let startGrid = transformState.dragStartMeshWarpGrid else { return }
            let delta = CanvasPoint(
                x: point.x - dragStartPoint.x,
                y: point.y - dragStartPoint.y
            )
            let nextGrid = startGrid.movingSurface(at: parameter, by: delta)
            transformState.meshWarpGrid = nextGrid
            setFreeTransformMeshWarpGrid(nextGrid)
        }
        relayIdeationOperation(.updateSelectionTransform(point: point))
    }

    /// Coordinator가 GPU offset을 직접 계산한 경우 사용 (선택 없는 전체 레이어 이동)
    func setTransformPreviewOffset(_ offset: CanvasPoint) {
        ideationBranchActivityHandler?()
        let nextPreview = FreeTransformPreview(
            translation: offset,
            scaleX: freeTransformPreview.scaleX,
            scaleY: freeTransformPreview.scaleY,
            rotationRadians: freeTransformPreview.rotationRadians
        )
        transformState.preview = nextPreview
        transformState.accumulatedOffset = nextPreview.translation
        setFreeTransformPreview(nextPreview)
        relayIdeationOperation(.setTransformPreviewOffset(offset))
    }

    func commitSelectionTransform(at end: CanvasPoint) {
        commitSelectionTransform(at: end, modifiers: [])
    }

    func commitSelectionTransform(
        at end: CanvasPoint,
        modifiers: NSEvent.ModifierFlags
    ) {
        ideationBranchActivityHandler?()
        _ = modifiers
        guard
            isTransformingSelection,
            transformState.dragStartPoint != nil
        else {
            return
        }

        if workspace.toolSession.activeTool == .freeTransform {
            transformState.endInteraction()
            activeMeshWarpDragControlPointIndices = nil
            isFreeTransformDragging = false
            activeFreeTransformInteractionMode = nil
            transformLogger.debug("[transform] overlayHiddenDuringMove=false")
            setFreeTransformPreview(transformState.preview)
        } else {
            let delta = transformState.finishDrag(at: end)
            transformPreviewOffset = transformState.accumulatedOffset
            guard delta.x != 0 || delta.y != 0 else {
                cancelSelectionTransform(clearSelectionAfterCancel: freeTransformUsesImplicitSelection)
                return
            }
            applySelectionTransform(clearSelectionAfterApply: freeTransformUsesImplicitSelection)
        }
        relayIdeationOperation(.commitSelectionTransform(end: end))
    }

    func applySelectionTransform() {
        ideationBranchActivityHandler?()
        if workspace.toolSession.activeTool == .freeTransform {
            applySelectionTransform(clearSelectionAfterApply: true)
        } else {
            applySelectionTransform(clearSelectionAfterApply: true)
        }
        relayIdeationOperation(.applySelectionTransform)
    }

    private func applySelectionTransform(clearSelectionAfterApply: Bool) {
        guard
            isTransformingSelection,
            let selectionShape = effectiveTransformOperationShape
        else {
            showStatus(.init(kind: .info, message: "当前没有活动变形"))
            return
        }

        guard !isApplyingTransformCommit else { return }

        let isFreeTransform = workspace.toolSession.activeTool == .freeTransform
        let preview = isFreeTransform ? freeTransformPreview : transformState.preview
        let meshWarpGrid = isFreeTransform && freeTransformToolMode == .mesh
            ? freeTransformMeshWarpGrid
            : nil
        let pixelDeltaX = Int(preview.translation.x.rounded())
        let pixelDeltaY = Int(preview.translation.y.rounded())
        let shouldClearSelection = clearSelectionAfterApply || freeTransformUsesImplicitSelection
        let capturedFreeTransformUsesImplicit = freeTransformUsesImplicitSelection
        let canvasSize = workspace.document.canvasSize
        let applyStart = DispatchTime.now().uptimeNanoseconds

        guard !preview.isIdentity || meshWarpGrid?.isIdentity == false else {
            transformState.reset()
            setFreeTransformMeshWarpGrid(nil)
            isFreeTransformDragging = false
            activeFreeTransformInteractionMode = nil
            freeTransformMoveLogCount = 0
            transformLogger.debug("[transform] overlayHiddenDuringMove=false")
            setFreeTransformPreview(.identity)
            isTransformingSelection = false
            freeTransformUsesImplicitSelection = false
            implicitFreeTransformSelectionShape = nil
            refresh()
            showStatus(.init(kind: .info, message: "没有变形"))
            return
        }

        guard let layerID = bootstrap.interactionController.activeEditableLayerID() else {
            transformState.reset()
            setFreeTransformMeshWarpGrid(nil)
            isFreeTransformDragging = false
            activeFreeTransformInteractionMode = nil
            freeTransformMoveLogCount = 0
            transformLogger.debug("[transform] overlayHiddenDuringMove=false")
            setFreeTransformPreview(.identity)
            isTransformingSelection = false
            freeTransformUsesImplicitSelection = false
            implicitFreeTransformSelectionShape = nil
            showStatus(.init(kind: .info, message: "当前图层已锁定"))
            refresh()
            return
        }

        guard
            let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: layerID),
            let texture = bootstrap.layerSurfaceStore.texture(for: surfaceID)
        else {
            transformState.reset()
            setFreeTransformMeshWarpGrid(nil)
            isFreeTransformDragging = false
            activeFreeTransformInteractionMode = nil
            freeTransformMoveLogCount = 0
            setFreeTransformPreview(.identity)
            isTransformingSelection = false
            freeTransformUsesImplicitSelection = false
            implicitFreeTransformSelectionShape = nil
            showStatus(.init(kind: .error, message: "无法访问当前图层"))
            refresh()
            return
        }

        let historyCheckpointStart = DispatchTime.now().uptimeNanoseconds
        checkpointHistoryIfPossible()
        let historyCheckpointDurationMs = Double(DispatchTime.now().uptimeNanoseconds - historyCheckpointStart) / 1_000_000
        transformLogger.debug("[apply] historyCheckpointMs=\(historyCheckpointDurationMs, privacy: .public)")
        isApplyingTransformCommit = true
        let capturedPreview = preview
        let capturedMeshWarpGrid = meshWarpGrid
        let buildStart = DispatchTime.now().uptimeNanoseconds

        transformPreviewSessionBuilder.makeSession(
            activeLayerSurfaceID: surfaceID,
            sourceTexture: texture,
            canvasSize: canvasSize,
            selectionShape: selectionShape,
            interactionBounds: effectiveTransformInteractionShape?.bounds,
            selectionRevision: selectionRevision,
            canvasContentRevision: canvasContentRevision,
            metal: bootstrap.metalContext
        ) { [weak self] session in
            guard let self else { return }

            let buildDurationMs = Double(DispatchTime.now().uptimeNanoseconds - buildStart) / 1_000_000
            self.transformLogger.debug(
                "[apply] sessionBuildMs=\(buildDurationMs, privacy: .public) success=\(session != nil, privacy: .public)"
            )

            guard let session else {
                self.isApplyingTransformCommit = false
                self.transformState.reset()
                self.setFreeTransformMeshWarpGrid(nil)
                self.isFreeTransformDragging = false
                self.activeFreeTransformInteractionMode = nil
                self.freeTransformMoveLogCount = 0
                self.transformLogger.debug("[transform] overlayHiddenDuringMove=false")
                self.setFreeTransformPreview(.identity)
                self.isTransformingSelection = false
                self.freeTransformUsesImplicitSelection = false
                self.implicitFreeTransformSelectionShape = nil
                self.refresh()
                self.showStatus(.init(kind: .error, message: "无法准备变形预览"))
                return
            }

            let compositor: TransformGPUCompositor
            do {
                compositor = try self.transformGPUCompositorResult.get()
            } catch {
                self.isApplyingTransformCommit = false
                self.transformState.reset()
                self.setFreeTransformMeshWarpGrid(nil)
                self.isFreeTransformDragging = false
                self.activeFreeTransformInteractionMode = nil
                self.freeTransformMoveLogCount = 0
                self.transformLogger.debug("[transform] overlayHiddenDuringMove=false")
                self.setFreeTransformPreview(.identity)
                self.isTransformingSelection = false
                self.freeTransformUsesImplicitSelection = false
                self.implicitFreeTransformSelectionShape = nil
                self.refresh()
                self.showStatus(.init(kind: .error, message: error.localizedDescription))
                return
            }

            let composeStart = DispatchTime.now().uptimeNanoseconds
            compositor.composeTransformedTexture(
                session: session,
                preview: capturedPreview,
                meshWarpGrid: capturedMeshWarpGrid,
                canvasSize: canvasSize,
                metal: self.bootstrap.metalContext
            ) { [weak self] targetTexture in
                guard let self else { return }

                let composeDurationMs = Double(DispatchTime.now().uptimeNanoseconds - composeStart) / 1_000_000
                self.transformLogger.debug(
                    "[apply] gpuComposeMs=\(composeDurationMs, privacy: .public) success=\(targetTexture != nil, privacy: .public)"
                )

                guard let targetTexture else {
                    self.isApplyingTransformCommit = false
                    self.transformState.reset()
                    self.setFreeTransformMeshWarpGrid(nil)
                    self.isFreeTransformDragging = false
                    self.activeFreeTransformInteractionMode = nil
                    self.freeTransformMoveLogCount = 0
                    self.transformLogger.debug("[transform] overlayHiddenDuringMove=false")
                    self.setFreeTransformPreview(.identity)
                    self.isTransformingSelection = false
                    self.freeTransformUsesImplicitSelection = false
                    self.implicitFreeTransformSelectionShape = nil
                    self.refresh()
                    self.showStatus(.init(kind: .error, message: "GPU 合成失败"))
                    return
                }

                guard
                    self.bootstrap.workspaceStore.state.document.layers.contains(where: { $0.id == layerID }),
                    self.bootstrap.layerSurfaceStore.surfaceID(for: layerID) == surfaceID
                else {
                    self.isApplyingTransformCommit = false
                    self.transformState.reset()
                    self.setFreeTransformMeshWarpGrid(nil)
                    self.isFreeTransformDragging = false
                    self.activeFreeTransformInteractionMode = nil
                    self.freeTransformMoveLogCount = 0
                    self.transformLogger.debug("[transform] overlayHiddenDuringMove=false")
                    self.setFreeTransformPreview(.identity)
                    self.isTransformingSelection = false
                    self.freeTransformUsesImplicitSelection = false
                    self.implicitFreeTransformSelectionShape = nil
                    self.refresh()
                    self.showStatus(.init(kind: .info, message: "目标图层已变化，已取消本次变形"))
                    return
                }

                self.bootstrap.layerSurfaceStore.swapTexture(for: surfaceID, with: targetTexture)

                self.isApplyingTransformCommit = false
                self.transformState.reset()
                self.setFreeTransformMeshWarpGrid(nil)
                self.isFreeTransformDragging = false
                self.activeFreeTransformInteractionMode = nil
                self.freeTransformMoveLogCount = 0
                self.transformLogger.debug("[transform] overlayHiddenDuringMove=false")
                self.setFreeTransformPreview(.identity)
                self.isTransformingSelection = false
                self.freeTransformUsesImplicitSelection = false
                self.implicitFreeTransformSelectionShape = nil

                self.bootstrap.workspaceStore.updateSelection { selection in
                    if shouldClearSelection {
                        selection.committedShape = nil
                    } else if !capturedFreeTransformUsesImplicit,
                              abs(capturedPreview.scaleX - 1) < 0.0001,
                              abs(capturedPreview.scaleY - 1) < 0.0001,
                              abs(capturedPreview.rotationRadians) < 0.0001 {
                        selection.committedShape = selection.committedShape?
                            .translatedBy(x: Double(pixelDeltaX), y: Double(pixelDeltaY))
                            .clamped(to: canvasSize)
                    }
                    selection.inProgressShape = nil
                    selection.anchorPoint = nil
                    selection.activeKind = nil
                }

                self.noteCanvasContentChanged(changedLayerIDs: [layerID])
                self.refresh(invalidatedLayerIDs: [layerID])

                let totalDurationMs = Double(DispatchTime.now().uptimeNanoseconds - applyStart) / 1_000_000
                self.transformLogger.debug("[apply] totalMs=\(totalDurationMs, privacy: .public)")
                self.showStatus(.init(
                    kind: .success,
                    message: capturedMeshWarpGrid != nil ? "已应用网格变形" : (
                        abs(capturedPreview.scaleX - 1) < 0.0001 &&
                        abs(capturedPreview.scaleY - 1) < 0.0001 &&
                        abs(capturedPreview.rotationRadians) < 0.0001
                    ) ? "已移动" : "已应用变形"
                ))
            }
        }
    }

    func cancelSelectionTransform() {
        ideationBranchActivityHandler?()
        cancelSelectionTransform(clearSelectionAfterCancel: false)
        relayIdeationOperation(.cancelSelectionTransform)
    }

    private func cancelSelectionTransform(clearSelectionAfterCancel: Bool) {
        transformState.reset()
        setFreeTransformMeshWarpGrid(nil)
        isFreeTransformDragging = false
        activeFreeTransformInteractionMode = nil
        freeTransformMoveLogCount = 0
        transformLogger.debug("[transform] overlayHiddenDuringMove=false")
        setFreeTransformPreview(.identity)
        isTransformingSelection = transformState.isActive
        let shouldClearSelection = clearSelectionAfterCancel || freeTransformUsesImplicitSelection

        if shouldClearSelection {
            bootstrap.workspaceStore.updateSelection { selection in
                selection = .empty
            }
        }
        freeTransformUsesImplicitSelection = false
        implicitFreeTransformSelectionShape = nil

        refresh()
        showStatus(.init(kind: .info, message: "已取消变形"))
    }

    private func setFreeTransformPreview(_ preview: FreeTransformPreview) {
        freeTransformPreview = preview
        transformPreviewOffset = preview.translation
        transformPreviewRevision &+= 1
    }

    var preciseFreeTransformInput: PreciseAffineInput? {
        guard workspace.toolSession.activeTool == .freeTransform,
              freeTransformToolMode == .standard,
              isTransformingSelection,
              let bounds = effectiveTransformInteractionShape?.bounds else {
            return nil
        }
        return PreciseAffineInput(
            bounds: bounds,
            preview: freeTransformPreview,
            locksAspectRatio: preciseTransformLocksAspectRatio
        )
    }

    func setPreciseFreeTransformInput(_ input: PreciseAffineInput) {
        guard workspace.toolSession.activeTool == .freeTransform,
              freeTransformToolMode == .standard,
              isTransformingSelection,
              let bounds = effectiveTransformInteractionShape?.bounds,
              let preview = input.resolvedPreview(bounds: bounds) else {
            showStatus(.init(kind: .info, message: "当前无法应用数值变形"))
            return
        }
        preciseTransformLocksAspectRatio = input.locksAspectRatio
        transformState.preview = preview
        transformState.accumulatedOffset = preview.translation
        setFreeTransformPreview(preview)
        showStatus(.init(kind: .info, message: "已更新数值变形预览"))
    }

    func flipFreeTransformHorizontally() {
        guard var input = preciseFreeTransformInput else {
            showStatus(.init(kind: .info, message: "当前无法水平翻转"))
            return
        }
        input.flipHorizontally()
        setPreciseFreeTransformInput(input)
        showStatus(.init(kind: .info, message: "已水平翻转变形预览"))
    }

    func flipFreeTransformVertically() {
        guard var input = preciseFreeTransformInput else {
            showStatus(.init(kind: .info, message: "当前无法垂直翻转"))
            return
        }
        input.flipVertically()
        setPreciseFreeTransformInput(input)
        showStatus(.init(kind: .info, message: "已垂直翻转变形预览"))
    }

    private func setFreeTransformMeshWarpGrid(_ grid: MeshWarpGrid?) {
        freeTransformMeshWarpGrid = grid
        if grid == nil {
            selectedMeshWarpControlPointIndices = []
            activeMeshWarpDragControlPointIndices = nil
        }
        transformPreviewRevision &+= 1
    }

    private func ensureFreeTransformMeshWarpGridIfNeeded() {
        guard freeTransformToolMode == .mesh else { return }
        guard freeTransformMeshWarpGrid == nil else { return }
        guard let bounds = effectiveTransformInteractionShape?.bounds else { return }

        var grid = MeshWarpGrid.regular(bounds: bounds)
        if !freeTransformPreview.isIdentity {
            grid = grid.applying(
                freeTransformAffineTransform(
                    bounds: bounds,
                    preview: freeTransformPreview
                )
            )
            transformState.preview = .identity
            transformState.accumulatedOffset = .init(x: 0, y: 0)
            setFreeTransformPreview(.identity)
        }
        transformState.meshWarpGrid = grid
        transformState.dragStartMeshWarpGrid = grid
        setFreeTransformMeshWarpGrid(grid)
    }

    private func rotatedPreview(
        for bounds: CanvasRect,
        dragStartPoint: CanvasPoint,
        currentPoint: CanvasPoint,
        startPreview: FreeTransformPreview
    ) -> FreeTransformPreview {
        let center = CanvasPoint(
            x: bounds.origin.x + (bounds.size.x / 2) + startPreview.translation.x,
            y: bounds.origin.y + (bounds.size.y / 2) + startPreview.translation.y
        )
        let startAngle = atan2(dragStartPoint.y - center.y, dragStartPoint.x - center.x)
        let currentAngle = atan2(currentPoint.y - center.y, currentPoint.x - center.x)

        return FreeTransformPreview(
            translation: startPreview.translation,
            scaleX: startPreview.scaleX,
            scaleY: startPreview.scaleY,
            rotationRadians: startPreview.rotationRadians + (currentAngle - startAngle)
        )
    }


    private func activateImplicitFreeTransformSelectionIfNeeded() {
        let currentState = bootstrap.workspaceStore.state
        guard currentState.toolSession.activeTool == .freeTransform else { return }
        guard currentState.selection.committedShape == nil else {
            freeTransformUsesImplicitSelection = false
            implicitFreeTransformSelectionShape = nil
            return
        }
        if implicitFreeTransformSelectionShape != nil {
            freeTransformUsesImplicitSelection = true
            return
        }
        guard let implicitSelection = implicitFreeTransformSelectionShape(from: currentState) else {
            freeTransformUsesImplicitSelection = false
            implicitFreeTransformSelectionShape = nil
            return
        }
        implicitFreeTransformSelectionShape = implicitSelection
        freeTransformUsesImplicitSelection = true
    }

    private func primeWholeLayerFreeTransformIdleStateIfNeeded(for state: WorkspaceState) {
        guard state.toolSession.activeTool == .freeTransform else { return }
        ensureWholeLayerInteractionBoundsAvailableIfNeeded(for: state)
        activateImplicitFreeTransformSelectionIfNeeded()
        guard effectiveTransformOperationShape != nil else {
            isTransformingSelection = transformState.isActive
            return
        }
        if !transformState.isActive {
            transformState.beginSession(at: .init(x: 0, y: 0))
            transformState.dragStartPoint = nil // 只激活，不开始拖动
            setFreeTransformPreview(.identity)
        }
        if freeTransformToolMode == .mesh {
            ensureFreeTransformMeshWarpGridIfNeeded()
        }
        isTransformingSelection = transformState.isActive
    }

    var hidesImplicitFreeTransformSelectionOverlay: Bool {
        bootstrap.workspaceStore.state.toolSession.activeTool == .freeTransform && freeTransformUsesImplicitSelection
    }

    var effectiveTransformOperationShape: SelectionShape? {
        workspace.selection.committedShape ?? implicitFreeTransformSelectionShape
    }

    var effectiveTransformInteractionShape: SelectionShape? {
        if let committed = workspace.selection.committedShape {
            return committed
        }
        guard workspace.toolSession.activeTool == .freeTransform else {
            return nil
        }
        guard let bounds = currentWholeLayerInteractionBounds(for: workspace) else {
            return nil
        }
        return SelectionShape(
            kind: .rectangle,
            bounds: bounds,
            pathPoints: []
        )
    }

    var displayedMeshWarpGrid: MeshWarpGrid? {
        guard freeTransformToolMode == .mesh else { return nil }
        if let freeTransformMeshWarpGrid {
            return freeTransformMeshWarpGrid
        }
        guard let bounds = effectiveTransformInteractionShape?.bounds else { return nil }
        return MeshWarpGrid.regular(bounds: bounds)
    }

    var transformPreparationSelectionShape: SelectionShape? {
        if let committed = workspace.selection.committedShape {
            return committed
        }
        guard workspace.toolSession.activeTool == .freeTransform else {
            return nil
        }
        return implicitFreeTransformSelectionShape(from: workspace)
    }

    private func implicitFreeTransformSelectionShape(from state: WorkspaceState) -> SelectionShape? {
        guard
            bootstrap.interactionController.activeEditableLayerID() != nil
        else {
            return nil
        }
        return SelectionShape(
            kind: .rectangle,
            bounds: CanvasRect(
                origin: .init(x: 0, y: 0),
                size: .init(
                    x: Double(state.document.canvasSize.width),
                    y: Double(state.document.canvasSize.height)
                )
            ),
            pathPoints: []
        )
    }

    private func wholeLayerInteractionBoundsKey(for state: WorkspaceState) -> WholeLayerInteractionBoundsKey? {
        guard state.toolSession.activeTool == .freeTransform else { return nil }
        guard state.selection.committedShape == nil else { return nil }
        guard
            let activeLayerID = bootstrap.interactionController.activeEditableLayerID(),
            let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: activeLayerID)
        else {
            return nil
        }
        return WholeLayerInteractionBoundsKey(
            surfaceID: surfaceID,
            canvasContentRevision: canvasContentRevision
        )
    }

    private func currentWholeLayerInteractionBounds(for state: WorkspaceState) -> CanvasRect? {
        guard let key = wholeLayerInteractionBoundsKey(for: state) else {
            return nil
        }
        guard wholeLayerInteractionBoundsCacheKey == key else {
            return nil
        }
        guard case .ready(let bounds) = wholeLayerInteractionBoundsCacheEntry else {
            return nil
        }
        return bounds
    }

    private func scheduleWholeLayerInteractionBoundsRefreshIfNeeded(for state: WorkspaceState) {
        guard let key = wholeLayerInteractionBoundsKey(for: state) else {
            wholeLayerInteractionBoundsTask?.cancel()
            wholeLayerInteractionBoundsTask = nil
            wholeLayerInteractionBoundsBuildingKey = nil
            logWholeLayerOverlayUsesInteractionBounds(false)
            return
        }

        if wholeLayerInteractionBoundsCacheKey == key {
            switch wholeLayerInteractionBoundsCacheEntry {
            case .ready(let bounds):
                transformLogger.debug(
                    "[transform] wholeLayerContentBoundsReady=true rect=\(String(describing: bounds), privacy: .public)"
                )
                logWholeLayerOverlayUsesInteractionBounds(true)
            case .empty:
                transformLogger.debug("[transform] wholeLayerContentBoundsEmpty=true")
                logWholeLayerOverlayUsesInteractionBounds(false)
            case nil:
                break
            }
            return
        }

        if wholeLayerInteractionBoundsBuildingKey == key {
            return
        }

        guard
            let texture = bootstrap.layerSurfaceStore.texture(for: key.surfaceID)
        else {
            return
        }

        wholeLayerInteractionBoundsTask?.cancel()
        wholeLayerInteractionBoundsTask = nil
        wholeLayerInteractionBoundsBuildingKey = key

        final class TextureBox: @unchecked Sendable {
            let texture: MTLTexture
            init(_ texture: MTLTexture) { self.texture = texture }
        }
        final class DetectorBox: @unchecked Sendable {
            let detector: LayerContentBoundsDetector
            init(_ detector: LayerContentBoundsDetector) { self.detector = detector }
        }
        final class CommandQueueBox: @unchecked Sendable {
            let commandQueue: MTLCommandQueue
            init(_ commandQueue: MTLCommandQueue) { self.commandQueue = commandQueue }
        }

        let textureBox = TextureBox(texture)
        let detectorBox = DetectorBox(bootstrap.layerContentBoundsDetector)
        let commandQueueBox = CommandQueueBox(bootstrap.metalContext.commandQueue)
        let task = Task.detached(priority: .utility) { () -> WholeLayerInteractionBoundsCacheEntry? in
            guard let result = try? detectorBox.detector.detect(
                texture: textureBox.texture,
                commandQueue: commandQueueBox.commandQueue
            ) else {
                return nil
            }
            return Self.wholeLayerInteractionBounds(from: result)
        }
        wholeLayerInteractionBoundsTask = task

        Task { @MainActor [weak self] in
            guard let self else { return }
            let entry = await task.value
            guard !Task.isCancelled else { return }
            guard self.wholeLayerInteractionBoundsKey(for: self.workspace) == key else { return }
            self.wholeLayerInteractionBoundsBuildingKey = nil
            self.wholeLayerInteractionBoundsTask = nil
            guard let entry else { return }
            self.wholeLayerInteractionBoundsCacheKey = key
            self.wholeLayerInteractionBoundsCacheEntry = entry
            switch entry {
            case .ready(let bounds):
                self.transformLogger.debug(
                    "[transform] wholeLayerContentBoundsReady=true rect=\(String(describing: bounds), privacy: .public)"
                )
                self.logWholeLayerOverlayUsesInteractionBounds(true)
            case .empty:
                self.transformLogger.debug("[transform] wholeLayerContentBoundsReady=false rect=nil")
                self.transformLogger.debug("[transform] wholeLayerContentBoundsEmpty=true")
                self.logWholeLayerOverlayUsesInteractionBounds(false)
            }
            self.sceneSnapshot = self.currentSceneSnapshot(for: self.workspace)
            self.syncSelectionOverlayProxy()
        }
    }

    private func ensureWholeLayerInteractionBoundsAvailableIfNeeded(for state: WorkspaceState) {
        guard let key = wholeLayerInteractionBoundsKey(for: state) else {
            return
        }
        if wholeLayerInteractionBoundsCacheKey == key,
           case .ready = wholeLayerInteractionBoundsCacheEntry {
            return
        }
        guard let texture = bootstrap.layerSurfaceStore.texture(for: key.surfaceID),
              let detected = try? bootstrap.layerContentBoundsDetector.detect(
                texture: texture,
                commandQueue: bootstrap.metalContext.commandQueue
              ) else {
            return
        }

        wholeLayerInteractionBoundsTask?.cancel()
        wholeLayerInteractionBoundsTask = nil
        wholeLayerInteractionBoundsBuildingKey = nil

        let entry = Self.wholeLayerInteractionBounds(from: detected)
        wholeLayerInteractionBoundsCacheKey = key
        wholeLayerInteractionBoundsCacheEntry = entry
        switch entry {
        case .ready(let bounds):
            transformLogger.debug(
                "[transform] wholeLayerContentBoundsSyncReady=true rect=\(String(describing: bounds), privacy: .public)"
            )
            logWholeLayerOverlayUsesInteractionBounds(true)
        case .empty:
            transformLogger.debug("[transform] wholeLayerContentBoundsSyncReady=false rect=nil")
            logWholeLayerOverlayUsesInteractionBounds(false)
        }
    }

    nonisolated private static func wholeLayerInteractionBounds(
        from result: LayerContentBoundsResult
    ) -> WholeLayerInteractionBoundsCacheEntry {
        switch result {
        case .empty:
            return .empty
        case .bounds(let bounds):
            return .ready(bounds)
        }
    }

    private func logWholeLayerOverlayUsesInteractionBounds(_ usesInteractionBounds: Bool) {
        guard workspace.toolSession.activeTool == .freeTransform else { return }
        guard workspace.selection.committedShape == nil else { return }
        guard lastLoggedWholeLayerOverlayUsesInteractionBounds != usesInteractionBounds else { return }
        lastLoggedWholeLayerOverlayUsesInteractionBounds = usesInteractionBounds
        transformLogger.debug(
            "[transform] wholeLayerUsesInteractionBoundsForOverlay=\(usesInteractionBounds, privacy: .public)"
        )
    }

    func copyPixels() {
        guard !isTransformingSelection else {
            showStatus(.init(kind: .info, message: "请先应用或取消变形"))
            return
        }

        _ = flushBrushEditingBoundary(reason: "copyPixels")

        guard let (_, texture) = activeLayerTextureForPixelClipboard(requireEditableLayer: false) else {
            return
        }

        do {
            guard let payload = try makePixelClipboardPayload(
                from: texture,
                selectionShape: workspace.selection.committedShape,
                canvasSize: workspace.document.canvasSize
            ) else {
                showStatus(.init(kind: .info, message: "当前图层没有可复制的像素"))
                return
            }

            bootstrap.pixelClipboardController.store(payload)
            showStatus(.init(kind: .success, message: "已复制像素"))
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func copyMergedPixels() {
        guard !isTransformingSelection else {
            showStatus(.init(kind: .info, message: "请先应用或取消变形"))
            return
        }

        _ = flushBrushEditingBoundary(reason: "copyMergedPixels")
        guard workspace.document.layers.contains(where: { $0.isVisible && $0.opacity > 0 }) else {
            showStatus(.init(kind: .info, message: "当前没有可合并拷贝的可见图层"))
            return
        }

        do {
            let compositeTexture = try makeVisibleCompositeTexture()
            guard let payload = try makePixelClipboardPayload(
                from: compositeTexture,
                selectionShape: workspace.selection.committedShape,
                canvasSize: workspace.document.canvasSize
            ) else {
                showStatus(.init(kind: .info, message: "选取范围内没有可复制的像素"))
                return
            }

            bootstrap.pixelClipboardController.store(payload)
            showStatus(
                .init(
                    kind: .success,
                    message: workspace.selection.committedShape == nil
                        ? "已合并拷贝所有可见图层"
                        : "已合并拷贝选区内的可见图层"
                )
            )
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func cutPixels() {
        guard !isTransformingSelection else {
            showStatus(.init(kind: .info, message: "请先应用或取消变形"))
            return
        }

        _ = flushBrushEditingBoundary(reason: "cutPixels")

        guard let (layerID, texture) = activeLayerTextureForPixelClipboard(requireEditableLayer: true) else {
            return
        }

        do {
            guard let payload = try makePixelClipboardPayload(
                from: texture,
                selectionShape: workspace.selection.committedShape,
                canvasSize: workspace.document.canvasSize
            ) else {
                showStatus(.init(kind: .info, message: "当前图层没有可剪切的像素"))
                return
            }

            bootstrap.pixelClipboardController.store(payload)

            if let selectionShape = workspace.selection.committedShape {
                _ = applyPixelOperation(
                    to: selectionShape,
                    operation: .clear,
                    historyOperationKind: "selection.cut",
                    successMessage: "已剪切像素"
                )
                return
            }

            checkpointHistoryIfPossible(
                operationKind: "pixel.cut",
                candidateChangedLayerIDs: [layerID],
                additionalOperationKinds: ["pixelClipboard"],
                captureMode: .inPlaceChangedLayers([layerID])
            )

            let clearedSnapshot = LayerTextureSnapshot(
                width: payload.snapshot.width,
                height: payload.snapshot.height,
                bytesPerRow: payload.snapshot.bytesPerRow,
                pixelData: Data(count: payload.snapshot.bytesPerRow * payload.snapshot.height)
            )
            try bootstrap.textureSerializer.restore(
                snapshot: clearedSnapshot,
                into: texture,
                destinationX: payload.originX,
                destinationY: payload.originY
            )
            refresh(invalidatedLayerIDs: [layerID])
            noteCanvasContentChanged(changedLayerIDs: [layerID])
            recordDrawingActivityIfNeeded()
            showStatus(.init(kind: .success, message: "已剪切像素"))
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func pastePixels() {
        guard !isTransformingSelection else {
            showStatus(.init(kind: .info, message: "请先应用或取消变形"))
            return
        }

        _ = flushBrushEditingBoundary(reason: "pastePixels")

        guard let payload = bootstrap.pixelClipboardController.preferredPayload() else {
            showStatus(.init(kind: .info, message: "剪贴板中没有可粘贴的像素"))
            return
        }

        _ = insertPixelPayloadAsNewLayer(
            payload,
            named: "粘贴图层",
            historyOperationKind: "pixel.paste",
            successMessage: "已粘贴为新图层",
            outsideCanvasMessage: "粘贴内容超出当前画布",
            additionalHistoryOperationKinds: ["pixelClipboard"]
        )
    }

    @discardableResult
    func importDroppedCanvasImage(
        from url: URL,
        centeredAt center: CanvasPoint
    ) -> Bool {
        guard let image = NSImage(contentsOf: url) else {
            showStatus(.init(kind: .error, message: "无法读取拖入的图片"))
            return false
        }
        let fileName = url.deletingPathExtension().lastPathComponent
        return importDroppedCanvasImage(
            from: image,
            centeredAt: center,
            layerName: fileName.isEmpty ? "导入图像" : fileName
        )
    }

    @discardableResult
    func importDroppedCanvasImage(
        from image: NSImage,
        centeredAt center: CanvasPoint,
        layerName: String = "导入图像"
    ) -> Bool {
        guard !isTransformingSelection else {
            showStatus(.init(kind: .info, message: "请先应用或取消变形"))
            return false
        }

        _ = flushBrushEditingBoundary(reason: "importDroppedCanvasImage")

        guard let payload = bootstrap.pixelClipboardController.canvasImportPayload(
            from: image,
            fittingWithin: workspace.document.canvasSize,
            centeredAt: center
        ) else {
            showStatus(.init(kind: .error, message: "无法读取拖入的图片"))
            return false
        }

        return insertPixelPayloadAsNewLayer(
            payload,
            named: layerName,
            historyOperationKind: "pixel.importDroppedImage",
            successMessage: "已将图片导入为新图层",
            outsideCanvasMessage: "拖入位置在画布外"
        )
    }

    @discardableResult
    private func insertPixelPayloadAsNewLayer(
        _ payload: PixelClipboardPayload,
        named layerName: String,
        historyOperationKind: String,
        successMessage: String,
        outsideCanvasMessage: String,
        additionalHistoryOperationKinds: [String] = []
    ) -> Bool {
        guard let placement = clippedPlacement(
            for: payload,
            destinationCanvasSize: workspace.document.canvasSize
        ) else {
            showStatus(.init(kind: .info, message: outsideCanvasMessage))
            return false
        }
        guard ensureDocumentResourceBudget(
            additionalPaintLayers: 1,
            action: "导入为新图层"
        ) else { return false }

        do {
            guard checkpointHistoryIfPossible(
                operationKind: historyOperationKind,
                topologyOperation: true,
                additionalOperationKinds: additionalHistoryOperationKinds,
                captureMode: .topologyDelta(changedLayerIDs: [])
            ) else { return false }

            let insertionIndex = min(
                (workspace.document.layers.firstIndex(where: { $0.id == workspace.document.activeLayerID }) ?? (workspace.document.layers.count - 1)) + 1,
                workspace.document.layers.count
            )

            var createdLayerID: LayerID?
            bootstrap.workspaceStore.updateDocument { document in
                createdLayerID = document.addLayer(named: layerName).id
                if let createdLayerID {
                    _ = document.moveLayer(createdLayerID, toIndex: insertionIndex)
                }
            }

            let state = bootstrap.workspaceStore.state
            bootstrap.layerSurfaceStore.prepareTextures(
                for: state.document,
                metal: bootstrap.metalContext
            )

            guard
                let createdLayerID,
                let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: createdLayerID),
                let texture = bootstrap.layerSurfaceStore.texture(for: surfaceID)
            else {
                throw CocoaError(.fileWriteUnknown)
            }

            try bootstrap.textureSerializer.restore(
                snapshot: placement.snapshot,
                into: texture,
                destinationX: placement.destinationX,
                destinationY: placement.destinationY
            )

            refresh(invalidatedLayerIDs: [createdLayerID])
            noteCanvasContentChanged(changedLayerIDs: [createdLayerID])
            recordDrawingActivityIfNeeded()
            showStatus(.init(kind: .success, message: successMessage))
            return true
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
            return false
        }
    }

    private func activeLayerTextureForPixelClipboard(
        requireEditableLayer: Bool
    ) -> (layerID: LayerID, texture: MTLTexture)? {
        let layerID: LayerID
        if requireEditableLayer {
            guard let editableLayerID = bootstrap.interactionController.activeEditableLayerID() else {
                showStatus(.init(kind: .info, message: "当前图层已锁定"))
                return nil
            }
            layerID = editableLayerID
        } else {
            layerID = workspace.document.activeLayerID
        }

        guard
            let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: layerID),
            let texture = bootstrap.layerSurfaceStore.texture(for: surfaceID)
        else {
            showStatus(.init(kind: .error, message: "无法访问当前图层"))
            return nil
        }

        return (layerID, texture)
    }

    private func makePixelClipboardPayload(
        from texture: MTLTexture,
        selectionShape: SelectionShape?,
        canvasSize: CanvasSize
    ) throws -> PixelClipboardPayload? {
        if let selectionShape {
            let clampedSelection = selectionShape.clamped(to: canvasSize)
            let minX = max(Int(clampedSelection.bounds.minX.rounded(.down)), 0)
            let minY = max(Int(clampedSelection.bounds.minY.rounded(.down)), 0)
            let maxX = min(Int(clampedSelection.bounds.maxX.rounded(.up)), texture.width)
            let maxY = min(Int(clampedSelection.bounds.maxY.rounded(.up)), texture.height)
            guard minX < maxX, minY < maxY else {
                return nil
            }

            let selectionMask = selectionMaskRegion(
                for: clampedSelection,
                canvasSize: canvasSize,
                originX: minX,
                originY: minY,
                width: maxX - minX,
                height: maxY - minY
            )
            let boundedSnapshot = try bootstrap.textureSerializer.snapshot(
                texture: texture,
                originX: minX,
                originY: minY,
                width: maxX - minX,
                height: maxY - minY
            )
            let maskedSnapshot = Self.maskedSnapshot(
                boundedSnapshot,
                using: selectionMask
            )
            guard let trimmedSnapshot = Self.trimmedSnapshot(maskedSnapshot) else {
                return nil
            }

            return PixelClipboardPayload(
                snapshot: trimmedSnapshot.snapshot,
                originX: minX + trimmedSnapshot.offsetX,
                originY: minY + trimmedSnapshot.offsetY,
                sourceCanvasSize: canvasSize
            )
        }

        let fullSnapshot = try bootstrap.textureSerializer.snapshot(texture: texture)
        guard let opaqueBounds = Self.opaqueBounds(in: fullSnapshot) else {
            return nil
        }

        return PixelClipboardPayload(
            snapshot: Self.cropSnapshot(
                fullSnapshot,
                originX: opaqueBounds.originX,
                originY: opaqueBounds.originY,
                width: opaqueBounds.width,
                height: opaqueBounds.height
            ),
            originX: opaqueBounds.originX,
            originY: opaqueBounds.originY,
            sourceCanvasSize: canvasSize
        )
    }

    private func clippedPlacement(
        for payload: PixelClipboardPayload,
        destinationCanvasSize: CanvasSize
    ) -> (snapshot: LayerTextureSnapshot, destinationX: Int, destinationY: Int)? {
        let destinationMinX = max(0, payload.originX)
        let destinationMinY = max(0, payload.originY)
        let destinationMaxX = min(destinationCanvasSize.width, payload.originX + payload.snapshot.width)
        let destinationMaxY = min(destinationCanvasSize.height, payload.originY + payload.snapshot.height)

        guard destinationMinX < destinationMaxX, destinationMinY < destinationMaxY else {
            return nil
        }

        let sourceOffsetX = destinationMinX - payload.originX
        let sourceOffsetY = destinationMinY - payload.originY
        let clippedWidth = destinationMaxX - destinationMinX
        let clippedHeight = destinationMaxY - destinationMinY

        return (
            snapshot: Self.cropSnapshot(
                payload.snapshot,
                originX: sourceOffsetX,
                originY: sourceOffsetY,
                width: clippedWidth,
                height: clippedHeight
            ),
            destinationX: destinationMinX,
            destinationY: destinationMinY
        )
    }

    private static func maskedSnapshot(
        _ snapshot: LayerTextureSnapshot,
        using selectionMaskRegion: SelectionMaskRegion
    ) -> LayerTextureSnapshot {
        guard
            snapshot.width == selectionMaskRegion.width,
            snapshot.height == selectionMaskRegion.height
        else {
            return snapshot
        }

        var bytes = [UInt8](snapshot.pixelData)
        let bytesPerPixel = 4
        selectionMaskRegion.withAlphaBytes { maskBytes in
            guard let maskBaseAddress = maskBytes.baseAddress else { return }

            for localY in 0..<snapshot.height {
                let maskRow = localY * selectionMaskRegion.width
                let byteRow = localY * snapshot.bytesPerRow
                for localX in 0..<snapshot.width {
                    let maskAlpha = maskBaseAddress[maskRow + localX]
                    let index = byteRow + (localX * bytesPerPixel)

                    switch maskAlpha {
                    case 0:
                        bytes[index] = 0
                        bytes[index + 1] = 0
                        bytes[index + 2] = 0
                        bytes[index + 3] = 0
                    case 255:
                        continue
                    default:
                        let scale = Int(maskAlpha)
                        for channel in 0..<bytesPerPixel {
                            bytes[index + channel] = UInt8((Int(bytes[index + channel]) * scale + 127) / 255)
                        }
                    }
                }
            }
        }

        return LayerTextureSnapshot(
            width: snapshot.width,
            height: snapshot.height,
            bytesPerRow: snapshot.bytesPerRow,
            pixelData: Data(bytes)
        )
    }

    private static func maskCompositedSnapshot(
        base: LayerTextureSnapshot,
        overlay: LayerTextureSnapshot,
        using selectionMaskRegion: SelectionMaskRegion
    ) -> LayerTextureSnapshot {
        guard
            base.width == overlay.width,
            base.height == overlay.height,
            base.bytesPerRow == overlay.bytesPerRow,
            base.width == selectionMaskRegion.width,
            base.height == selectionMaskRegion.height
        else {
            return overlay
        }

        let bytesPerPixel = 4
        var output = [UInt8](base.pixelData)
        let overlayBytes = [UInt8](overlay.pixelData)

        selectionMaskRegion.withAlphaBytes { maskBytes in
            guard let maskBaseAddress = maskBytes.baseAddress else { return }

            for y in 0..<base.height {
                let maskRow = y * selectionMaskRegion.width
                let byteRow = y * base.bytesPerRow
                for x in 0..<base.width {
                    let maskAlpha = Int(maskBaseAddress[maskRow + x])
                    guard maskAlpha > 0 else { continue }

                    let index = byteRow + (x * bytesPerPixel)
                    if maskAlpha == 255 {
                        output[index] = overlayBytes[index]
                        output[index + 1] = overlayBytes[index + 1]
                        output[index + 2] = overlayBytes[index + 2]
                        output[index + 3] = overlayBytes[index + 3]
                        continue
                    }

                    let inverse = 255 - maskAlpha
                    for channel in 0..<bytesPerPixel {
                        let baseValue = Int(output[index + channel])
                        let overlayValue = Int(overlayBytes[index + channel])
                        output[index + channel] = UInt8(
                            (baseValue * inverse + overlayValue * maskAlpha + 127) / 255
                        )
                    }
                }
            }
        }

        return LayerTextureSnapshot(
            width: base.width,
            height: base.height,
            bytesPerRow: base.bytesPerRow,
            pixelData: Data(output)
        )
    }

    private static func trimmedSnapshot(
        _ snapshot: LayerTextureSnapshot
    ) -> (snapshot: LayerTextureSnapshot, offsetX: Int, offsetY: Int)? {
        guard let bounds = opaqueBounds(in: snapshot) else {
            return nil
        }

        return (
            snapshot: cropSnapshot(
                snapshot,
                originX: bounds.originX,
                originY: bounds.originY,
                width: bounds.width,
                height: bounds.height
            ),
            offsetX: bounds.originX,
            offsetY: bounds.originY
        )
    }

    private static func opaqueBounds(
        in snapshot: LayerTextureSnapshot
    ) -> (originX: Int, originY: Int, width: Int, height: Int)? {
        let width = snapshot.width
        let height = snapshot.height
        guard width > 0, height > 0 else {
            return nil
        }

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1

        snapshot.pixelData.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for y in 0..<height {
                let rowStart = y * snapshot.bytesPerRow
                for x in 0..<width {
                    let alphaIndex = rowStart + (x * 4) + 3
                    guard bytes[alphaIndex] > 0 else { continue }
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }

        guard maxX >= minX, maxY >= minY else {
            return nil
        }

        return (
            originX: minX,
            originY: minY,
            width: (maxX - minX) + 1,
            height: (maxY - minY) + 1
        )
    }

    private static func cropSnapshot(
        _ snapshot: LayerTextureSnapshot,
        originX: Int,
        originY: Int,
        width: Int,
        height: Int
    ) -> LayerTextureSnapshot {
        let bytesPerPixel = 4
        let croppedBytesPerRow = width * bytesPerPixel
        var croppedBytes = [UInt8](repeating: 0, count: croppedBytesPerRow * height)

        snapshot.pixelData.withUnsafeBytes { rawBuffer in
            let sourceBytes = rawBuffer.bindMemory(to: UInt8.self)
            for localY in 0..<height {
                let sourceOffset = (originY + localY) * snapshot.bytesPerRow + (originX * bytesPerPixel)
                let destinationOffset = localY * croppedBytesPerRow
                for localX in 0..<croppedBytesPerRow {
                    croppedBytes[destinationOffset + localX] = sourceBytes[sourceOffset + localX]
                }
            }
        }

        return LayerTextureSnapshot(
            width: width,
            height: height,
            bytesPerRow: croppedBytesPerRow,
            pixelData: Data(croppedBytes)
        )
    }

    func deleteSelectionContents() {
        guard let selectionShape = workspace.selection.committedShape else {
            showStatus(.init(kind: .info, message: "没有可删除的选区"))
            return
        }
        _ = applyPixelOperation(
            to: selectionShape,
            operation: .clear,
            historyOperationKind: "selection.erase",
            successMessage: "已删除选区内容"
        )
    }

    func deleteSelectionOrActiveLayer() {
        if workspace.selection.committedShape != nil {
            deleteSelectionContents()
        } else {
            showStatus(.init(kind: .info, message: "没有选区；请在图层面板中明确删除图层"))
        }
    }

    func fillSelectionContents() {
        guard let selectionShape = workspace.selection.committedShape else {
            showStatus(.init(kind: .info, message: "没有可填充的选区"))
            return
        }
        _ = applyPixelOperation(
            to: selectionShape,
            operation: .fill(premultipliedPixel(from: workspace.toolSession.selectedColor)),
            historyOperationKind: "selection.fill",
            successMessage: "已填充选区"
        )
    }

    func fillLassoContents() {
        guard let selectionShape = workspace.selection.committedShape else {
            showStatus(.init(kind: .info, message: "没有可填充的选区"))
            return
        }

        guard selectionShape.containsLassoContent else {
            showStatus(.init(kind: .info, message: "当前选区不是套索"))
            return
        }

        _ = applyLassoFill(
            to: selectionShape,
            historyOperationKind: "lasso.fill",
            successMessage: "已填充选区"
        )
    }

    private func fillCurrentSelectionWithForegroundColorShortcut() {
        guard let selectionShape = workspace.selection.committedShape else {
            showStatus(.init(kind: .info, message: "没有可填充的选区"))
            return
        }

        _ = applyPixelOperation(
            to: selectionShape,
            operation: .fill(premultipliedPixel(from: workspace.toolSession.selectedColor)),
            historyOperationKind: "selection.fill",
            successMessage: "已填充选区"
        )
    }

    private func fillLegalPixelsWithForegroundColorShortcut() {
        if workspace.selection.committedShape != nil {
            fillCurrentSelectionWithForegroundColorShortcut()
            return
        }

        fillActiveLayerOpaquePixelsWithForegroundColor()
    }

    private func fillActiveLayerOpaquePixelsWithForegroundColor() {
        guard let layerID = bootstrap.interactionController.activeEditableLayerID() else {
            showStatus(.init(kind: .info, message: "当前图层已锁定"))
            return
        }

        if bootstrap.layerSurfaceStore.isKnownTransparent(layerID: layerID) {
            showStatus(.init(kind: .info, message: "当前图层没有可填充的不透明像素"))
            return
        }

        let canvasSize = workspace.document.canvasSize
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            showStatus(.init(kind: .info, message: "画布为空"))
            return
        }

        let fullCanvasSelection = SelectionShape(
            kind: .rectangle,
            bounds: CanvasRect(
                origin: .init(x: 0, y: 0),
                size: .init(x: Double(canvasSize.width), y: Double(canvasSize.height))
            ),
            pathPoints: []
        )
        _ = applyPixelOperation(
            to: fullCanvasSelection,
            operation: .fill(premultipliedPixel(from: workspace.toolSession.selectedColor)),
            historyOperationKind: "layerOpaque.fill",
            successMessage: "已填充当前图层不透明像素",
            preservesExistingAlpha: true
        )
    }

    func applyGeneratorToActiveLayer(clearSelectionAfterApply: Bool = false) {
        guard let layerID = bootstrap.interactionController.activeEditableLayerID() else {
            showStatus(.init(kind: .info, message: "当前图层已锁定"))
            return
        }

        guard
            let texture = bootstrap.layerSurfaceStore.surfaceID(for: layerID).flatMap(bootstrap.layerSurfaceStore.texture(for:))
        else {
            showStatus(.init(kind: .error, message: "无法访问当前图层"))
            return
        }

        let generator = workspace.generator
        let canvasSize = CanvasSize(width: texture.width, height: texture.height)
        let targetShape = workspace.selection.committedShape?.clamped(to: canvasSize)
        let selectedColor = workspace.toolSession.selectedColor
        let generatorColor = resolvedGeneratorColor(from: selectedColor)
        do {
            let bounds = targetShape?.bounds ?? CanvasRect(
                origin: CanvasPoint(x: 0, y: 0),
                size: CanvasPoint(
                    x: Double(texture.width),
                    y: Double(texture.height)
                )
            )

            let minX = max(Int(bounds.minX.rounded(.down)), 0)
            let minY = max(Int(bounds.minY.rounded(.down)), 0)
            let maxX = min(Int(bounds.maxX.rounded(.up)), texture.width)
            let maxY = min(Int(bounds.maxY.rounded(.up)), texture.height)

            guard minX < maxX, minY < maxY else {
                showStatus(.init(kind: .info, message: "生成区域为空"))
                return
            }

            let snapshot = try bootstrap.textureSerializer.snapshot(
                texture: texture,
                originX: minX,
                originY: minY,
                width: maxX - minX,
                height: maxY - minY
            )
            cancelActiveRasterizationTask()
            showStatus(.init(kind: .info, message: "正在生成\(generator.kind.displayName)…"))
            activeRasterizationTask = Task { [weak self] in
                let result = await Task.detached(priority: .userInitiated) {
                    var bytes = [UInt8](snapshot.pixelData)
                    let summary = GeneratorRegionRasterizer.apply(
                        settings: generator,
                        color: generatorColor,
                        targetShape: targetShape,
                        originX: minX,
                        originY: minY,
                        width: snapshot.width,
                        height: snapshot.height,
                        bytesPerRow: snapshot.bytesPerRow,
                        bytes: &bytes
                    )
                    return (summary, Data(bytes))
                }.value

                guard let self, !Task.isCancelled else { return }
                self.activeRasterizationTask = nil
                guard result.0.touchedPixelCount > 0 else {
                    self.showStatus(.init(kind: .info, message: "生成区域内没有可绘制像素"))
                    return
                }
                guard self.bootstrap.workspaceStore.state.document.activeLayerID == layerID,
                      self.bootstrap.workspaceStore.state.selection.committedShape == targetShape
                else {
                    self.showStatus(.init(kind: .info, message: "画布状态已变化，已取消过期生成结果"))
                    return
                }

                self.checkpointHistoryIfPossible(
                    operationKind: "generator.\(generator.kind.rawValue)",
                    candidateChangedLayerIDs: [layerID],
                    captureMode: .inPlaceChangedLayers([layerID])
                )
                let updatedSnapshot = LayerTextureSnapshot(
                    width: snapshot.width,
                    height: snapshot.height,
                    bytesPerRow: snapshot.bytesPerRow,
                    pixelData: result.1
                )
                do {
                    try self.bootstrap.textureSerializer.restore(
                        snapshot: updatedSnapshot,
                        into: texture,
                        destinationX: minX,
                        destinationY: minY
                    )
                } catch {
                    self.showStatus(.init(kind: .error, message: error.localizedDescription))
                    return
                }
                if clearSelectionAfterApply {
                    self.bootstrap.workspaceStore.updateSelection { selection in
                        selection.anchorPoint = nil
                        selection.activeKind = nil
                        selection.committedShape = nil
                        selection.inProgressShape = nil
                    }
                    self.isGeneratorStrokeModeEnabled = false
                    self.isGeneratorRegionSelectionArmed = true
                    self.bootstrap.workspaceStore.updateToolSession { session in
                        session.activeTool = .lassoSelection
                    }
                }
                self.refresh(invalidatedLayerIDs: [layerID])
                self.noteCanvasContentChanged(changedLayerIDs: [layerID])
                self.showStatus(.init(
                    kind: .success,
                    message: clearSelectionAfterApply
                        ? "已应用\(generator.kind.displayName)，可继续圈选下一区域"
                        : "已应用\(generator.kind.displayName)生成器"
                ))
            }
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    private func applyLinearGradient(geometry: LinearGradientGeometry) {
        guard let layerID = bootstrap.interactionController.activeEditableLayerID() else {
            showStatus(.init(kind: .info, message: "当前图层已锁定"))
            return
        }

        guard
            let texture = bootstrap.layerSurfaceStore.surfaceID(for: layerID).flatMap(bootstrap.layerSurfaceStore.texture(for:))
        else {
            showStatus(.init(kind: .error, message: "无法访问当前图层"))
            return
        }

        let pointA = geometry.pointA
        let pointB = geometry.pointB
        let pointC = geometry.pointC
        let vectorU = CanvasPoint(x: pointB.x - pointA.x, y: pointB.y - pointA.y)
        let vectorV = CanvasPoint(x: pointC.x - pointB.x, y: pointC.y - pointB.y)
        let determinant = (vectorU.x * vectorV.y) - (vectorU.y * vectorV.x)
        guard abs(determinant) > 0.0001 else {
            showStatus(.init(kind: .info, message: "渐变长度和宽度不能共线"))
            return
        }

        checkpointHistoryIfPossible(
            operationKind: "linearGradient.apply",
            candidateChangedLayerIDs: [layerID],
            captureMode: .inPlaceChangedLayers([layerID])
        )

        let pointD = geometry.pointD
        let minCanvasX = min(min(pointA.x, pointB.x), min(pointC.x, pointD.x))
        let minCanvasY = min(min(pointA.y, pointB.y), min(pointC.y, pointD.y))
        let maxCanvasX = max(max(pointA.x, pointB.x), max(pointC.x, pointD.x))
        let maxCanvasY = max(max(pointA.y, pointB.y), max(pointC.y, pointD.y))
        let minX = max(Int(floor(minCanvasX)), 0)
        let minY = max(Int(floor(minCanvasY)), 0)
        let maxX = min(Int(ceil(maxCanvasX)), texture.width)
        let maxY = min(Int(ceil(maxCanvasY)), texture.height)

        guard minX < maxX, minY < maxY else {
            showStatus(.init(kind: .info, message: "渐变区域为空"))
            return
        }

        guard let commandBuffer = bootstrap.metalContext.commandQueue.makeCommandBuffer() else {
            showStatus(.init(kind: .error, message: "无法创建渐变命令缓冲"))
            return
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = texture
        renderPassDescriptor.colorAttachments[0].loadAction = .load
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        let applyStart = DispatchTime.now().uptimeNanoseconds
        let alphaLockTexture = makeAlphaLockTextureCopyIfNeeded(for: layerID, sourceTexture: texture)
        guard alphaLockTexture != nil || !layerTransparentPixelLockEnabled(layerID) else {
            showStatus(.init(kind: .error, message: "无法创建锁定透明像素遮罩"))
            return
        }
        bootstrap.linearGradientRenderer.encode(
            into: renderPassDescriptor,
            commandBuffer: commandBuffer,
            canvasSize: workspace.document.canvasSize,
            pointA: pointA,
            pointB: pointB,
            pointC: pointC,
            transitionMidpoint: Float(geometry.transitionMidpoint),
            color: gradientPreviewColor,
            settings: gradientRenderSettings,
            paintJitterAmount: displayedPaintJitterAmount,
            paintContrastAmount: displayedPaintContrastAmount,
            distortionAmount: workspace.toolSession.brush.jitterAmount,
            selectionShape: workspace.selection.committedShape,
            alphaLockTexture: alphaLockTexture
        )

        commitGradientApplication(
            commandBuffer,
            layerID: layerID,
            resetInteractionState: { self.linearGradientState = .init() },
            successMessage: "已应用直线渐变",
            failureMessage: "无法完成直线渐变提交",
            logTool: "linear",
            startedAt: applyStart
        )
    }

    func applyStraightLine(
        pointA: CanvasPoint,
        pointB: CanvasPoint,
        paintVariationSeed: UInt32? = nil
    ) -> Bool {
        guard let layerID = bootstrap.interactionController.activeEditableLayerID() else {
            showStatus(.init(kind: .info, message: "当前图层已锁定"))
            return false
        }

        checkpointHistoryIfPossible()
        let resolvedToolSession = resolvedToolSessionForCanvasStrokes()

        let stroke = StrokeDescriptor(
            tool: .brush,
            color: resolvedToolSession.selectedColor,
            brush: resolvedToolSession.brush,
            points: [
                StrokePoint(x: pointA.x, y: pointA.y, pressure: 1),
                StrokePoint(x: pointB.x, y: pointB.y, pressure: 1)
            ],
            selectionShape: workspace.selection.committedShape,
            alphaLockEnabled: layerTransparentPixelLockEnabled(layerID),
            paintVariationSeed: paintVariationSeed ?? makePaintVariationSeed(),
            pigmentPalette: resolvedToolSession.activeOilPaintPalette
        )

        bootstrap.strokeEngine.beginStrokeIfNeeded(
            toolSession: ToolSessionState(
                activeTool: .brush,
                brush: resolvedToolSession.brush,
                selectedColor: resolvedToolSession.selectedColor
            ),
            layerID: layerID
        )
        bootstrap.strokeEngine.applyStroke(stroke, to: layerID)
        bootstrap.strokeEngine.endStroke()
        refresh(invalidatedLayerIDs: [layerID])
        noteCanvasContentChanged(changedLayerIDs: [layerID])
        recordDrawingActivityIfNeeded()
        showStatus(.init(kind: .success, message: "已应用直线"))
        return true
    }

    private func applySectorGradient(geometry: SectorGradientGeometry) {
        guard let layerID = bootstrap.interactionController.activeEditableLayerID() else {
            showStatus(.init(kind: .info, message: "当前图层已锁定"))
            return
        }

        guard
            let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: layerID),
            let texture = bootstrap.layerSurfaceStore.texture(for: surfaceID)
        else {
            showStatus(.init(kind: .error, message: "无法访问当前图层"))
            return
        }

        guard geometry.maxRadius > 1, geometry.pathPoints.count >= 3 else {
            showStatus(.init(kind: .info, message: "区域太小，无法生成扇形渐变"))
            return
        }

        checkpointHistoryIfPossible(
            operationKind: "sectorGradient.apply",
            candidateChangedLayerIDs: [layerID],
            captureMode: .inPlaceChangedLayers([layerID])
        )

        let alphaLockTexture = makeAlphaLockTextureCopyIfNeeded(for: layerID, sourceTexture: texture)
        guard alphaLockTexture != nil || !layerTransparentPixelLockEnabled(layerID) else {
            showStatus(.init(kind: .error, message: "无法创建锁定透明像素遮罩"))
            return
        }

        guard let commandBuffer = bootstrap.metalContext.commandQueue.makeCommandBuffer() else {
            showStatus(.init(kind: .error, message: "无法创建渐变命令缓冲"))
            return
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = texture
        renderPassDescriptor.colorAttachments[0].loadAction = .load
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        bootstrap.sectorGradientRenderer.encode(
            into: renderPassDescriptor,
            commandBuffer: commandBuffer,
            canvasSize: workspace.document.canvasSize,
            center: geometry.center,
            pathPoints: geometry.pathPoints,
            maxRadius: geometry.maxRadius,
            color: gradientPreviewColor,
            settings: gradientRenderSettings,
            paintJitterAmount: displayedPaintJitterAmount,
            paintContrastAmount: displayedPaintContrastAmount,
            distortionAmount: workspace.toolSession.brush.jitterAmount,
            maskQuality: .commit,
            selectionShape: workspace.selection.committedShape,
            alphaLockTexture: alphaLockTexture
        )

        commitGradientApplication(
            commandBuffer,
            layerID: layerID,
            resetInteractionState: { self.sectorGradientState = .init() },
            successMessage: "已应用扇形渐变",
            failureMessage: "无法完成扇形渐变提交"
        )
    }

    func eraseLassoContents() {
        guard let selectionShape = workspace.selection.committedShape else {
            showStatus(.init(kind: .info, message: "没有可擦除的选区"))
            return
        }

        guard selectionShape.containsLassoContent else {
            showStatus(.init(kind: .info, message: "当前选区不是套索"))
            return
        }

        _ = applyPixelOperation(
            to: selectionShape,
            operation: .clear,
            historyOperationKind: "lasso.erase",
            successMessage: "已删除选区内容"
        )
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        let normalizedModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53, isBucketFillInProgress {
            cancelBucketFill()
            return true
        }

        // The momentary HUD must stay on the shortest possible event path. In particular,
        // do not make it wait behind tool/session-specific keyboard dispatch.
        if shortcutSettings.quickColorPickerShortcut.matchesKeyDown(event) {
            armQuickColorPickerShortcutIfNeeded()
            return true
        }

        if toggleSmartSelectionDisplayModeIfPossible(event) {
            return true
        }

        if applySmartSelectionThresholdShortcut(event) {
            return true
        }

        if workspace.toolSession.activeTool == .perspective,
           normalizedModifiers.isEmpty {
            if event.keyCode == 51 || event.keyCode == 117 {
                guard selectedPerspectiveAnchorID != nil else { return false }
                deleteSelectedPerspectiveGuideAnchor()
                return true
            }
            if event.keyCode == 53 {
                if perspectiveGuideMatchState.isActive {
                    stopPerspectiveGuideMatch()
                    return true
                }
                selectedPerspectiveAnchorID = nil
                endPerspectiveGuideInteraction()
                return true
            }
        }

        if workspace.toolSession.activeTool == .blockReference,
           handleBlockReferenceKeyDown(event) {
            return true
        }

        if workspace.toolSession.activeTool == .canvasCrop {
            if event.keyCode == 36 || event.keyCode == 76 {
                applyCanvasCrop()
                return true
            }
            if event.keyCode == 53 {
                cancelCanvasCrop()
                return true
            }
        }

        if workspace.toolSession.activeTool == .brightnessAdjust {
            switch brightnessAdjustmentEditorMode {
            case .colorParameters:
                if handleColorAdjustmentKeyDown(event, modifiers: normalizedModifiers) {
                    return true
                }
            case .curves:
                if handleCurveAdjustmentKeyDown(event, modifiers: normalizedModifiers) {
                    return true
                }
            }
        } else if handleCurveAdjustmentKeyDown(event, modifiers: normalizedModifiers) {
            return true
        }

        if normalizedModifiers.isEmpty,
           event.charactersIgnoringModifiers?.lowercased() == "a" {
            toggleLayerTransparentPixelLock(workspace.document.activeLayerID)
            return true
        }

        if handleOilPaintShortcut(event) {
            return true
        }

        if event.keyCode == 53, patternPlacementPhase != .idle {
            cancelPatternPlacement(keepSelection: true)
            return true
        }

        if (event.keyCode == 36 || event.keyCode == 76),
           workspace.toolSession.activeTool == .straightLine,
           straightLineState.phase == .pending {
            return commitPendingStraightLine()
        }

        if event.keyCode == 53,
           workspace.toolSession.activeTool == .straightLine,
           straightLineState.phase != .idle {
            cancelStraightLineInteraction()
            return true
        }

        if event.keyCode == 53,
           workspace.toolSession.activeTool == .linearGradient,
           linearGradientState.phase != .idle {
            cancelLinearGradientInteraction()
            return true
        }

        if (event.keyCode == 36 || event.keyCode == 76),
           workspace.toolSession.activeTool == .linearGradient,
           linearGradientState.isActiveSession {
            applyActiveGradientSession()
            return true
        }

        if event.keyCode == 53,
           workspace.toolSession.activeTool == .sectorGradient,
           sectorGradientState.phase != .idle {
            cancelSectorGradientInteraction()
            return true
        }

        if (event.keyCode == 36 || event.keyCode == 76),
           workspace.toolSession.activeTool == .sectorGradient,
           sectorGradientState.isActiveSession {
            applyActiveGradientSession()
            return true
        }

        if event.keyCode == 53,
           workspace.toolSession.activeTool == .polygonSelection,
           polygonSelectionState.phase != .idle {
            cancelPolygonSelectionInteraction()
            return true
        }

        if (event.keyCode == 51 || event.keyCode == 117),
           workspace.toolSession.activeTool == .polygonSelection,
           polygonSelectionState.phase == .building {
            undoLastPolygonSelectionPoint()
            return true
        }

        if workspace.toolSession.activeTool == .freeTransform {
            if event.keyCode == 36 || event.keyCode == 76 { // Enter
                applySelectionTransform()
                return true
            }
            if event.keyCode == 53 { // ESC
                cancelSelectionTransform()
                return true
            }
        }

        if isTransformingSelection && workspace.toolSession.activeTool != .freeTransform {
            if event.keyCode == 36 || event.keyCode == 76 { // Enter
                applySelectionTransform()
                return true
            }
            if event.keyCode == 53 { // ESC
                cancelSelectionTransform()
                return true
            }
        }

        if isBrushTipCanvasFocused,
           normalizedModifiers.intersection([.command, .control]).isEmpty == false,
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            return importBrushTipImage(fromPasteboard: .general)
        }

        if isColorBlocksPanelFocused,
           workspace.colorPanel.mode == .blocks,
           normalizedModifiers.intersection([.command, .control]).isEmpty == false,
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            return importColorPanelPalette(fromPasteboard: .general)
        }

        if normalizedModifiers == [.command, .option, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "e" {
            stampVisibleLayers()
            return true
        }

        if normalizedModifiers == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            copyMergedPixels()
            return true
        }

        if normalizedModifiers == [.command],
           let shortcut = event.charactersIgnoringModifiers?.lowercased() {
            switch shortcut {
            case "c":
                copyPixels()
                return true
            case "x":
                cutPixels()
                return true
            case "v":
                pastePixels()
                return true
            default:
                break
            }
        }

        if normalizedModifiers.intersection([.command, .control, .option]).isEmpty,
           let digit = event.charactersIgnoringModifiers,
           let shortcut = Int(digit),
           (1...4).contains(shortcut),
           activateBrushPresetShortcut(slotIndex: shortcut - 1) {
            return true
        }

        if event.keyCode == 49 {
            if !isPanModeActive {
                setPanModeActive(true)
            }
            return true
        }

        if event.keyCode == 53 {
            guard workspace.selection.displayRect != nil else { return false }
            clearSelection()
            return true
        }

        if isForegroundColorFillShortcut(
            keyCode: event.keyCode,
            modifiers: normalizedModifiers
        ) {
            fillLegalPixelsWithForegroundColorShortcut()
            return true
        }

        if (event.keyCode == 51 || event.keyCode == 117),
           normalizedModifiers.isEmpty {
            deleteSelectionOrActiveLayer()
            return true
        }

        if normalizedModifiers.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "d" {
            guard workspace.selection.displayRect != nil else { return true }
            clearSelection()
            return true
        }

        if let shortcutKey = event.charactersIgnoringModifiers?.uppercased(),
           handleToolShortcutKey(shortcutKey, modifiers: normalizedModifiers) {
            return true
        }

        if let direction = brushSizeShortcutDirection(for: event) {
            if isBrushTipCanvasFocused {
                adjustBrushTipEditorBrushSize(by: direction)
            } else {
                adjustBrushSize(by: direction)
            }
            return true
        }

        return false
    }

    private func handleOilPaintShortcut(_ event: NSEvent) -> Bool {
        let isBrushContext = workspace.toolSession.activeTool == .brush
            || (workspace.toolSession.activeTool == .eyedropper && previousToolBeforeEyedropper == .brush)
        guard isBrushContext,
              workspace.toolSession.brush.oilPaint.isEnabled,
              workspace.toolSession.brush.effectivePaintJitterAmount > 0.001 else {
            return false
        }
        if shortcutSettings.oilPaintWashShortcut.matchesKeyDown(event) {
            washOilPaintBrush()
            return true
        }
        if shortcutSettings.oilPaintLoadShortcut.matchesKeyDown(event) {
            loadSelectedColorIntoOilPaintBrush()
            return true
        }
        return false
    }

    func handleKeyUp(_ event: NSEvent) -> Bool {
        if shortcutSettings.quickColorPickerShortcut.matchesKeyUp(event),
           isQuickColorPickerShortcutActive {
            cancelQuickColorPickerShortcut()
            return true
        }

        guard event.keyCode == 49 else { return false }
        if isPanModeActive {
            setPanModeActive(false)
        }
        return true
    }

    func handleModifierFlagsChanged(_ modifierFlags: NSEvent.ModifierFlags) -> Bool {
        let normalizedModifiers = modifierFlags.intersection(.deviceIndependentFlagsMask)
        if isQuickColorPickerShortcutActive,
           !shortcutSettings.quickColorPickerShortcut.modifiersStillSatisfied(by: normalizedModifiers) {
            cancelQuickColorPickerShortcut()
        }
        return false
    }

    private func refresh(
        invalidatedLayerIDs: Set<LayerID>? = nil,
        reason: StaticString = "unspecified"
    ) {
        Self.normalizeDisabledToolsIfNeeded(in: bootstrap.workspaceStore)
        let state = bootstrap.workspaceStore.state
        let previousSceneSnapshot = sceneSnapshot
        if workspace.selection != state.selection {
            selectionRevision &+= 1
        }
        if workspace.viewport != state.viewport {
            viewportRevision &+= 1
        }
        bootstrap.layerSurfaceStore.prepareTextures(
            for: state.document,
            metal: bootstrap.metalContext
        )
        if let invalidatedLayerIDs {
            for layerID in invalidatedLayerIDs {
                layerThumbnailCache.removeValue(forKey: layerID)
            }
        } else {
            let previousDocument = workspace.document
            let currentDocument = state.document
            let previousLayerByID = Dictionary(uniqueKeysWithValues: previousDocument.layers.map { ($0.id, $0) })
            let currentLayerByID = Dictionary(uniqueKeysWithValues: currentDocument.layers.map { ($0.id, $0) })
            let validLayerIDs = Set(currentLayerByID.keys)
            layerThumbnailCache = layerThumbnailCache.filter { validLayerIDs.contains($0.key) }
            for layerID in validLayerIDs where previousLayerByID[layerID] != currentLayerByID[layerID] {
                // Visibility, ordering and active selection do not alter an
                // individual layer thumbnail. Mask or adjustment changes do.
                let previous = previousLayerByID[layerID]
                let current = currentLayerByID[layerID]
                if previous?.mask != current?.mask || previous?.adjustment != current?.adjustment {
                    layerThumbnailCache.removeValue(forKey: layerID)
                }
            }
        }
        layerThumbnailRevision &+= 1
        workspace = state
        syncColorAdjustmentSessionToCurrentContextIfNeeded()
        syncCurveAdjustmentSessionToCurrentContextIfNeeded()
        let updatedSceneSnapshot = currentSceneSnapshot(for: state)
        sceneSnapshot = updatedSceneSnapshot
        scheduleNavigatorPreviewRefreshIfSourceChanged(
            previousSceneSnapshot: previousSceneSnapshot,
            currentSceneSnapshot: updatedSceneSnapshot
        )
        canUndo = bootstrap.historyController.canUndo
        canRedo = bootstrap.historyController.canRedo
        canMergeDown = state.document.activeMergeDownContext.map { !$0.destination.isAdjustmentLayer } ?? false
        canMergeVisible = state.document.mergeVisibleContext != nil
        syncSelectionOverlayProxy()
        scheduleWholeLayerInteractionBoundsRefreshIfNeeded(for: state)
        scheduleLuminosityCaptureIfSourceChanged(
            previousSceneSnapshot: previousSceneSnapshot,
            currentSceneSnapshot: updatedSceneSnapshot
        )
    }

    private func refreshLightweight(reason: StaticString = "unspecified") {
        Self.normalizeDisabledToolsIfNeeded(in: bootstrap.workspaceStore)
        let state = bootstrap.workspaceStore.state
        let previousSceneSnapshot = sceneSnapshot
        if workspace.selection != state.selection {
            selectionRevision &+= 1
        }
        if workspace.viewport != state.viewport {
            viewportRevision &+= 1
        }
        workspace = state
        syncColorAdjustmentSessionToCurrentContextIfNeeded()
        syncCurveAdjustmentSessionToCurrentContextIfNeeded()
        let updatedSceneSnapshot = currentSceneSnapshot(for: state)
        sceneSnapshot = updatedSceneSnapshot
        scheduleNavigatorPreviewRefreshIfSourceChanged(
            previousSceneSnapshot: previousSceneSnapshot,
            currentSceneSnapshot: updatedSceneSnapshot
        )
        canUndo = bootstrap.historyController.canUndo
        canRedo = bootstrap.historyController.canRedo
        canMergeDown = state.document.activeMergeDownContext.map { !$0.destination.isAdjustmentLayer } ?? false
        canMergeVisible = state.document.mergeVisibleContext != nil
        colorPanelProxy.colorPanel = state.colorPanel
        colorPanelProxy.selectedColor = state.toolSession.selectedColor
        scheduleLuminosityCaptureIfSourceChanged(
            previousSceneSnapshot: previousSceneSnapshot,
            currentSceneSnapshot: updatedSceneSnapshot
        )
        syncSelectionOverlayProxy()
        scheduleWholeLayerInteractionBoundsRefreshIfNeeded(for: state)
    }

    /// GPU content changed without a WorkspaceState mutation. Publish only the
    /// render snapshot so high-frequency preview packets do not invalidate the
    /// entire SwiftUI inspector hierarchy. The stroke-end path performs the
    /// normal full refresh and history/capability synchronization.
    private func refreshCanvasContentOnly() {
        let state = bootstrap.workspaceStore.state
        let previousSceneSnapshot = sceneSnapshot
        let updatedSceneSnapshot = currentSceneSnapshot(for: state)
        sceneSnapshot = updatedSceneSnapshot
        scheduleNavigatorPreviewRefreshIfSourceChanged(
            previousSceneSnapshot: previousSceneSnapshot,
            currentSceneSnapshot: updatedSceneSnapshot
        )
        scheduleLuminosityCaptureIfSourceChanged(
            previousSceneSnapshot: previousSceneSnapshot,
            currentSceneSnapshot: updatedSceneSnapshot
        )
    }

    /// 仅同步 toolSession 相关状态（画笔大小、不透明度、颜色等），
    /// 不触碰 GPU 纹理、缩略图缓存或 sceneSnapshot，避免滑块拖动时主线程卡顿。
    private func refreshToolSessionOnly() {
        let state = bootstrap.workspaceStore.state
        workspace = state
    }

    /// 透视辅助线属于文档级 UI 状态，不应触发 Metal 场景重建或缩略图刷新。
    private func refreshPerspectiveGuideOnly() {
        workspace = bootstrap.workspaceStore.state
        if let selectedPerspectiveAnchorID,
           workspace.document.perspectiveGuide?.anchors.contains(where: {
               $0.id == selectedPerspectiveAnchorID
           }) != true {
            self.selectedPerspectiveAnchorID = nil
        }
        canUndo = bootstrap.historyController.canUndo
        canRedo = bootstrap.historyController.canRedo
    }

    /// 体块参考属于文档级 UI 场景，不参与图层合成，也不应重建 Metal 画布快照。
    private func refreshBlockReferenceOnly() {
        workspace = bootstrap.workspaceStore.state
        let existingObjectIDs = Set(workspace.document.blockReferenceScene?.objects.map(\.id) ?? [])
        blockReferenceEditorState.selectedObjectIDs.formIntersection(existingObjectIDs)
        if let selectedObjectID = blockReferenceEditorState.selectedObjectID,
           !existingObjectIDs.contains(selectedObjectID) {
            blockReferenceEditorState.selectedObjectID = blockReferenceEditorState.selectedObjectIDs.first
            blockReferenceEditorState.selectedFaceIndex = nil
        }
        canUndo = bootstrap.historyController.canUndo
        canRedo = bootstrap.historyController.canRedo
    }

    private func refreshDocumentOverlayOnly() {
        refreshPerspectiveGuideOnly()
        let existingObjectIDs = Set(workspace.document.blockReferenceScene?.objects.map(\.id) ?? [])
        blockReferenceEditorState.selectedObjectIDs.formIntersection(existingObjectIDs)
        if let selectedObjectID = blockReferenceEditorState.selectedObjectID,
           !existingObjectIDs.contains(selectedObjectID) {
            blockReferenceEditorState.selectedObjectID = blockReferenceEditorState.selectedObjectIDs.first
            blockReferenceEditorState.selectedFaceIndex = nil
        }
    }

    private func notePrimaryBrushTipDefinitionChanged() {
        strokeResetToken &+= 1
    }

    private func refreshSelectionOverlayOnly() {
        syncSelectionOverlayProxy()
    }

    var metalContext: MetalDeviceContext {
        bootstrap.metalContext
    }

    var layerSurfaceStore: StageOneLayerSurfaceStore {
        bootstrap.layerSurfaceStore
    }

    var eyedropperSampler: EyedropperSampler {
        bootstrap.eyedropperSampler
    }

    @discardableResult
    func checkpointSingleLayerHistoryIfPossible(
        layerID: LayerID,
        operationKind: String,
        workspaceOverride: WorkspaceState? = nil
    ) -> Bool {
        checkpointHistoryIfPossible(
            operationKind: operationKind,
            candidateChangedLayerIDs: [layerID],
            captureMode: .inPlaceChangedLayers([layerID]),
            workspaceOverride: workspaceOverride
        )
    }

    func finalizeCommittedSingleLayerMutation(_ layerID: LayerID) {
        layerThumbnailCache.removeValue(forKey: layerID)
        bootstrap.strokeEngine.resetBrushPipelineState()
        clearRecentBrushAdjustmentState()
        noteCanvasContentChanged(changedLayerIDs: [layerID])
        refresh(invalidatedLayerIDs: [layerID])
        recordDrawingActivityIfNeeded()
    }

    func clearCommittedSelectionWithoutHistory() {
        selectionEpoch += 1
        cancelActiveRasterizationTask()
        pendingCombineMode = nil
        pendingCombineBaseShape = nil
        activeLassoRawPoints = []
        activeLassoPreviewPoints = []
        activeLassoBounds = nil
        lassoSamplingDebugPoints = []
        samePathPreviewDebugShape = nil
        samePathCommittedDebugShape = nil
        bootstrap.workspaceStore.updateSelection { selection in
            selection = .empty
        }
    }

    func syncSelectionOverlayForAdjustmentState() {
        syncSelectionOverlayProxy()
    }

    func presentWorkspaceStatus(
        kind: WorkspaceStatus.Kind,
        message: String
    ) {
        showStatus(.init(kind: kind, message: message))
    }

    func setBrightnessAdjustmentEditorMode(_ mode: BrightnessAdjustmentEditorMode) {
        brightnessAdjustmentEditorMode = mode
        syncBrightnessAdjustmentHotkeyState()
    }

    func applyStroke(samples: [CanvasStrokeSample]) {
        if applyLayerMaskStrokeIfNeeded(samples: samples) {
            return
        }
        if workspace.toolSession.activeTool == .colorVitalization {
            applyColorAdjustmentStroke(samples: samples)
            return
        }
        if workspace.toolSession.activeTool == .brightnessAdjust {
            switch brightnessAdjustmentEditorMode {
            case .colorParameters:
                applyColorAdjustmentStroke(samples: samples)
            case .curves:
                applyCurveAdjustmentStroke(samples: samples)
            }
            return
        }
        dispatchCanvasStrokeSamples(
            samples,
            relayOriginalSamples: samples,
            recordsPaintingActivity: true
        )
    }

    private func dispatchCanvasStrokeSamples(
        _ samples: [CanvasStrokeSample],
        relayOriginalSamples: [CanvasStrokeSample]?,
        recordsPaintingActivity: Bool
    ) {
        guard !samples.isEmpty else { return }
        let diagnosticsEnabled = RuntimeDiagnostics.brushHotPathLoggingEnabled
        let applyStartNs = diagnosticsEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        if relayOriginalSamples != nil {
            ideationBranchActivityHandler?()
        }
        let packetIndex = strokePacketCount
        let skipLeadingStamp = packetIndex > 0
        _ = resolvedToolSessionForCanvasStrokes()
        if activePaintVariationSeed == 0 {
            activePaintVariationSeed = makePaintVariationSeed()
        }
        guard let strokePayload = bootstrap.interactionController.makeStrokeDescriptor(
            samples: samples,
            skipLeadingStamp: skipLeadingStamp,
            paintVariationSeed: activePaintVariationSeed
        ) else {
            if diagnosticsEnabled {
                let applyDurationMs = Double(DispatchTime.now().uptimeNanoseconds - applyStartNs) / 1_000_000
                brushStrokeLogger.debug("[brush-feel] applyStrokeMainThreadMs=\(applyDurationMs, privacy: .public)")
            }
            return
        }

        if isGeneratorStrokeModeEnabled,
           strokePayload.stroke.tool == .brush,
           applyGeneratorStroke(samples: samples, layerID: strokePayload.layerID, baseStroke: strokePayload.stroke) {
            if recordsPaintingActivity, !isApplyingMirroredIdeationOperation {
                drawingStatsController.recordPaintingActivity()
            }
            strokePacketCount += 1
            if diagnosticsEnabled {
                let applyDurationMs = Double(DispatchTime.now().uptimeNanoseconds - applyStartNs) / 1_000_000
                brushStrokeLogger.debug("[brush-feel] applyStrokeMainThreadMs=\(applyDurationMs, privacy: .public)")
            }
            return
        }

        let livePathMetric = bootstrap.strokeEngine.applyStroke(
            strokePayload.stroke,
            to: strokePayload.layerID
        )
        if diagnosticsEnabled {
            brushStrokeLogger.debug(
                "[packet] index=\(packetIndex, privacy: .public) skipLeadingStamp=\(skipLeadingStamp, privacy: .public) incomingPoints=\(samples.count, privacy: .public) livePathMetric=\(livePathMetric, privacy: .public)"
            )
            let applyDurationMs = Double(DispatchTime.now().uptimeNanoseconds - applyStartNs) / 1_000_000
            brushStrokeLogger.debug("[brush-feel] applyStrokeMainThreadMs=\(applyDurationMs, privacy: .public)")
        }
        if recordsPaintingActivity, !isApplyingMirroredIdeationOperation {
            drawingStatsController.recordPaintingActivity()
        }
        strokePacketCount += 1
        if let relayOriginalSamples {
            relayIdeationOperation(.applyStroke(relayOriginalSamples))
        }
    }

    func beginStrokeIfNeeded(paintVariationSeed seedOverride: UInt32? = nil) {
        let auditEnabled = PerformanceAuditStore.shared.isRecordingEnabled
        let startNs = auditEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if auditEnabled {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000
                PerformanceAuditStore.shared.recordDuration("WorkspaceViewModel.beginStrokeIfNeeded", ms: ms)
            }
        }
        ideationBranchActivityHandler?()
        strokePacketCount = 0

        if let layerID = activeMaskEditingLayerID,
           layerID == workspace.document.activeLayerID,
           workspace.document.layer(layerID)?.mask != nil,
           workspace.toolSession.activeTool == .brush || workspace.toolSession.activeTool == .eraser {
            lastLayerMaskStrokeSample = nil
            _ = checkpointHistoryIfPossible(
                operationKind: "layerMask.stroke",
                candidateChangedLayerIDs: [layerID],
                captureMode: .inPlaceChangedLayers([layerID])
            )
            return
        }

        if workspace.toolSession.activeTool == .colorVitalization {
            beginColorAdjustmentStrokeIfNeeded()
            return
        }
        if workspace.toolSession.activeTool == .brightnessAdjust {
            switch brightnessAdjustmentEditorMode {
            case .colorParameters:
                beginColorAdjustmentStrokeIfNeeded()
            case .curves:
                beginCurveAdjustmentStrokeIfNeeded()
            }
            return
        }

        let activeLayerID = workspace.document.activeLayerID
        if let activeLayer = workspace.document.layer(activeLayerID),
           activeLayer.isPaintLayer,
           !workspace.document.isLayerEffectivelyVisible(activeLayerID) {
            showStatus(.init(kind: .info, message: "当前图层不可见，请先显示图层再绘画"))
            return
        }

        guard let layerID = bootstrap.interactionController.activeEditableLayerID() else {
            return
        }

        if shouldBakeRecentBrushAdjustmentBeforeStartingNewBrushStroke() {
            _ = drainPendingBrushCommitsIfNeeded(resetLiveSession: true)
        }
        if isGeneratorStrokeModeEnabled,
           workspace.toolSession.activeTool == .brush,
           !GeneratorFeatureSupport.support(for: workspace.generator.kind).supports(.directStroke) {
            showStatus(.init(kind: .info, message: "\(workspace.generator.kind.displayName) 仅支持区域生成"))
            return
        }

        if !isBrushLikeTool(workspace.toolSession.activeTool) {
            checkpointHistoryIfPossible()
        }

        let paintVariationSeed = seedOverride ?? makePaintVariationSeed()
        activePaintVariationSeed = paintVariationSeed
        bootstrap.strokeEngine.beginStrokeIfNeeded(
            toolSession: resolvedToolSessionForCanvasStrokes(),
            layerID: layerID
        )
        relayIdeationOperation(.beginStroke(paintVariationSeed: paintVariationSeed))
    }

    func endStroke() {
        if let layerID = activeMaskEditingLayerID,
           layerID == workspace.document.activeLayerID,
           workspace.document.layer(layerID)?.mask != nil,
           workspace.toolSession.activeTool == .brush || workspace.toolSession.activeTool == .eraser {
            lastLayerMaskStrokeSample = nil
            strokePacketCount = 0
            noteCanvasContentChanged(changedLayerIDs: [layerID])
            refresh(invalidatedLayerIDs: [layerID])
            return
        }
        if workspace.toolSession.activeTool == .colorVitalization {
            endColorAdjustmentStroke()
            return
        }
        if workspace.toolSession.activeTool == .brightnessAdjust {
            switch brightnessAdjustmentEditorMode {
            case .colorParameters:
                endColorAdjustmentStroke()
            case .curves:
                endCurveAdjustmentStroke()
            }
            return
        }
        ideationBranchActivityHandler?()
        bootstrap.strokeEngine.endStroke()
        strokePacketCount = 0
        activePaintVariationSeed = 0
        generatorStrokeSession = .init(kind: workspace.generator.kind)
        noteCanvasContentChanged(changedLayerIDs: [workspace.document.activeLayerID])
        relayIdeationOperation(.endStroke)
    }

    private func applyLayerMaskStrokeIfNeeded(samples: [CanvasStrokeSample]) -> Bool {
        guard let layerID = activeMaskEditingLayerID,
              layerID == workspace.document.activeLayerID,
              workspace.document.layer(layerID)?.mask != nil,
              workspace.toolSession.activeTool == .brush || workspace.toolSession.activeTool == .eraser,
              let maskTexture = bootstrap.layerSurfaceStore.maskTexture(for: layerID),
              !samples.isEmpty else {
            return false
        }
        var continuousSamples = samples
        if let lastLayerMaskStrokeSample,
           continuousSamples.first != lastLayerMaskStrokeSample {
            continuousSamples.insert(lastLayerMaskStrokeSample, at: 0)
        }
        _ = bootstrap.layerMaskStrokeRenderer.render(
            samples: continuousSamples,
            brush: workspace.toolSession.brush,
            targetValue: resolvedLayerMaskStrokeTargetValue(),
            into: maskTexture,
            commandQueue: bootstrap.metalContext.commandQueue
        )
        lastLayerMaskStrokeSample = samples.last
        canvasContentRevision &+= 1
        refreshCanvasContentOnly()
        return true
    }

    private func resolvedLayerMaskStrokeTargetValue() -> Float {
        guard workspace.toolSession.activeTool == .brush else { return 0 }
        let color = workspace.toolSession.selectedColor
        // 图层蒙版遵循绘图软件通用的灰度语义：白色显示、黑色隐藏，
        // 中间灰度按感知亮度产生部分显示。橡皮擦始终写入黑色。
        return min(max(
            (color.red * 0.2126) + (color.green * 0.7152) + (color.blue * 0.0722),
            0
        ), 1)
    }

    private func makePaintVariationSeed() -> UInt32 {
        UInt32.random(in: 1...UInt32.max)
    }

    private func derivedPaintVariationSeed(_ seed: UInt32, salt: UInt32) -> UInt32 {
        var value = seed ^ (salt &* 0x9E37_79B9)
        value ^= value >> 16
        value &*= 0x7FEB_352D
        value ^= value >> 15
        value &*= 0x846C_A68B
        value ^= value >> 16
        return value == 0 ? (salt | 1) : value
    }

    @discardableResult
    func flushPendingBrushWork(into commandBuffer: MTLCommandBuffer) -> BrushFlushMetrics? {
        bootstrap.strokeEngine.flushPendingStrokePackets(into: commandBuffer)
    }

    var hasPendingBrushWork: Bool {
        bootstrap.strokeEngine.hasPendingBrushWork
    }

    func canOpportunisticallyDrainBrushCommits(
        hadLiveBrushWorkThisFrame: Bool
    ) -> Bool {
        let retainedRecentBrushCommitJobs = workspace.toolSession.activeTool == .brush
            ? bootstrap.strokeEngine.recentAdjustableBrushCommitLimit
            : 0
        return bootstrap.strokeEngine.canOpportunisticallyDrainPendingBrushCommitJobs(
            hadLiveBrushWorkThisFrame: hadLiveBrushWorkThisFrame,
            retainedRecentBrushCommitJobs: retainedRecentBrushCommitJobs
        )
    }

    func brushDisplayTexture(for layerID: LayerID) -> MTLTexture? {
        if let liveTexture = activeCurveAdjustmentPreviewTexture(for: layerID) {
            return liveTexture
        }
        if let liveTexture = activeColorAdjustmentPreviewTexture(for: layerID) {
            return liveTexture
        }
        return bootstrap.strokeEngine.displayTexture(for: layerID)
    }

    func opportunisticallyDrainBrushCommits(hadLiveBrushWorkThisFrame: Bool) {
        let auditEnabled = PerformanceAuditStore.shared.isRecordingEnabled
        let startNs = auditEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if auditEnabled {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000
                PerformanceAuditStore.shared.recordDuration("WorkspaceViewModel.opportunisticallyDrainBrushCommits", ms: ms)
            }
        }
        guard bootstrap.strokeEngine.hasPendingBrushCommitJobs else {
            return
        }

        do {
            let result = try bootstrap.strokeEngine.opportunisticDrainPendingBrushCommitJobs(
                hadLiveBrushWorkThisFrame: hadLiveBrushWorkThisFrame,
                maxJobs: 1,
                maxCpuMs: 0.75,
                retainedRecentBrushCommitJobs: workspace.toolSession.activeTool == .brush
                    ? bootstrap.strokeEngine.recentAdjustableBrushCommitLimit
                    : 0
            ) { [self] job in
                try captureBrushCommitCheckpoint(for: job)
                hasUnsavedChanges = true
            }

            if result.drainedJobs > 0 {
                canUndo = bootstrap.historyController.canUndo
                canRedo = bootstrap.historyController.canRedo
                if workspace.toolSession.activeTool != .brush || !bootstrap.strokeEngine.hasPendingBrushCommitJobs {
                    clearRecentBrushAdjustmentState()
                } else {
                    syncRecentBrushAdjustmentState()
                }
            }
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func undo() {
        if cancelPendingBlockReferenceEditForHistory() { return }
        let auditEnabled = PerformanceAuditStore.shared.isRecordingEnabled
        let startNs = auditEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if auditEnabled {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000
                PerformanceAuditStore.shared.recordDuration("WorkspaceViewModel.undo", ms: ms)
            }
        }
        ideationBranchActivityHandler?()
        if workspace.toolSession.activeTool == .straightLine,
           straightLineState.phase != .idle {
            cancelStraightLineInteraction()
            return
        }
        _ = drainPendingBrushCommitsIfNeeded(resetLiveSession: true)
        if ideationUndoHandler?() == true {
            return
        }
        performUndoLocally()
    }

    var visibleHistoryTimeline: VisibleHistoryTimeline {
        bootstrap.historyController.visibleTimeline
    }

    func prepareVisibleHistoryPresentation() {
        _ = flushBrushEditingBoundary(reason: "openVisibleHistory")
        guard visibleHistoryPreviewOriginCount == nil else { return }
        let currentCount = visibleHistoryTimeline.currentAppliedEntryCount
        visibleHistoryPreviewOriginCount = currentCount
        visibleHistoryPreviewOriginWasDirty = hasUnsavedChanges
        visibleHistoryPreviewOriginSelection = workspace.selection
        visibleHistoryPreviewTargetCount = currentCount
    }

    func previewVisibleHistory(toAppliedEntryCount targetCount: Int) {
        if visibleHistoryPreviewOriginCount == nil {
            prepareVisibleHistoryPresentation()
        }
        guard let plan = visibleHistoryTimeline.navigationPlan(toAppliedEntryCount: targetCount) else {
            showStatus(.init(kind: .info, message: "历史记录已经变化，请重新打开预览"))
            return
        }
        if performVisibleHistoryNavigation(plan, marksDocumentDirty: false, showsCompletionStatus: false) {
            visibleHistoryPreviewTargetCount = targetCount
        }
    }

    func applyVisibleHistoryPreview() {
        guard let originCount = visibleHistoryPreviewOriginCount else { return }
        let targetCount = visibleHistoryTimeline.currentAppliedEntryCount
        let changed = targetCount != originCount
        visibleHistoryPreviewOriginCount = nil
        visibleHistoryPreviewOriginSelection = nil
        visibleHistoryPreviewTargetCount = nil
        hasUnsavedChanges = changed ? true : visibleHistoryPreviewOriginWasDirty
        showStatus(.init(
            kind: .info,
            message: changed ? "已应用预览中的历史状态" : "画布保持在原历史状态"
        ))
    }

    func cancelVisibleHistoryPreview() {
        guard let originCount = visibleHistoryPreviewOriginCount else { return }
        if originCount != visibleHistoryTimeline.currentAppliedEntryCount,
           let plan = visibleHistoryTimeline.navigationPlan(toAppliedEntryCount: originCount) {
            _ = performVisibleHistoryNavigation(
                plan,
                marksDocumentDirty: false,
                showsCompletionStatus: false
            )
        }
        let wasDirty = visibleHistoryPreviewOriginWasDirty
        if let originSelection = visibleHistoryPreviewOriginSelection {
            bootstrap.workspaceStore.updateSelection { selection in
                selection = originSelection
            }
            refreshLightweight(reason: "visibleHistoryPreview.restoreSelection")
        }
        visibleHistoryPreviewOriginCount = nil
        visibleHistoryPreviewOriginSelection = nil
        visibleHistoryPreviewTargetCount = nil
        hasUnsavedChanges = wasDirty
        showStatus(.init(kind: .info, message: "已退出历史预览，画布已恢复"))
    }

    func navigateVisibleHistory(to entryID: UUID) {
        guard ideationSession == nil, snapshotCompareSession == nil else {
            showStatus(.init(kind: .info, message: "当前模式下不可跳转编辑历史"))
            return
        }
        guard let plan = visibleHistoryTimeline.navigationPlan(to: entryID) else {
            showStatus(.init(kind: .info, message: "历史记录已经变化，请重新选择"))
            return
        }
        _ = performVisibleHistoryNavigation(plan)
    }

    func navigateVisibleHistory(toAppliedEntryCount targetCount: Int) {
        guard ideationSession == nil, snapshotCompareSession == nil else {
            showStatus(.init(kind: .info, message: "当前模式下不可跳转编辑历史"))
            return
        }
        guard let plan = visibleHistoryTimeline.navigationPlan(toAppliedEntryCount: targetCount) else {
            showStatus(.init(kind: .info, message: "历史记录已经变化，请重新选择"))
            return
        }
        _ = performVisibleHistoryNavigation(plan)
    }

    @discardableResult
    private func performVisibleHistoryNavigation(
        _ plan: VisibleHistoryNavigationPlan,
        marksDocumentDirty: Bool = true,
        showsCompletionStatus: Bool = true
    ) -> Bool {
        guard plan.totalStepCount > 0 else { return true }

        _ = drainPendingBrushCommitsIfNeeded(resetLiveSession: true)
        canvasCropState.cancel()
        guard resolveColorAdjustmentSessionIfNeeded(reason: .historyNavigation) else { return false }
        guard resolveCurveAdjustmentSessionIfNeeded(reason: .historyNavigation) else { return false }
        if resolveTransformSession(reason: .historyNavigation) { return false }

        do {
            var restoredPixelContent = false
            switch plan.direction {
            case .undo:
                for _ in 0..<plan.undoStepCount {
                    restoredPixelContent = restoredPixelContent
                        || !bootstrap.historyController.nextUndoRestoresWorkspaceOnly
                    guard try bootstrap.historyController.undo() else { break }
                }
            case .redo:
                for _ in 0..<plan.redoStepCount {
                    restoredPixelContent = restoredPixelContent
                        || !bootstrap.historyController.nextRedoRestoresWorkspaceOnly
                    guard try bootstrap.historyController.redo() else { break }
                }
            case .none:
                return true
            }

            if restoredPixelContent {
                bootstrap.layerSurfaceStore.markContentUnknown(
                    for: bootstrap.workspaceStore.state.document.layers.map(\.id)
                )
                refresh()
                scheduleNavigatorPreviewRefresh()
            } else {
                refreshDocumentOverlayOnly()
            }
            canUndo = bootstrap.historyController.canUndo
            canRedo = bootstrap.historyController.canRedo
            if marksDocumentDirty {
                hasUnsavedChanges = true
            }
            if showsCompletionStatus {
                showStatus(.init(kind: .info, message: "已跳转到所选历史状态"))
            }
            return true
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
            return false
        }
    }

    private func performUndoLocally() {
        canvasCropState.cancel()
        guard resolveColorAdjustmentSessionIfNeeded(reason: .historyNavigation) else {
            return
        }
        guard resolveCurveAdjustmentSessionIfNeeded(reason: .historyNavigation) else {
            return
        }
        if resolveTransformSession(reason: .historyNavigation) {
            return
        }
        do {
            let restoresWorkspaceOnly = bootstrap.historyController.nextUndoRestoresWorkspaceOnly
            let didUndo = try bootstrap.historyController.undo()
            if didUndo, !restoresWorkspaceOnly {
                bootstrap.layerSurfaceStore.markContentUnknown(
                    for: bootstrap.workspaceStore.state.document.layers.map(\.id)
                )
            }
            if restoresWorkspaceOnly {
                refreshDocumentOverlayOnly()
            } else {
                refresh()
            }
            if didUndo, !restoresWorkspaceOnly {
                scheduleNavigatorPreviewRefresh()
            }
            if didUndo, workspace.toolSession.activeTool == .blockReference {
                blockReferenceEditorState.instruction = "已撤销上一项操作。"
            }
            showStatus(
                .init(
                    kind: .info,
                    message: didUndo ? "已撤销" : "没有可撤销的操作"
                )
            )
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func redo() {
        if cancelPendingBlockReferenceEditForHistory() { return }
        let auditEnabled = PerformanceAuditStore.shared.isRecordingEnabled
        let startNs = auditEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if auditEnabled {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000
                PerformanceAuditStore.shared.recordDuration("WorkspaceViewModel.redo", ms: ms)
            }
        }
        ideationBranchActivityHandler?()
        if workspace.toolSession.activeTool == .straightLine,
           straightLineState.phase != .idle {
            cancelStraightLineInteraction()
            return
        }
        _ = drainPendingBrushCommitsIfNeeded(resetLiveSession: true)
        if ideationRedoHandler?() == true {
            return
        }
        performRedoLocally()
    }

    private func performRedoLocally() {
        canvasCropState.cancel()
        guard resolveColorAdjustmentSessionIfNeeded(reason: .historyNavigation) else {
            return
        }
        guard resolveCurveAdjustmentSessionIfNeeded(reason: .historyNavigation) else {
            return
        }
        if resolveTransformSession(reason: .historyNavigation) {
            return
        }
        do {
            let restoresWorkspaceOnly = bootstrap.historyController.nextRedoRestoresWorkspaceOnly
            let didRedo = try bootstrap.historyController.redo()
            if didRedo, !restoresWorkspaceOnly {
                bootstrap.layerSurfaceStore.markContentUnknown(
                    for: bootstrap.workspaceStore.state.document.layers.map(\.id)
                )
            }
            if restoresWorkspaceOnly {
                refreshDocumentOverlayOnly()
            } else {
                refresh()
            }
            if didRedo, !restoresWorkspaceOnly {
                scheduleNavigatorPreviewRefresh()
            }
            if didRedo, workspace.toolSession.activeTool == .blockReference {
                blockReferenceEditorState.instruction = "已重做上一项操作。"
            }
            showStatus(
                .init(
                    kind: .info,
                    message: didRedo ? "已重做" : "没有可重做的操作"
                )
            )
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func exportPNG() {
        let documentName = workspace.document.metadata.name
        bootstrap.filePanelService.presentPNGExportPanel(
            defaultName: documentName,
            completion: documentScopedFileSelection { owner, url in
                guard let url else { return }
                do {
                    try owner.exportPNG(to: url)
                    owner.showStatus(.init(kind: .success, message: "已导出 PNG：\(url.lastPathComponent)"))
                } catch { owner.showStatus(.init(kind: .error, message: error.localizedDescription)) }
            }
        )
    }

    func presentRasterExportSheet() {
        guard !isRasterExportSheetPresented else { return }
        guard canBeginDocumentPersistence(action: "导出") else { return }
        rasterExportError = nil
        isRasterExportSheetPresented = true
        prepareRasterExportSourceBounds()
    }

    func dismissRasterExportSheet() {
        guard !isRasterExporting else { return }
        isRasterExportSheetPresented = false
        finishRasterExportPresentation()
    }

    func finishRasterExportPresentation() {
        guard !isRasterExporting else { return }
        rasterExportBoundsRequest = nil
        rasterExportSourceBounds = nil
        isPreparingRasterExportBounds = false
        rasterExportBoundsError = nil
    }

    private func prepareRasterExportSourceBounds() {
        rasterExportSourceBounds = nil
        rasterExportBoundsError = nil
        isPreparingRasterExportBounds = true
        let request = UUID()
        rasterExportBoundsRequest = request
        let documentRevision = documentChangeRevision
        let documentID = workspace.document.metadata.drawingStatsID
        do {
            let composite = try makeVisibleCompositeTexture(waitUntilCompleted: false, includesLiveBrushContent: true)
            let detector = WorkspaceUncheckedBox(bootstrap.layerContentBoundsDetector)
            let queue = WorkspaceUncheckedBox(bootstrap.metalContext.commandQueue)
            let texture = WorkspaceUncheckedBox(composite)
            Task { [weak self] in
                let detected = await Task.detached(priority: .utility) {
                    Result { try detector.value.detect(texture: texture.value, commandQueue: queue.value) }
                }.value
                guard let self, self.rasterExportBoundsRequest == request,
                      self.isRasterExportSheetPresented else { return }
                self.isPreparingRasterExportBounds = false
                guard self.documentChangeRevision == documentRevision,
                      self.workspace.document.metadata.drawingStatsID == documentID else {
                    self.rasterExportBoundsError = "画布已变化，请关闭后重新打开导出窗口"
                    return
                }
                do {
                    switch try detected.get() {
                    case .bounds(let bounds):
                        self.rasterExportSourceBounds = RasterExportPixelBounds(
                            originX: max(0, Int(floor(bounds.minX))),
                            originY: max(0, Int(floor(bounds.minY))),
                            width: max(1, Int(ceil(bounds.maxX)) - Int(floor(bounds.minX))),
                            height: max(1, Int(ceil(bounds.maxY)) - Int(floor(bounds.minY)))
                        )
                    case .empty:
                        self.rasterExportBoundsError = RasterExportError.noVisibleContent.localizedDescription
                    }
                } catch {
                    self.rasterExportBoundsError = error.localizedDescription
                }
            }
        } catch {
            isPreparingRasterExportBounds = false
            rasterExportBoundsError = error.localizedDescription
        }
    }

    func rasterExportValidationMessage(options: RasterExportOptions) -> String? {
        do {
            try options.validate()
            let size = workspace.document.canvasSize
            let bounds: RasterExportPixelBounds
            if options.scope == .visibleContent {
                if isPreparingRasterExportBounds { return "正在计算可见内容边界…" }
                if let error = rasterExportBoundsError { return error }
                guard let source = rasterExportSourceBounds else {
                    return "可见内容边界尚未准备好，请重新打开导出窗口"
                }
                bounds = source
            } else {
                bounds = .init(originX: 0, originY: 0, width: size.width, height: size.height)
            }
            try bootstrap.rasterExporter.validateOutput(
                canvasWidth: size.width, canvasHeight: size.height, sourceBounds: bounds, options: options
            )
            return nil
        } catch { return error.localizedDescription }
    }

    func exportRaster(options: RasterExportOptions) {
        guard isRasterExportSheetPresented, !isRasterExporting else { return }
        if let error = rasterExportValidationMessage(options: options) {
            rasterExportError = error
            return
        }
        rasterExportError = nil
        // Busy includes destination selection, preventing duplicate panels and document replacement.
        isRasterExporting = true
        let documentID = workspace.document.metadata.drawingStatsID
        bootstrap.filePanelService.presentRasterExportPanel(
            defaultName: workspace.document.metadata.name,
            format: options.format
        ) { [weak self] url in
            guard let self else { return }
            guard let url else {
                self.isRasterExporting = false
                return
            }
            guard self.workspace.document.metadata.drawingStatsID == documentID else {
                self.isRasterExporting = false
                self.rasterExportError = "工程已切换，请重新打开导出窗口"
                return
            }
            self.performRasterExport(options: options, to: url)
        }
    }

    private func performRasterExport(options: RasterExportOptions, to url: URL) {
        let exporter = bootstrap.rasterExporter
        showStatus(.init(kind: .info, message: "正在导出…"))
        rasterExportTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            let composite: MTLTexture
            do {
                // Same visible-layer plan as recording; include the most recent adjustable stroke
                // without forcing a synchronous history commit merely to export an image.
                composite = try self.makeVisibleCompositeTexture(waitUntilCompleted: false, includesLiveBrushContent: true)
            } catch {
                self.rasterExportTask = nil
                self.isRasterExporting = false
                self.rasterExportError = error.localizedDescription
                self.showStatus(.init(kind: .error, message: error.localizedDescription))
                return
            }

            let texture = WorkspaceUncheckedBox(composite)
            let serializer = WorkspaceUncheckedBox(self.bootstrap.textureSerializer)
            let exportResult = await Task.detached(priority: .userInitiated) {
                Result {
                    let snapshot = try serializer.value.snapshot(texture: texture.value)
                    return try exporter.export(
                        snapshot: snapshot,
                        options: options,
                        to: url
                    )
                }
            }.value

            self.rasterExportTask = nil
            self.isRasterExporting = false
            do {
                let result = try exportResult.get()
                self.isRasterExportSheetPresented = false
                self.finishRasterExportPresentation()
                self.showStatus(.init(
                    kind: .success,
                    message: "已导出 \(options.format.rawValue.uppercased())：\(result.pixelWidth)×\(result.pixelHeight)"
                ))
            } catch {
                self.rasterExportError = error.localizedDescription
                self.showStatus(.init(kind: .error, message: error.localizedDescription))
            }
        }
    }

    func exportPNG(to fileURL: URL) throws {
        _ = flushBrushEditingBoundary(reason: "exportPNG")
        let compositeTexture = try makeVisibleCompositeTexture()
        try bootstrap.exportController.exportPNG(
            texture: compositeTexture,
            request: ExportRequest(fileURL: fileURL)
        )
    }

    func toggleWorkspaceChromeVisibility() {
        isWorkspaceChromeHidden.toggle()
    }

    var ideationActiveBranchViewModel: WorkspaceViewModel? {
        ideationSession?.activeBranchViewModel
    }

    func handleSnapshotSavePrimaryAction() {
        guard snapshotCompareSession == nil else { return }
        guard ideationSession == nil else {
            showStatus(.init(kind: .info, message: "方案试探期间不可使用快照保存"))
            return
        }

        if savedSnapshots.count >= Self.maxSavedSnapshotCount {
            openSnapshotCompare()
            return
        }

        guard ensureDocumentResourceBudget(
            additionalSavedSnapshots: 1,
            action: "保存画布快照"
        ) else { return }

        do {
            _ = flushBrushEditingBoundary(reason: "handleSnapshotSavePrimaryAction")
            let snapshot = try makeVisibleCompositeSnapshot()
            let savedSnapshot = makeSavedCanvasSnapshot(from: snapshot, includesPreviewImage: false)
            savedSnapshots.append(savedSnapshot)
            hasUnsavedChanges = true
            showStatus(.init(kind: .success, message: "已保存快照（\(savedSnapshots.count)/\(Self.maxSavedSnapshotCount)）"))
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func requestSnapshotSavePrimaryAction() {
        guard !isSavingSnapshot else { return }
        guard !isPreparingSnapshotCompare else { return }
        guard snapshotCompareSession == nil else { return }
        guard ideationSession == nil else {
            showStatus(.init(kind: .info, message: "方案试探期间不可使用快照保存"))
            return
        }

        if savedSnapshots.count >= Self.maxSavedSnapshotCount {
            requestOpenSnapshotCompare()
            return
        }


        guard ensureDocumentResourceBudget(
            additionalSavedSnapshots: 1,
            action: "保存画布快照"
        ) else { return }

        do {
            _ = flushBrushEditingBoundary(reason: "requestSnapshotSavePrimaryAction")
            let compositeTexture = try makeVisibleCompositeTexture(waitUntilCompleted: false)
            let serializerBox = WorkspaceUncheckedBox(bootstrap.textureSerializer)
            let textureBox = WorkspaceUncheckedBox(compositeTexture)
            let documentID = workspace.document.metadata.drawingStatsID

            snapshotSaveRequestID &+= 1
            let requestID = snapshotSaveRequestID
            isSavingSnapshot = true
            showStatus(.init(kind: .info, message: "正在保存快照…"))

            snapshotSaveTask = Task { [weak self] in
                let result = await Task.detached(priority: .userInitiated) {
                    Result {
                        try serializerBox.value.snapshot(texture: textureBox.value)
                    }
                }.value

                guard let self, self.snapshotSaveRequestID == requestID else { return }
                self.snapshotSaveTask = nil
                self.isSavingSnapshot = false
                guard !Task.isCancelled else { return }
                guard self.workspace.document.metadata.drawingStatsID == documentID else { return }

                do {
                    let savedSnapshot = self.makeSavedCanvasSnapshot(
                        from: try result.get(),
                        includesPreviewImage: false
                    )
                    guard self.savedSnapshots.count < Self.maxSavedSnapshotCount else { return }
                    self.savedSnapshots.append(savedSnapshot)
                    self.hasUnsavedChanges = true
                    self.showStatus(
                        .init(
                            kind: .success,
                            message: "已保存快照（\(self.savedSnapshots.count)/\(Self.maxSavedSnapshotCount)）"
                        )
                    )
                } catch {
                    self.showStatus(.init(kind: .error, message: error.localizedDescription))
                }
            }
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func requestOpenSnapshotCompare() {
        guard !isPreparingSnapshotCompare else { return }
        guard !isSavingSnapshot else {
            showStatus(.init(kind: .info, message: "快照保存完成后再进入对比"))
            return
        }
        guard snapshotCompareSession == nil else {
            showStatus(.init(kind: .info, message: "快照对比已开启"))
            return
        }
        guard ideationSession == nil else {
            showStatus(.init(kind: .info, message: "方案试探期间不可进入快照对比"))
            return
        }
        guard !savedSnapshots.isEmpty else {
            showStatus(.init(kind: .info, message: "当前还没有已保存的快照"))
            return
        }

        do {
            _ = flushBrushEditingBoundary(reason: "requestOpenSnapshotCompare")
            suspendTimelapseForSnapshotCompareIfNeeded()
            let compositeTexture = try makeVisibleCompositeTexture(waitUntilCompleted: false)
            let serializerBox = WorkspaceUncheckedBox(bootstrap.textureSerializer)
            let textureBox = WorkspaceUncheckedBox(compositeTexture)
            let documentID = workspace.document.metadata.drawingStatsID

            snapshotComparePreparationRequestID &+= 1
            let requestID = snapshotComparePreparationRequestID
            isPreparingSnapshotCompare = true
            showStatus(.init(kind: .info, message: "正在准备快照对比…"))

            snapshotComparePreparationTask = Task { [weak self] in
                let result = await Task.detached(priority: .userInitiated) {
                    Result {
                        try serializerBox.value.snapshot(texture: textureBox.value)
                    }
                }.value

                guard let self, self.snapshotComparePreparationRequestID == requestID else { return }
                self.snapshotComparePreparationTask = nil
                self.isPreparingSnapshotCompare = false
                guard !Task.isCancelled else {
                    self.resumeTimelapseAfterSnapshotCompareIfNeeded()
                    return
                }
                guard self.workspace.document.metadata.drawingStatsID == documentID else {
                    self.resumeTimelapseAfterSnapshotCompareIfNeeded()
                    return
                }

                do {
                    let frozenSnapshot = self.makeSavedCanvasSnapshot(
                        from: try result.get(),
                        includesPreviewImage: false
                    )
                    self.snapshotCompareSession = SnapshotCompareSessionState(
                        frozenCurrentSnapshot: frozenSnapshot
                    )
                    self.prepareFrozenSnapshotPreviewIfNeeded(for: frozenSnapshot)
                    self.showStatus(.init(kind: .success, message: "已进入快照对比"))
                } catch {
                    self.resumeTimelapseAfterSnapshotCompareIfNeeded()
                    self.showStatus(.init(kind: .error, message: error.localizedDescription))
                }
            }
        } catch {
            resumeTimelapseAfterSnapshotCompareIfNeeded()
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func openSnapshotCompare(frozenSnapshotOverride: CanvasSavedSnapshot? = nil) {
        guard snapshotCompareSession == nil else {
            showStatus(.init(kind: .info, message: "快照对比已开启"))
            return
        }
        guard ideationSession == nil else {
            showStatus(.init(kind: .info, message: "方案试探期间不可进入快照对比"))
            return
        }
        guard !savedSnapshots.isEmpty else {
            showStatus(.init(kind: .info, message: "当前还没有已保存的快照"))
            return
        }

        do {
            _ = flushBrushEditingBoundary(reason: "openSnapshotCompare")
            suspendTimelapseForSnapshotCompareIfNeeded()
            let frozenSnapshot: CanvasSavedSnapshot
            if let frozenSnapshotOverride {
                frozenSnapshot = frozenSnapshotOverride
            } else {
                frozenSnapshot = makeSavedCanvasSnapshot(
                    from: try makeVisibleCompositeSnapshot(),
                    includesPreviewImage: false
                )
            }
            snapshotCompareSession = SnapshotCompareSessionState(frozenCurrentSnapshot: frozenSnapshot)
            prepareFrozenSnapshotPreviewIfNeeded(for: frozenSnapshot)
            showStatus(.init(kind: .success, message: "已进入快照对比"))
        } catch {
            resumeTimelapseAfterSnapshotCompareIfNeeded()
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func cancelSnapshotCompare() {
        guard snapshotCompareSession != nil else { return }
        cancelSnapshotPreviewPreparationTasks()
        snapshotCompareSession = nil
        resumeTimelapseAfterSnapshotCompareIfNeeded()
        showStatus(.init(kind: .info, message: "已退出快照对比"))
    }

    func clearSavedSnapshots() {
        let wasSaving = isSavingSnapshot
        cancelPendingSnapshotSave()
        cancelPendingSnapshotComparePreparation(resumeTimelapseIfNeeded: true)
        guard !savedSnapshots.isEmpty else {
            showStatus(
                .init(
                    kind: .info,
                    message: wasSaving ? "已取消快照保存" : "当前没有可清空的快照"
                )
            )
            return
        }

        savedSnapshots.removeAll()
        hasUnsavedChanges = true
        cancelSnapshotPreviewPreparationTasks()
        if snapshotCompareSession != nil {
            snapshotCompareSession = nil
            resumeTimelapseAfterSnapshotCompareIfNeeded()
        }
        showStatus(.init(kind: .info, message: "已清空全部快照"))
    }

    func deleteSavedSnapshot(_ id: UUID) {
        guard let index = savedSnapshots.firstIndex(where: { $0.id == id }) else {
            return
        }
        savedSnapshots.remove(at: index)
        hasUnsavedChanges = true
        cancelSavedSnapshotPreviewPreparationTask(for: id)
        snapshotCompareSession?.removeSnapshot(id)

        if savedSnapshots.isEmpty, snapshotCompareSession != nil {
            snapshotCompareSession = nil
            resumeTimelapseAfterSnapshotCompareIfNeeded()
            showStatus(.init(kind: .info, message: "已删除最后一张快照，并退出快照对比"))
        } else {
            showStatus(.init(kind: .info, message: "已删除快照"))
        }
    }

    func selectSavedSnapshotForCompare(_ id: UUID?) {
        snapshotCompareSession?.selectedSnapshotID = id
    }

    func assignSavedSnapshot(_ id: UUID, to slot: SnapshotCompareSlot) {
        guard savedSnapshot(with: id) != nil else { return }
        snapshotCompareSession?.assignSnapshot(id, to: slot)
        prepareSavedSnapshotPreviewIfNeeded(for: id)
    }

    func clearSavedSnapshotCompareSlot(_ slot: SnapshotCompareSlot) {
        snapshotCompareSession?.clearSlot(slot)
    }

    func applySelectedSavedSnapshotToMainCanvas() {
        guard
            let session = snapshotCompareSession,
            let selectedSnapshotID = session.selectedSnapshotID,
            let savedSnapshot = savedSnapshot(with: selectedSnapshotID)
        else {
            showStatus(.init(kind: .info, message: "请先选择一个快照"))
            return
        }

        do {
            _ = flushBrushEditingBoundary(reason: "applySelectedSavedSnapshotToMainCanvas")
            let labelIndex = savedSnapshotDisplayIndex(for: selectedSnapshotID) ?? savedSnapshots.count
            try appendCompositeSnapshotAsNewLayer(
                savedSnapshot.snapshot,
                named: "快照 \(labelIndex)"
            )
            cancelSnapshotPreviewPreparationTasks()
            snapshotCompareSession = nil
            resumeTimelapseAfterSnapshotCompareIfNeeded(recordCurrentCanvas: true)
            showStatus(.init(kind: .success, message: "已将快照 \(labelIndex) 应用于主画布"))
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func exportSavedSnapshotsToDisk() {
        guard !savedSnapshots.isEmpty else {
            showStatus(.init(kind: .info, message: "当前没有可导出的快照"))
            return
        }

        bootstrap.filePanelService.presentDirectorySelectionPanel(
            title: "选择快照导出文件夹",
            prompt: "导出",
            completion: documentScopedFileSelection { owner, url in
                if let url { owner.exportSavedSnapshots(to: url) }
            }
        )
    }

    private func exportSavedSnapshots(to directoryURL: URL) {
        let defaultDirectoryName = "\(workspace.document.metadata.name)-快照"
        let exportEntries = savedSnapshots.enumerated().map { index, entry in
            (index: index, snapshot: entry.snapshot)
        }
        let boxedExporter = WorkspaceUncheckedBox(bootstrap.pngExporter)
        showStatus(.init(kind: .info, message: "正在导出 \(exportEntries.count) 个快照..."))

        Task { [weak self] in
            guard let self else { return }
            let result = await Task.detached(priority: .utility) {
                Result {
                    for entry in exportEntries {
                        let outputURL = directoryURL
                            .appendingPathComponent("\(defaultDirectoryName)-\(entry.index + 1).png")
                        try boxedExporter.value.export(snapshot: entry.snapshot, to: outputURL)
                    }
                }
            }.value

            do {
                try result.get()
                self.showStatus(.init(kind: .success, message: "已导出 \(exportEntries.count) 个快照"))
            } catch {
                self.showStatus(.init(kind: .error, message: error.localizedDescription))
            }
        }
    }

    func startIdeationSession() {
        guard !isSavingSnapshot, !isPreparingSnapshotCompare else {
            showStatus(.init(kind: .info, message: "快照任务完成后再进入方案试探"))
            return
        }
        guard snapshotCompareSession == nil else {
            showStatus(.init(kind: .info, message: "快照对比期间不可进入方案试探"))
            return
        }
        guard ideationSession == nil else {
            showStatus(.init(kind: .info, message: "方案试探已开启"))
            return
        }
        let branchCopies = saturatingMultiply(
            currentLiveSurfaceByteCount(),
            by: 4
        )
        let branchCompositeBytes = saturatingMultiply(
            saturatingMultiply(
                workspace.document.canvasSize.width,
                by: workspace.document.canvasSize.height
            ),
            by: 4
        )
        guard ensureDocumentResourceBudget(
            additionalWorkingBytes: saturatingAdd(branchCopies, branchCompositeBytes),
            action: "进入方案试探"
        ) else { return }

        do {
            _ = flushBrushEditingBoundary(reason: "startIdeationSession")
            suspendTimelapseForIdeationIfNeeded()
            let sourceWorkspace = bootstrap.workspaceStore.state
            let baseCompositeTexture = try makeVisibleCompositeTexture()
            ideationSession = try IdeationSessionState(
                hostViewModel: self,
                sourceWorkspace: sourceWorkspace,
                sourceLayerSurfaceStore: bootstrap.layerSurfaceStore,
                baseCompositeTexture: baseCompositeTexture,
                metalContext: bootstrap.metalContext,
                sharedMetalServices: bootstrap.sharedMetalServices
            )
            showStatus(.init(kind: .success, message: "已进入方案试探"))
        } catch {
            resumeTimelapseAfterIdeationIfNeeded()
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func cancelIdeationSession() {
        ideationSession = nil
        resumeTimelapseAfterIdeationIfNeeded()
        showStatus(.init(kind: .info, message: "已退出方案试探"))
    }

    func applySelectedIdeationVariantToMainCanvas() {
        guard let ideationSession else { return }

        do {
            _ = ideationSession.activeBranchViewModel.flushBrushEditingBoundary(
                reason: "applySelectedIdeationVariantToMainCanvas.ideationBranch"
            )
            let snapshot = try ideationSession.activeBranchViewModel.makeVisibleCompositeTexture()
            guard let deltaSnapshot = try ideationDeltaSnapshot(
                variantTexture: snapshot,
                baseTexture: ideationSession.baseCompositeTexture
            ) else {
                showStatus(.init(kind: .info, message: "当前方案没有可附加到新图层的可见差异"))
                return
            }
            let slotIndex = ideationSession.selectedBranchIndex + 1
            self.ideationSession = nil
            try appendCompositeSnapshotAsNewLayer(
                deltaSnapshot,
                named: "方案试探 \(slotIndex)"
            )
            resumeTimelapseAfterIdeationIfNeeded(recordCurrentCanvas: true)
            showStatus(.init(kind: .success, message: "已将方案 \(slotIndex) 应用于主画布"))
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func exportIdeationVariantsToDisk() {
        guard ideationSession != nil else { return }
        bootstrap.filePanelService.presentDirectorySelectionPanel(
            title: "选择草图导出文件夹",
            prompt: "导出",
            completion: documentScopedFileSelection { owner, url in
                if let url { owner.exportIdeationVariants(to: url) }
            }
        )
    }

    private func exportIdeationVariants(to directoryURL: URL) {
        guard let ideationSession else { return }
        let defaultDirectoryName = "\(workspace.document.metadata.name)-方案试探"
        let boxedExporter = WorkspaceUncheckedBox(bootstrap.pngExporter)
        let boxedSerializer = WorkspaceUncheckedBox(bootstrap.textureSerializer)

        showStatus(.init(kind: .info, message: "正在导出 4 个草图..."))

        do {
            var composites: [(index: Int, texture: MTLTexture)] = []
            composites.reserveCapacity(ideationSession.branches.count)
            for (index, branch) in ideationSession.branches.enumerated() {
                _ = branch.viewModel.flushBrushEditingBoundary(
                    reason: "exportIdeationVariantsToDisk.branch\(index)"
                )
                composites.append(
                    (
                        index: index,
                        texture: try branch.viewModel.makeVisibleCompositeTexture(waitUntilCompleted: false)
                    )
                )
            }
            let boxedComposites = WorkspaceUncheckedBox(composites)

            Task { [weak self] in
                guard let self else { return }
                let result = await Task.detached(priority: .utility) {
                    Result {
                        for entry in boxedComposites.value {
                            let snapshot = try boxedSerializer.value.snapshot(texture: entry.texture)
                            let outputURL = directoryURL
                                .appendingPathComponent("\(defaultDirectoryName)-\(entry.index + 1).png")
                            try boxedExporter.value.export(snapshot: snapshot, to: outputURL)
                        }
                    }
                }.value

                do {
                    try result.get()
                    self.showStatus(.init(kind: .success, message: "已导出 4 个草图"))
                } catch {
                    self.showStatus(.init(kind: .error, message: error.localizedDescription))
                }
            }
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    @discardableResult
    // A true return means the request was accepted, not that data is on disk.
    // Only completion(true) permits a destructive document transition.
    func saveProject(completion: ((Bool) -> Void)? = nil) -> Bool {
        guard !isProjectSaving, !isChoosingProjectSaveLocation else {
            showStatus(.init(kind: .info, message: "正在选择保存位置或保存工程，请稍候"))
            completion?(false)
            return false
        }
        guard canBeginDocumentPersistence(action: "保存工程") else { completion?(false); return false }
        guard !timelapseRecorder.isBusy else {
            pendingManualSaveAfterTimelapse = completion == nil
            showStatus(.init(kind: .info, message: completion == nil
                ? "录像帧写入完成后将立即保存工程" : "正在完成录像写入，请稍后再试"))
            completion?(false)
            return completion == nil
        }
        guard recoveryAutosaveWriteTask == nil else {
            pendingManualSaveAfterRecoveryAutosave = completion == nil
            showStatus(.init(kind: .info, message: completion == nil
                ? "自动恢复写入完成后将立即保存工程" : "正在完成自动恢复写入，请稍后再试"))
            completion?(false)
            return completion == nil
        }
        if let url = currentProjectURL {
            startProjectSave(to: url, completion: completion)
        } else {
            isChoosingProjectSaveLocation = true
            let generation = documentRenderGeneration
            bootstrap.filePanelService.presentProjectSavePanel(defaultName: workspace.document.metadata.name) { [weak self] url in
                guard let self else { completion?(false); return }
                self.isChoosingProjectSaveLocation = false
                guard self.documentRenderGeneration == generation else { completion?(false); return }
                guard let url else {
                    self.showStatus(.init(kind: .info, message: "已取消工程保存，当前内容仍未保存"))
                    completion?(false)
                    return
                }
                self.startProjectSave(to: url, completion: completion)
            }
        }
        return true
    }

    private func startProjectSave(to url: URL, completion: ((Bool) -> Void)?) {
        guard let prepared = prepareProjectSave(to: url) else { completion?(false); return }
        isProjectSaving = true
        showStatus(.init(kind: .info, message: "正在保存工程：\(prepared.url.lastPathComponent)"))
        let persistenceBox = WorkspaceUncheckedBox(bootstrap.persistenceController)
        let captureBox = WorkspaceUncheckedBox(prepared.capture)
        projectSaveTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result {
                    let payload = try persistenceBox.value.materializeProjectPayload(
                        from: captureBox.value
                    )
                    return try persistenceBox.value.writeCapturedProject(payload, to: prepared.url)
                }
            }.value
            guard let self else { completion?(false); return }
            self.projectSaveTask = nil
            let savedCurrentRevision = self.finishProjectSave(prepared, result: result)
            self.isProjectSaving = false
            completion?(savedCurrentRevision)
        }
    }

    private func ensureDocumentResourceBudget(
        additionalPaintLayers: Int = 0,
        additionalMasks: Int = 0,
        additionalSavedSnapshots: Int = 0,
        additionalWorkingBytes: Int = 0,
        replacingReferenceImageAt slotID: Int? = nil,
        with referenceImageAsset: ReferenceImageAsset? = nil,
        action: String
    ) -> Bool {
        if let encodedCount = referenceImageAsset?.encodedImageData?.count,
           encodedCount > bootstrap.archiveReadLimits.maximumUncompressedAssetBytes {
            showStatus(.init(
                kind: .error,
                message: "无法\(action)：单张参考图超过工程格式的安全资产上限"
            ))
            return false
        }
        let referenceBytes = currentReferenceImageByteCounts(
            replacingSlotID: slotID,
            with: referenceImageAsset
        )
        let assessment = bootstrap.documentResourceBudgetPolicy.assess(
            canvasSize: workspace.document.canvasSize,
            paintLayerCount: workspace.document.paintLayers.count + additionalPaintLayers,
            maskCount: workspace.document.paintLayers.filter { $0.mask != nil }.count + additionalMasks,
            savedSnapshotCount: savedSnapshots.count + additionalSavedSnapshots,
            referenceImageBytes: referenceBytes.archive,
            referenceImageResidentBytes: referenceBytes.resident,
            historyResidentBytes: bootstrap.historyController.residentByteCount,
            additionalWorkingBytes: additionalWorkingBytes
        )
        guard !assessment.isSupported else { return true }

        let peak = ByteCountFormatter.string(
            fromByteCount: Int64(clamping: assessment.footprint.estimatedSavePeakBytes),
            countStyle: .memory
        )
        showStatus(.init(
            kind: .error,
            message: "无法\(action)：\(assessment.rejectionReason ?? "超出安全资源范围")（预计保存峰值 \(peak)）"
        ))
        return false
    }

    private func currentReferenceImageByteCounts(
        replacingSlotID: Int? = nil,
        with replacementAsset: ReferenceImageAsset? = nil
    ) -> (archive: Int, resident: Int) {
        referenceImageSlots.reduce(into: (archive: 0, resident: 0)) { total, slot in
            let asset = slot.id == replacingSlotID ? replacementAsset : slot.asset
            guard let asset else { return }
            total.resident = saturatingAdd(total.resident, asset.rgbaPixels.count)
            if let encodedCount = asset.encodedImageData?.count {
                total.archive = saturatingAdd(total.archive, encodedCount)
                total.resident = saturatingAdd(total.resident, encodedCount)
            }
        }
    }

    private func currentLiveSurfaceByteCount() -> Int {
        let pixels = saturatingMultiply(
            workspace.document.canvasSize.width,
            by: workspace.document.canvasSize.height
        )
        let paintBytes = saturatingMultiply(
            saturatingMultiply(pixels, by: workspace.document.paintLayers.count),
            by: 4
        )
        let maskBytes = saturatingMultiply(
            pixels,
            by: workspace.document.paintLayers.filter { $0.mask != nil }.count
        )
        return saturatingAdd(paintBytes, maskBytes)
    }

    private func currentDocumentInteractiveResidentByteCount() -> Int {
        let referenceBytes = currentReferenceImageByteCounts()
        return bootstrap.documentResourceBudgetPolicy.assess(
            canvasSize: workspace.document.canvasSize,
            paintLayerCount: workspace.document.paintLayers.count,
            maskCount: workspace.document.paintLayers.filter { $0.mask != nil }.count,
            savedSnapshotCount: savedSnapshots.count,
            referenceImageBytes: referenceBytes.archive,
            referenceImageResidentBytes: referenceBytes.resident,
            historyResidentBytes: bootstrap.historyController.residentByteCount
        ).footprint.estimatedInteractiveResidentBytes
    }

    private func saturatingMultiply(_ lhs: Int, by rhs: Int) -> Int {
        guard lhs >= 0, rhs >= 0 else { return Int.max }
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? Int.max : value
    }

    private func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        guard lhs >= 0, rhs >= 0 else { return Int.max }
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : value
    }

    private struct PreparedProjectSave {
        var url: URL
        var capture: FrozenProjectCapture
        var savedDocumentName: String
        var editRevision: UInt64
        var documentGeneration: UInt64
    }

    private func prepareProjectSave(to url: URL) -> PreparedProjectSave? {
        guard canBeginDocumentPersistence(action: "保存工程") else {
            return nil
        }
        guard resolveColorAdjustmentSessionIfNeeded(reason: .persistence) else {
            return nil
        }
        guard resolveCurveAdjustmentSessionIfNeeded(reason: .persistence) else {
            return nil
        }
        if straightLineState.phase == .pending,
           !commitPendingStraightLine() {
            return nil
        }
        _ = flushBrushEditingBoundary(reason: "saveProject")
        guard
            straightLineState.phase != .pending,
            !bootstrap.strokeEngine.hasPendingBrushWork,
            !bootstrap.strokeEngine.hasPendingBrushCommitJobs
        else {
            showStatus(.init(kind: .error, message: "仍有笔触尚未完成，工程未保存"))
            return nil
        }
        pauseDrawingStatsTracking()
        let savedDocumentName = Self.projectDisplayName(for: url)

        do {
            let previewTexture = try? makeVisibleCompositeTexture(waitUntilCompleted: false)
            var capture = try bootstrap.persistenceController.freezeProjectCapture(
                referenceImages: try projectReferenceImagePayloads(),
                savedSnapshots: persistentSavedSnapshotPayloads(),
                previewTexture: previewTexture
            )
            // The live document name/path change only after the archive is safely written.
            capture.workspace.document.metadata.name = savedDocumentName
            return PreparedProjectSave(
                url: url,
                capture: capture,
                savedDocumentName: savedDocumentName,
                editRevision: documentEditRevision,
                documentGeneration: documentRenderGeneration
            )
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
            return nil
        }
    }

    private func finishProjectSave(
        _ prepared: PreparedProjectSave,
        result: Result<ProjectWriteOutcome, Error>
    ) -> Bool {
        guard prepared.documentGeneration == documentRenderGeneration else { return false }
        do {
            let outcome = try result.get()
            let previewPNGData = outcome.previewPNGData
            currentProjectURL = prepared.url
            bootstrap.workspaceStore.updateDocument { $0.metadata.name = prepared.savedDocumentName }
            let thumbnailApplied = previewPNGData.map {
                bootstrap.filePanelService.applyProjectThumbnail($0, to: prepared.url)
            } ?? false
            if documentEditRevision == prepared.editRevision {
                hasUnsavedChanges = false
                try? bootstrap.persistenceController.discardRecoveryProject()
                hasRecoveryProject = false
            }
            refreshDocumentOverlayOnly()
            persistBrushLibrary()
            syncTimelapseDocumentContext()
            syncDrawingStatsDocumentContext()
            var suffix = hasUnsavedChanges ? "；保存后又有新改动" : ""
            if previewPNGData != nil, !thumbnailApplied {
                suffix += "；Finder 缩略图更新失败"
            }
            if let versionBackupWarning = outcome.versionBackupWarning {
                suffix += "；\(versionBackupWarning)"
            }
            showStatus(.init(
                kind: .success,
                message: "已保存工程：\(prepared.url.lastPathComponent)\(suffix)"
            ))
            return !hasUnsavedChanges
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
            return false
        }
    }

    func openProject() {
        guard canBeginDocumentPersistence(action: "打开工程") else {
            return
        }
        guard !isChoosingProjectToOpen else { return }
        isChoosingProjectToOpen = true
        bootstrap.filePanelService.presentProjectOpenPanel { [weak self] url in
            guard let self else { return }
            self.isChoosingProjectToOpen = false
            guard let url else {
                self.showStatus(.init(kind: .info, message: "已取消打开工程"))
                return
            }
            self.beginProjectOpen(from: url, isRecovery: false)
        }
    }

    func openProjectFromExternalURL(_ url: URL) {
        guard let projectURL = FilePanelService.normalizedProjectOpenURL(url) else {
            showStatus(.init(kind: .error, message: "无法识别要打开的 ArtFlex 工程"))
            return
        }
        beginProjectOpen(from: projectURL, isRecovery: false)
    }

    func recoverAutosavedProject() {
        guard bootstrap.persistenceController.hasRecoveryProject else {
            hasRecoveryProject = false
            showStatus(.init(kind: .info, message: "没有可恢复的自动保存工程"))
            return
        }
        beginProjectOpen(from: nil, isRecovery: true)
    }

    func discardAutosavedProject() {
        recoveryAutosaveInvalidationGeneration &+= 1
        recoveryAutosaveGeneration &+= 1
        recoveryAutosaveTask?.cancel()
        recoveryAutosaveTask = nil
        recoveryAutosaveScheduledDeadline = nil
        do {
            try bootstrap.persistenceController.discardRecoveryProject()
            hasRecoveryProject = false
            showStatus(.init(kind: .info, message: "已丢弃自动恢复工程"))
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    private func beginProjectOpen(from url: URL?, isRecovery: Bool) {
        let action = isRecovery ? "恢复工程" : "打开工程"
        guard canBeginDocumentPersistence(action: action) else { return }
        guard !isProjectSaving, recoveryAutosaveWriteTask == nil else {
            showStatus(.init(kind: .info, message: "正在完成工程写入，请稍候再打开其他工程"))
            return
        }
        guard !timelapseRecorder.isBusy else {
            showStatus(.init(kind: .info, message: "正在完成录像帧写入，请稍候再\(action)"))
            return
        }

        continueAfterUnsavedChanges(detail: "打开其他工程前，要先保存当前内容吗？") { [weak self] allowed in
            guard let self, allowed else { return }
            self.loadProjectInBackground(from: url, isRecovery: isRecovery)
        }
    }

    private func loadProjectInBackground(from url: URL?, isRecovery: Bool) {
        let policy = bootstrap.documentResourceBudgetPolicy
        let currentResidentBytes = currentDocumentInteractiveResidentByteCount()
        let persistenceBox = WorkspaceUncheckedBox(bootstrap.persistenceController)
        isProjectOpening = true
        let editRevision = documentEditRevision
        let documentGeneration = documentRenderGeneration
        showStatus(.init(kind: .info, message: isRecovery ? "正在验证并恢复工程…" : "正在验证并打开工程…"))

        projectOpenTask?.cancel()
        projectOpenTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result<(URL, OpenProjectResult), Error> {
                    let preflight: (ProjectOpenInspection) throws -> Void = { inspection in
                        let assessment = policy.assess(
                            canvasSize: inspection.workspace.document.canvasSize,
                            paintLayerCount: inspection.workspace.document.paintLayers.count,
                            maskCount: inspection.workspace.document.paintLayers.filter { $0.mask != nil }.count,
                            savedSnapshotCount: inspection.savedSnapshotCount,
                            referenceImageBytes: inspection.referenceArchiveBytes,
                            referenceImageResidentBytes: inspection.estimatedReferenceResidentBytes
                        )
                        guard assessment.isSupported else {
                            throw PersistenceError.invalidProject(
                                assessment.rejectionReason ?? "工程超出当前设备的安全资源范围"
                            )
                        }
                        let (transitionPeak, overflow) = assessment.footprint.estimatedSavePeakBytes
                            .addingReportingOverflow(currentResidentBytes)
                        guard !overflow, transitionPeak <= policy.maximumSavePeakBytes else {
                            throw PersistenceError.invalidProject(
                                "打开工程时，新旧文档同时驻留会超过安全内存峰值"
                            )
                        }
                    }

                    if isRecovery {
                        let opened = try persistenceBox.value.openBestAvailableRecoveryProject(
                            preflight: preflight
                        )
                        return (opened.url, opened.result)
                    }
                    guard let url else { throw CocoaError(.fileNoSuchFile) }
                    return (
                        url,
                        try persistenceBox.value.openProject(from: url, preflight: preflight)
                    )
                }
            }.value

            guard let self, !Task.isCancelled else { return }
            self.projectOpenTask = nil
            self.isProjectOpening = false
            guard self.documentEditRevision == editRevision,
                  self.documentRenderGeneration == documentGeneration else {
                self.showStatus(.init(kind: .info, message: "打开期间当前画布发生变化，已保留当前工程；请重新打开"))
                return
            }
            do {
                let opened = try result.get()
                try self.applyOpenedProjectResult(
                    opened.1,
                    sourceURL: opened.0,
                    isRecovery: isRecovery
                )
            } catch {
                self.showStatus(.init(kind: .error, message: error.localizedDescription))
            }
        }
    }

    func openProject(from url: URL, isRecovery: Bool) {
        beginProjectOpen(from: url, isRecovery: isRecovery)
    }

    private func applyOpenedProjectResult(
        _ result: OpenProjectResult,
        sourceURL: URL,
        isRecovery: Bool
    ) throws {
        let existingWorkspace = bootstrap.workspaceStore.state
        var openedWorkspace = Self.workspaceForOpenedProject(
            result.workspace,
            currentWorkspace: existingWorkspace
        )
        if !isRecovery {
            openedWorkspace.document.metadata.name = Self.projectDisplayName(for: sourceURL)
        }
        let stagedLayerTextures = try stageOpenedProjectTextures(
            result.layerSnapshots,
            canvasSize: openedWorkspace.document.canvasSize
        )

        _ = drainPendingBrushCommitsIfNeeded(resetLiveSession: true)
        pauseDrawingStatsTracking()
        cancelColorAdjustmentSessionIfNeeded(showFeedback: false)
        cancelCurveAdjustmentIfNeeded(showFeedback: false)
        resolveTransformSession(reason: .documentOpen)
        resetTransientDocumentInteractionsForReplacement()
        timelapseRecorder.stopRecording()
        resetSnapshotToolState(resumeTimelapseIfNeeded: false)
        perspectiveGuideMatchState = .init()
        bootstrap.workspaceStore.replaceState(openedWorkspace)
        _ = synchronizeTipImageLibraryFromWorkspace(persistIfChanged: false)
        Self.normalizeLegacySelectionIfNeeded(in: bootstrap.workspaceStore)
        bootstrap.layerSurfaceStore.reset()
        _ = bootstrap.layerSurfaceStore.surfaceRecords(
            for: bootstrap.workspaceStore.state.document
        )

        for stagedLayer in stagedLayerTextures {
            switch stagedLayer.resourceKind {
            case .content:
                guard let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: stagedLayer.layerID) else {
                    throw PersistenceError.invalidProject(
                        "无法恢复图层 \(stagedLayer.layerID.rawValue.uuidString)"
                    )
                }
                bootstrap.layerSurfaceStore.swapTexture(for: surfaceID, with: stagedLayer.texture)
            case .mask:
                bootstrap.layerSurfaceStore.setMaskTexture(stagedLayer.texture, for: stagedLayer.layerID)
            }
        }
        bootstrap.textureSerializer.purgeStagingTextures(
            exceeding: bootstrap.workspaceStore.state.document.canvasSize
        )

        publishDocumentReplacementRenderState()

        bootstrap.historyController.resetHistory()
        restoreProjectReferenceImages(result.referenceImages)
        restorePersistentSavedSnapshots(result.savedSnapshots)
        currentProjectURL = isRecovery || result.storageFormat == .legacyJSON ? nil : sourceURL
        // Opening is read-only. Finder metadata is updated only after a successful save.
        hasUnsavedChanges = isRecovery
        persistBrushLibrary()
        syncTimelapseDocumentContext()
        syncDrawingStatsDocumentContext()
        showStatus(.init(
            kind: .success,
            message: isRecovery
                ? "已恢复自动保存工程，请另存为正式工程"
                : result.storageFormat == .legacyJSON
                    ? "已打开旧版工程，保存时请另存为 .artflex：\(sourceURL.lastPathComponent)"
                    : "已打开工程：\(sourceURL.lastPathComponent)"
        ))
        refresh()
    }

    private func stageOpenedProjectTextures(
        _ snapshots: [LayerHistorySnapshot],
        canvasSize: CanvasSize
    ) throws -> [(layerID: LayerID, resourceKind: LayerHistoryResourceKind, texture: MTLTexture)] {
        try snapshots.map { layerSnapshot in
            guard let texture = bootstrap.layerSurfaceStore.makeTexture(
                width: canvasSize.width,
                height: canvasSize.height,
                pixelFormat: layerSnapshot.resourceKind == .mask ? .r8Unorm : .bgra8Unorm_srgb,
                metal: bootstrap.metalContext
            ) else {
                throw PersistenceError.invalidProject("无法为图层准备纹理")
            }
            try bootstrap.textureSerializer.restore(
                snapshot: layerSnapshot.texture,
                into: texture
            )
            return (layerSnapshot.layerID, layerSnapshot.resourceKind, texture)
        }
    }

    private func projectReferenceImagePayloads() throws -> [ProjectReferenceImagePayload] {
        try referenceImageSlots.compactMap { slot in
            guard
                slot.id != luminosityReferenceSlotID,
                let asset = slot.asset,
                let encodedImageData = asset.encodedImageData
            else {
                return nil
            }
            return try ProjectReferenceImagePayload(
                slotIndex: slot.id,
                displayName: asset.fileName,
                originalFilename: asset.fileName,
                typeIdentifier: asset.typeIdentifier,
                pixelWidth: asset.width,
                pixelHeight: asset.height,
                encodedImageData: encodedImageData
            )
        }
    }

    private func persistentSavedSnapshotPayloads() -> [PersistentCanvasSnapshotPayload] {
        let canvasSize = workspace.document.canvasSize
        return savedSnapshots.prefix(Self.maxSavedSnapshotCount).map { savedSnapshot in
            PersistentCanvasSnapshotPayload(
                descriptor: PersistentCanvasSnapshotDescriptor(
                    id: savedSnapshot.id,
                    displayName: savedSnapshot.displayName,
                    createdAt: savedSnapshot.createdAt,
                    canvasSize: canvasSize,
                    pixelResourceID: CanvasPixelResourceID()
                ),
                pixels: savedSnapshot.snapshot
            )
        }
    }

    private func restorePersistentSavedSnapshots(
        _ payloads: [PersistentCanvasSnapshotPayload]
    ) {
        cancelPendingSnapshotSave()
        cancelPendingSnapshotComparePreparation(resumeTimelapseIfNeeded: false)
        cancelSnapshotPreviewPreparationTasks()
        snapshotCompareSession = nil
        savedSnapshots = payloads
            .prefix(Self.maxSavedSnapshotCount)
            .map { payload in
                CanvasSavedSnapshot(
                    id: payload.descriptor.id,
                    displayName: payload.descriptor.displayName,
                    createdAt: payload.descriptor.createdAt,
                    snapshot: payload.pixels,
                    thumbnailImage: Self.snapshotImage(
                        from: payload.pixels,
                        maxDimension: Self.savedSnapshotThumbnailDimension
                    )
                )
            }
    }

    private func restoreProjectReferenceImages(_ payloads: [ProjectReferenceImagePayload]) {
        referenceImageUpgradeTasks.values.forEach { $0.cancel() }
        referenceImageUpgradeTasks.removeAll()
        luminosityCaptureTask?.cancel()
        luminosityCaptureTask = nil
        isCanvasLuminosityReferenceActive = false
        luminosityReferenceSlotID = nil
        referenceImageLoadingSlotIDs.removeAll()
        referenceImageSlots = Self.makeDefaultReferenceImageSlots()
        selectedReferenceImageSlotID = nil
        referenceImagePreviewColor = nil

        for payload in payloads.sorted(by: {
            $0.descriptor.slotIndex < $1.descriptor.slotIndex
        }) {
            let slotID = payload.descriptor.slotIndex
            guard referenceImageSlots.indices.contains(slotID) else { continue }
            guard let asset = ReferenceImageAsset.decode(
                from: payload.encodedImageData,
                fileName: payload.descriptor.originalFilename,
                maxDimension: 768
            ) else {
                continue
            }
            replaceReferenceImageSlotAsset(asset, at: slotID)
            if selectedReferenceImageSlotID == nil {
                selectedReferenceImageSlotID = slotID
            }
        }
    }

    private func scheduleRecoveryAutosave(delay: Duration = .seconds(30)) {
        let clock = ContinuousClock()
        let now = clock.now
        if recoveryAutosaveForcedDeadline == nil {
            recoveryAutosaveForcedDeadline = now.advanced(
                by: Self.recoveryAutosaveMaximumDeferral
            )
        }
        let deadline = resolvedRecoveryAutosaveDeadline(
            now: now,
            delay: delay,
            forcedDeadline: recoveryAutosaveForcedDeadline,
            scheduledDeadline: recoveryAutosaveScheduledDeadline
        )
        recoveryAutosaveScheduledDeadline = deadline
        recoveryAutosaveGeneration &+= 1
        let generation = recoveryAutosaveGeneration
        recoveryAutosaveTask?.cancel()
        recoveryAutosaveTask = Task { [weak self] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            guard
                let self,
                self.hasUnsavedChanges,
                self.recoveryAutosaveGeneration == generation
            else { return }
            self.recoveryAutosaveTask = nil
            self.recoveryAutosaveScheduledDeadline = nil
            self.performRecoveryAutosave(generation: generation)
        }
    }

    func applicationDidResignActiveForPersistence() {
        pauseDrawingStatsTracking()
        guard hasUnsavedChanges else { return }
        scheduleRecoveryAutosave(delay: .zero)
    }

    private func performRecoveryAutosave(generation: UInt64) {
        guard hasUnsavedChanges else { return }
        guard !timelapseRecorder.isBusy else {
            recoveryAutosaveWaitingForTimelapse = true
            return
        }
        recoveryAutosaveWaitingForTimelapse = false
        guard !isProjectSaving, !isChoosingProjectSaveLocation, projectSaveTask == nil else {
            scheduleRecoveryAutosave(delay: .seconds(15))
            return
        }
        guard recoveryAutosaveWriteTask == nil else {
            scheduleRecoveryAutosave(delay: .seconds(15))
            return
        }
        guard
            !isApplyingPatternPlacementCommit,
            !isApplyingGradientCommit,
            !isApplyingTransformCommit,
            !isBucketFillInProgress,
            !isSavingSnapshot,
            !isPreparingSnapshotCompare,
            !isRasterExporting,
            !isTransformingSelection,
            patternPlacementPhase.draft == nil,
            linearGradientState.phase == .idle,
            sectorGradientState.phase == .idle,
            straightLineState.phase != .pending,
            colorAdjustmentSession == nil,
            curveAdjustmentSession == nil,
            !bootstrap.strokeEngine.hasPendingBrushWork
        else {
            scheduleRecoveryAutosave(delay: .seconds(15))
            return
        }

        if bootstrap.strokeEngine.hasPendingBrushCommitJobs {
            let now = ContinuousClock().now
            if let forcedDeadline = recoveryAutosaveForcedDeadline,
               now < forcedDeadline {
                scheduleRecoveryAutosave(delay: .seconds(15))
                return
            }

            // Recent brush jobs are intentionally retained for short-lived
            // post-stroke adjustment. Once maximum autosave deferral expires,
            // commit them at this idle boundary so recovery can represent the
            // visible canvas instead of retrying forever.
            isSuppressingRecoveryAutosaveScheduling = true
            _ = flushBrushEditingBoundary(reason: "recoveryAutosave.maximumDeferral")
            isSuppressingRecoveryAutosaveScheduling = false
            guard !bootstrap.strokeEngine.hasPendingBrushCommitJobs else {
                scheduleRecoveryAutosave(delay: .seconds(15))
                return
            }
        }

        do {
            // The main actor performs only one private-to-private Metal copy. Pixel readback,
            // checksums, compression, and disk I/O continue on the utility task.
            let capture = try bootstrap.persistenceController.freezeProjectCapture(
                referenceImages: try projectReferenceImagePayloads(),
                savedSnapshots: persistentSavedSnapshotPayloads()
            )
            let stagingURL = try bootstrap.persistenceController.makeRecoveryStagingURL()
            let persistenceBox = WorkspaceUncheckedBox(bootstrap.persistenceController)
            let invalidationGeneration = recoveryAutosaveInvalidationGeneration

            recoveryAutosaveWriteTask = Task { [weak self] in
                let result = await Task.detached(priority: .utility) {
                    Result {
                        let payload = try persistenceBox.value.materializeProjectPayload(
                            from: capture
                        )
                        _ = try persistenceBox.value.writeCapturedProject(
                            payload,
                            to: stagingURL,
                            recordsVersionBackup: false
                        )
                    }
                }.value

                guard let self else {
                    persistenceBox.value.discardRecoveryStagingProject(at: stagingURL)
                    return
                }
                self.recoveryAutosaveWriteTask = nil
#if DEBUG
                self.debugRecoveryAutosaveBeforeInstall?()
#endif
                defer {
                    if self.pendingManualSaveAfterRecoveryAutosave {
                        self.pendingManualSaveAfterRecoveryAutosave = false
                        _ = self.saveProject()
                    }
                }

                guard
                    self.hasUnsavedChanges,
                    self.recoveryAutosaveInvalidationGeneration == invalidationGeneration
                else {
                    persistenceBox.value.discardRecoveryStagingProject(at: stagingURL)
                    return
                }

                do {
                    try result.get()
                    try persistenceBox.value.installRecoveryProject(from: stagingURL)
                    self.hasRecoveryProject = true
                    self.recoveryAutosaveForcedDeadline = ContinuousClock().now.advanced(
                        by: Self.recoveryAutosaveMaximumDeferral
                    )
                    if self.recoveryAutosaveGeneration != generation {
                        // Preserve this complete recovery point, then catch up to newer edits.
                        self.scheduleRecoveryAutosave()
                    }
                } catch {
                    persistenceBox.value.discardRecoveryStagingProject(at: stagingURL)
                    self.showStatus(.init(kind: .error, message: "自动恢复保存失败，已有副本保留；请手动保存工程：\(error.localizedDescription)"))
                    self.scheduleRecoveryAutosave(delay: .seconds(30))
                }
            }
        } catch {
            showStatus(.init(kind: .error, message: "无法准备自动恢复副本；请手动保存工程：\(error.localizedDescription)"))
            scheduleRecoveryAutosave(delay: .seconds(30))
        }
    }

    private func resumePersistenceAfterTimelapseBecameIdle() {
        if pendingManualSaveAfterTimelapse {
            pendingManualSaveAfterTimelapse = false
            _ = saveProject()
            return
        }
        if recoveryAutosaveWaitingForTimelapse {
            recoveryAutosaveWaitingForTimelapse = false
            scheduleRecoveryAutosave(delay: .zero)
        }
    }

    private func canBeginDocumentPersistence(action: String) -> Bool {
        guard !isProjectSaving, !isChoosingProjectSaveLocation else {
            showStatus(.init(kind: .info, message: "工程正在保存，请稍候再\(action)"))
            return false
        }
        guard !bootstrap.filePanelService.isPresentingDialog else {
            showStatus(.init(kind: .info, message: "请先完成或取消当前文件窗口，再\(action)"))
            return false
        }
        guard !isProjectOpening else {
            showStatus(.init(kind: .info, message: "工程正在打开，请稍候"))
            return false
        }
        guard
            !isApplyingPatternPlacementCommit,
            !isApplyingGradientCommit,
            !isApplyingTransformCommit,
            !isBucketFillInProgress
        else {
            showStatus(.init(kind: .info, message: "正在完成画布操作，请稍后再\(action)"))
            return false
        }
        guard !isTransformingSelection else {
            showStatus(.init(kind: .info, message: "请先确认或取消自由变形，再\(action)"))
            return false
        }
        guard !isSavingSnapshot, !isPreparingSnapshotCompare, !isRasterExporting else {
            showStatus(.init(kind: .info, message: "正在完成快照或导出，请稍后再\(action)"))
            return false
        }
        guard patternPlacementPhase.draft == nil else {
            showStatus(.init(kind: .info, message: "请先确认或取消图案放置，再\(action)"))
            return false
        }
        guard linearGradientState.phase == .idle, sectorGradientState.phase == .idle else {
            showStatus(.init(kind: .info, message: "请先应用或取消渐变，再\(action)"))
            return false
        }
        guard canvasCropState.bounds == nil else {
            showStatus(.init(kind: .info, message: "请先应用或取消画布裁剪，再\(action)"))
            return false
        }
        return true
    }

    private func resetTransientDocumentInteractionsForReplacement() {
        isRasterExportSheetPresented = false
        finishRasterExportPresentation()
        imagePaletteExtractor.cancel()
        cancelBlockReferenceInteraction()
        blockReferenceWorkflow = .init()
        blockReferenceEditorState = .init()
        patternPlacementPhase = .idle
        straightLineState = .init()
        linearGradientState = .init()
        sectorGradientState = .init()
        polygonSelectionState = .init()
        deferredGradientAction = nil
        canvasCropState.cancel()
        textureFillGestureState = nil
        activeLassoRawPoints = []
        activeLassoPreviewPoints = []
        activeLassoBounds = nil
        lassoSamplingDebugPoints = []
        isGeneratorRegionSelectionArmed = false
        isGeneratorStrokeModeEnabled = false
        generatorStrokeSession = .init()
    }

    func createNewCanvas(
        name: String = "未命名",
        canvasSize: CanvasSize,
        resolutionDPI: Int
    ) {
        createNewCanvas(
            name: name,
            canvasSize: canvasSize,
            resolutionDPI: resolutionDPI,
            decisionOverride: nil
        )
    }

    func createNewCanvasDiscardingUnsavedChanges(
        name: String = "未命名",
        canvasSize: CanvasSize,
        resolutionDPI: Int
    ) {
        createNewCanvas(
            name: name,
            canvasSize: canvasSize,
            resolutionDPI: resolutionDPI,
            decisionOverride: .discard
        )
    }

    private func createNewCanvas(
        name: String,
        canvasSize: CanvasSize,
        resolutionDPI: Int,
        decisionOverride: NewCanvasCreationDecision?
    ) {
        guard !isDocumentTransitionPending,
              canBeginDocumentPersistence(action: "新建画布") else { return }
        let capacity = canvasCapacityPolicy.assess(canvasSize)
        guard capacity.isSupported else {
            showStatus(.init(
                kind: .error,
                message: capacity.rejectionReason ?? "当前画布尺寸超出安全上限"
            ))
            return
        }
        pauseDrawingStatsTracking()
        guard resolveColorAdjustmentSessionIfNeeded(reason: .documentOpen) else { return }
        guard resolveCurveAdjustmentSessionIfNeeded(reason: .documentOpen) else { return }
        resolveTransformSession(reason: .documentOpen)

        guard let decision = decisionOverride else {
            continueAfterUnsavedChanges(detail: "创建新画布前，要先保存当前内容吗？") { [weak self] allowed in
                guard let self, allowed else { return }
                self.createNewCanvas(name: name, canvasSize: canvasSize, resolutionDPI: resolutionDPI, decisionOverride: .discard)
            }
            return
        }
        switch decision {
        case .cancel:
            return
        case .save:
            saveProject { [weak self] saved in
                guard let self, saved else { return }
                self.createNewCanvas(name: name, canvasSize: canvasSize, resolutionDPI: resolutionDPI, decisionOverride: .discard)
            }
            return
        case .discard:
            _ = flushBrushEditingBoundary(reason: "createNewCanvas.discard")
            break
        }

        timelapseRecorder.stopRecording()
        resetTransientDocumentInteractionsForReplacement()
        resetSnapshotToolState(resumeTimelapseIfNeeded: false)
        perspectiveGuideMatchState = .init()

        let now = Date()
        let layers = ArtDocument.stageOneDefaultLayers()
        var resetToolSession = workspace.toolSession
        resetToolSession.brush.size = ToolSessionState.stageOneDefault.brush.size
        resetToolSession.brush.opacity = BrushSettings.stageOneDefault.opacity
        resetToolSession.washOilPaintReservoir()
        let document = ArtDocument(
            metadata: DocumentMetadata(
                name: name,
                createdAt: now,
                updatedAt: now,
                resolutionDPI: resolutionDPI
            ),
            canvasSize: canvasSize,
            layers: layers,
            activeLayerID: layers.last?.id ?? layers[0].id
        )

        let newWorkspace = WorkspaceState(
            document: document,
            toolSession: resetToolSession,
            colorPanel: workspace.colorPanel,
            brushLibrary: workspace.brushLibrary,
            patternLibrary: workspace.patternLibrary,
            textureFillLibrary: workspace.textureFillLibrary,
            blockReferenceModuleLibrary: workspace.blockReferenceModuleLibrary,
            tipImageLibrary: workspace.tipImageLibrary,
            generator: workspace.generator,
            viewport: .stageOneDefault,
            selection: .empty
        )

        bootstrap.workspaceStore.replaceState(newWorkspace)
        bootstrap.layerSurfaceStore.reset()
        bootstrap.layerSurfaceStore.prepareTextures(
            for: newWorkspace.document,
            metal: bootstrap.metalContext
        )
        seedDefaultBackgroundLayerIfNeeded(for: newWorkspace.document)
        bootstrap.textureSerializer.purgeStagingTextures(exceeding: newWorkspace.document.canvasSize)
        publishDocumentReplacementRenderState()
        bootstrap.historyController.resetHistory()

        currentProjectURL = nil
        hasUnsavedChanges = true
        isNewCanvasSheetPresented = false
        syncTimelapseDocumentContext()
        syncDrawingStatsDocumentContext()
        showStatus(.init(kind: .success, message: "已创建新画布：\(canvasSize.width)×\(canvasSize.height)"))
        refresh()
    }

    /// Publishes one rendering boundary after replacing the workspace and all layer
    /// textures. A normal redraw revision is insufficient because an existing Metal
    /// view can retain surface identifiers from the former document.
    private func publishDocumentReplacementRenderState() {
        recoveryAutosaveInvalidationGeneration &+= 1
        recoveryAutosaveGeneration &+= 1
        recoveryAutosaveTask?.cancel()
        recoveryAutosaveTask = nil
        recoveryAutosaveScheduledDeadline = nil
        recoveryAutosaveForcedDeadline = nil
        bootstrap.strokeEngine.resetBrushPipelineState()
        clearRecentBrushAdjustmentState()
        invalidateWholeLayerInteractionBoundsCache()
        documentChangeRevision &+= 1
        canvasContentRevision = documentChangeRevision
        strokeResetToken &+= 1
        documentRenderGeneration &+= 1
    }

    private func seedDefaultBackgroundLayerIfNeeded(for document: ArtDocument) {
        guard
            let backgroundLayer = document.layers.first(where: { $0.name == LayerRecord.defaultBackgroundLayerName }),
            backgroundLayer.name == LayerRecord.defaultBackgroundLayerName,
            let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: backgroundLayer.id),
            let texture = bootstrap.layerSurfaceStore.texture(for: surfaceID)
        else {
            return
        }

        let snapshot = Self.solidColorSnapshot(
            width: document.canvasSize.width,
            height: document.canvasSize.height,
            blue: 255,
            green: 255,
            red: 255,
            alpha: 255
        )

        do {
            try bootstrap.textureSerializer.restore(snapshot: snapshot, into: texture)
            bootstrap.layerSurfaceStore.markContentUnknown(for: backgroundLayer.id)
            layerThumbnailCache.removeValue(forKey: backgroundLayer.id)
        } catch {
            return
        }
    }

    private static func solidColorSnapshot(
        width: Int,
        height: Int,
        blue: UInt8,
        green: UInt8,
        red: UInt8,
        alpha: UInt8
    ) -> LayerTextureSnapshot {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        for offset in stride(from: 0, to: pixels.count, by: 4) {
            pixels[offset] = blue
            pixels[offset + 1] = green
            pixels[offset + 2] = red
            pixels[offset + 3] = alpha
        }

        return LayerTextureSnapshot(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            pixelData: Data(pixels)
        )
    }

    private static func makeSceneSnapshot(
        workspace: WorkspaceState,
        bootstrap: AppBootstrap,
        canvasContentRevision: UInt64,
        selectionRevision: UInt64,
        viewportRevision: UInt64
    ) -> CanvasSceneSnapshot {
        let surfaces = bootstrap.layerSurfaceStore.surfaceRecords(for: workspace.document)
        let activeSurface = surfaces.first { $0.layerID == workspace.document.activeLayerID }
        var renderDocument = workspace.document
        renderDocument.perspectiveGuide = nil
        renderDocument.blockReferenceScene = nil

        return CanvasSceneSnapshot(
            renderSnapshot: CanvasRenderSnapshot(
                document: renderDocument,
                viewport: workspace.viewport,
                canvasContentRevision: canvasContentRevision,
                viewportRevision: viewportRevision
            ),
            layerSurfaces: surfaces,
            activeLayerSurfaceID: activeSurface?.surfaceID,
            selectionShape: workspace.selection.committedShape,
            selectionRevision: selectionRevision
        )
    }

    private enum NewCanvasCreationDecision {
        case save
        case discard
        case cancel
    }

    private enum BrushLibraryImportMode {
        case replace
        case append
    }

    private func importBrushLibrary(mode: BrushLibraryImportMode) {
        bootstrap.filePanelService.presentBrushLibraryImportPanel(completion: documentScopedFileSelection { owner, url in
            if let url { owner.importBrushLibrary(from: url, mode: mode) }
        })
    }

    private func importBrushLibrary(from url: URL, mode: BrushLibraryImportMode) {
        do {
            let imported = try bootstrap.brushLibraryPersistenceController.importLibrary(from: url)
            _ = applyImportedBrushLibraryResources(
                imported,
                replacingExistingLibrary: mode == .replace
            )
            persistBrushLibrary()
            refresh()
            let message = mode == .replace ? "已替换画笔库" : "已追加导入画笔库"
            showStatus(.init(kind: .success, message: message))
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    @discardableResult
    func applyImportedBrushLibraryResources(
        _ imported: PersistedBrushResources,
        replacingExistingLibrary: Bool
    ) -> Bool {
        let previousSelectedPresetID = bootstrap.workspaceStore.state.brushLibrary.selectedPresetID
        let normalizedLibrary = Self.normalizeImportedBrushLibrary(imported.library)
        let normalizedTipImageLibrary = Self.normalizeImportedTipImageLibrary(imported.tipImageLibrary)

        bootstrap.workspaceStore.updateBrushLibrary { library in
            let resolvedLibrary = (
                replacingExistingLibrary
                ? normalizedLibrary
                : Self.mergeBrushLibraries(base: library, imported: normalizedLibrary)
            )
            .removingLikelyAutoSavedDuplicatePresets()
            .removingRetiredBrushDemoPresets()
            library = resolvedLibrary
            if library.selectedPresetID == nil {
                library.selectedPresetID = library.presets.first?.id
            }
        }
        bootstrap.workspaceStore.updateTipImageLibrary { tipImageLibrary in
            if replacingExistingLibrary {
                tipImageLibrary = normalizedTipImageLibrary
            } else {
                tipImageLibrary = Self.mergeTipImageLibraries(
                    base: tipImageLibrary,
                    imported: normalizedTipImageLibrary
                )
            }
        }

        let didRealignCurrentBrush = synchronizeCurrentBrushToSelectedPresetIfNeeded(
            previousSelectedPresetID: previousSelectedPresetID,
            force: replacingExistingLibrary
        )
        _ = synchronizeTipImageLibraryFromWorkspace(persistIfChanged: false)
        return didRealignCurrentBrush
    }

    private nonisolated static func normalizeImportedBrushLibrary(_ library: BrushLibraryState) -> BrushLibraryState {
        var seen = Set<String>()
        var presets: [BrushPreset] = []

        for preset in library.presets {
            var normalized = preset
            if seen.contains(normalized.id) {
                normalized = BrushPreset(
                    id: UUID().uuidString,
                    name: normalized.name,
                    brush: normalized.brush,
                    isBuiltIn: false,
                    slotIndex: normalized.slotIndex
                )
            } else {
                normalized.isBuiltIn = normalized.id == BrushPreset.pressureGrainCrayonPresetID
            }
            seen.insert(normalized.id)
            presets.append(normalized)
        }

        let selectedPresetID = presets.contains(where: { $0.id == library.selectedPresetID }) ? library.selectedPresetID : presets.first?.id
        return BrushLibraryState(
            presets: presets,
            selectedPresetID: selectedPresetID
        ).removingLikelyAutoSavedDuplicatePresets()
    }

    private nonisolated static func mergeBrushLibraries(base: BrushLibraryState, imported: BrushLibraryState) -> BrushLibraryState {
        var merged = base
        var existingIDs = Set(merged.presets.map(\.id))

        for preset in imported.presets {
            let normalizedID = existingIDs.contains(preset.id) ? UUID().uuidString : preset.id
            let normalized = BrushPreset(
                id: normalizedID,
                name: preset.name,
                brush: preset.brush,
                isBuiltIn: false,
                slotIndex: preset.slotIndex
            )
            existingIDs.insert(normalized.id)
            merged.presets.append(normalized)
        }

        if merged.selectedPresetID == nil {
            merged.selectedPresetID = imported.selectedPresetID ?? merged.presets.first?.id
        }
        return merged
    }

    private nonisolated static func normalizeImportedTipImageLibrary(_ library: TipImageLibraryState) -> TipImageLibraryState {
        library.normalizedMergingDuplicates()
    }

    private nonisolated static func mergeTipImageLibraries(
        base: TipImageLibraryState,
        imported: TipImageLibraryState
    ) -> TipImageLibraryState {
        var merged = base
        _ = merged.mergeItems(from: imported.normalizedMergingDuplicates())
        return merged
    }

    nonisolated static func workspaceForOpenedProject(
        _ openedWorkspace: WorkspaceState,
        currentWorkspace: WorkspaceState
    ) -> WorkspaceState {
        var resolvedWorkspace = openedWorkspace
        resolvedWorkspace.brushLibrary = currentWorkspace.brushLibrary
        resolvedWorkspace.patternLibrary = currentWorkspace.patternLibrary
        resolvedWorkspace.textureFillLibrary = currentWorkspace.textureFillLibrary
        resolvedWorkspace.blockReferenceModuleLibrary = currentWorkspace.blockReferenceModuleLibrary
        resolvedWorkspace.tipImageLibrary = mergeTipImageLibraries(
            base: currentWorkspace.tipImageLibrary,
            imported: normalizeImportedTipImageLibrary(openedWorkspace.tipImageLibrary)
        )
        return resolvedWorkspace
    }

    @discardableResult
    private func restorePersistedTipImageLibraryIfAvailable() -> Bool {
        guard let restored = bootstrap.brushLibraryPersistenceController.loadResources() else {
            return false
        }

        let normalizedTipImageLibrary = Self.normalizeImportedTipImageLibrary(restored.tipImageLibrary)
        var changed = false
        bootstrap.workspaceStore.updateTipImageLibrary { tipImageLibrary in
            let merged = Self.mergeTipImageLibraries(
                base: tipImageLibrary,
                imported: normalizedTipImageLibrary
            )
            if merged != tipImageLibrary {
                tipImageLibrary = merged
                changed = true
            }
        }
        return changed
    }

    @discardableResult
    private func synchronizeTipImageLibraryFromWorkspace(
        persistIfChanged: Bool
    ) -> Bool {
        let state = bootstrap.workspaceStore.state
        var brushVariants = [state.toolSession.drawingBrush]
        if state.toolSession.smudgeBrushUsesIndependentSettings {
            brushVariants.append(state.toolSession.smudgeBrush)
        }
        let presetBrushes = state.brushLibrary.presets.map(\.brush)

        var changed = false
        bootstrap.workspaceStore.updateTipImageLibrary { library in
            for brush in brushVariants {
                changed = library.upsertImportedTips(from: brush) || changed
            }
            for brush in presetBrushes {
                changed = library.upsertImportedTips(from: brush) || changed
            }
        }

        if changed, persistIfChanged {
            persistBrushLibrary()
        }
        return changed
    }

    private func persistBrushLibrary() {
        let library = bootstrap.workspaceStore.state.brushLibrary
        let tipImageLibrary = bootstrap.workspaceStore.state.tipImageLibrary
        let controller = bootstrap.brushLibraryPersistenceController
        brushLibraryPersistenceQueue.enqueue {
            try controller.saveResources(
                library: library,
                tipImageLibrary: tipImageLibrary
            )
        } onError: { [weak self] error in
            DispatchQueue.main.async {
                self?.showStatus(.init(kind: .error, message: "保存画笔库失败：\(error.localizedDescription)"))
            }
        }
    }

    private func persistPatternLibrary() {
        let library = bootstrap.workspaceStore.state.patternLibrary
        let controller = bootstrap.patternLibraryPersistenceController
        patternLibraryPersistenceQueue.enqueue {
            try controller.saveLibrary(library)
        } onError: { [weak self] error in
            DispatchQueue.main.async {
                self?.showStatus(.init(kind: .error, message: "保存图案库失败：\(error.localizedDescription)"))
            }
        }
    }

    private func persistTextureFillLibrary() {
        let library = bootstrap.workspaceStore.state.textureFillLibrary
        let controller = bootstrap.textureFillLibraryPersistenceController
        textureFillLibraryPersistenceQueue.enqueue {
            try controller.saveLibrary(library)
        } onError: { [weak self] error in
            DispatchQueue.main.async {
                self?.showStatus(.init(kind: .error, message: "保存纹理库失败：\(error.localizedDescription)"))
            }
        }
    }

    private func persistBlockReferenceModuleLibrary() {
        let library = bootstrap.workspaceStore.state.blockReferenceModuleLibrary
        let controller = bootstrap.blockReferenceModuleLibraryPersistenceController
        blockReferenceModuleLibraryPersistenceQueue.enqueue {
            try controller.saveLibrary(library)
        } onError: { [weak self] error in
            DispatchQueue.main.async {
                self?.showStatus(.init(kind: .error, message: "保存体块库失败：\(error.localizedDescription)"))
            }
        }
    }

    @discardableResult
    private static func restorePersistedBrushLibraryIfAvailable(in bootstrap: AppBootstrap) -> Bool {
        guard let restored = bootstrap.brushLibraryPersistenceController.loadResources() else {
            return false
        }
        let normalizedLibrary = Self.normalizeImportedBrushLibrary(restored.library)
            .removingRetiredBrushDemoPresets()
            .installingOrUpdatingPressureGrainCrayonPresetIfPossible()
        let normalizedTipImageLibrary = Self.normalizeImportedTipImageLibrary(restored.tipImageLibrary)
        bootstrap.workspaceStore.updateBrushLibrary { library in
            library = normalizedLibrary
            if library.selectedPresetID == nil {
                library.selectedPresetID = library.launchDefaultPreset()?.id
            }
        }
        bootstrap.workspaceStore.updateTipImageLibrary { tipImageLibrary in
            tipImageLibrary = normalizedTipImageLibrary
        }
        return normalizedLibrary != restored.library || normalizedTipImageLibrary != restored.tipImageLibrary
    }

    @discardableResult
    private static func applyLaunchDefaultBrushPresetIfNeeded(in workspaceStore: WorkspaceStore) -> Bool {
        guard let firstPreset = workspaceStore.state.brushLibrary.launchDefaultPreset() else {
            return false
        }

        var didChange = false
        if workspaceStore.state.brushLibrary.selectedPresetID != firstPreset.id {
            workspaceStore.updateBrushLibrary { library in
                library.selectedPresetID = firstPreset.id
            }
            didChange = true
        }

        if workspaceStore.state.toolSession.brush != firstPreset.brush {
            workspaceStore.updateToolSession { session in
                session.brush = firstPreset.brush
            }
            didChange = true
        }

        return didChange
    }

    @discardableResult
    private static func restorePersistedPatternLibraryIfAvailable(in bootstrap: AppBootstrap) -> Bool {
        guard let restored = bootstrap.patternLibraryPersistenceController.loadLibrary() else {
            return false
        }

        bootstrap.workspaceStore.updatePatternLibrary { library in
            library = restored.library
            if library.selectedItemID == nil {
                library.selectedItemID = library.items.first?.id
            }
        }

        return restored.didSanitize
    }

    private static func restorePersistedTextureFillLibraryIfAvailable(in bootstrap: AppBootstrap) {
        guard let restored = bootstrap.textureFillLibraryPersistenceController.loadLibrary() else {
            return
        }

        bootstrap.workspaceStore.updateTextureFillLibrary { library in
            library = restored
            if library.selectedItemID == nil {
                library.selectedItemID = library.items.first?.id
            }
        }
    }

    private static func restorePersistedBlockReferenceModuleLibraryIfAvailable(in bootstrap: AppBootstrap) {
        guard let restored = bootstrap.blockReferenceModuleLibraryPersistenceController.loadLibrary() else {
            return
        }
        bootstrap.workspaceStore.updateBlockReferenceModuleLibrary { library in
            library = restored
        }
    }

    @discardableResult
    private func synchronizeCurrentBrushToSelectedPresetIfNeeded(
        previousSelectedPresetID: String?,
        force: Bool = false
    ) -> Bool {
        let state = bootstrap.workspaceStore.state
        let selectedPresetID = state.brushLibrary.selectedPresetID
        guard force || selectedPresetID != previousSelectedPresetID else {
            return false
        }
        guard
            let selectedPresetID,
            let selectedPreset = state.brushLibrary.preset(id: selectedPresetID)
        else {
            return false
        }
        guard state.toolSession.brush != selectedPreset.brush else {
            return false
        }

        bootstrap.strokeEngine.endStroke()
        strokeResetToken &+= 1
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush = selectedPreset.brush
        }
        return true
    }

    private func activateBrushPresetShortcut(slotIndex: Int) -> Bool {
        guard let preset = workspace.brushLibrary.preset(atSlot: slotIndex) else {
            return false
        }
        applyBrushPreset(preset.id, showFeedback: false)
        return true
    }

    func confirmCloseOrQuitIfNeeded(completion: @escaping (Bool) -> Void) {
        guard canBeginDocumentPersistence(action: "退出") else { completion(false); return }
        guard !isRasterExporting else {
            showStatus(.init(kind: .info, message: "正在选择导出位置或写入图片，请完成或取消后再退出"))
            completion(false); return
        }
        pauseDrawingStatsTracking()
        guard resolveColorAdjustmentSessionIfNeeded(reason: .closeOrQuit) else {
            completion(false); return
        }
        guard resolveCurveAdjustmentSessionIfNeeded(reason: .closeOrQuit) else {
            completion(false); return
        }
        _ = flushBrushEditingBoundary(reason: "closeTimelapse")
        timelapseRecorder.stopRecording()
        guard !timelapseRecorder.isBusy else {
            showStatus(.init(kind: .info, message: "正在完成录像写入或导出，请稍候再退出"))
            completion(false); return
        }
        continueAfterUnsavedChanges(detail: "退出前，要先保存当前内容吗？", completion: completion)
    }

    private func continueAfterUnsavedChanges(detail: String, completion: @escaping (Bool) -> Void) {
        guard !isDocumentTransitionPending,
              !isProjectSaving, !isChoosingProjectSaveLocation,
              recoveryAutosaveWriteTask == nil,
              !bootstrap.filePanelService.isPresentingDialog else {
            showStatus(.init(kind: .info, message: "请等待当前文件操作完成；当前工程已保留"))
            completion(false)
            return
        }
        let hasPendingAdjustment =
            colorAdjustmentSession?.hasPendingCommittedEffect == true ||
            curveAdjustmentSession?.hasPendingCommittedEffect == true
        guard hasUnsavedChanges || hasPendingAdjustment || straightLineState.phase == .pending else {
            completion(true)
            return
        }
        isDocumentTransitionPending = true
        let generation = documentRenderGeneration
        let finish: (Bool) -> Void = { [weak self] allowed in
            guard let self else { completion(false); return }
            self.isDocumentTransitionPending = false
            completion(allowed && self.documentRenderGeneration == generation)
        }
        bootstrap.filePanelService.presentUnsavedChangesConfirmation(
            message: "当前画布有未保存内容", detail: detail
        ) { [weak self] response in
            guard let self, self.documentRenderGeneration == generation else { finish(false); return }
            switch response {
            case .alertFirstButtonReturn:
                self.saveProject(completion: finish)
            case .alertSecondButtonReturn:
                finish(true)
            default:
                finish(false)
            }
        }
    }

    nonisolated static func projectDisplayName(for url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        if name.lowercased().hasSuffix(".artflex") {
            name.removeLast(".artflex".count)
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名" : trimmed
    }

    private static func normalizeDisabledToolsIfNeeded(in store: WorkspaceStore) {
        let activeTool = store.state.toolSession.activeTool
        let normalizedTool = normalizedAvailableTool(activeTool)
        guard normalizedTool != activeTool else { return }
        store.updateToolSession { session in
            session.activeTool = normalizedTool
        }
    }

    private static func normalizedViewportRotation(_ angleDegrees: Double) -> Double {
        var normalized = angleDegrees.truncatingRemainder(dividingBy: 360)
        if normalized > 180 {
            normalized -= 360
        } else if normalized <= -180 {
            normalized += 360
        }
        return normalized
    }

    private func currentSceneSnapshot(for state: WorkspaceState) -> CanvasSceneSnapshot {
        var snapshot = WorkspaceViewModel.makeSceneSnapshot(
            workspace: state,
            bootstrap: bootstrap,
            canvasContentRevision: canvasContentRevision,
            selectionRevision: selectionRevision,
            viewportRevision: viewportRevision
        )
        if state.toolSession.activeTool == .freeTransform {
            snapshot.selectionShape = effectiveTransformInteractionShape.map {
                SelectionShape(
                    kind: .rectangle,
                    bounds: $0.bounds,
                    pathPoints: []
                )
            }
        }
        return snapshot
    }

    @discardableResult
    private func resolveTransformSession(reason: TransformResolutionReason) -> Bool {
        switch transformState.resolutionAction(for: reason) {
        case .none:
            return false
        case .applyAndClearSelection:
            applySelectionTransform(clearSelectionAfterApply: true)
        case .cancelAndClearSelection:
            cancelSelectionTransform(clearSelectionAfterCancel: true)
        case .cancelAndPreserveSelection:
            cancelSelectionTransform(clearSelectionAfterCancel: false)
        }

        return true
    }

    private func showStatus(_ status: WorkspaceStatus) {
        self.status = status
        statusDismissTask?.cancel()

        statusDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.status = nil
        }
    }

    func showIdeationSyncError(_ error: Error) {
        showStatus(.init(kind: .error, message: "方案同步失败：\(error.localizedDescription)"))
    }

    func applyIdeationOperation(_ operation: IdeationCanvasOperation) {
        let savedActivityHandler = ideationBranchActivityHandler
        ideationBranchActivityHandler = nil
        isApplyingMirroredIdeationOperation = true
        defer {
            isApplyingMirroredIdeationOperation = false
            ideationBranchActivityHandler = savedActivityHandler
        }

        switch operation {
        case .beginStroke(let paintVariationSeed):
            beginStrokeIfNeeded(paintVariationSeed: paintVariationSeed)
        case .applyStroke(let samples):
            applyStroke(samples: samples)
        case .endStroke:
            endStroke()
            refreshLightweight(reason: "applyIdeationOperation.endStroke")
        case .beginGradientDrag(let point, let modifiers):
            beginGradientDrag(at: point, modifiers: modifiers.eventFlags)
        case .updateGradientDrag(let point, let modifiers):
            updateGradientDrag(to: point, modifiers: modifiers.eventFlags)
        case .endGradientDrag(let point, let modifiers):
            endGradientDrag(at: point, modifiers: modifiers.eventFlags)
        case .enterGradientEditing:
            enterGradientEditingViaShift()
        case .applyGradientSession:
            applyActiveGradientSession()
        case .cancelGradientSession:
            cancelCanvasToolInteraction()
        case .beginStraightLineDrag(
            let point,
            let brushSize,
            let paintVariationSeed,
            let thicknessAdjustmentDeadZone
        ):
            beginStraightLineDrag(
                at: point,
                paintVariationSeed: paintVariationSeed,
                initialBrushSize: brushSize,
                thicknessAdjustmentDeadZone: thicknessAdjustmentDeadZone
            )
        case .updateStraightLineDrag(let points):
            updateStraightLineDrag(along: points)
        case .endStraightLineDrag(let point):
            endStraightLineDrag(at: point)
        case .commitStraightLine:
            _ = commitPendingStraightLine()
        case .cancelStraightLine:
            cancelStraightLineInteraction()
        case .fillAtPoint(let point):
            fillAtPoint(point)
        case .applyCanvasCrop(let bounds):
            canvasCropState.bounds = bounds
            applyCanvasCrop()
        case .handleCanvasToolClick(let point, let modifiers, let clickCount, let paintVariationSeed):
            handleCanvasToolClick(
                at: point,
                modifiers: modifiers.eventFlags,
                clickCount: clickCount,
                paintVariationSeed: paintVariationSeed
            )
        case .beginSelection(let kind, let start, let modifiers):
            beginSelection(kind: kind, at: start, modifiers: modifiers.eventFlags)
        case .updateSelection(let point, let modifiers):
            updateSelection(to: point, modifiers: modifiers.eventFlags)
        case .commitSelection(let end, let modifiers):
            commitSelection(at: end, modifiers: modifiers.eventFlags)
        case .moveSelectionPreview(let deltaX, let deltaY):
            moveSelectionPreview(by: deltaX, deltaY: deltaY)
        case .commitSelectionMove:
            commitSelectionMove()
        case .setFreeTransformToolMode(let mode):
            setFreeTransformToolMode(mode)
        case .beginSelectionTransform(let start, let mode, let modifiers):
            beginSelectionTransform(at: start, mode: mode, modifiers: modifiers.eventFlags)
        case .updateSelectionTransform(let point):
            updateSelectionTransform(to: point)
        case .commitSelectionTransform(let end):
            commitSelectionTransform(at: end)
        case .setTransformPreviewOffset(let offset):
            setTransformPreviewOffset(offset)
        case .applySelectionTransform:
            applySelectionTransform()
        case .cancelSelectionTransform:
            cancelSelectionTransform()
        }
    }

    func makeIdeationEditingContext() -> IdeationEditingContext {
        IdeationEditingContext(
            toolSession: workspace.toolSession,
            colorPanel: workspace.colorPanel,
            brushLibrary: workspace.brushLibrary,
            patternLibrary: workspace.patternLibrary,
            textureFillLibrary: workspace.textureFillLibrary,
            tipImageLibrary: workspace.tipImageLibrary,
            generator: workspace.generator
        )
    }

    func applyIdeationEditingContext(_ context: IdeationEditingContext) {
        let current = workspace
        var didChange = false
        if current.toolSession != context.toolSession {
            bootstrap.workspaceStore.updateToolSession { $0 = context.toolSession }
            didChange = true
        }
        if current.colorPanel != context.colorPanel {
            bootstrap.workspaceStore.updateColorPanel { $0 = context.colorPanel }
            didChange = true
        }
        if current.brushLibrary != context.brushLibrary {
            bootstrap.workspaceStore.updateBrushLibrary { $0 = context.brushLibrary }
            didChange = true
        }
        if current.patternLibrary != context.patternLibrary {
            bootstrap.workspaceStore.updatePatternLibrary { $0 = context.patternLibrary }
            didChange = true
        }
        if current.textureFillLibrary != context.textureFillLibrary {
            bootstrap.workspaceStore.updateTextureFillLibrary { $0 = context.textureFillLibrary }
            didChange = true
        }
        if current.tipImageLibrary != context.tipImageLibrary {
            bootstrap.workspaceStore.updateTipImageLibrary { $0 = context.tipImageLibrary }
            didChange = true
        }
        if current.generator != context.generator {
            bootstrap.workspaceStore.updateGenerator { $0 = context.generator }
            didChange = true
        }
        guard didChange else { return }
        refreshLightweight()
    }

    private func relayIdeationOperation(_ operation: IdeationCanvasOperation) {
        guard !isApplyingMirroredIdeationOperation else { return }
        ideationOperationHandler?(operation)
    }

    private func suspendTimelapseForIdeationIfNeeded() {
        shouldResumeTimelapseAfterIdeation = timelapseRecorder.isRecording
        guard shouldResumeTimelapseAfterIdeation else { return }
        timelapseRecorder.stopRecording()
    }

    private func resumeTimelapseAfterIdeationIfNeeded(recordCurrentCanvas: Bool = false) {
        guard shouldResumeTimelapseAfterIdeation else { return }
        shouldResumeTimelapseAfterIdeation = false

        syncTimelapseDocumentContext()
        do {
            _ = try timelapseRecorder.startRecording(
                documentName: workspace.document.metadata.name,
                documentFileURL: currentProjectURL
            )
            if recordCurrentCanvas {
                timelapseRecorder.noteCanvasChanged(
                    revision: documentChangeRevision,
                    documentName: workspace.document.metadata.name,
                    documentFileURL: currentProjectURL
                )
            }
        } catch {
            showStatus(.init(kind: .error, message: "恢复录像失败：\(error.localizedDescription)"))
        }
    }

    private func suspendTimelapseForSnapshotCompareIfNeeded() {
        shouldResumeTimelapseAfterSnapshotCompare = timelapseRecorder.isRecording
        guard shouldResumeTimelapseAfterSnapshotCompare else { return }
        timelapseRecorder.stopRecording()
    }

    private func resumeTimelapseAfterSnapshotCompareIfNeeded(recordCurrentCanvas: Bool = false) {
        guard shouldResumeTimelapseAfterSnapshotCompare else { return }
        shouldResumeTimelapseAfterSnapshotCompare = false

        syncTimelapseDocumentContext()
        do {
            _ = try timelapseRecorder.startRecording(
                documentName: workspace.document.metadata.name,
                documentFileURL: currentProjectURL
            )
            if recordCurrentCanvas {
                timelapseRecorder.noteCanvasChanged(
                    revision: documentChangeRevision,
                    documentName: workspace.document.metadata.name,
                    documentFileURL: currentProjectURL
                )
            }
        } catch {
            showStatus(.init(kind: .error, message: "恢复录像失败：\(error.localizedDescription)"))
        }
    }

    private func resetSnapshotToolState(resumeTimelapseIfNeeded: Bool) {
        cancelPendingSnapshotSave()
        cancelPendingSnapshotComparePreparation(resumeTimelapseIfNeeded: false)
        savedSnapshots.removeAll()
        cancelSnapshotPreviewPreparationTasks()
        snapshotCompareSession = nil
        if resumeTimelapseIfNeeded {
            resumeTimelapseAfterSnapshotCompareIfNeeded()
        } else {
            shouldResumeTimelapseAfterSnapshotCompare = false
        }
    }

    private func cancelPendingSnapshotSave() {
        snapshotSaveRequestID &+= 1
        snapshotSaveTask?.cancel()
        snapshotSaveTask = nil
        isSavingSnapshot = false
    }

    private func cancelPendingSnapshotComparePreparation(resumeTimelapseIfNeeded: Bool) {
        let wasPreparing = isPreparingSnapshotCompare
        snapshotComparePreparationRequestID &+= 1
        snapshotComparePreparationTask?.cancel()
        snapshotComparePreparationTask = nil
        isPreparingSnapshotCompare = false

        guard wasPreparing else { return }
        if resumeTimelapseIfNeeded {
            resumeTimelapseAfterSnapshotCompareIfNeeded()
        } else {
            shouldResumeTimelapseAfterSnapshotCompare = false
        }
    }

    private func makeSavedCanvasSnapshot(
        from snapshot: LayerTextureSnapshot,
        includesPreviewImage: Bool
    ) -> CanvasSavedSnapshot {
        CanvasSavedSnapshot(
            displayName: "快照 \(savedSnapshots.count + 1)",
            snapshot: snapshot,
            thumbnailImage: Self.snapshotImage(from: snapshot, maxDimension: Self.savedSnapshotThumbnailDimension),
            previewImage: includesPreviewImage
                ? Self.snapshotImage(from: snapshot, maxDimension: Self.snapshotComparePreviewDimension)
                : nil
        )
    }

    private func prepareSavedSnapshotPreviewIfNeeded(for id: UUID) {
        guard snapshotPreviewPreparationTasks[id] == nil else { return }
        guard let snapshot = savedSnapshot(with: id), snapshot.previewImage == nil else { return }

        let sourceSnapshot = snapshot.snapshot
        let previewDimension = Self.snapshotComparePreviewDimension
        snapshotPreviewPreparationTasks[id] = Task.detached(priority: .utility) { [sourceSnapshot] in
            let image = WorkspaceViewModel.snapshotImage(
                from: sourceSnapshot,
                maxDimension: previewDimension
            )

            await MainActor.run { [weak self] in
                guard let self else { return }
                guard !Task.isCancelled else {
                    self.snapshotPreviewPreparationTasks[id] = nil
                    return
                }
                guard let updatedIndex = self.savedSnapshots.firstIndex(where: { $0.id == id }) else {
                    self.snapshotPreviewPreparationTasks[id] = nil
                    return
                }

                var updatedSnapshots = self.savedSnapshots
                if updatedSnapshots[updatedIndex].previewImage == nil {
                    updatedSnapshots[updatedIndex].previewImage = image
                    self.savedSnapshots = updatedSnapshots
                }
                self.snapshotPreviewPreparationTasks[id] = nil
            }
        }
    }

    private func prepareFrozenSnapshotPreviewIfNeeded(for snapshot: CanvasSavedSnapshot) {
        guard snapshot.previewImage == nil else { return }

        frozenSnapshotPreviewPreparationTask?.cancel()
        let snapshotID = snapshot.id
        let sourceSnapshot = snapshot.snapshot
        let previewDimension = Self.snapshotComparePreviewDimension

        frozenSnapshotPreviewPreparationTask = Task.detached(priority: .utility) { [sourceSnapshot] in
            let image = WorkspaceViewModel.snapshotImage(
                from: sourceSnapshot,
                maxDimension: previewDimension
            )

            await MainActor.run { [weak self] in
                guard let self else { return }
                guard !Task.isCancelled else {
                    self.frozenSnapshotPreviewPreparationTask = nil
                    return
                }
                guard let session = self.snapshotCompareSession else {
                    self.frozenSnapshotPreviewPreparationTask = nil
                    return
                }
                guard session.frozenCurrentSnapshot.id == snapshotID else {
                    self.frozenSnapshotPreviewPreparationTask = nil
                    return
                }

                var updatedSnapshot = session.frozenCurrentSnapshot
                if updatedSnapshot.previewImage == nil {
                    updatedSnapshot.previewImage = image
                    session.updateFrozenCurrentSnapshot(updatedSnapshot)
                }
                self.frozenSnapshotPreviewPreparationTask = nil
            }
        }
    }

    private func cancelSavedSnapshotPreviewPreparationTask(for id: UUID) {
        snapshotPreviewPreparationTasks[id]?.cancel()
        snapshotPreviewPreparationTasks[id] = nil
    }

    private func cancelSnapshotPreviewPreparationTasks() {
        for task in snapshotPreviewPreparationTasks.values {
            task.cancel()
        }
        snapshotPreviewPreparationTasks.removeAll()

        frozenSnapshotPreviewPreparationTask?.cancel()
        frozenSnapshotPreviewPreparationTask = nil
    }

    nonisolated private static func snapshotImage(
        from snapshot: LayerTextureSnapshot,
        maxDimension: Int?,
        colorSpace: CGColorSpace = CGColorSpaceCreateDeviceRGB()
    ) -> CGImage? {
        let (targetWidth, targetHeight) = fittedSnapshotPreviewSize(
            width: snapshot.width,
            height: snapshot.height,
            maxDimension: maxDimension
        )
        let bytesPerPixel = 4
        let targetBytesPerRow = targetWidth * bytesPerPixel
        var rgba = [UInt8](repeating: 0, count: targetHeight * targetBytesPerRow)
        var wasCancelled = false

        snapshot.pixelData.withUnsafeBytes { rawBuffer in
            let sourceBytes = rawBuffer.bindMemory(to: UInt8.self)
            for targetY in 0..<targetHeight {
                if Task.isCancelled {
                    wasCancelled = true
                    break
                }
                let sourceY = Swift.min((targetY * snapshot.height) / targetHeight, snapshot.height - 1)
                for targetX in 0..<targetWidth {
                    let sourceX = Swift.min((targetX * snapshot.width) / targetWidth, snapshot.width - 1)
                    let sourceOffset = (sourceY * snapshot.bytesPerRow) + (sourceX * bytesPerPixel)
                    let targetOffset = (targetY * targetBytesPerRow) + (targetX * bytesPerPixel)
                    rgba[targetOffset] = sourceBytes[sourceOffset + 2]
                    rgba[targetOffset + 1] = sourceBytes[sourceOffset + 1]
                    rgba[targetOffset + 2] = sourceBytes[sourceOffset]
                    rgba[targetOffset + 3] = sourceBytes[sourceOffset + 3]
                }
            }
        }

        guard !wasCancelled else { return nil }

        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else {
            return nil
        }

        return CGImage(
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: targetBytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    nonisolated private static func positionedSnapshotImage(
        from snapshot: LayerTextureSnapshot,
        originX: Int,
        originY: Int,
        canvasSize: CanvasSize,
        maxDimension: Int
    ) -> CGImage? {
        let (targetWidth, targetHeight) = fittedSnapshotPreviewSize(
            width: canvasSize.width,
            height: canvasSize.height,
            maxDimension: maxDimension
        )
        let bytesPerPixel = 4
        let bytesPerRow = targetWidth * bytesPerPixel
        var rgba = [UInt8](repeating: 0, count: targetHeight * bytesPerRow)
        snapshot.pixelData.withUnsafeBytes { rawBuffer in
            let source = rawBuffer.bindMemory(to: UInt8.self)
            for targetY in 0..<targetHeight {
                let canvasY = min(
                    canvasSize.height - 1,
                    (targetY * canvasSize.height) / targetHeight
                )
                let sourceY = canvasY - originY
                guard sourceY >= 0, sourceY < snapshot.height else { continue }
                for targetX in 0..<targetWidth {
                    let canvasX = min(
                        canvasSize.width - 1,
                        (targetX * canvasSize.width) / targetWidth
                    )
                    let sourceX = canvasX - originX
                    guard sourceX >= 0, sourceX < snapshot.width else { continue }
                    let sourceOffset = sourceY * snapshot.bytesPerRow + sourceX * bytesPerPixel
                    let targetOffset = targetY * bytesPerRow + targetX * bytesPerPixel
                    rgba[targetOffset] = source[sourceOffset + 2]
                    rgba[targetOffset + 1] = source[sourceOffset + 1]
                    rgba[targetOffset + 2] = source[sourceOffset]
                    rgba[targetOffset + 3] = source[sourceOffset + 3]
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    nonisolated private static func fittedSnapshotPreviewSize(
        width: Int,
        height: Int,
        maxDimension: Int?
    ) -> (width: Int, height: Int) {
        guard
            let maxDimension,
            maxDimension > 0,
            max(width, height) > maxDimension
        else {
            return (max(1, width), max(1, height))
        }

        let scale = Double(maxDimension) / Double(max(width, height))
        let targetWidth = max(1, Int((Double(width) * scale).rounded()))
        let targetHeight = max(1, Int((Double(height) * scale).rounded()))
        return (targetWidth, targetHeight)
    }

    private static func normalizeLegacySelectionIfNeeded(in workspaceStore: WorkspaceStore) {
        let selection = workspaceStore.state.selection
        let hasLegacyCommittedSelection = selection.committedShape?.kind == .composite
        let hasLegacyInProgressSelection = selection.inProgressShape?.kind == .mask || selection.inProgressShape?.kind == .composite
        guard hasLegacyCommittedSelection || hasLegacyInProgressSelection else {
            return
        }

        workspaceStore.updateSelection { state in
            state = .empty
        }
    }

    @discardableResult
    private func checkpointHistoryIfPossible(
        operationKind: String = "generic.checkpoint",
        candidateChangedLayerIDs: [LayerID] = [],
        topologyOperation: Bool = false,
        additionalOperationKinds: [String] = [],
        captureMode: HistoryCaptureMode = .full,
        workspaceOverride: WorkspaceState? = nil
    ) -> Bool {
        _ = flushBrushEditingBoundary(reason: "checkpointHistoryIfPossible")
        do {
            try bootstrap.historyController.captureCheckpoint(
                workspaceOverride: workspaceOverride,
                captureMode: captureMode,
                auditContext: HistoryEligibilityAuditContext(
                    operationKind: operationKind,
                    candidateChangedLayerIDs: candidateChangedLayerIDs,
                    candidateChangedLayerIDsKnown: !candidateChangedLayerIDs.isEmpty,
                    comparisonWorkspace: captureHistoryEligibilityComparisonWorkspace(),
                    topologyOperation: topologyOperation,
                    additionalOperationKinds: additionalOperationKinds
                )
            )
            hasUnsavedChanges = true
            canUndo = bootstrap.historyController.canUndo
            canRedo = bootstrap.historyController.canRedo
            return true
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
            return false
        }
    }

    private func noteCanvasContentChanged(changedLayerIDs: Set<LayerID>? = nil) {
        if let changedLayerIDs {
            bootstrap.layerSurfaceStore.markContentUnknown(for: changedLayerIDs)
        } else {
            bootstrap.layerSurfaceStore.markContentUnknown(
                for: bootstrap.workspaceStore.state.document.layers.map(\.id)
            )
        }
        hasUnsavedChanges = true
        documentChangeRevision &+= 1
        canvasContentRevision = documentChangeRevision
        luminosityReferenceSourceRevision &+= 1
        scheduleLuminosityCaptureIfNeeded()
        scheduleNavigatorPreviewRefresh()
        syncTimelapseDocumentContext()
        timelapseRecorder.noteCanvasChanged(
            revision: documentChangeRevision,
            documentName: workspace.document.metadata.name,
            documentFileURL: currentProjectURL
        )
        canvasContentChangeHandler?()
    }

    func captureWorkspaceSnapshot() throws -> WorkspaceHistoryEntry {
        _ = flushBrushEditingBoundary(reason: "captureWorkspaceSnapshot")
        return try bootstrap.historyController.captureCurrentEntry()
    }

    func restoreWorkspaceSnapshot(_ entry: WorkspaceHistoryEntry) throws {
        _ = flushBrushEditingBoundary(reason: "restoreWorkspaceSnapshot")
        try bootstrap.historyController.restoreExact(entry: entry)
        refresh()
    }

    func cloneWorkspaceForIdeation(
        from sourceWorkspace: WorkspaceState,
        sourceLayerSurfaceStore: StageOneLayerSurfaceStore
    ) throws {
        let prepared = try LayerSurfaceTransfer.prepare(
            document: sourceWorkspace.document, source: sourceLayerSurfaceStore,
            metal: bootstrap.metalContext
        )
        bootstrap.workspaceStore.replaceState(sourceWorkspace)
        bootstrap.layerSurfaceStore.adoptContents(of: prepared)
        bootstrap.historyController.resetHistory()
        refresh()
    }

    @discardableResult
    func flushBrushEditingBoundary(reason: String) -> Bool {
        _ = reason
        let hadPendingStraightLine = straightLineState.phase == .pending
        let didCommitStraightLine = hadPendingStraightLine && commitPendingStraightLine()
        let hadPendingWork = flushPendingBrushWorkAtEditingBoundaryIfNeeded()
        let hadPendingCommits = drainPendingBrushCommitsIfNeeded(resetLiveSession: true)
        if didCommitStraightLine || hadPendingWork || hadPendingCommits {
            invalidateWholeLayerInteractionBoundsCache()
        }
        return didCommitStraightLine || hadPendingWork || hadPendingCommits
    }

    @discardableResult
    private func flushPendingBrushWorkAtEditingBoundaryIfNeeded() -> Bool {
        guard bootstrap.strokeEngine.hasPendingBrushWork else {
            return false
        }
        guard let commandBuffer = bootstrap.metalContext.commandQueue.makeCommandBuffer() else {
            showStatus(.init(kind: .error, message: "无法刷新待提交的笔刷内容"))
            return false
        }

        let didFlushLiveWork = flushPendingBrushWork(into: commandBuffer) != nil
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return didFlushLiveWork
    }

    private func drainPendingBrushCommitsIfNeeded(resetLiveSession: Bool) -> Bool {
        let hadPendingCommits = bootstrap.strokeEngine.hasPendingBrushCommitJobs

        if hadPendingCommits {
            do {
                try bootstrap.strokeEngine.drainPendingBrushCommitJobs { [self] job in
                    try captureBrushCommitCheckpoint(for: job)
                    hasUnsavedChanges = true
                }
                canUndo = bootstrap.historyController.canUndo
                canRedo = bootstrap.historyController.canRedo
                refresh()
            } catch {
                showStatus(.init(kind: .error, message: error.localizedDescription))
                return false
            }
        }

        if resetLiveSession {
            bootstrap.strokeEngine.resetBrushPipelineState()
        }

        if hadPendingCommits || resetLiveSession {
            clearRecentBrushAdjustmentState()
        }

        return hadPendingCommits
    }

    private func isBrushLikeTool(_ tool: ToolKind) -> Bool {
        tool == .brush || tool == .eraser || tool == .smudge
    }

    private func invalidateWholeLayerInteractionBoundsCache() {
        wholeLayerInteractionBoundsTask?.cancel()
        wholeLayerInteractionBoundsTask = nil
        wholeLayerInteractionBoundsBuildingKey = nil
        wholeLayerInteractionBoundsCacheKey = nil
        wholeLayerInteractionBoundsCacheEntry = nil
        lastLoggedWholeLayerOverlayUsesInteractionBounds = nil
    }

    private func captureBrushCommitCheckpoint(for job: BrushCommitJob) throws {
        let operationKind: String
        let captureMode: HistoryCaptureMode
        switch job.packets.last?.tool {
        case .brush:
            operationKind = "brush.commit"
            captureMode = .inPlaceChangedLayers([job.layerID])
        case .eraser:
            operationKind = "eraser.commit"
            captureMode = .inPlaceChangedLayers([job.layerID])
        case .smudge:
            operationKind = "smudge.commit"
            captureMode = .inPlaceChangedLayers([job.layerID])
        default:
            operationKind = "brushLike.commit"
            captureMode = .full
        }
        let auditContext = HistoryEligibilityAuditContext(
            operationKind: operationKind,
            candidateChangedLayerIDs: [job.layerID],
            candidateChangedLayerIDsKnown: true,
            comparisonWorkspace: captureHistoryEligibilityComparisonWorkspace()
        )
        if let dirtySnapshot = try makeBrushCommitHistorySnapshot(for: job) {
            try bootstrap.historyController.captureCheckpoint(
                captureMode: captureMode,
                providedLayerSnapshots: [dirtySnapshot],
                auditContext: auditContext
            )
        } else {
            try bootstrap.historyController.captureCheckpoint(
                captureMode: captureMode,
                auditContext: auditContext
            )
        }
    }

    private func makeBrushCommitHistorySnapshot(
        for job: BrushCommitJob
    ) throws -> LayerHistorySnapshot? {
        guard
            job.packets.last.map({ isBrushLikeTool($0.tool) }) == true,
            let bounds = job.renderedPixelBounds,
            !bounds.isEmpty,
            let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: job.layerID),
            let texture = bootstrap.layerSurfaceStore.texture(for: surfaceID),
            bounds.originX >= 0,
            bounds.originY >= 0,
            bounds.originX + bounds.width <= texture.width,
            bounds.originY + bounds.height <= texture.height
        else {
            return nil
        }

        let snapshot = try bootstrap.textureSerializer.snapshot(
            texture: texture,
            originX: bounds.originX,
            originY: bounds.originY,
            width: bounds.width,
            height: bounds.height
        )
        return LayerHistorySnapshot(
            layerID: job.layerID,
            texture: snapshot,
            originX: bounds.originX,
            originY: bounds.originY
        )
    }

    func makeVisibleCompositeTexture() throws -> MTLTexture {
        try makeVisibleCompositeTexture(waitUntilCompleted: true)
    }

    private func makeVisibleCompositeTexture(
        waitUntilCompleted: Bool,
        includesLiveBrushContent: Bool = false
    ) throws -> MTLTexture {
        let state = bootstrap.workspaceStore.state
        bootstrap.layerSurfaceStore.prepareTextures(
            for: state.document,
            metal: bootstrap.metalContext
        )

        let visibleLayers = state.document.layers.filter {
            $0.isPaintLayer && state.document.isLayerEffectivelyVisible($0.id)
        }
        return try makeCompositeTexture(
            layers: visibleLayers,
            document: state.document,
            waitUntilCompleted: waitUntilCompleted,
            includesLiveBrushContent: includesLiveBrushContent
        )
    }

    private func makeReferenceCompositeTextureIfNeeded() throws -> MTLTexture? {
        let state = bootstrap.workspaceStore.state
        let referenceLayers = state.document.layers.filter {
            $0.isPaintLayer && $0.isReference && state.document.isLayerEffectivelyVisible($0.id)
        }
        guard !referenceLayers.isEmpty else { return nil }
        bootstrap.layerSurfaceStore.prepareTextures(for: state.document, metal: bootstrap.metalContext)
        return try makeCompositeTexture(
            layers: referenceLayers,
            document: state.document,
            waitUntilCompleted: true
        )
    }

    private func makeFillTopologyReference(
        for source: FillSampleSource
    ) throws -> (texture: MTLTexture?, isAvailable: Bool) {
        switch source {
        case .automatic:
            return (try makeReferenceCompositeTextureIfNeeded(), true)
        case .currentLayer:
            return (nil, true)
        case .allVisibleLayers:
            return (try makeVisibleCompositeTexture(), true)
        case .markedReferenceLayers:
            let texture = try makeReferenceCompositeTextureIfNeeded()
            return (texture, texture != nil)
        }
    }

    private func makeCompositeTexture(
        layers: [LayerRecord],
        document: ArtDocument,
        waitUntilCompleted: Bool,
        includesLiveBrushContent: Bool = false
    ) throws -> MTLTexture {
        guard let firstLayer = layers.first,
              let firstSurfaceID = bootstrap.layerSurfaceStore.surfaceID(for: firstLayer.id),
              let firstTexture = bootstrap.layerSurfaceStore.texture(for: firstSurfaceID)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let textureEntries = try CanvasCompositeInputPlan.make(
            document: document,
            orderedLayers: layers,
            textureForLayer: { layerID in
                // Recent adjustable strokes intentionally remain outside the formal
                // layer. Recording must include them without forcing a history commit.
                if includesLiveBrushContent,
                   let live = bootstrap.strokeEngine.displayTexture(for: layerID) {
                    return live
                }
                return bootstrap.layerSurfaceStore.surfaceID(for: layerID)
                    .flatMap(bootstrap.layerSurfaceStore.texture(for:))
            },
            enabledMaskTextureForLayer: bootstrap.layerSurfaceStore.maskTexture(for:)
        ).inputs

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: firstTexture.pixelFormat,
            width: firstTexture.width,
            height: firstTexture.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .private

        guard let targetTexture = bootstrap.metalContext.device.makeTexture(descriptor: descriptor) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = targetTexture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 0,
            green: 0,
            blue: 0,
            alpha: 0
        )
        guard let commandBuffer = bootstrap.metalContext.commandQueue.makeCommandBuffer() else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard bootstrap.canvasPresenter.encode(
            layerInputs: textureEntries,
            into: renderPassDescriptor,
            commandBuffer: commandBuffer
        ) else {
            commandBuffer.commit()
            throw PersistenceError.invalidProject("无法准备完整图层合成，已停止操作，未替换画布内容")
        }
        commandBuffer.commit()
        if waitUntilCompleted {
            commandBuffer.waitUntilCompleted()
        }

        return targetTexture
    }

    func makeVisibleCompositeSnapshot() throws -> LayerTextureSnapshot {
        let targetTexture = try makeVisibleCompositeTexture()
        return try bootstrap.textureSerializer.snapshot(texture: targetTexture)
    }

    func appendCompositeSnapshotAsNewLayer(
        _ snapshot: LayerTextureSnapshot,
        named layerName: String
    ) throws {
        guard ensureDocumentResourceBudget(
            additionalPaintLayers: 1,
            action: "将结果加入新图层"
        ) else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        guard checkpointHistoryIfPossible(
            operationKind: "layer.appendCompositeSnapshot",
            topologyOperation: true,
            captureMode: .topologyDelta(changedLayerIDs: [])
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var createdLayerID: LayerID?
        bootstrap.workspaceStore.updateDocument { document in
            createdLayerID = document.addLayer(named: layerName).id
        }

        let state = bootstrap.workspaceStore.state
        bootstrap.layerSurfaceStore.prepareTextures(
            for: state.document,
            metal: bootstrap.metalContext
        )

        guard
            let createdLayerID,
            let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: createdLayerID),
            let texture = bootstrap.layerSurfaceStore.texture(for: surfaceID)
        else {
            throw CocoaError(.fileWriteUnknown)
        }

        try bootstrap.textureSerializer.restore(snapshot: snapshot, into: texture)
        refresh(invalidatedLayerIDs: [createdLayerID])
        noteCanvasContentChanged(changedLayerIDs: [createdLayerID])
    }

    private func ideationDeltaSnapshot(
        variantTexture: MTLTexture,
        baseTexture: MTLTexture
    ) throws -> LayerTextureSnapshot? {
        guard
            variantTexture.width == baseTexture.width,
            variantTexture.height == baseTexture.height,
            variantTexture.pixelFormat == baseTexture.pixelFormat
        else {
            throw CocoaError(.fileReadCorruptFile)
        }

        guard let deltaTexture = bootstrap.layerSurfaceStore.makeTexture(
            width: variantTexture.width,
            height: variantTexture.height,
            pixelFormat: variantTexture.pixelFormat,
            metal: bootstrap.metalContext
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = deltaTexture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 0,
            green: 0,
            blue: 0,
            alpha: 0
        )
        guard let commandBuffer = bootstrap.metalContext.commandQueue.makeCommandBuffer() else {
            throw CocoaError(.fileWriteUnknown)
        }
        bootstrap.visibleDeltaRenderer.encode(
            variantTexture: variantTexture,
            baseTexture: baseTexture,
            into: renderPassDescriptor,
            commandBuffer: commandBuffer
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let snapshot = try bootstrap.textureSerializer.snapshot(texture: deltaTexture)
        let hasVisibleDelta = snapshot.pixelData.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] > 0 }
        }
        return hasVisibleDelta ? snapshot : nil
    }

    private func syncTimelapseDocumentContext() {
        // The published UI snapshot may still describe the previous document here.
        let document = bootstrap.workspaceStore.state.document
        let context = TimelapseDocumentContext(
            documentID: document.metadata.drawingStatsID,
            documentName: document.metadata.name,
            documentFileURL: currentProjectURL
        )
        guard context != lastSyncedTimelapseDocumentContext else { return }
        timelapseRecorder.syncCurrentDocument(
            documentName: context.documentName,
            documentFileURL: context.documentFileURL
        )
        lastSyncedTimelapseDocumentContext = context
#if DEBUG
        debugTimelapseDocumentContextSyncCount += 1
#endif
    }

    private func syncDrawingStatsDocumentContext() {
        drawingStatsController.syncCurrentDocument(
            id: workspace.document.metadata.drawingStatsID,
            name: workspace.document.metadata.name,
            accumulatedPaintingTime: workspace.document.metadata.accumulatedPaintingTime
        )
    }

    private func syncCommittedDrawingStatsIntoActiveDocumentMetadata() {
        let committedTime = drawingStatsController.currentDocumentAccumulatedPaintingTime
        guard workspace.document.metadata.accumulatedPaintingTime != committedTime else {
            return
        }

        bootstrap.workspaceStore.updateDocument { document in
            document.metadata.accumulatedPaintingTime = committedTime
        }
        workspace.document.metadata = bootstrap.workspaceStore.state.document.metadata
    }

    func pauseDrawingStatsTracking() {
        drawingStatsController.pauseTracking()
        syncCommittedDrawingStatsIntoActiveDocumentMetadata()
    }

    private func recordDrawingActivityIfNeeded() {
        guard !isApplyingMirroredIdeationOperation else { return }
        drawingStatsController.recordPaintingActivity()
    }

    func showDrawingStatsMilestone(_ milestone: DrawingStatsMilestone) {
        showStatus(.init(kind: .success, message: "绘画里程碑：\(milestone.title)"))
    }

    private func checkpointSelectionChangeIfPossible(previousCommittedShape: SelectionShape?) {
        var workspaceSnapshot = workspace
        workspaceSnapshot.selection.committedShape = previousCommittedShape
        workspaceSnapshot.selection.inProgressShape = nil
        workspaceSnapshot.selection.anchorPoint = nil
        workspaceSnapshot.selection.activeKind = nil

        do {
            try bootstrap.historyController.captureCheckpoint(workspaceOverride: workspaceSnapshot)
            canUndo = bootstrap.historyController.canUndo
            canRedo = bootstrap.historyController.canRedo
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func workspaceSnapshotClearingSelection(
        from base: WorkspaceState? = nil
    ) -> WorkspaceState {
        var workspaceSnapshot = base ?? workspace
        workspaceSnapshot.selection.committedShape = nil
        workspaceSnapshot.selection.inProgressShape = nil
        workspaceSnapshot.selection.anchorPoint = nil
        workspaceSnapshot.selection.activeKind = nil
        workspaceSnapshot.selection.activeCombineMode = .replace
        return workspaceSnapshot
    }

    private func premultipliedPixel(from color: RGBAColor) -> EditablePixel {
        let premultiplied = color.premultiplied
        return EditablePixel(
            blue: UInt8(clamping: Int((premultiplied.blue * 255).rounded())),
            green: UInt8(clamping: Int((premultiplied.green * 255).rounded())),
            red: UInt8(clamping: Int((premultiplied.red * 255).rounded())),
            alpha: UInt8(clamping: Int((premultiplied.alpha * 255).rounded()))
        )
    }

    private enum SelectionPixelOperation {
        case clear
        case fill(EditablePixel)
    }

    private func renderInput(for operation: SelectionPixelOperation) -> (
        mode: SelectionPixelOperationRenderMode,
        premultipliedColor: RGBAColor
    ) {
        switch operation {
        case .clear:
            return (.clear, RGBAColor(red: 0, green: 0, blue: 0, alpha: 0))
        case .fill(let fillPixel):
            return (
                .fill,
                RGBAColor(
                    red: Float(fillPixel.red) / 255,
                    green: Float(fillPixel.green) / 255,
                    blue: Float(fillPixel.blue) / 255,
                    alpha: Float(fillPixel.alpha) / 255
                )
            )
        }
    }

    @discardableResult
    private func applyTextureFillSolid(
        to selectionShape: SelectionShape,
        historyOperationKind: String,
        successMessage: String
    ) -> Bool {
        guard let layerID = bootstrap.interactionController.activeEditableLayerID() else {
            showStatus(.init(kind: .info, message: "当前图层已锁定"))
            return false
        }

        guard
            let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: layerID),
            let texture = bootstrap.layerSurfaceStore.texture(for: surfaceID)
        else {
            showStatus(.init(kind: .error, message: "无法访问当前图层"))
            return false
        }

        let clampedSelection = selectionShape.clamped(
            to: CanvasSize(width: texture.width, height: texture.height)
        )
        guard !clampedSelection.isEmpty else {
            showStatus(.init(kind: .info, message: "选区为空"))
            return false
        }

        let minX = max(Int(clampedSelection.bounds.minX.rounded(.down)), 0)
        let minY = max(Int(clampedSelection.bounds.minY.rounded(.down)), 0)
        let maxX = min(Int(clampedSelection.bounds.maxX.rounded(.up)), texture.width)
        let maxY = min(Int(clampedSelection.bounds.maxY.rounded(.up)), texture.height)
        guard minX < maxX, minY < maxY else {
            showStatus(.init(kind: .info, message: "选区为空"))
            return false
        }

        let selectionMaskRegion = selectionMaskRegion(
            for: clampedSelection,
            canvasSize: CanvasSize(width: texture.width, height: texture.height),
            originX: minX,
            originY: minY,
            width: maxX - minX,
            height: maxY - minY
        )
        let fillCenter = clampedSelection.pathPoints.first ?? CanvasPoint(
            x: clampedSelection.bounds.origin.x + (clampedSelection.bounds.size.x * 0.5),
            y: clampedSelection.bounds.origin.y + (clampedSelection.bounds.size.y * 0.5)
        )

        let alphaLockTexture = makeAlphaLockTextureCopyIfNeeded(for: layerID, sourceTexture: texture)
        guard alphaLockTexture != nil || !layerTransparentPixelLockEnabled(layerID) else {
            showStatus(.init(kind: .error, message: "无法创建锁定透明像素遮罩"))
            return false
        }

        checkpointHistoryIfPossible(
            operationKind: historyOperationKind,
            candidateChangedLayerIDs: [layerID],
            additionalOperationKinds: ["textureFillSolidRenderer"],
            captureMode: .inPlaceChangedLayers([layerID])
        )

        guard let commandBuffer = bootstrap.metalContext.commandQueue.makeCommandBuffer() else {
            showStatus(.init(kind: .error, message: "无法创建纹理填充命令缓冲"))
            return false
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = texture
        renderPassDescriptor.colorAttachments[0].loadAction = .load
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        bootstrap.selectionFillRenderer.encode(
            into: renderPassDescriptor,
            commandBuffer: commandBuffer,
            canvasSize: CanvasSize(width: texture.width, height: texture.height),
            selectionMaskOriginX: selectionMaskRegion.originX,
            selectionMaskOriginY: selectionMaskRegion.originY,
            selectionMaskWidth: selectionMaskRegion.width,
            selectionMaskHeight: selectionMaskRegion.height,
            selectionMaskAlphaBytes: selectionMaskRegion.alphaBytes,
            fillCenter: fillCenter,
            color: resolvedFillToolColor(from: workspace.toolSession.selectedColor),
            paintJitterAmount: 0,
            paintContrastAmount: 0,
            distortionAmount: 0,
            alphaLockTexture: alphaLockTexture
        )

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        layerThumbnailCache.removeValue(forKey: layerID)
        bootstrap.strokeEngine.resetBrushPipelineState()
        clearRecentBrushAdjustmentState()
        noteCanvasContentChanged(changedLayerIDs: [layerID])
        refresh(invalidatedLayerIDs: [layerID])
        recordDrawingActivityIfNeeded()
        showStatus(.init(kind: .success, message: successMessage))
        return true
    }

    @discardableResult
    private func applyLassoFill(
        to selectionShape: SelectionShape,
        historyOperationKind: String,
        successMessage: String
    ) -> Bool {
        guard let layerID = bootstrap.interactionController.activeEditableLayerID() else {
            showStatus(.init(kind: .info, message: "当前图层已锁定"))
            return false
        }

        guard
            let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: layerID),
            let texture = bootstrap.layerSurfaceStore.texture(for: surfaceID)
        else {
            showStatus(.init(kind: .error, message: "无法访问当前图层"))
            return false
        }

        let clampedSelection = selectionShape.clamped(
            to: CanvasSize(width: texture.width, height: texture.height)
        )
        guard !clampedSelection.isEmpty else {
            showStatus(.init(kind: .info, message: "选区为空"))
            return false
        }

        let minX = max(Int(clampedSelection.bounds.minX.rounded(.down)), 0)
        let minY = max(Int(clampedSelection.bounds.minY.rounded(.down)), 0)
        let maxX = min(Int(clampedSelection.bounds.maxX.rounded(.up)), texture.width)
        let maxY = min(Int(clampedSelection.bounds.maxY.rounded(.up)), texture.height)
        guard minX < maxX, minY < maxY else {
            showStatus(.init(kind: .info, message: "选区为空"))
            return false
        }

        let selectionMaskRegion = selectionMaskRegion(
            for: clampedSelection,
            canvasSize: CanvasSize(width: texture.width, height: texture.height),
            originX: minX,
            originY: minY,
            width: maxX - minX,
            height: maxY - minY
        )
        let lassoFillCenter: CanvasPoint = {
            if let firstPoint = clampedSelection.pathPoints.first {
                return firstPoint
            }
            for component in clampedSelection.flattenedComponents() {
                if let firstPoint = component.shape.pathPoints.first {
                    return firstPoint
                }
            }
            return CanvasPoint(
                x: clampedSelection.bounds.origin.x + (clampedSelection.bounds.size.x * 0.5),
                y: clampedSelection.bounds.origin.y + (clampedSelection.bounds.size.y * 0.5)
            )
        }()

        let alphaLockTexture = makeAlphaLockTextureCopyIfNeeded(for: layerID, sourceTexture: texture)
        guard alphaLockTexture != nil || !layerTransparentPixelLockEnabled(layerID) else {
            showStatus(.init(kind: .error, message: "无法创建锁定透明像素遮罩"))
            return false
        }

        checkpointHistoryIfPossible(
            operationKind: historyOperationKind,
            candidateChangedLayerIDs: [layerID],
            additionalOperationKinds: ["lassoFillRenderer"],
            captureMode: .inPlaceChangedLayers([layerID])
        )

        guard let commandBuffer = bootstrap.metalContext.commandQueue.makeCommandBuffer() else {
            showStatus(.init(kind: .error, message: "无法创建填充命令缓冲"))
            return false
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = texture
        renderPassDescriptor.colorAttachments[0].loadAction = .load
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        bootstrap.selectionFillRenderer.encode(
            into: renderPassDescriptor,
            commandBuffer: commandBuffer,
            canvasSize: CanvasSize(width: texture.width, height: texture.height),
            selectionMaskOriginX: selectionMaskRegion.originX,
            selectionMaskOriginY: selectionMaskRegion.originY,
            selectionMaskWidth: selectionMaskRegion.width,
            selectionMaskHeight: selectionMaskRegion.height,
            selectionMaskAlphaBytes: selectionMaskRegion.alphaBytes,
            fillCenter: lassoFillCenter,
            color: resolvedFillToolColor(from: workspace.toolSession.selectedColor),
            paintJitterAmount: displayedPaintJitterAmount,
            paintContrastAmount: displayedPaintContrastAmount,
            distortionAmount: workspace.toolSession.brush.jitterAmount,
            alphaLockTexture: alphaLockTexture
        )

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        layerThumbnailCache.removeValue(forKey: layerID)
        bootstrap.strokeEngine.resetBrushPipelineState()
        clearRecentBrushAdjustmentState()
        noteCanvasContentChanged(changedLayerIDs: [layerID])
        refresh(invalidatedLayerIDs: [layerID])
        recordDrawingActivityIfNeeded()
        showStatus(.init(kind: .success, message: successMessage))
        return true
    }

    @discardableResult
    private func applyPixelOperation(
        to selectionShape: SelectionShape,
        operation: SelectionPixelOperation,
        historyOperationKind: String,
        successMessage: String,
        preservesExistingAlpha: Bool = false
    ) -> Bool {
        let auditEnabled = PerformanceAuditStore.shared.isRecordingEnabled
        let totalStartNs = auditEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        guard let layerID = bootstrap.interactionController.activeEditableLayerID() else {
            showStatus(.init(kind: .info, message: "当前图层已锁定"))
            return false
        }

        guard
            let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: layerID),
            let texture = bootstrap.layerSurfaceStore.texture(for: surfaceID)
        else {
            showStatus(.init(kind: .error, message: "无法访问当前图层"))
            return false
        }

        let clampedSelection = selectionShape.clamped(
            to: CanvasSize(width: texture.width, height: texture.height)
        )
        let minX = max(Int(clampedSelection.bounds.minX.rounded(.down)), 0)
        let minY = max(Int(clampedSelection.bounds.minY.rounded(.down)), 0)
        let maxX = min(Int(clampedSelection.bounds.maxX.rounded(.up)), texture.width)
        let maxY = min(Int(clampedSelection.bounds.maxY.rounded(.up)), texture.height)

        guard minX < maxX, minY < maxY else {
            showStatus(.init(kind: .info, message: "选区为空"))
            return false
        }

        let maskPreparationStartNs = auditEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        let selectionMaskRegion = selectionMaskRegion(
            for: clampedSelection,
            canvasSize: CanvasSize(width: texture.width, height: texture.height),
            originX: minX,
            originY: minY,
            width: maxX - minX,
            height: maxY - minY
        )
        if auditEnabled {
            let maskPreparationMs = Double(DispatchTime.now().uptimeNanoseconds - maskPreparationStartNs) / 1_000_000
            PerformanceAuditStore.shared.recordDuration("WorkspaceViewModel.applyPixelOperation.maskPreparation", ms: maskPreparationMs)
            PerformanceAuditStore.shared.recordDuration("WorkspaceViewModel.applyPixelOperation.snapshot", ms: 0)
        }

        let alphaLockTexture = makeAlphaLockTextureCopyIfNeeded(
            for: layerID,
            sourceTexture: texture,
            force: preservesExistingAlpha
        )
        guard alphaLockTexture != nil || (!layerTransparentPixelLockEnabled(layerID) && !preservesExistingAlpha) else {
            showStatus(.init(kind: .error, message: "无法创建锁定透明像素遮罩"))
            return false
        }

        let pixelOperationCaptureMode: HistoryCaptureMode
#if DEBUG
        pixelOperationCaptureMode = debugPixelOperationHistoryCaptureModeOverride ?? .inPlaceChangedLayers([layerID])
#else
        pixelOperationCaptureMode = .inPlaceChangedLayers([layerID])
#endif

        let historyCheckpointStartNs = auditEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        checkpointHistoryIfPossible(
            operationKind: historyOperationKind,
            candidateChangedLayerIDs: [layerID],
            additionalOperationKinds: ["applyPixelOperation"],
            captureMode: pixelOperationCaptureMode
        )
        if auditEnabled {
            let historyCheckpointMs = Double(DispatchTime.now().uptimeNanoseconds - historyCheckpointStartNs) / 1_000_000
            PerformanceAuditStore.shared.recordDuration("WorkspaceViewModel.applyPixelOperation.historyCheckpoint", ms: historyCheckpointMs)
        }

        guard let commandBuffer = bootstrap.metalContext.commandQueue.makeCommandBuffer() else {
            showStatus(.init(kind: .error, message: "无法创建选区像素操作命令缓冲"))
            return false
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = texture
        renderPassDescriptor.colorAttachments[0].loadAction = .load
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        let renderInput = renderInput(for: operation)
        let operationStartNs = auditEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        bootstrap.selectionPixelOperationRenderer.encode(
            into: renderPassDescriptor,
            commandBuffer: commandBuffer,
            canvasSize: CanvasSize(width: texture.width, height: texture.height),
            selectionMaskOriginX: selectionMaskRegion.originX,
            selectionMaskOriginY: selectionMaskRegion.originY,
            selectionMaskWidth: selectionMaskRegion.width,
            selectionMaskHeight: selectionMaskRegion.height,
            selectionMaskAlphaBytes: selectionMaskRegion.alphaBytes,
            operationMode: renderInput.mode,
            premultipliedFillColor: renderInput.premultipliedColor,
            alphaLockTexture: alphaLockTexture
        )

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if auditEnabled {
            let operationMs = Double(DispatchTime.now().uptimeNanoseconds - operationStartNs) / 1_000_000
            PerformanceAuditStore.shared.recordDuration("WorkspaceViewModel.applyPixelOperation.pixelMutation", ms: operationMs)
            PerformanceAuditStore.shared.recordDuration("WorkspaceViewModel.applyPixelOperation.restore", ms: 0)
        }

        let uiConfirmStartNs = auditEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        refresh(invalidatedLayerIDs: [layerID])
        noteCanvasContentChanged(changedLayerIDs: [layerID])
        recordDrawingActivityIfNeeded()
        showStatus(.init(kind: .success, message: successMessage))
        if auditEnabled {
            let uiConfirmMs = Double(DispatchTime.now().uptimeNanoseconds - uiConfirmStartNs) / 1_000_000
            PerformanceAuditStore.shared.recordDuration("WorkspaceViewModel.applyPixelOperation.uiConfirm", ms: uiConfirmMs)
            let totalMs = Double(DispatchTime.now().uptimeNanoseconds - totalStartNs) / 1_000_000
            PerformanceAuditStore.shared.recordDuration("WorkspaceViewModel.applyPixelOperation.total", ms: totalMs)
        }
        return true
    }

    private func captureHistoryEligibilityComparisonWorkspace() -> WorkspaceState? {
        bootstrap.historyController.latestUndoWorkspaceForAudit
    }

    private func resolvedGeneratorColor(from color: RGBAColor) -> RGBAColor {
        return color
    }

    nonisolated private func distanceBetween(_ lhs: CanvasPoint, _ rhs: CanvasPoint) -> Double {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    private func selectionCombineMode(
        for kind: SelectionShapeKind,
        modifiers: NSEvent.ModifierFlags
    ) -> SelectionCombineMode {
        guard kind == .lasso || kind == .rectangle || kind == .ellipse else {
            return .replace
        }
        let normalized = modifiers.intersection(.deviceIndependentFlagsMask)
        if normalized.contains(.shift), normalized.contains(.option) {
            return .intersect
        }
        if normalized.contains(.option) {
            return .subtract
        }
        if normalized.contains(.shift) {
            return .add
        }
        return .replace
    }

    private func selectionGeometryOptions(
        modifiers: NSEvent.ModifierFlags,
        combineMode: SelectionCombineMode
    ) -> SelectionGeometryOptions {
        let normalized = modifiers.intersection(.deviceIndependentFlagsMask)
        guard combineMode == .replace else {
            return SelectionGeometryOptions(constrainsProportions: false, drawsFromCenter: false)
        }
        return SelectionGeometryOptions(
            constrainsProportions: normalized.contains(.shift),
            drawsFromCenter: normalized.contains(.control)
        )
    }

    private func selectionPreviewShape(
        kind: SelectionShapeKind,
        start: CanvasPoint,
        currentPoint: CanvasPoint,
        existingPoints: [CanvasPoint]?,
        modifiers: NSEvent.ModifierFlags,
        combineMode: SelectionCombineMode,
        precomputedBounds: CanvasRect? = nil
    ) -> SelectionShape? {
        switch kind {
        case .lasso:
            let points = existingPoints ?? [start]
            guard points.count >= 2 else { return nil }
            if RuntimeDiagnostics.selectionTraceLoggingEnabled,
               points.count == 2 || points.count % 24 == 0 {
                let lastPoint = points.last ?? currentPoint
                let message = "[selectionPreviewShape] pointCount=\(points.count) current=(\(currentPoint.x),\(currentPoint.y)) previewLast=(\(lastPoint.x),\(lastPoint.y))"
                selectionTraceLogger.debug("\(message, privacy: .public)")
                emitSelectionTraceViewModel(message)
            }
            return SelectionShape(
                kind: .lasso,
                bounds: precomputedBounds ?? CanvasRect.bounding(points: points),
                pathPoints: points
            )
        case .rectangle, .ellipse:
            let bounds = selectionBounds(
                start: start,
                end: currentPoint,
                options: selectionGeometryOptions(
                    modifiers: modifiers,
                    combineMode: combineMode
                )
            )
            return SelectionShape(
                kind: kind,
                bounds: bounds,
                pathPoints: []
            )
        case .mask, .composite:
            return nil
        }
    }

    private func selectionInput(
        kind: SelectionShapeKind,
        currentStart: CanvasPoint,
        end: CanvasPoint,
        inProgressShape: SelectionShape?,
        modifiers: NSEvent.ModifierFlags,
        combineMode: SelectionCombineMode
    ) -> SelectionInputShape {
        switch kind {
        case .lasso:
            let rawPoints = activeLassoRawPoints.isEmpty
                ? (inProgressShape?.pathPoints ?? [currentStart])
                : activeLassoRawPoints
            let points = finalizedLassoPoints(
                rawPoints: rawPoints,
                closingTo: end
            )
            guard points.count >= 3 else {
                return SelectionInputShape(polygonShapes: [], preferredDisplayShape: nil)
            }
            if RuntimeDiagnostics.selectionTraceLoggingEnabled {
                let lastPoint = points.last ?? end
                let message = "[selectionInput] polygonPointCount=\(points.count) end=(\(end.x),\(end.y)) inputLast=(\(lastPoint.x),\(lastPoint.y))"
                selectionTraceLogger.debug("\(message, privacy: .public)")
                emitSelectionTraceViewModel(message)
            }
            return SelectionInputShape(
                polygonShapes: [[points.map { CGPoint(x: $0.x, y: $0.y) }]],
                preferredDisplayShape: SelectionShape(
                    kind: .lasso,
                    bounds: CanvasRect.bounding(points: points),
                    pathPoints: points
                )
            )
        case .rectangle, .ellipse:
            let bounds = selectionBounds(
                start: currentStart,
                end: end,
                options: selectionGeometryOptions(
                    modifiers: modifiers,
                    combineMode: combineMode
                )
            )
            guard !bounds.isEmpty else {
                return SelectionInputShape(polygonShapes: [], preferredDisplayShape: nil)
            }

            let outlinePoints = selectionOutlinePoints(for: kind, bounds: bounds)
            return SelectionInputShape(
                polygonShapes: [outlinePoints],
                preferredDisplayShape: SelectionShape(
                    kind: kind,
                    bounds: bounds,
                    pathPoints: []
                )
            )
        case .mask, .composite:
            return SelectionInputShape(polygonShapes: [], preferredDisplayShape: nil)
        }
    }

    nonisolated private func committedSelectionShape(
        input: SelectionInputShape,
        canvasSize: CanvasSize,
        mode: SelectionCombineMode,
        baseShape: SelectionShape?
    ) -> SelectionShape? {
        let logger = Logger(subsystem: "ArtFlex", category: "SelectionTrace")
        let incomingPatch = selectionMaskPatch(
            from: input.polygonShapes,
            canvasSize: canvasSize
        )
        if RuntimeDiagnostics.selectionTraceLoggingEnabled {
            let committedMessage = "[committedSelectionShape] incomingPatchOrigin=(\(incomingPatch.originX),\(incomingPatch.originY)) incomingPatchSize=(\(incomingPatch.width),\(incomingPatch.height)) mode=\(mode.rawValue)"
            logger.debug("\(committedMessage, privacy: .public)")
            emitSelectionTraceViewModel(committedMessage)
        }
        guard incomingPatch.width > 0, incomingPatch.height > 0 else {
            return switch mode {
            case .add, .subtract: baseShape
            case .replace, .intersect: nil
            }
        }

        let baseMaskData: Data? = if mode == .replace {
            nil
        } else if let maskData = baseShape?.maskData,
                  maskData.canvasWidth == canvasSize.width,
                  maskData.canvasHeight == canvasSize.height {
            maskData.alphaBytes
        } else if baseShape != nil {
            Data(selectionMaskBytes(for: baseShape, canvasSize: canvasSize))
        } else {
            nil
        }
        let merged = SelectionMaskCombiner.combineCanvas(
            base: baseMaskData,
            baseBounds: baseShape?.bounds,
            incoming: incomingPatch,
            canvasWidth: canvasSize.width,
            canvasHeight: canvasSize.height,
            mode: mode
        )
        let resultShape = SelectionShape.mask(
            canvasWidth: canvasSize.width,
            canvasHeight: canvasSize.height,
            alphaBytes: merged.alphaBytes,
            knownBounds: merged.bounds
        )
        guard let resultMaskData = resultShape.maskData else { return nil }
        let resultBounds = resultShape.bounds

        guard !resultBounds.isEmpty else {
            return nil
        }

        let displayComponents: [SelectionShapeComponent]
        if mode == .replace, let preferredDisplayShape = input.preferredDisplayShape {
            displayComponents = [
                SelectionShapeComponent(operation: .add, shape: preferredDisplayShape)
            ]
        } else {
            // Cross-tool combinations may start from a raster-only Magic Wand
            // mask. A vector component list cannot faithfully describe that
            // result (and used to hide the existing mask after lasso commit), so
            // combined results deliberately display their authoritative mask.
            displayComponents = []
        }

        return SelectionShape(
            kind: .mask,
            bounds: resultBounds,
            pathPoints: [],
            maskData: resultMaskData,
            components: displayComponents
        )
    }

    nonisolated private func selectionMaskPatch(
        from polygonShapes: [SelectionPolygonShape],
        canvasSize: CanvasSize
    ) -> SelectionMaskCombiner.Patch {
        let points = polygonShapes.lazy.flatMap { $0 }.flatMap { $0 }
        guard let first = points.first else {
            return .init(originX: 0, originY: 0, width: 0, height: 0, alphaBytes: Data())
        }

        var minX = first.x
        var minY = first.y
        var maxX = first.x
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }

        // Preserve Core Graphics antialiasing at the boundary without turning
        // a local gesture into a full-canvas rasterization.
        let originX = min(max(Int(minX.rounded(.down)) - 1, 0), canvasSize.width)
        let originY = min(max(Int(minY.rounded(.down)) - 1, 0), canvasSize.height)
        let endX = min(max(Int(maxX.rounded(.up)) + 1, 0), canvasSize.width)
        let endY = min(max(Int(maxY.rounded(.up)) + 1, 0), canvasSize.height)
        let width = max(endX - originX, 0)
        let height = max(endY - originY, 0)
        guard width > 0, height > 0 else {
            return .init(originX: 0, originY: 0, width: 0, height: 0, alphaBytes: Data())
        }

        return SelectionMaskCombiner.Patch(
            originX: originX,
            originY: originY,
            width: width,
            height: height,
            alphaBytes: rasterizedSelectionMaskRegionBytes(
                polygonShapes: polygonShapes,
                originX: originX,
                originY: originY,
                width: width,
                height: height
            )
        )
    }

    nonisolated private func finalizedLassoPoints(
        rawPoints: [CanvasPoint],
        closingTo endPoint: CanvasPoint
    ) -> [CanvasPoint] {
        smoothedClosedLassoPoints(rawPoints: rawPoints, closingTo: endPoint)
    }

    nonisolated private func interpolatedLassoPoints(from start: CanvasPoint, to end: CanvasPoint) -> [CanvasPoint] {
        let distance = distanceBetween(start, end)
        guard distance > 0 else { return [] }

        let step = 0.75
        let steps = max(Int(distance / step), 1)
        guard steps > 1 else { return [end] }

        return (1...steps).map { index in
            let t = Double(index) / Double(steps)
            return CanvasPoint(
                x: start.x + ((end.x - start.x) * t),
                y: start.y + ((end.y - start.y) * t)
            )
        }
    }

    nonisolated private func deduplicatedLassoPoints(
        _ points: [CanvasPoint],
        minimumDistance: Double
    ) -> [CanvasPoint] {
        guard let first = points.first else { return [] }
        var output: [CanvasPoint] = [first]
        for point in points.dropFirst() {
            if distanceBetween(output[output.count - 1], point) >= minimumDistance {
                output.append(point)
            }
        }
        if let last = points.last, output.last != last {
            output.append(last)
        }
        return output
    }

    nonisolated private func makeSmoothedClosedLassoPath(points: [CanvasPoint]) -> CGMutablePath {
        let path = CGMutablePath()
        guard points.count >= 3 else { return path }

        let lastMidpoint = midpointBetween(points[points.count - 1], points[0])
        path.move(to: CGPoint(x: lastMidpoint.x, y: lastMidpoint.y))

        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            let midpoint = midpointBetween(current, next)
            path.addQuadCurve(
                to: CGPoint(x: midpoint.x, y: midpoint.y),
                control: CGPoint(x: current.x, y: current.y)
            )
        }

        path.closeSubpath()
        return path
    }

    nonisolated private func sampledPoints(
        from path: CGPath,
        sampleStep: Double
    ) -> [CanvasPoint] {
        var sampled: [CanvasPoint] = []
        var currentPoint = CGPoint.zero
        var subpathStart = CGPoint.zero

        path.applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            switch element.type {
            case .moveToPoint:
                let point = element.points[0]
                currentPoint = point
                subpathStart = point
                sampled.append(CanvasPoint(x: point.x, y: point.y))
            case .addLineToPoint:
                let end = element.points[0]
                sampled.append(contentsOf: sampleLine(from: currentPoint, to: end, step: sampleStep))
                currentPoint = end
            case .addQuadCurveToPoint:
                let control = element.points[0]
                let end = element.points[1]
                sampled.append(
                    contentsOf: sampleQuadratic(
                        from: currentPoint,
                        control: control,
                        to: end,
                        step: sampleStep
                    )
                )
                currentPoint = end
            case .closeSubpath:
                sampled.append(contentsOf: sampleLine(from: currentPoint, to: subpathStart, step: sampleStep))
                currentPoint = subpathStart
            default:
                break
            }
        }

        return sampled
    }

    nonisolated private func sampleLine(
        from start: CGPoint,
        to end: CGPoint,
        step: Double
    ) -> [CanvasPoint] {
        let distance = hypot(end.x - start.x, end.y - start.y)
        let steps = max(Int(ceil(distance / max(step, 0.5))), 1)
        return (1...steps).map { index in
            let t = Double(index) / Double(steps)
            return CanvasPoint(
                x: start.x + ((end.x - start.x) * t),
                y: start.y + ((end.y - start.y) * t)
            )
        }
    }

    nonisolated private func sampleQuadratic(
        from start: CGPoint,
        control: CGPoint,
        to end: CGPoint,
        step: Double
    ) -> [CanvasPoint] {
        let controlPolygonLength =
            hypot(control.x - start.x, control.y - start.y) +
            hypot(end.x - control.x, end.y - control.y)
        let steps = max(Int(ceil(controlPolygonLength / max(step, 0.5))), 2)

        return (1...steps).map { index in
            let t = Double(index) / Double(steps)
            let oneMinusT = 1 - t
            let x =
                (oneMinusT * oneMinusT * start.x) +
                (2 * oneMinusT * t * control.x) +
                (t * t * end.x)
            let y =
                (oneMinusT * oneMinusT * start.y) +
                (2 * oneMinusT * t * control.y) +
                (t * t * end.y)
            return CanvasPoint(x: x, y: y)
        }
    }

    nonisolated private func midpointBetween(_ lhs: CanvasPoint, _ rhs: CanvasPoint) -> CanvasPoint {
        CanvasPoint(
            x: (lhs.x + rhs.x) * 0.5,
            y: (lhs.y + rhs.y) * 0.5
        )
    }

    private func appendActiveLassoPreviewPointIfNeeded(_ point: CanvasPoint) {
        let displayScale = currentCanvasViewportTransform?.actualDisplayScale ?? 1
        // The authoritative path retains every sample. Four display pixels are
        // sufficient for the live outline and keep redraw cost bounded.
        let minimumCanvasDistance = max(4 / max(displayScale, 0.000_001), 1)
        guard let lastPoint = activeLassoPreviewPoints.last else {
            activeLassoPreviewPoints = [point]
            return
        }
        if distanceBetween(lastPoint, point) >= minimumCanvasDistance {
            activeLassoPreviewPoints.append(point)
        }
    }

    private func refreshLiveLassoOverlayIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastLassoOverlayRefreshUptime >= (1.0 / 60.0) else { return }
        lastLassoOverlayRefreshUptime = now
        refreshSelectionOverlayOnly()
    }

    private func activeLassoPreviewPath(endingAt point: CanvasPoint) -> [CanvasPoint] {
        guard activeLassoPreviewPoints.last != point else {
            return activeLassoPreviewPoints
        }
        var previewPoints = activeLassoPreviewPoints
        previewPoints.append(point)
        return previewPoints
    }

    private func expandedBounds(_ current: CanvasRect?, including point: CanvasPoint) -> CanvasRect {
        guard let current else {
            return CanvasRect(origin: point, size: .init(x: 0, y: 0))
        }

        let minX = min(current.minX, point.x)
        let minY = min(current.minY, point.y)
        let maxX = max(current.maxX, point.x)
        let maxY = max(current.maxY, point.y)
        return CanvasRect(
            origin: .init(x: minX, y: minY),
            size: .init(x: maxX - minX, y: maxY - minY)
        )
    }

    private func selectionBounds(
        start: CanvasPoint,
        end: CanvasPoint,
        options: SelectionGeometryOptions
    ) -> CanvasRect {
        var deltaX = end.x - start.x
        var deltaY = end.y - start.y

        if options.constrainsProportions {
            let side = max(abs(deltaX), abs(deltaY))
            deltaX = signedMagnitude(for: deltaX, fallback: deltaY) * side
            deltaY = signedMagnitude(for: deltaY, fallback: deltaX) * side
        }

        if options.drawsFromCenter {
            return CanvasRect(
                origin: CanvasPoint(
                    x: start.x - abs(deltaX),
                    y: start.y - abs(deltaY)
                ),
                size: CanvasPoint(
                    x: abs(deltaX) * 2,
                    y: abs(deltaY) * 2
                )
            )
        }

        return CanvasRect.fromPoints(
            start,
            CanvasPoint(x: start.x + deltaX, y: start.y + deltaY)
        )
    }

    private func signedMagnitude(for value: Double, fallback: Double) -> Double {
        if value > 0 { return 1 }
        if value < 0 { return -1 }
        if fallback > 0 { return 1 }
        if fallback < 0 { return -1 }
        return 1
    }

    nonisolated private func selectionOutlinePoints(
        for kind: SelectionShapeKind,
        bounds: CanvasRect
    ) -> SelectionPolygonShape {
        switch kind {
        case .rectangle:
            return [[
                CGPoint(x: bounds.minX, y: bounds.minY),
                CGPoint(x: bounds.minX, y: bounds.maxY),
                CGPoint(x: bounds.maxX, y: bounds.maxY),
                CGPoint(x: bounds.maxX, y: bounds.minY)
            ]]
        case .ellipse:
            return [ellipsePolygonPoints(for: bounds)]
        case .lasso:
            return []
        case .mask, .composite:
            return []
        }
    }

    nonisolated private func ellipsePolygonPoints(for bounds: CanvasRect, segments: Int = 96) -> [CGPoint] {
        let radiusX = max(bounds.size.x / 2, 0.5)
        let radiusY = max(bounds.size.y / 2, 0.5)
        let centerX = bounds.origin.x + radiusX
        let centerY = bounds.origin.y + radiusY

        return (0..<segments).map { index in
            let angle = (Double(index) / Double(segments)) * .pi * 2
            return CGPoint(
                x: centerX + (cos(angle) * radiusX),
                y: centerY + (sin(angle) * radiusY)
            )
        }
    }

    nonisolated private func selectionMaskShape(
        from polygonShapes: [SelectionPolygonShape],
        canvasSize: CanvasSize,
        preferredDisplayShape: SelectionShape?
    ) -> SelectionShape {
        let components = polygonShapes.flatMap { polygonShape -> [SelectionShapeComponent] in
            polygonShape.compactMap { path in
                let clamped = path.map {
                    CanvasPoint(
                        x: min(max(Double($0.x), 0), Double(canvasSize.width)),
                        y: min(max(Double($0.y), 0), Double(canvasSize.height))
                    )
                }
                guard clamped.count >= 3 else { return nil }
                return SelectionShapeComponent(
                    operation: .add,
                    shape: SelectionShape(
                        kind: .lasso,
                        bounds: CanvasRect.bounding(points: clamped),
                        pathPoints: clamped
                    )
                )
            }
        }

        if components.isEmpty {
            return emptySelectionMaskShape(canvasSize: canvasSize)
        }

        let maskBytes = rasterizedSelectionMaskBytes(
            polygonShapes: polygonShapes,
            canvasSize: canvasSize
        )
        let maskShape = SelectionShape.mask(
            canvasWidth: canvasSize.width,
            canvasHeight: canvasSize.height,
            alphaBytes: maskBytes
        )
        if RuntimeDiagnostics.selectionTraceLoggingEnabled {
            let maskMessage = "[selectionMaskShape] polygonShapeCount=\(polygonShapes.count) maskBoundsOrigin=(\(maskShape.bounds.origin.x),\(maskShape.bounds.origin.y)) maskBoundsSize=(\(maskShape.bounds.size.x),\(maskShape.bounds.size.y)) preferredDisplayKind=\(preferredDisplayShape?.kind.rawValue ?? "nil")"
            Logger(subsystem: "ArtFlex", category: "SelectionTrace").debug("\(maskMessage, privacy: .public)")
            emitSelectionTraceViewModel(maskMessage)
        }

        return SelectionShape(
            kind: .mask,
            bounds: maskShape.bounds,
            pathPoints: preferredDisplayShape?.pathPoints ?? [],
            maskData: maskShape.maskData,
            components: preferredDisplayShape.map {
                [SelectionShapeComponent(operation: .add, shape: $0.clamped(to: canvasSize))]
            } ?? []
        )
    }

    nonisolated private func emptySelectionMaskShape(canvasSize: CanvasSize) -> SelectionShape {
        SelectionShape.mask(
            canvasWidth: canvasSize.width,
            canvasHeight: canvasSize.height,
            alphaBytes: [UInt8](repeating: 0, count: canvasSize.width * canvasSize.height)
        )
    }

    nonisolated private func selectionMaskBytes(for shape: SelectionShape?, canvasSize: CanvasSize) -> [UInt8] {
        guard let shape else {
            return [UInt8](repeating: 0, count: canvasSize.width * canvasSize.height)
        }

        if let maskData = shape.maskData,
           maskData.canvasWidth == canvasSize.width,
           maskData.canvasHeight == canvasSize.height {
            return [UInt8](maskData.alphaBytes)
        }

        let polygonShapes: [SelectionPolygonShape]
        switch shape.kind {
        case .lasso:
            guard shape.pathPoints.count >= 3 else {
                return [UInt8](repeating: 0, count: canvasSize.width * canvasSize.height)
            }
            polygonShapes = [[shape.pathPoints.map { CGPoint(x: $0.x, y: $0.y) }]]
        case .rectangle, .ellipse:
            polygonShapes = [selectionOutlinePoints(for: shape.kind, bounds: shape.bounds)]
        case .mask:
            if shape.components.count == 1,
               let component = shape.components.first,
               component.operation == .add {
                return selectionMaskBytes(for: component.shape, canvasSize: canvasSize)
            }
            if shape.pathPoints.count >= 3 {
                polygonShapes = [[shape.pathPoints.map { CGPoint(x: $0.x, y: $0.y) }]]
            } else {
                return [UInt8](repeating: 0, count: canvasSize.width * canvasSize.height)
            }
        case .composite:
            return compositedSelectionMaskBytes(for: shape, canvasSize: canvasSize)
        }

        return rasterizedSelectionMaskBytes(
            polygonShapes: polygonShapes,
            canvasSize: canvasSize
        )
    }

    nonisolated private func selectionMaskRegion(
        for shape: SelectionShape?,
        canvasSize: CanvasSize,
        originX: Int,
        originY: Int,
        width: Int,
        height: Int
    ) -> SelectionMaskRegion {
        guard width > 0, height > 0 else {
            return SelectionMaskRegion(originX: originX, originY: originY, width: 0, height: 0, alphaBytes: Data())
        }

        guard let shape else {
            return SelectionMaskRegion(
                originX: originX,
                originY: originY,
                width: width,
                height: height,
                alphaBytes: Data(count: width * height)
            )
        }

        if let maskData = shape.maskData,
           maskData.canvasWidth == canvasSize.width,
           maskData.canvasHeight == canvasSize.height {
            return SelectionMaskRegion(
                originX: originX,
                originY: originY,
                width: width,
                height: height,
                alphaBytes: maskRegionBytes(
                    from: maskData.alphaBytes,
                    canvasWidth: canvasSize.width,
                    originX: originX,
                    originY: originY,
                    width: width,
                    height: height
                )
            )
        }

        let polygonShapes: [SelectionPolygonShape]
        switch shape.kind {
        case .lasso:
            guard shape.pathPoints.count >= 3 else {
                return SelectionMaskRegion(
                    originX: originX,
                    originY: originY,
                    width: width,
                    height: height,
                    alphaBytes: Data(count: width * height)
                )
            }
            polygonShapes = [[shape.pathPoints.map { CGPoint(x: $0.x, y: $0.y) }]]
        case .rectangle, .ellipse:
            polygonShapes = [selectionOutlinePoints(for: shape.kind, bounds: shape.bounds)]
        case .mask:
            if shape.components.count == 1,
               let component = shape.components.first,
               component.operation == .add {
                return selectionMaskRegion(
                    for: component.shape,
                    canvasSize: canvasSize,
                    originX: originX,
                    originY: originY,
                    width: width,
                    height: height
                )
            }
            if shape.pathPoints.count >= 3 {
                polygonShapes = [[shape.pathPoints.map { CGPoint(x: $0.x, y: $0.y) }]]
            } else {
                return SelectionMaskRegion(
                    originX: originX,
                    originY: originY,
                    width: width,
                    height: height,
                    alphaBytes: Data(count: width * height)
                )
            }
        case .composite:
            return compositedSelectionMaskRegion(
                for: shape,
                canvasSize: canvasSize,
                originX: originX,
                originY: originY,
                width: width,
                height: height
            )
        }

        return SelectionMaskRegion(
            originX: originX,
            originY: originY,
            width: width,
            height: height,
            alphaBytes: rasterizedSelectionMaskRegionBytes(
                polygonShapes: polygonShapes,
                originX: originX,
                originY: originY,
                width: width,
                height: height
            )
        )
    }

    nonisolated private func featheredSelectionShape(
        _ shape: SelectionShape,
        canvasSize: CanvasSize,
        radiusPixels: Int
    ) throws -> SelectionShape {
        let clampedShape = shape.clamped(to: canvasSize)
        guard !clampedShape.isEmpty else {
            throw SelectionMaskFeatheringError.invalidDimensions
        }

        let minX = max(Int(clampedShape.bounds.minX.rounded(.down)) - radiusPixels, 0)
        let minY = max(Int(clampedShape.bounds.minY.rounded(.down)) - radiusPixels, 0)
        let maxX = min(Int(clampedShape.bounds.maxX.rounded(.up)) + radiusPixels, canvasSize.width)
        let maxY = min(Int(clampedShape.bounds.maxY.rounded(.up)) + radiusPixels, canvasSize.height)
        let width = maxX - minX
        let height = maxY - minY
        guard width > 0, height > 0 else {
            throw SelectionMaskFeatheringError.invalidDimensions
        }

        let sourceRegion = selectionMaskRegion(
            for: clampedShape,
            canvasSize: canvasSize,
            originX: minX,
            originY: minY,
            width: width,
            height: height
        )
        let featheredRegionBytes = try VImageSelectionMaskFeatherer.feather(
            alphaBytes: sourceRegion.alphaBytes,
            width: width,
            height: height,
            radiusPixels: radiusPixels
        )

        var canvasMaskBytes = [UInt8](
            repeating: 0,
            count: canvasSize.width * canvasSize.height
        )
        canvasMaskBytes.withUnsafeMutableBufferPointer { destinationBuffer in
            featheredRegionBytes.withUnsafeBytes { sourceRawBuffer in
                guard
                    let destinationBaseAddress = destinationBuffer.baseAddress,
                    let sourceBaseAddress = sourceRawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else {
                    return
                }

                for row in 0..<height {
                    let sourceOffset = row * width
                    let destinationOffset = ((minY + row) * canvasSize.width) + minX
                    UnsafeMutableRawPointer(destinationBaseAddress.advanced(by: destinationOffset))
                        .copyMemory(
                            from: UnsafeRawPointer(sourceBaseAddress.advanced(by: sourceOffset)),
                            byteCount: width
                        )
                }
            }
        }

        let result = SelectionShape.mask(
            canvasWidth: canvasSize.width,
            canvasHeight: canvasSize.height,
            alphaBytes: canvasMaskBytes
        )
        guard !result.isEmpty else {
            throw SelectionMaskFeatheringError.invalidDimensions
        }

        // The feathered mask controls pixel coverage, while the original vector
        // geometry remains the stable 50% contour used by the marching-ants overlay.
        // Existing mask selections may already carry display-only components.
        let displayComponents: [SelectionShapeComponent]
        if clampedShape.kind == .mask {
            displayComponents = clampedShape.components
        } else {
            displayComponents = [
                SelectionShapeComponent(operation: .add, shape: clampedShape)
            ]
        }
        return SelectionShape(
            kind: .mask,
            bounds: result.bounds,
            pathPoints: clampedShape.pathPoints,
            maskData: result.maskData,
            components: displayComponents
        )
    }

    nonisolated private func maskRegionBytes(
        from alphaBytes: Data,
        canvasWidth: Int,
        originX: Int,
        originY: Int,
        width: Int,
        height: Int
    ) -> Data {
        var result = Data(count: width * height)
        guard !result.isEmpty else { return result }

        result.withUnsafeMutableBytes { destinationRawBuffer in
            alphaBytes.withUnsafeBytes { sourceRawBuffer in
                guard
                    let destinationBase = destinationRawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    let sourceBase = sourceRawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else {
                    return
                }

                for row in 0..<height {
                    let sourceOffset = ((originY + row) * canvasWidth) + originX
                    let destinationOffset = row * width
                    UnsafeMutableRawPointer(destinationBase.advanced(by: destinationOffset))
                        .copyMemory(
                            from: UnsafeRawPointer(sourceBase.advanced(by: sourceOffset)),
                            byteCount: width
                        )
                }
            }
        }

        return result
    }

    nonisolated private func maskRegionBytes(
        from alphaBytes: [UInt8],
        canvasWidth: Int,
        originX: Int,
        originY: Int,
        width: Int,
        height: Int
    ) -> Data {
        var result = Data(count: width * height)
        guard !result.isEmpty else { return result }

        result.withUnsafeMutableBytes { destinationRawBuffer in
            alphaBytes.withUnsafeBufferPointer { sourceBuffer in
                guard
                    let destinationBase = destinationRawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    let sourceBase = sourceBuffer.baseAddress
                else {
                    return
                }

                for row in 0..<height {
                    let sourceOffset = ((originY + row) * canvasWidth) + originX
                    let destinationOffset = row * width
                    UnsafeMutableRawPointer(destinationBase.advanced(by: destinationOffset))
                        .copyMemory(
                            from: UnsafeRawPointer(sourceBase.advanced(by: sourceOffset)),
                            byteCount: width
                        )
                }
            }
        }

        return result
    }

    nonisolated private func applyIncomingMask(
        to result: inout [UInt8],
        incomingMaskData: SelectionMaskData,
        incomingBounds: CanvasRect,
        canvasSize: CanvasSize,
        mode: SelectionCombineMode
    ) {
        let minX = max(Int(floor(incomingBounds.minX)), 0)
        let minY = max(Int(floor(incomingBounds.minY)), 0)
        let maxX = min(Int(ceil(incomingBounds.maxX)), canvasSize.width)
        let maxY = min(Int(ceil(incomingBounds.maxY)), canvasSize.height)
        guard minX < maxX, minY < maxY else { return }

        incomingMaskData.withAlphaBytes { incomingBytes in
            for y in minY..<maxY {
                let rowOffset = y * canvasSize.width
                for x in minX..<maxX {
                    let index = rowOffset + x
                    guard index < incomingBytes.count else { continue }
                    let incoming = incomingBytes[index]
                    guard incoming > 0 else { continue }

                    switch mode {
                    case .replace:
                        result[index] = incoming
                    case .add:
                        result[index] = max(result[index], incoming)
                    case .subtract:
                        let kept = (Int(result[index]) * (255 - Int(incoming))) / 255
                        result[index] = UInt8(clamping: kept)
                    case .intersect:
                        result[index] = UInt8(clamping: (Int(result[index]) * Int(incoming)) / 255)
                    }
                }
            }
        }
    }

    nonisolated private func compositedSelectionMaskBytes(
        for shape: SelectionShape,
        canvasSize: CanvasSize
    ) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: canvasSize.width * canvasSize.height)
        guard canvasSize.width > 0, canvasSize.height > 0 else { return result }

        for component in shape.flattenedComponents() {
            guard let regionBounds = selectionMaskIntersectionRegion(
                for: component.shape,
                canvasSize: canvasSize,
                originX: 0,
                originY: 0,
                width: canvasSize.width,
                height: canvasSize.height
            ) else {
                continue
            }
            let incomingRegion = selectionMaskRegion(
                for: component.shape,
                canvasSize: canvasSize,
                originX: regionBounds.originX,
                originY: regionBounds.originY,
                width: regionBounds.width,
                height: regionBounds.height
            )
            applySelectionMaskRegion(
                to: &result,
                canvasWidth: canvasSize.width,
                incomingRegion: incomingRegion,
                operation: component.operation
            )
        }

        return result
    }

    nonisolated private func compositedSelectionMaskRegion(
        for shape: SelectionShape,
        canvasSize: CanvasSize,
        originX: Int,
        originY: Int,
        width: Int,
        height: Int
    ) -> SelectionMaskRegion {
        var result = Data(count: width * height)
        guard width > 0, height > 0 else {
            return SelectionMaskRegion(originX: originX, originY: originY, width: 0, height: 0, alphaBytes: Data())
        }

        for component in shape.flattenedComponents() {
            guard let regionBounds = selectionMaskIntersectionRegion(
                for: component.shape,
                canvasSize: canvasSize,
                originX: originX,
                originY: originY,
                width: width,
                height: height
            ) else {
                continue
            }
            let incomingRegion = selectionMaskRegion(
                for: component.shape,
                canvasSize: canvasSize,
                originX: regionBounds.originX,
                originY: regionBounds.originY,
                width: regionBounds.width,
                height: regionBounds.height
            )
            applySelectionMaskRegion(
                to: &result,
                destinationOriginX: originX,
                destinationOriginY: originY,
                destinationWidth: width,
                incomingRegion: incomingRegion,
                operation: component.operation
            )
        }

        return SelectionMaskRegion(
            originX: originX,
            originY: originY,
            width: width,
            height: height,
            alphaBytes: result
        )
    }

    nonisolated private func selectionMaskIntersectionRegion(
        for shape: SelectionShape,
        canvasSize: CanvasSize,
        originX: Int,
        originY: Int,
        width: Int,
        height: Int
    ) -> (originX: Int, originY: Int, width: Int, height: Int)? {
        let bounds = shape.bounds.clamped(to: canvasSize)
        let shapeMinX = max(Int(floor(bounds.minX)) - 1, 0)
        let shapeMinY = max(Int(floor(bounds.minY)) - 1, 0)
        let shapeMaxX = min(Int(ceil(bounds.maxX)) + 1, canvasSize.width)
        let shapeMaxY = min(Int(ceil(bounds.maxY)) + 1, canvasSize.height)
        let minX = max(originX, shapeMinX)
        let minY = max(originY, shapeMinY)
        let maxX = min(originX + width, shapeMaxX)
        let maxY = min(originY + height, shapeMaxY)

        guard minX < maxX, minY < maxY else { return nil }
        return (originX: minX, originY: minY, width: maxX - minX, height: maxY - minY)
    }

    nonisolated private func applySelectionMaskRegion(
        to result: inout [UInt8],
        canvasWidth: Int,
        incomingRegion: SelectionMaskRegion,
        operation: SelectionComponentOperation
    ) {
        guard incomingRegion.width > 0, incomingRegion.height > 0 else { return }
        incomingRegion.withAlphaBytes { incomingBytes in
            for localY in 0..<incomingRegion.height {
                let resultRowOffset = (incomingRegion.originY + localY) * canvasWidth
                let incomingRowOffset = localY * incomingRegion.width
                for localX in 0..<incomingRegion.width {
                    let incoming = incomingBytes[incomingRowOffset + localX]
                    guard incoming > 0 else { continue }
                    let resultIndex = resultRowOffset + incomingRegion.originX + localX
                    switch operation {
                    case .add:
                        result[resultIndex] = max(result[resultIndex], incoming)
                    case .subtract:
                        let kept = (Int(result[resultIndex]) * (255 - Int(incoming))) / 255
                        result[resultIndex] = UInt8(clamping: kept)
                    }
                }
            }
        }
    }

    nonisolated private func applySelectionMaskRegion(
        to result: inout Data,
        destinationOriginX: Int,
        destinationOriginY: Int,
        destinationWidth: Int,
        incomingRegion: SelectionMaskRegion,
        operation: SelectionComponentOperation
    ) {
        guard incomingRegion.width > 0, incomingRegion.height > 0 else { return }
        result.withUnsafeMutableBytes { destinationRawBuffer in
            incomingRegion.withAlphaBytes { incomingBytes in
                guard let destinationBase = destinationRawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return
                }
                for localY in 0..<incomingRegion.height {
                    let destinationY = incomingRegion.originY + localY - destinationOriginY
                    let destinationX = incomingRegion.originX - destinationOriginX
                    let destinationRowOffset = (destinationY * destinationWidth) + destinationX
                    let incomingRowOffset = localY * incomingRegion.width
                    for localX in 0..<incomingRegion.width {
                        let incoming = incomingBytes[incomingRowOffset + localX]
                        guard incoming > 0 else { continue }
                        let resultIndex = destinationRowOffset + localX
                        switch operation {
                        case .add:
                            destinationBase[resultIndex] = max(destinationBase[resultIndex], incoming)
                        case .subtract:
                            let kept = (Int(destinationBase[resultIndex]) * (255 - Int(incoming))) / 255
                            destinationBase[resultIndex] = UInt8(clamping: kept)
                        }
                    }
                }
            }
        }
    }

    nonisolated private func rasterizedSelectionMaskBytes(
        polygonShapes: [SelectionPolygonShape],
        canvasSize: CanvasSize
    ) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: canvasSize.width * canvasSize.height)
        guard !polygonShapes.isEmpty else { return result }

        let allPoints = polygonShapes.flatMap { polygonShape in
            polygonShape.flatMap { polygon in
                polygon.map { CanvasPoint(x: Double($0.x), y: Double($0.y)) }
            }
        }
        let bounds = CanvasRect.bounding(points: allPoints).clamped(to: canvasSize)
        let minX = max(Int(floor(bounds.minX)) - 1, 0)
        let minY = max(Int(floor(bounds.minY)) - 1, 0)
        let maxX = min(Int(ceil(bounds.maxX)) + 1, canvasSize.width)
        let maxY = min(Int(ceil(bounds.maxY)) + 1, canvasSize.height)
        if RuntimeDiagnostics.selectionTraceLoggingEnabled {
            let rasterMessage = "[rasterizedSelectionMaskBytes] allPointCount=\(allPoints.count) clampedBoundsOrigin=(\(bounds.origin.x),\(bounds.origin.y)) clampedBoundsSize=(\(bounds.size.x),\(bounds.size.y)) localRect=(\(minX),\(minY))-(\(maxX),\(maxY))"
            Logger(subsystem: "ArtFlex", category: "SelectionTrace").debug("\(rasterMessage, privacy: .public)")
            emitSelectionTraceViewModel(rasterMessage)
        }
        guard minX < maxX, minY < maxY else { return result }

        let width = maxX - minX
        let height = maxY - minY
        let bytesPerRow = width
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var localBytes = [UInt8](repeating: 0, count: width * height)

        guard let context = CGContext(
            data: &localBytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return result
        }
        context.translateBy(x: 0, y: Double(height))
        context.scaleBy(x: 1, y: -1)
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)

        for polygonShape in polygonShapes {
            for polygon in polygonShape {
                guard polygon.count >= 3 else { continue }
                let path = CGMutablePath()
                let localPoints = polygon.map {
                    CGPoint(x: $0.x - Double(minX), y: $0.y - Double(minY))
                }
                path.addLines(between: localPoints)
                path.closeSubpath()

                context.addPath(path)
                context.setBlendMode(.normal)
                context.setFillColor(gray: 1, alpha: 1)
                context.fillPath()
            }
        }

        for localY in 0..<height {
            let destinationRow = (localY + minY) * canvasSize.width
            let sourceRow = localY * width
            for localX in 0..<width {
                result[destinationRow + localX + minX] = localBytes[sourceRow + localX]
            }
        }

        return result
    }

    nonisolated private func rasterizedSelectionMaskRegionBytes(
        polygonShapes: [SelectionPolygonShape],
        originX: Int,
        originY: Int,
        width: Int,
        height: Int
    ) -> Data {
        var result = Data(count: width * height)
        guard !polygonShapes.isEmpty, width > 0, height > 0 else { return result }

        let padding = 1
        let paddedWidth = width + (padding * 2)
        let paddedHeight = height + (padding * 2)
        let bytesPerRow = paddedWidth
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var paddedBytes = [UInt8](repeating: 0, count: paddedWidth * paddedHeight)

        guard let context = CGContext(
            data: &paddedBytes,
            width: paddedWidth,
            height: paddedHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return result
        }

        context.translateBy(
            x: Double(-originX + padding),
            y: Double(originY - padding + paddedHeight)
        )
        context.scaleBy(x: 1, y: -1)
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)

        for polygonShape in polygonShapes {
            for polygon in polygonShape {
                guard polygon.count >= 3 else { continue }
                let path = CGMutablePath()
                path.addLines(between: polygon)
                path.closeSubpath()

                context.addPath(path)
                context.setBlendMode(.normal)
                context.setFillColor(gray: 1, alpha: 1)
                context.fillPath()
            }
        }

        result.withUnsafeMutableBytes { destinationRawBuffer in
            paddedBytes.withUnsafeBufferPointer { sourceBuffer in
                guard
                    let destinationBase = destinationRawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    let sourceBase = sourceBuffer.baseAddress
                else {
                    return
                }

                for localY in 0..<height {
                    let destinationOffset = localY * width
                    let sourceOffset = ((localY + padding) * paddedWidth) + padding
                    UnsafeMutableRawPointer(destinationBase.advanced(by: destinationOffset))
                        .copyMemory(
                            from: UnsafeRawPointer(sourceBase.advanced(by: sourceOffset)),
                            byteCount: width
                        )
                }
            }
        }

        return result
    }

    private func applyGeneratorStroke(
        samples: [CanvasStrokeSample],
        layerID: LayerID,
        baseStroke: StrokeDescriptor
    ) -> Bool {
        switch workspace.generator.kind {
        case .automaticLines:
            var generatorBaseStroke = baseStroke
            generatorBaseStroke.color = baseStroke.color.withAlpha(
                baseStroke.color.alpha * min(max(workspace.generator.opacity, 0.05), 1)
            )
            let transformedStroke = makeAutomaticLineStroke(
                from: generatorBaseStroke,
                settings: workspace.generator,
                session: &generatorStrokeSession
            )
            guard !transformedStroke.points.isEmpty else { return true }
            bootstrap.strokeEngine.applyStroke(transformedStroke, to: layerID)

            if let branchStroke = makeAutomaticLineBranchStroke(
                from: transformedStroke,
                settings: workspace.generator,
                session: &generatorStrokeSession
            ) {
                bootstrap.strokeEngine.applyStroke(branchStroke, to: layerID)
            }
            for companionStroke in makeAutomaticLineCompanionStrokes(
                from: transformedStroke,
                settings: workspace.generator,
                session: &generatorStrokeSession
            ) {
                bootstrap.strokeEngine.applyStroke(companionStroke, to: layerID)
            }
            return true
        case .driftDraw:
            var generatorBaseStroke = baseStroke
            generatorBaseStroke.color = baseStroke.color.withAlpha(
                baseStroke.color.alpha * min(max(workspace.generator.opacity, 0.05), 1)
            )
            let transformedStroke = makeDriftDrawStroke(
                from: generatorBaseStroke,
                settings: workspace.generator,
                session: &generatorStrokeSession
            )
            guard !transformedStroke.points.isEmpty else { return true }
            bootstrap.strokeEngine.applyStroke(transformedStroke, to: layerID)
            return true
        case .elasticWhip, .tremorTrace, .angularBreaks:
            var generatorBaseStroke = baseStroke
            generatorBaseStroke.color = baseStroke.color.withAlpha(
                baseStroke.color.alpha * min(max(workspace.generator.opacity, 0.05), 1)
            )
            let transformedStroke = makeLineGeneratorVariantStroke(
                from: generatorBaseStroke,
                kind: workspace.generator.kind,
                settings: workspace.generator,
                session: &generatorStrokeSession
            )
            guard !transformedStroke.points.isEmpty else { return true }
            bootstrap.strokeEngine.applyStroke(transformedStroke, to: layerID)
            return true
        }
    }

    private func makeLineGeneratorVariantStroke(
        from stroke: StrokeDescriptor,
        kind: GeneratorKind,
        settings: GeneratorSettings,
        session: inout GeneratorStrokeSessionState
    ) -> StrokeDescriptor {
        guard let first = stroke.points.first else { return stroke }

        var random = session.random
        var previousBase = session.lastBasePoint ?? first
        var previousOutput = session.lastOutputPoint ?? first
        var phase = session.fractureImpulse
        var angularState = session.angularVelocity
        let brushSize = Double(max(stroke.brush.size, 1))
        var output: [StrokePoint] = []
        output.reserveCapacity(stroke.points.count)

        for point in stroke.points {
            let dx = point.x - previousBase.x
            let dy = point.y - previousBase.y
            let distance = hypot(dx, dy)
            guard distance > 0.0001 else {
                output.append(previousOutput)
                previousBase = point
                continue
            }
            let angle = atan2(dy, dx)
            let normalX = -sin(angle)
            let normalY = cos(angle)
            let resolved: StrokePoint

            switch kind {
            case .elasticWhip:
                let response = 0.16 + Double(settings.density) * 0.34
                phase += distance / max(brushSize * (1.2 + Double(settings.branch) * 2.8), 1)
                angularState = (angularState * 0.82) + (angle - angularState) * 0.18
                let wave = sin(phase) * brushSize * (0.2 + Double(settings.drift) * 2.1)
                resolved = StrokePoint(
                    x: previousOutput.x + (point.x - previousOutput.x) * response + normalX * wave,
                    y: previousOutput.y + (point.y - previousOutput.y) * response + normalY * wave,
                    pressure: point.pressure
                )
            case .tremorTrace:
                phase += distance / max(brushSize * 0.22, 0.8)
                let amplitude = brushSize * (0.08 + Double(settings.drift) * 0.82)
                let tremor = (sin(phase * 2.7) * 0.68 + sin(phase * 5.3) * 0.23)
                    * amplitude
                    + random.double(in: -0.18...0.18) * amplitude
                resolved = StrokePoint(
                    x: point.x + normalX * tremor,
                    y: point.y + normalY * tremor,
                    pressure: point.pressure
                )
            case .angularBreaks:
                let turnProbability = 0.04 + Double(settings.branch) * 0.22
                if random.double(in: 0...1) < turnProbability {
                    angularState += random.double(in: -1...1) * (.pi / 2)
                } else {
                    let snap = .pi / (3 + Double(Int(settings.density * 3)))
                    angularState = (angle / snap).rounded() * snap
                }
                resolved = StrokePoint(
                    x: previousOutput.x + cos(angularState) * distance,
                    y: previousOutput.y + sin(angularState) * distance,
                    pressure: point.pressure
                )
            case .automaticLines, .driftDraw:
                resolved = point
            }

            output.append(resolved)
            previousBase = point
            previousOutput = resolved
        }

        session.random = random
        session.lastBasePoint = previousBase
        session.lastOutputPoint = previousOutput
        session.fractureImpulse = phase
        session.angularVelocity = angularState

        var result = stroke
        result.points = kind == .angularBreaks ? output : smoothStrokePoints(output)
        return result
    }

    private func makeDriftDrawStroke(
        from stroke: StrokeDescriptor,
        settings: GeneratorSettings,
        session: inout GeneratorStrokeSessionState
    ) -> StrokeDescriptor {
        guard !stroke.points.isEmpty else { return stroke }

        var random = session.random
        var previous = session.lastBasePoint ?? stroke.points[0]
        var driftOffset = session.driftOffset
        var driftVelocity = session.angularVelocity
        var phase = session.fractureImpulse
        let brushSize = Double(max(stroke.brush.size, 1))
        let amplitude = brushSize * (0.16 + Double(settings.drift) * 2.8)
        let response = 0.08 + Double(settings.density) * 0.18

        let points = stroke.points.map { point -> StrokePoint in
            let dx = point.x - previous.x
            let dy = point.y - previous.y
            let distance = max(hypot(dx, dy), 0.0001)
            let normalX = -dy / distance
            let normalY = dx / distance
            phase += distance / max(brushSize * (2.5 - Double(settings.branch)), 1)
            driftVelocity += random.double(in: -1...1) * response
            driftVelocity *= 0.84
            driftOffset = (driftOffset * 0.88) + driftVelocity * amplitude
            let wave = sin(phase) * amplitude * (0.35 + Double(settings.branch) * 0.8)
            previous = point
            return StrokePoint(
                x: point.x + normalX * (driftOffset + wave),
                y: point.y + normalY * (driftOffset + wave),
                pressure: point.pressure
            )
        }

        session.random = random
        session.lastBasePoint = previous
        session.lastOutputPoint = points.last
        session.driftOffset = driftOffset
        session.angularVelocity = driftVelocity
        session.fractureImpulse = phase

        var result = stroke
        result.points = smoothStrokePoints(points)
        return result
    }

    private func makeAutomaticLineStroke(
        from stroke: StrokeDescriptor,
        settings: GeneratorSettings,
        session: inout GeneratorStrokeSessionState
    ) -> StrokeDescriptor {
        guard !stroke.points.isEmpty else {
            return stroke
        }

        var random = session.random
        var lastBasePoint = session.lastBasePoint ?? stroke.points.first
        var lastOutputPoint = session.lastOutputPoint ?? stroke.points.first
        var driftOffset = session.driftOffset
        var angularVelocity = session.angularVelocity
        var fractureImpulse = session.fractureImpulse
        var fractureCountdown = session.fractureCountdown
        let brushSize = Double(max(stroke.brush.size, 1))
        let driftPower = pow(Double(settings.drift), 2.15)
        let densityPower = pow(Double(settings.density), 1.7)
        let branchPower = pow(Double(settings.branch), 1.85)
        let driftDistance = brushSize * (0.18 + (driftPower * 18.0))
        let lagDistance = brushSize * (0.04 + (driftPower * 6.4))
        let densityGain = 0.06 + (densityPower * 2.2)
        var curlPhase = random.double(in: 0...(Double.pi * 2))
        var curlVelocity = random.double(in: -0.35...0.35) * (0.18 + driftPower * 1.6)

        let transformedPoints = stroke.points.map { point -> StrokePoint in
            let base = CanvasPoint(x: point.x, y: point.y)
            let previousBase = CanvasPoint(x: lastBasePoint?.x ?? point.x, y: lastBasePoint?.y ?? point.y)
            let dx = base.x - previousBase.x
            let dy = base.y - previousBase.y
            let distance = max(sqrt((dx * dx) + (dy * dy)), 0.0001)
            let tangent = CanvasPoint(x: dx / distance, y: dy / distance)
            let normal = CanvasPoint(x: -tangent.y, y: tangent.x)

            angularVelocity += random.double(in: -1.85...1.85) * (0.18 + driftPower * 3.4)
            angularVelocity *= max(0.18, 0.62 - (driftPower * 0.34))

            if fractureCountdown <= 0,
               random.double(in: 0...1) < (0.04 + driftPower * 0.3 + branchPower * 0.22) {
                fractureImpulse = random.double(in: -1...1) * driftDistance * (1.2 + driftPower * 3.6)
                fractureCountdown = Int(random.double(in: 2...8))
            } else if fractureCountdown > 0 {
                fractureCountdown -= 1
                fractureImpulse *= 0.72
            } else {
                fractureImpulse *= 0.45
            }

            driftOffset =
                (driftOffset * max(0.08, 0.48 - densityGain * 0.16)) +
                (angularVelocity * driftDistance) +
                random.double(in: -1.8...1.8) * driftDistance * (0.22 + densityGain) +
                fractureImpulse

            curlVelocity += random.double(in: -0.28...0.28) * (0.14 + driftPower * 0.9 + branchPower * 0.45)
            curlVelocity *= 0.92
            curlPhase += curlVelocity

            let lagged = CanvasPoint(
                x: base.x - (tangent.x * lagDistance),
                y: base.y - (tangent.y * lagDistance)
            )
            let rebound = sin(Double(point.pressure) * .pi + angularVelocity * 0.5) * driftDistance * (0.12 + branchPower * 0.55)
            let forwardWhip = tangent.x * fractureImpulse * (0.12 + driftPower * 0.28)
            let forwardWhipY = tangent.y * fractureImpulse * (0.12 + driftPower * 0.28)
            let curlRadius = driftDistance * (0.08 + driftPower * 0.42 + branchPower * 0.16)
            let curlX = cos(curlPhase) * curlRadius
            let curlY = sin(curlPhase) * curlRadius
            let output = CanvasPoint(
                x: lagged.x + (normal.x * (driftOffset + rebound + curlY)) + forwardWhip + (tangent.x * curlX),
                y: lagged.y + (normal.y * (driftOffset + rebound + curlY)) + forwardWhipY + (tangent.y * curlX)
            )

            lastBasePoint = point
            lastOutputPoint = StrokePoint(x: output.x, y: output.y, pressure: point.pressure)
            return StrokePoint(x: output.x, y: output.y, pressure: point.pressure)
        }

        session.random = random
        session.lastBasePoint = lastBasePoint
        session.lastOutputPoint = lastOutputPoint
        session.driftOffset = driftOffset
        session.angularVelocity = angularVelocity
        session.fractureImpulse = fractureImpulse
        session.fractureCountdown = fractureCountdown

        return StrokeDescriptor(
            tool: stroke.tool,
            color: stroke.color,
            brush: stroke.brush,
            points: smoothStrokePoints(transformedPoints),
            selectionShape: stroke.selectionShape,
            alphaLockEnabled: stroke.alphaLockEnabled,
            skipLeadingStamp: stroke.skipLeadingStamp,
            paintVariationSeed: stroke.paintVariationSeed,
            pigmentPalette: stroke.pigmentPalette,
            brushStreamID: stroke.brushStreamID
        )
    }

    private func makeAutomaticLineBranchStroke(
        from stroke: StrokeDescriptor,
        settings: GeneratorSettings,
        session: inout GeneratorStrokeSessionState
    ) -> StrokeDescriptor? {
        guard stroke.points.count >= 4 else {
            return nil
        }

        var random = session.random
        let branchPower = pow(Double(settings.branch), 1.75)
        let driftPower = pow(Double(settings.drift), 1.5)
        let probability = min(0.96, 0.08 + (branchPower * 1.05))
        guard random.double(in: 0...1) < probability else {
            session.random = random
            return nil
        }

        let branchStartIndex = min(max(Int(Double(stroke.points.count - 2) * random.double(in: 0.3...0.75)), 1), stroke.points.count - 2)
        let branchBase = stroke.points[branchStartIndex]
        let nextPoint = stroke.points[branchStartIndex + 1]
        let dx = nextPoint.x - branchBase.x
        let dy = nextPoint.y - branchBase.y
        let distance = max(sqrt((dx * dx) + (dy * dy)), 0.0001)
        let tangent = CanvasPoint(x: dx / distance, y: dy / distance)
        let angle = random.double(in: 0.9...2.4) * (random.double(in: 0...1) > 0.5 ? 1 : -1)
        let rotated = CanvasPoint(
            x: (tangent.x * cos(angle)) - (tangent.y * sin(angle)),
            y: (tangent.x * sin(angle)) + (tangent.y * cos(angle))
        )

        let branchPointCount = max(6, Int(Double(stroke.points.count) * random.double(in: 0.6...1.25)))
        let step = Double(max(stroke.brush.size, 1)) * random.double(in: 1.8...3.8)
        var points: [StrokePoint] = [branchBase]
        var current = CanvasPoint(x: branchBase.x, y: branchBase.y)
        for index in 0..<branchPointCount {
            let drift = random.double(in: -2.4...2.4) * (0.15 + driftPower * 1.8) * Double(max(stroke.brush.size, 1))
            let curl = sin(Double(index) * random.double(in: 0.45...1.1)) * Double(max(stroke.brush.size, 1)) * (0.12 + branchPower * 0.95)
            current = CanvasPoint(
                x: current.x + (rotated.x * step) - (rotated.y * drift * 0.55) + (tangent.x * curl),
                y: current.y + (rotated.y * step) + (rotated.x * drift * 0.55) + (tangent.y * curl)
            )
            let taperedPressure = max(0.18, branchBase.pressure * Float(1 - (Double(index + 1) / Double(branchPointCount + 1)) * 0.55))
            points.append(StrokePoint(x: current.x, y: current.y, pressure: taperedPressure))
        }

        session.random = random
        return StrokeDescriptor(
            tool: stroke.tool,
            color: stroke.color.withAlpha(stroke.color.alpha * Float(0.58 + (settings.branch * 0.18))),
            brush: stroke.brush,
            points: smoothStrokePoints(points),
            selectionShape: stroke.selectionShape,
            alphaLockEnabled: stroke.alphaLockEnabled,
            paintVariationSeed: derivedPaintVariationSeed(stroke.paintVariationSeed, salt: 0xB12A_4C4D),
            pigmentPalette: stroke.pigmentPalette
        )
    }

    private func makeAutomaticLineCompanionStrokes(
        from stroke: StrokeDescriptor,
        settings: GeneratorSettings,
        session: inout GeneratorStrokeSessionState
    ) -> [StrokeDescriptor] {
        guard stroke.points.count >= 3 else {
            return []
        }

        var random = session.random
        let densityPower = pow(Double(settings.density), 1.8)
        let driftPower = pow(Double(settings.drift), 1.5)
        let branchPower = pow(Double(settings.branch), 1.5)
        let extraStrokeCount = min(5, Int((densityPower * 5.6).rounded(.down)))
        guard extraStrokeCount > 0 else {
            session.random = random
            return []
        }

        let brushSize = Double(max(stroke.brush.size, 1))
        let output: [StrokeDescriptor] = (0..<extraStrokeCount).map { index in
            let lateralSign = index.isMultiple(of: 2) ? 1.0 : -1.0
            let fanAngle = random.double(in: 0.45...1.85) * lateralSign
            // 伴随线仍应围绕手势活动；原上限可偏离十几个笔宽，
            // 会令单步历史脏区膨胀并提前触发内存淘汰。
            let lateralOffset = brushSize * random.double(in: 1.2...4.5) * (0.16 + driftPower * 0.72) * lateralSign
            let forwardLag = brushSize * random.double(in: 0.8...3.4) * (0.12 + driftPower * 0.9)
            let points: [StrokePoint] = stroke.points.enumerated().map { pointIndex, point in
                let previous = pointIndex > 0 ? stroke.points[pointIndex - 1] : point
                let dx = point.x - previous.x
                let dy = point.y - previous.y
                let distance = max(sqrt((dx * dx) + (dy * dy)), 0.0001)
                let tangent = CanvasPoint(x: dx / distance, y: dy / distance)
                let normal = CanvasPoint(x: -tangent.y, y: tangent.x)
                let rotated = CanvasPoint(
                    x: (normal.x * cos(fanAngle)) - (normal.y * sin(fanAngle)),
                    y: (normal.x * sin(fanAngle)) + (normal.y * cos(fanAngle))
                )
                let noise = random.double(in: -2.8...2.8) * brushSize * (0.05 + branchPower * 0.8)
                let hook = sin(Double(pointIndex) * random.double(in: 0.35...0.9)) * brushSize * (0.1 + branchPower * 1.1)
                return StrokePoint(
                    x: point.x + (rotated.x * (lateralOffset + noise)) - (tangent.x * (forwardLag - hook)),
                    y: point.y + (rotated.y * (lateralOffset + noise)) - (tangent.y * (forwardLag - hook)),
                    pressure: max(0.12, point.pressure * Float(0.55 + random.double(in: 0.05...0.18)))
                )
            }

            return StrokeDescriptor(
                tool: stroke.tool,
                color: stroke.color.withAlpha(stroke.color.alpha * Float(0.28 + random.double(in: 0.08...0.18))),
                brush: stroke.brush,
                points: smoothStrokePoints(points),
                selectionShape: stroke.selectionShape,
                alphaLockEnabled: stroke.alphaLockEnabled,
                paintVariationSeed: derivedPaintVariationSeed(
                    stroke.paintVariationSeed,
                    salt: UInt32(index + 1) &* 0x45D9_F3B
                ),
                pigmentPalette: stroke.pigmentPalette
            )
        }

        session.random = random
        return output
    }

    private func smoothStrokePoints(_ points: [StrokePoint]) -> [StrokePoint] {
        guard points.count >= 3 else { return points }

        var output: [StrokePoint] = [points[0]]
        for index in 0..<(points.count - 1) {
            let p0 = index > 0 ? points[index - 1] : points[index]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = (index + 2) < points.count ? points[index + 2] : p2
            let distance = max(hypot(p2.x - p1.x, p2.y - p1.y), 0.0001)
            let subdivisions = max(Int(distance / 1.8), 4)

            for step in 1...subdivisions {
                let t = Double(step) / Double(subdivisions)
                let t2 = t * t
                let t3 = t2 * t
                let x = 0.5 * (
                    (2 * p1.x) +
                    (-p0.x + p2.x) * t +
                    ((2 * p0.x) - (5 * p1.x) + (4 * p2.x) - p3.x) * t2 +
                    (-p0.x + (3 * p1.x) - (3 * p2.x) + p3.x) * t3
                )
                let y = 0.5 * (
                    (2 * p1.y) +
                    (-p0.y + p2.y) * t +
                    ((2 * p0.y) - (5 * p1.y) + (4 * p2.y) - p3.y) * t2 +
                    (-p0.y + (3 * p1.y) - (3 * p2.y) + p3.y) * t3
                )
                let pressure = Float(
                    0.5 * (
                        (2 * Double(p1.pressure)) +
                        (-Double(p0.pressure) + Double(p2.pressure)) * t +
                        ((2 * Double(p0.pressure)) - (5 * Double(p1.pressure)) + (4 * Double(p2.pressure)) - Double(p3.pressure)) * t2 +
                        (-Double(p0.pressure) + (3 * Double(p1.pressure)) - (3 * Double(p2.pressure)) + Double(p3.pressure)) * t3
                    )
                )
                output.append(
                    StrokePoint(
                        x: x,
                        y: y,
                        pressure: min(max(pressure, 0.05), 1)
                    )
                )
            }
        }
        return output
    }

    private func applyAutomaticLineGenerator(
        to bytes: inout [UInt8],
        snapshotWidth: Int,
        snapshotHeight: Int,
        bytesPerRow: Int,
        originX: Int,
        originY: Int,
        targetShape: SelectionShape?,
        color: RGBAColor,
        settings: GeneratorSettings
    ) {
        let bounds = targetShape?.bounds ?? CanvasRect(
            origin: CanvasPoint(x: Double(originX), y: Double(originY)),
            size: CanvasPoint(x: Double(snapshotWidth), y: Double(snapshotHeight))
        )
        let boundedWidth = max(bounds.maxX - bounds.minX, 1)
        let boundedHeight = max(bounds.maxY - bounds.minY, 1)
        let area = boundedWidth * boundedHeight
        let baseCount = Int(sqrt(area) * Double(0.18 + (settings.density * 0.45)))
        let strokeCount = min(max(baseCount, 8), 180)
        var random = GeneratorRandom()

        for _ in 0..<strokeCount {
            guard let start = randomPoint(in: bounds, shape: targetShape, random: &random) else {
                continue
            }

            let normalizedLength = 0.18 + (settings.density * 0.52) + random.float(in: -0.08...0.12)
            let length = Float(max(min(boundedWidth, boundedHeight), 1)) * normalizedLength
            let segmentCount = max(6, Int(length / 10))
            let baseAngle = random.float(in: 0...(Float.pi * 2))
            let strokeWidth = random.float(in: 1.2...3.8) * (0.7 + settings.density * 0.8)
            let opacity = min(max(0.18 + random.float(in: 0...0.32), 0.1), 0.55) * settings.opacity
            let points = makeAutomaticLinePoints(
                start: start,
                length: length,
                segmentCount: segmentCount,
                baseAngle: baseAngle,
                drift: settings.drift,
                random: &random
            )
            drawPolyline(
                points,
                width: strokeWidth,
                opacity: opacity,
                color: color,
                bytes: &bytes,
                snapshotWidth: snapshotWidth,
                snapshotHeight: snapshotHeight,
                bytesPerRow: bytesPerRow,
                originX: originX,
                originY: originY,
                targetShape: targetShape
            )

            let branchProbability = 0.06 + (settings.branch * 0.32)
            if points.count > 5 && random.float(in: 0...1) < branchProbability {
                let branchIndex = min(max(Int(Float(points.count - 2) * random.float(in: 0.28...0.82)), 1), points.count - 2)
                let branchStart = points[branchIndex]
                let offsetAngle = random.float(in: -1.45...1.45)
                let branchPoints = makeAutomaticLinePoints(
                    start: branchStart,
                    length: length * random.float(in: 0.28...0.6),
                    segmentCount: max(4, segmentCount / 2),
                    baseAngle: baseAngle + offsetAngle,
                    drift: min(max(settings.drift + 0.18, 0), 1),
                    random: &random
                )
                drawPolyline(
                    branchPoints,
                    width: strokeWidth * random.float(in: 0.42...0.72),
                    opacity: opacity * random.float(in: 0.65...0.92),
                    color: color,
                    bytes: &bytes,
                    snapshotWidth: snapshotWidth,
                    snapshotHeight: snapshotHeight,
                    bytesPerRow: bytesPerRow,
                    originX: originX,
                    originY: originY,
                    targetShape: targetShape
                )
            }
        }
    }

    private func randomPoint(
        in bounds: CanvasRect,
        shape: SelectionShape?,
        random: inout GeneratorRandom
    ) -> CanvasPoint? {
        for _ in 0..<32 {
            let point = CanvasPoint(
                x: random.double(in: bounds.minX...bounds.maxX),
                y: random.double(in: bounds.minY...bounds.maxY)
            )
            if shape?.contains(point) ?? true {
                return point
            }
        }
        return nil
    }

    private func makeAutomaticLinePoints(
        start: CanvasPoint,
        length: Float,
        segmentCount: Int,
        baseAngle: Float,
        drift: Float,
        random: inout GeneratorRandom
    ) -> [CanvasPoint] {
        var points = [start]
        var current = start
        var angle = baseAngle
        var angularVelocity: Float = 0
        var orbitPhase = random.float(in: 0...(Float.pi * 2))
        var orbitVelocity = random.float(in: -0.45...0.45) * (0.18 + drift * 1.4)
        let stepLength = max(length / Float(max(segmentCount, 1)), 2)
        let driftStrength = 0.08 + (drift * 0.42)

        for _ in 0..<segmentCount {
            angularVelocity += random.float(in: -driftStrength...driftStrength)
            angularVelocity *= 0.88 - (drift * 0.18)
            orbitVelocity += random.float(in: -0.22...0.22) * (0.12 + drift * 0.95)
            orbitVelocity *= 0.94
            orbitPhase += orbitVelocity
            angle += angularVelocity + random.float(in: -(driftStrength * 0.75)...(driftStrength * 0.75))

            let orbitRadius = stepLength * (0.12 + drift * 1.1)
            let next = CanvasPoint(
                x: current.x + Double(cos(angle) * stepLength) + Double(cos(orbitPhase + angle * 0.4) * orbitRadius),
                y: current.y + Double(sin(angle) * stepLength) + Double(sin(orbitPhase + angle * 0.4) * orbitRadius)
            )
            points.append(next)
            current = next
        }

        return points
    }

    private func drawPolyline(
        _ points: [CanvasPoint],
        width: Float,
        opacity: Float,
        color: RGBAColor,
        bytes: inout [UInt8],
        snapshotWidth: Int,
        snapshotHeight: Int,
        bytesPerRow: Int,
        originX: Int,
        originY: Int,
        targetShape: SelectionShape?
    ) {
        guard points.count >= 2 else { return }
        let smoothedPoints = smoothGeneratorPath(points)
        guard smoothedPoints.count >= 2 else { return }

        for index in 1..<smoothedPoints.count {
            let start = smoothedPoints[index - 1]
            let end = smoothedPoints[index]
            let dx = end.x - start.x
            let dy = end.y - start.y
            let distance = max(sqrt((dx * dx) + (dy * dy)), 0.0001)
            let steps = max(Int(distance / Double(max(width * 0.22, 0.35))), 1)

            for step in 0...steps {
                let t = Double(step) / Double(steps)
                let point = CanvasPoint(
                    x: start.x + (dx * t),
                    y: start.y + (dy * t)
                )
                let taper = Float(1 - abs((t * 2) - 1))
                let radius = width * (0.7 + (taper * 0.35))
                stampSoftDisc(
                    at: point,
                    radius: radius,
                    opacity: opacity * (0.72 + (taper * 0.28)),
                    color: color,
                    bytes: &bytes,
                    snapshotWidth: snapshotWidth,
                    snapshotHeight: snapshotHeight,
                    bytesPerRow: bytesPerRow,
                    originX: originX,
                    originY: originY,
                    targetShape: targetShape
                )
            }
        }
    }

    private func smoothGeneratorPath(_ points: [CanvasPoint]) -> [CanvasPoint] {
        guard points.count >= 3 else { return points }

        var output: [CanvasPoint] = [points[0]]
        for index in 0..<(points.count - 1) {
            let p0 = index > 0 ? points[index - 1] : points[index]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = (index + 2) < points.count ? points[index + 2] : p2
            let distance = max(hypot(p2.x - p1.x, p2.y - p1.y), 0.0001)
            let subdivisions = max(Int(distance / 2.2), 3)

            for step in 1...subdivisions {
                let t = Double(step) / Double(subdivisions)
                let t2 = t * t
                let t3 = t2 * t
                let x = 0.5 * (
                    (2 * p1.x) +
                    (-p0.x + p2.x) * t +
                    ((2 * p0.x) - (5 * p1.x) + (4 * p2.x) - p3.x) * t2 +
                    (-p0.x + (3 * p1.x) - (3 * p2.x) + p3.x) * t3
                )
                let y = 0.5 * (
                    (2 * p1.y) +
                    (-p0.y + p2.y) * t +
                    ((2 * p0.y) - (5 * p1.y) + (4 * p2.y) - p3.y) * t2 +
                    (-p0.y + (3 * p1.y) - (3 * p2.y) + p3.y) * t3
                )
                output.append(CanvasPoint(x: x, y: y))
            }
        }
        return output
    }

    private func stampSoftDisc(
        at center: CanvasPoint,
        radius: Float,
        opacity: Float,
        color: RGBAColor,
        bytes: inout [UInt8],
        snapshotWidth: Int,
        snapshotHeight: Int,
        bytesPerRow: Int,
        originX: Int,
        originY: Int,
        targetShape: SelectionShape?
    ) {
        let expandedRadius = max(radius, 0.8)
        let minX = max(Int(floor(center.x - Double(expandedRadius))) - originX, 0)
        let maxX = min(Int(ceil(center.x + Double(expandedRadius))) - originX, snapshotWidth - 1)
        let minY = max(Int(floor(center.y - Double(expandedRadius))) - originY, 0)
        let maxY = min(Int(ceil(center.y + Double(expandedRadius))) - originY, snapshotHeight - 1)

        guard minX <= maxX, minY <= maxY else { return }

        for localY in minY...maxY {
            for localX in minX...maxX {
                let globalPoint = CanvasPoint(
                    x: Double(originX + localX) + 0.5,
                    y: Double(originY + localY) + 0.5
                )
                if let targetShape, !targetShape.contains(globalPoint) {
                    continue
                }

                let distanceX = Float(globalPoint.x - center.x)
                let distanceY = Float(globalPoint.y - center.y)
                let distance = sqrt((distanceX * distanceX) + (distanceY * distanceY))
                if distance > expandedRadius {
                    continue
                }

                let falloff = pow(max(0, 1 - (distance / expandedRadius)), 1.7)
                let localOpacity = min(max(opacity * falloff, 0), 1)
                if localOpacity <= 0.001 {
                    continue
                }

                let index = (localY * bytesPerRow) + (localX * 4)
                let destination = LinearPremultipliedColor(
                    bgraBlue: bytes[index],
                    green: bytes[index + 1],
                    red: bytes[index + 2],
                    alpha: bytes[index + 3]
                )
                let source = LinearPremultipliedColor(
                    srgbPremultiplied: color.withAlpha(color.alpha * localOpacity).premultiplied
                )
                let output = source.composited(over: destination).bgra8PremultipliedBytes
                bytes[index] = output.blue
                bytes[index + 1] = output.green
                bytes[index + 2] = output.red
                bytes[index + 3] = output.alpha
            }
        }
    }

    private func applyPickerColorFromPanel() {
        let color = ColorBlocksEngine.pickerColor(from: bootstrap.workspaceStore.state.colorPanel)
        rememberReferenceImagePreviousColor(before: color)
        bootstrap.workspaceStore.updateToolSession { session in
            session.commitSelectedColor(color)
        }
        refreshColorPanelOnly(includeSelectedColor: true)
    }

    private func armQuickColorPickerShortcutIfNeeded() {
        ideationBranchActivityHandler?()
        isQuickColorPickerShortcutActive = true
        guard quickColorPickerState == nil else { return }
        presentQuickColorPickerIfPossible()
    }

    private func cancelQuickColorPickerShortcut() {
        isQuickColorPickerShortcutActive = false
        if quickColorPickerState != nil {
            commitQuickColorPickerSelectionIfNeeded()
            quickColorPickerState = nil
            quickColorPickerDraftState = nil
            isRecentBrushSelectionHighlightActive = false
            syncRecentBrushAdjustmentState(showsSelectionHighlight: false)
        }
    }

    private func presentQuickColorPickerIfPossible() {
        guard let anchorPoint = lastCanvasHoverPoint else { return }

        var panel = workspace.colorPanel
        panel.mode = .picker
        let selectedColor = workspace.toolSession.selectedColor
        ColorBlocksEngine.syncPicker(to: selectedColor, state: &panel)
        panel.baseHSV = ColorBlocksEngine.rgbToHsv(selectedColor)
        let recentBrushSelectionLimit = currentRecentBrushAdjustmentLimit()
        recentBrushAdjustmentSelectedCount = Self.resolvedRecentBrushAdjustmentSelectionCount(
            preferredCount: recentBrushAdjustmentSelectedCount,
            limit: recentBrushSelectionLimit
        )

        let state = QuickColorPickerState(
            anchorPoint: anchorPoint,
            panel: panel,
            recentBrushSelectionCount: recentBrushAdjustmentSelectedCount,
            recentBrushSelectionLimit: recentBrushSelectionLimit,
            recentBrushOpacity: recentBrushAdjustmentOpacity,
            recentBrushBrightness: recentBrushAdjustmentBrightness,
            recentBrushSaturation: recentBrushAdjustmentSaturation
        )
        quickColorPickerDraftState = state
        quickColorPickerState = state
        isRecentBrushSelectionHighlightActive = false
        // Opening the HUD is presentation-only. Recent-brush Metal replay is
        // performed only after the user changes one of its adjustment controls.
        // Keeping it out of this key-down path makes HUD presentation constant-time.
    }

    private func previewQuickColorPickerState(_ state: QuickColorPickerState) {
        quickColorPickerDraftState = state
        let color = ColorBlocksEngine.pickerColor(from: state.panel)
        colorPanelProxy.selectedColor = color
    }

    private func commitQuickColorPickerSelectionIfNeeded() {
        guard let state = quickColorPickerDraftState ?? quickColorPickerState else { return }
        let color = ColorBlocksEngine.pickerColor(from: state.panel)

        rememberReferenceImagePreviousColor(before: color)
        bootstrap.workspaceStore.updateToolSession { session in
            session.commitSelectedColor(color)
        }
        bootstrap.workspaceStore.updateColorPanel { panel in
            guard panel.mode == .picker else { return }
            panel.pickerHue = state.panel.pickerHue
            panel.pickerX = state.panel.pickerX
            panel.pickerY = state.panel.pickerY
            panel.baseHSV = ColorBlocksEngine.rgbToHsv(color)
            panel.baseSource = .synced
            panel.baseName = ""
        }
        refreshColorPanelOnly(includeSelectedColor: true)
    }

    private func currentRecentBrushAdjustmentLayerID() -> LayerID? {
        guard workspace.toolSession.activeTool == .brush else {
            return nil
        }
        return bootstrap.interactionController.activeEditableLayerID()
    }

    private func currentRecentBrushAdjustmentLimit() -> Int {
        guard let layerID = currentRecentBrushAdjustmentLayerID() else {
            return 0
        }
        return bootstrap.strokeEngine.recentAdjustableBrushCommitCount(for: layerID)
    }

    nonisolated static func resolvedRecentBrushAdjustmentSelectionCount(
        preferredCount: Int,
        limit: Int
    ) -> Int {
        guard limit > 0 else {
            return 0
        }
        return min(max(preferredCount, 1), limit)
    }

    private func recentBrushAdjustmentValuesMatch(_ lhs: Float, _ rhs: Float) -> Bool {
        abs(lhs - rhs) < 0.0005
    }

    private func shouldBakeRecentBrushAdjustmentBeforeStartingNewBrushStroke() -> Bool {
        guard workspace.toolSession.activeTool == .brush else {
            return false
        }
        guard recentBrushAdjustmentSelectedCount > 0 else {
            return false
        }
        guard quickColorPickerState == nil else {
            return false
        }
        return bootstrap.strokeEngine.hasPendingBrushCommitJobs
    }

    private func syncRecentBrushAdjustmentState(showsSelectionHighlight: Bool? = nil) {
        let recentBrushSelectionLimit = currentRecentBrushAdjustmentLimit()
        recentBrushAdjustmentSelectedCount = Self.resolvedRecentBrushAdjustmentSelectionCount(
            preferredCount: recentBrushAdjustmentSelectedCount,
            limit: recentBrushSelectionLimit
        )
        recentBrushAdjustmentOpacity = min(max(recentBrushAdjustmentOpacity, 0), 1)
        recentBrushAdjustmentBrightness = min(max(recentBrushAdjustmentBrightness, -1), 1)
        recentBrushAdjustmentSaturation = min(max(recentBrushAdjustmentSaturation, -1), 1)
        if recentBrushSelectionLimit == 0 {
            recentBrushAdjustmentOpacity = 1
            recentBrushAdjustmentBrightness = 0
            recentBrushAdjustmentSaturation = 0
        }

        let resolvedShowsSelectionHighlight = showsSelectionHighlight ?? isRecentBrushSelectionHighlightActive
        let resolvedLayerID = currentRecentBrushAdjustmentLayerID()
        let hasActiveAdjustment = resolvedLayerID != nil && recentBrushAdjustmentSelectedCount > 0
        let targetSyncState = RecentBrushAdjustmentSyncState(
            layerID: hasActiveAdjustment ? resolvedLayerID : nil,
            selectionLimit: recentBrushSelectionLimit,
            selectionCount: recentBrushAdjustmentSelectedCount,
            opacity: recentBrushAdjustmentOpacity,
            brightness: recentBrushAdjustmentBrightness,
            saturation: recentBrushAdjustmentSaturation,
            showsSelectionHighlight: hasActiveAdjustment ? resolvedShowsSelectionHighlight : false
        )

        let didUpdateQuickColorPickerState: Bool
        if var state = quickColorPickerDraftState ?? quickColorPickerState {
            let updatedState = QuickColorPickerState(
                anchorPoint: state.anchorPoint,
                panel: state.panel,
                recentBrushSelectionCount: recentBrushAdjustmentSelectedCount,
                recentBrushSelectionLimit: recentBrushSelectionLimit,
                recentBrushOpacity: recentBrushAdjustmentOpacity,
                recentBrushBrightness: recentBrushAdjustmentBrightness,
                recentBrushSaturation: recentBrushAdjustmentSaturation
            )
            didUpdateQuickColorPickerState = updatedState != state
            if updatedState != state {
                state = updatedState
                quickColorPickerDraftState = state
                quickColorPickerState = state
            }
        } else {
            didUpdateQuickColorPickerState = false
        }

        guard lastRecentBrushAdjustmentSyncState != targetSyncState || didUpdateQuickColorPickerState else {
            return
        }

        if let layerID = resolvedLayerID,
           recentBrushAdjustmentSelectedCount > 0 {
            bootstrap.strokeEngine.setRecentBrushAdjustment(
                layerID: layerID,
                selectedRecentCount: recentBrushAdjustmentSelectedCount,
                opacity: recentBrushAdjustmentOpacity,
                brightness: recentBrushAdjustmentBrightness,
                saturation: recentBrushAdjustmentSaturation,
                showsSelectionHighlight: resolvedShowsSelectionHighlight
            )
        } else {
            bootstrap.strokeEngine.clearRecentBrushAdjustment()
        }

        lastRecentBrushAdjustmentSyncState = targetSyncState
        recentBrushAdjustmentRedrawRevision &+= 1
    }

    private func clearRecentBrushAdjustmentState() {
        recentBrushAdjustmentSelectedCount = 0
        recentBrushAdjustmentOpacity = 1
        recentBrushAdjustmentBrightness = 0
        recentBrushAdjustmentSaturation = 0
        isRecentBrushSelectionHighlightActive = false
        bootstrap.strokeEngine.clearRecentBrushAdjustment()
        lastRecentBrushAdjustmentSyncState = RecentBrushAdjustmentSyncState(
            layerID: nil,
            selectionLimit: currentRecentBrushAdjustmentLimit(),
            selectionCount: 0,
            opacity: 1,
            brightness: 0,
            saturation: 0,
            showsSelectionHighlight: false
        )
        if var state = quickColorPickerDraftState ?? quickColorPickerState {
            state.recentBrushSelectionCount = 0
            state.recentBrushSelectionLimit = currentRecentBrushAdjustmentLimit()
            state.recentBrushOpacity = 1
            state.recentBrushBrightness = 0
            state.recentBrushSaturation = 0
            quickColorPickerDraftState = state
            quickColorPickerState = state
        }
        recentBrushAdjustmentRedrawRevision &+= 1
    }

    private func refreshColorPanelOnly(includeSelectedColor: Bool = false) {
        let state = bootstrap.workspaceStore.state
        var updated = workspace
        updated.colorPanel = state.colorPanel
        if includeSelectedColor {
            updated.toolSession.selectedColor = state.toolSession.selectedColor
            updated.toolSession.oilPaintReservoir = state.toolSession.oilPaintReservoir
        }
        workspace = updated
        colorPanelProxy.colorPanel = state.colorPanel
        if includeSelectedColor {
            colorPanelProxy.selectedColor = state.toolSession.selectedColor
        }
    }

    private func rememberReferenceImagePreviousColor(before nextColor: RGBAColor) {
        let currentColor = workspace.toolSession.selectedColor
        guard currentColor != nextColor else { return }
        referenceImagePreviousPickedColor = currentColor
    }

    @MainActor
    final class ColorPanelProxy: ObservableObject {
        @Published var colorPanel: ColorPanelState = .stageOneDefault
        @Published var selectedColor: RGBAColor = .init(red: 0, green: 0, blue: 0, alpha: 1)
    }

    private(set) lazy var colorPanelProxy: ColorPanelProxy = {
        let proxy = ColorPanelProxy()
        proxy.colorPanel = workspace.colorPanel
        proxy.selectedColor = workspace.toolSession.selectedColor
        return proxy
    }()

    @MainActor
    final class NavigatorPreviewProxy: ObservableObject {
        @Published var sceneSnapshot: CanvasSceneSnapshot
        @Published var redrawRevision: UInt64 = 0

        init(sceneSnapshot: CanvasSceneSnapshot) {
            self.sceneSnapshot = sceneSnapshot
        }
    }

    private(set) lazy var navigatorPreviewProxy: NavigatorPreviewProxy = {
        NavigatorPreviewProxy(sceneSnapshot: navigatorSceneSnapshot)
    }()

    // 选区 overlay 专用代理
    // CanvasContainerView 里的 SelectionOverlay 只订阅它
    // 选区拖动时只有 overlay 重绘，MetalCanvasHost 完全不受影响
    final class SelectionOverlayProxy: ObservableObject {
        let maskCacheNamespace = UUID()
        @Published var displayShape: SelectionShape?
        @Published var committedShape: SelectionShape?
        @Published var inProgressShape: SelectionShape?
        @Published var committedShapeRevision: UInt64 = 0
        @Published var isHiddenForTransientAdjustment: Bool = false
        @Published var activeCombineMode: SelectionCombineMode = .replace
        @Published var isApplyingTransformCommit: Bool = false
        @Published var isTransformingSelection: Bool = false
        @Published var activeTool: ToolKind = .brush
        @Published var smartSelectionDisplayMode: SmartSelectionDisplayMode = .tint
        @Published var transformPreviewOffset: CanvasPoint = .init(x: 0, y: 0)
        @Published var selectionMovePreviewOffset: CanvasPoint = .init(x: 0, y: 0)
        @Published var hidesImplicitFreeTransformSelectionOverlay: Bool = false
        @Published var isFreeTransformDragging: Bool = false
        @Published var activeFreeTransformInteractionMode: FreeTransformInteractionMode?
        @Published var redrawRevision: UInt64 = 0
    }

    private(set) lazy var selectionOverlayProxy: SelectionOverlayProxy = {
        SelectionOverlayProxy()
    }()

    private var hidesSelectionOverlayForAdjustmentPreview: Bool {
        if let colorAdjustmentSession,
           colorAdjustmentSession.hasPendingCommittedEffect,
           case .selection = colorAdjustmentSession.source {
            return true
        }
        if let curveAdjustmentSession,
           curveAdjustmentSession.hasPendingCommittedEffect,
           case .selection = curveAdjustmentSession.source {
            return true
        }
        return false
    }

    // 选区变化时同步到 proxy（由 refreshLightweight 调用）
    private func syncSelectionOverlayProxy() {
        let state = bootstrap.workspaceStore.state
        let sel = state.selection
        if selectionOverlayProxy.displayShape != sel.displayShape {
            selectionOverlayProxy.redrawRevision &+= 1
            selectionOverlayProxy.displayShape = sel.displayShape
        }
        if selectionOverlayProxy.committedShape != sel.committedShape {
            selectionOverlayProxy.committedShapeRevision &+= 1
            selectionOverlayProxy.committedShape = sel.committedShape
        }
        if selectionOverlayProxy.inProgressShape != sel.inProgressShape {
            selectionOverlayProxy.inProgressShape = sel.inProgressShape
        }
        if selectionOverlayProxy.isHiddenForTransientAdjustment != hidesSelectionOverlayForAdjustmentPreview {
            selectionOverlayProxy.isHiddenForTransientAdjustment = hidesSelectionOverlayForAdjustmentPreview
        }
        if selectionOverlayProxy.activeCombineMode != sel.activeCombineMode {
            selectionOverlayProxy.activeCombineMode = sel.activeCombineMode
        }
        if selectionOverlayProxy.isApplyingTransformCommit != isApplyingTransformCommit {
            selectionOverlayProxy.isApplyingTransformCommit = isApplyingTransformCommit
        }
        if selectionOverlayProxy.isTransformingSelection != isTransformingSelection {
            selectionOverlayProxy.isTransformingSelection = isTransformingSelection
        }
        if selectionOverlayProxy.activeTool != state.toolSession.activeTool {
            selectionOverlayProxy.activeTool = state.toolSession.activeTool
        }
        if selectionOverlayProxy.smartSelectionDisplayMode != smartSelectionDisplayMode {
            selectionOverlayProxy.smartSelectionDisplayMode = smartSelectionDisplayMode
        }
        if selectionOverlayProxy.transformPreviewOffset != transformPreviewOffset {
            selectionOverlayProxy.transformPreviewOffset = transformPreviewOffset
        }
        if selectionOverlayProxy.selectionMovePreviewOffset != selectionMovePreviewOffset {
            selectionOverlayProxy.selectionMovePreviewOffset = selectionMovePreviewOffset
        }
        if selectionOverlayProxy.hidesImplicitFreeTransformSelectionOverlay != hidesImplicitFreeTransformSelectionOverlay {
            selectionOverlayProxy.hidesImplicitFreeTransformSelectionOverlay = hidesImplicitFreeTransformSelectionOverlay
        }
        if selectionOverlayProxy.isFreeTransformDragging != isFreeTransformDragging {
            selectionOverlayProxy.isFreeTransformDragging = isFreeTransformDragging
        }
        if selectionOverlayProxy.activeFreeTransformInteractionMode != activeFreeTransformInteractionMode {
            selectionOverlayProxy.activeFreeTransformInteractionMode = activeFreeTransformInteractionMode
        }
    }

    private func syncNavigatorPreviewProxy() {
        let snapshot = navigatorSceneSnapshot
        guard navigatorPreviewProxy.sceneSnapshot != snapshot else { return }
        navigatorPreviewProxy.sceneSnapshot = snapshot
    }

}

private struct EditablePixel {
    var blue: UInt8
    var green: UInt8
    var red: UInt8
    var alpha: UInt8
}

private struct SelectionMaskRegion {
    var originX: Int
    var originY: Int
    var width: Int
    var height: Int
    var alphaBytes: Data

    @inline(__always)
    func withAlphaBytes<Result>(_ body: (UnsafeBufferPointer<UInt8>) -> Result) -> Result {
        alphaBytes.withUnsafeBytes { rawBuffer in
            body(rawBuffer.bindMemory(to: UInt8.self))
        }
    }
}

private struct TextureFillSlice {
    var anchorPoint: CanvasPoint
    var previousEdgePoint: CanvasPoint
    var currentEdgePoint: CanvasPoint
}

private struct TextureFillGestureState {
    var layerID: LayerID
    var surfaceID: LayerSurfaceID
    var anchorPoint: CanvasPoint
    var sessionSeed: UInt64
    var baseTexture: MTLTexture?
    var rawEdgePoints: [CanvasPoint]
    var tipSettings: TextureFillTipSettings
    var brush: BrushSettings
    var color: RGBAColor
    var lastEdgePoint: CanvasPoint?
    var renderedSliceCount = 0
}

private struct GeneratorStrokeSessionState {
    var lastBasePoint: StrokePoint?
    var lastOutputPoint: StrokePoint?
    var driftOffset: Double = 0
    var angularVelocity: Double = 0
    var fractureImpulse: Double = 0
    var fractureCountdown: Int = 0
    var random: GeneratorRandom

    init(kind: GeneratorKind = .automaticLines) {
        random = GeneratorRandom(seed: Self.seed(for: kind))
    }

    private static func seed(for kind: GeneratorKind) -> UInt64 {
        kind.rawValue.utf8.reduce(0xA076_1D64_78BD_642F) { partial, byte in
            (partial ^ UInt64(byte)) &* 0xE703_7ED1_A0B4_28DB
        }
    }
}

private struct DeferredGradientDrag {
    var tool: ToolKind
    var points: [CanvasPoint]
    var modifiers: NSEvent.ModifierFlags
    var didEnd: Bool
}

private enum DeferredGradientAction {
    case toolSwitch(ToolKind)
    case gradientDrag(DeferredGradientDrag)
}

let straightLineDefaultThicknessDeadZoneScreenDistance: Double = 50

func straightLineThicknessDeadZoneCanvasDistance(
    screenDistance: Double = straightLineDefaultThicknessDeadZoneScreenDistance,
    actualDisplayScale: Double
) -> Double {
    max(screenDistance / max(actualDisplayScale, 0.000_001), 1)
}

enum StraightLinePhase: Sendable, Equatable {
    case idle
    case drawingLine
    case adjustingThickness
    case pending
}

struct StraightLinePreview: Sendable {
    let pointA: CanvasPoint
    let pointB: CanvasPoint
    let thicknessHandlePoint: CanvasPoint?
    let isPending: Bool
}

struct StraightLineInteractionState: Sendable {
    var phase: StraightLinePhase = .idle
    var pointA: CanvasPoint?
    var pointB: CanvasPoint?
    var lastDragPoint: CanvasPoint?
    var baseBrushSize: Float = 1
    var paintVariationSeed: UInt32?
    var thicknessAdjustmentDeadZone = straightLineDefaultThicknessDeadZoneScreenDistance
    var thicknessDragOrigin: CanvasPoint?
    var thicknessPerpendicularUnit: CanvasPoint?
    var thicknessHandlePoint: CanvasPoint?
    var turnCandidateOrigin: CanvasPoint?
    var turnCandidatePerpendicularUnit: CanvasPoint?

    mutating func begin(
        at point: CanvasPoint,
        brushSize: Float,
        paintVariationSeed: UInt32,
        thicknessAdjustmentDeadZone: Double = straightLineDefaultThicknessDeadZoneScreenDistance
    ) {
        self = StraightLineInteractionState(
            phase: .drawingLine,
            pointA: point,
            pointB: point,
            lastDragPoint: point,
            baseBrushSize: max(brushSize, 1),
            paintVariationSeed: paintVariationSeed,
            thicknessAdjustmentDeadZone: max(thicknessAdjustmentDeadZone, 1)
        )
    }

    @discardableResult
    mutating func updateDrag(to point: CanvasPoint) -> Float? {
        switch phase {
        case .idle, .pending:
            return nil
        case .adjustingThickness:
            guard let origin = thicknessDragOrigin,
                  let perpendicular = thicknessPerpendicularUnit else {
                return nil
            }
            thicknessHandlePoint = point
            lastDragPoint = point
            return Self.adjustedBrushSize(
                baseBrushSize: baseBrushSize,
                origin: origin,
                perpendicularUnit: perpendicular,
                point: point,
                deadZone: thicknessAdjustmentDeadZone
            )
        case .drawingLine:
            guard let pointA, let lastDragPoint else { return nil }

            if let candidateOrigin = turnCandidateOrigin,
               let candidatePerpendicular = turnCandidatePerpendicularUnit {
                return resolveTurnCandidate(
                    at: point,
                    origin: candidateOrigin,
                    perpendicularUnit: candidatePerpendicular
                )
            }

            let lineX = lastDragPoint.x - pointA.x
            let lineY = lastDragPoint.y - pointA.y
            let lineLength = hypot(lineX, lineY)
            let movementX = point.x - lastDragPoint.x
            let movementY = point.y - lastDragPoint.y
            let movementLength = hypot(movementX, movementY)

            if lineLength >= 24, movementLength >= 1 {
                let direction = CanvasPoint(x: lineX / lineLength, y: lineY / lineLength)
                let perpendicular = CanvasPoint(x: -direction.y, y: direction.x)
                let parallelMovement = (movementX * direction.x) + (movementY * direction.y)
                let perpendicularMovement = (movementX * perpendicular.x) + (movementY * perpendicular.y)

                if abs(perpendicularMovement) > max(1, abs(parallelMovement) * 1.35) {
                    turnCandidateOrigin = lastDragPoint
                    turnCandidatePerpendicularUnit = perpendicular
                    self.lastDragPoint = point
                    return resolveTurnCandidate(
                        at: point,
                        origin: lastDragPoint,
                        perpendicularUnit: perpendicular
                    )
                }
            }

            pointB = point
            self.lastDragPoint = point
            return nil
        }
    }

    @discardableResult
    mutating func finishDrag(at point: CanvasPoint) -> Bool {
        switch phase {
        case .idle, .pending:
            return false
        case .drawingLine:
            pointB = turnCandidateOrigin ?? point
            clearTurnCandidate()
        case .adjustingThickness:
            _ = updateDrag(to: point)
        }

        guard let pointA, let pointB, hypot(pointB.x - pointA.x, pointB.y - pointA.y) > 0.5 else {
            self = .init()
            return false
        }
        phase = .pending
        lastDragPoint = nil
        clearTurnCandidate()
        return true
    }

    var preview: StraightLinePreview? {
        guard phase != .idle, let pointA, let pointB else { return nil }
        return StraightLinePreview(
            pointA: pointA,
            pointB: pointB,
            thicknessHandlePoint: thicknessHandlePoint,
            isPending: phase == .pending
        )
    }

    private mutating func resolveTurnCandidate(
        at point: CanvasPoint,
        origin: CanvasPoint,
        perpendicularUnit: CanvasPoint
    ) -> Float? {
        let direction = CanvasPoint(
            x: perpendicularUnit.y,
            y: -perpendicularUnit.x
        )
        let offsetX = point.x - origin.x
        let offsetY = point.y - origin.y
        let parallelDistance = (offsetX * direction.x) + (offsetY * direction.y)
        let perpendicularDistance = (offsetX * perpendicularUnit.x) + (offsetY * perpendicularUnit.y)
        let activationDistance = thicknessAdjustmentDeadZone
        pointB = origin

        if abs(perpendicularDistance) >= activationDistance,
           abs(perpendicularDistance) > abs(parallelDistance) * 1.15 {
            phase = .adjustingThickness
            pointB = origin
            thicknessDragOrigin = origin
            thicknessPerpendicularUnit = perpendicularUnit
            thicknessHandlePoint = point
            lastDragPoint = point
            clearTurnCandidate()
            return Self.adjustedBrushSize(
                baseBrushSize: baseBrushSize,
                origin: origin,
                perpendicularUnit: perpendicularUnit,
                point: point,
                deadZone: activationDistance
            )
        }

        let cancellationDistance = max(12, min(activationDistance * 0.2, 32))
        if abs(parallelDistance) > abs(perpendicularDistance),
           hypot(offsetX, offsetY) >= cancellationDistance {
            pointB = point
            clearTurnCandidate()
        }
        lastDragPoint = point
        return nil
    }

    private mutating func clearTurnCandidate() {
        turnCandidateOrigin = nil
        turnCandidatePerpendicularUnit = nil
    }

    private static func adjustedBrushSize(
        baseBrushSize: Float,
        origin: CanvasPoint,
        perpendicularUnit: CanvasPoint,
        point: CanvasPoint,
        deadZone: Double
    ) -> Float {
        let offsetX = point.x - origin.x
        let offsetY = point.y - origin.y
        let signedDistance = (offsetX * perpendicularUnit.x) + (offsetY * perpendicularUnit.y)
        let effectiveDistance = max(abs(signedDistance) - deadZone, 0)
        let signedEffectiveDistance = signedDistance < 0 ? -effectiveDistance : effectiveDistance
        return min(max(baseBrushSize + Float(signedEffectiveDistance), 1), 1_000)
    }
}

enum PolygonSelectionPhase: Sendable {
    case idle
    case building
}

struct PolygonSelectionPreview: Sendable {
    let vertices: [CanvasPoint]
    let hoverPoint: CanvasPoint?
    let closesToFirst: Bool
}

struct PolygonSelectionInteractionState: Sendable {
    var phase: PolygonSelectionPhase = .idle
    var vertices: [CanvasPoint] = []
    var hoverPoint: CanvasPoint?
    var combineMode: SelectionCombineMode = .replace

    var preview: PolygonSelectionPreview? {
        guard phase == .building, !vertices.isEmpty else { return nil }
        let closesToFirst: Bool
        if let hoverPoint, let first = vertices.first, vertices.count >= 3 {
            closesToFirst = hypot(hoverPoint.x - first.x, hoverPoint.y - first.y) <= 12
        } else {
            closesToFirst = false
        }
        return PolygonSelectionPreview(
            vertices: vertices,
            hoverPoint: hoverPoint,
            closesToFirst: closesToFirst
        )
    }
}

private struct GeneratorRandom {
    private var state: UInt64

    init(seed: UInt64 = 0x9E37_79B9_7F4A_7C15) {
        state = seed
    }

    mutating func float(in range: ClosedRange<Float>) -> Float {
        let unit = Float(nextUnit())
        return range.lowerBound + ((range.upperBound - range.lowerBound) * unit)
    }

    mutating func double(in range: ClosedRange<Double>) -> Double {
        let unit = nextUnit()
        return range.lowerBound + ((range.upperBound - range.lowerBound) * unit)
    }

    private mutating func nextUnit() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let mantissa = state >> 11
        return Double(mantissa) / Double(1 << 53)
    }
}

/// non-Sendable 타입을 DispatchQueue 클로저에서 캡처하기 위한 래퍼
private final class WorkspaceUncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

private func bgraToRGBA(_ bytes: [UInt8]) -> [UInt8] {
    guard !bytes.isEmpty else { return bytes }
    var rgba = bytes
    for index in stride(from: 0, to: bytes.count, by: 4) {
        rgba[index] = bytes[index + 2]
        rgba[index + 1] = bytes[index + 1]
        rgba[index + 2] = bytes[index]
        rgba[index + 3] = bytes[index + 3]
    }
    return rgba
}

private func rgbaToBGRA(_ bytes: [UInt8]) -> [UInt8] {
    guard !bytes.isEmpty else { return bytes }
    var bgra = bytes
    for index in stride(from: 0, to: bytes.count, by: 4) {
        bgra[index] = bytes[index + 2]
        bgra[index + 1] = bytes[index + 1]
        bgra[index + 2] = bytes[index]
        bgra[index + 3] = bytes[index + 3]
    }
    return bgra
}

private func rgbaImage(
    width: Int,
    height: Int,
    bytesPerRow: Int,
    rgbaBytes: [UInt8]
) -> CGImage? {
    guard let provider = CGDataProvider(data: Data(rgbaBytes) as CFData) else {
        return nil
    }
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: true,
        intent: .defaultIntent
    )
}

private func makeRGBAContext(
    width: Int,
    height: Int,
    bytesPerRow: Int,
    bytes: UnsafeMutableRawPointer
) -> CGContext? {
    CGContext(
        data: bytes,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).rawValue
    )
}

/// 픽셀 이동 계산 - top-level이라 @MainActor 제약 없이 백그라운드 스레드에서 호출 가능
private func shiftLayerPixels(
    snapshot: LayerTextureSnapshot,
    selection: SelectionShape,
    dx: Int,
    dy: Int
) -> LayerTextureSnapshot {
    let w = snapshot.width; let h = snapshot.height
    let bpr = snapshot.bytesPerRow; let bpp = 4
    var dst = [UInt8](snapshot.pixelData)

    let minX = max(Int(selection.bounds.minX.rounded(.down)), 0)
    let minY = max(Int(selection.bounds.minY.rounded(.down)), 0)
    let maxX = min(Int(selection.bounds.maxX.rounded(.up)), w)
    let maxY = min(Int(selection.bounds.maxY.rounded(.up)), h)

    snapshot.pixelData.withUnsafeBytes { rawBuffer in
        let src = rawBuffer.bindMemory(to: UInt8.self)
        if selection.kind == .rectangle {
            for y in minY..<maxY {
                for x in minX..<maxX {
                    let si = (y * bpr) + (x * bpp)
                    dst[si] = 0; dst[si+1] = 0; dst[si+2] = 0; dst[si+3] = 0
                }
            }
            for y in minY..<maxY {
                let ny = y + dy; guard ny >= 0, ny < h else { continue }
                for x in minX..<maxX {
                    let nx = x + dx; guard nx >= 0, nx < w else { continue }
                    let si = (y * bpr) + (x * bpp)
                    let di = (ny * bpr) + (nx * bpp)
                    dst[di] = src[si]; dst[di+1] = src[si+1]
                    dst[di+2] = src[si+2]; dst[di+3] = src[si+3]
                }
            }
        } else {
            let rw = maxX - minX; let rh = maxY - minY
            var mask = [Bool](repeating: false, count: rw * rh)
            for ly in 0..<rh {
                for lx in 0..<rw {
                    mask[ly * rw + lx] = selection.contains(
                        CanvasPoint(x: Double(minX + lx) + 0.5, y: Double(minY + ly) + 0.5)
                    )
                }
            }
            for ly in 0..<rh {
                for lx in 0..<rw {
                    guard mask[ly * rw + lx] else { continue }
                    let si = ((minY+ly) * bpr) + ((minX+lx) * bpp)
                    dst[si] = 0; dst[si+1] = 0; dst[si+2] = 0; dst[si+3] = 0
                }
            }
            for ly in 0..<rh {
                for lx in 0..<rw {
                    guard mask[ly * rw + lx] else { continue }
                    let x = minX+lx; let y = minY+ly
                    let si = (y * bpr) + (x * bpp)
                    let nx = x + dx; let ny = y + dy
                    guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                    let di = (ny * bpr) + (nx * bpp)
                    dst[di] = src[si]; dst[di+1] = src[si+1]
                    dst[di+2] = src[si+2]; dst[di+3] = src[si+3]
                }
            }
        }
    }
    return LayerTextureSnapshot(width: w, height: h, bytesPerRow: bpr, pixelData: Data(dst))
}

private func affineTransformLayerPixels(
    snapshot: LayerTextureSnapshot,
    selection: SelectionShape,
    preview: FreeTransformPreview
) -> LayerTextureSnapshot {
    let width = snapshot.width
    let height = snapshot.height
    let bytesPerRow = snapshot.bytesPerRow
    let bytesPerPixel = 4

    let minX = max(Int(selection.bounds.minX.rounded(.down)), 0)
    let minY = max(Int(selection.bounds.minY.rounded(.down)), 0)
    let maxX = min(Int(selection.bounds.maxX.rounded(.up)), width)
    let maxY = min(Int(selection.bounds.maxY.rounded(.up)), height)
    guard minX < maxX, minY < maxY else { return snapshot }

    let cropWidth = maxX - minX
    let cropHeight = maxY - minY
    let cropBytesPerRow = cropWidth * bytesPerPixel

    var sourceBGRA = [UInt8](snapshot.pixelData)

    // 選択領域のクロップを BGRA のまま抽出し、ソースから消去
    var cropBGRA = [UInt8](repeating: 0, count: cropBytesPerRow * cropHeight)
    func extractSelectedPixels(maskBytes: UnsafeBufferPointer<UInt8>?) {
        for localY in 0..<cropHeight {
            let y = minY + localY
            for localX in 0..<cropWidth {
                let x = minX + localX
                let isSelected: Bool
                if let maskBytes {
                    let maskIndex = (y * width) + x
                    isSelected = maskIndex < maskBytes.count && maskBytes[maskIndex] > 0
                } else {
                    isSelected = true
                }
                guard isSelected else { continue }
                let si = (y * bytesPerRow) + (x * bytesPerPixel)
                let ci = (localY * cropBytesPerRow) + (localX * bytesPerPixel)
                cropBGRA[ci] = sourceBGRA[si]; cropBGRA[ci+1] = sourceBGRA[si+1]
                cropBGRA[ci+2] = sourceBGRA[si+2]; cropBGRA[ci+3] = sourceBGRA[si+3]
                sourceBGRA[si] = 0; sourceBGRA[si+1] = 0
                sourceBGRA[si+2] = 0; sourceBGRA[si+3] = 0
            }
        }
    }

    if selection.kind == .rectangle {
        extractSelectedPixels(maskBytes: nil)
    } else if let maskData = selection.maskData,
              maskData.canvasWidth == width,
              maskData.canvasHeight == height {
        maskData.withAlphaBytes { maskBytes in
            extractSelectedPixels(maskBytes: maskBytes)
        }
    } else {
        var fullMaskBytes = [UInt8](repeating: 0, count: width * height)
        for y in minY..<maxY {
            for x in minX..<maxX {
                let point = CanvasPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                if selection.contains(point) {
                    fullMaskBytes[(y * width) + x] = 255
                }
            }
        }
        fullMaskBytes.withUnsafeBufferPointer { maskBytes in
            extractSelectedPixels(maskBytes: maskBytes)
        }
    }

    // vImage でアフィン変換（BGRA のまま処理、RGBA 変換不要）
    guard let inverseTransform = freeTransformAffineTransform(bounds: selection.bounds, preview: preview).invertedIfPossible else {
        return snapshot
    }

    let transformedCorners = freeTransformCornerPoints(bounds: selection.bounds, preview: preview)
    let transformedBounds = CanvasRect.bounding(points: transformedCorners)
    let outMinX = max(Int(transformedBounds.minX.rounded(.down)) - 1, 0)
    let outMinY = max(Int(transformedBounds.minY.rounded(.down)) - 1, 0)
    let outMaxX = min(Int(transformedBounds.maxX.rounded(.up)) + 1, width)
    let outMaxY = min(Int(transformedBounds.maxY.rounded(.up)) + 1, height)
    guard outMinX < outMaxX, outMinY < outMaxY else {
        return LayerTextureSnapshot(width: width, height: height, bytesPerRow: bytesPerRow, pixelData: Data(sourceBGRA))
    }

    let outWidth = outMaxX - outMinX
    let outHeight = outMaxY - outMinY
    let outBytesPerRow = outWidth * bytesPerPixel
    var transformedBGRA = [UInt8](repeating: 0, count: outBytesPerRow * outHeight)

    // アフィン変換をピクセルループで実行（BGRA のまま、Float 演算で高速化）
    let ia = Float(inverseTransform.a); let ib = Float(inverseTransform.b)
    let ic = Float(inverseTransform.c); let id = Float(inverseTransform.d)
    let itx = Float(inverseTransform.tx); let ity = Float(inverseTransform.ty)
    let cropW = Float(cropWidth); let cropH = Float(cropHeight)
    let fMinX = Float(minX); let fMinY = Float(minY)

    for y in outMinY..<outMaxY {
        let fy = Float(y) + 0.5
        let localY = y - outMinY
        for x in outMinX..<outMaxX {
            let fx = Float(x) + 0.5
            // アフィン逆変換
            let sx = ia * fx + ic * fy + itx - fMinX - 0.5
            let sy = ib * fx + id * fy + ity - fMinY - 0.5

            // バイリニアサンプリング（Float で処理）
            let x0 = Int(sx); let y0 = Int(sy)
            guard x0 >= -1, y0 >= -1, x0 < Int(cropW), y0 < Int(cropH) else { continue }

            let x1 = x0 + 1; let y1 = y0 + 1
            let tx = sx - Float(x0); let ty = sy - Float(y0)

            func sampleByte(_ px: Int, _ py: Int, _ ch: Int) -> Float {
                guard px >= 0, py >= 0, px < cropWidth, py < cropHeight else { return 0 }
                return Float(cropBGRA[(py * cropBytesPerRow) + (px * bytesPerPixel) + ch])
            }

            let a00 = sampleByte(x0,y0,3); let a10 = sampleByte(x1,y0,3)
            let a01 = sampleByte(x0,y1,3); let a11 = sampleByte(x1,y1,3)
            let srcA = (a00*(1-tx) + a10*tx)*(1-ty) + (a01*(1-tx) + a11*tx)*ty
            guard srcA > 0 else { continue }

            let di = (localY * outBytesPerRow) + ((x - outMinX) * bytesPerPixel)
            for ch in 0..<4 {
                let c00 = sampleByte(x0,y0,ch); let c10 = sampleByte(x1,y0,ch)
                let c01 = sampleByte(x0,y1,ch); let c11 = sampleByte(x1,y1,ch)
                let sampled = (c00*(1-tx) + c10*tx)*(1-ty) + (c01*(1-tx) + c11*tx)*ty
                transformedBGRA[di+ch] = UInt8(min(255, max(0, sampled.rounded())))
            }
        }
    }

    // 変換結果をソース画像にコンポジット（プリマルチアルファ合成）
    for localY in 0..<outHeight {
        let y = outMinY + localY
        guard y >= 0, y < height else { continue }
        for localX in 0..<outWidth {
            let x = outMinX + localX
            guard x >= 0, x < width else { continue }
            let si = (localY * outBytesPerRow) + (localX * bytesPerPixel)
            let srcA = Float(transformedBGRA[si+3]) / 255.0
            guard srcA > 0 else { continue }
            let di = (y * bytesPerRow) + (x * bytesPerPixel)
            let dstA = Float(sourceBGRA[di+3]) / 255.0
            let outA = srcA + dstA * (1 - srcA)
            guard outA > 0 else { continue }
            for ch in 0..<3 {
                let srcC = Float(transformedBGRA[si+ch]) / 255.0
                let dstC = Float(sourceBGRA[di+ch]) / 255.0
                sourceBGRA[di+ch] = UInt8(min(255, max(0, ((srcC + dstC * (1-srcA)) / outA * 255).rounded())))
            }
            sourceBGRA[di+3] = UInt8(min(255, (outA * 255).rounded()))
        }
    }

    return LayerTextureSnapshot(width: width, height: height, bytesPerRow: bytesPerRow, pixelData: Data(sourceBGRA))
}

private extension CGAffineTransform {
    var invertedIfPossible: CGAffineTransform? {
        let determinant = a * d - b * c
        guard abs(determinant) > 0.000001 else { return nil }
        return inverted()
    }
}

private func bilinearSamplePremultipliedRGBA(
    bytes: [UInt8],
    width: Int,
    height: Int,
    bytesPerRow: Int,
    x: Double,
    y: Double
) -> (Double, Double, Double, Double) {
    guard width > 0, height > 0 else { return (0, 0, 0, 0) }

    let x0 = Int(floor(x))
    let y0 = Int(floor(y))
    let x1 = x0 + 1
    let y1 = y0 + 1
    let tx = x - Double(x0)
    let ty = y - Double(y0)

    func pixel(_ px: Int, _ py: Int) -> (Double, Double, Double, Double) {
        guard px >= 0, py >= 0, px < width, py < height else { return (0, 0, 0, 0) }
        let index = (py * bytesPerRow) + (px * 4)
        return (
            Double(bytes[index]) / 255.0,
            Double(bytes[index + 1]) / 255.0,
            Double(bytes[index + 2]) / 255.0,
            Double(bytes[index + 3]) / 255.0
        )
    }

    let p00 = pixel(x0, y0)
    let p10 = pixel(x1, y0)
    let p01 = pixel(x0, y1)
    let p11 = pixel(x1, y1)

    func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + ((b - a) * t)
    }

    let top = (
        lerp(p00.0, p10.0, tx),
        lerp(p00.1, p10.1, tx),
        lerp(p00.2, p10.2, tx),
        lerp(p00.3, p10.3, tx)
    )
    let bottom = (
        lerp(p01.0, p11.0, tx),
        lerp(p01.1, p11.1, tx),
        lerp(p01.2, p11.2, tx),
        lerp(p01.3, p11.3, tx)
    )

    return (
        lerp(top.0, bottom.0, ty),
        lerp(top.1, bottom.1, ty),
        lerp(top.2, bottom.2, ty),
        lerp(top.3, bottom.3, ty)
    )
}

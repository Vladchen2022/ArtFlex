import Foundation
import Metal
import ArtFlexPolicies

/// macOS editor lifetime owner. Model geometry stays in Core; native draft presentations live here.
/// The workspace facade forwards to this storage so replacement cannot leave a second live copy.
@MainActor
final class WorkspaceEditingSessions {
    var onStateChange: (() -> Void)?
    let preparation = DocumentPreparationCoordinator()
    let selectionPreview = LatestPreviewCoordinator<SelectionShape?>()
    let texturePreview = LatestPreviewCoordinator<WorkspaceUncheckedBox<MTLTexture>>()
    let gradient = GradientSessionController()
    private(set) var generation: UInt64 = 0
    struct LayerPickContext {
        let id: UUID
        let document: ArtDocument
        let contentRevision: UInt64
    }
    var layerPickContext: LayerPickContext?
    var activeMaskEditingLayerID: LayerID? { willSet { onStateChange?() } }
    var lastLayerMaskStrokeSample: CanvasStrokeSample?
    var maskStrokeHistoryAccepted = false
    var isPreparingDocumentEdit: Bool = false { willSet { onStateChange?() } }
    var editableLayerDraft: EditableLayerDraft? { willSet { onStateChange?() } didSet { if oldValue !== editableLayerDraft { oldValue?.cancel() } } }
    var selectionRefinementDraft: SelectionRefinementDraft? { willSet { onStateChange?() } }
    var selectionPreviewRequest: UUID = UUID()
    var recentTextureFill: RecentTextureFill?
    var isTextureAdjustmentComputing: Bool = false { willSet { onStateChange?() } }
    var textureAdjustmentError: String? { willSet { onStateChange?() } }
    var textureAdjustmentSettings: TextureFillTipSettings? { willSet { onStateChange?() } }
    var canAdjustRecentTextureFill: Bool = false { willSet { onStateChange?() } }
    var textureAdjustmentInitialFill: RecentTextureFill?
    var textureAdjustmentOriginal: MTLTexture?
    var canvasCropState: CanvasCropInteractionState = CanvasCropInteractionState() { willSet { onStateChange?() } }
    var patternPlacementPhase: PatternPlacementPhase = PatternPlacementPhase.idle { willSet { onStateChange?() } }
    var isApplyingPatternPlacementCommit: Bool = false { willSet { onStateChange?() } }
    var isTransformingSelection: Bool = false { willSet { onStateChange?() } }
    var straightLineState: StraightLineInteractionState = StraightLineInteractionState() { willSet { onStateChange?() } }
    var polygonSelectionState: PolygonSelectionInteractionState = PolygonSelectionInteractionState() { willSet { onStateChange?() } }
    var transformPreviewOffset: CanvasPoint = CanvasPoint(x: 0, y: 0) { willSet { onStateChange?() } }
    var freeTransformPreview: FreeTransformPreview = FreeTransformPreview.identity { willSet { onStateChange?() } }
    var freeTransformMeshWarpGrid: MeshWarpGrid? { willSet { onStateChange?() } }
    var selectedMeshWarpControlPointIndices: Set<Int> = [] { willSet { onStateChange?() } }
    var isFreeTransformDragging: Bool = false { willSet { onStateChange?() } }
    var activeFreeTransformInteractionMode: FreeTransformInteractionMode? { willSet { onStateChange?() } }
    var transformState: TransformInteractionState = TransformInteractionState()
    var activeMeshWarpDragControlPointIndices: Set<Int>?
    var textureFillGestureState: TextureFillGestureState?
    var bucketFillRequestID: UInt64 = 0
    var bucketFillTask: Task<Void, Never>?
    var bucketFillCancellation: WorkCancellation?
    var isBucketFillInProgress: Bool = false { willSet { onStateChange?() } }
    var freeTransformUsesImplicitSelection: Bool = false
    var implicitFreeTransformSelectionShape: SelectionShape?
    var transformCommitRequestID: UUID?
    var isApplyingTransformCommit: Bool = false { willSet { onStateChange?() } }
    var colorAdjustmentSession: ColorAdjustmentSession?
    var curveAdjustmentSession: CurveAdjustmentSession?
    var colorAdjustmentPreviewRenderInFlight: Bool = false
    var colorAdjustmentPreviewRenderNeedsResubmit: Bool = false
    var colorAdjustmentPreviewToken: UInt64 = 0
    var curveAdjustmentPreviewRenderInFlight: Bool = false
    var curveAdjustmentPreviewRenderNeedsResubmit: Bool = false
    var curveAdjustmentPreviewToken: UInt64 = 0
    var activeLassoRawPoints: [CanvasPoint] = []
    var activeLassoPreviewPoints: [CanvasPoint] = []
    var activeLassoBounds: CanvasRect?

    init() { gradient.onStateChange = { [weak self] in self?.onStateChange?() } }

    /// History restores document state, not transient input targets. Never keep
    /// a target whose surface disappeared or whose layer is no longer active.
    func reconcileMaskTarget(with document: ArtDocument) {
        guard let id = activeMaskEditingLayerID else { return }
        guard id != document.activeLayerID || document.layer(id)?.mask == nil else { return }
        clearMaskTarget()
    }

    private func clearMaskTarget() {
        activeMaskEditingLayerID = nil
        lastLayerMaskStrokeSample = nil
        maskStrokeHistoryAccepted = false
    }

    var hasModalDraft: Bool {
        isPreparingDocumentEdit || editableLayerDraft != nil || selectionRefinementDraft != nil || textureAdjustmentSettings != nil
    }

    var persistenceActivity: PersistenceEditingActivity {
        var value: PersistenceEditingActivity = []
        if hasModalDraft { value.insert(.gesture) }
        if isApplyingPatternPlacementCommit || gradient.isCommitting || isApplyingTransformCommit || isBucketFillInProgress || preparation.isRunning {
            value.insert(.pixelCommit)
        }
        if isTransformingSelection { value.insert(.transform) }
        if patternPlacementPhase.draft != nil { value.insert(.pattern) }
        if gradient.linear.phase != .idle || gradient.sector.phase != .idle { value.insert(.gradient) }
        if canvasCropState.bounds != nil { value.insert(.crop) }
        if textureFillGestureState != nil || !activeLassoRawPoints.isEmpty || polygonSelectionState.phase == .building { value.insert(.gesture) }
        if colorAdjustmentSession != nil || curveAdjustmentSession != nil { value.insert(.adjustment) }
        if straightLineState.phase == .pending { value.insert(.pendingLine) }
        return value
    }

    func disposeForReplacement() {
        generation &+= 1
        layerPickContext = nil
        clearMaskTarget()
        preparation.cancel(); isPreparingDocumentEdit = false
        selectionPreview.cancel(); selectionPreviewRequest = UUID(); selectionRefinementDraft = nil
        texturePreview.cancel(); textureAdjustmentSettings = nil
        textureAdjustmentInitialFill = nil; textureAdjustmentOriginal = nil; recentTextureFill = nil
        textureAdjustmentError = nil; isTextureAdjustmentComputing = false; canAdjustRecentTextureFill = false
        editableLayerDraft = nil
        gradient.cancel()
        colorAdjustmentPreviewToken &+= 1; curveAdjustmentPreviewToken &+= 1
        colorAdjustmentSession = nil; curveAdjustmentSession = nil
        colorAdjustmentPreviewRenderInFlight = false; colorAdjustmentPreviewRenderNeedsResubmit = false
        curveAdjustmentPreviewRenderInFlight = false; curveAdjustmentPreviewRenderNeedsResubmit = false
        transformCommitRequestID = nil; isApplyingTransformCommit = false
        transformState = .init(); transformPreviewOffset = .init(x: 0, y: 0); freeTransformPreview = .identity
        freeTransformMeshWarpGrid = nil; selectedMeshWarpControlPointIndices = []
        activeMeshWarpDragControlPointIndices = nil; activeFreeTransformInteractionMode = nil
        isTransformingSelection = false; isFreeTransformDragging = false
        freeTransformUsesImplicitSelection = false; implicitFreeTransformSelectionShape = nil
        bucketFillRequestID &+= 1; bucketFillCancellation?.cancel(); bucketFillTask?.cancel()
        bucketFillTask = nil; bucketFillCancellation = nil; isBucketFillInProgress = false
        patternPlacementPhase = .idle; isApplyingPatternPlacementCommit = false
        canvasCropState.cancel(); straightLineState = .init(); polygonSelectionState = .init()
        textureFillGestureState = nil; activeLassoRawPoints = []; activeLassoPreviewPoints = []; activeLassoBounds = nil
    }
}

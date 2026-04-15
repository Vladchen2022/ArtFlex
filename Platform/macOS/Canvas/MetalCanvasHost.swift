import MetalKit
import SwiftUI
import os
@preconcurrency import Metal

func resolveBrushInputPressure(
    rawPressure: Float,
    isTabletLikeEvent: Bool,
    eventSubtypeIsTabletPoint: Bool,
    sawTabletAuxiliaryEvent: Bool,
    lastPressure: Float?,
    strokeInputSampleCount: Int,
    minimumTabletPressure: Float,
    debugForceConstantPressure: Bool
) -> Float {
    let normalizedPressure: Float
    let shouldTrustRawPressure = isTabletLikeEvent || !sawTabletAuxiliaryEvent

    if rawPressure > 0, shouldTrustRawPressure {
        let clamped = min(max(rawPressure, 0), 1)
        let shouldBypassPressureWarmup =
            isTabletLikeEvent &&
            strokeInputSampleCount < 6
        if shouldBypassPressureWarmup {
            normalizedPressure = clamped
        } else if let lastPressure {
            let delta = abs(clamped - lastPressure)
            let previousWeight: Float
            switch delta {
            case ..<0.04:
                previousWeight = 0.82
            case ..<0.12:
                previousWeight = 0.58
            default:
                previousWeight = 0.25
            }
            normalizedPressure = (lastPressure * previousWeight) + (clamped * (1 - previousWeight))
        } else {
            normalizedPressure = clamped
        }
    } else if eventSubtypeIsTabletPoint || sawTabletAuxiliaryEvent {
        normalizedPressure = lastPressure ?? minimumTabletPressure
    } else {
        normalizedPressure = 1
    }

    return debugForceConstantPressure ? 1 : normalizedPressure
}

private func emitSelectionTraceHost(_ message: String) {
    appendSelectionTrace(message)
}

struct MetalCanvasHost: NSViewRepresentable {
    let sceneSnapshot: CanvasSceneSnapshot
    let externalRedrawRevision: UInt64
    let transformSelectionShape: SelectionShape?
    let metalContext: MetalDeviceContext
    let layerSurfaceStore: StageOneLayerSurfaceStore
    let activeTool: ToolKind
    let viewportRotationDegrees: Double
    let strokeResetToken: Int
    let brushSize: Float
    let isPanModeActive: Bool
    let isTransformingSelection: Bool
    let isFreeTransformDragging: Bool
    let activeFreeTransformInteractionMode: FreeTransformInteractionMode?
    let transformPreview: FreeTransformPreview
    let linearGradientPreview: LinearGradientPreview?
    let sectorGradientPreview: SectorGradientPreview?
    let gradientPreviewColor: RGBAColor
    let gradientPaintJitterAmount: Float
    let gradientPaintContrastAmount: Float
    let gradientDistortionAmount: Float
    let onStrokeBegan: () -> Void
    let onStrokeInput: ([CanvasStrokeSample]) -> Void
    let onStrokeEnded: () -> Void
    let onFlushPendingBrushWork: (MTLCommandBuffer) -> BrushFlushMetrics?
    let onDrainPendingBrushCommitsInteractively: (Bool) -> Void
    let resolveBrushDisplayTexture: (LayerID) -> MTLTexture?
    let onEyedropperSample: (CanvasPoint) -> Void
    let onBucketFill: (CanvasPoint) -> Void
    let onCanvasClick: (CanvasPoint, NSEvent.ModifierFlags, Int) -> Void
    let onCanvasHover: (CanvasPoint) -> Void
    let onSelectionBegan: (CanvasPoint, NSEvent.ModifierFlags) -> Void
    let onSelectionChanged: (CanvasPoint, NSEvent.ModifierFlags) -> Void
    let onSelectionEnded: (CanvasPoint, NSEvent.ModifierFlags) -> Void
    let onSelectionMouseDown: (CanvasPoint, NSEvent.ModifierFlags) -> SelectionMouseDownAction
    let onMoveSelectionPreview: (Double, Double) -> Void
    let onCommitSelectionMove: () -> Void
    let onTransformBegan: (CanvasPoint, FreeTransformInteractionMode, NSEvent.ModifierFlags) -> Void
    let onTransformChanged: (CanvasPoint, NSEvent.ModifierFlags) -> Void
    let onTransformEnded: (CanvasPoint, NSEvent.ModifierFlags) -> Void
    let onTransformOffsetChanged: (CanvasPoint) -> Void
    let onCanvasRotationChanged: (Double) -> Void
    let onPanModeChanged: (Bool) -> Void
    let onToolShortcut: (String, NSEvent.ModifierFlags) -> Void
    let onKeyDown: (NSEvent) -> Bool
    let onKeyUp: (NSEvent) -> Bool
    let onModifierFlagsChanged: (NSEvent.ModifierFlags) -> Bool
    let onGradientDragBegan: (CanvasPoint, NSEvent.ModifierFlags) -> Void
    let onGradientDragChanged: (CanvasPoint, NSEvent.ModifierFlags) -> Void
    let onGradientDragEnded: (CanvasPoint, NSEvent.ModifierFlags) -> Void
    let onEnterGradientEditing: () -> Void
    let onCancelCanvasTool: () -> Void
    let onApplyGradientSession: () -> Void
    let onClearSelection: () -> Void
    let onApplyTransform: () -> Void
    let onCancelTransform: () -> Void
    let isLuminosityPreviewEnabled: Bool
    let onAdjustBrushSize: (Float) -> Void
    private let brushFeelLogger = Logger(subsystem: "ArtFlex", category: "BrushFeel")

    func makeCoordinator() -> MetalCanvasCoordinator {
        MetalCanvasCoordinator(
            metalContext: metalContext,
            layerSurfaceStore: layerSurfaceStore,
            activeTool: activeTool,
            externalRedrawRevision: externalRedrawRevision,
            transformSelectionShape: transformSelectionShape,
            transformPreview: transformPreview,
            linearGradientPreview: linearGradientPreview,
            sectorGradientPreview: sectorGradientPreview,
            gradientPreviewColor: gradientPreviewColor,
            gradientPaintJitterAmount: gradientPaintJitterAmount,
            gradientPaintContrastAmount: gradientPaintContrastAmount,
            gradientDistortionAmount: gradientDistortionAmount,
            onCanvasRotationChanged: onCanvasRotationChanged,
            onStrokeBegan: onStrokeBegan,
            onStrokeInput: onStrokeInput,
            onStrokeEnded: onStrokeEnded,
            onFlushPendingBrushWork: onFlushPendingBrushWork,
            onDrainPendingBrushCommitsInteractively: onDrainPendingBrushCommitsInteractively,
            resolveBrushDisplayTexture: resolveBrushDisplayTexture,
            onEyedropperSample: onEyedropperSample,
            onBucketFill: onBucketFill,
            onCanvasClick: onCanvasClick,
            onCanvasHover: onCanvasHover,
            onSelectionBegan: onSelectionBegan,
            onSelectionChanged: onSelectionChanged,
            onSelectionEnded: onSelectionEnded,
            onSelectionMouseDown: onSelectionMouseDown,
            onMoveSelectionPreview: onMoveSelectionPreview,
            onCommitSelectionMove: onCommitSelectionMove,
            onTransformBegan: onTransformBegan,
            onTransformChanged: onTransformChanged,
            onTransformEnded: onTransformEnded,
            onTransformOffsetChanged: onTransformOffsetChanged,
            onPanModeChanged: onPanModeChanged,
            onToolShortcut: onToolShortcut,
            onGradientDragBegan: onGradientDragBegan,
            onGradientDragChanged: onGradientDragChanged,
            onGradientDragEnded: onGradientDragEnded,
            onEnterGradientEditing: onEnterGradientEditing,
            onCancelCanvasTool: onCancelCanvasTool,
            onApplyGradientSession: onApplyGradientSession,
            onClearSelection: onClearSelection,
            onApplyTransform: onApplyTransform,
            onCancelTransform: onCancelTransform,
            onAdjustBrushSize: onAdjustBrushSize
        )
    }

    func makeNSView(context: Context) -> MTKView {
        let view = StrokeCaptureMTKView()
        view.device = metalContext.device
        view.delegate = context.coordinator
        view.strokeDelegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
        view.preferredFramesPerSecond = 120
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.framebufferOnly = false
        view.keyDownEventHandler = onKeyDown
        view.keyUpEventHandler = onKeyUp
        view.modifierFlagsChangedEventHandler = onModifierFlagsChanged
        view.wantsLayer = true
        view.layer?.backgroundColor = CGColor(
            red: 1,
            green: 1,
            blue: 1,
            alpha: 1
        )
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        let updateStartNs = DispatchTime.now().uptimeNanoseconds
        let wasTransforming = context.coordinator.isTransformingSelection
        let previousSnapshot = context.coordinator.sceneSnapshot
        let previousActiveTool = context.coordinator.activeTool
        let previousExternalRedrawRevision = context.coordinator.previousExternalRedrawRevision
        let previousIsTransforming = context.coordinator.isTransformingSelection
        let previousTransformPreview = context.coordinator.transformPreview
        context.coordinator.sceneSnapshot = sceneSnapshot
        context.coordinator.transformSelectionShape = transformSelectionShape
        context.coordinator.activeTool = activeTool
        context.coordinator.previousExternalRedrawRevision = externalRedrawRevision
        context.coordinator.isTransformingSelection = isTransformingSelection
        context.coordinator.isFreeTransformDragging = isFreeTransformDragging
        context.coordinator.activeFreeTransformInteractionMode = activeFreeTransformInteractionMode
        context.coordinator.transformPreview = transformPreview
        context.coordinator.linearGradientPreview = linearGradientPreview
        context.coordinator.sectorGradientPreview = sectorGradientPreview
        context.coordinator.gradientPreviewColor = gradientPreviewColor
        context.coordinator.gradientPaintJitterAmount = gradientPaintJitterAmount
        context.coordinator.gradientPaintContrastAmount = gradientPaintContrastAmount
        context.coordinator.gradientDistortionAmount = gradientDistortionAmount
        let previousLuminosityPreview = context.coordinator.isLuminosityPreviewEnabled
        context.coordinator.isLuminosityPreviewEnabled = isLuminosityPreviewEnabled
        if let view = nsView as? StrokeCaptureMTKView {
            let previousCanvasSize = view.canvasSize
            let previousViewportRotation = view.viewportRotationDegrees
            let previousPanMode = view.isPanModeActive
            let previousStrokeResetToken = view.strokeResetToken
            let previousBrushSize = view.brushSize
            let previousCanvasContentRevision = previousSnapshot?.renderSnapshot.canvasContentRevision
            let previousViewportRevision = previousSnapshot?.renderSnapshot.viewportRevision
            let previousSelectionRevision = previousSnapshot?.selectionRevision
            let previousSelectionShape = previousSnapshot?.selectionShape
            let previousLinearGradientPreview = context.coordinator.previousLinearGradientPreview
            let previousSectorGradientPreview = context.coordinator.previousSectorGradientPreview
            let previousGradientPreviewColor = context.coordinator.previousGradientPreviewColor
            let previousGradientPaintJitterAmount = context.coordinator.previousGradientPaintJitterAmount
            let previousGradientPaintContrastAmount = context.coordinator.previousGradientPaintContrastAmount
            let previousGradientDistortionAmount = context.coordinator.previousGradientDistortionAmount

            let nonBrushStateChanged =
                previousCanvasContentRevision != sceneSnapshot.renderSnapshot.canvasContentRevision ||
                previousViewportRevision != sceneSnapshot.renderSnapshot.viewportRevision ||
                previousSelectionRevision != sceneSnapshot.selectionRevision ||
                previousSelectionShape?.kind != sceneSnapshot.selectionShape?.kind ||
                previousSelectionShape?.bounds != sceneSnapshot.selectionShape?.bounds ||
                previousActiveTool != activeTool ||
                previousExternalRedrawRevision != externalRedrawRevision ||
                previousIsTransforming != isTransformingSelection ||
                previousTransformPreview != transformPreview ||
                previousLinearGradientPreview != linearGradientPreview ||
                previousSectorGradientPreview != sectorGradientPreview ||
                previousGradientPreviewColor != gradientPreviewColor ||
                previousGradientPaintJitterAmount != gradientPaintJitterAmount ||
                previousGradientPaintContrastAmount != gradientPaintContrastAmount ||
                previousGradientDistortionAmount != gradientDistortionAmount ||
                previousLuminosityPreview != isLuminosityPreviewEnabled ||
                previousCanvasSize != sceneSnapshot.renderSnapshot.document.canvasSize ||
                previousViewportRotation != viewportRotationDegrees ||
                previousPanMode != isPanModeActive ||
                previousStrokeResetToken != strokeResetToken

            view.transformPreviewDelegate = context.coordinator

            if previousBrushSize != brushSize && !nonBrushStateChanged {
                view.brushSize = brushSize
                let updateDurationMs = Double(DispatchTime.now().uptimeNanoseconds - updateStartNs) / 1_000_000
                brushFeelLogger.debug("[brush-size] updateNSViewFastPath=true")
                brushFeelLogger.debug("[brush-size] updateNSViewFastPathMs=\(updateDurationMs, privacy: .public)")
                return
            }

            context.coordinator.updatePreparedTransformSessionIfNeeded()

            view.canvasSize = sceneSnapshot.renderSnapshot.document.canvasSize
            view.activeTool = activeTool
            view.viewportRotationDegrees = viewportRotationDegrees
            view.isPanModeActive = isPanModeActive
            view.keyDownEventHandler = onKeyDown
            view.keyUpEventHandler = onKeyUp
            view.modifierFlagsChangedEventHandler = onModifierFlagsChanged
            if view.strokeResetToken != strokeResetToken {
                view.strokeResetToken = strokeResetToken
                view.resetInteractionState()
            }
            view.brushSize = brushSize

            if wasTransforming && !isTransformingSelection {
                view.isPaused = true
                view.enableSetNeedsDisplay = true
            }

            let requiresCanvasRedraw =
                previousCanvasContentRevision != sceneSnapshot.renderSnapshot.canvasContentRevision ||
                previousViewportRevision != sceneSnapshot.renderSnapshot.viewportRevision ||
                previousSelectionRevision != sceneSnapshot.selectionRevision ||
                previousSelectionShape?.kind != sceneSnapshot.selectionShape?.kind ||
                previousSelectionShape?.bounds != sceneSnapshot.selectionShape?.bounds ||
                previousActiveTool != activeTool ||
                previousExternalRedrawRevision != externalRedrawRevision ||
                previousIsTransforming != isTransformingSelection ||
                previousTransformPreview != transformPreview ||
                previousLinearGradientPreview != linearGradientPreview ||
                previousSectorGradientPreview != sectorGradientPreview ||
                previousGradientPreviewColor != gradientPreviewColor ||
                previousGradientPaintJitterAmount != gradientPaintJitterAmount ||
                previousGradientPaintContrastAmount != gradientPaintContrastAmount ||
                previousGradientDistortionAmount != gradientDistortionAmount ||
                previousLuminosityPreview != isLuminosityPreviewEnabled ||
                previousCanvasSize != view.canvasSize ||
                previousViewportRotation != viewportRotationDegrees ||
                previousPanMode != isPanModeActive ||
                previousStrokeResetToken != strokeResetToken

            context.coordinator.previousLinearGradientPreview = linearGradientPreview
            context.coordinator.previousSectorGradientPreview = sectorGradientPreview
            context.coordinator.previousGradientPreviewColor = gradientPreviewColor
            context.coordinator.previousGradientPaintJitterAmount = gradientPaintJitterAmount
            context.coordinator.previousGradientPaintContrastAmount = gradientPaintContrastAmount
            context.coordinator.previousGradientDistortionAmount = gradientDistortionAmount

            let brushSizeOnlyChanged = previousBrushSize != brushSize && !requiresCanvasRedraw
            let updateDurationMs = Double(DispatchTime.now().uptimeNanoseconds - updateStartNs) / 1_000_000
            brushFeelLogger.debug("[brush-feel] updateNSViewMs=\(updateDurationMs, privacy: .public)")
            brushFeelLogger.debug("[brush-feel] updateNSViewDuringActiveBrush=\(view.isBrushLikeStrokeActive, privacy: .public)")
            brushFeelLogger.debug("[brush-feel] sceneSnapshotDeepCompare=false")
            if brushSizeOnlyChanged {
                return
            }
        }
        if nsView.isPaused {
            nsView.draw()
        } else {
            nsView.setNeedsDisplay(nsView.bounds)
        }
    }
}

@MainActor
protocol TransformPreviewDelegate: AnyObject {
    func freeTransformInteractionMode(for point: CanvasPoint, in view: StrokeCaptureMTKView) -> FreeTransformInteractionMode
    func strokeCaptureView(_ view: StrokeCaptureMTKView, shouldBeginTransformAt point: CanvasPoint) -> Bool
    func strokeCaptureView(_ view: StrokeCaptureMTKView, didUpdateTransformPreviewTo point: CanvasPoint)
    func strokeCaptureViewDidCancelTransformPreview(_ view: StrokeCaptureMTKView)
    func strokeCaptureViewSetFallbackStartPoint(_ view: StrokeCaptureMTKView, point: CanvasPoint)
}

// ViewModel 告诉 View，mouseDown 时应该进入哪种模式
enum SelectionMouseDownAction {
    case beginDrawing   // 开始画新选区
    case beginMoving    // 开始移动已有选区
    case idle           // 只清除选区，不做其他事
}

@MainActor
protocol StrokeCaptureDelegate: AnyObject {
    func strokeCaptureViewDidBeginStroke(_ view: StrokeCaptureMTKView)
    func strokeCaptureView(_ view: StrokeCaptureMTKView, didProduce samples: [CanvasStrokeSample])
    func strokeCaptureViewDidEndStroke(_ view: StrokeCaptureMTKView)
    func strokeCaptureView(_ view: StrokeCaptureMTKView, didSampleColorAt point: CanvasPoint)
    func strokeCaptureView(_ view: StrokeCaptureMTKView, didRequestBucketFillAt point: CanvasPoint)
    func strokeCaptureView(_ view: StrokeCaptureMTKView, didClickCanvasAt point: CanvasPoint, modifiers: NSEvent.ModifierFlags, clickCount: Int)
    func strokeCaptureView(_ view: StrokeCaptureMTKView, didHoverCanvasAt point: CanvasPoint)
    func strokeCaptureView(_ view: StrokeCaptureMTKView, didBeginSelectionAt point: CanvasPoint, modifiers: NSEvent.ModifierFlags)
    func strokeCaptureView(_ view: StrokeCaptureMTKView, didChangeSelectionAt point: CanvasPoint, modifiers: NSEvent.ModifierFlags)
    func strokeCaptureView(_ view: StrokeCaptureMTKView, didEndSelectionAt point: CanvasPoint, modifiers: NSEvent.ModifierFlags)
    func strokeCaptureView(_ view: StrokeCaptureMTKView, selectionToolMouseDownAt point: CanvasPoint, modifiers: NSEvent.ModifierFlags) -> SelectionMouseDownAction
    func strokeCaptureView(_ view: StrokeCaptureMTKView, didMoveSelectionPreviewBy deltaX: Double, deltaY: Double)
    func strokeCaptureViewDidCommitSelectionMove(_ view: StrokeCaptureMTKView)
    func strokeCaptureView(_ view: StrokeCaptureMTKView, didBeginTransformAt point: CanvasPoint, mode: FreeTransformInteractionMode, modifiers: NSEvent.ModifierFlags)
    func strokeCaptureView(_ view: StrokeCaptureMTKView, didChangeTransformAt point: CanvasPoint, modifiers: NSEvent.ModifierFlags)
    func strokeCaptureView(_ view: StrokeCaptureMTKView, didEndTransformAt point: CanvasPoint, modifiers: NSEvent.ModifierFlags)
    func strokeCaptureView(_ view: StrokeCaptureMTKView, didRotateCanvasTo angleDegrees: Double)
    func strokeCaptureView(_ view: StrokeCaptureMTKView, didPanBy deltaX: Double, deltaY: Double)
    func strokeCaptureView(_ view: StrokeCaptureMTKView, didChangePanMode isActive: Bool)
    func strokeCaptureView(_ view: StrokeCaptureMTKView, didRequestToolShortcutKey key: String, modifiers: NSEvent.ModifierFlags)
    func strokeCaptureView(_ view: StrokeCaptureMTKView, didBeginGradientDragAt point: CanvasPoint, modifiers: NSEvent.ModifierFlags)
    func strokeCaptureView(_ view: StrokeCaptureMTKView, didChangeGradientDragAt point: CanvasPoint, modifiers: NSEvent.ModifierFlags)
    func strokeCaptureView(_ view: StrokeCaptureMTKView, didEndGradientDragAt point: CanvasPoint, modifiers: NSEvent.ModifierFlags)
    func strokeCaptureViewDidRequestEnterGradientEditing(_ view: StrokeCaptureMTKView)
    func strokeCaptureViewDidRequestCanvasToolCancel(_ view: StrokeCaptureMTKView)
    func strokeCaptureViewDidRequestApplyGradientSession(_ view: StrokeCaptureMTKView)
    func strokeCaptureViewDidRequestClearSelection(_ view: StrokeCaptureMTKView)
    func strokeCaptureViewDidRequestApplyTransform(_ view: StrokeCaptureMTKView)
    func strokeCaptureViewDidRequestCancelTransform(_ view: StrokeCaptureMTKView)
    func strokeCaptureViewDidSyncTransformOffset(_ view: StrokeCaptureMTKView)
    func strokeCaptureView(_ view: StrokeCaptureMTKView, didRequestBrushSizeAdjustment delta: Float)
}

private final class DisabledLayerAction: NSObject, CAAction {
    func run(forKey event: String, object anObject: Any, arguments dict: [AnyHashable: Any]?) {}
}

func makeCursorIndicatorDisabledActions() -> [String: CAAction] {
    return [
        "path": DisabledLayerAction(),
        "position": DisabledLayerAction(),
        "bounds": DisabledLayerAction(),
        "hidden": DisabledLayerAction(),
        "transform": DisabledLayerAction(),
        "opacity": DisabledLayerAction()
    ]
}

func latestBrushHoverLocation(
    originalLocation: CGPoint,
    batchedLocations: [CGPoint]
) -> CGPoint {
    batchedLocations.last ?? originalLocation
}

enum PendingBrushInputKind: Equatable {
    case begin
    case samples([CanvasStrokeSample])
    case end
}

struct PendingBrushInputBatch: Equatable {
    var kind: PendingBrushInputKind
    var enqueuedAt: UInt64
}

struct PendingBrushInputQueue {
    private(set) var batches: [PendingBrushInputBatch] = []

    var isEmpty: Bool { batches.isEmpty }

    mutating func enqueue(_ kind: PendingBrushInputKind, at timestamp: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        batches.append(PendingBrushInputBatch(kind: kind, enqueuedAt: timestamp))
    }

    mutating func flush() -> [PendingBrushInputBatch] {
        let pending = batches
        batches = []
        return pending
    }
}

enum BrushCursorMode: Equatable {
    case arrow
    case crosshair
    case eyedropper
}

enum BrushSizePreviewState: Equatable {
    case local
    case model
    case synced
}

func resolveBrushSizePreview(
    displayBrushSize: Float,
    modelBrushSize: Float,
    isAdjustingBrushSizePreview: Bool,
    previewExpiresAtNs: UInt64,
    nowUptimeNs: UInt64
) -> (displayBrushSize: Float, isAdjustingBrushSizePreview: Bool, previewExpiresAtNs: UInt64, state: BrushSizePreviewState) {
    guard isAdjustingBrushSizePreview else {
        return (
            displayBrushSize: modelBrushSize,
            isAdjustingBrushSizePreview: false,
            previewExpiresAtNs: 0,
            state: .model
        )
    }

    let modelCaughtUp = abs(displayBrushSize - modelBrushSize) < 0.01
    let previewExpired = nowUptimeNs >= previewExpiresAtNs
    if modelCaughtUp || previewExpired {
        return (
            displayBrushSize: modelBrushSize,
            isAdjustingBrushSizePreview: false,
            previewExpiresAtNs: 0,
            state: modelCaughtUp ? .synced : .model
        )
    }

    return (
        displayBrushSize: displayBrushSize,
        isAdjustingBrushSizePreview: true,
        previewExpiresAtNs: previewExpiresAtNs,
        state: .local
    )
}

func preferredBrushCursorMode(
    activeTool: ToolKind,
    isEyedropperCursorActive: Bool,
    hasHoverLocation: Bool
) -> BrushCursorMode? {
    guard hasHoverLocation else { return nil }
    if isEyedropperCursorActive {
        return .eyedropper
    }
    if activeTool == .brush || activeTool == .eraser || activeTool == .smudge || activeTool == .brightnessAdjust {
        return .crosshair
    }
    return .arrow
}

func shouldShowBrushOutlineIndicator(
    activeTool: ToolKind,
    hasHoverLocation: Bool,
    isAdjustingBrushSizePreview: Bool,
    isBrushOutlineForcedVisible: Bool,
    suppressesBrushOutline: Bool,
    isBrushStrokeActive: Bool,
    showsBrushOutlineDuringStroke: Bool,
    hasContinuousStrokeGrace: Bool
) -> Bool {
    guard (activeTool == .brush || activeTool == .eraser || activeTool == .smudge || activeTool == .brightnessAdjust), hasHoverLocation else {
        return false
    }
    if isAdjustingBrushSizePreview { return true }
    if isBrushOutlineForcedVisible { return true }
    if suppressesBrushOutline { return false }
    if isBrushStrokeActive && !showsBrushOutlineDuringStroke { return false }
    if hasContinuousStrokeGrace { return false }
    return true
}

func shouldShowBrushTipIndicator(
    activeTool: ToolKind,
    hasHoverLocation: Bool
) -> Bool {
    guard activeTool == .brush || activeTool == .eraser || activeTool == .smudge || activeTool == .brightnessAdjust else {
        return false
    }
    return hasHoverLocation
}

func freeTransformCanStartImmediately(
    signature: TransformPreviewPreparedSignature?,
    hasPreparedSession: Bool
) -> Bool {
    if hasPreparedSession {
        return true
    }
    return signature?.mode == .wholeLayer
}

func freeTransformShouldSkipSessionRebuild(
    isTransformingSelection: Bool,
    isFreeTransformDragging: Bool,
    activeInteractionMode: FreeTransformInteractionMode?
) -> Bool {
    isTransformingSelection && isFreeTransformDragging && activeInteractionMode == .move
}

func freeTransformActiveLayerPreviewStrategy(
    hasActivePreview: Bool,
    sessionMode: TransformPreviewMode?,
    hasBaseTexture: Bool,
    plannedMode: TransformPreviewMode?
) -> FreeTransformActiveLayerPreviewStrategy {
    guard hasActivePreview else { return .showOriginalLayer }

    if let sessionMode {
        if sessionMode == .selection, hasBaseTexture {
            return .showBaseTexture
        }
        return .hideOriginalLayer
    }

    if plannedMode == .wholeLayer {
        return .hideOriginalLayer
    }

    return .showOriginalLayer
}

enum FreeTransformActiveLayerPreviewStrategy: Equatable {
    case showOriginalLayer
    case showBaseTexture
    case hideOriginalLayer
}

final class StrokeCaptureMTKView: MTKView {
    private struct BrushInputDebugRecord {
        var index: Int
        var eventType: NSEvent.EventType
        var eventSubtype: NSEvent.EventSubtype
        var timestamp: TimeInterval
        var location: CanvasPoint
        var rawPressure: Float
        var filteredPressure: Float
        var dx: Double
        var dy: Double
        var dt: TimeInterval
        var distanceFromPrevious: Double
    }

    weak var strokeDelegate: StrokeCaptureDelegate?
    weak var transformPreviewDelegate: TransformPreviewDelegate?
    var keyDownEventHandler: ((NSEvent) -> Bool)?
    var keyUpEventHandler: ((NSEvent) -> Bool)?
    var modifierFlagsChangedEventHandler: ((NSEvent.ModifierFlags) -> Bool)?
    var canvasSize: CanvasSize = .stageOneDefault
    var activeTool: ToolKind = .brush {
        didSet {
            if !isBrushLikeToolActive() {
                cancelBrushOutlineReveal()
                isBrushOutlineForcedVisible = false
                suppressesBrushOutline = false
            }
            updateCursorAppearance()
            updateCursorIndicator()
        }
    }
    var viewportRotationDegrees: Double = 0
    var isPanModeActive = false
    var strokeResetToken = 0
    var brushSize: Float = 24 {
        didSet {
            let now = DispatchTime.now().uptimeNanoseconds
            let resolvedPreview = resolveBrushSizePreview(
                displayBrushSize: displayBrushSize,
                modelBrushSize: brushSize,
                isAdjustingBrushSizePreview: isAdjustingBrushSizePreview,
                previewExpiresAtNs: brushSizePreviewExpiresAtNs,
                nowUptimeNs: now
            )
            displayBrushSize = resolvedPreview.displayBrushSize
            if isAdjustingBrushSizePreview && !resolvedPreview.isAdjustingBrushSizePreview {
                cancelBrushSizePreviewSettle()
            }
            isAdjustingBrushSizePreview = resolvedPreview.isAdjustingBrushSizePreview
            brushSizePreviewExpiresAtNs = resolvedPreview.previewExpiresAtNs
            brushStrokeLogger.debug("[brush-size] previewState=\(String(describing: resolvedPreview.state), privacy: .public)")
            brushStrokeLogger.debug("[brush-size] displayBrushSize=\(self.displayBrushSize, privacy: .public)")
            brushStrokeLogger.debug("[brush-size] modelBrushSize=\(self.brushSize, privacy: .public)")
            updateCursorIndicator()
        }
    }
    // 当前选区交互模式，由 ViewModel 在 mouseDown 响应后通过 updateNSView 同步回来
    var selectionInteractionMode: SelectionMouseDownAction = .idle

    private var lastSample: CanvasStrokeSample?
    /// 入力スムージング用 EMA（指数移動平均）の現在位置。
    /// 実際のカーソル位置を α で追従し、急な加速による起始直線を消す。
    private var smoothedPosition: CanvasPoint?
    private var selectionMoveLastPoint: CanvasPoint?
    private var lastPanLocation: CGPoint?
    private var lastPressure: Float?
    private var strokePacketIndex = 0
    private var strokeInputSampleCount = 0
    private var isBrushStrokeActive = false
    private var sawTabletAuxiliaryEvent = false
    private var pendingTransformBeginPoint: CanvasPoint?
    private var pendingTransformLatestPoint: CanvasPoint?
    private var pendingTransformInteractionMode: FreeTransformInteractionMode?
    private var activeFreeTransformDragPoint: CanvasPoint?
    private var activeFreeTransformDragMode: FreeTransformInteractionMode?
    private var isGradientDragActive = false
    private var previousMouseCoalescingEnabled: Bool?
    private var brushDebugRecords: [BrushInputDebugRecord] = []
    private let minimumTabletPressure: Float = 0.02
    private var trackingAreaRef: NSTrackingArea?
    private let cursorIndicatorLayer = CAShapeLayer()
    private let cursorTipLayer = CAShapeLayer()
    private var hoverLocation: CGPoint?
    private var activeModifierFlags: NSEvent.ModifierFlags = []
    private var pendingBrushInputQueue = PendingBrushInputQueue()
    private var continuousStrokeRenderGraceWorkItem: DispatchWorkItem?
    private var brushOutlineRevealWorkItem: DispatchWorkItem?
    private var brushSizePreviewSettleWorkItem: DispatchWorkItem?
    private var displayBrushSize: Float = 24
    private var isAdjustingBrushSizePreview = false
    private var brushSizePreviewExpiresAtNs: UInt64 = 0
    private var isBrushOutlineForcedVisible = false
    private var suppressesBrushOutline = false
    private let selectionTraceLogger = Logger(subsystem: "ArtFlex", category: "SelectionTrace")
    private let brushStrokeLogger = Logger(subsystem: "ArtFlex", category: "BrushStroke")
    private let transformStrokeLogger = Logger(subsystem: "ArtFlex", category: "TransformStroke")
    private var canvasRotationBaseDegrees: Double?
    private var canvasRotationStartAngleDegrees: Double?
    private static let eyedropperCursor: NSCursor = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        if let image = NSImage(
            systemSymbolName: "eyedropper",
            accessibilityDescription: "Eyedropper"
        )?.withSymbolConfiguration(configuration) {
            return NSCursor(image: image, hotSpot: NSPoint(x: 1, y: image.size.height - 1))
        }
        return .crosshair
    }()

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private let debugDisableMouseCoalescingDuringStroke = true
    private let debugForceConstantPressure = false
    private let debugBypassStartupPressureSmoothing = false
    private let debugLogFirstRawSamples = true
    private let strokeRenderGraceDelay: TimeInterval = 0.15
    private let brushOutlineIdleRevealDelay: TimeInterval = 0.10
    private let brushSizePreviewSettleDelay: TimeInterval = 0.16
    private let showsBrushOutlineDuringStroke = false

    var isBrushLikeStrokeActive: Bool {
        activeTool == .brush || activeTool == .eraser || activeTool == .smudge
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if cursorIndicatorLayer.superlayer == nil {
            cursorIndicatorLayer.fillColor = NSColor.clear.cgColor
            cursorIndicatorLayer.strokeColor = NSColor.black.withAlphaComponent(0.28).cgColor
            cursorIndicatorLayer.lineWidth = 1
            cursorIndicatorLayer.actions = makeCursorIndicatorDisabledActions()
            layer?.addSublayer(cursorIndicatorLayer)
        }
        if cursorTipLayer.superlayer == nil {
            cursorTipLayer.fillColor = NSColor.black.cgColor
            cursorTipLayer.strokeColor = nil
            cursorTipLayer.lineWidth = 0
            cursorTipLayer.actions = makeCursorIndicatorDisabledActions()
            layer?.addSublayer(cursorTipLayer)
        }
        displayBrushSize = brushSize
        window?.acceptsMouseMovedEvents = true
        window?.makeFirstResponder(self)
        updateCursorAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }

    override func mouseDown(with event: NSEvent) {
        let handlerStartNs = DispatchTime.now().uptimeNanoseconds
        activeModifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        window?.makeFirstResponder(self)
        if isBrushLikeToolActive() {
            cancelBrushSizePreviewSettle()
            isAdjustingBrushSizePreview = false
            brushSizePreviewExpiresAtNs = 0
            suppressBrushOutlineForActiveInput()
        }
        hoverLocation = convert(event.locationInWindow, from: nil)
        updateCursorIndicator()
        brushStrokeLogger.debug(
            "[brush-feel] eventTimestampToCursorUpdateMs=\((ProcessInfo.processInfo.systemUptime - event.timestamp) * 1_000, privacy: .public)"
        )
        updateCursorAppearance()
        if isPanModeActive {
            return
        }

        if activeTool == .eyedropper || shouldUseEyedropperOverride(for: event) {
            strokeDelegate?.strokeCaptureView(self, didSampleColorAt: sample(from: event).location)
            setNeedsDisplay(bounds)
            return
        }

        if activeTool == .bucket {
            strokeDelegate?.strokeCaptureView(self, didRequestBucketFillAt: sample(from: event).location)
            setNeedsDisplay(bounds)
            return
        }

        if activeTool == .polygonSelection {
            let point = sample(from: event).location
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let action = strokeDelegate?.strokeCaptureView(
                self,
                selectionToolMouseDownAt: point,
                modifiers: modifiers
            ) ?? .idle
            selectionInteractionMode = action
            selectionMoveLastPoint = (action == .beginMoving) ? point : nil
            setNeedsDisplay(bounds)
            return
        }

        if activeTool == .canvasRotate {
            let location = convert(event.locationInWindow, from: nil)
            canvasRotationBaseDegrees = viewportRotationDegrees
            canvasRotationStartAngleDegrees = canvasRotationAngleDegrees(for: location)
            setNeedsDisplay(bounds)
            return
        }

        if activeTool == .linearGradient || activeTool == .sectorGradient {
            isGradientDragActive = true
            strokeDelegate?.strokeCaptureView(
                self,
                didBeginGradientDragAt: sample(from: event).location,
                modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            )
            beginContinuousTransformRendering()
            setNeedsDisplay(bounds)
            return
        }

        if activeTool == .straightLine {
            setNeedsDisplay(bounds)
            return
        }

        if activeTool == .freeTransform {
            let point = sample(from: event).location
            let mode = transformPreviewDelegate?.freeTransformInteractionMode(for: point, in: self) ?? .move
            let sessionStarted = transformPreviewDelegate?.strokeCaptureView(self, shouldBeginTransformAt: point) ?? false
            transformStrokeLogger.debug(
                "[transform] sessionReadyAtDragStart=\(sessionStarted, privacy: .public)"
            )
            if sessionStarted {
                beginContinuousTransformRendering()
                activeFreeTransformDragPoint = point
                activeFreeTransformDragMode = mode
                strokeDelegate?.strokeCaptureView(
                    self,
                    didBeginTransformAt: point,
                    mode: mode,
                    modifiers: activeModifierFlags
                )
            } else {
                pendingTransformBeginPoint = point
                pendingTransformLatestPoint = point
                pendingTransformInteractionMode = mode
            }
            return
        }
        if activeTool == .rectangleSelection || activeTool == .ellipseSelection || activeTool == .lassoSelection || activeTool == .lassoFill {
            let point = sample(from: event).location
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // 同步询问 ViewModel 应该进入哪种模式
            // ViewModel 在 handleSelectionMouseDown 内部已经调用了 beginSelection，这里只需记录模式
            let action = strokeDelegate?.strokeCaptureView(
                self,
                selectionToolMouseDownAt: point,
                modifiers: modifiers
            ) ?? .beginDrawing
            selectionInteractionMode = action
            selectionMoveLastPoint = (action == .beginMoving) ? point : nil
            setNeedsDisplay(bounds)
            return
        }

        beginContinuousStrokeRendering()
        beginBrushStrokeDiagnostics()
        strokePacketIndex = 0
        strokeInputSampleCount = 0
        let rawSample = sample(from: event)
        smoothedPosition = nil                    // 新しい筆触：スムージング状態リセット
        let s = smoothed(rawSample)
        lastSample = s
        enqueuePendingBrushBegin()
        emitCoalescedStrokeSamples([s])
        strokePacketIndex += 1
        let handlerDurationMs = Double(DispatchTime.now().uptimeNanoseconds - handlerStartNs) / 1_000_000
        brushStrokeLogger.debug(
            "[brush-feel] eventTimestampToHandlerStartMs=\((ProcessInfo.processInfo.systemUptime - event.timestamp) * 1_000, privacy: .public)"
        )
        brushStrokeLogger.debug("[brush-feel] mouseDownBeginMs=\(handlerDurationMs, privacy: .public)")
        setNeedsDisplay(bounds)
    }

    override func mouseDragged(with event: NSEvent) {
        let handlerStartNs = DispatchTime.now().uptimeNanoseconds
        activeModifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        updateCursorAppearance()
        if activeTool == .polygonSelection {
            switch selectionInteractionMode {
            case .beginMoving:
                let point = sample(from: event).location
                if let last = selectionMoveLastPoint {
                    strokeDelegate?.strokeCaptureView(
                        self,
                        didMoveSelectionPreviewBy: point.x - last.x,
                        deltaY: point.y - last.y
                    )
                }
                selectionMoveLastPoint = point
                setNeedsDisplay(bounds)
                return
            case .beginDrawing, .idle:
                strokeDelegate?.strokeCaptureView(self, didHoverCanvasAt: sample(from: event).location)
                setNeedsDisplay(bounds)
                return
            }
        }

        if activeTool == .canvasRotate {
            let currentLocation = convert(event.locationInWindow, from: nil)
            if let baseDegrees = canvasRotationBaseDegrees,
               let startAngleDegrees = canvasRotationStartAngleDegrees {
                let currentAngleDegrees = canvasRotationAngleDegrees(for: currentLocation)
                let sensitivity = canvasRotationSensitivity(for: currentLocation)
                strokeDelegate?.strokeCaptureView(
                    self,
                    didRotateCanvasTo: baseDegrees + ((currentAngleDegrees - startAngleDegrees) * sensitivity)
                )
            }
            setNeedsDisplay(bounds)
            return
        }

        if activeTool == .linearGradient || activeTool == .sectorGradient {
            strokeDelegate?.strokeCaptureView(
                self,
                didChangeGradientDragAt: sample(from: event).location,
                modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            )
            setNeedsDisplay(bounds)
            return
        }

        if activeTool == .straightLine {
            strokeDelegate?.strokeCaptureView(self, didHoverCanvasAt: sample(from: event).location)
            setNeedsDisplay(bounds)
            return
        }
        if activeTool == .eyedropper || shouldUseEyedropperOverride(for: event) {
            strokeDelegate?.strokeCaptureView(self, didSampleColorAt: sample(from: event).location)
            setNeedsDisplay(bounds)
            return
        }

        if activeTool == .rectangleSelection || activeTool == .ellipseSelection || activeTool == .lassoSelection || activeTool == .lassoFill {
            switch selectionInteractionMode {
            case .beginMoving:
                let point = sample(from: event).location
                if let last = selectionMoveLastPoint {
                    strokeDelegate?.strokeCaptureView(
                        self,
                        didMoveSelectionPreviewBy: point.x - last.x,
                        deltaY: point.y - last.y
                    )
                }
                selectionMoveLastPoint = point
                setNeedsDisplay(bounds)
                return
            case .beginDrawing:
                let samples = selectionSamples(from: event)
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if activeTool == .lassoSelection || activeTool == .lassoFill {
                    let message = "[sampleBatch] draggedEvents=\(samples.count) finalCanvas=(\(samples.last?.location.x ?? 0),\(samples.last?.location.y ?? 0))"
                    selectionTraceLogger.debug("\(message, privacy: .public)")
                    emitSelectionTraceHost(message)
                }
                for sample in samples {
                    strokeDelegate?.strokeCaptureView(
                        self,
                        didChangeSelectionAt: sample.location,
                        modifiers: modifiers
                    )
                }
                setNeedsDisplay(bounds)
                return
            case .idle:
                setNeedsDisplay(bounds)
                return
            }
        }

        if activeTool == .freeTransform {
            let point = sample(from: event).location
            if let pendingStart = pendingTransformBeginPoint {
                pendingTransformLatestPoint = point
                let sessionStarted = transformPreviewDelegate?.strokeCaptureView(
                    self,
                    shouldBeginTransformAt: pendingStart
                ) ?? false
                if sessionStarted {
                    let pendingMode = pendingTransformInteractionMode ?? .move
                    transformStrokeLogger.debug("[transform] startedWithPendingBegin=true")
                    pendingTransformBeginPoint = nil
                    pendingTransformLatestPoint = nil
                    pendingTransformInteractionMode = nil
                    beginContinuousTransformRendering()
                    activeFreeTransformDragPoint = point
                    activeFreeTransformDragMode = pendingMode
                    strokeDelegate?.strokeCaptureView(
                        self,
                        didBeginTransformAt: pendingStart,
                        mode: pendingMode,
                        modifiers: activeModifierFlags
                    )
                    strokeDelegate?.strokeCaptureView(
                        self,
                        didChangeTransformAt: point,
                        modifiers: activeModifierFlags
                    )
                    transformPreviewDelegate?.strokeCaptureView(self, didUpdateTransformPreviewTo: point)
                }
                setNeedsDisplay(bounds)
                return
            }

            activeFreeTransformDragPoint = point
            if activeFreeTransformDragMode == nil {
                activeFreeTransformDragMode = pendingTransformInteractionMode ?? .move
            }
            strokeDelegate?.strokeCaptureView(
                self,
                didChangeTransformAt: point,
                modifiers: activeModifierFlags
            )
            transformPreviewDelegate?.strokeCaptureView(self, didUpdateTransformPreviewTo: point)
            setNeedsDisplay(bounds)
            return
        }

        if activeTool == .eyedropper || activeTool == .bucket {
            return
        }

        if isPanModeActive {
            return
        }

        hoverLocation = convert(event.locationInWindow, from: nil)
        updateCursorIndicator()
        brushStrokeLogger.debug("[brush-feel] eventTimestampToCursorUpdateMs=\((ProcessInfo.processInfo.systemUptime - event.timestamp) * 1_000, privacy: .public)")
        let current = smoothed(sample(from: event))
        emitCoalescedStrokeSamples([current])
        lastSample = current
        strokePacketIndex += 1
        let handlerDurationMs = Double(DispatchTime.now().uptimeNanoseconds - handlerStartNs) / 1_000_000
        brushStrokeLogger.debug("[brush-feel] brushDragUsesCurrentEventOnly=true")
        brushStrokeLogger.debug("[brush-feel] drainedBrushEventsCount=1")
        brushStrokeLogger.debug("[brush-feel] cursorTipEnabled=true")
        brushStrokeLogger.debug("[brush-feel] mouseDraggedHandlerMs=\(handlerDurationMs, privacy: .public)")
        setNeedsDisplay(bounds)
    }

    override func mouseUp(with event: NSEvent) {
        activeModifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        hoverLocation = convert(event.locationInWindow, from: nil)
        updateCursorIndicator()
        updateCursorAppearance()
        if activeTool == .polygonSelection {
            switch selectionInteractionMode {
            case .beginMoving:
                selectionMoveLastPoint = nil
                selectionInteractionMode = .idle
                strokeDelegate?.strokeCaptureViewDidCommitSelectionMove(self)
            case .beginDrawing, .idle:
                selectionInteractionMode = .idle
                strokeDelegate?.strokeCaptureView(
                    self,
                    didClickCanvasAt: sample(from: event).location,
                    modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask),
                    clickCount: event.clickCount
                )
            }
            lastSample = nil
            lastPressure = nil
            setNeedsDisplay(bounds)
            return
        }

        if activeTool == .canvasRotate {
            canvasRotationBaseDegrees = nil
            canvasRotationStartAngleDegrees = nil
            lastSample = nil
            lastPressure = nil
            setNeedsDisplay(bounds)
            return
        }

        if activeTool == .linearGradient || activeTool == .sectorGradient {
            isGradientDragActive = false
            strokeDelegate?.strokeCaptureView(
                self,
                didEndGradientDragAt: sample(from: event).location,
                modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            )
            endContinuousTransformRendering()
            lastSample = nil
            lastPressure = nil
            setNeedsDisplay(bounds)
            return
        }

        if activeTool == .straightLine {
            strokeDelegate?.strokeCaptureView(
                self,
                didClickCanvasAt: sample(from: event).location,
                modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask),
                clickCount: event.clickCount
            )
            lastSample = nil
            lastPressure = nil
            setNeedsDisplay(bounds)
            return
        }
        if activeTool == .rectangleSelection || activeTool == .ellipseSelection || activeTool == .lassoSelection || activeTool == .lassoFill {
            switch selectionInteractionMode {
            case .beginMoving:
                selectionMoveLastPoint = nil
                selectionInteractionMode = .idle
                strokeDelegate?.strokeCaptureViewDidCommitSelectionMove(self)
            case .beginDrawing:
                selectionInteractionMode = .idle
                strokeDelegate?.strokeCaptureView(
                    self,
                    didEndSelectionAt: sample(from: event).location,
                    modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                )
            case .idle:
                selectionInteractionMode = .idle
            }
            lastSample = nil
            lastPressure = nil
            setNeedsDisplay(bounds)
            return
        }

        if activeTool == .freeTransform {
            let point = sample(from: event).location
            if pendingTransformBeginPoint != nil {
                pendingTransformBeginPoint = nil
                pendingTransformLatestPoint = nil
                pendingTransformInteractionMode = nil
                transformPreviewDelegate?.strokeCaptureViewDidCancelTransformPreview(self)
            } else {
                transformPreviewDelegate?.strokeCaptureViewDidCancelTransformPreview(self)
                strokeDelegate?.strokeCaptureView(
                    self,
                    didEndTransformAt: point,
                    modifiers: activeModifierFlags
                )
                // mouseUp: ViewModel에 현재 offset 동기화 (SwiftUI overlay 업데이트)
                strokeDelegate?.strokeCaptureViewDidSyncTransformOffset(self)
            }
            activeFreeTransformDragPoint = nil
            activeFreeTransformDragMode = nil
            endContinuousTransformRendering()
            lastSample = nil
            lastPressure = nil
            return
        }

        if activeTool == .eyedropper || activeTool == .bucket || shouldUseEyedropperOverride(for: event) {
            lastSample = nil
            lastPressure = nil
            setNeedsDisplay(bounds)
            return
        }

        if isPanModeActive {
            lastPanLocation = nil
            return
        }

        let current = smoothed(sample(from: event))
        emitCoalescedStrokeSamples([current])
        enqueuePendingBrushEnd()
        let _ = flushPendingBrushInputQueue()
        endContinuousStrokeRendering()
        endBrushStrokeDiagnostics()
        scheduleBrushOutlineRevealAfterIdle()
        strokePacketIndex = 0
        strokeInputSampleCount = 0
        lastSample = nil
        smoothedPosition = nil
        lastPressure = nil
        setNeedsDisplay(bounds)
    }

    override func keyDown(with event: NSEvent) {
        let normalizedModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        activeModifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        updateCursorAppearance()

        // Enter：提交 freeTransform
        if (event.keyCode == 36 || event.keyCode == 76) && activeTool == .freeTransform {
            endContinuousTransformRendering()
            strokeDelegate?.strokeCaptureViewDidRequestApplyTransform(self)
            return
        }

        if (event.keyCode == 36 || event.keyCode == 76) &&
            activeTool == .sectorGradient {
            strokeDelegate?.strokeCaptureViewDidRequestApplyGradientSession(self)
            return
        }

        // ESC：取消 freeTransform 或其他工具
        if event.keyCode == 53 {
            if activeTool == .freeTransform {
                endContinuousTransformRendering()
                strokeDelegate?.strokeCaptureViewDidRequestCancelTransform(self)
                return
            }
            if activeTool == .straightLine || activeTool == .linearGradient || activeTool == .sectorGradient || activeTool == .polygonSelection {
                strokeDelegate?.strokeCaptureViewDidRequestCanvasToolCancel(self)
                return
            }
            strokeDelegate?.strokeCaptureViewDidRequestClearSelection(self)
            return
        }

        if event.keyCode == 49 {
            if !isPanModeActive {
                isPanModeActive = true
                strokeDelegate?.strokeCaptureView(self, didChangePanMode: true)
            }
            return
        }

        if event.charactersIgnoringModifiers == "[" {
            previewAdjustBrushSize(by: -1)
            strokeDelegate?.strokeCaptureView(self, didRequestBrushSizeAdjustment: -1)
            return
        }

        if event.charactersIgnoringModifiers == "]" {
            previewAdjustBrushSize(by: 1)
            strokeDelegate?.strokeCaptureView(self, didRequestBrushSizeAdjustment: 1)
            return
        }

        if let shortcutKey = event.charactersIgnoringModifiers?.uppercased(),
           shortcutKey.count == 1,
           ToolSidebarGroup.group(forShortcutKey: shortcutKey) != nil,
           normalizedModifiers.isDisjoint(with: [.command, .option, .control]) {
            strokeDelegate?.strokeCaptureView(
                self,
                didRequestToolShortcutKey: shortcutKey,
                modifiers: normalizedModifiers
            )
            return
        }

        if normalizedModifiers.contains(.command) && event.charactersIgnoringModifiers?.lowercased() == "d" {
            strokeDelegate?.strokeCaptureViewDidRequestClearSelection(self)
            return
        }

        if keyDownEventHandler?(event) == true {
            return
        }

        super.keyDown(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        activeModifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        hoverLocation = convert(event.locationInWindow, from: nil)
        updateCursorIndicator()
        updateCursorAppearance()
        let point = sample(from: event).location
        strokeDelegate?.strokeCaptureView(self, didHoverCanvasAt: point)
        if activeTool == .straightLine || activeTool == .polygonSelection {
            setNeedsDisplay(bounds)
        }
    }

    override func tabletPoint(with event: NSEvent) {
        activeModifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        hoverLocation = convert(event.locationInWindow, from: nil)
        updateCursorIndicator()
        updateCursorAppearance()
        strokeDelegate?.strokeCaptureView(self, didHoverCanvasAt: sample(from: event).location)
        if handleAuxiliaryBrushInputEvent(event, source: "tabletPoint") {
            return
        }
        super.tabletPoint(with: event)
    }

    override func pressureChange(with event: NSEvent) {
        activeModifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        hoverLocation = convert(event.locationInWindow, from: nil)
        updateCursorIndicator()
        updateCursorAppearance()
        strokeDelegate?.strokeCaptureView(self, didHoverCanvasAt: sample(from: event).location)
        if handleAuxiliaryBrushInputEvent(event, source: "pressureChange") {
            return
        }
        super.pressureChange(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        activeModifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        hoverLocation = convert(event.locationInWindow, from: nil)
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        updateCursorIndicator()
        updateCursorAppearance()
        strokeDelegate?.strokeCaptureView(self, didHoverCanvasAt: sample(from: event).location)
    }

    override func mouseExited(with event: NSEvent) {
        cancelBrushOutlineReveal()
        cancelBrushSizePreviewSettle()
        isAdjustingBrushSizePreview = false
        brushSizePreviewExpiresAtNs = 0
        isBrushOutlineForcedVisible = false
        suppressesBrushOutline = false
        hoverLocation = nil
        updateCursorIndicator()
        NSCursor.arrow.set()
    }

    override func keyUp(with event: NSEvent) {
        activeModifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        updateCursorAppearance()
        if event.keyCode == 49 {
            if isPanModeActive {
                isPanModeActive = false
                strokeDelegate?.strokeCaptureView(self, didChangePanMode: false)
            }
            return
        }

        if keyUpEventHandler?(event) == true {
            return
        }

        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let previousModifiers = activeModifierFlags
        activeModifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        updateCursorAppearance()
        let shiftDidRise = !previousModifiers.contains(.shift) && activeModifierFlags.contains(.shift)
        if shiftDidRise, !isGradientDragActive, (activeTool == .linearGradient || activeTool == .sectorGradient) {
            strokeDelegate?.strokeCaptureViewDidRequestEnterGradientEditing(self)
        }
        if activeTool == .freeTransform,
           let activePoint = activeFreeTransformDragPoint,
           case .scale = activeFreeTransformDragMode,
           pendingTransformBeginPoint == nil {
            strokeDelegate?.strokeCaptureView(
                self,
                didChangeTransformAt: activePoint,
                modifiers: activeModifierFlags
            )
        }
        if modifierFlagsChangedEventHandler?(event.modifierFlags) == true {
            return
        }
        super.flagsChanged(with: event)
    }

    private func sample(from event: NSEvent) -> CanvasStrokeSample {
        let location = convert(event.locationInWindow, from: nil)
        let normalizedX = max(min(location.x / bounds.width, 1), 0)
        let normalizedY = max(min(location.y / bounds.height, 1), 0)
        let rawPressure = Float(event.pressure)
        let effectivePressure = resolveBrushInputPressure(
            rawPressure: rawPressure,
            isTabletLikeEvent: isTabletLikeEvent(event),
            eventSubtypeIsTabletPoint: event.subtype == .tabletPoint,
            sawTabletAuxiliaryEvent: sawTabletAuxiliaryEvent,
            lastPressure: lastPressure,
            strokeInputSampleCount: strokeInputSampleCount,
            minimumTabletPressure: minimumTabletPressure,
            debugForceConstantPressure: debugForceConstantPressure
        )
        lastPressure = effectivePressure

        let sample = CanvasStrokeSample(
            location: CanvasPoint(
                x: Double(normalizedX) * Double(canvasSize.width),
                y: Double(1 - normalizedY) * Double(canvasSize.height)
            ),
            pressure: effectivePressure
        )
        recordBrushInputDebugSample(
            event: event,
            rawPressure: rawPressure,
            filteredPressure: effectivePressure,
            sample: sample
        )

        if activeTool == .lassoSelection || activeTool == .lassoFill {
            let message =
                """
                [sample] event=\(event.type.rawValue) \
                rawView=(\(location.x),\(location.y)) \
                normalized=(\(normalizedX),\(normalizedY)) \
                canvas=(\(sample.location.x),\(sample.location.y))
                """
            selectionTraceLogger.debug("\(message, privacy: .public)")
            emitSelectionTraceHost(message)
        }

        return sample
    }

    private func isBrushLikeToolActive() -> Bool {
        activeTool == .brush || activeTool == .eraser || activeTool == .smudge || activeTool == .brightnessAdjust
    }

    private func isTabletLikeEvent(_ event: NSEvent) -> Bool {
        event.type == .tabletPoint || event.type == .pressure || event.subtype == .tabletPoint
    }

    private func beginBrushStrokeDiagnostics() {
        guard isBrushLikeToolActive() else { return }
        isBrushStrokeActive = true
        sawTabletAuxiliaryEvent = false
        brushDebugRecords = []
        if debugDisableMouseCoalescingDuringStroke {
            previousMouseCoalescingEnabled = NSEvent.isMouseCoalescingEnabled
            NSEvent.isMouseCoalescingEnabled = false
            brushStrokeLogger.debug("[brush-feel] mouseCoalescingDisabled=\(!NSEvent.isMouseCoalescingEnabled, privacy: .public)")
            brushStrokeLogger.debug(
                "[coalescing] begin previous=\(String(describing: self.previousMouseCoalescingEnabled), privacy: .public) current=\(NSEvent.isMouseCoalescingEnabled, privacy: .public)"
            )
        }
    }

    private func endBrushStrokeDiagnostics() {
        guard isBrushStrokeActive else { return }

        let firstSlice = Array(brushDebugRecords.prefix(8))
        let middleSlice: [BrushInputDebugRecord]
        if brushDebugRecords.count >= 16 {
            let start = max((brushDebugRecords.count / 2) - 4, 0)
            middleSlice = Array(brushDebugRecords[start..<min(start + 8, brushDebugRecords.count)])
        } else if brushDebugRecords.count > 8 {
            middleSlice = Array(brushDebugRecords.suffix(8))
        } else {
            middleSlice = firstSlice
        }

        func mean<T: BinaryFloatingPoint>(_ values: [T]) -> Double {
            guard !values.isEmpty else { return 0 }
            return values.reduce(0) { $0 + Double($1) } / Double(values.count)
        }

        if debugLogFirstRawSamples, !firstSlice.isEmpty {
            let startMeanDT = mean(firstSlice.dropFirst().map(\.dt))
            let startMeanDistance = mean(firstSlice.dropFirst().map(\.distanceFromPrevious))
            let middleMeanDT = mean(middleSlice.dropFirst().map(\.dt))
            let middleMeanDistance = mean(middleSlice.dropFirst().map(\.distanceFromPrevious))
            brushStrokeLogger.debug(
                "[inputSummary] startMeanDT=\(startMeanDT, privacy: .public) startMeanDistance=\(startMeanDistance, privacy: .public) middleMeanDT=\(middleMeanDT, privacy: .public) middleMeanDistance=\(middleMeanDistance, privacy: .public)"
            )
            if !sawTabletAuxiliaryEvent {
                brushStrokeLogger.debug("[tablet] no tabletPoint/pressureChange events received during stroke")
            }
        }

        if let previousMouseCoalescingEnabled {
            NSEvent.isMouseCoalescingEnabled = previousMouseCoalescingEnabled
            brushStrokeLogger.debug("[brush-feel] restoredMouseCoalescing=\(NSEvent.isMouseCoalescingEnabled == previousMouseCoalescingEnabled, privacy: .public)")
            brushStrokeLogger.debug(
                "[coalescing] end restored=\(previousMouseCoalescingEnabled, privacy: .public) current=\(NSEvent.isMouseCoalescingEnabled, privacy: .public)"
            )
        }

        previousMouseCoalescingEnabled = nil
        isBrushStrokeActive = false
        sawTabletAuxiliaryEvent = false
        brushDebugRecords = []
    }

    private func recordBrushInputDebugSample(
        event: NSEvent,
        rawPressure: Float,
        filteredPressure: Float,
        sample: CanvasStrokeSample
    ) {
        guard isBrushStrokeActive, isBrushLikeToolActive() else { return }

        let previous = brushDebugRecords.last
        let dx = previous.map { sample.location.x - $0.location.x } ?? 0
        let dy = previous.map { sample.location.y - $0.location.y } ?? 0
        let dt = previous.map { event.timestamp - $0.timestamp } ?? 0
        let distance = previous.map { _ in sqrt((dx * dx) + (dy * dy)) } ?? 0

        let record = BrushInputDebugRecord(
            index: strokeInputSampleCount,
            eventType: event.type,
            eventSubtype: event.subtype,
            timestamp: event.timestamp,
            location: sample.location,
            rawPressure: rawPressure,
            filteredPressure: filteredPressure,
            dx: dx,
            dy: dy,
            dt: dt,
            distanceFromPrevious: distance
        )
        brushDebugRecords.append(record)

        if debugLogFirstRawSamples, record.index < 8 {
            brushStrokeLogger.debug(
                "[rawSample] index=\(record.index, privacy: .public) type=\(String(describing: record.eventType), privacy: .public) subtype=\(String(describing: record.eventSubtype), privacy: .public) timestamp=\(record.timestamp, privacy: .public) x=\(record.location.x, privacy: .public) y=\(record.location.y, privacy: .public) rawPressure=\(record.rawPressure, privacy: .public) filteredPressure=\(record.filteredPressure, privacy: .public) dx=\(record.dx, privacy: .public) dy=\(record.dy, privacy: .public) dt=\(record.dt, privacy: .public) distance=\(record.distanceFromPrevious, privacy: .public) deviceID=n/a"
            )
        }

        strokeInputSampleCount += 1
    }

    private func handleAuxiliaryBrushInputEvent(_ event: NSEvent, source: StaticString) -> Bool {
        guard isBrushStrokeActive, isBrushLikeToolActive(), !isPanModeActive else {
            return false
        }

        sawTabletAuxiliaryEvent = true
        brushStrokeLogger.debug(
            "[auxEvent] source=\(source, privacy: .public) type=\(String(describing: event.type), privacy: .public) subtype=\(String(describing: event.subtype), privacy: .public) timestamp=\(event.timestamp, privacy: .public) rawPressure=\(Float(event.pressure), privacy: .public) deviceID=n/a"
        )
        let sample = smoothed(sample(from: event))
        emitCoalescedStrokeSamples([sample])
        lastSample = sample
        strokePacketIndex += 1
        setNeedsDisplay(bounds)
        return true
    }
    private func canvasRotationAngleDegrees(for location: CGPoint) -> Double {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        return atan2(location.y - center.y, location.x - center.x) * 180 / .pi
    }

    private func canvasRotationSensitivity(for location: CGPoint) -> Double {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let distance = hypot(location.x - center.x, location.y - center.y)
        let normalized = min(max(distance / 240, 0.2), 0.75)
        return normalized
    }

    private func selectionSamples(from event: NSEvent) -> [CanvasStrokeSample] {
        guard activeTool == .lassoSelection || activeTool == .lassoFill else {
            return [sample(from: event)]
        }

        var events: [NSEvent] = [event]
        let mask = NSEvent.EventTypeMask.leftMouseDragged

        while let queuedEvent = window?.nextEvent(
            matching: mask,
            until: Date.distantPast,
            inMode: .eventTracking,
            dequeue: true
        ) {
            events.append(queuedEvent)
        }

        if events.count == 1 {
            while let queuedEvent = window?.nextEvent(
                matching: mask,
                until: Date.distantPast,
                inMode: .default,
                dequeue: true
            ) {
                events.append(queuedEvent)
            }
        }

        return events.map(sample(from:))
    }

    private func brushInputEvents(from event: NSEvent) -> [NSEvent] {
        [event]
    }

    /// 入力スムージング用 EMA。
    /// α が小さいほど遅延が大きく滑らか、大きいほど即応する。
    /// 0.5 = 適度な追従感（起始直線を消しつつ遅延は最小限）。
    private let isBrushPositionSmoothingEnabled = false
    private let smoothingAlpha: Double = 1.0

    /// raw サンプルに EMA を適用して平滑化座標を返す。
    /// 筆触開始時は smoothedPosition をリセットすること。
    private func smoothed(_ raw: CanvasStrokeSample) -> CanvasStrokeSample {
        guard isBrushPositionSmoothingEnabled else {
            smoothedPosition = raw.location
            return raw
        }
        let pos: CanvasPoint
        if let prev = smoothedPosition {
            pos = CanvasPoint(
                x: prev.x + smoothingAlpha * (raw.location.x - prev.x),
                y: prev.y + smoothingAlpha * (raw.location.y - prev.y)
            )
        } else {
            pos = raw.location
        }
        smoothedPosition = pos
        return CanvasStrokeSample(location: pos, pressure: raw.pressure)
    }

    /// 把一批 coalesced samples 过滤重复点后发送给 delegate。
    /// Renderer 侧的 look-ahead 缓冲负责管理渲染时机，这里只做去重，不做数量限制。
    private func emitCoalescedStrokeSamples(_ samples: [CanvasStrokeSample]) {
        guard !samples.isEmpty else { return }
        // 去掉极近重复点：距离 < 0.5px 且压力变化 < 0.01 时跳过
        var filtered: [CanvasStrokeSample] = [samples[0]]
        for i in 1..<samples.count {
            let prev = filtered[filtered.count - 1]
            let curr = samples[i]
            let dx = curr.location.x - prev.location.x
            let dy = curr.location.y - prev.location.y
            if dx * dx + dy * dy < 0.25, abs(curr.pressure - prev.pressure) < 0.01 {
                continue
            }
            filtered.append(curr)
        }
        pendingBrushInputQueue.enqueue(.samples(filtered))
    }

    private func enqueuePendingBrushBegin() {
        pendingBrushInputQueue.enqueue(.begin)
    }

    private func enqueuePendingBrushEnd() {
        pendingBrushInputQueue.enqueue(.end)
    }

    @discardableResult
    func flushPendingBrushInputQueue() -> Int {
        let batches = pendingBrushInputQueue.flush()
        guard !batches.isEmpty else { return 0 }
        let flushStartNs = DispatchTime.now().uptimeNanoseconds
        let oldestEnqueueNs = batches.first?.enqueuedAt ?? flushStartNs
        var flushedSampleBatchCount = 0

        for batch in batches {
            switch batch.kind {
            case .begin:
                strokeDelegate?.strokeCaptureViewDidBeginStroke(self)
            case .samples(let samples):
                let didProduceStartNs = DispatchTime.now().uptimeNanoseconds
                strokeDelegate?.strokeCaptureView(self, didProduce: samples)
                let didProduceDurationMs = Double(DispatchTime.now().uptimeNanoseconds - didProduceStartNs) / 1_000_000
                brushStrokeLogger.debug("[brush-feel] didProduceSyncMs=\(didProduceDurationMs, privacy: .public)")
                flushedSampleBatchCount += 1
            case .end:
                strokeDelegate?.strokeCaptureViewDidEndStroke(self)
            }
        }

        let enqueueToFlushMs = Double(flushStartNs - oldestEnqueueNs) / 1_000_000
        brushStrokeLogger.debug("[brush-feel] flushPacketsThisFrame=\(flushedSampleBatchCount, privacy: .public)")
        brushStrokeLogger.debug("[brush-feel] enqueueToFlushMs=\(enqueueToFlushMs, privacy: .public)")
        return flushedSampleBatchCount
    }

    private func shouldUseEyedropperOverride(for event: NSEvent) -> Bool {
        allowsTemporaryEyedropperOverride &&
            event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.option)
    }

    private func beginContinuousTransformRendering() {
        enableSetNeedsDisplay = false
        isPaused = false
    }

    private func endContinuousTransformRendering() {
        isPaused = true
        enableSetNeedsDisplay = true
        setNeedsDisplay(bounds)
    }

    private func beginContinuousStrokeRendering() {
        continuousStrokeRenderGraceWorkItem?.cancel()
        continuousStrokeRenderGraceWorkItem = nil
        enableSetNeedsDisplay = false
        isPaused = false
    }

    private func endContinuousStrokeRendering() {
        continuousStrokeRenderGraceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isPaused = true
            self.enableSetNeedsDisplay = true
            self.setNeedsDisplay(self.bounds)
            self.brushStrokeLogger.debug("[brush-feel] renderGraceHit=false")
        }
        continuousStrokeRenderGraceWorkItem = workItem
        brushStrokeLogger.debug("[brush-feel] renderGraceHit=true")
        DispatchQueue.main.asyncAfter(deadline: .now() + strokeRenderGraceDelay, execute: workItem)
    }

    func resetInteractionState() {
        continuousStrokeRenderGraceWorkItem?.cancel()
        continuousStrokeRenderGraceWorkItem = nil
        cancelBrushOutlineReveal()
        cancelBrushSizePreviewSettle()
        isAdjustingBrushSizePreview = false
        brushSizePreviewExpiresAtNs = 0
        isBrushOutlineForcedVisible = false
        suppressesBrushOutline = false
        endBrushStrokeDiagnostics()
        lastSample = nil
        smoothedPosition = nil
        lastPanLocation = nil
        lastPressure = nil
        selectionInteractionMode = .idle
        selectionMoveLastPoint = nil
        pendingTransformBeginPoint = nil
        pendingTransformLatestPoint = nil
        pendingTransformInteractionMode = nil
        isGradientDragActive = false
        activeFreeTransformDragPoint = nil
        activeFreeTransformDragMode = nil
        isPaused = true
        enableSetNeedsDisplay = true
        setNeedsDisplay(bounds)
        updateCursorAppearance()
    }

    private func updateCursorIndicator() {
        let updateStartNs = DispatchTime.now().uptimeNanoseconds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard let hoverLocation else {
            cursorIndicatorLayer.isHidden = true
            cursorTipLayer.isHidden = true
            let updateDurationMs = Double(DispatchTime.now().uptimeNanoseconds - updateStartNs) / 1_000_000
            brushStrokeLogger.debug("[brush-feel] cursorIndicatorUpdateMs=\(updateDurationMs, privacy: .public)")
            brushStrokeLogger.debug("[brush-feel] cursorImplicitAnimationDisabled=true")
            brushStrokeLogger.debug("[brush-feel] cursorTipEnabled=false")
            return
        }

        let showBrushTip = shouldShowBrushTip
        let showBrushOutline = shouldShowBrushOutline

        cursorTipLayer.isHidden = !showBrushTip
        let tipDiameter: CGFloat = 3
        if showBrushTip {
            cursorTipLayer.path = CGPath(
                ellipseIn: CGRect(
                    x: hoverLocation.x - (tipDiameter / 2),
                    y: hoverLocation.y - (tipDiameter / 2),
                    width: tipDiameter,
                    height: tipDiameter
                ),
                transform: nil
            )
        }

        cursorIndicatorLayer.isHidden = !showBrushOutline
        if showBrushOutline {
            let diameter = max(CGFloat(displayBrushSize) * (bounds.width / CGFloat(max(canvasSize.width, 1))), 2)
            cursorIndicatorLayer.path = CGPath(
                ellipseIn: CGRect(
                    x: hoverLocation.x - (diameter / 2),
                    y: hoverLocation.y - (diameter / 2),
                    width: diameter,
                    height: diameter
                ),
                transform: nil
            )
        }
        let updateDurationMs = Double(DispatchTime.now().uptimeNanoseconds - updateStartNs) / 1_000_000
        brushStrokeLogger.debug("[brush-feel] cursorIndicatorUpdateMs=\(updateDurationMs, privacy: .public)")
        brushStrokeLogger.debug("[brush-feel] cursorImplicitAnimationDisabled=true")
        brushStrokeLogger.debug("[brush-feel] cursorTipEnabled=\(showBrushTip, privacy: .public)")
        brushStrokeLogger.debug("[brush-size] outlineShownForSizePreview=\(self.isAdjustingBrushSizePreview && showBrushOutline, privacy: .public)")
    }

    private var shouldShowBrushOutline: Bool {
        shouldShowBrushOutlineIndicator(
            activeTool: activeTool,
            hasHoverLocation: hoverLocation != nil,
            isAdjustingBrushSizePreview: isAdjustingBrushSizePreview,
            isBrushOutlineForcedVisible: isBrushOutlineForcedVisible,
            suppressesBrushOutline: suppressesBrushOutline,
            isBrushStrokeActive: isBrushStrokeActive,
            showsBrushOutlineDuringStroke: showsBrushOutlineDuringStroke,
            hasContinuousStrokeGrace: continuousStrokeRenderGraceWorkItem != nil
        )
    }

    private var shouldShowBrushTip: Bool {
        shouldShowBrushTipIndicator(
            activeTool: activeTool,
            hasHoverLocation: hoverLocation != nil
        )
    }

    private var isEyedropperCursorActive: Bool {
        activeTool == .eyedropper || (allowsTemporaryEyedropperOverride && activeModifierFlags.contains(.option))
    }

    private var allowsTemporaryEyedropperOverride: Bool {
        switch activeTool {
        case .brush, .eraser, .smudge, .straightLine, .linearGradient, .sectorGradient, .brightnessAdjust:
            return true
        case .eyedropper, .bucket, .polygonSelection, .lassoFill, .rectangleSelection, .ellipseSelection, .lassoSelection, .canvasRotate, .freeTransform:
            return false
        }
    }

    private func updateCursorAppearance() {
        guard let cursorMode = preferredBrushCursorMode(
            activeTool: activeTool,
            isEyedropperCursorActive: isEyedropperCursorActive,
            hasHoverLocation: hoverLocation != nil
        ) else {
            return
        }
        switch cursorMode {
        case .eyedropper:
            Self.eyedropperCursor.set()
        case .crosshair:
            NSCursor.crosshair.set()
        case .arrow:
            NSCursor.arrow.set()
        }
    }

    private func cancelBrushOutlineReveal() {
        brushOutlineRevealWorkItem?.cancel()
        brushOutlineRevealWorkItem = nil
    }

    private func cancelBrushSizePreviewSettle() {
        brushSizePreviewSettleWorkItem?.cancel()
        brushSizePreviewSettleWorkItem = nil
    }

    private func suppressBrushOutlineForActiveInput() {
        cancelBrushOutlineReveal()
        isBrushOutlineForcedVisible = false
        suppressesBrushOutline = true
    }

    private func scheduleBrushOutlineRevealAfterIdle() {
        guard isBrushLikeToolActive() else { return }
        cancelBrushOutlineReveal()
        let delay = max(brushOutlineIdleRevealDelay, strokeRenderGraceDelay)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isBrushLikeToolActive(), self.hoverLocation != nil else { return }
            guard !self.isBrushStrokeActive, self.continuousStrokeRenderGraceWorkItem == nil else { return }
            self.suppressesBrushOutline = false
            self.isBrushOutlineForcedVisible = false
            self.updateCursorIndicator()
        }
        brushOutlineRevealWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func scheduleBrushSizePreviewSettle() {
        cancelBrushSizePreviewSettle()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now >= self.brushSizePreviewExpiresAtNs else {
                self.scheduleBrushSizePreviewSettle()
                return
            }
            self.isAdjustingBrushSizePreview = false
            self.isBrushOutlineForcedVisible = false
            if !self.isBrushStrokeActive, self.continuousStrokeRenderGraceWorkItem == nil {
                self.suppressesBrushOutline = false
            }
            self.updateCursorIndicator()
        }
        brushSizePreviewSettleWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + brushSizePreviewSettleDelay, execute: workItem)
    }

    private func forceBrushOutlineForSizePreview() {
        guard isBrushLikeToolActive() else { return }
        cancelBrushOutlineReveal()
        suppressesBrushOutline = false
        isBrushOutlineForcedVisible = true
        updateCursorIndicator()
    }

    func previewAdjustBrushSize(by delta: Float) {
        guard isBrushLikeToolActive() else { return }
        let currentSize = isAdjustingBrushSizePreview ? displayBrushSize : brushSize
        let direction: Float = delta == 0 ? 0 : (delta > 0 ? 1 : -1)
        let step = brushSizeShortcutStep(for: currentSize)
        displayBrushSize = max(1, currentSize + (direction * step))
        isAdjustingBrushSizePreview = true
        brushSizePreviewExpiresAtNs = DispatchTime.now().uptimeNanoseconds + UInt64(brushSizePreviewSettleDelay * 1_000_000_000)
        forceBrushOutlineForSizePreview()
        updateCursorIndicator()
        updateCursorAppearance()
        scheduleBrushSizePreviewSettle()
        brushStrokeLogger.debug("[brush-size] localPreviewApplied=true")
        brushStrokeLogger.debug("[brush-size] displayBrushSize=\(self.displayBrushSize, privacy: .public)")
        brushStrokeLogger.debug("[brush-size] modelBrushSize=\(self.brushSize, privacy: .public)")
        brushStrokeLogger.debug("[brush-size] previewState=local")
    }

    private func brushSizeShortcutStep(for size: Float) -> Float {
        if size <= 10 { return 1 }
        if size <= 50 { return 5 }
        if size <= 100 { return 10 }
        if size <= 200 { return 25 }
        if size <= 300 { return 50 }
        return 100
    }

}

@MainActor
final class MetalCanvasCoordinator: NSObject, MTKViewDelegate, StrokeCaptureDelegate {
    private let metalContext: MetalDeviceContext
    private let layerSurfaceStore: StageOneLayerSurfaceStore
    private let canvasPresenter: StageOneCanvasPresenter?
    private let canvasPresenterInitializationError: Error?
    private let transformPreviewBuilder: TransformPreviewSessionBuilder
    private let linearGradientRenderer: LinearGradientRenderer
    private let sectorGradientRenderer: SectorGradientRenderer
    var activeTool: ToolKind
    var previousExternalRedrawRevision: UInt64 = 0
    var transformSelectionShape: SelectionShape?
    private let onStrokeBegan: () -> Void
    private let onStrokeInput: ([CanvasStrokeSample]) -> Void
    private let onStrokeEnded: () -> Void
    private let onFlushPendingBrushWork: (MTLCommandBuffer) -> BrushFlushMetrics?
    private let onDrainPendingBrushCommitsInteractively: (Bool) -> Void
    private let resolveBrushDisplayTexture: (LayerID) -> MTLTexture?
    private let onEyedropperSample: (CanvasPoint) -> Void
    private let onBucketFill: (CanvasPoint) -> Void
    private let onCanvasClick: (CanvasPoint, NSEvent.ModifierFlags, Int) -> Void
    private let onCanvasHover: (CanvasPoint) -> Void
    private let onSelectionBegan: (CanvasPoint, NSEvent.ModifierFlags) -> Void
    private let onSelectionChanged: (CanvasPoint, NSEvent.ModifierFlags) -> Void
    private let onSelectionEnded: (CanvasPoint, NSEvent.ModifierFlags) -> Void
    private let onSelectionMouseDown: (CanvasPoint, NSEvent.ModifierFlags) -> SelectionMouseDownAction
    private let onMoveSelectionPreview: (Double, Double) -> Void
    private let onCommitSelectionMove: () -> Void
    private let onTransformBegan: (CanvasPoint, FreeTransformInteractionMode, NSEvent.ModifierFlags) -> Void
    private let onTransformChanged: (CanvasPoint, NSEvent.ModifierFlags) -> Void
    private let onTransformEnded: (CanvasPoint, NSEvent.ModifierFlags) -> Void
    private let onTransformOffsetChanged: (CanvasPoint) -> Void
    private let onCanvasRotationChanged: (Double) -> Void
    private let onPanModeChanged: (Bool) -> Void
    private let onToolShortcut: (String, NSEvent.ModifierFlags) -> Void
    private let onGradientDragBegan: (CanvasPoint, NSEvent.ModifierFlags) -> Void
    private let onGradientDragChanged: (CanvasPoint, NSEvent.ModifierFlags) -> Void
    private let onGradientDragEnded: (CanvasPoint, NSEvent.ModifierFlags) -> Void
    private let onEnterGradientEditing: () -> Void
    private let onCancelCanvasTool: () -> Void
    private let onApplyGradientSession: () -> Void
    private let onClearSelection: () -> Void
    private let onApplyTransform: () -> Void
    private let onCancelTransform: () -> Void
    private let onAdjustBrushSize: (Float) -> Void
    private let brushFeelLogger = Logger(subsystem: "ArtFlex", category: "BrushFeel")

    var sceneSnapshot: CanvasSceneSnapshot?
    var isTransformingSelection = false
    var isFreeTransformDragging = false
    var activeFreeTransformInteractionMode: FreeTransformInteractionMode?
    fileprivate var transformPreviewSession: TransformPreviewSession?
    fileprivate var preparedTransformSession: TransformPreviewSession?
    fileprivate var preparedTransformSignature: TransformPreviewPreparedSignature?
    fileprivate var transformPreviewStartPoint: CanvasPoint?
    fileprivate var transformPreviewDragBaseOffset = CanvasPoint(x: 0, y: 0)
    fileprivate var isPrepBuildingSession = false
    // freeTransform 전체 레이어 이동용 offset (makeSession 없이 GPU encodePreview에 직접 전달)
    fileprivate var freeTransformDragOffset = CanvasPoint(x: 0, y: 0)
    fileprivate var freeTransformDragStart: CanvasPoint? = nil
    fileprivate var freeTransformDragBase = CanvasPoint(x: 0, y: 0)
    fileprivate var liveTransformPreview: FreeTransformPreview?
    fileprivate var liveTransformMode: FreeTransformInteractionMode?
    fileprivate var liveTransformDragStartPoint: CanvasPoint?
    fileprivate var liveTransformStartPreview = FreeTransformPreview.identity
    fileprivate var isLiveTransformDragging = false
    var linearGradientPreview: LinearGradientPreview?
    var sectorGradientPreview: SectorGradientPreview?
    var gradientPreviewColor: RGBAColor = .black
    var gradientPaintJitterAmount: Float = 0
    var gradientPaintContrastAmount: Float = 0
    var gradientDistortionAmount: Float = 0
    var previousLinearGradientPreview: LinearGradientPreview?
    var previousSectorGradientPreview: SectorGradientPreview?
    var previousGradientPreviewColor: RGBAColor = .black
    var previousGradientPaintJitterAmount: Float = 0
    var previousGradientPaintContrastAmount: Float = 0
    var previousGradientDistortionAmount: Float = 0
    var transformPreview = FreeTransformPreview.identity
    var isLuminosityPreviewEnabled = false
    private let labLuminosityPostProcessor: LABLuminosityPostProcessor?
    private let labLuminosityPostProcessorError: Error?
    private var cachedLuminosityTempTexture: MTLTexture?
    private let selectionTraceLogger = Logger(subsystem: "ArtFlex", category: "SelectionTrace")
    private let transformLogger = Logger(subsystem: "ArtFlex", category: "Transform")
    private var previewTimingFrameCounter = 0
    private var didLogNoRebuildDuringActiveMove = false
    private var lastIdlePreparedAvailability: Bool?
    private var lastLoggedWholeLayerCanScaleRotate: Bool?
    private var lastLoggedWholeLayerUsesInteractionBoundsForHitTesting: Bool?
    private var liveMoveLogCount = 0
    private var hasScheduledInteractiveBrushCommitDrain = false

    init(
        metalContext: MetalDeviceContext,
        layerSurfaceStore: StageOneLayerSurfaceStore,
        activeTool: ToolKind,
        externalRedrawRevision: UInt64,
        transformSelectionShape: SelectionShape?,
        transformPreview: FreeTransformPreview,
        linearGradientPreview: LinearGradientPreview?,
        sectorGradientPreview: SectorGradientPreview?,
        gradientPreviewColor: RGBAColor,
        gradientPaintJitterAmount: Float,
        gradientPaintContrastAmount: Float,
        gradientDistortionAmount: Float,
        onCanvasRotationChanged: @escaping (Double) -> Void,
        onStrokeBegan: @escaping () -> Void,
        onStrokeInput: @escaping ([CanvasStrokeSample]) -> Void,
        onStrokeEnded: @escaping () -> Void,
        onFlushPendingBrushWork: @escaping (MTLCommandBuffer) -> BrushFlushMetrics?,
        onDrainPendingBrushCommitsInteractively: @escaping (Bool) -> Void,
        resolveBrushDisplayTexture: @escaping (LayerID) -> MTLTexture?,
        onEyedropperSample: @escaping (CanvasPoint) -> Void,
        onBucketFill: @escaping (CanvasPoint) -> Void,
        onCanvasClick: @escaping (CanvasPoint, NSEvent.ModifierFlags, Int) -> Void,
        onCanvasHover: @escaping (CanvasPoint) -> Void,
        onSelectionBegan: @escaping (CanvasPoint, NSEvent.ModifierFlags) -> Void,
        onSelectionChanged: @escaping (CanvasPoint, NSEvent.ModifierFlags) -> Void,
        onSelectionEnded: @escaping (CanvasPoint, NSEvent.ModifierFlags) -> Void,
        onSelectionMouseDown: @escaping (CanvasPoint, NSEvent.ModifierFlags) -> SelectionMouseDownAction,
        onMoveSelectionPreview: @escaping (Double, Double) -> Void,
        onCommitSelectionMove: @escaping () -> Void,
        onTransformBegan: @escaping (CanvasPoint, FreeTransformInteractionMode, NSEvent.ModifierFlags) -> Void,
        onTransformChanged: @escaping (CanvasPoint, NSEvent.ModifierFlags) -> Void,
        onTransformEnded: @escaping (CanvasPoint, NSEvent.ModifierFlags) -> Void,
        onTransformOffsetChanged: @escaping (CanvasPoint) -> Void,
        onPanModeChanged: @escaping (Bool) -> Void,
        onToolShortcut: @escaping (String, NSEvent.ModifierFlags) -> Void,
        onGradientDragBegan: @escaping (CanvasPoint, NSEvent.ModifierFlags) -> Void,
        onGradientDragChanged: @escaping (CanvasPoint, NSEvent.ModifierFlags) -> Void,
        onGradientDragEnded: @escaping (CanvasPoint, NSEvent.ModifierFlags) -> Void,
        onEnterGradientEditing: @escaping () -> Void,
        onCancelCanvasTool: @escaping () -> Void,
        onApplyGradientSession: @escaping () -> Void,
        onClearSelection: @escaping () -> Void,
        onApplyTransform: @escaping () -> Void,
        onCancelTransform: @escaping () -> Void,
        onAdjustBrushSize: @escaping (Float) -> Void
    ) {
        self.metalContext = metalContext
        self.layerSurfaceStore = layerSurfaceStore
        do {
            self.canvasPresenter = try StageOneCanvasPresenter(device: metalContext.device)
            self.canvasPresenterInitializationError = nil
        } catch {
            self.canvasPresenter = nil
            self.canvasPresenterInitializationError = error
        }
        self.transformPreviewBuilder = TransformPreviewSessionBuilder(device: metalContext.device)
        self.linearGradientRenderer = LinearGradientRenderer(device: metalContext.device)
        self.sectorGradientRenderer = SectorGradientRenderer(device: metalContext.device)
        do {
            self.labLuminosityPostProcessor = try LABLuminosityPostProcessor(device: metalContext.device)
            self.labLuminosityPostProcessorError = nil
        } catch {
            self.labLuminosityPostProcessor = nil
            self.labLuminosityPostProcessorError = error
        }
        self.activeTool = activeTool
        self.previousExternalRedrawRevision = externalRedrawRevision
        self.transformSelectionShape = transformSelectionShape
        self.transformPreview = transformPreview
        self.linearGradientPreview = linearGradientPreview
        self.sectorGradientPreview = sectorGradientPreview
        self.gradientPreviewColor = gradientPreviewColor
        self.gradientPaintJitterAmount = gradientPaintJitterAmount
        self.gradientPaintContrastAmount = gradientPaintContrastAmount
        self.gradientDistortionAmount = gradientDistortionAmount
        self.previousLinearGradientPreview = linearGradientPreview
        self.previousSectorGradientPreview = sectorGradientPreview
        self.previousGradientPreviewColor = gradientPreviewColor
        self.previousGradientPaintJitterAmount = gradientPaintJitterAmount
        self.previousGradientPaintContrastAmount = gradientPaintContrastAmount
        self.previousGradientDistortionAmount = gradientDistortionAmount
        self.onCanvasRotationChanged = onCanvasRotationChanged
        self.onStrokeBegan = onStrokeBegan
        self.onStrokeInput = onStrokeInput
        self.onStrokeEnded = onStrokeEnded
        self.onFlushPendingBrushWork = onFlushPendingBrushWork
        self.onDrainPendingBrushCommitsInteractively = onDrainPendingBrushCommitsInteractively
        self.resolveBrushDisplayTexture = resolveBrushDisplayTexture
        self.onEyedropperSample = onEyedropperSample
        self.onBucketFill = onBucketFill
        self.onCanvasClick = onCanvasClick
        self.onCanvasHover = onCanvasHover
        self.onSelectionBegan = onSelectionBegan
        self.onSelectionChanged = onSelectionChanged
        self.onSelectionEnded = onSelectionEnded
        self.onSelectionMouseDown = onSelectionMouseDown
        self.onMoveSelectionPreview = onMoveSelectionPreview
        self.onCommitSelectionMove = onCommitSelectionMove
        self.onTransformBegan = onTransformBegan
        self.onTransformChanged = onTransformChanged
        self.onTransformEnded = onTransformEnded
        self.onTransformOffsetChanged = onTransformOffsetChanged
        self.onPanModeChanged = onPanModeChanged
        self.onToolShortcut = onToolShortcut
        self.onGradientDragBegan = onGradientDragBegan
        self.onGradientDragChanged = onGradientDragChanged
        self.onGradientDragEnded = onGradientDragEnded
        self.onEnterGradientEditing = onEnterGradientEditing
        self.onCancelCanvasTool = onCancelCanvasTool
        self.onApplyGradientSession = onApplyGradientSession
        self.onClearSelection = onClearSelection
        self.onApplyTransform = onApplyTransform
        self.onCancelTransform = onCancelTransform
        self.onAdjustBrushSize = onAdjustBrushSize
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let drawStartNs = DispatchTime.now().uptimeNanoseconds
        guard
            let drawable = view.currentDrawable,
            let descriptor = view.currentRenderPassDescriptor,
            let commandBuffer = metalContext.commandQueue.makeCommandBuffer()
        else {
            return
        }

        let flushedInputBatchCount: Int
        if let strokeView = view as? StrokeCaptureMTKView {
            flushedInputBatchCount = strokeView.flushPendingBrushInputQueue()
        } else {
            flushedInputBatchCount = 0
        }
        let liveFlushMetrics = onFlushPendingBrushWork(commandBuffer)
        let hadLiveBrushWorkThisFrame =
            flushedInputBatchCount > 0 ||
            (liveFlushMetrics?.flushedPacketCount ?? 0) > 0

        guard let canvasPresenter else {
            if let canvasPresenterInitializationError {
                brushFeelLogger.error("Canvas presenter unavailable: \(canvasPresenterInitializationError.localizedDescription, privacy: .public)")
            }
            commandBuffer.present(drawable)
            commandBuffer.commit()
            scheduleInteractiveBrushCommitDrain(hadLiveBrushWorkThisFrame: hadLiveBrushWorkThisFrame)
            return
        }

        if let snapshot = sceneSnapshot {
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].storeAction = .store
            descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)

            let canvasSize = snapshot.renderSnapshot.document.canvasSize
            let isTransforming = isTransformingSelection && activeTool == .freeTransform
            let effectivePreview = liveTransformPreview ?? transformPreview
            let activeLayerSurfaceID = snapshot.activeLayerSurfaceID
            let activeLayerID = snapshot.renderSnapshot.document.activeLayerID
            let activeBrushDisplayTexture = resolveBrushDisplayTexture(activeLayerID)
            let activeLayerAlphaLockTexture: MTLTexture? = {
                guard
                    let activeLayerSurfaceID,
                    snapshot.renderSnapshot.document.layers.first(where: { $0.id == activeLayerID })?.locksTransparentPixels == true
                else {
                    return nil
                }
                return layerSurfaceStore.texture(for: activeLayerSurfaceID)
            }()
            let hasActivePreview = isTransforming
            let resolvedLinearGradientGeometry =
                activeTool == .linearGradient
                ? linearGradientPreview.flatMap {
                    resolvedLinearGradientPreviewGeometry(
                        preview: $0,
                        canvasSize: canvasSize
                    )
                }
                : nil
            let resolvedSectorGradientGeometry =
                activeTool == .sectorGradient
                ? sectorGradientPreview.flatMap { resolvedSectorGradientPreviewGeometry(preview: $0) }
                : nil
            let hasLinearGradientPreview = resolvedLinearGradientGeometry != nil
            let hasSectorGradientPreview = resolvedSectorGradientGeometry != nil
            let hasGradientPreview = hasLinearGradientPreview || hasSectorGradientPreview

            let activeLayerOpacity = activeLayerSurfaceID.flatMap { surfaceID in
                snapshot.layerSurfaces.first(where: { $0.surfaceID == surfaceID })?.opacity
            } ?? 1
            let currentTransformPlan = currentTransformPreviewPlan()
            let previewEncodeStart = DispatchTime.now().uptimeNanoseconds

            let orderedVisibleLayers = snapshot.layerSurfaces.compactMap { surface -> (LayerSurfaceID, MTLTexture, Float)? in
                let resolvedTexture: MTLTexture?
                if surface.surfaceID == activeLayerSurfaceID, let activeBrushDisplayTexture {
                    resolvedTexture = activeBrushDisplayTexture
                } else {
                    resolvedTexture = layerSurfaceStore.texture(for: surface.surfaceID)
                }

                guard surface.isVisible, let texture = resolvedTexture else {
                    return nil
                }

                if hasActivePreview, surface.surfaceID == activeLayerSurfaceID {
                    switch freeTransformActiveLayerPreviewStrategy(
                        hasActivePreview: hasActivePreview,
                        sessionMode: transformPreviewSession?.mode,
                        hasBaseTexture: transformPreviewSession?.baseTexture != nil,
                        plannedMode: currentTransformPlan?.mode
                    ) {
                    case .showOriginalLayer:
                        return (surface.surfaceID, texture, surface.opacity)
                    case .showBaseTexture:
                        guard let baseTexture = transformPreviewSession?.baseTexture else {
                            return (surface.surfaceID, texture, surface.opacity)
                        }
                        return (surface.surfaceID, baseTexture, surface.opacity)
                    case .hideOriginalLayer:
                        return nil
                    }
                }
                return (surface.surfaceID, texture, surface.opacity)
            }

            if hasGradientPreview, let activeLayerSurfaceID {
                let lowerPrefix = Array(orderedVisibleLayers.prefix { $0.0 != activeLayerSurfaceID })
                let activeLayerEntries = orderedVisibleLayers.filter { $0.0 == activeLayerSurfaceID }
                let lowerLayers = lowerPrefix + activeLayerEntries
                canvasPresenter.encode(
                    layerTextures: lowerLayers.map { ($0.1, $0.2) },
                    into: descriptor,
                    commandBuffer: commandBuffer
                )

                descriptor.colorAttachments[0].loadAction = .load
                descriptor.colorAttachments[0].storeAction = .store
                if let geometry = resolvedLinearGradientGeometry {
                    linearGradientRenderer.encode(
                        into: descriptor,
                        commandBuffer: commandBuffer,
                        canvasSize: canvasSize,
                        pointA: geometry.pointA,
                        pointB: geometry.pointB,
                        pointC: geometry.pointC,
                        color: gradientPreviewColor,
                        paintJitterAmount: gradientPaintJitterAmount,
                        paintContrastAmount: gradientPaintContrastAmount,
                        distortionAmount: gradientDistortionAmount,
                        selectionShape: snapshot.selectionShape,
                        alphaLockTexture: activeLayerAlphaLockTexture
                    )
                } else if let geometry = resolvedSectorGradientGeometry {
                    sectorGradientRenderer.encode(
                        into: descriptor,
                        commandBuffer: commandBuffer,
                        canvasSize: canvasSize,
                        center: geometry.center,
                        pathPoints: geometry.pathPoints,
                        maxRadius: geometry.maxRadius,
                        color: gradientPreviewColor,
                        paintJitterAmount: gradientPaintJitterAmount,
                        paintContrastAmount: gradientPaintContrastAmount,
                        distortionAmount: gradientDistortionAmount,
                        maskQuality: .preview,
                        selectionShape: snapshot.selectionShape,
                        alphaLockTexture: activeLayerAlphaLockTexture
                    )
                }

                let upperLayers = Array(orderedVisibleLayers.drop { $0.0 != activeLayerSurfaceID }.dropFirst())
                if !upperLayers.isEmpty {
                    descriptor.colorAttachments[0].loadAction = .load
                    descriptor.colorAttachments[0].storeAction = .store
                    canvasPresenter.encode(
                        layerTextures: upperLayers.map { ($0.1, $0.2) },
                        into: descriptor,
                        commandBuffer: commandBuffer
                    )
                }
            } else {
                canvasPresenter.encode(
                    layerTextures: orderedVisibleLayers.map { ($0.1, $0.2) },
                    into: descriptor,
                    commandBuffer: commandBuffer
                )
            }

            if hasActivePreview, let surfaceID = activeLayerSurfaceID {
                descriptor.colorAttachments[0].loadAction = .load
                descriptor.colorAttachments[0].storeAction = .store

                if let session = transformPreviewSession {
                    canvasPresenter.encodePreview(
                        texture: session.extractedTexture,
                        opacity: activeLayerOpacity,
                        canvasSize: canvasSize,
                        bounds: session.operationBounds,
                        pivotBounds: session.interactionBounds ?? session.operationBounds,
                        preview: effectivePreview,
                        into: descriptor,
                        commandBuffer: commandBuffer
                    )
                } else if currentTransformPlan?.mode == .wholeLayer,
                          let texture = layerSurfaceStore.texture(for: surfaceID) {
                    let fullBounds = CanvasRect(
                        origin: .init(x: 0, y: 0),
                        size: .init(x: Double(canvasSize.width), y: Double(canvasSize.height))
                    )
                    canvasPresenter.encodePreview(
                        texture: texture,
                        opacity: activeLayerOpacity,
                        canvasSize: canvasSize,
                        bounds: fullBounds,
                        pivotBounds: currentTransformPlan?.interactionBounds ?? fullBounds,
                        preview: effectivePreview,
                        into: descriptor,
                        commandBuffer: commandBuffer
                    )
                }
            }

            if hasActivePreview || hasGradientPreview {
                previewTimingFrameCounter &+= 1
                if previewTimingFrameCounter % 15 == 0 {
                    let previewEncodeDurationMs = Double(DispatchTime.now().uptimeNanoseconds - previewEncodeStart) / 1_000_000
                    if hasGradientPreview {
                        transformLogger.debug("[gradient] previewEncodeMs=\(previewEncodeDurationMs, privacy: .public) sessionTool=\(hasLinearGradientPreview ? "linear" : "sector", privacy: .public)")
                    } else {
                        transformLogger.debug(
                            "[preview] encodeMs=\(previewEncodeDurationMs, privacy: .public) mode=\(String(describing: self.transformPreviewSession?.mode), privacy: .public)"
                        )
                    }
                }
            } else {
                previewTimingFrameCounter = 0
            }
        } else if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) {
            encoder.endEncoding()
        }

        if isLuminosityPreviewEnabled, let labProcessor = labLuminosityPostProcessor {
            let drawableTexture = drawable.texture
            if cachedLuminosityTempTexture == nil
                || cachedLuminosityTempTexture!.width != drawableTexture.width
                || cachedLuminosityTempTexture!.height != drawableTexture.height
                || cachedLuminosityTempTexture!.pixelFormat != drawableTexture.pixelFormat {
                let tempDesc = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: drawableTexture.pixelFormat,
                    width: drawableTexture.width,
                    height: drawableTexture.height,
                    mipmapped: false
                )
                tempDesc.usage = [.shaderRead, .renderTarget]
                tempDesc.storageMode = .private
                cachedLuminosityTempTexture = metalContext.device.makeTexture(descriptor: tempDesc)
            }
            if let tempTexture = cachedLuminosityTempTexture,
               let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
                blitEncoder.copy(from: drawableTexture, to: tempTexture)
                blitEncoder.endEncoding()

                let labPassDescriptor = MTLRenderPassDescriptor()
                labPassDescriptor.colorAttachments[0].texture = drawableTexture
                labPassDescriptor.colorAttachments[0].loadAction = .dontCare
                labPassDescriptor.colorAttachments[0].storeAction = .store
                labProcessor.encode(
                    sourceTexture: tempTexture,
                    into: labPassDescriptor,
                    commandBuffer: commandBuffer
                )
            }
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
        scheduleInteractiveBrushCommitDrain(hadLiveBrushWorkThisFrame: hadLiveBrushWorkThisFrame)
        if let strokeView = view as? StrokeCaptureMTKView, strokeView.isBrushLikeStrokeActive {
            let drawFrameMs = Double(DispatchTime.now().uptimeNanoseconds - drawStartNs) / 1_000_000
            brushFeelLogger.debug("[brush-feel] drawFrameMs=\(drawFrameMs, privacy: .public)")
        }
    }

    private func scheduleInteractiveBrushCommitDrain(hadLiveBrushWorkThisFrame: Bool) {
        guard !hasScheduledInteractiveBrushCommitDrain else {
            return
        }
        hasScheduledInteractiveBrushCommitDrain = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasScheduledInteractiveBrushCommitDrain = false
            self.onDrainPendingBrushCommitsInteractively(hadLiveBrushWorkThisFrame)
        }
    }

    func strokeCaptureViewDidBeginStroke(_ view: StrokeCaptureMTKView) {
        onStrokeBegan()
    }

    func strokeCaptureView(_ view: StrokeCaptureMTKView, didProduce samples: [CanvasStrokeSample]) {
        onStrokeInput(samples)
    }

    func strokeCaptureViewDidEndStroke(_ view: StrokeCaptureMTKView) {
        onStrokeEnded()
    }

    func strokeCaptureView(_ view: StrokeCaptureMTKView, didSampleColorAt point: CanvasPoint) {
        onEyedropperSample(point)
    }

    func strokeCaptureView(_ view: StrokeCaptureMTKView, didRequestBucketFillAt point: CanvasPoint) {
        onBucketFill(point)
    }

    func strokeCaptureView(
        _ view: StrokeCaptureMTKView,
        didClickCanvasAt point: CanvasPoint,
        modifiers: NSEvent.ModifierFlags,
        clickCount: Int
    ) {
        onCanvasClick(point, modifiers, clickCount)
    }

    func strokeCaptureView(_ view: StrokeCaptureMTKView, didHoverCanvasAt point: CanvasPoint) {
        onCanvasHover(point)
    }

    func strokeCaptureView(
        _ view: StrokeCaptureMTKView,
        didBeginGradientDragAt point: CanvasPoint,
        modifiers: NSEvent.ModifierFlags
    ) {
        onGradientDragBegan(point, modifiers)
    }

    func strokeCaptureView(
        _ view: StrokeCaptureMTKView,
        didChangeGradientDragAt point: CanvasPoint,
        modifiers: NSEvent.ModifierFlags
    ) {
        onGradientDragChanged(point, modifiers)
    }

    func strokeCaptureView(
        _ view: StrokeCaptureMTKView,
        didEndGradientDragAt point: CanvasPoint,
        modifiers: NSEvent.ModifierFlags
    ) {
        onGradientDragEnded(point, modifiers)
    }

    func strokeCaptureViewDidRequestEnterGradientEditing(_ view: StrokeCaptureMTKView) {
        onEnterGradientEditing()
    }

    func strokeCaptureView(_ view: StrokeCaptureMTKView, didBeginSelectionAt point: CanvasPoint, modifiers: NSEvent.ModifierFlags) {
        let message = "[coordinator.didBeginSelectionAt] point=(\(point.x),\(point.y)) modifiers=\(modifiers.rawValue)"
        selectionTraceLogger.debug("\(message, privacy: .public)")
        emitSelectionTraceHost(message)
        onSelectionBegan(point, modifiers)
    }

    func strokeCaptureView(_ view: StrokeCaptureMTKView, didChangeSelectionAt point: CanvasPoint, modifiers: NSEvent.ModifierFlags) {
        let message = "[coordinator.didChangeSelectionAt] point=(\(point.x),\(point.y)) modifiers=\(modifiers.rawValue)"
        selectionTraceLogger.debug("\(message, privacy: .public)")
        emitSelectionTraceHost(message)
        onSelectionChanged(point, modifiers)
    }

    func strokeCaptureView(_ view: StrokeCaptureMTKView, didEndSelectionAt point: CanvasPoint, modifiers: NSEvent.ModifierFlags) {
        let message = "[coordinator.didEndSelectionAt] point=(\(point.x),\(point.y)) modifiers=\(modifiers.rawValue)"
        selectionTraceLogger.debug("\(message, privacy: .public)")
        emitSelectionTraceHost(message)
        onSelectionEnded(point, modifiers)
    }

    func strokeCaptureView(_ view: StrokeCaptureMTKView, selectionToolMouseDownAt point: CanvasPoint, modifiers: NSEvent.ModifierFlags) -> SelectionMouseDownAction {
        let message = "[coordinator.selectionMouseDown] point=(\(point.x),\(point.y)) modifiers=\(modifiers.rawValue)"
        selectionTraceLogger.debug("\(message, privacy: .public)")
        emitSelectionTraceHost(message)
        return onSelectionMouseDown(point, modifiers)
    }

    func strokeCaptureView(_ view: StrokeCaptureMTKView, didPanBy deltaX: Double, deltaY: Double) {}

    func strokeCaptureView(_ view: StrokeCaptureMTKView, didMoveSelectionPreviewBy deltaX: Double, deltaY: Double) {
        onMoveSelectionPreview(deltaX, deltaY)
    }

    func strokeCaptureViewDidCommitSelectionMove(_ view: StrokeCaptureMTKView) {
        onCommitSelectionMove()
    }

    func strokeCaptureView(
        _ view: StrokeCaptureMTKView,
        didBeginTransformAt point: CanvasPoint,
        mode: FreeTransformInteractionMode,
        modifiers: NSEvent.ModifierFlags
    ) {
        if mode == .move {
            isLiveTransformDragging = true
            liveTransformMode = mode
            liveTransformDragStartPoint = point
            liveTransformStartPreview = transformPreview
            liveTransformPreview = transformPreview
            liveMoveLogCount = 0
            transformLogger.debug("[transform] liveMoveUsesCoordinatorPreview=true")
        } else {
            clearLiveTransformState()
        }
        onTransformBegan(point, mode, modifiers)
    }

    func strokeCaptureView(
        _ view: StrokeCaptureMTKView,
        didChangeTransformAt point: CanvasPoint,
        modifiers: NSEvent.ModifierFlags
    ) {
        if isLiveTransformDragging,
           liveTransformMode == .move,
           let dragStart = liveTransformDragStartPoint {
            let nextPreview = freeTransformTranslatedPreview(
                dragStartPoint: dragStart,
                currentPoint: point,
                startPreview: liveTransformStartPreview
            )
            liveTransformPreview = nextPreview
            if liveMoveLogCount < 10 {
                transformLogger.debug(
                    "[transform] moveTranslation x=\(nextPreview.translation.x, privacy: .public) y=\(nextPreview.translation.y, privacy: .public)"
                )
                liveMoveLogCount += 1
            }
            view.setNeedsDisplay(view.bounds)
            return
        }
        onTransformChanged(point, modifiers)
    }

    func strokeCaptureView(
        _ view: StrokeCaptureMTKView,
        didEndTransformAt point: CanvasPoint,
        modifiers: NSEvent.ModifierFlags
    ) {
        if isLiveTransformDragging, liveTransformMode == .move {
            onTransformChanged(point, modifiers)
            clearLiveTransformState()
            view.setNeedsDisplay(view.bounds)
        }
        onTransformEnded(point, modifiers)
    }

    func strokeCaptureView(_ view: StrokeCaptureMTKView, didRotateCanvasTo angleDegrees: Double) {
        onCanvasRotationChanged(angleDegrees)
    }

    func strokeCaptureView(_ view: StrokeCaptureMTKView, didChangePanMode isActive: Bool) {
        onPanModeChanged(isActive)
    }

    func strokeCaptureView(_ view: StrokeCaptureMTKView, didRequestToolShortcutKey key: String, modifiers: NSEvent.ModifierFlags) {
        onToolShortcut(key, modifiers)
    }

    func strokeCaptureViewDidRequestCanvasToolCancel(_ view: StrokeCaptureMTKView) {
        onCancelCanvasTool()
    }

    func strokeCaptureViewDidRequestApplyGradientSession(_ view: StrokeCaptureMTKView) {
        onApplyGradientSession()
    }

    func strokeCaptureViewDidRequestClearSelection(_ view: StrokeCaptureMTKView) {
        onClearSelection()
    }

    func strokeCaptureViewDidRequestApplyTransform(_ view: StrokeCaptureMTKView) {
        onApplyTransform()
    }

    func strokeCaptureViewDidRequestCancelTransform(_ view: StrokeCaptureMTKView) {
        freeTransformDragOffset = .init(x: 0, y: 0)
        freeTransformDragBase = .init(x: 0, y: 0)
        clearLiveTransformState()
        onCancelTransform()
    }

    func strokeCaptureViewDidSyncTransformOffset(_ view: StrokeCaptureMTKView) {
        // freeTransform 已改为由 ViewModel 维护完整仿射状态，这里不再回灌旧的 offset-only 值。
    }

    func strokeCaptureView(_ view: StrokeCaptureMTKView, didRequestBrushSizeAdjustment delta: Float) {
        onAdjustBrushSize(delta)
    }
}

@MainActor
extension MetalCanvasCoordinator: TransformPreviewDelegate {
    func freeTransformInteractionMode(for point: CanvasPoint, in view: StrokeCaptureMTKView) -> FreeTransformInteractionMode {
        let handleCanvasRadius = max(Double(14) * Double(view.canvasSize.width) / max(view.bounds.width, 1), 12)
        let selectionBounds = sceneSnapshot?.selectionShape?.bounds
        if currentPreparedTransformSignature()?.mode == .wholeLayer {
            let canScaleRotate = selectionBounds != nil
            if lastLoggedWholeLayerCanScaleRotate != canScaleRotate {
                lastLoggedWholeLayerCanScaleRotate = canScaleRotate
                transformLogger.debug("[transform] wholeLayerCanScaleRotate=\(canScaleRotate, privacy: .public)")
            }
            let usesInteractionBounds = selectionBounds != nil
            if lastLoggedWholeLayerUsesInteractionBoundsForHitTesting != usesInteractionBounds {
                lastLoggedWholeLayerUsesInteractionBoundsForHitTesting = usesInteractionBounds
                transformLogger.debug(
                    "[transform] wholeLayerUsesInteractionBoundsForHitTesting=\(usesInteractionBounds, privacy: .public)"
                )
            }
        }

        return ArtFlex.freeTransformInteractionMode(
            point: point,
            bounds: selectionBounds,
            preview: transformPreview,
            handleRadius: handleCanvasRadius,
            rotationHandleDistance: handleCanvasRadius * 3.4
        )
    }

    func strokeCaptureView(_ view: StrokeCaptureMTKView, shouldBeginTransformAt point: CanvasPoint) -> Bool {
        if transformPreviewSession != nil {
            transformPreviewStartPoint = point
            transformLogger.debug("[transform] dragStartUsesPreparedSession=true")
            return true
        }

        if let prepared = preparedTransformSession,
           preparedTransformSignature == currentPreparedTransformSignature() {
            transformPreviewSession = prepared
            transformPreviewStartPoint = point
            transformLogger.debug("[transform] dragStartUsesPreparedSession=true")
            return true
        }

        let signature = currentPreparedTransformSignature()
        if preparedTransformSignature != signature {
            preparedTransformSession = nil
            preparedTransformSignature = nil
        }
        if freeTransformCanStartImmediately(
            signature: signature,
            hasPreparedSession: preparedTransformSession != nil
        ) {
            transformPreviewStartPoint = point
            transformLogger.debug("[transform] dragStartUsesPreparedSession=false")
            return true
        }
        updatePreparedTransformSessionIfNeeded()
        transformLogger.debug("[transform] dragStartUsesPreparedSession=false")
        return false
    }

    func strokeCaptureView(_ view: StrokeCaptureMTKView, didUpdateTransformPreviewTo point: CanvasPoint) {
        guard transformPreviewStartPoint != nil else { return }
        if transformPreviewSession == nil, let prepared = preparedTransformSession {
            transformPreviewSession = prepared
        }
    }

    func strokeCaptureViewDidCancelTransformPreview(_ view: StrokeCaptureMTKView) {
        transformPreviewStartPoint = nil
        view.setNeedsDisplay(view.bounds)
    }

    func strokeCaptureViewSetFallbackStartPoint(_ view: StrokeCaptureMTKView, point: CanvasPoint) {
        transformPreviewStartPoint = point
    }

    func updatePreparedTransformSessionIfNeeded() {
        if !isTransformingSelection {
            transformPreviewSession = nil
            transformPreviewStartPoint = nil
            transformPreviewDragBaseOffset = .init(x: 0, y: 0)
        }

        guard activeTool == .freeTransform else {
            transformPreviewSession = nil
            transformPreviewStartPoint = nil
            transformPreviewDragBaseOffset = .init(x: 0, y: 0)
            preparedTransformSession = nil
            preparedTransformSignature = nil
            isPrepBuildingSession = false
            didLogNoRebuildDuringActiveMove = false
            lastIdlePreparedAvailability = nil
            return
        }

        if freeTransformShouldSkipSessionRebuild(
            isTransformingSelection: isTransformingSelection,
            isFreeTransformDragging: isFreeTransformDragging,
            activeInteractionMode: activeFreeTransformInteractionMode
        ) {
            if !didLogNoRebuildDuringActiveMove {
                transformLogger.debug("[transform] rebuiltSessionDuringActiveMove=false")
                didLogNoRebuildDuringActiveMove = true
            }
            return
        }
        didLogNoRebuildDuringActiveMove = false

        guard
            let snapshot = sceneSnapshot,
            let activeLayerSurfaceID = snapshot.activeLayerSurfaceID,
            let sourceTexture = layerSurfaceStore.texture(for: activeLayerSurfaceID)
        else {
            transformPreviewSession = nil
            preparedTransformSession = nil
            preparedTransformSignature = nil
            isPrepBuildingSession = false
            logIdlePreparedAvailability(false)
            return
        }

        guard let signature = currentPreparedTransformSignature() else {
            transformPreviewSession = nil
            preparedTransformSession = nil
            preparedTransformSignature = nil
            isPrepBuildingSession = false
            logIdlePreparedAvailability(false)
            return
        }

        if transformPreviewSession?.preparedSignature != signature {
            transformPreviewSession = nil
        }

        if transformPreviewSession?.preparedSignature == signature {
            preparedTransformSession = transformPreviewSession
            preparedTransformSignature = signature
            logIdlePreparedAvailability(true)
            return
        }
        if preparedTransformSignature == signature, preparedTransformSession != nil {
            logIdlePreparedAvailability(true)
            return
        }
        if isPrepBuildingSession { return }

        isPrepBuildingSession = true
        let selectionShape = transformSelectionShape
        let canvasSize = snapshot.renderSnapshot.document.canvasSize
        let buildStart = DispatchTime.now().uptimeNanoseconds

        transformPreviewBuilder.makeSession(
            activeLayerSurfaceID: activeLayerSurfaceID,
            sourceTexture: sourceTexture,
            canvasSize: canvasSize,
            selectionShape: selectionShape,
            interactionBounds: snapshot.selectionShape?.bounds,
            selectionRevision: snapshot.selectionRevision,
            canvasContentRevision: snapshot.renderSnapshot.canvasContentRevision,
            metal: metalContext
        ) { [weak self] session in
            guard let self else { return }
            let buildDurationMs = Double(DispatchTime.now().uptimeNanoseconds - buildStart) / 1_000_000
            self.transformLogger.debug(
                "[session] buildMs=\(buildDurationMs, privacy: .public) success=\(session != nil, privacy: .public)"
            )
            guard self.activeTool == .freeTransform else {
                self.isPrepBuildingSession = false
                self.logIdlePreparedAvailability(self.preparedTransformSession != nil)
                return
            }
            self.isPrepBuildingSession = false
            let latestSignature = self.currentPreparedTransformSignature()
            guard session?.preparedSignature == latestSignature || session == nil else {
                self.logIdlePreparedAvailability(self.preparedTransformSession != nil)
                return
            }
            self.preparedTransformSession = session
            self.preparedTransformSignature = session?.preparedSignature
            if self.isTransformingSelection, self.transformPreviewSession == nil {
                self.transformPreviewSession = session
            }
            self.logIdlePreparedAvailability(session != nil)
        }
    }

    private func currentPreparedTransformSignature() -> TransformPreviewPreparedSignature? {
        guard
            let snapshot = sceneSnapshot,
            let activeLayerSurfaceID = snapshot.activeLayerSurfaceID,
            let plan = currentTransformPreviewPlan()
        else {
            return nil
        }

        return TransformPreviewPreparedSignature(
            activeLayerSurfaceID: activeLayerSurfaceID,
            mode: plan.mode,
            canvasContentRevision: snapshot.renderSnapshot.canvasContentRevision,
            selectionRevision: snapshot.selectionRevision,
            operationBounds: plan.operationBounds
        )
    }

    private func currentTransformPreviewPlan() -> TransformPreviewPlan? {
        guard let snapshot = sceneSnapshot else {
            return nil
        }
        return TransformPreviewSessionBuilder.plan(
            canvasSize: snapshot.renderSnapshot.document.canvasSize,
            selectionShape: transformSelectionShape,
            interactionBounds: snapshot.selectionShape?.bounds
        )
    }

    private func clearLiveTransformState() {
        isLiveTransformDragging = false
        liveTransformMode = nil
        liveTransformDragStartPoint = nil
        liveTransformStartPreview = .identity
        liveTransformPreview = nil
        liveMoveLogCount = 0
    }

    private func logIdlePreparedAvailability(_ available: Bool) {
        guard !isTransformingSelection else { return }
        guard lastIdlePreparedAvailability != available else { return }
        lastIdlePreparedAvailability = available
        transformLogger.debug("[transform] idlePreparedAvailable=\(available, privacy: .public)")
    }

}

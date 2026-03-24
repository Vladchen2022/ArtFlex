import MetalKit
import SwiftUI
import os
@preconcurrency import Metal

private func emitSelectionTraceHost(_ message: String) {
    appendSelectionTrace(message)
}

struct MetalCanvasHost: NSViewRepresentable {
    let sceneSnapshot: CanvasSceneSnapshot
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
    let onStrokeBegan: () -> Void
    let onStrokeInput: ([CanvasStrokeSample]) -> Void
    let onStrokeEnded: () -> Void
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
    let onGradientDragBegan: (CanvasPoint, NSEvent.ModifierFlags) -> Void
    let onGradientDragChanged: (CanvasPoint, NSEvent.ModifierFlags) -> Void
    let onGradientDragEnded: (CanvasPoint, NSEvent.ModifierFlags) -> Void
    let onCancelCanvasTool: () -> Void
    let onApplyGradientSession: () -> Void
    let onClearSelection: () -> Void
    let onApplyTransform: () -> Void
    let onCancelTransform: () -> Void
    let onAdjustBrushSize: (Float) -> Void

    func makeCoordinator() -> MetalCanvasCoordinator {
        MetalCanvasCoordinator(
            metalContext: metalContext,
            layerSurfaceStore: layerSurfaceStore,
            activeTool: activeTool,
            transformSelectionShape: transformSelectionShape,
            transformPreview: transformPreview,
            linearGradientPreview: linearGradientPreview,
            sectorGradientPreview: sectorGradientPreview,
            gradientPreviewColor: gradientPreviewColor,
            onCanvasRotationChanged: onCanvasRotationChanged,
            onStrokeBegan: onStrokeBegan,
            onStrokeInput: onStrokeInput,
            onStrokeEnded: onStrokeEnded,
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
        let wasTransforming = context.coordinator.isTransformingSelection
        let previousSnapshot = context.coordinator.sceneSnapshot
        let previousActiveTool = context.coordinator.activeTool
        let previousIsTransforming = context.coordinator.isTransformingSelection
        let previousTransformPreview = context.coordinator.transformPreview
        context.coordinator.sceneSnapshot = sceneSnapshot
        context.coordinator.transformSelectionShape = transformSelectionShape
        context.coordinator.activeTool = activeTool
        context.coordinator.isTransformingSelection = isTransformingSelection
        context.coordinator.isFreeTransformDragging = isFreeTransformDragging
        context.coordinator.activeFreeTransformInteractionMode = activeFreeTransformInteractionMode
        context.coordinator.transformPreview = transformPreview
        context.coordinator.linearGradientPreview = linearGradientPreview
        context.coordinator.sectorGradientPreview = sectorGradientPreview
        context.coordinator.gradientPreviewColor = gradientPreviewColor
        context.coordinator.updatePreparedTransformSessionIfNeeded()
        if let view = nsView as? StrokeCaptureMTKView {
            let previousCanvasSize = view.canvasSize
            let previousViewportRotation = view.viewportRotationDegrees
            let previousPanMode = view.isPanModeActive
            let previousStrokeResetToken = view.strokeResetToken
            let previousBrushSize = view.brushSize

            view.canvasSize = sceneSnapshot.renderSnapshot.document.canvasSize
            view.activeTool = activeTool
            view.viewportRotationDegrees = viewportRotationDegrees
            view.isPanModeActive = isPanModeActive
            if view.strokeResetToken != strokeResetToken {
                view.strokeResetToken = strokeResetToken
                view.resetInteractionState()
            }
            view.brushSize = brushSize
            view.transformPreviewDelegate = context.coordinator

            if wasTransforming && !isTransformingSelection {
                view.isPaused = true
                view.enableSetNeedsDisplay = true
            }

            let previousCanvasContentRevision = previousSnapshot?.renderSnapshot.canvasContentRevision
            let previousViewportRevision = previousSnapshot?.renderSnapshot.viewportRevision
            let previousSelectionRevision = previousSnapshot?.selectionRevision
            let previousSelectionShape = previousSnapshot?.selectionShape
            let previousLinearGradientPreview = context.coordinator.previousLinearGradientPreview
            let previousSectorGradientPreview = context.coordinator.previousSectorGradientPreview
            let previousGradientPreviewColor = context.coordinator.previousGradientPreviewColor

            let requiresCanvasRedraw =
                previousCanvasContentRevision != sceneSnapshot.renderSnapshot.canvasContentRevision ||
                previousViewportRevision != sceneSnapshot.renderSnapshot.viewportRevision ||
                previousSelectionRevision != sceneSnapshot.selectionRevision ||
                previousSelectionShape?.kind != sceneSnapshot.selectionShape?.kind ||
                previousSelectionShape?.bounds != sceneSnapshot.selectionShape?.bounds ||
                previousActiveTool != activeTool ||
                previousIsTransforming != isTransformingSelection ||
                previousTransformPreview != transformPreview ||
                previousLinearGradientPreview != linearGradientPreview ||
                previousSectorGradientPreview != sectorGradientPreview ||
                previousGradientPreviewColor != gradientPreviewColor ||
                previousCanvasSize != view.canvasSize ||
                previousViewportRotation != viewportRotationDegrees ||
                previousPanMode != isPanModeActive ||
                previousStrokeResetToken != strokeResetToken

            context.coordinator.previousLinearGradientPreview = linearGradientPreview
            context.coordinator.previousSectorGradientPreview = sectorGradientPreview
            context.coordinator.previousGradientPreviewColor = gradientPreviewColor

            let brushSizeOnlyChanged = previousBrushSize != brushSize && !requiresCanvasRedraw
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
    func strokeCaptureViewDidRequestCanvasToolCancel(_ view: StrokeCaptureMTKView)
    func strokeCaptureViewDidRequestApplyGradientSession(_ view: StrokeCaptureMTKView)
    func strokeCaptureViewDidRequestClearSelection(_ view: StrokeCaptureMTKView)
    func strokeCaptureViewDidRequestApplyTransform(_ view: StrokeCaptureMTKView)
    func strokeCaptureViewDidRequestCancelTransform(_ view: StrokeCaptureMTKView)
    func strokeCaptureViewDidSyncTransformOffset(_ view: StrokeCaptureMTKView)
    func strokeCaptureView(_ view: StrokeCaptureMTKView, didRequestBrushSizeAdjustment delta: Float)
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
    var canvasSize: CanvasSize = .stageOneDefault
    var activeTool: ToolKind = .brush {
        didSet { updateCursorAppearance() }
    }
    var viewportRotationDegrees: Double = 0
    var isPanModeActive = false
    var strokeResetToken = 0
    var brushSize: Float = 24 {
        didSet { updateCursorIndicator() }
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
    private var previousMouseCoalescingEnabled: Bool?
    private var brushDebugRecords: [BrushInputDebugRecord] = []
    private let minimumTabletPressure: Float = 0.02
    private var trackingAreaRef: NSTrackingArea?
    private let cursorIndicatorLayer = CAShapeLayer()
    private var hoverLocation: CGPoint?
    private var activeModifierFlags: NSEvent.ModifierFlags = []
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
    private let debugDisableMouseCoalescingDuringStroke = true
    private let debugForceConstantPressure = false
    private let debugBypassStartupPressureSmoothing = false
    private let debugLogFirstRawSamples = true

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if cursorIndicatorLayer.superlayer == nil {
            cursorIndicatorLayer.fillColor = NSColor.clear.cgColor
            cursorIndicatorLayer.strokeColor = NSColor.black.withAlphaComponent(0.28).cgColor
            cursorIndicatorLayer.lineWidth = 1
            layer?.addSublayer(cursorIndicatorLayer)
        }
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
        activeModifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        window?.makeFirstResponder(self)
        hoverLocation = convert(event.locationInWindow, from: nil)
        updateCursorIndicator()
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
            strokeDelegate?.strokeCaptureView(
                self,
                didBeginGradientDragAt: sample(from: event).location,
                modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            )
            beginContinuousStrokeRendering()
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

        strokeDelegate?.strokeCaptureViewDidBeginStroke(self)
        beginContinuousStrokeRendering()
        beginBrushStrokeDiagnostics()
        strokePacketIndex = 0
        strokeInputSampleCount = 0
        let rawSample = sample(from: event)
        smoothedPosition = nil                    // 新しい筆触：スムージング状態リセット
        let s = smoothed(rawSample)
        lastSample = s
        strokeDelegate?.strokeCaptureView(self, didProduce: [s])
        strokePacketIndex += 1
        setNeedsDisplay(bounds)
    }

    override func mouseDragged(with event: NSEvent) {
        activeModifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        hoverLocation = convert(event.locationInWindow, from: nil)
        updateCursorIndicator()
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

        let samples = brushSamples(from: event).map(smoothed)
        emitCoalescedStrokeSamples(samples)
        lastSample = samples.last
        if !samples.isEmpty {
            strokePacketIndex += 1
        }
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
            strokeDelegate?.strokeCaptureView(
                self,
                didEndGradientDragAt: sample(from: event).location,
                modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            )
            endContinuousStrokeRendering()
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
        strokeDelegate?.strokeCaptureViewDidEndStroke(self)
        endContinuousStrokeRendering()
        endBrushStrokeDiagnostics()
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
            (activeTool == .linearGradient || activeTool == .sectorGradient) {
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
            strokeDelegate?.strokeCaptureView(self, didRequestBrushSizeAdjustment: -1)
            return
        }

        if event.charactersIgnoringModifiers == "]" {
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

        super.keyDown(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        activeModifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        hoverLocation = convert(event.locationInWindow, from: nil)
        updateCursorIndicator()
        updateCursorAppearance()
        if activeTool == .straightLine || activeTool == .polygonSelection {
            strokeDelegate?.strokeCaptureView(self, didHoverCanvasAt: sample(from: event).location)
            setNeedsDisplay(bounds)
        }
    }

    override func tabletPoint(with event: NSEvent) {
        activeModifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        hoverLocation = convert(event.locationInWindow, from: nil)
        updateCursorIndicator()
        updateCursorAppearance()
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
        if handleAuxiliaryBrushInputEvent(event, source: "pressureChange") {
            return
        }
        super.pressureChange(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        activeModifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        hoverLocation = convert(event.locationInWindow, from: nil)
        updateCursorIndicator()
        updateCursorAppearance()
    }

    override func mouseExited(with event: NSEvent) {
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

        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        activeModifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        updateCursorAppearance()
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
        super.flagsChanged(with: event)
    }

    private func sample(from event: NSEvent) -> CanvasStrokeSample {
        let location = convert(event.locationInWindow, from: nil)
        let normalizedX = max(min(location.x / bounds.width, 1), 0)
        let normalizedY = max(min(location.y / bounds.height, 1), 0)
        let rawPressure = Float(event.pressure)
        let normalizedPressure: Float
        if rawPressure > 0 {
            let clamped = min(max(rawPressure, 0), 1)
            let shouldBypassPressureWarmup =
                debugBypassStartupPressureSmoothing &&
                isTabletLikeEvent(event) &&
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
        } else if event.subtype == .tabletPoint {
            normalizedPressure = lastPressure ?? minimumTabletPressure
        } else {
            normalizedPressure = 1
        }
        let effectivePressure: Float = debugForceConstantPressure ? 1 : normalizedPressure
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
        activeTool == .brush || activeTool == .eraser || activeTool == .smudge
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

    private func brushSamples(from event: NSEvent) -> [CanvasStrokeSample] {
        guard activeTool == .brush || activeTool == .eraser || activeTool == .smudge else {
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
        strokeDelegate?.strokeCaptureView(self, didProduce: filtered)
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
        enableSetNeedsDisplay = false
        isPaused = false
    }

    private func endContinuousStrokeRendering() {
        isPaused = true
        enableSetNeedsDisplay = true
        setNeedsDisplay(bounds)
    }

    func resetInteractionState() {
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
        activeFreeTransformDragPoint = nil
        activeFreeTransformDragMode = nil
        isPaused = true
        enableSetNeedsDisplay = true
        setNeedsDisplay(bounds)
        updateCursorAppearance()
    }

    private func updateCursorIndicator() {
        guard let hoverLocation, shouldShowCursorIndicator else {
            cursorIndicatorLayer.isHidden = true
            return
        }

        let diameter = max(CGFloat(brushSize) * (bounds.width / CGFloat(max(canvasSize.width, 1))), 2)
        cursorIndicatorLayer.isHidden = false
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

    private var shouldShowCursorIndicator: Bool {
        activeTool == .brush || activeTool == .eraser || activeTool == .smudge
    }

    private var isEyedropperCursorActive: Bool {
        activeTool == .eyedropper || (allowsTemporaryEyedropperOverride && activeModifierFlags.contains(.option))
    }

    private var allowsTemporaryEyedropperOverride: Bool {
        switch activeTool {
        case .brush, .eraser, .smudge, .straightLine, .linearGradient, .sectorGradient:
            return true
        case .eyedropper, .bucket, .polygonSelection, .lassoFill, .rectangleSelection, .ellipseSelection, .lassoSelection, .canvasRotate, .freeTransform:
            return false
        }
    }

    private func updateCursorAppearance() {
        guard hoverLocation != nil else { return }
        if isEyedropperCursorActive {
            Self.eyedropperCursor.set()
        } else {
            NSCursor.arrow.set()
        }
    }

}

@MainActor
final class MetalCanvasCoordinator: NSObject, MTKViewDelegate, StrokeCaptureDelegate {
    private let metalContext: MetalDeviceContext
    private let layerSurfaceStore: StageOneLayerSurfaceStore
    private let canvasPresenter: StageOneCanvasPresenter
    private let transformPreviewBuilder: TransformPreviewSessionBuilder
    private let linearGradientRenderer: LinearGradientRenderer
    private let sectorGradientRenderer: SectorGradientRenderer
    var activeTool: ToolKind
    var transformSelectionShape: SelectionShape?
    private let onStrokeBegan: () -> Void
    private let onStrokeInput: ([CanvasStrokeSample]) -> Void
    private let onStrokeEnded: () -> Void
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
    private let onCancelCanvasTool: () -> Void
    private let onApplyGradientSession: () -> Void
    private let onClearSelection: () -> Void
    private let onApplyTransform: () -> Void
    private let onCancelTransform: () -> Void
    private let onAdjustBrushSize: (Float) -> Void

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
    var previousLinearGradientPreview: LinearGradientPreview?
    var previousSectorGradientPreview: SectorGradientPreview?
    var previousGradientPreviewColor: RGBAColor = .black
    var transformPreview = FreeTransformPreview.identity
    private let selectionTraceLogger = Logger(subsystem: "ArtFlex", category: "SelectionTrace")
    private let transformLogger = Logger(subsystem: "ArtFlex", category: "Transform")
    private var previewTimingFrameCounter = 0
    private var didLogNoRebuildDuringActiveMove = false
    private var lastIdlePreparedAvailability: Bool?
    private var lastLoggedWholeLayerCanScaleRotate: Bool?
    private var lastLoggedWholeLayerUsesInteractionBoundsForHitTesting: Bool?
    private var liveMoveLogCount = 0

    init(
        metalContext: MetalDeviceContext,
        layerSurfaceStore: StageOneLayerSurfaceStore,
        activeTool: ToolKind,
        transformSelectionShape: SelectionShape?,
        transformPreview: FreeTransformPreview,
        linearGradientPreview: LinearGradientPreview?,
        sectorGradientPreview: SectorGradientPreview?,
        gradientPreviewColor: RGBAColor,
        onCanvasRotationChanged: @escaping (Double) -> Void,
        onStrokeBegan: @escaping () -> Void,
        onStrokeInput: @escaping ([CanvasStrokeSample]) -> Void,
        onStrokeEnded: @escaping () -> Void,
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
        onCancelCanvasTool: @escaping () -> Void,
        onApplyGradientSession: @escaping () -> Void,
        onClearSelection: @escaping () -> Void,
        onApplyTransform: @escaping () -> Void,
        onCancelTransform: @escaping () -> Void,
        onAdjustBrushSize: @escaping (Float) -> Void
    ) {
        self.metalContext = metalContext
        self.layerSurfaceStore = layerSurfaceStore
        self.canvasPresenter = StageOneCanvasPresenter(device: metalContext.device)
        self.transformPreviewBuilder = TransformPreviewSessionBuilder(device: metalContext.device)
        self.linearGradientRenderer = LinearGradientRenderer(device: metalContext.device)
        self.sectorGradientRenderer = SectorGradientRenderer(device: metalContext.device)
        self.activeTool = activeTool
        self.transformSelectionShape = transformSelectionShape
        self.transformPreview = transformPreview
        self.linearGradientPreview = linearGradientPreview
        self.sectorGradientPreview = sectorGradientPreview
        self.gradientPreviewColor = gradientPreviewColor
        self.previousLinearGradientPreview = linearGradientPreview
        self.previousSectorGradientPreview = sectorGradientPreview
        self.previousGradientPreviewColor = gradientPreviewColor
        self.onCanvasRotationChanged = onCanvasRotationChanged
        self.onStrokeBegan = onStrokeBegan
        self.onStrokeInput = onStrokeInput
        self.onStrokeEnded = onStrokeEnded
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
        guard
            let drawable = view.currentDrawable,
            let descriptor = view.currentRenderPassDescriptor,
            let commandBuffer = metalContext.commandQueue.makeCommandBuffer()
        else {
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
            let hasActivePreview = isTransforming
            let hasLinearGradientPreview = activeTool == .linearGradient && linearGradientPreview?.geometry != nil
            let hasSectorGradientPreview = activeTool == .sectorGradient && sectorGradientPreview?.geometry != nil
            let hasGradientPreview = hasLinearGradientPreview || hasSectorGradientPreview

            let activeLayerOpacity = activeLayerSurfaceID.flatMap { surfaceID in
                snapshot.layerSurfaces.first(where: { $0.surfaceID == surfaceID })?.opacity
            } ?? 1
            let previewEncodeStart = DispatchTime.now().uptimeNanoseconds

            let orderedVisibleLayers = snapshot.layerSurfaces.compactMap { surface -> (LayerSurfaceID, MTLTexture, Float)? in
                guard surface.isVisible, let texture = layerSurfaceStore.texture(for: surface.surfaceID) else {
                    return nil
                }

                if hasActivePreview, surface.surfaceID == activeLayerSurfaceID {
                    if let session = transformPreviewSession {
                        if session.mode == .selection, let baseTexture = session.baseTexture {
                            return (surface.surfaceID, baseTexture, surface.opacity)
                        }
                        return nil
                    }
                    return (surface.surfaceID, texture, surface.opacity)
                }
                return (surface.surfaceID, texture, surface.opacity)
            }

            if hasGradientPreview, let activeLayerSurfaceID {
                let lowerLayers = Array(orderedVisibleLayers.prefix { $0.0 != activeLayerSurfaceID }) +
                    orderedVisibleLayers.filter { $0.0 == activeLayerSurfaceID }
                canvasPresenter.encode(
                    layerTextures: lowerLayers.map { ($0.1, $0.2) },
                    into: descriptor,
                    commandBuffer: commandBuffer
                )

                descriptor.colorAttachments[0].loadAction = .load
                descriptor.colorAttachments[0].storeAction = .store
                if hasLinearGradientPreview, let geometry = linearGradientPreview?.geometry {
                    linearGradientRenderer.encode(
                        into: descriptor,
                        commandBuffer: commandBuffer,
                        canvasSize: canvasSize,
                        pointA: geometry.pointA,
                        pointB: geometry.pointB,
                        pointC: geometry.pointC,
                        color: gradientPreviewColor
                    )
                } else if hasSectorGradientPreview, let geometry = sectorGradientPreview?.geometry {
                    sectorGradientRenderer.encode(
                        into: descriptor,
                        commandBuffer: commandBuffer,
                        canvasSize: canvasSize,
                        center: geometry.center,
                        radius: geometry.radius,
                        startAngle: geometry.startAngle,
                        sweepAngle: geometry.sweepAngle,
                        isFullCircle: geometry.isFullCircle,
                        color: gradientPreviewColor
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
                        preview: effectivePreview,
                        into: descriptor,
                        commandBuffer: commandBuffer
                    )
                } else if currentPreparedTransformSignature()?.mode == .wholeLayer,
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

        commandBuffer.present(drawable)
        commandBuffer.commit()
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
            let plan = TransformPreviewSessionBuilder.plan(
                canvasSize: snapshot.renderSnapshot.document.canvasSize,
                selectionShape: transformSelectionShape,
                interactionBounds: snapshot.selectionShape?.bounds
            )
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

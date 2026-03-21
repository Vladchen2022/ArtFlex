import MetalKit
import SwiftUI
import os
@preconcurrency import Metal

private func emitSelectionTraceHost(_ message: String) {
    appendSelectionTrace(message)
}

struct MetalCanvasHost: NSViewRepresentable {
    let sceneSnapshot: CanvasSceneSnapshot
    let metalContext: MetalDeviceContext
    let layerSurfaceStore: StageOneLayerSurfaceStore
    let activeTool: ToolKind
    let viewportRotationDegrees: Double
    let strokeResetToken: Int
    let brushSize: Float
    let isPanModeActive: Bool
    let isTransformingSelection: Bool
    let transformPreview: FreeTransformPreview
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
    let onTransformBegan: (CanvasPoint, FreeTransformInteractionMode) -> Void
    let onTransformChanged: (CanvasPoint) -> Void
    let onTransformEnded: (CanvasPoint) -> Void
    let onTransformOffsetChanged: (CanvasPoint) -> Void
    let onCanvasRotationChanged: (Double) -> Void
    let onPanModeChanged: (Bool) -> Void
    let onToolShortcut: (String, NSEvent.ModifierFlags) -> Void
    let onCancelCanvasTool: () -> Void
    let onClearSelection: () -> Void
    let onApplyTransform: () -> Void
    let onCancelTransform: () -> Void
    let onAdjustBrushSize: (Float) -> Void

    func makeCoordinator() -> MetalCanvasCoordinator {
        MetalCanvasCoordinator(
            metalContext: metalContext,
            layerSurfaceStore: layerSurfaceStore,
            activeTool: activeTool,
            transformPreview: transformPreview,
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
            onCancelCanvasTool: onCancelCanvasTool,
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
        context.coordinator.sceneSnapshot = sceneSnapshot
        context.coordinator.activeTool = activeTool
        context.coordinator.isTransformingSelection = isTransformingSelection
        context.coordinator.transformPreview = transformPreview
        context.coordinator.updatePreparedTransformSessionIfNeeded()
        if let view = nsView as? StrokeCaptureMTKView {
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

            // freeTransform 종료 시 연속 렌더링 중지
            if wasTransforming && !isTransformingSelection {
                view.isPaused = true
                view.enableSetNeedsDisplay = true
            }
            // freeTransform 시작 시 연속 렌더링 시작
            if !wasTransforming && isTransformingSelection && activeTool == .freeTransform {
                view.enableSetNeedsDisplay = false
                view.isPaused = false
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
    func strokeCaptureView(_ view: StrokeCaptureMTKView, didBeginTransformAt point: CanvasPoint, mode: FreeTransformInteractionMode)
    func strokeCaptureView(_ view: StrokeCaptureMTKView, didChangeTransformAt point: CanvasPoint)
    func strokeCaptureView(_ view: StrokeCaptureMTKView, didEndTransformAt point: CanvasPoint)
    func strokeCaptureView(_ view: StrokeCaptureMTKView, didRotateCanvasTo angleDegrees: Double)
    func strokeCaptureView(_ view: StrokeCaptureMTKView, didPanBy deltaX: Double, deltaY: Double)
    func strokeCaptureView(_ view: StrokeCaptureMTKView, didChangePanMode isActive: Bool)
    func strokeCaptureView(_ view: StrokeCaptureMTKView, didRequestToolShortcutKey key: String, modifiers: NSEvent.ModifierFlags)
    func strokeCaptureViewDidRequestCanvasToolCancel(_ view: StrokeCaptureMTKView)
    func strokeCaptureViewDidRequestClearSelection(_ view: StrokeCaptureMTKView)
    func strokeCaptureViewDidRequestApplyTransform(_ view: StrokeCaptureMTKView)
    func strokeCaptureViewDidRequestCancelTransform(_ view: StrokeCaptureMTKView)
    func strokeCaptureViewDidSyncTransformOffset(_ view: StrokeCaptureMTKView)
    func strokeCaptureView(_ view: StrokeCaptureMTKView, didRequestBrushSizeAdjustment delta: Float)
}

final class StrokeCaptureMTKView: MTKView {
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
    private var selectionMoveLastPoint: CanvasPoint?
    private var lastPanLocation: CGPoint?
    private var lastPressure: Float?
    private let minimumTabletPressure: Float = 0.02
    private var trackingAreaRef: NSTrackingArea?
    private let cursorIndicatorLayer = CAShapeLayer()
    private var hoverLocation: CGPoint?
    private var activeModifierFlags: NSEvent.ModifierFlags = []
    private let selectionTraceLogger = Logger(subsystem: "ArtFlex", category: "SelectionTrace")
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

        if activeTool == .straightLine || activeTool == .linearGradient || activeTool == .sectorGradient {
            setNeedsDisplay(bounds)
            return
        }

        if activeTool == .freeTransform {
            let point = sample(from: event).location
            let mode = transformPreviewDelegate?.freeTransformInteractionMode(for: point, in: self) ?? .move
            beginContinuousTransformRendering()
            strokeDelegate?.strokeCaptureView(self, didBeginTransformAt: point, mode: mode)
            // shouldBeginTransformAt이 성공하면 내부에서 startPoint가 설정됨
            // 실패해도 delegate에게 startPoint 기록을 요청
            let sessionStarted = transformPreviewDelegate?.strokeCaptureView(self, shouldBeginTransformAt: point) ?? false
            if !sessionStarted {
                // preparedSession 미준비 — delegate에 fallback startPoint 설정 요청
                transformPreviewDelegate?.strokeCaptureViewSetFallbackStartPoint(self, point: point)
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
        let sample = sample(from: event)
        lastSample = sample
        strokeDelegate?.strokeCaptureView(self, didProduce: [sample])
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

        if activeTool == .straightLine || activeTool == .linearGradient || activeTool == .sectorGradient {
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
            strokeDelegate?.strokeCaptureView(self, didChangeTransformAt: point)
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

        let current = sample(from: event)
        if let lastSample {
            emitStrokeSamples(from: lastSample, to: current)
        } else {
            strokeDelegate?.strokeCaptureView(self, didProduce: [current])
        }
        lastSample = current
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

        if activeTool == .straightLine || activeTool == .linearGradient || activeTool == .sectorGradient {
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
            transformPreviewDelegate?.strokeCaptureViewDidCancelTransformPreview(self)
            strokeDelegate?.strokeCaptureView(self, didEndTransformAt: sample(from: event).location)
            // mouseUp: ViewModel에 현재 offset 동기화 (SwiftUI overlay 업데이트)
            strokeDelegate?.strokeCaptureViewDidSyncTransformOffset(self)
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

        let current = sample(from: event)
        if let lastSample {
            emitStrokeSamples(from: lastSample, to: current)
        } else {
            strokeDelegate?.strokeCaptureView(self, didProduce: [current])
        }
        strokeDelegate?.strokeCaptureViewDidEndStroke(self)
        endContinuousStrokeRendering()
        lastSample = nil
        lastPressure = nil
        setNeedsDisplay(bounds)
    }

    override func keyDown(with event: NSEvent) {
        let normalizedModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        activeModifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        updateCursorAppearance()

        // Enter：提交 freeTransform
        if (event.keyCode == 36 || event.keyCode == 76) && activeTool == .freeTransform {
            strokeDelegate?.strokeCaptureViewDidRequestApplyTransform(self)
            return
        }

        // ESC：取消 freeTransform 或其他工具
        if event.keyCode == 53 {
            if activeTool == .freeTransform {
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
        if activeTool == .straightLine || activeTool == .linearGradient || activeTool == .sectorGradient || activeTool == .polygonSelection {
            strokeDelegate?.strokeCaptureView(self, didHoverCanvasAt: sample(from: event).location)
            setNeedsDisplay(bounds)
        }
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
            if let lastPressure {
                normalizedPressure = (lastPressure * 0.9) + (clamped * 0.1)
            } else {
                normalizedPressure = clamped
            }
        } else if event.subtype == .tabletPoint {
            normalizedPressure = lastPressure ?? minimumTabletPressure
        } else {
            normalizedPressure = 1
        }
        lastPressure = normalizedPressure

        let sample = CanvasStrokeSample(
            location: CanvasPoint(
                x: Double(normalizedX) * Double(canvasSize.width),
                y: Double(1 - normalizedY) * Double(canvasSize.height)
            ),
            pressure: normalizedPressure
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

    private func emitStrokeSamples(from previous: CanvasStrokeSample, to current: CanvasStrokeSample) {
        let dx = current.location.x - previous.location.x
        let dy = current.location.y - previous.location.y
        let distanceSquared = (dx * dx) + (dy * dy)
        let pressureDelta = abs(current.pressure - previous.pressure)

        if distanceSquared < 0.25, pressureDelta < 0.01 {
            return
        }

        strokeDelegate?.strokeCaptureView(self, didProduce: [previous, current])
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
        lastSample = nil
        lastPanLocation = nil
        lastPressure = nil
        selectionInteractionMode = .idle
        selectionMoveLastPoint = nil
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

final class MetalCanvasCoordinator: NSObject, MTKViewDelegate, StrokeCaptureDelegate {
    fileprivate struct PreparedTransformSignature: Equatable {
        let activeLayerSurfaceID: LayerSurfaceID
        let selectionShape: SelectionShape
    }

    private let metalContext: MetalDeviceContext
    private let layerSurfaceStore: StageOneLayerSurfaceStore
    private let canvasPresenter: StageOneCanvasPresenter
    var activeTool: ToolKind
    private let transformPreviewBuilder = TransformPreviewSessionBuilder()
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
    private let onTransformBegan: (CanvasPoint, FreeTransformInteractionMode) -> Void
    private let onTransformChanged: (CanvasPoint) -> Void
    private let onTransformEnded: (CanvasPoint) -> Void
    private let onTransformOffsetChanged: (CanvasPoint) -> Void
    private let onCanvasRotationChanged: (Double) -> Void
    private let onPanModeChanged: (Bool) -> Void
    private let onToolShortcut: (String, NSEvent.ModifierFlags) -> Void
    private let onCancelCanvasTool: () -> Void
    private let onClearSelection: () -> Void
    private let onApplyTransform: () -> Void
    private let onCancelTransform: () -> Void
    private let onAdjustBrushSize: (Float) -> Void

    var sceneSnapshot: CanvasSceneSnapshot?
    var isTransformingSelection = false
    fileprivate var transformPreviewSession: TransformPreviewSession?
    fileprivate var preparedTransformSession: TransformPreviewSession?
    fileprivate var preparedTransformSignature: PreparedTransformSignature?
    fileprivate var transformPreviewStartPoint: CanvasPoint?
    fileprivate var transformPreviewDragBaseOffset = CanvasPoint(x: 0, y: 0)
    fileprivate var isPrepBuildingSession = false
    // freeTransform 전체 레이어 이동용 offset (makeSession 없이 GPU encodePreview에 직접 전달)
    fileprivate var freeTransformDragOffset = CanvasPoint(x: 0, y: 0)
    fileprivate var freeTransformDragStart: CanvasPoint? = nil
    fileprivate var freeTransformDragBase = CanvasPoint(x: 0, y: 0)
    var transformPreview = FreeTransformPreview.identity
    private let selectionTraceLogger = Logger(subsystem: "ArtFlex", category: "SelectionTrace")

    init(
        metalContext: MetalDeviceContext,
        layerSurfaceStore: StageOneLayerSurfaceStore,
        activeTool: ToolKind,
        transformPreview: FreeTransformPreview,
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
        onTransformBegan: @escaping (CanvasPoint, FreeTransformInteractionMode) -> Void,
        onTransformChanged: @escaping (CanvasPoint) -> Void,
        onTransformEnded: @escaping (CanvasPoint) -> Void,
        onTransformOffsetChanged: @escaping (CanvasPoint) -> Void,
        onPanModeChanged: @escaping (Bool) -> Void,
        onToolShortcut: @escaping (String, NSEvent.ModifierFlags) -> Void,
        onCancelCanvasTool: @escaping () -> Void,
        onClearSelection: @escaping () -> Void,
        onApplyTransform: @escaping () -> Void,
        onCancelTransform: @escaping () -> Void,
        onAdjustBrushSize: @escaping (Float) -> Void
    ) {
        self.metalContext = metalContext
        self.layerSurfaceStore = layerSurfaceStore
        self.canvasPresenter = StageOneCanvasPresenter(device: metalContext.device)
        self.activeTool = activeTool
        self.transformPreview = transformPreview
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
        self.onCancelCanvasTool = onCancelCanvasTool
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
            let activeLayerSurfaceID = snapshot.activeLayerSurfaceID
            let hasActivePreview = isTransforming

            let orderedVisibleLayers = snapshot.layerSurfaces.compactMap { surface -> (MTLTexture, Float)? in
                guard surface.isVisible, let texture = layerSurfaceStore.texture(for: surface.surfaceID) else {
                    return nil
                }

                if hasActivePreview, surface.surfaceID == activeLayerSurfaceID {
                    if let session = transformPreviewSession {
                        if let workingTexture = session.workingTexture {
                            // 选区变形：先画挖空后的底图，再单独叠加 preview
                            return (workingTexture, surface.opacity)
                        }
                        // 整层移动：由 encodePreview 单独绘制 preview
                        return nil
                    }
                    // preview session 还没准备好时，继续显示原图层，避免首帧同步构建造成卡顿/闪空。
                    return (texture, surface.opacity)
                }
                return (texture, surface.opacity)
            }

            canvasPresenter.encode(
                layerTextures: orderedVisibleLayers,
                into: descriptor,
                commandBuffer: commandBuffer
            )

            if hasActivePreview, let surfaceID = activeLayerSurfaceID {
                descriptor.colorAttachments[0].loadAction = .load
                descriptor.colorAttachments[0].storeAction = .store

                if let session = transformPreviewSession {
                    canvasPresenter.encodePreview(
                        texture: session.previewTexture,
                        opacity: 1,
                        canvasSize: canvasSize,
                        bounds: session.previewBounds,
                        preview: transformPreview,
                        into: descriptor,
                        commandBuffer: commandBuffer
                    )
                } else if snapshot.selectionShape == nil,
                          let texture = layerSurfaceStore.texture(for: surfaceID) {
                    let fullBounds = CanvasRect(
                        origin: .init(x: 0, y: 0),
                        size: .init(x: Double(canvasSize.width), y: Double(canvasSize.height))
                    )
                    canvasPresenter.encodePreview(
                        texture: texture,
                        opacity: snapshot.layerSurfaces.first(where: { $0.surfaceID == surfaceID })?.opacity ?? 1,
                        canvasSize: canvasSize,
                        bounds: fullBounds,
                        preview: transformPreview,
                        into: descriptor,
                        commandBuffer: commandBuffer
                    )
                }
            } else if let previewSession = transformPreviewSession, !isTransforming {
                // 기존 non-freeTransform 도구의 transform
                descriptor.colorAttachments[0].loadAction = .load
                descriptor.colorAttachments[0].storeAction = .store
                canvasPresenter.encodePreview(
                    texture: previewSession.previewTexture,
                    opacity: 1,
                    canvasSize: canvasSize,
                    bounds: previewSession.previewBounds,
                    preview: transformPreview,
                    into: descriptor,
                    commandBuffer: commandBuffer
                )
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

    func strokeCaptureView(_ view: StrokeCaptureMTKView, didBeginTransformAt point: CanvasPoint, mode: FreeTransformInteractionMode) {
        onTransformBegan(point, mode)
    }

    func strokeCaptureView(_ view: StrokeCaptureMTKView, didChangeTransformAt point: CanvasPoint) {
        onTransformChanged(point)
    }

    func strokeCaptureView(_ view: StrokeCaptureMTKView, didEndTransformAt point: CanvasPoint) {
        onTransformEnded(point)
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

    func strokeCaptureViewDidRequestClearSelection(_ view: StrokeCaptureMTKView) {
        onClearSelection()
    }

    func strokeCaptureViewDidRequestApplyTransform(_ view: StrokeCaptureMTKView) {
        onApplyTransform()
    }

    func strokeCaptureViewDidRequestCancelTransform(_ view: StrokeCaptureMTKView) {
        freeTransformDragOffset = .init(x: 0, y: 0)
        freeTransformDragBase = .init(x: 0, y: 0)
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
        guard let selectionBounds = sceneSnapshot?.selectionShape?.bounds else {
            return .move
        }

        let handleCanvasRadius = max(Double(14) * Double(view.canvasSize.width) / max(view.bounds.width, 1), 12)
        let handlePoints = freeTransformHandlePoints(
            bounds: selectionBounds,
            preview: transformPreview,
            rotationHandleDistance: handleCanvasRadius * 3.4
        )

        if let rotationPoint = handlePoints[.rotation],
           hypot(rotationPoint.x - point.x, rotationPoint.y - point.y) <= handleCanvasRadius {
            return .rotate
        }

        for handle in FreeTransformHandle.allCases where handle != .rotation {
            if let handlePoint = handlePoints[handle],
               hypot(handlePoint.x - point.x, handlePoint.y - point.y) <= handleCanvasRadius {
                return .scale(handle)
            }
        }

        if freeTransformContains(point: point, bounds: selectionBounds, preview: transformPreview) {
            return .move
        }

        return .move
    }

    func strokeCaptureView(_ view: StrokeCaptureMTKView, shouldBeginTransformAt point: CanvasPoint) -> Bool {
        // 이미 활성 세션이 있는 경우: 연속 드래그
        if transformPreviewSession != nil {
            transformPreviewStartPoint = point
            return true
        }

        // preparedSession 已准备好：直接进入拖动
        if let prepared = preparedTransformSession {
            transformPreviewSession = prepared
            transformPreviewStartPoint = point
            return true
        }

        guard
            let snapshot = sceneSnapshot,
            let activeLayerSurfaceID = snapshot.activeLayerSurfaceID
        else {
            return false
        }

        let canvasSize = snapshot.renderSnapshot.document.canvasSize
        let effectiveSelection: SelectionShape = snapshot.selectionShape ?? SelectionShape(
            kind: .rectangle,
            bounds: CanvasRect(
                origin: .init(x: 0, y: 0),
                size: .init(x: Double(canvasSize.width), y: Double(canvasSize.height))
            ),
            pathPoints: []
        )

        let signature = PreparedTransformSignature(
            activeLayerSurfaceID: activeLayerSurfaceID,
            selectionShape: effectiveSelection
        )

        // 不再在主线程同步 makeSession。让后台预热继续进行，本次拖动先记录起点即可。
        if preparedTransformSignature != signature {
            preparedTransformSession = nil
            preparedTransformSignature = nil
        }
        transformPreviewStartPoint = point
        updatePreparedTransformSessionIfNeeded()
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
            preparedTransformSession = nil
            preparedTransformSignature = nil
            isPrepBuildingSession = false
            return
        }

        if transformPreviewSession != nil { return }

        guard activeTool == .freeTransform else {
            preparedTransformSession = nil
            preparedTransformSignature = nil
            return
        }

        guard
            let snapshot = sceneSnapshot,
            let activeLayerSurfaceID = snapshot.activeLayerSurfaceID
        else {
            preparedTransformSession = nil
            preparedTransformSignature = nil
            return
        }

        let canvasSize = snapshot.renderSnapshot.document.canvasSize
        let effectiveSelection: SelectionShape = snapshot.selectionShape ?? SelectionShape(
            kind: .rectangle,
            bounds: CanvasRect(
                origin: .init(x: 0, y: 0),
                size: .init(x: Double(canvasSize.width), y: Double(canvasSize.height))
            ),
            pathPoints: []
        )

        let signature = PreparedTransformSignature(
            activeLayerSurfaceID: activeLayerSurfaceID,
            selectionShape: effectiveSelection
        )

        if preparedTransformSignature == signature, preparedTransformSession != nil { return }
        if isPrepBuildingSession { return }

        isPrepBuildingSession = true
        let capturedSnapshot = snapshot
        let capturedSurfaceStore = UncheckedBox(layerSurfaceStore)
        let capturedMetal = UncheckedBox(metalContext)
        let capturedBuilder = UncheckedBox(transformPreviewBuilder)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let session = try? capturedBuilder.value.makeSession(
                sceneSnapshot: capturedSnapshot,
                layerSurfaceStore: capturedSurfaceStore.value,
                metal: capturedMetal.value,
                selectionShape: effectiveSelection
            )
            DispatchQueue.main.async {
                guard let self, self.isTransformingSelection else { return }
                self.isPrepBuildingSession = false
                self.preparedTransformSession = session
                self.preparedTransformSignature = session == nil ? nil : signature
            }
        }
    }

}

/// non-Sendable 타입을 DispatchQueue 클로저에서 캡처하기 위한 래퍼
private final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

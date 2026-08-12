import AppKit
import SwiftUI

/// Marks an AppKit editor that must keep keyboard ownership while SwiftUI republishes workspace state.
@MainActor
protocol WorkspaceKeyboardFocusOwner: AnyObject {}

struct WindowKeyboardBridge: NSViewRepresentable {
    private let keyDownEventHandler: (NSEvent) -> Bool
    private let keyUpEventHandler: (NSEvent) -> Bool
    private let flagsChangedEventHandler: (NSEvent) -> Bool
    private let shouldMonitorBrushSizeShortcut: () -> Bool

    init(viewModel: WorkspaceViewModel) {
        self.keyDownEventHandler = { [weak viewModel] event in
            viewModel?.handleKeyDown(event) ?? false
        }
        self.keyUpEventHandler = { [weak viewModel] event in
            viewModel?.handleKeyUp(event) ?? false
        }
        self.flagsChangedEventHandler = { [weak viewModel] event in
            viewModel?.handleModifierFlagsChanged(event.modifierFlags) ?? false
        }
        self.shouldMonitorBrushSizeShortcut = { [weak viewModel] in
            viewModel?.isBrushTipCanvasFocused ?? false
        }
    }

    init(
        keyDownHandler: @escaping (NSEvent) -> Bool,
        keyUpHandler: @escaping (NSEvent) -> Bool,
        flagsChangedHandler: @escaping (NSEvent) -> Bool,
        shouldMonitorBrushSizeShortcut: @escaping () -> Bool = { false }
    ) {
        self.keyDownEventHandler = keyDownHandler
        self.keyUpEventHandler = keyUpHandler
        self.flagsChangedEventHandler = flagsChangedHandler
        self.shouldMonitorBrushSizeShortcut = shouldMonitorBrushSizeShortcut
    }

    func makeNSView(context: Context) -> KeyboardBridgeView {
        let view = KeyboardBridgeView()
        view.keyDownHandler = keyDownEventHandler
        view.keyUpHandler = keyUpEventHandler
        view.flagsChangedHandler = flagsChangedEventHandler
        view.shouldMonitorBrushSizeShortcut = shouldMonitorBrushSizeShortcut
        return view
    }

    func updateNSView(_ nsView: KeyboardBridgeView, context: Context) {
        nsView.keyDownHandler = keyDownEventHandler
        nsView.keyUpHandler = keyUpEventHandler
        nsView.flagsChangedHandler = flagsChangedEventHandler
        nsView.shouldMonitorBrushSizeShortcut = shouldMonitorBrushSizeShortcut
        nsView.activateIfNeeded()
    }
}

@MainActor
final class KeyboardBridgeView: NSView {
    var keyDownHandler: ((NSEvent) -> Bool)?
    var keyUpHandler: ((NSEvent) -> Bool)?
    var flagsChangedHandler: ((NSEvent) -> Bool)?
    var shouldMonitorBrushSizeShortcut: (() -> Bool)?
    private var workspaceKeyDownMonitor: Any?
    private var workspaceKeyUpMonitor: Any?
    private var workspacePointerDownMonitor: Any?
    private var forwardedModalSpaceWindowNumber: Int?
    private var lastPointerInteractionWasCanvas = true

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        installWorkspaceKeyDownMonitorIfNeeded()
        installWorkspaceKeyUpMonitorIfNeeded()
        installWorkspacePointerDownMonitorIfNeeded()
        activateIfNeeded()
    }

    override func keyDown(with event: NSEvent) {
        let normalizedModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 48,
           normalizedModifiers.isEmpty,
           !shouldAllowWorkspaceChromeToggle(for: window?.firstResponder) {
            window?.selectNextKeyView(nil)
            return
        }
        if let delta = brushSizeShortcutDirection(for: event) {
            activeStrokeCaptureView()?.previewAdjustBrushSize(by: delta)
        }
        if keyDownHandler?(event) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if keyUpHandler?(event) == true {
            return
        }
        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        if flagsChangedHandler?(event) == true {
            return
        }
        super.flagsChanged(with: event)
    }

    func activateIfNeeded() {
        guard let window else { return }
        if shouldPreserveCurrentFirstResponder(window.firstResponder) {
            return
        }
        if window.firstResponder !== self {
            window.makeFirstResponder(self)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let workspaceKeyDownMonitor {
            NSEvent.removeMonitor(workspaceKeyDownMonitor)
            self.workspaceKeyDownMonitor = nil
        }
        if newWindow == nil, let workspaceKeyUpMonitor {
            NSEvent.removeMonitor(workspaceKeyUpMonitor)
            self.workspaceKeyUpMonitor = nil
            forwardedModalSpaceWindowNumber = nil
        }
        if newWindow == nil, let workspacePointerDownMonitor {
            NSEvent.removeMonitor(workspacePointerDownMonitor)
            self.workspacePointerDownMonitor = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    private func installWorkspaceKeyDownMonitorIfNeeded() {
        guard workspaceKeyDownMonitor == nil else { return }
        workspaceKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window else { return event }
            guard event.windowNumber == window.windowNumber else { return event }

            let normalizedModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if isForegroundColorFillShortcut(
                keyCode: event.keyCode,
                modifiers: normalizedModifiers
            ) {
                guard self.shouldAllowWorkspaceShortcut(for: window.firstResponder) else { return event }
                return self.keyDownHandler?(event) == true ? nil : event
            }

            if brushSizeShortcutDirection(for: event) != nil,
               self.shouldMonitorBrushSizeShortcut?() == true {
                guard self.shouldAllowWorkspaceShortcut(for: window.firstResponder) else { return event }
                return self.keyDownHandler?(event) == true ? nil : event
            }

            if self.shouldForwardWorkspaceShortcutFromControl(
                event,
                responder: window.firstResponder
            ) {
                let handled = self.keyDownHandler?(event) == true
                if handled, event.keyCode == 49 {
                    self.forwardedModalSpaceWindowNumber = window.windowNumber
                }
                return handled ? nil : event
            }

            guard event.keyCode == 48, normalizedModifiers.isEmpty else { return event }
            guard self.shouldAllowWorkspaceChromeToggle(for: window.firstResponder) else {
                window.selectNextKeyView(nil)
                return nil
            }
            return self.keyDownHandler?(event) == true ? nil : event
        }
    }

    private func installWorkspaceKeyUpMonitorIfNeeded() {
        guard workspaceKeyUpMonitor == nil else { return }
        workspaceKeyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard
                let self,
                event.keyCode == 49,
                let forwardedWindowNumber = self.forwardedModalSpaceWindowNumber,
                event.windowNumber == forwardedWindowNumber,
                self.window?.windowNumber == forwardedWindowNumber
            else {
                return event
            }

            self.forwardedModalSpaceWindowNumber = nil
            return self.keyUpHandler?(event) == true ? nil : event
        }
    }

    func shouldPreserveCurrentFirstResponder(_ responder: Any?) -> Bool {
        if responder is any WorkspaceKeyboardFocusOwner {
            return true
        }
        if let textView = responder as? NSTextView, textView.isEditable {
            return true
        }
        if let textField = responder as? NSTextField, textField.isEditable {
            return true
        }
        if responder is NSControl {
            return true
        }
        return false
    }

    func shouldAllowWorkspaceChromeToggle(for responder: NSResponder?) -> Bool {
        guard lastPointerInteractionWasCanvas else { return false }
        guard let responder else { return true }
        return responder === self || responder is StrokeCaptureMTKView
    }

    func recordWorkspacePointerInteraction(isCanvasInteraction: Bool) {
        lastPointerInteractionWasCanvas = isCanvasInteraction
    }

    func shouldForwardWorkspaceShortcutFromControl(
        _ event: NSEvent,
        responder: NSResponder?
    ) -> Bool {
        guard responder is NSControl else { return false }
        if let textView = responder as? NSTextView, textView.isEditable {
            return false
        }
        if let textField = responder as? NSTextField, textField.isEditable {
            return false
        }
        let commandModifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard commandModifiers.isEmpty else { return false }

        if event.keyCode == 49, responder is NSSlider {
            return true
        }
        guard let characters = event.charactersIgnoringModifiers, characters.count == 1 else {
            return false
        }
        return characters.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
    }

    private func shouldAllowWorkspaceShortcut(for responder: Any?) -> Bool {
        guard let responder else { return true }
        if let textView = responder as? NSTextView, textView.isEditable {
            return false
        }
        return true
    }

    private func installWorkspacePointerDownMonitorIfNeeded() {
        guard workspacePointerDownMonitor == nil else { return }
        workspacePointerDownMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self, let window = self.window, event.window === window else {
                return event
            }
            self.recordWorkspacePointerInteraction(
                isCanvasInteraction: self.isPointInsideVisibleCanvas(event.locationInWindow)
            )
            return event
        }
    }

    private func isPointInsideVisibleCanvas(_ pointInWindow: NSPoint) -> Bool {
        guard let rootView = window?.contentView else { return false }
        return containsVisibleCanvas(at: pointInWindow, in: rootView)
    }

    private func containsVisibleCanvas(at pointInWindow: NSPoint, in view: NSView) -> Bool {
        if let strokeView = view as? StrokeCaptureMTKView,
           !strokeView.isHiddenOrHasHiddenAncestor,
           strokeView.bounds.contains(strokeView.convert(pointInWindow, from: nil)) {
            return true
        }
        return view.subviews.contains { subview in
            containsVisibleCanvas(at: pointInWindow, in: subview)
        }
    }

    private func activeStrokeCaptureView() -> StrokeCaptureMTKView? {
        guard let rootView = window?.contentView else {
            return nil
        }
        return findStrokeCaptureView(in: rootView)
    }

    private func findStrokeCaptureView(in view: NSView) -> StrokeCaptureMTKView? {
        if let strokeView = view as? StrokeCaptureMTKView {
            return strokeView
        }
        for subview in view.subviews {
            if let strokeView = findStrokeCaptureView(in: subview) {
                return strokeView
            }
        }
        return nil
    }
}

func brushSizeShortcutDirection(for event: NSEvent) -> Float? {
    let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
    guard modifiers.isEmpty else { return nil }

    // ANSI physical positions keep the shortcut stable across input methods.
    switch event.keyCode {
    case 33:
        return -1
    case 30:
        return 1
    default:
        break
    }

    switch event.charactersIgnoringModifiers {
    case "[":
        return -1
    case "]":
        return 1
    default:
        return nil
    }
}

func isForegroundColorFillShortcut(
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags
) -> Bool {
    (keyCode == 51 || keyCode == 117) && modifiers == [.option]
}

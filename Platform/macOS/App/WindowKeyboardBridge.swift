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
            viewModel?.isBrushTipEditorVisible ?? false
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

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installWorkspaceKeyDownMonitorIfNeeded()
        activateIfNeeded()
    }

    override func keyDown(with event: NSEvent) {
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
        super.viewWillMove(toWindow: newWindow)
    }

    private func installWorkspaceKeyDownMonitorIfNeeded() {
        guard workspaceKeyDownMonitor == nil else { return }
        workspaceKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window else { return event }
            guard NSApp.keyWindow === window else { return event }

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

            guard event.keyCode == 48, normalizedModifiers.isEmpty else { return event }
            guard self.shouldAllowWorkspaceShortcut(for: window.firstResponder) else { return event }
            return self.keyDownHandler?(event) == true ? nil : event
        }
    }

    private func shouldPreserveCurrentFirstResponder(_ responder: Any?) -> Bool {
        if responder is any WorkspaceKeyboardFocusOwner {
            return true
        }
        if let textView = responder as? NSTextView, textView.isEditable {
            return true
        }
        if let textField = responder as? NSTextField, textField.isEditable {
            return true
        }
        return false
    }

    private func shouldAllowWorkspaceShortcut(for responder: Any?) -> Bool {
        guard let responder else { return true }
        if let textView = responder as? NSTextView, textView.isEditable {
            return false
        }
        return true
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

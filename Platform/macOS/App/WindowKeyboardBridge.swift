import AppKit
import SwiftUI

struct WindowKeyboardBridge: NSViewRepresentable {
    private let keyDownEventHandler: (NSEvent) -> Bool
    private let keyUpEventHandler: (NSEvent) -> Bool
    private let flagsChangedEventHandler: (NSEvent) -> Bool

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
    }

    init(
        keyDownHandler: @escaping (NSEvent) -> Bool,
        keyUpHandler: @escaping (NSEvent) -> Bool,
        flagsChangedHandler: @escaping (NSEvent) -> Bool
    ) {
        self.keyDownEventHandler = keyDownHandler
        self.keyUpEventHandler = keyUpHandler
        self.flagsChangedEventHandler = flagsChangedHandler
    }

    func makeNSView(context: Context) -> KeyboardBridgeView {
        let view = KeyboardBridgeView()
        view.keyDownHandler = keyDownEventHandler
        view.keyUpHandler = keyUpEventHandler
        view.flagsChangedHandler = flagsChangedEventHandler
        return view
    }

    func updateNSView(_ nsView: KeyboardBridgeView, context: Context) {
        nsView.keyDownHandler = keyDownEventHandler
        nsView.keyUpHandler = keyUpEventHandler
        nsView.flagsChangedHandler = flagsChangedEventHandler
        nsView.activateIfNeeded()
    }
}

@MainActor
final class KeyboardBridgeView: NSView {
    var keyDownHandler: ((NSEvent) -> Bool)?
    var keyUpHandler: ((NSEvent) -> Bool)?
    var flagsChangedHandler: ((NSEvent) -> Bool)?
    private var tabKeyMonitor: Any?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installTabMonitorIfNeeded()
        activateIfNeeded()
    }

    override func keyDown(with event: NSEvent) {
        if let delta = brushSizeShortcutDelta(for: event) {
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
        if newWindow == nil, let tabKeyMonitor {
            NSEvent.removeMonitor(tabKeyMonitor)
            self.tabKeyMonitor = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    private func installTabMonitorIfNeeded() {
        guard tabKeyMonitor == nil else { return }
        tabKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window else { return event }
            guard NSApp.keyWindow === window else { return event }
            guard event.keyCode == 48 else { return event }

            let normalizedModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard normalizedModifiers.isEmpty else { return event }
            guard self.shouldAllowTabWorkspaceChromeToggle(for: window.firstResponder) else { return event }

            if self.keyDownHandler?(event) == true {
                return nil
            }
            return event
        }
    }

    private func shouldPreserveCurrentFirstResponder(_ responder: Any?) -> Bool {
        false
    }

    private func shouldAllowTabWorkspaceChromeToggle(for responder: Any?) -> Bool {
        guard let responder else { return true }
        if let textView = responder as? NSTextView, textView.isEditable {
            return false
        }
        return true
    }

    private func brushSizeShortcutDelta(for event: NSEvent) -> Float? {
        switch event.charactersIgnoringModifiers {
        case "[":
            return -1
        case "]":
            return 1
        default:
            return nil
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

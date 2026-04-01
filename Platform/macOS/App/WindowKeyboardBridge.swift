import AppKit
import SwiftUI

struct WindowKeyboardBridge: NSViewRepresentable {
    @ObservedObject var viewModel: WorkspaceViewModel

    func makeNSView(context: Context) -> KeyboardBridgeView {
        let view = KeyboardBridgeView()
        view.keyDownHandler = { [weak viewModel] event in
            viewModel?.handleKeyDown(event) ?? false
        }
        view.keyUpHandler = { [weak viewModel] event in
            viewModel?.handleKeyUp(event) ?? false
        }
        view.flagsChangedHandler = { [weak viewModel] event in
            viewModel?.handleModifierFlagsChanged(event.modifierFlags) ?? false
        }
        return view
    }

    func updateNSView(_ nsView: KeyboardBridgeView, context: Context) {
        nsView.keyDownHandler = { [weak viewModel] event in
            viewModel?.handleKeyDown(event) ?? false
        }
        nsView.keyUpHandler = { [weak viewModel] event in
            viewModel?.handleKeyUp(event) ?? false
        }
        nsView.flagsChangedHandler = { [weak viewModel] event in
            viewModel?.handleModifierFlagsChanged(event.modifierFlags) ?? false
        }
        nsView.activateIfNeeded()
    }
}

final class KeyboardBridgeView: NSView {
    var keyDownHandler: ((NSEvent) -> Bool)?
    var keyUpHandler: ((NSEvent) -> Bool)?
    var flagsChangedHandler: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
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
        if window.firstResponder !== self {
            window.makeFirstResponder(self)
        }
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

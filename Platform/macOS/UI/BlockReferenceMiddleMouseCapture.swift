import AppKit
import IOKit.hidsystem

/// Owns a middle-button gesture before AppKit routes it to an NSView. Some input
/// drivers deliver auxiliary-button changes and windowless drag/up events instead
/// of a complete otherMouseDown/Dragged/Up sequence to the hit-tested view.
@MainActor
final class BlockReferenceMiddleMouseCapture: NSObject {
    weak var view: NSView?
    var onBegan: ((CGPoint, NSEvent.ModifierFlags) -> Void)?
    var onChanged: ((CGPoint) -> Void)?
    var onEnded: (() -> Void)?

    private var monitor: Any?
    private(set) var isCapturing = false
    private var rejectedMiddleDown = false
    private var suppressPenContactUntilUp = false
    private static let middleMask = 1 << 2

    func install(for view: NSView) {
        stop()
        self.view = view
        guard let window = view.window else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [
            .systemDefined, .otherMouseDown, .otherMouseDragged, .otherMouseUp,
            .mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .tabletPoint
        ]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(endForFocusChange),
            name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(endForFocusChange),
            name: NSApplication.willResignActiveNotification, object: nil)
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        NotificationCenter.default.removeObserver(self)
        endForFocusChange()
        view = nil
    }

    @objc private func endForFocusChange() {
        finish()
        suppressPenContactUntilUp = false
        rejectedMiddleDown = false
    }

    private func finish() {
        guard isCapturing else { return }
        isCapturing = false
        onEnded?()
    }

    func handle(_ event: NSEvent) -> NSEvent? {
        guard let view, let window = view.window, window.isVisible,
              !view.isHiddenOrHasHiddenAncestor,
              window.attachedSheet == nil,
              NSApp.modalWindow == nil || NSApp.modalWindow === window else {
            endForFocusChange()
            return event
        }

        if event.type == .leftMouseUp, suppressPenContactUntilUp {
            suppressPenContactUntilUp = false
            return nil
        }

        // IOLLEvent.h: data1 is the changed-button mask, data2 the down-button
        // mask. Only the middle bit is relevant; media keys and side buttons pass.
        if event.type == .systemDefined {
            guard event.subtype.rawValue == NX_SUBTYPE_AUX_MOUSE_BUTTONS,
                  event.data1 & Self.middleMask != 0 else { return event }
            if event.data2 & Self.middleMask != 0 {
                return handleDown(event, view: view, window: window)
            }
            rejectedMiddleDown = false
            guard isCapturing else { return event }
            finish()
            return nil
        }

        switch event.type {
        case .otherMouseDown where event.buttonNumber == 2:
            return handleDown(event, view: view, window: window)
        case .otherMouseDragged where event.buttonNumber == 2:
            // Recover a missing down only when the first drag actually hits 3D.
            // Never start a gesture over the inspector, a sheet, or another window.
            guard !rejectedMiddleDown,
                  isCapturing || begin(event, view: view, window: window) else { return event }
            onChanged?(localPoint(event, view: view, window: window))
            return nil
        case .otherMouseUp where event.buttonNumber == 2:
            rejectedMiddleDown = false
            guard isCapturing else { return event }
            finish()
            return nil
        case .leftMouseDown where isCapturing:
            // A pen can touch the tablet while its mapped middle button is held.
            // Do not let that contact create/move a model or end navigation early.
            suppressPenContactUntilUp = true
            return nil
        case .leftMouseDragged where isCapturing,
             .mouseMoved where isCapturing,
             .tabletPoint where isCapturing:
            onChanged?(localPoint(event, view: view, window: window))
            return nil
        default:
            return event
        }
    }

    private func handleDown(_ event: NSEvent, view: NSView, window: NSWindow) -> NSEvent? {
        guard !rejectedMiddleDown else { return event }
        if begin(event, view: view, window: window) { return nil }
        // Do not reinterpret a known outside/panel press as an orphan drag when
        // it later crosses the 3D viewport. Wait for that button to be released.
        rejectedMiddleDown = true
        return event
    }

    private func begin(_ event: NSEvent, view: NSView, window: NSWindow) -> Bool {
        if isCapturing { return true } // Auxiliary and ordinary down may both arrive.
        guard event.window == nil ? window.isKeyWindow : event.window === window else { return false }
        let point = localPoint(event, view: view, window: window)
        guard view.visibleRect.contains(point), let root = window.contentView else { return false }
        let hitPoint = root.superview?.convert(point, from: view) ?? view.convert(point, to: nil)
        guard root.hitTest(hitPoint) === view else { return false }
        isCapturing = true
        onBegan?(point, event.modifierFlags)
        return true
    }

    private func localPoint(_ event: NSEvent, view: NSView, window: NSWindow) -> CGPoint {
        let pointInWindow: CGPoint
        if let sourceWindow = event.window {
            let screen = sourceWindow.convertPoint(toScreen: event.locationInWindow)
            pointInWindow = window.convertPoint(fromScreen: screen)
        } else {
            // NSEvent.locationInWindow is in Cocoa screen coordinates if window is nil.
            pointInWindow = window.convertPoint(fromScreen: event.locationInWindow)
        }
        return view.convert(pointInWindow, from: nil)
    }
}

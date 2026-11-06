import AppKit

/// Owns the key-up lifetime even if a slider or text control takes focus.
@MainActor
final class WorkspaceMomentaryTools {
    private weak var owner: WorkspaceViewModel?
    private(set) var state: MomentaryToolState?
    private(set) var isSelecting = false
    private var pointerIsDown = false
    nonisolated(unsafe) private var keyUpMonitor: Any?

    init(owner: WorkspaceViewModel) { self.owner = owner }

    deinit { if let keyUpMonitor { NSEvent.removeMonitor(keyUpMonitor) } }

    func keyDown(_ event: NSEvent) -> Bool {
        if let state, state.keyCode == event.keyCode { return true }
        guard let owner,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              let key = event.charactersIgnoringModifiers,
              let group = owner.shortcutSettings.toolGroup(forShortcutKey: key),
              [.eraser, .smudge, .canvasRotate].contains(group.defaultTool) else { return false }
        guard !event.isARepeat else { return true }
        guard !pointerIsDown else { return true }
        restore()
        guard let origin = owner.prepareMomentaryTool(group.defaultTool, keyCode: event.keyCode, timestamp: event.timestamp) else {
            return false
        }
        isSelecting = true
        owner.selectToolFromUI(group.defaultTool, shortcutLabel: owner.shortcutSettings.shortcutDisplayTitle(for: group))
        isSelecting = false
        guard owner.workspace.toolSession.activeTool == group.defaultTool else { return true }
        state = origin
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            self?.keyUp(event) == true ? nil : event
        }
        return true
    }

    func keyUp(_ event: NSEvent) -> Bool {
        guard let state, state.keyCode == event.keyCode else { return false }
        if state.shouldRestore(at: event.timestamp) {
            if pointerIsDown { self.state?.restoreWhenPointerEnds = true }
            else { restore() }
        } else { discard() }
        return true
    }

    func pointerChanged(isDown: Bool) {
        pointerIsDown = isDown
        if !isDown, state?.restoreWhenPointerEnds == true { restore() }
    }

    func discard() {
        state = nil
        if let keyUpMonitor { NSEvent.removeMonitor(keyUpMonitor); self.keyUpMonitor = nil }
    }

    func restore() {
        guard let state else { return }
        discard()
        isSelecting = true
        owner?.restoreMomentaryTool(state)
        isSelecting = false
    }

    func focusLost() { pointerIsDown = false; restore() }
}

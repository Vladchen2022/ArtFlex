import AppKit

/// Native menus own arrows, Return and Escape until AppKit finishes tracking.
/// Keep this at the platform boundary; canvas commands must not consume them.
@MainActor
final class MenuKeyboardOwnership: NSObject {
    static let shared = MenuKeyboardOwnership()
    private let menus = NSHashTable<NSMenu>.weakObjects()
    var isTracking: Bool { !menus.allObjects.isEmpty }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(began(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(ended(_:)), name: NSMenu.didEndTrackingNotification, object: nil)
    }

    @objc private func began(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        menus.add(menu)
    }

    @objc private func ended(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        menus.remove(menu)
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}

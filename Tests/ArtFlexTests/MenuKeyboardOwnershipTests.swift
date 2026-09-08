import AppKit
import Testing
@testable import ArtFlex

@MainActor
struct MenuKeyboardOwnershipTests {
    @Test func nativeMenuNotificationsKeepOwnershipUntilAllMenusClose() {
        let ownership = MenuKeyboardOwnership()
        let first = NSMenu(title: "First")
        let second = NSMenu(title: "Second")
        #expect(!ownership.isTracking)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: first)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: first)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: second)
        #expect(ownership.isTracking)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: first)
        #expect(ownership.isTracking)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: second)
        #expect(!ownership.isTracking)
    }
}

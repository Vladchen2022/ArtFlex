import Foundation

/// DispatchQueue.main may be starved while AppKit waits for terminateLater.
/// Deliver document callbacks in both normal and termination-modal run loops.
enum MainRunLoopDelivery {
    static func perform(_ body: @escaping @MainActor @Sendable () -> Void) {
        RunLoop.main.perform(inModes: [.default, .common, .init(rawValue: "NSModalPanelRunLoopMode")]) {
            MainActor.assumeIsolated { body() }
        }
    }
}

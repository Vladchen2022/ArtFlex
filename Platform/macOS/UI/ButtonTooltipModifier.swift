import SwiftUI

/// The single naming path for icon-only controls. `help` supplies the native
/// macOS hover tag, while `accessibilityLabel` prevents SF Symbol names from
/// leaking into VoiceOver and other accessibility clients.
extension View {
    func buttonTooltip(_ name: String, help: String? = nil) -> some View {
        accessibilityLabel(Text(name))
            .help(help ?? name)
    }
}

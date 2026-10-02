import AppKit

extension CanvasModifierState {
    init(flags: NSEvent.ModifierFlags) {
        shift = flags.contains(.shift)
        option = flags.contains(.option)
        command = flags.contains(.command)
        control = flags.contains(.control)
    }

    var eventFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if shift { flags.insert(.shift) }
        if option { flags.insert(.option) }
        if command { flags.insert(.command) }
        if control { flags.insert(.control) }
        return flags
    }
}

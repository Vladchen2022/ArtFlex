import AppKit
import Foundation
import SwiftUI

struct AppKeyboardShortcut: Codable, Equatable, Sendable {
    var key: String
    var usesCommand = false
    var usesShift = false
    var usesOption = false
    var usesControl = false

    static let defaultQuickColorPicker = AppKeyboardShortcut(
        key: "Z",
        usesCommand: false,
        usesShift: true,
        usesOption: false,
        usesControl: false
    )

    static let defaultOilPaintLoad = AppKeyboardShortcut(key: "D")
    static let defaultOilPaintWash = AppKeyboardShortcut(key: "D", usesShift: true)

    var normalizedKey: String {
        key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if usesCommand { flags.insert(.command) }
        if usesShift { flags.insert(.shift) }
        if usesOption { flags.insert(.option) }
        if usesControl { flags.insert(.control) }
        return flags
    }

    var displayString: String {
        let modifierParts = [
            usesCommand ? "Cmd" : nil,
            usesShift ? "Shift" : nil,
            usesOption ? "Option" : nil,
            usesControl ? "Control" : nil
        ].compactMap { $0 }

        let keyPart = normalizedKey.isEmpty ? "未设置" : normalizedKey
        guard modifierParts.isEmpty == false else { return keyPart }
        return modifierParts.joined(separator: "+") + "+" + keyPart
    }

    func matchesKeyDown(_ event: NSEvent) -> Bool {
        normalizedKey.isEmpty == false &&
        event.charactersIgnoringModifiers?.uppercased() == normalizedKey &&
        event.modifierFlags.intersection(.deviceIndependentFlagsMask) == modifierFlags
    }

    func matchesKeyUp(_ event: NSEvent) -> Bool {
        normalizedKey.isEmpty == false &&
        event.charactersIgnoringModifiers?.uppercased() == normalizedKey
    }

    func modifiersStillSatisfied(by modifierFlags: NSEvent.ModifierFlags) -> Bool {
        let current = modifierFlags.intersection(.deviceIndependentFlagsMask)
        if usesCommand, current.contains(.command) == false { return false }
        if usesShift, current.contains(.shift) == false { return false }
        if usesOption, current.contains(.option) == false { return false }
        if usesControl, current.contains(.control) == false { return false }
        return true
    }
}

@MainActor
final class AppShortcutSettingsStore: ObservableObject {
    private enum StorageKeys {
        static let quickColorPickerShortcut = "ArtFlex.Settings.Shortcuts.QuickColorPicker"
        static let oilPaintLoadShortcut = "ArtFlex.Settings.Shortcuts.OilPaintLoad"
        static let oilPaintWashShortcut = "ArtFlex.Settings.Shortcuts.OilPaintWash"
        static let toolGroupShortcuts = "ArtFlex.Settings.Shortcuts.ToolGroups"
    }

    static let availableShortcutKeys: [String] =
        (65...90).compactMap(UnicodeScalar.init).map { String(Character($0)) } +
        (0...9).map(String.init)

    @Published var quickColorPickerShortcut: AppKeyboardShortcut
    @Published var oilPaintLoadShortcut: AppKeyboardShortcut
    @Published var oilPaintWashShortcut: AppKeyboardShortcut
    @Published private var toolGroupShortcuts: [String: String]

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let data = userDefaults.data(forKey: StorageKeys.quickColorPickerShortcut),
           let decoded = try? JSONDecoder().decode(AppKeyboardShortcut.self, from: data),
           decoded.normalizedKey.isEmpty == false {
            quickColorPickerShortcut = decoded
        } else {
            quickColorPickerShortcut = .defaultQuickColorPicker
        }
        if let data = userDefaults.data(forKey: StorageKeys.oilPaintLoadShortcut),
           let decoded = try? JSONDecoder().decode(AppKeyboardShortcut.self, from: data),
           decoded.normalizedKey.isEmpty == false {
            oilPaintLoadShortcut = decoded
        } else {
            oilPaintLoadShortcut = .defaultOilPaintLoad
        }
        if let data = userDefaults.data(forKey: StorageKeys.oilPaintWashShortcut),
           let decoded = try? JSONDecoder().decode(AppKeyboardShortcut.self, from: data),
           decoded.normalizedKey.isEmpty == false {
            oilPaintWashShortcut = decoded
        } else {
            oilPaintWashShortcut = .defaultOilPaintWash
        }
        if let data = userDefaults.data(forKey: StorageKeys.toolGroupShortcuts),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            let migrated = Self.migratedToolGroupShortcuts(from: decoded)
            let normalized = Self.normalizedToolGroupShortcuts(from: migrated)
            toolGroupShortcuts = normalized
            if normalized != decoded,
               let normalizedData = try? JSONEncoder().encode(normalized) {
                userDefaults.set(normalizedData, forKey: StorageKeys.toolGroupShortcuts)
            }
        } else {
            toolGroupShortcuts = Self.defaultToolGroupShortcuts
        }
    }

    func persist() {
        guard let data = try? JSONEncoder().encode(quickColorPickerShortcut) else { return }
        userDefaults.set(data, forKey: StorageKeys.quickColorPickerShortcut)
        guard let oilPaintLoadData = try? JSONEncoder().encode(oilPaintLoadShortcut) else { return }
        userDefaults.set(oilPaintLoadData, forKey: StorageKeys.oilPaintLoadShortcut)
        guard let oilPaintWashData = try? JSONEncoder().encode(oilPaintWashShortcut) else { return }
        userDefaults.set(oilPaintWashData, forKey: StorageKeys.oilPaintWashShortcut)
        guard let toolGroupData = try? JSONEncoder().encode(toolGroupShortcuts) else { return }
        userDefaults.set(toolGroupData, forKey: StorageKeys.toolGroupShortcuts)
    }

    var configurableToolGroups: [ToolSidebarGroup] {
        ToolSidebarGroup.orderedGroups.filter { $0.shortcutKey != nil }
    }

    func shortcutKey(for group: ToolSidebarGroup) -> String? {
        toolGroupShortcuts[group.id]
    }

    func setShortcutKey(_ key: String, for group: ToolSidebarGroup) {
        let normalized = key.uppercased()
        guard normalized.isEmpty == false else { return }
        var updated = toolGroupShortcuts
        if let existingGroupID = updated.first(where: { $0.value == normalized })?.key,
           existingGroupID != group.id {
            let previous = updated[group.id]
            updated[existingGroupID] = previous
        }
        updated[group.id] = normalized
        toolGroupShortcuts = updated
        persist()
    }

    func toolGroup(forShortcutKey key: String) -> ToolSidebarGroup? {
        let normalized = key.uppercased()
        guard let groupID = toolGroupShortcuts.first(where: { $0.value == normalized })?.key else {
            return nil
        }
        return ToolSidebarGroup.orderedGroups.first(where: { $0.id == groupID })
    }

    func shortcutDisplayTitle(for group: ToolSidebarGroup) -> String {
        shortcutKey(for: group) ?? "未设置"
    }

    private static var defaultToolGroupShortcuts: [String: String] {
        Dictionary(
            uniqueKeysWithValues: ToolSidebarGroup.orderedGroups.compactMap { group in
                guard let shortcutKey = group.shortcutKey else { return nil }
                return (group.id, shortcutKey.uppercased())
            }
        )
    }

    private static func migratedToolGroupShortcuts(from raw: [String: String]) -> [String: String] {
        let cropGroupID = "canvas-crop"
        let oldDefault = "X"
        let newDefault = "C"
        guard raw[cropGroupID]?.uppercased() == oldDefault else {
            return raw
        }

        var migrated = raw
        if let conflictingGroupID = migrated.first(where: {
            $0.key != cropGroupID && $0.value.uppercased() == newDefault
        })?.key {
            migrated[conflictingGroupID] = oldDefault
        }
        migrated[cropGroupID] = newDefault
        return migrated
    }

    private static func normalizedToolGroupShortcuts(from raw: [String: String]) -> [String: String] {
        var resolved = defaultToolGroupShortcuts
        var used: Set<String> = []
        for group in ToolSidebarGroup.orderedGroups where group.shortcutKey != nil {
            let fallback = defaultToolGroupShortcuts[group.id] ?? ""
            let candidate = raw[group.id]?.uppercased() ?? fallback
            if candidate.isEmpty || used.contains(candidate) {
                resolved[group.id] = fallback
                used.insert(fallback)
            } else {
                resolved[group.id] = candidate
                used.insert(candidate)
            }
        }
        return resolved
    }
}

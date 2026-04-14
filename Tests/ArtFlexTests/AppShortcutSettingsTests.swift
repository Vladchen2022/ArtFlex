import AppKit
import Foundation
import Testing
@testable import ArtFlex

struct AppShortcutSettingsTests {
    @Test
    func defaultQuickColorPickerShortcutUsesShiftZ() {
        let shortcut = AppKeyboardShortcut.defaultQuickColorPicker

        #expect(shortcut.normalizedKey == "Z")
        #expect(shortcut.usesShift == true)
        #expect(shortcut.usesCommand == false)
        #expect(shortcut.displayString == "Shift+Z")
    }

    @Test
    @MainActor
    func shortcutSettingsStorePersistsQuickColorPickerShortcut() {
        let suiteName = "ArtFlexTests.AppShortcutSettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let store = AppShortcutSettingsStore(userDefaults: defaults)
        store.quickColorPickerShortcut = AppKeyboardShortcut(
            key: "Q",
            usesCommand: true,
            usesShift: false,
            usesOption: true,
            usesControl: false
        )
        store.persist()

        let restored = AppShortcutSettingsStore(userDefaults: defaults)
        #expect(restored.quickColorPickerShortcut == store.quickColorPickerShortcut)
    }

    @Test
    @MainActor
    func toolGroupShortcutAssignmentsStayUniqueAndPersist() {
        let suiteName = "ArtFlexTests.AppShortcutSettings.ToolGroups.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let store = AppShortcutSettingsStore(userDefaults: defaults)
        let brushGroup = ToolSidebarGroup.orderedGroups.first { $0.id == "brush" }!
        let eraserGroup = ToolSidebarGroup.orderedGroups.first { $0.id == "eraser" }!

        let originalBrushShortcut = store.shortcutKey(for: brushGroup)
        let originalEraserShortcut = store.shortcutKey(for: eraserGroup)

        store.setShortcutKey(originalEraserShortcut!, for: brushGroup)

        #expect(store.shortcutKey(for: brushGroup) == originalEraserShortcut)
        #expect(store.shortcutKey(for: eraserGroup) == originalBrushShortcut)

        let restored = AppShortcutSettingsStore(userDefaults: defaults)
        #expect(restored.shortcutKey(for: brushGroup) == originalEraserShortcut)
        #expect(restored.shortcutKey(for: eraserGroup) == originalBrushShortcut)
    }
}

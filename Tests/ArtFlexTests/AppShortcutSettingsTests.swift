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
    func defaultOilPaintShortcutsUseDAndShiftD() {
        #expect(AppKeyboardShortcut.defaultOilPaintLoad.displayString == "D")
        #expect(AppKeyboardShortcut.defaultOilPaintWash.displayString == "Shift+D")
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
    func shortcutSettingsStorePersistsOilPaintShortcuts() {
        let suiteName = "ArtFlexTests.AppShortcutSettings.OilPaint.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let store = AppShortcutSettingsStore(userDefaults: defaults)
        store.oilPaintLoadShortcut = AppKeyboardShortcut(key: "L", usesOption: true)
        store.oilPaintWashShortcut = AppKeyboardShortcut(key: "W", usesControl: true)
        store.persist()

        let restored = AppShortcutSettingsStore(userDefaults: defaults)
        #expect(restored.oilPaintLoadShortcut == store.oilPaintLoadShortcut)
        #expect(restored.oilPaintWashShortcut == store.oilPaintWashShortcut)
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

    @Test
    @MainActor
    func textureFillUsesTheMergedLassoFillShortcutGroup() {
        let suiteName = "ArtFlexTests.AppShortcutSettings.TextureFill.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let store = AppShortcutSettingsStore(userDefaults: defaults)
        let lassoFillGroup = ToolSidebarGroup.orderedGroups.first { $0.id == "lasso-fill" }!

        #expect(store.configurableToolGroups.contains(lassoFillGroup))
        #expect(lassoFillGroup.tools == [.lassoFill, .textureFill])
        #expect(store.shortcutKey(for: lassoFillGroup) == "K")
        #expect(store.toolGroup(forShortcutKey: "F") == nil)
    }

    @Test
    @MainActor
    func perspectiveToolIsRegisteredWithDefaultPShortcut() {
        let store = AppShortcutSettingsStore(
            userDefaults: UserDefaults(suiteName: "ArtFlexTests.Perspective.\(UUID().uuidString)")!
        )
        let group = ToolSidebarGroup.orderedGroups.first { $0.id == "perspective" }

        #expect(group?.tools == [.perspective])
        #expect(group.flatMap { store.shortcutKey(for: $0) } == "P")
        #expect(ToolKind.perspective.displayName == "透视")
    }

    @Test
    @MainActor
    func canvasCropUsesCAndMigratesThePreviousXDefault() throws {
        let suiteName = "ArtFlexTests.CanvasCropShortcut.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let rawShortcuts = [
            "brush": "C",
            "canvas-crop": "X"
        ]
        defaults.set(
            try JSONEncoder().encode(rawShortcuts),
            forKey: "ArtFlex.Settings.Shortcuts.ToolGroups"
        )

        let store = AppShortcutSettingsStore(userDefaults: defaults)
        let brushGroup = ToolSidebarGroup.orderedGroups.first { $0.id == "brush" }!
        let cropGroup = ToolSidebarGroup.orderedGroups.first { $0.id == "canvas-crop" }!

        #expect(ToolKind.canvasCrop.shortcutKey == "C")
        #expect(cropGroup.shortcutKey == "C")
        #expect(store.shortcutKey(for: cropGroup) == "C")
        #expect(store.shortcutKey(for: brushGroup) == "X")
        #expect(store.toolGroup(forShortcutKey: "C") == cropGroup)
    }
}

import AppKit
import Foundation
import Testing
@testable import ArtFlex

struct BrushTipEditingAndNavigatorTests {
    @Test
    @MainActor
    func workspaceKeyboardBridgeDoesNotStealFocusFromBrushTipEditor() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        let bridge = KeyboardBridgeView(frame: .zero)
        let brushTipEditor = TestWorkspaceKeyboardFocusOwner(frame: .zero)
        container.addSubview(bridge)
        container.addSubview(brushTipEditor)
        window.contentView = container

        #expect(window.makeFirstResponder(brushTipEditor))
        bridge.activateIfNeeded()

        #expect(window.firstResponder === brushTipEditor)
    }

    @Test
    @MainActor
    func workspaceKeyboardBridgePreservesControlsAndLeavesTabNavigationToThem() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        let bridge = KeyboardBridgeView(frame: .zero)
        let slider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
        container.addSubview(bridge)
        container.addSubview(slider)
        window.contentView = container

        #expect(window.makeFirstResponder(slider))
        bridge.activateIfNeeded()

        #expect(window.firstResponder === slider)
        #expect(bridge.shouldAllowWorkspaceChromeToggle(for: slider) == false)
        #expect(bridge.shouldAllowWorkspaceChromeToggle(for: bridge))

        bridge.recordWorkspacePointerInteraction(isCanvasInteraction: false)
        #expect(bridge.shouldAllowWorkspaceChromeToggle(for: bridge) == false)

        var handledTab = false
        bridge.keyDownHandler = { _ in
            handledTab = true
            return true
        }
        let tab = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\t",
            charactersIgnoringModifiers: "\t",
            isARepeat: false,
            keyCode: 48
        )!
        bridge.keyDown(with: tab)
        #expect(handledTab == false)

        let brushShortcut = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "b",
            charactersIgnoringModifiers: "b",
            isARepeat: false,
            keyCode: 11
        )!
        #expect(bridge.shouldForwardWorkspaceShortcutFromControl(brushShortcut, responder: slider))
    }

    @Test
    @MainActor
    func installedWorkspaceKeyboardBridgePairsOnlyForwardedSliderSpaceKeyUp() {
        let application = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let otherWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        let bridge = KeyboardBridgeView(frame: .zero)
        let slider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
        container.addSubview(bridge)
        container.addSubview(slider)
        window.contentView = container
        defer {
            window.contentView = NSView()
            window.orderOut(nil)
            otherWindow.orderOut(nil)
        }

        var forwardedKeyDowns: [UInt16] = []
        var forwardedKeyUps: [UInt16] = []
        var isModalSpaceActive = false
        bridge.keyDownHandler = { event in
            forwardedKeyDowns.append(event.keyCode)
            if event.keyCode == 49 {
                isModalSpaceActive = true
            }
            return true
        }
        bridge.keyUpHandler = { event in
            forwardedKeyUps.append(event.keyCode)
            if event.keyCode == 49 {
                isModalSpaceActive = false
            }
            return true
        }

        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(slider))

        application.sendEvent(makeBridgeKeyEvent(type: .keyUp, character: " ", keyCode: 49, window: window))
        #expect(forwardedKeyUps.isEmpty)

        for (character, keyCode) in [("b", UInt16(11)), ("e", UInt16(14)), ("g", UInt16(5))] {
            application.sendEvent(
                makeBridgeKeyEvent(type: .keyDown, character: character, keyCode: keyCode, window: window)
            )
            application.sendEvent(
                makeBridgeKeyEvent(type: .keyUp, character: character, keyCode: keyCode, window: window)
            )
        }
        #expect(forwardedKeyDowns == [11, 14, 5])
        #expect(forwardedKeyUps.isEmpty)

        application.sendEvent(makeBridgeKeyEvent(type: .keyDown, character: " ", keyCode: 49, window: window))
        #expect(isModalSpaceActive)
        application.sendEvent(makeBridgeKeyEvent(type: .keyUp, character: " ", keyCode: 49, window: otherWindow))
        #expect(isModalSpaceActive)
        #expect(forwardedKeyUps.isEmpty)
        application.sendEvent(makeBridgeKeyEvent(type: .keyUp, character: " ", keyCode: 49, window: window))

        #expect(!isModalSpaceActive)
        #expect(forwardedKeyDowns == [11, 14, 5, 49])
        #expect(forwardedKeyUps == [49])
    }

    @Test
    func brushSizeShortcutUsesTheSameProgressiveStepsAcrossEditors() {
        #expect(BrushSizeShortcut.step(for: 2) == 1)
        #expect(BrushSizeShortcut.step(for: 10) == 1)
        #expect(BrushSizeShortcut.step(for: 11) == 5)
        #expect(BrushSizeShortcut.step(for: 51) == 10)
        #expect(BrushSizeShortcut.step(for: 101) == 25)
        #expect(BrushSizeShortcut.step(for: 201) == 50)
        #expect(BrushSizeShortcut.step(for: 301) == 100)
    }

    @Test
    func brushSizeShortcutRecognizesPhysicalBracketKeysWithoutTextInput() {
        let leftBracket = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 33
        )!
        let rightBracket = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 30
        )!

        #expect(brushSizeShortcutDirection(for: leftBracket) == -1)
        #expect(brushSizeShortcutDirection(for: rightBracket) == 1)
    }

    @Test
    @MainActor
    func mainCanvasAppliesPhysicalBrushSizeShortcutsWithoutTextInput() {
        let view = StrokeCaptureMTKView(
            frame: .init(x: 0, y: 0, width: 320, height: 240),
            device: nil
        )
        view.brushSize = 24

        let increase = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 30
        )!
        view.keyDown(with: increase)
        #expect(view.displayBrushSize == 29)

        let decrease = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 33
        )!
        view.keyDown(with: decrease)
        #expect(view.displayBrushSize == 24)
    }

    @Test
    func brushTipDraftHistorySupportsBoundedUndoRedoAndBranching() {
        let baseline = BrushTipDraftSnapshot.procedural
        let first = BrushTipDraftSnapshot(
            maskData: Data([1]),
            sourceSemantic: .customMask,
            assetID: nil,
            sourceInfo: nil
        )
        let second = BrushTipDraftSnapshot(
            maskData: Data([2]),
            sourceSemantic: .customMask,
            assetID: nil,
            sourceInfo: nil
        )
        var history = BrushTipDraftHistory(capacity: 2)

        history.record(current: baseline, next: first)
        history.record(current: first, next: second)
        #expect(history.canUndo)
        #expect(history.undo(current: second) == first)
        #expect(history.canRedo)
        #expect(history.redo(current: first) == second)

        _ = history.undo(current: second)
        history.record(current: first, next: baseline)
        #expect(!history.canRedo)
    }

    @Test
    func logarithmicNavigatorZoomRoundTripsRepresentativeValues() {
        for percent in [5.0, 25, 100, 400, 3200] {
            let position = NavigatorZoomMapping.sliderPosition(for: percent)
            let restored = NavigatorZoomMapping.percent(forSliderPosition: position)
            #expect(abs(restored - percent) < 0.000_001)
        }
        #expect(NavigatorZoomMapping.sliderPosition(for: 5) == 0)
        #expect(abs(NavigatorZoomMapping.sliderPosition(for: 3200) - 1) < 0.000_001)
    }

    @Test
    func navigatorPolygonClipsEdgesWithoutCollapsingRotatedCorners() {
        let clipped = NavigatorGeometry.clippedCanvasPolygon(
            [
                .init(x: -20, y: 30),
                .init(x: 40, y: -20),
                .init(x: 120, y: 60),
                .init(x: 40, y: 120)
            ],
            canvasSize: .init(width: 100, height: 100)
        )

        #expect(clipped.count >= 4)
        #expect(clipped.allSatisfy { $0.x >= 0 && $0.x <= 100 && $0.y >= 0 && $0.y <= 100 })
        #expect(clipped.contains { abs($0.x) < 0.000_001 })
        #expect(clipped.contains { abs($0.y) < 0.000_001 })
        #expect(clipped.contains { abs($0.x - 100) < 0.000_001 })
        #expect(clipped.contains { abs($0.y - 100) < 0.000_001 })
    }

    @Test
    func navigatorPolygonReturnsEmptyWhenViewportMissesCanvas() {
        let clipped = NavigatorGeometry.clippedCanvasPolygon(
            [
                .init(x: -100, y: -100),
                .init(x: -20, y: -100),
                .init(x: -20, y: -20),
                .init(x: -100, y: -20)
            ],
            canvasSize: .init(width: 100, height: 100)
        )
        #expect(clipped.isEmpty)
    }
}

@MainActor
private final class TestWorkspaceKeyboardFocusOwner: NSView, WorkspaceKeyboardFocusOwner {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
private func makeBridgeKeyEvent(
    type: NSEvent.EventType,
    character: String,
    keyCode: UInt16,
    window: NSWindow
) -> NSEvent {
    NSEvent.keyEvent(
        with: type,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: character,
        charactersIgnoringModifiers: character,
        isARepeat: false,
        keyCode: keyCode
    )!
}

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

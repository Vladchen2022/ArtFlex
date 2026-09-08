import AppKit
import SwiftUI
import Testing
@testable import ArtFlex

/// The command-line test host cannot activate like a bundled GUI app. Supply
/// key-window ownership explicitly, without activating over the user's artwork.
private final class InputTestWindow: NSWindow {
    var ownsInput = true
    override var isKeyWindow: Bool { ownsInput }
}

@MainActor
@Suite(.serialized)
struct BlockReferenceWindowInputTests {
    private func middleEvent(_ type: NSEvent.EventType, in window: NSWindow,
                             at point: NSPoint, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let source = try #require(NSEvent.mouseEvent(with: type, location: point,
            modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1,
            clickCount: 1, pressure: type == .otherMouseUp ? 0 : 1))
        let cg = try #require(source.cgEvent)
        cg.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        let event = try #require(NSEvent(cgEvent: cg))
        #expect(event.buttonNumber == 2)
        #expect(event.windowNumber == window.windowNumber)
        #expect(event.locationInWindow == point)
        return event
    }

    @Test func middleDragThroughCanvasWindowChangesObservation() async throws {
        _ = NSApplication.shared
        let vm = WorkspaceViewModel(bootstrap: try AppBootstrap(), installsZoomKeyboardMonitor: false,
                                    preparesInitialTextures: false)
        vm.selectTool(.blockReference)
        vm.createEmptyBlockReferenceScene()
        _ = vm.updateBlockReferenceDocument {
            $0?.objects = [BlockReferenceObject(name: "Input test", kind: .box,
                position: .zero, dimensions: .stageOneDefault)]
            $0?.display.isFrozen = true
        }
        let original = vm.workspace.document
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 600, height: 450),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: MainWindowView(viewModel: vm,
            presentationState: AppPresentationState(), onCanvasReady: {}))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(150))
        let point = NSPoint(x: 300, y: 200)
        let hit = host.hitTest(point)
        #expect(hit is BlockReferenceInteractionView)
        window.makeKeyAndOrderFront(nil)
        NSApp.sendEvent(try middleEvent(.otherMouseDown, in: window, at: point))
        #expect(vm.isBlockReferenceCameraNavigating)
        try await Task.sleep(for: .milliseconds(100))
        NSApp.sendEvent(try middleEvent(.otherMouseDragged, in: window, at: NSPoint(x: 370, y: 225)))
        #expect(vm.blockReferenceScene?.camera != original.blockReferenceScene?.camera)
        try await Task.sleep(for: .milliseconds(100))
        NSApp.sendEvent(try middleEvent(.otherMouseUp, in: window, at: NSPoint(x: 370, y: 225)))
        #expect(!vm.isBlockReferenceCameraNavigating)
        #expect(vm.workspace.document == original)
    }

    private func auxiliaryMiddleEvent(in window: NSWindow, at point: NSPoint, down: Bool) throws -> NSEvent {
        try #require(NSEvent.otherEvent(with: .systemDefined,
            location: window.convertPoint(toScreen: point), modifierFlags: .shift,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            subtype: 7, data1: 4, data2: down ? 4 : 0))
    }

    private func windowlessMiddleEvent(_ type: NSEvent.EventType, in window: NSWindow,
                                      at point: NSPoint) throws -> NSEvent {
        let raw = try #require(NSEvent.mouseEvent(with: type,
            location: window.convertPoint(toScreen: point), modifierFlags: .shift,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
            context: nil, eventNumber: 1, clickCount: 0, pressure: type == .otherMouseUp ? 0 : 1))
        let cg = try #require(raw.cgEvent)
        cg.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        let event = try #require(NSEvent(cgEvent: cg))
        #expect(event.window == nil)
        return event
    }

    @Test func windowlessAuxiliaryButtonAndDragReachThe3DView() throws {
        _ = NSApplication.shared
        let window = InputTestWindow(contentRect: NSRect(x: 310, y: 220, width: 600, height: 450),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = BlockReferenceInteractionView(frame: NSRect(x: 0, y: 0, width: 600, height: 450))
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        var modes: [BlockReferenceNavigationMode] = []
        var changes: [CGPoint] = []
        var ends = 0
        view.onNavigationBegan = { modes.append($0) }
        view.onNavigationChanged = { _, x, y in changes.append(CGPoint(x: x, y: y)) }
        view.onNavigationEnded = { ends += 1 }
        let start = NSPoint(x: 200, y: 180)
        NSApp.sendEvent(try auxiliaryMiddleEvent(in: window, at: start, down: true))
        #expect(modes == [.pan])
        // Actual driver trace: no event.window, screen coordinates, buttonNumber 2.
        let moved = NSPoint(x: 270, y: 205)
        NSApp.sendEvent(try windowlessMiddleEvent(.otherMouseDragged, in: window, at: moved))
        #expect(changes.last == CGPoint(x: 70, y: -25))
        NSApp.sendEvent(try auxiliaryMiddleEvent(in: window, at: moved, down: false))
        #expect(ends == 1)
    }

    private func withCapture(_ body: (InputTestWindow, NSView, BlockReferenceMiddleMouseCapture) throws -> Void) rethrows {
        _ = NSApplication.shared
        let window = InputTestWindow(contentRect: NSRect(x: 310, y: 220, width: 600, height: 450),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 450))
        let view = NSView(frame: NSRect(x: 60, y: 40, width: 400, height: 300))
        root.addSubview(view)
        window.contentView = root
        window.orderFront(nil)
        let capture = BlockReferenceMiddleMouseCapture()
        capture.install(for: view)
        defer { capture.stop(); window.contentView = nil; window.close() }
        try body(window, view, capture)
    }

    @Test func duplicateDownAndMixedPenContactMakeOneNavigationTransaction() throws {
        try withCapture { window, _, capture in
            var begins = 0, ends = 0, moves = 0
            capture.onBegan = { _, _ in begins += 1 }
            capture.onChanged = { _ in moves += 1 }
            capture.onEnded = { ends += 1 }
            let point = NSPoint(x: 200, y: 180)
            #expect(try capture.handle(auxiliaryMiddleEvent(in: window, at: point, down: true)) == nil)
            #expect(try capture.handle(middleEvent(.otherMouseDown, in: window, at: point)) == nil)
            #expect(begins == 1)
            for type: NSEvent.EventType in [.leftMouseDown, .leftMouseDragged] {
                let contact = try #require(NSEvent.mouseEvent(with: type, location: point,
                    modifierFlags: .shift, timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 0.7))
                #expect(capture.handle(contact) == nil)
            }
            #expect(moves == 1)
            #expect(try capture.handle(windowlessMiddleEvent(.otherMouseUp, in: window, at: point)) == nil)
            #expect(!capture.isCapturing)
            #expect(ends == 1)
            let contactUp = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
            #expect(capture.handle(contactUp) == nil)
            _ = try capture.handle(auxiliaryMiddleEvent(in: window, at: point, down: false))
            #expect(ends == 1)
        }
    }

    @Test func orphanWindowlessDragRecoversButUnownedRegionAndInactiveWindowDoNot() throws {
        try withCapture { window, _, capture in
            let outside = try windowlessMiddleEvent(.otherMouseDragged, in: window, at: NSPoint(x: 540, y: 200))
            #expect(capture.handle(outside) === outside)
            #expect(!capture.isCapturing)
            window.ownsInput = false
            let inside = try windowlessMiddleEvent(.otherMouseDragged, in: window, at: NSPoint(x: 200, y: 180))
            #expect(capture.handle(inside) === inside)
            window.ownsInput = true
            #expect(capture.handle(inside) == nil)
            #expect(capture.isCapturing)
            // Once owned, moving outside keeps the gesture; it cannot get stuck at an edge.
            #expect(capture.handle(outside) == nil)
        }
    }

    @Test func controlsOtherButtonsAndForeignWindowsAreNotCaptured() throws {
        try withCapture { window, view, capture in
            let field = NSTextField(frame: NSRect(x: 100, y: 100, width: 120, height: 24))
            view.addSubview(field)
            let overField = view.convert(NSPoint(x: 150, y: 110), to: nil)
            let blocked = try auxiliaryMiddleEvent(in: window, at: overField, down: true)
            #expect(capture.handle(blocked) === blocked)
            let side = try #require(NSEvent.otherEvent(with: .systemDefined,
                location: window.convertPoint(toScreen: NSPoint(x: 200, y: 180)), modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, subtype: 7, data1: 8, data2: 8))
            #expect(capture.handle(side) === side)
            let foreign = NSWindow(contentRect: window.frame, styleMask: [.titled], backing: .buffered, defer: false)
            foreign.isReleasedWhenClosed = false
            defer { foreign.close() }
            let event = try middleEvent(.otherMouseDown, in: foreign, at: NSPoint(x: 200, y: 180))
            #expect(capture.handle(event) === event)
            #expect(!capture.isCapturing)
        }
    }

    @Test func focusLossAndOverlayRemovalAlwaysFinishCapture() throws {
        try withCapture { window, _, capture in
            var ends = 0
            capture.onEnded = { ends += 1 }
            let event = try auxiliaryMiddleEvent(in: window, at: NSPoint(x: 200, y: 180), down: true)
            _ = capture.handle(event)
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
            #expect(!capture.isCapturing)
            #expect(ends == 1)
            _ = capture.handle(event)
            capture.stop()
            #expect(!capture.isCapturing)
            #expect(ends == 2)
            #expect(capture.handle(event) === event)
        }
    }

    @Test func middlePressInInspectorCannotTurnInto3DNavigationWhenDraggedInside() throws {
        try withCapture { window, _, capture in
            let down = try auxiliaryMiddleEvent(in: window, at: NSPoint(x: 550, y: 180), down: true)
            #expect(capture.handle(down) === down)
            let drag = try windowlessMiddleEvent(.otherMouseDragged, in: window, at: NSPoint(x: 200, y: 180))
            #expect(capture.handle(drag) === drag)
            #expect(!capture.isCapturing)
            _ = try capture.handle(auxiliaryMiddleEvent(in: window, at: NSPoint(x: 200, y: 180), down: false))
            #expect(try capture.handle(auxiliaryMiddleEvent(in: window, at: NSPoint(x: 200, y: 180), down: true)) == nil)
            #expect(capture.isCapturing)
        }
    }

    @Test func nativeWindowDispatchesMiddleButtonWithoutPriorLeftClick() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 600, height: 450),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = BlockReferenceInteractionView(frame: NSRect(x: 0, y: 0, width: 600, height: 450))
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        window.orderFront(nil)
        window.resignKey()
        var began = false
        view.onNavigationBegan = { _ in began = true }
        window.sendEvent(try middleEvent(.otherMouseDown, in: window, at: NSPoint(x: 300, y: 200)))
        #expect(began)
        window.sendEvent(try middleEvent(.otherMouseUp, in: window, at: NSPoint(x: 300, y: 200)))
    }
}

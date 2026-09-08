import AppKit
import Testing
@testable import ArtFlex

@MainActor
struct BlockReferenceNavigationTests {
    private func model(locked: Bool = false) throws -> WorkspaceViewModel {
        let vm = WorkspaceViewModel(bootstrap: try AppBootstrap(), installsZoomKeyboardMonitor: false, preparesInitialTextures: false)
        vm.selectTool(.blockReference)
        vm.createEmptyBlockReferenceScene()
        let object = BlockReferenceObject(name: "Navigation test", kind: .box,
            position: .init(x: 80, y: 20, z: 50), dimensions: .stageOneDefault)
        _ = vm.updateBlockReferenceDocument { $0?.objects = [object]; $0?.display.isFrozen = locked }
        vm.selectBlockReferenceObject(object.id, extending: false)
        return vm
    }

    private func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], characters: String = "") throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    @Test func frozenCompositionAutomaticallyAllowsNavigationWithoutEditingDocument() throws {
        let vm = try model(locked: true)
        let original = vm.workspace.document
        vm.beginBlockReferenceCameraNavigation(.orbit)
        vm.updateBlockReferenceCameraNavigation(mode: .orbit, deltaX: 80, deltaY: 30, screenScale: 1)
        vm.endBlockReferenceCameraNavigation()
        #expect(vm.blockReferenceScene?.camera != original.blockReferenceScene?.camera)
        #expect(vm.workspace.document == original)
        vm.zoomBlockReferenceCamera(by: 0.7)
        vm.commitPendingBlockReferenceCameraZoom()
        vm.frameBlockReferenceCamera(selectedOnly: false)
        vm.setBlockReferenceOrthographic(true)
        #expect(vm.workspace.document == original)
        #expect(vm.blockReferenceScene?.camera.isOrthographic == true)
        vm.returnToBlockReferenceComposition()
        #expect(vm.blockReferenceScene == original.blockReferenceScene)
    }

    @Test func numpadNavigationWorksInLockedInspectionButModelShortcutsDoNot() throws {
        let vm = try model(locked: true)
        let original = vm.workspace.document
        #expect(vm.handleBlockReferenceKeyDown(try key(83))) // Front
        #expect(vm.blockReferenceScene?.camera.yawDegrees == -90)
        #expect(vm.blockReferenceScene?.camera.isOrthographic == true)
        #expect(vm.handleBlockReferenceKeyDown(try key(83, .control))) // Back
        #expect(vm.blockReferenceScene?.camera.yawDegrees == 90)
        #expect(vm.handleBlockReferenceKeyDown(try key(86))) // Orbit left
        #expect(vm.blockReferenceScene?.camera.yawDegrees != 90)
        let beforePan = vm.blockReferenceScene?.camera.target
        #expect(vm.handleBlockReferenceKeyDown(try key(91, .control))) // Pan up
        #expect(vm.blockReferenceScene?.camera.target != beforePan)
        let beforeZoom = try #require(vm.blockReferenceScene?.camera.distance)
        #expect(vm.handleBlockReferenceKeyDown(try key(69))) // +
        vm.commitPendingBlockReferenceCameraZoom()
        #expect(try #require(vm.blockReferenceScene?.camera.distance) < beforeZoom)
        #expect(vm.handleBlockReferenceKeyDown(try key(65))) // Frame selection
        #expect(!vm.handleBlockReferenceKeyDown(try key(5, characters: "g")))
        #expect(vm.workspace.document == original)
    }

    @Test func nearTopViewHasNoSuddenBasisFlip() {
        var camera = BlockReferenceCamera.stageOneDefault
        camera.yawDegrees = -90
        camera.pitchDegrees = 84
        let before = blockCameraBasis(camera)
        camera.pitchDegrees = 85
        let after = blockCameraBasis(camera)
        #expect(before.right.dot(after.right) > 0.999)
    }

    @Test func frameSelectionWithNothingSelectedDoesNotResetCamera() throws {
        let vm = try model()
        vm.deselectAllBlockReferenceObjects()
        vm.setBlockReferenceCameraView(yaw: 20, pitch: 35)
        let camera = vm.blockReferenceScene?.camera
        vm.frameBlockReferenceCamera(selectedOnly: true)
        #expect(vm.blockReferenceScene?.camera == camera)
    }

    @Test func liveDragCameraIsClampedBeforeRendering() throws {
        let vm = try model()
        vm.beginBlockReferenceCameraNavigation(.orbit)
        vm.updateBlockReferenceCameraNavigation(mode: .orbit, deltaX: 10000, deltaY: 10000, screenScale: 1)
        let preview = try #require(vm.blockReferenceScene?.camera)
        #expect(abs(preview.pitchDegrees) <= 89.9)
        #expect(abs(preview.yawDegrees) <= 360)
        vm.endBlockReferenceCameraNavigation()
        #expect(vm.blockReferenceScene?.camera == preview)
    }

    @Test func middleButtonAndTrackpadUseBlenderModifierPriority() throws {
        #expect(BlockReferenceInteractionView.navigationMode(for: []) == .orbit)
        #expect(BlockReferenceInteractionView.navigationMode(for: .shift) == .pan)
        #expect(BlockReferenceInteractionView.navigationMode(for: .control) == .zoom)
        #expect(BlockReferenceInteractionView.navigationMode(for: [.shift, .control]) == .dolly)
        let view = BlockReferenceInteractionView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        var modes: [BlockReferenceNavigationMode] = []
        var changes: [CGPoint] = []
        var ends = 0
        view.onNavigationBegan = { modes.append($0) }
        view.onNavigationChanged = { _, x, y in changes.append(CGPoint(x: x, y: y)) }
        view.onNavigationEnded = { ends += 1 }
        view.updateScrollNavigation(deltaX: 10, deltaY: 4, modifiers: [])
        view.updateScrollNavigation(deltaX: 20, deltaY: 6, modifiers: [])
        #expect(modes == [.orbit])
        #expect(changes.last == CGPoint(x: 30, y: 10))
        #expect(ends == 0)
        view.updateScrollNavigation(deltaX: 5, deltaY: 6, modifiers: .shift)
        #expect(modes == [.orbit, .pan])
        #expect(changes.last == CGPoint(x: 5, y: 6))
        #expect(ends == 1)
        view.finishScrollNavigation()
        view.finishScrollNavigation()
        #expect(ends == 2)
    }

    @Test func optionModifierOverridesSelectedLeftNavigationTool() throws {
        let view = BlockReferenceInteractionView()
        view.primaryNavigationMode = .orbit
        var mode: BlockReferenceNavigationMode?
        view.onNavigationBegan = { mode = $0 }
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
            modifierFlags: [.option, .shift], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        view.mouseDown(with: event)
        #expect(mode == .pan)
        view.mouseUp(with: event)
    }

    @Test func trackpadGestureCommitsOneUndoAndDoesNotMoveObjects() throws {
        let vm = try model()
        let original = vm.workspace.document.blockReferenceScene
        let view = BlockReferenceInteractionView()
        view.onNavigationBegan = vm.beginBlockReferenceCameraNavigation
        view.onNavigationChanged = { vm.updateBlockReferenceCameraNavigation(mode: $0, deltaX: $1, deltaY: $2, screenScale: 1) }
        view.onNavigationEnded = vm.endBlockReferenceCameraNavigation
        for _ in 0..<40 { view.updateScrollNavigation(deltaX: 2, deltaY: 1, modifiers: []) }
        #expect(vm.workspace.document.blockReferenceScene == original)
        view.finishScrollNavigation()
        #expect(vm.workspace.document.blockReferenceScene?.camera != original?.camera)
        #expect(vm.workspace.document.blockReferenceScene?.objects == original?.objects)
        vm.undo()
        #expect(vm.workspace.document.blockReferenceScene == original)
        vm.redo()
        #expect(vm.workspace.document.blockReferenceScene?.camera != original?.camera)
    }

    @Test func panFollowsScreenWhenCanvasRotatedAndMirrored() throws {
        let vm = try model()
        vm.setViewportRotation(90)
        vm.toggleCanvasHorizontalFlip()
        let transform = CanvasViewportTransform(canvasSize: vm.workspace.document.canvasSize,
            viewport: vm.workspace.viewport, availableWidth: 900, availableHeight: 700)
        let original = try #require(vm.blockReferenceScene?.camera)
        let before = try #require(projectBlockPoint(original.target, camera: original,
            canvasSize: vm.workspace.document.canvasSize)?.canvasPoint)
        vm.beginBlockReferenceCameraNavigation(.pan)
        vm.updateBlockReferenceCameraNavigation(mode: .pan, deltaX: 60, deltaY: 35, screenScale: transform.actualDisplayScale)
        let movedCamera = try #require(vm.blockReferenceScene?.camera)
        let after = try #require(projectBlockPoint(original.target, camera: movedCamera,
            canvasSize: vm.workspace.document.canvasSize)?.canvasPoint)
        let p = transform.canvasToViewport(before), q = transform.canvasToViewport(after)
        #expect(abs(q.x - p.x - 60) < 0.01)
        #expect(abs(q.y - p.y - 35) < 0.01)
        vm.endBlockReferenceCameraNavigation()
    }
}

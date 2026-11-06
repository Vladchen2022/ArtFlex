import AppKit
import Metal
import Testing
@testable import ArtFlex

@Suite(.serialized)
@MainActor
struct PaintingConvenienceTests {
    @Test(arguments: [("e", UInt16(14), ToolKind.eraser), ("t", 17, .smudge), ("r", 15, .canvasRotate)])
    func tapSelectsAndHoldRestoresToolAndBrush(shortcut: (String, UInt16, ToolKind)) throws {
        let h = try ConvenienceHarness(); defer { h.cleanUp() }
        let (key, code, tool) = shortcut
        h.vm.setBrushSize(37); h.vm.setBrushOpacity(0.42)
        let original = h.vm.workspace.toolSession.brush
        #expect(h.vm.handleKeyDown(keyEvent(key, code, at: 10)))
        #expect(h.vm.workspace.toolSession.activeTool == tool)
        #expect(h.vm.handleKeyUp(keyEvent(key, code, at: 10.1, up: true)))
        #expect(h.vm.workspace.toolSession.activeTool == tool)
        h.vm.selectTool(.brush)
        #expect(h.vm.handleKeyDown(keyEvent(key, code, at: 20)))
        #expect(h.vm.handleKeyDown(keyEvent(key, code, at: 20.4, repeated: true)))
        #expect(h.vm.handleKeyUp(keyEvent(key, code, at: 20.5, up: true)))
        #expect(h.vm.workspace.toolSession.activeTool == .brush)
        #expect(h.vm.workspace.toolSession.brush == original)
        #expect(h.vm.momentaryTools.state == nil)
    }

    @Test func releaseDuringStrokeWaitsForEndAndPreservesOneUndoableErase() async throws {
        let h = try ConvenienceHarness(); defer { h.cleanUp() }
        try h.fill(h.layerID, color: .init(red: 1, green: 0, blue: 0, alpha: 1))
        let before = try h.snapshot(h.layerID)
        let history = h.bootstrap.historyController.currentStateID
        #expect(h.vm.handleKeyDown(keyEvent("e", 14, at: 1)))
        h.vm.setBrushSize(20)
        h.vm.momentaryTools.pointerChanged(isDown: true)
        h.vm.beginStrokeIfNeeded()
        h.vm.applyStroke(samples: [.init(location: .init(x: 20, y: 20), pressure: 1), .init(location: .init(x: 35, y: 20), pressure: 1)])
        #expect(h.vm.handleKeyUp(keyEvent("e", 14, at: 2, up: true)))
        #expect(h.vm.workspace.toolSession.activeTool == .eraser)
        h.vm.endStroke()
        h.vm.momentaryTools.pointerChanged(isDown: false)
        #expect(h.vm.workspace.toolSession.activeTool == .brush)
        _ = h.vm.flushBrushEditingBoundary(reason: "test")
        #expect(!h.vm.hasPendingBrushEdits)
        let erased = try h.snapshot(h.layerID)
        #expect(erased != before)
        #expect(h.bootstrap.historyController.currentStateID != history)
        h.vm.undo()
        for _ in 0..<500 where h.vm.isHistoryNavigating { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!h.vm.isHistoryNavigating)
        #expect(try h.snapshot(h.layerID) == before)
    }

    @Test func explicitChoiceFocusLossTabSwitchAndNestedKeysCannotLeaveTemporaryTool() throws {
        let h = try ConvenienceHarness(); defer { h.cleanUp() }
        _ = h.vm.handleKeyDown(keyEvent("e", 14, at: 1))
        h.vm.selectTool(.bucket)
        #expect(!h.vm.handleKeyUp(keyEvent("e", 14, at: 2, up: true)))
        #expect(h.vm.workspace.toolSession.activeTool == .bucket)
        h.vm.selectTool(.brush)
        _ = h.vm.handleKeyDown(keyEvent("t", 17, at: 3))
        h.vm.momentaryTools.focusLost()
        #expect(h.vm.workspace.toolSession.activeTool == .brush)
        _ = h.vm.handleKeyDown(keyEvent("r", 15, at: 4))
        h.vm.isSessionActive = false
        #expect(h.vm.workspace.toolSession.activeTool == .brush)
        h.vm.isSessionActive = true
        _ = h.vm.handleKeyDown(keyEvent("e", 14, at: 5))
        _ = h.vm.handleKeyDown(keyEvent("t", 17, at: 5.5))
        #expect(h.vm.workspace.toolSession.activeTool == .smudge)
        #expect(!h.vm.handleKeyUp(keyEvent("e", 14, at: 6, up: true)))
        #expect(h.vm.handleKeyUp(keyEvent("t", 17, at: 6.5, up: true)))
        #expect(h.vm.workspace.toolSession.activeTool == .brush)
    }

    @Test func maskTargetRestoresAndModalDraftOwnsKeyboard() throws {
        let h = try ConvenienceHarness(); defer { h.cleanUp() }
        h.vm.addMaskToActiveLayer(revealsAll: true)
        h.vm.selectLayerMask(h.layerID)
        _ = h.vm.handleKeyDown(keyEvent("r", 15, at: 1))
        _ = h.vm.handleKeyUp(keyEvent("r", 15, at: 2, up: true))
        #expect(h.vm.activeMaskEditingLayerID == h.layerID)
        h.vm.selectAllCanvas()
        h.vm.beginSelectionRefinementPreview(.feather)
        #expect(h.vm.hasModalEditSession)
        #expect(h.vm.handleKeyDown(keyEvent("e", 14, at: 3)))
        #expect(h.vm.workspace.toolSession.activeTool == .brush)
        #expect(h.vm.momentaryTools.state == nil)
        h.vm.cancelSelectionRefinementPreview()
    }

    @Test func nativeCanvasRoutesHeldKeysBeforeLegacyToolMap() throws {
        let h = try ConvenienceHarness(); defer { h.cleanUp() }
        let view = StrokeCaptureMTKView(frame: .init(x: 0, y: 0, width: 64, height: 64), device: h.bootstrap.metalContext.device)
        view.keyDownEventHandler = { h.vm.handleKeyDown($0) }
        view.keyDown(with: keyEvent("e", 14, at: 1))
        #expect(h.vm.momentaryTools.state?.tool == .eraser)
        _ = h.vm.handleKeyUp(keyEvent("e", 14, at: 2, up: true))
        #expect(h.vm.workspace.toolSession.activeTool == .brush)
    }

    @Test func canvasDrawingResumesWhenPopoverConsumesMouseUp() throws {
        let h = try ConvenienceHarness(); defer { h.cleanUp() }
        let view = StrokeCaptureMTKView(frame: .init(x: 0, y: 0, width: 64, height: 64), device: h.bootstrap.metalContext.device)
        view.canvasSize = .init(width: 64, height: 64)
        view.makeLayerPicker = { CanvasLayerPickerModel(viewModel: h.vm, point: $0) }
        var pointerStates: [Bool] = []
        view.pointerGestureChangedHandler = { pointerStates.append($0) }
        func mouse(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: .init(x: 20, y: 20), modifierFlags: modifiers,
                timestamp: 1, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: mouse(.leftMouseDown, modifiers: [.command, .option]))
        // A transient panel may take the mouse-up. The next complete gesture must work.
        view.mouseDown(with: mouse(.leftMouseDown))
        view.mouseUp(with: mouse(.leftMouseUp))
        #expect(pointerStates == [true, false])
    }

    @Test func pickerSelectionAndCancellationPreservePixelsToolHistoryAndDirtyState() async throws {
        let h = try ConvenienceHarness(); defer { h.cleanUp() }
        let bottom = h.layerID
        try h.fill(bottom, color: .init(red: 1, green: 0, blue: 0, alpha: 1))
        h.vm.addLayer(); let top = h.layerID
        try h.fill(top, color: .init(red: 0, green: 0, blue: 1, alpha: 1))
        h.vm.selectTool(.eraser); h.vm.hasUnsavedChanges = false
        let history = h.bootstrap.historyController.currentStateID
        let before = try [h.snapshot(bottom), h.snapshot(top)]
        let token = UUID()
        let candidates = try await h.vm.canvasLayerPickCandidates(at: .init(x: 32, y: 32), requestID: token)
        #expect(candidates.prefix(2).map(\.id) == [top, bottom])
        #expect(candidates.map(\.id) == h.vm.workspace.document.paintLayers.reversed().map(\.id))
        let image = try await h.vm.canvasLayerPickPreview(bottom, requestID: token)
        #expect(image?.width == 64)
        #expect(h.vm.selectCanvasPickedLayer(bottom, requestID: token))
        #expect(h.layerID == bottom)
        #expect(h.vm.workspace.toolSession.activeTool == .eraser)
        #expect(!h.vm.hasUnsavedChanges)
        #expect(h.bootstrap.historyController.currentStateID == history)
        #expect(try [h.snapshot(bottom), h.snapshot(top)] == before)
        let cancel = UUID()
        _ = try await h.vm.canvasLayerPickCandidates(at: .init(x: 32, y: 32), requestID: cancel)
        h.vm.cancelCanvasLayerPick(cancel)
        #expect(!h.vm.selectCanvasPickedLayer(top, requestID: cancel))
        #expect(h.layerID == bottom)
    }

    @Test func pickerRejectsRequestsAfterContentTopologyOrDocumentChange() async throws {
        let h = try ConvenienceHarness(); defer { h.cleanUp() }
        let layer = h.layerID
        try h.fill(layer, color: .init(red: 1, green: 0, blue: 0, alpha: 1))
        for mutation in 0..<3 {
            let token = UUID()
            _ = try await h.vm.canvasLayerPickCandidates(at: .init(x: 20, y: 20), requestID: token)
            switch mutation {
            case 0: h.vm.setActiveLayerOpacity(0.7)
            case 1: h.vm.addLayer()
            default: h.vm.createNewCanvasDiscardingUnsavedChanges(name: "replacement", canvasSize: .init(width: 32, height: 32), resolutionDPI: 300, pixelFormat: .rgba8)
            }
            #expect(!h.vm.selectCanvasPickedLayer(layer, requestID: token))
        }
    }
}

@MainActor
struct ConvenienceHarness {
    let bootstrap: AppBootstrap
    let vm: WorkspaceViewModel
    let root: URL
    init() throws {
        _ = NSApplication.shared
        let store = WorkspaceStore()
        store.updateDocument { $0.canvasSize = .init(width: 64, height: 64) }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ArtFlex-Convenience-\(UUID())")
        bootstrap = try AppBootstrap(workspaceStore: store, metalContext: #require(MetalDeviceContext()),
            layerSurfaceStore: StageOneLayerSurfaceStore(), persistenceRecoveryRootURL: root)
        vm = WorkspaceViewModel(bootstrap: bootstrap, installsZoomKeyboardMonitor: false)
    }
    var layerID: LayerID { vm.workspace.document.activeLayerID }
    func fill(_ id: LayerID, color: LinearPremultipliedColor) throws {
        let surface = try #require(bootstrap.layerSurfaceStore.surfaceID(for: id))
        let texture = try #require(bootstrap.layerSurfaceStore.texture(for: surface))
        try writeConveniencePixels(color, texture: texture, serializer: bootstrap.textureSerializer)
        bootstrap.layerSurfaceStore.markContentUnknown(for: id)
    }
    func snapshot(_ id: LayerID) throws -> LayerTextureSnapshot {
        let surface = try #require(bootstrap.layerSurfaceStore.surfaceID(for: id))
        return try bootstrap.textureSerializer.snapshot(texture: #require(bootstrap.layerSurfaceStore.readTexture(for: surface)))
    }
    func cleanUp() { vm.momentaryTools.discard(); try? FileManager.default.removeItem(at: root) }
}

func keyEvent(_ key: String, _ code: UInt16, at timestamp: TimeInterval, up: Bool = false, repeated: Bool = false) -> NSEvent {
    NSEvent.keyEvent(with: up ? .keyUp : .keyDown, location: .zero, modifierFlags: [], timestamp: timestamp,
        windowNumber: 0, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: repeated, keyCode: code)!
}

func writeConveniencePixels(_ color: LinearPremultipliedColor, texture: MTLTexture, serializer: LayerTextureSerializer) throws {
    let encoding: CanvasPixelEncoding = texture.pixelFormat == .rgba16Float ? .premultipliedRGBA16FloatLinear : .premultipliedBGRA8SRGB
    var bytes = Data(count: texture.width * texture.height * encoding.bytesPerPixel)
    bytes.withUnsafeMutableBytes { buffer in
        for pixel in 0..<(texture.width * texture.height) { CanvasPixelCodec.write(color, into: buffer, offset: pixel * encoding.bytesPerPixel, encoding: encoding) }
    }
    try serializer.restore(snapshot: .init(width: texture.width, height: texture.height, bytesPerRow: texture.width * encoding.bytesPerPixel,
        pixelData: bytes, encoding: encoding), into: texture)
}

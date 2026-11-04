import Foundation
import Metal
import Testing
@testable import ArtFlex

struct EditableLayerTests {
    private func source(encoding: CanvasPixelEncoding = .premultipliedBGRA8SRGB) -> LayerTextureSnapshot {
        let width = 24, height = 16
        var data = Data(count: width * height * encoding.bytesPerPixel)
        data.withUnsafeMutableBytes { bytes in
            for y in 0..<height { for x in 0..<width {
                let alpha: Float = (x + y) % 3 == 0 ? 0.5 : 1
                CanvasPixelCodec.write(.init(red: Float(x) / 24 * alpha, green: Float(y) / 16 * alpha, blue: 0.1 * alpha, alpha: alpha),
                    into: bytes, offset: (y * width + x) * encoding.bytesPerPixel, encoding: encoding)
            } }
        }
        return .init(width: width, height: height, bytesPerRow: width * encoding.bytesPerPixel, pixelData: data, encoding: encoding)
    }

    @Test(arguments: [CanvasPixelEncoding.premultipliedBGRA8SRGB, .premultipliedRGBA16FloatLinear])
    func transformRestoresOriginalAfterRepeatedEditsAndArchiveRoundTrip(encoding: CanvasPixelEncoding) throws {
        let metal = try #require(MetalDeviceContext())
        let serializer = LayerTextureSerializer(metalContext: metal)
        let renderer = EditableLayerRenderer(metal: metal, serializer: serializer)
        let snapshot = source(encoding: encoding)
        let size = CanvasSize(width: snapshot.width, height: snapshot.height)
        var content = try EditableLayerContent(source: .init(snapshot: snapshot), operation: .image(.init()))
        for scale in [0.2, 1.6, 0.5] {
            content.operation = .image(.init(translation: .init(x: 1.3, y: -0.5), scaleX: scale, scaleY: scale, rotationDegrees: 17))
            let texture = try renderer.render(content, canvas: size, cancellation: WorkCancellation())
            #expect(try serializer.snapshot(texture: texture).pixelData != snapshot.pixelData)
        }
        content.operation = .image(.init())
        let identity = try renderer.render(content, canvas: size, cancellation: WorkCancellation())
        #expect(try serializer.snapshot(texture: identity) == snapshot)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var workspace = WorkspaceState.stageOneDefault
        workspace.document.layers = [workspace.document.layers[0]]
        workspace.document.activeLayerID = workspace.document.layers[0].id
        workspace.document.canvasSize = size
        workspace.document.colorStandard = encoding == .premultipliedRGBA16FloatLinear ? .highPrecision : .stageOneDefault
        workspace.document.layers[0].editableContent = content
        let payload = ProjectArchivePayload(package: .fromWorkspace(workspace, layerSnapshots: [
            .init(layerID: workspace.document.activeLayerID, texture: snapshot)
        ]), referenceImages: [])
        let manifest = try ProjectArchiveV2Writer().write(payload, to: root)
        #expect(manifest.minimumReaderVersion == 4)
        #expect(manifest.editableSources.count == 1)
        let projectBytes = try Data(contentsOf: root.appendingPathComponent("project.json"))
        #expect(!String(decoding: projectBytes, as: UTF8.self).contains("compressedData"))
        let reopened = try ProjectArchiveV2Reader().read(from: root)
        let reopenedContent = try #require(reopened.package.document.layers[0].editableContent)
        #expect(try reopenedContent.source.snapshot() == snapshot)
        let restored = try renderer.render(reopenedContent, canvas: size, cancellation: WorkCancellation())
        #expect(try serializer.snapshot(texture: restored) == snapshot)
        try Data([0, 1, 2]).write(to: root.appendingPathComponent(manifest.editableSources[0].relativePath))
        #expect(throws: (any Error).self) { try ProjectArchiveV2Reader().read(from: root) }
    }

    @Test func textureParametersAreStableAndIndependentOfBrushLibrary() throws {
        let metal = try #require(MetalDeviceContext()), snapshot = source()
        let serializer = LayerTextureSerializer(metalContext: metal)
        let renderer = EditableLayerRenderer(metal: metal, serializer: serializer)
        let shape = SelectionShape(kind: .rectangle, bounds: .init(origin: .init(x: 2, y: 2), size: .init(x: 18, y: 12)), pathPoints: [])
        var fill = try EditableTextureFill(shape: shape, anchor: .init(x: 2, y: 2), material: .init(data: Data(repeating: 255, count: 64)),
            seed: 928, angle: 0.6, color: .white, scale: 1, coverage: 0.7, variation: 0.6, jitter: 0, contrast: 0,
            arrangement: .directional, alphaLocked: false)
        var content = try EditableLayerContent(source: .init(snapshot: snapshot), operation: .texture(fill))
        let size = CanvasSize(width: snapshot.width, height: snapshot.height)
        let first = try serializer.snapshot(texture: renderer.render(content, canvas: size, cancellation: WorkCancellation()))
        #expect(first != snapshot)
        fill.color = .black; content.operation = .texture(fill)
        let second = try serializer.snapshot(texture: renderer.render(content, canvas: size, cancellation: WorkCancellation()))
        #expect(first != second)
        fill.color = .white; content.operation = .texture(fill)
        #expect(try serializer.snapshot(texture: renderer.render(content, canvas: size, cancellation: WorkCancellation())) == first)
        #expect(try content.source.snapshot() == snapshot)
    }

    @Test func corruptSourcesAndInvalidTransformsAreRejectedBeforeAllocation() throws {
        var content = try EditableLayerContent(source: .init(snapshot: source()), operation: .image(.init()))
        content.operation = .image(.init(scaleX: 0))
        #expect(throws: (any Error).self) { try content.validate() }
        content.operation = .image(.init())
        content.source.pixels.byteCount += 1
        #expect(throws: (any Error).self) { try content.validate() }
        content.source.pixels.byteCount -= 1
        content.source.pixels.compressedData = Data([1, 2, 3])
        #expect(throws: (any Error).self) { try content.source.snapshot() }
    }

    @Test func croppedImageCanRestoreSourceAndOffCanvasIsTransparent() throws {
        let metal = try #require(MetalDeviceContext()), snapshot = source()
        let serializer = LayerTextureSerializer(metalContext: metal)
        let renderer = EditableLayerRenderer(metal: metal, serializer: serializer)
        var content = try EditableLayerContent(source: .init(snapshot: snapshot), operation: .image(.init()))
        content.crop(originX: 6, originY: 3)
        let cropped = try serializer.snapshot(texture: renderer.render(content, canvas: .init(width: 12, height: 8), cancellation: WorkCancellation()))
        let expected = NonDestructiveCanvasCrop.slice(snapshot.pixelData, sourceRegion: .init(originX: 0, originY: 0, width: 24, height: 16),
            targetRegion: .init(originX: 6, originY: 3, width: 12, height: 8), encoding: snapshot.encoding)
        #expect(cropped == expected)
        content.crop(originX: -6, originY: -3)
        #expect(try serializer.snapshot(texture: renderer.render(content, canvas: .init(width: 24, height: 16), cancellation: WorkCancellation())) == snapshot)
        content.operation = .image(.init(translation: .init(x: 1000, y: 1000)))
        let outside = try serializer.snapshot(texture: renderer.render(content, canvas: .init(width: 24, height: 16), cancellation: WorkCancellation()))
        #expect(outside.pixelData.allSatisfy { $0 == 0 })
    }

    @Test func gradientParametersSurviveEncodingAndCropWithoutChangingSource() throws {
        let metal = try #require(MetalDeviceContext()), snapshot = source()
        let serializer = LayerTextureSerializer(metalContext: metal)
        let renderer = EditableLayerRenderer(metal: metal, serializer: serializer)
        let geometry = LinearGradientGeometry(pointA: .init(x: 0, y: 0), pointB: .init(x: 24, y: 0), pointC: .init(x: 24, y: 16))
        var fill = EditableGradientFill(geometry: .linear(geometry), settings: .currentColorToTransparent(.white), color: .white,
            jitter: 0, contrast: 0, distortion: 0, alphaLocked: false)
        let content = try EditableLayerContent(source: .init(snapshot: snapshot), operation: .gradient(fill))
        let first = try serializer.snapshot(texture: renderer.render(content, canvas: .init(width: 24, height: 16), cancellation: WorkCancellation()))
        #expect(first != snapshot)
        var decoded = try JSONDecoder().decode(EditableLayerContent.self, from: JSONEncoder().encode(content))
        fill.settings = .currentColorToTransparent(.black); decoded.operation = .gradient(fill)
        let changed = try serializer.snapshot(texture: renderer.render(decoded, canvas: .init(width: 24, height: 16), cancellation: WorkCancellation()))
        #expect(changed != first)
        decoded.crop(originX: 6, originY: 3)
        let cropped = try serializer.snapshot(texture: renderer.render(decoded, canvas: .init(width: 12, height: 8), cancellation: WorkCancellation()))
        #expect(cropped == NonDestructiveCanvasCrop.slice(changed.pixelData,
            sourceRegion: .init(originX: 0, originY: 0, width: 24, height: 16), targetRegion: .init(originX: 6, originY: 3, width: 12, height: 8), encoding: changed.encoding))
        #expect(try decoded.source.snapshot() == snapshot)
    }

    @Test func duplicationRetainsSourceWhilePaintingIsBlocked() throws {
        let store = WorkspaceStore()
        store.updateDocument { document in
            document.layers[document.layers.count - 1].editableContent = try! .init(source: .init(snapshot: source()), operation: .image(.init()))
        }
        let controller = CanvasInteractionController(workspaceStore: store)
        #expect(controller.activeEditableLayerID() == nil)
        #expect(controller.makeStrokeDescriptor(samples: [.init(location: .init(x: 1, y: 1))]) == nil)
        let original = store.state.document.layers.last!.editableContent
        store.updateDocument { document in _ = document.duplicateActiveLayer() }
        #expect(store.state.document.layers.last!.editableContent == original)
    }

    @Test @MainActor func editorApplyCancelRasterizeAndHistoryKeepMetadataAndPixelsTogether() async throws {
        let original = source()
        var workspace = WorkspaceState.stageOneDefault
        workspace.document.canvasSize = .init(width: original.width, height: original.height)
        let bootstrap = try AppBootstrap(workspaceStore: WorkspaceStore(state: workspace))
        let vm = WorkspaceViewModel(bootstrap: bootstrap, installsZoomKeyboardMonitor: false)
        let id = workspace.document.activeLayerID
        let surface = try #require(bootstrap.layerSurfaceStore.surfaceID(for: id))
        try bootstrap.textureSerializer.restore(snapshot: original, into: #require(bootstrap.layerSurfaceStore.texture(for: surface)))
        func pixels() throws -> LayerTextureSnapshot {
            try bootstrap.textureSerializer.snapshot(texture: #require(bootstrap.layerSurfaceStore.readTexture(for: surface)))
        }
        vm.beginEditableLayer(id)
        let draft = try #require(vm.editableLayerDraft)
        draft.content.operation = .image(.init(scaleX: 0.5, scaleY: 0.5))
        for _ in 0..<300 where draft.isComputing { try await Task.sleep(for: .milliseconds(10)) }
        #expect(draft.canApply)
        #expect(try pixels() == original) // The sheet preview never mutates the live layer.
        #expect(draft.apply())
        vm.editableLayerDraft = nil
        let changed = try pixels()
        #expect(changed != original)
        #expect(vm.workspace.document.layer(id)?.editableContent != nil)
        vm.undo()
        #expect(vm.workspace.document.layer(id)?.editableContent == nil)
        #expect(try pixels() == original)
        vm.redo()
        #expect(try pixels() == changed)
        #expect(vm.workspace.document.layer(id)?.editableContent != nil)
        vm.rasterizeEditableLayer(id)
        #expect(vm.workspace.document.layer(id)?.editableContent == nil)
        #expect(try pixels() == changed)
        vm.undo()
        #expect(vm.workspace.document.layer(id)?.editableContent != nil)
        vm.beginEditableLayer(id)
        let cancelled = try #require(vm.editableLayerDraft)
        cancelled.content.operation = .image(.init(rotationDegrees: 70))
        cancelled.cancel(); vm.editableLayerDraft = nil
        #expect(try pixels() == changed)
    }
}

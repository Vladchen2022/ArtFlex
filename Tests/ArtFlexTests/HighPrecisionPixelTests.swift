import AppKit
import Foundation
import ImageIO
import Testing
@testable import ArtFlex

struct HighPrecisionPixelTests {
    @Test @MainActor func sixteenBitImportClipboardAndSelectionFillKeepSubByteColorSteps() throws {
        var bytes = Data(count: 512 * 8)
        bytes.withUnsafeMutableBytes { output in
            for x in 0..<512 {
                CanvasPixelCodec.write(.init(red: 0.05 + Float(x) / 10000, green: 0.08, blue: 0.03, alpha: 0.5),
                    into: output, offset: x * 8, encoding: .premultipliedRGBA16FloatLinear)
            }
        }
        let original = LayerTextureSnapshot(width: 512, height: 1, bytesPerRow: 4096,
            pixelData: bytes, encoding: .premultipliedRGBA16FloatLinear)
        let encoded = try RasterExporter().encode(snapshot: original, options: .init(format: .png,
            background: .transparent, bitDepth: .sixteen))
        let image = try #require(NSImage(data: encoded.encodedData))
        let clipboard = PixelClipboardController()
        let payload = try #require(clipboard.canvasImportPayload(from: image,
            fittingWithin: .init(width: 512, height: 1), centeredAt: .init(x: 256, y: 0)))
        #expect(payload.snapshot.encoding == .premultipliedRGBA16FloatLinear)
        let red = (0..<512).map { payload.snapshot.linearPixel(x: $0, y: 0).red }
        #expect(Set(red).count > 300)
        #expect(abs(red[200] - original.linearPixel(x: 200, y: 0).red) < 0.001)
        #expect(abs(payload.snapshot.linearPixel(x: 200, y: 0).alpha - 0.5) < 0.001)
        let board = NSPasteboard(name: .init("ArtFlex-half-clipboard-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        clipboard.store(payload, pasteboard: board)
        #expect(clipboard.preferredPayload(from: board) == payload)
        let external = try #require(PixelClipboardController().preferredPayload(from: board))
        #expect(external.snapshot.encoding == .premultipliedRGBA16FloatLinear)
        #expect(Set((0..<512).map { external.snapshot.linearPixel(x: $0, y: 0).red }).count > 300)

        var state = WorkspaceState.stageOneDefault
        state.document.canvasSize = .init(width: 8, height: 8)
        state.document.colorStandard = .highPrecision
        let bootstrap = try AppBootstrap(workspaceStore: WorkspaceStore(state: state))
        let vm = WorkspaceViewModel(bootstrap: bootstrap, installsZoomKeyboardMonitor: false)
        vm.debugSetCommittedSelectionShapeForTests(.init(kind: .rectangle,
            bounds: .init(origin: .init(x: 0, y: 0), size: .init(x: 8, y: 8)), pathPoints: []))
        let color = RGBAColor(red: 0.41231, green: 0.12341, blue: 0.63213, alpha: 1)
        vm.setSelectedColor(color)
        vm.fillSelectionContents()
        let id = try #require(bootstrap.layerSurfaceStore.surfaceID(for: state.document.activeLayerID))
        let texture = try #require(bootstrap.layerSurfaceStore.readTexture(for: id))
        let picked = try bootstrap.textureSerializer.samplePixel(texture: texture, x: 4, y: 4)
        #expect(abs(picked.red - color.red) < 0.0003)
        #expect(abs(picked.green - color.green) < 0.0003)
        #expect(abs(picked.blue - color.blue) < 0.0003)
    }

    @Test func imageIOExportsRealSixteenBitColorAndAlpha() throws {
        var bytes = Data(count: 1024 * 8)
        bytes.withUnsafeMutableBytes { output in
            for x in 0..<1024 {
                CanvasPixelCodec.write(.init(red: 0.1 + Float(x) / 20000, green: 0.05, blue: 0.025, alpha: 0.5),
                    into: output, offset: x * 8, encoding: .premultipliedRGBA16FloatLinear)
            }
        }
        let snapshot = LayerTextureSnapshot(width: 1024, height: 1, bytesPerRow: 8192,
            pixelData: bytes, encoding: .premultipliedRGBA16FloatLinear)
        for format in [RasterExportFormat.png, .tiff] {
            for resize in [RasterExportResize.original, .scale(2)] {
                let result = try RasterExporter().encode(snapshot: snapshot, options: .init(format: format,
                    background: .transparent, resize: resize, bitDepth: .sixteen))
                let source = try #require(CGImageSourceCreateWithData(result.encodedData as CFData, nil))
                let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
                #expect(image.bitsPerComponent == 16)
                #expect(image.width == result.pixelWidth)
                let data = try #require(image.dataProvider?.data) as Data
                #expect(Set(stride(from: 0, to: image.bytesPerRow, by: 8).map { Data(data[$0..<$0 + 8]) }).count > 300)
            }
        }
        #expect(throws: RasterExportError.unsupportedBitDepth) {
            try RasterExportOptions(format: .jpeg, bitDepth: .sixteen).validate()
        }
    }

    @Test @MainActor func paintingHistorySavingRecoveryAndCropKeepHalfFloatPixels() throws {
        var state = WorkspaceState.stageOneDefault
        state.document.canvasSize = .init(width: 128, height: 128)
        state.document.colorStandard = .highPrecision
        let bootstrap = try AppBootstrap(workspaceStore: WorkspaceStore(state: state))
        let vm = WorkspaceViewModel(bootstrap: bootstrap, installsZoomKeyboardMonitor: false)
        let id = try #require(vm.layerSurfaceStore.surfaceID(for: state.document.activeLayerID))
        #expect(vm.layerSurfaceStore.readTexture(for: id)?.pixelFormat == .rgba16Float)
        vm.setBrushSize(24)
        vm.setSelectedColor(.init(red: 0.4123, green: 0.2345, blue: 0.1234, alpha: 1))
        for tool in [ToolKind.brush, .eraser] {
            vm.selectTool(tool)
            vm.setBrushSize(tool == .eraser ? 4 : 24)
            vm.beginStrokeIfNeeded()
            vm.applyStroke(samples: [.init(location: .init(x: 20, y: 60), pressure: 0.4),
                .init(location: .init(x: 100, y: 70), pressure: 0.8)])
            vm.endStroke()
            #expect(vm.flushBrushEditingBoundary(reason: "half-float-history"))
        }
        func pixels() throws -> LayerTextureSnapshot {
            try bootstrap.textureSerializer.snapshot(texture: #require(vm.layerSurfaceStore.readTexture(for: id)))
        }
        let painted = try pixels()
        #expect(painted.encoding == .premultipliedRGBA16FloatLinear)
        #expect(painted.pixelData.contains { $0 != 0 })
        vm.undo(); vm.redo()
        #expect(try pixels() == painted)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArtFlex-half-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = PersistenceController(workspaceStore: bootstrap.workspaceStore, layerSurfaceStore: vm.layerSurfaceStore,
            serializer: bootstrap.textureSerializer, recoveryRootURL: root.appendingPathComponent("recovery"))
        let file = root.appendingPathComponent("painting.artflex")
        try controller.saveProject(to: file)
        let loaded = try controller.openProject(from: file)
        #expect(loaded.workspace.document.colorStandard == .highPrecision)
        #expect(loaded.layerSnapshots.first { $0.layerID == state.document.activeLayerID }?.texture == painted)
        let capture = try controller.freezeIncrementalRecovery()
        let staging = try controller.makeRecoveryStagingURL()
        try controller.writeIncrementalRecovery(capture, to: staging)
        try controller.installRecoveryProject(from: staging)
        let recovered = try controller.openProject(from: controller.recoveryProjectURL)
        #expect(recovered.layerSnapshots.first { $0.layerID == state.document.activeLayerID }?.texture == painted)
        let cropped = try NonDestructiveCanvasCrop.prepare(document: vm.workspace.document, source: vm.layerSurfaceStore,
            region: .init(originX: 40, originY: 40, width: 48, height: 48), metal: bootstrap.metalContext,
            serializer: bootstrap.textureSerializer)
        var croppedDoc = vm.workspace.document
        croppedDoc.canvasSize = .init(width: 48, height: 48); croppedDoc.cropRetention = cropped.retention
        let expanded = try NonDestructiveCanvasCrop.prepare(document: croppedDoc, source: cropped.surfaces,
            region: cropped.retention.fullBounds, metal: bootstrap.metalContext, serializer: bootstrap.textureSerializer)
        let expandedID = try #require(expanded.surfaces.surfaceID(for: state.document.activeLayerID))
        let restored = try bootstrap.textureSerializer.snapshot(texture: #require(expanded.surfaces.readTexture(for: expandedID)))
        #expect(restored == painted)
    }
    @Test func legacyEncodingAndHalfFloatRoundTripsPreserveExistingColorSemantics() throws {
        var bytes = Data(count: 256 * 4)
        for i in 0..<256 {
            bytes[i * 4] = UInt8(i); bytes[i * 4 + 1] = UInt8(i); bytes[i * 4 + 2] = UInt8(i); bytes[i * 4 + 3] = 255
        }
        let old = LayerTextureSnapshot(width: 256, height: 1, bytesPerRow: 1024, pixelData: bytes)
        let half = try old.converted(to: .premultipliedRGBA16FloatLinear)
        #expect(half.pixelData.count == 2048)
        #expect(try half.converted(to: .premultipliedBGRA8SRGB).pixelData == bytes)
        #expect(try JSONDecoder().decode(LayerTextureSnapshot.self, from: JSONEncoder().encode(half)) == half)
        let legacy = Data("{\"width\":1,\"height\":1,\"bytesPerRow\":4,\"pixelData\":\"AAAAAA==\"}".utf8)
        #expect(try JSONDecoder().decode(LayerTextureSnapshot.self, from: legacy).encoding == .premultipliedBGRA8SRGB)
    }

    @Test func gpuReadbackKeepsValuesBetweenEightBitSteps() throws {
        let metal = try #require(MetalDeviceContext())
        let serializer = LayerTextureSerializer(metalContext: metal)
        let store = StageOneLayerSurfaceStore()
        let texture = try #require(store.makeTexture(width: 512, height: 1, pixelFormat: .rgba16Float, metal: metal))
        var bytes = Data(count: 512 * 8)
        bytes.withUnsafeMutableBytes { output in
            for i in 0..<512 {
                let value = 0.2 + Float(i) * 0.0001
                CanvasPixelCodec.write(.init(red: value, green: value, blue: value, alpha: 1),
                    into: output, offset: i * 8, encoding: .premultipliedRGBA16FloatLinear)
            }
        }
        let original = LayerTextureSnapshot(width: 512, height: 1, bytesPerRow: 4096,
            pixelData: bytes, encoding: .premultipliedRGBA16FloatLinear)
        try serializer.restore(snapshot: original, into: texture)
        let snapshot = try serializer.snapshot(texture: texture)
        #expect(snapshot == original)
        let unique = snapshot.pixelData.withUnsafeBytes { pixels in
            Set((0..<512).map { CanvasPixelCodec.read(pixels, offset: $0 * 8, encoding: snapshot.encoding).red })
        }
        #expect(unique.count > 300)
        let picked = try serializer.samplePixel(texture: texture, x: 50, y: 0)
        #expect(abs(picked.red - LinearPremultipliedColor.linearChannelToSRGB(Float(Float16(0.205)))) < 0.00001)
        let eightBitTarget = try #require(store.makeTexture(width: 512, height: 1, metal: metal))
        #expect(throws: (any Error).self) { try serializer.restore(snapshot: snapshot, into: eightBitTarget) }
    }
}

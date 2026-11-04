import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Metal
import Testing
@testable import ArtFlex

@MainActor
struct WideGamutColorTests {
    private func p3Image(alpha: UInt8 = 255) throws -> NSImage {
        let pixels = Data(Array(repeating: [UInt8(255), 0, 0, alpha], count: 16 * 16).flatMap { $0 })
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let image = try #require(CGImage(width: 16, height: 16, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 64,
            space: space, bitmapInfo: .init(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .relativeColorimetric))
        return NSImage(cgImage: image, size: .init(width: 16, height: 16))
    }
    private func imported(_ alpha: UInt8 = 255) throws -> LayerTextureSnapshot {
        try #require(PixelClipboardController().canvasImportPayload(from: p3Image(alpha: alpha), fittingWithin: .init(width: 16, height: 16),
            centeredAt: .init(x: 8, y: 8), preservesWideGamut: true)).snapshot
    }

    @Test func p3ImportSamplingAndP3ExportPreserveOutOfSRGBColorAndAlpha() throws {
        let metal = try #require(MetalDeviceContext()), source = try imported(128)
        let c = source.linearPixel(x: 8, y: 8)
        #expect(c.red > c.alpha && c.green < -0.001 && c.blue < -0.001)
        let sampler = EyedropperSampler(serializer: .init(metalContext: metal))
        var settings = EyedropperSettings.stageOneDefault; settings.preservesTransparency = true
        let picked = sampler.sampledColor(from: source, settings: settings)
        let roundTrip = LinearPremultipliedColor(srgb: picked)
        #expect(abs(roundTrip.red - c.red) < 0.0005)
        #expect(abs(roundTrip.green - c.green) < 0.0005)
        for resize in [RasterExportResize.original, .scale(2)] {
            let output = try RasterExporter().encode(snapshot: source, options: .init(background: .transparent, resize: resize,
                bitDepth: .sixteen, colorProfile: .displayP3))
            let imageSource = try #require(CGImageSourceCreateWithData(output.encodedData as CFData, nil))
            let cg = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
            #expect(cg.colorSpace?.isWideGamutRGB == true)
            #expect(cg.bitsPerComponent == 16)
            let image = NSImage(cgImage: cg, size: .init(width: cg.width, height: cg.height))
            let reimported = try #require(PixelClipboardController().canvasImportPayload(from: image,
                fittingWithin: .init(width: cg.width, height: cg.height), centeredAt: .init(x: 8, y: 8), preservesWideGamut: true))
            let actual = reimported.snapshot.linearPixel(x: 8, y: 8)
            #expect(abs(actual.red - c.red) < 0.003)
            #expect(abs(actual.green - c.green) < 0.003)
            #expect(abs(actual.alpha - c.alpha) < 0.002)
        }
    }

    @Test func nativeRGBProofClipsToOutputGamutWithoutTouchingSourcePixels() throws {
        let metal = try #require(MetalDeviceContext()), serializer = LayerTextureSerializer(metalContext: metal)
        let snapshot = try imported()
        let store = StageOneLayerSurfaceStore()
        let source = try #require(store.makeTexture(width: 16, height: 16, pixelFormat: .rgba16Float, metal: metal))
        let destination = try #require(store.makeTexture(width: 16, height: 16, pixelFormat: .rgba16Float, metal: metal))
        try serializer.restore(snapshot: snapshot, into: source)
        for profile in [ManagedRGBProfile.sRGB, .displayP3] {
            let renderer = try ColorProofRenderer(profile: profile, metal: metal)
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = destination; pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
            let command = try #require(metal.commandQueue.makeCommandBuffer())
            try renderer.encode(source: source, into: pass, command: command)
            command.commit(); command.waitUntilCompleted()
            #expect(command.status == .completed)
            let actual = try serializer.snapshot(texture: destination).linearPixel(x: 8, y: 8)
            if profile == .sRGB { #expect(actual.red <= 1.002 && actual.green >= -0.001) }
            else {
                let expected = snapshot.linearPixel(x: 8, y: 8)
                #expect(abs(actual.red - expected.red) < 0.005)
                #expect(abs(actual.green - expected.green) < 0.005)
            }
            #expect(try serializer.snapshot(texture: source) == snapshot)
        }
    }

    @Test func wideSelectionFillHistoryAndNativeReopenKeepNegativeChannels() throws {
        var state = WorkspaceState.stageOneDefault
        state.document.canvasSize = .init(width: 16, height: 16); state.document.colorStandard = .wideGamut
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bootstrap = try AppBootstrap(workspaceStore: .init(state: state), persistenceRecoveryRootURL: root.appendingPathComponent("Recovery"))
        let vm = WorkspaceViewModel(bootstrap: bootstrap, installsZoomKeyboardMonitor: false)
        let c = try imported().linearPixel(x: 8, y: 8)
        vm.setSelectedColor(.init(red: LinearPremultipliedColor.linearChannelToExtendedSRGB(c.red),
            green: LinearPremultipliedColor.linearChannelToExtendedSRGB(c.green), blue: LinearPremultipliedColor.linearChannelToExtendedSRGB(c.blue), alpha: 1))
        vm.debugSetCommittedSelectionShapeForTests(.init(kind: .rectangle, bounds: .init(origin: .init(x: 0, y: 0), size: .init(x: 16, y: 16)), pathPoints: []))
        vm.fillSelectionContents()
        let id = try #require(vm.layerSurfaceStore.surfaceID(for: state.document.activeLayerID))
        func pixels() throws -> LayerTextureSnapshot { try bootstrap.textureSerializer.snapshot(texture: #require(vm.layerSurfaceStore.readTexture(for: id))) }
        let filled = try pixels()
        #expect(abs(filled.linearPixel(x: 8, y: 8).red - c.red) < 0.003)
        #expect(filled.linearPixel(x: 8, y: 8).green < 0)
        vm.undo(); vm.redo(); #expect(try pixels() == filled)
        let url = root.appendingPathComponent("wide.artflex")
        try bootstrap.persistenceController.saveProject(to: url)
        let read = try bootstrap.persistenceController.openProject(from: url)
        #expect(read.workspace.document.colorStandard == .wideGamut)
        #expect(read.layerSnapshots.first { $0.layerID == state.document.activeLayerID }?.texture == filled)
    }

    @Test func wideBrushRetainsExtendedComponentsAndCustomICCExport() throws {
        var state = WorkspaceState.stageOneDefault
        state.document.canvasSize = .init(width: 64, height: 64)
        state.document.colorStandard = .wideGamut
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let boot = try AppBootstrap(workspaceStore: .init(state: state), persistenceRecoveryRootURL: root)
        let vm = WorkspaceViewModel(bootstrap: boot, installsZoomKeyboardMonitor: false)
        let input = try imported()
        let c = input.linearPixel(x: 8, y: 8)
        vm.setSelectedColor(.init(red: LinearPremultipliedColor.linearChannelToExtendedSRGB(c.red),
            green: LinearPremultipliedColor.linearChannelToExtendedSRGB(c.green), blue: LinearPremultipliedColor.linearChannelToExtendedSRGB(c.blue), alpha: 1))
        vm.setBrushSize(24)
        vm.beginStrokeIfNeeded()
        vm.applyStroke(samples: [.init(location: .init(x: 10, y: 32), pressure: 1), .init(location: .init(x: 54, y: 32), pressure: 1)])
        vm.endStroke()
        #expect(vm.flushBrushEditingBoundary(reason: "wide-brush"))
        let id = try #require(vm.layerSurfaceStore.surfaceID(for: state.document.activeLayerID))
        let texture = try #require(vm.layerSurfaceStore.readTexture(for: id))
        let painted = try boot.textureSerializer.snapshot(texture: texture)
        let center = painted.linearPixel(x: 32, y: 32)
        #expect(center.red > 1 && center.green < 0 && center.alpha > 0.99)
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let icc = try #require(p3.copyICCData()) as Data
        let encoded = try RasterExporter().encode(snapshot: input, options: .init(background: .transparent, bitDepth: .sixteen,
            colorProfile: .init(kind: .icc, name: "自定义 P3", iccData: icc)))
        let source = try #require(CGImageSourceCreateWithData(encoded.encodedData as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.colorSpace?.isWideGamutRGB == true)
        let reimported = try #require(PixelClipboardController().canvasImportPayload(from: NSImage(cgImage: image, size: .init(width: 16, height: 16)),
            fittingWithin: .init(width: 16, height: 16), centeredAt: .init(x: 8, y: 8), preservesWideGamut: true))
        #expect(abs(reimported.snapshot.linearPixel(x: 8, y: 8).red - c.red) < 0.003)
    }

    @Test func invalidRGBProfilesAndInvalidWideEightBitDocumentsAreRejected() throws {
        #expect(throws: (any Error).self) { try ManagedColorTransform.colorSpace(.init(kind: .icc, name: "坏文件", iccData: Data([1,2,3]))) }
        let bad = ArtColorStandard(pixelFormat: .rgba8, alphaMode: .premultiplied, colorSpace: .extendedSRGB)
        let bytes = try JSONEncoder().encode(bad)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ArtColorStandard.self, from: bytes) }
    }
}

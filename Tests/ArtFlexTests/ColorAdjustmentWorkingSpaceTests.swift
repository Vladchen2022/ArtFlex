import CoreGraphics
import Foundation
import Metal
import Testing
@testable import ArtFlex

struct ColorAdjustmentWorkingSpaceTests {
    private func snapshot(_ colors: [LinearPremultipliedColor]) -> LayerTextureSnapshot {
        var data = Data(count: colors.count * 8)
        data.withUnsafeMutableBytes { bytes in
            for (x, color) in colors.enumerated() { CanvasPixelCodec.write(color, into: bytes, offset: x * 8, encoding: .premultipliedRGBA16FloatLinear) }
        }
        return .init(width: colors.count, height: 1, bytesPerRow: colors.count * 8,
            pixelData: data, encoding: .premultipliedRGBA16FloatLinear)
    }

    private func adjusted(_ input: LayerTextureSnapshot, space: ArtColorSpace, brightness: Float = 0.5,
                          vitalization: Bool = false, reference: RGBAColor? = nil) throws -> LayerTextureSnapshot {
        let metal = try #require(MetalDeviceContext())
        let store = StageOneLayerSurfaceStore(), serializer = LayerTextureSerializer(metalContext: metal)
        let source = try #require(store.makeTexture(width: input.width, height: input.height, pixelFormat: .rgba16Float, metal: metal))
        let result = try #require(store.makeTexture(width: input.width, height: input.height, pixelFormat: .rgba16Float, metal: metal))
        try serializer.restore(snapshot: input, into: source)
        var parameters = vitalization ? ColorAdjustmentParameters.vitalizationDefault : .neutral
        if !vitalization { parameters.brightness = brightness }
        let renderer = try ColorAdjustmentRenderer(device: metal.device)
        let command = try #require(metal.commandQueue.makeCommandBuffer())
        #expect(renderer.encodePreview(sourceTexture: source, previewTexture: result, maskTexture: nil,
            maskReadMode: .sourceAlpha, parameters: parameters, colorSpace: space,
            effectMode: vitalization ? .vitalization : .standard, vitalizationReferenceColor: reference,
            vitalizationSeed: 47, overlayOnly: false, effectRegion: nil, commandBuffer: command))
        command.commit(); command.waitUntilCompleted()
        #expect(command.status == .completed)
        #expect(try serializer.snapshot(texture: source) == input)
        return try serializer.snapshot(texture: result)
    }

    @Test @MainActor func widePreviewCommitUndoAndReopenUseTheSameDomain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var state = WorkspaceState.stageOneDefault
        state.document.canvasSize = .init(width: 8, height: 1)
        state.document.colorStandard = .wideGamut
        let bootstrap = try AppBootstrap(workspaceStore: .init(state: state), persistenceRecoveryRootURL: root)
        let vm = WorkspaceViewModel(bootstrap: bootstrap, installsZoomKeyboardMonitor: false)
        let source = snapshot(Array(repeating: .init(red: 0, green: 0.5, blue: 0.2, alpha: 1), count: 8))
        let id = state.document.activeLayerID
        let surface = try #require(bootstrap.layerSurfaceStore.surfaceID(for: id))
        try bootstrap.textureSerializer.restore(snapshot: source, into: #require(bootstrap.layerSurfaceStore.texture(for: surface)))
        vm.selectTool(.brightnessAdjust)
        vm.setColorAdjustmentBrightness(0.5)
        for _ in 0..<300 where vm.colorAdjustmentPreviewRenderInFlight { try await Task.sleep(for: .milliseconds(10)) }
        let preview = try bootstrap.textureSerializer.snapshot(texture: #require(vm.activeColorAdjustmentPreviewTexture(for: id)))
        let expected = try adjusted(source, space: .extendedSRGB)
        #expect(preview == expected)
        #expect(vm.confirmColorAdjustmentSession())
        let committed = try bootstrap.textureSerializer.snapshot(texture: #require(bootstrap.layerSurfaceStore.readTexture(for: surface)))
        #expect(committed == preview)
        vm.undo()
        #expect(try bootstrap.textureSerializer.snapshot(texture: #require(bootstrap.layerSurfaceStore.readTexture(for: surface))) == source)
        vm.redo()
        let url = root.appendingPathComponent("wide-adjustment.artflex")
        try bootstrap.persistenceController.saveProject(to: url)
        let reopened = try bootstrap.persistenceController.openProject(from: url)
        #expect(reopened.layerSnapshots.first { $0.layerID == id }?.texture == committed)
    }

    @Test func adjacentPixelsRemainContinuousAcrossSRGBBoundaries() throws {
        for channel in 0..<3 {
            for boundary: Float in [0, 1] {
                var a: [Float] = [0.2, 0.5, 0.3], b = a
                a[channel] = boundary; b[channel] = boundary + (boundary == 0 ? -0.000001 : 0.00001)
                let result = try adjusted(snapshot([.init(red: a[0], green: a[1], blue: a[2], alpha: 1),
                    .init(red: b[0], green: b[1], blue: b[2], alpha: 1)]), space: .extendedSRGB)
                let x = result.linearPixel(x: 0, y: 0), y = result.linearPixel(x: 1, y: 0)
                #expect(abs(x.red - y.red) < 0.001)
                #expect(abs(x.green - y.green) < 0.001)
                #expect(abs(x.blue - y.blue) < 0.001)
            }
        }
    }

    @Test func legacySRGBKeepsTheEstablishedLinearBrightnessResponse() throws {
        let input = snapshot([.init(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)])
        let result = try adjusted(input, space: .sRGB).linearPixel(x: 0, y: 0)
        let source = input.linearPixel(x: 0, y: 0)
        let gamma: Float = 1 + 1.45 * pow(0.5, 1.18)
        for pair in [(source.red, result.red), (source.green, result.green), (source.blue, result.blue)] {
            #expect(abs(pair.1 - (1 - pow(1 - pair.0, gamma))) < 0.001)
        }
    }

    @Test func wideDocumentUsesNativeP3DomainEvenForSRGBPixels() throws {
        let srgb = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let p3 = try #require(CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
        let input = snapshot([.init(red: 0, green: 0.5, blue: 0.2, alpha: 1)])
        let color = input.linearPixel(x: 0, y: 0)
        let native = try #require(CGColor(colorSpace: srgb, components: [CGFloat(color.red), CGFloat(color.green), CGFloat(color.blue), 1])?
            .converted(to: p3, intent: .relativeColorimetric, options: nil)?.components)
        let gamma = 1 + 1.45 * pow(0.5, 1.18)
        var adjusted = native.prefix(3).map { CGFloat(1 - pow(1 - Double($0), gamma)) }; adjusted.append(1)
        let expected = try #require(CGColor(colorSpace: p3, components: adjusted)?.converted(to: srgb, intent: .relativeColorimetric, options: nil)?.components)
        let result = try self.adjusted(input, space: .extendedSRGB).linearPixel(x: 0, y: 0)
        #expect(abs(result.red - Float(expected[0])) < 0.001)
        #expect(abs(result.green - Float(expected[1])) < 0.001)
        #expect(abs(result.blue - Float(expected[2])) < 0.001)
    }

    @Test func vitalizationDoesNotClampWideRedToSRGB() throws {
        let color = LinearPremultipliedColor(red: 1.2247, green: -0.0421, blue: -0.0196, alpha: 1)
        let reference = RGBAColor(red: LinearPremultipliedColor.linearChannelToExtendedSRGB(color.red),
            green: LinearPremultipliedColor.linearChannelToExtendedSRGB(color.green),
            blue: LinearPremultipliedColor.linearChannelToExtendedSRGB(color.blue), alpha: 1)
        let result = try adjusted(snapshot([color]), space: .extendedSRGB, vitalization: true, reference: reference).linearPixel(x: 0, y: 0)
        #expect(result.red > 1 || result.green < -0.001 || result.blue < -0.001)
        #expect(result.alpha == 1)
    }
}

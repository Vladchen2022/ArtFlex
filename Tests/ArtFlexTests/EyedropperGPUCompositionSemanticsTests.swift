import Foundation
@preconcurrency import Metal
import Testing
@testable import ArtFlex

@MainActor
struct EyedropperGPUCompositionSemanticsTests {
    @Test func masksClippingCurvesAndLiveTextureSourcesMatchCanonicalSampling() async throws {
        for standard in [ArtColorStandard.stageOneDefault, .highPrecision] {
            var bottom = LayerRecord.stageOneDefault()
            bottom.mask = .init()
            var curve = LayerRecord.stageOneDefault()
            curve.opacity = 0.7
            curve.mask = .init()
            var parameters = CurveAdjustmentParameters.neutral
            parameters.redCurve = .init(points: [.init(x: 0, y: 0.2), .init(x: 0.5, y: 0.8), .init(x: 1, y: 1)])
            curve.adjustment = .curves(parameters)
            var top = LayerRecord.stageOneDefault()
            top.opacity = 0.63
            top.blendMode = .screen
            top.clipTargetLayerID = bottom.id
            top.mask = .init()
            let h = try GPUEyedropperSemanticsHarness(layers: [bottom, curve, top], activeLayerID: top.id,
                standard: standard)
            try h.restore(bottom.id) { x, y in
                .init(red: 0.02 + Float(x) * 0.025, green: 0.15, blue: 0.04 + Float(y) * 0.025, alpha: 0.65)
            }
            try h.restore(top.id) { x, y in
                .init(red: 0.24, green: Float(x) * 0.025, blue: 0.04 + Float(y) * 0.035, alpha: 0.45)
            }
            try h.restoreMask(bottom.id) { x, _ in UInt8(x * 35) }
            try h.restoreMask(top.id) { _, y in UInt8(y * 50) }
            try h.restoreMask(curve.id) { x, y in UInt8((x + y) * 23) }
            let liveBottom = try h.makeTexture { _, _ in .init(red: 0.03, green: 0.04, blue: 0.3, alpha: 0.4) }
            let liveTop = try h.makeTexture { _, _ in .init(red: 0.2, green: 0.01, blue: 0.03, alpha: 0.3) }
            let displayBottom = try h.makeTexture { _, _ in .init(red: 0.08, green: 0.5, blue: 0.06, alpha: 0.8) }
            let displayTop = try h.makeTexture { _, _ in .init(red: 0.03, green: 0.25, blue: 0.03, alpha: 0.35) }
            let content: (LayerID) -> MTLTexture? = { id in id == bottom.id ? liveBottom : (id == top.id ? liveTop : nil) }
            let display: (LayerID) -> MTLTexture? = { id in id == bottom.id ? displayBottom : (id == top.id ? displayTop : nil) }
            var results: [EyedropperSampleSource: RGBAColor] = [:]
            for source in [EyedropperSampleSource.currentLayer, .allVisibleLayers, .displayedColor] {
                for statistic in [EyedropperSampleStatistic.average, .median] {
                    let settings = EyedropperSettings(sampleSize: .threeByThree, statistic: statistic,
                        source: source, preservesTransparency: true, returnsToPreviousTool: false)
                    let actual = try await h.compare(at: .init(x: 3, y: 2), settings: settings,
                        content: content, display: display)
                    if statistic == .average { results[source] = actual }
                }
            }
            let visible = try #require(results[.allVisibleLayers])
            let displayed = try #require(results[.displayedColor])
            #expect(abs(visible.green - displayed.green) > 0.05)
            // A disabled layer mask must not be used even when its texture exists.
            h.document.layers[2].mask?.isEnabled = false
            _ = try await h.compare(at: .init(x: 3, y: 2), settings: .init(sampleSize: .point,
                statistic: .average, source: .displayedColor, preservesTransparency: true,
                returnsToPreviousTool: false), content: content, display: display)
            // A hidden clip target suppresses the clipped layer, including current-layer sampling.
            h.document.layers[0].isVisible = false
            let hiddenClip = try await h.compare(at: .init(x: 3, y: 2), settings: .init(sampleSize: .point,
                statistic: .average, source: .currentLayer, preservesTransparency: true,
                returnsToPreviousTool: false), content: content, display: display)
            #expect(hiddenClip.alpha == 0)
        }
    }

    @Test func hiddenCurrentLayerStillSamplesItsContentMaskAndOpacity() async throws {
        var bottom = LayerRecord.stageOneDefault()
        bottom.name = "Visible backdrop"
        var hidden = LayerRecord.stageOneDefault()
        hidden.isVisible = false
        hidden.opacity = 0.5
        hidden.mask = .init()
        let h = try GPUEyedropperSemanticsHarness(layers: [bottom, hidden], activeLayerID: hidden.id)
        try h.restore(bottom.id) { _, _ in .init(red: 1, green: 0, blue: 0, alpha: 1) }
        try h.restore(hidden.id) { _, _ in .init(red: 0, green: 0, blue: 0.4, alpha: 0.4) }
        try h.restoreMask(hidden.id) { _, _ in 128 }
        let displayTexture = try h.makeTexture { _, _ in .init(red: 0, green: 1, blue: 0, alpha: 1) }
        var settings = EyedropperSettings(sampleSize: .point, statistic: .average,
            source: .currentLayer, preservesTransparency: true, returnsToPreviousTool: false)
        let current = try await h.compare(at: .init(x: 3, y: 2), settings: settings,
            display: { $0 == hidden.id ? displayTexture : nil })
        #expect(current.blue > 0.99)
        #expect(current.green < 0.001)
        #expect(abs(current.alpha - 0.4 * 0.5 * 128 / 255) < 0.003)
        for source in [EyedropperSampleSource.allVisibleLayers, .displayedColor] {
            settings.source = source
            let visible = try await h.compare(at: .init(x: 3, y: 2), settings: settings,
                display: { $0 == hidden.id ? displayTexture : nil })
            #expect(visible.red > 0.99 && visible.blue < 0.001 && visible.green < 0.001)
        }
    }

    @Test func zeroOpacityInputsProduceDefinedTransparentOrWhiteSamples() async throws {
        var layer = LayerRecord.stageOneDefault()
        layer.opacity = 0
        let h = try GPUEyedropperSemanticsHarness(layers: [layer], activeLayerID: layer.id)
        try h.restore(layer.id) { _, _ in .init(red: 1, green: 0.2, blue: 0.7, alpha: 1) }
        for source in [EyedropperSampleSource.currentLayer, .allVisibleLayers, .displayedColor] {
            for preservesTransparency in [true, false] {
                let sample = try await h.compare(at: .init(x: 6, y: 4), settings: .init(sampleSize: .fiveByFive,
                    statistic: .average, source: source, preservesTransparency: preservesTransparency,
                    returnsToPreviousTool: false))
                #expect(sample.alpha == (preservesTransparency ? 0 : 1))
                if !preservesTransparency {
                    #expect(sample.red > 0.999 && sample.green > 0.999 && sample.blue > 0.999)
                }
            }
        }
    }
}

@MainActor
private final class GPUEyedropperSemanticsHarness {
    let metal: MetalDeviceContext
    let store = StageOneLayerSurfaceStore()
    let serializer: LayerTextureSerializer
    let sampler: EyedropperSampler
    var document: ArtDocument

    init(layers: [LayerRecord], activeLayerID: LayerID, standard: ArtColorStandard = .stageOneDefault) throws {
        metal = try #require(MetalDeviceContext())
        serializer = LayerTextureSerializer(metalContext: metal)
        sampler = EyedropperSampler(serializer: serializer)
        document = ArtDocument(metadata: .init(name: "GPU sampler semantics", createdAt: Date(), updatedAt: Date()),
            canvasSize: .init(width: 7, height: 5), layers: layers, activeLayerID: activeLayerID)
        document.colorStandard = standard
        store.prepareTextures(for: document, metal: metal)
    }

    func restore(_ layerID: LayerID, color: (Int, Int) -> LinearPremultipliedColor) throws {
        let surfaceID = try #require(store.surfaceID(for: layerID))
        let texture = try #require(store.texture(for: surfaceID))
        try restore(texture, color: color)
    }

    func makeTexture(color: (Int, Int) -> LinearPremultipliedColor) throws -> MTLTexture {
        let format: MTLPixelFormat = document.colorStandard == .highPrecision ? .rgba16Float : .bgra8Unorm_srgb
        let texture = try #require(store.makeTexture(width: 7, height: 5, pixelFormat: format, metal: metal))
        try restore(texture, color: color)
        return texture
    }

    private func restore(_ texture: MTLTexture, color: (Int, Int) -> LinearPremultipliedColor) throws {
        let encoding: CanvasPixelEncoding = texture.pixelFormat == .rgba16Float
            ? .premultipliedRGBA16FloatLinear : .premultipliedBGRA8SRGB
        var bytes = Data(count: 7 * 5 * encoding.bytesPerPixel)
        bytes.withUnsafeMutableBytes { output in
            for y in 0..<5 { for x in 0..<7 {
                CanvasPixelCodec.write(color(x, y), into: output, offset: (y * 7 + x) * encoding.bytesPerPixel,
                    encoding: encoding)
            } }
        }
        try serializer.restore(snapshot: .init(width: 7, height: 5, bytesPerRow: 7 * encoding.bytesPerPixel,
            pixelData: bytes, encoding: encoding), into: texture)
    }

    func restoreMask(_ layerID: LayerID, value: (Int, Int) -> UInt8) throws {
        let texture = try #require(store.maskTexture(for: layerID))
        var bytes: [UInt8] = []
        for y in 0..<5 { for x in 0..<7 { bytes.append(value(x, y)) } }
        try serializer.restore(snapshot: .init(width: 7, height: 5, bytesPerRow: 7, pixelData: Data(bytes)), into: texture)
    }

    func compare(at point: CanvasPoint, settings: EyedropperSettings,
        content: ((LayerID) -> MTLTexture?)? = nil,
        display: ((LayerID) -> MTLTexture?)? = nil) async throws -> RGBAColor {
        let expected = try sampler.sampleVisibleColor(at: point, document: document, layerSurfaceStore: store,
            settings: settings, contentTextureForLayer: content, displayTextureForLayer: display)
        let ticket = try sampler.enqueueVisibleColor(at: point, document: document, layerSurfaceStore: store,
            metal: metal, settings: settings, contentTextureForLayer: content, displayTextureForLayer: display)
        let snapshot = try await Task.detached { try ticket.read() }.value
        let actual = sampler.sampledColor(from: snapshot, settings: settings)
        #expect(abs(actual.red - expected.red) < 0.008)
        #expect(abs(actual.green - expected.green) < 0.008)
        #expect(abs(actual.blue - expected.blue) < 0.008)
        #expect(abs(actual.alpha - expected.alpha) < 0.003)
        return actual
    }
}

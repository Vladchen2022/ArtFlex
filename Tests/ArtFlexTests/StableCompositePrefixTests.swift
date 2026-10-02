import Foundation
@preconcurrency import Metal
import Testing
@testable import ArtFlex

struct StableCompositePrefixTests {
    @Test func cachedPrefixMatchesCompleteCompositionAndInvalidatesEveryDependency() throws {
        let metal = try #require(MetalDeviceContext())
        let serializer = LayerTextureSerializer(metalContext: metal)
        let store = StageOneLayerSurfaceStore()
        let presenter = try StageOneCanvasPresenter(device: metal.device)
        let reference = try StageOneCanvasPresenter(device: metal.device)
        func solid(_ rgba: LinearPremultipliedColor, format: MTLPixelFormat = .rgba16Float) throws -> MTLTexture {
            let encoding: CanvasPixelEncoding = format == .rgba16Float ? .premultipliedRGBA16FloatLinear : .premultipliedBGRA8SRGB
            let texture = try #require(store.makeTexture(width: 8, height: 8, pixelFormat: format, metal: metal))
            var bytes = Data(count: 64 * encoding.bytesPerPixel)
            bytes.withUnsafeMutableBytes { out in
                for index in 0..<64 { CanvasPixelCodec.write(rgba, into: out, offset: index * encoding.bytesPerPixel, encoding: encoding) }
            }
            try serializer.restore(snapshot: .init(width: 8, height: 8, bytesPerRow: 8 * encoding.bytesPerPixel,
                pixelData: bytes, encoding: encoding), into: texture)
            return texture
        }
        for format in [MTLPixelFormat.bgra8Unorm_srgb, .rgba16Float] {
            presenter.invalidateCompositePrefixCache()
            let paper = try solid(.init(red: 0.8, green: 0.7, blue: 0.6, alpha: 1), format: format)
            let paint = try solid(.init(red: 0.3, green: 0.1, blue: 0.05, alpha: 0.5), format: format)
            let upper = try solid(.init(red: 0.02, green: 0.1, blue: 0.2, alpha: 0.4), format: format)
            let active = try solid(.init(red: 0.2, green: 0.2, blue: 0.03, alpha: 0.3), format: format)
            let mask = try #require(store.makeTexture(width: 8, height: 8, pixelFormat: .r8Unorm,
                storageMode: .shared, metal: metal))
            func writeMask(_ alpha: UInt8) {
                let bytes = [UInt8](repeating: alpha, count: 64)
                mask.replace(region: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0, withBytes: bytes, bytesPerRow: 8)
            }
            writeMask(170)
            var inputs: [CanvasLayerCompositeInput] = [
                .init(texture: paper, opacity: 1),
                .init(texture: paint, opacity: 0.7, blendMode: .multiply, layerMaskTexture: mask),
                .init(texture: upper, opacity: 0.8, blendMode: .screen, clipMaskTexture: paint, clipLayerMaskTexture: mask),
                .init(texture: active, opacity: 0.6),
                .init(texture: active, opacity: 0.3, curveAdjustmentLUTs: .identity)
            ]
            let output = try solid(.clear, format: format)
            let expected = try solid(.clear, format: format)
            var journal = LayerChangeJournal()
            var background = MTLClearColorMake(0, 0, 0, 0)
            func render(_ renderer: StageOneCanvasPresenter, target: MTLTexture, hint: CanvasCompositePrefixCacheHint?) throws -> LayerTextureSnapshot {
                let command = try #require(metal.commandQueue.makeCommandBuffer())
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = target
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                pass.colorAttachments[0].clearColor = background
                #expect(renderer.encode(layerInputs: inputs, cacheHint: hint, into: pass, commandBuffer: command))
                command.commit(); command.waitUntilCompleted()
                #expect(command.status == .completed)
                return try serializer.snapshot(texture: target)
            }
            func compare() throws {
                let cached = try render(presenter, target: output, hint: .init(count: 3, revisionTokens: [journal.cursor]))
                let uncached = try render(reference, target: expected, hint: nil)
                cached.pixelData.withUnsafeBytes { lhs in
                    uncached.pixelData.withUnsafeBytes { rhs in
                        for pixel in 0..<64 {
                            let a = CanvasPixelCodec.read(lhs, offset: pixel * cached.encoding.bytesPerPixel, encoding: cached.encoding)
                            let b = CanvasPixelCodec.read(rhs, offset: pixel * uncached.encoding.bytesPerPixel, encoding: uncached.encoding)
                            #expect(abs(a.red - b.red) < 0.007)
                            #expect(abs(a.green - b.green) < 0.007)
                            #expect(abs(a.blue - b.blue) < 0.007)
                            #expect(abs(a.alpha - b.alpha) < 0.004)
                        }
                    }
                }
            }
            let builds = presenter.debugPrefixCacheBuilds
            try compare()
            #expect(presenter.debugPrefixCacheBuilds == builds + 1)
            let hits = presenter.debugPrefixCacheHits
            try compare()
            #expect(presenter.debugPrefixCacheHits == hits + 1)
            inputs[3].opacity = 0.9 // Changed active layer must reuse the lower prefix.
            try compare()
            #expect(presenter.debugPrefixCacheBuilds == builds + 1)
            writeMask(70)
            journal.markAll() // In-place mask write has identical MTLTexture identity.
            try compare()
            #expect(presenter.debugPrefixCacheBuilds == builds + 2)
            inputs.swapAt(1, 2)
            try compare()
            #expect(presenter.debugPrefixCacheBuilds == builds + 3)
            inputs[1].opacity = 0.4
            try compare()
            #expect(presenter.debugPrefixCacheBuilds == builds + 4)
            inputs[0].texture = try solid(.init(red: 0.4, green: 0.5, blue: 0.6, alpha: 1), format: format)
            try compare()
            #expect(presenter.debugPrefixCacheBuilds == builds + 5)
            presenter.invalidateCompositePrefixCache()
            presenter.debugPreventsPrefixCacheAllocation = true
            try compare() // Memory pressure falls back to exact full composition.
            presenter.debugPreventsPrefixCacheAllocation = false
            // Exercise the ordinary fixed-function fast path with a translucent
            // prefix over an opaque background, where an extra intermediate can
            // expose quantization or an incorrectly applied background.
            inputs = inputs.map { input in
                var normal = input
                normal.blendMode = .normal
                normal.layerMaskTexture = nil
                normal.clipMaskTexture = nil
                normal.clipLayerMaskTexture = nil
                normal.curveAdjustmentLUTs = nil
                normal.opacity = 0.3
                return normal
            }
            background = MTLClearColorMake(0.8, 0.7, 0.6, 1)
            try compare()
            try compare()
            inputs[3].opacity = 0.55
            try compare()
            for index in 0..<3 { inputs[index].opacity = 0 }
            try compare() // An invisible prefix must not expose uninitialized pixels.
        }
    }
}

import Foundation
import Metal
import Testing
@testable import ArtFlex

struct RegionalCompositeTests {
    @Test func distributionsExcludeInvalidValuesAndKeepTailLatency() throws {
        let result = try #require(PerformanceDistribution(Array(1...100).map(Double.init) + [.nan, .infinity, -1]))
        #expect(result.count == 100)
        #expect(result.median == 50 && result.p95 == 95 && result.p99 == 99 && result.maximum == 100)
        #expect(PerformanceDistribution([]) == nil)
    }

    @Test(arguments: [ArtPixelFormat.rgba8, .rgba16Float])
    func partialBrushCompositionMatchesFullRenderAcrossMasksAndRevisions(format: ArtPixelFormat) throws {
        let metal = try #require(MetalDeviceContext())
        let serializer = LayerTextureSerializer(metalContext: metal)
        let store = StageOneLayerSurfaceStore()
        let renderer = try StageOneCanvasPresenter(device: metal.device)
        let reference = try StageOneCanvasPresenter(device: metal.device)
        let cache = CanvasRegionalComposite()
        let encoding = format.encoding
        func texture(_ color: LinearPremultipliedColor, width: Int = 64, height: Int = 64) throws -> MTLTexture {
            let texture = try #require(store.makeTexture(width: width, height: height, pixelFormat: encoding.metalPixelFormat, metal: metal))
            var bytes = Data(count: width * height * encoding.bytesPerPixel)
            bytes.withUnsafeMutableBytes { buffer in
                for pixel in 0..<(width * height) { CanvasPixelCodec.write(color, into: buffer, offset: pixel * encoding.bytesPerPixel, encoding: encoding) }
            }
            try serializer.restore(snapshot: .init(width: width, height: height, bytesPerRow: width * encoding.bytesPerPixel, pixelData: bytes, encoding: encoding), into: texture)
            return texture
        }
        let paper = try texture(.init(red: 0.4, green: 0.3, blue: 0.2, alpha: 0.6))
        let paint = try texture(.init(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4))
        let mask = try #require(store.makeTexture(width: 64, height: 64, pixelFormat: .r8Unorm, storageMode: .shared, metal: metal))
        let maskBytes = [UInt8](repeating: 160, count: 4096)
        mask.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0, withBytes: maskBytes, bytesPerRow: 64)
        var inputs: [CanvasLayerCompositeInput] = [
            .init(texture: paper, opacity: 0.8),
            .init(texture: paint, opacity: 0.7, blendMode: .multiply, layerMaskTexture: mask),
            .init(texture: paint, opacity: 0.6, blendMode: .screen, clipMaskTexture: paper),
            .init(texture: paper, opacity: 0.5, curveAdjustmentLUTs: .identity)
        ]
        let result = try texture(.clear, width: 96, height: 80)
        let expected = try texture(.clear, width: 96, height: 80)
        var journal = LayerChangeJournal()
        let dirty = PixelRegion(originX: 0, originY: 19, width: 8, height: 9)
        func compare() throws {
            let command = try #require(metal.commandQueue.makeCommandBuffer())
            func pass(_ texture: MTLTexture) -> MTLRenderPassDescriptor {
                let descriptor = MTLRenderPassDescriptor()
                descriptor.colorAttachments[0].texture = texture
                descriptor.colorAttachments[0].loadAction = .clear
                descriptor.colorAttachments[0].storeAction = .store
                descriptor.colorAttachments[0].clearColor = MTLClearColorMake(1, 1, 1, 1)
                return descriptor
            }
            #expect(cache.encode(inputs: inputs, revisions: [journal.cursor], changedRegion: dirty,
                canvasSize: .init(width: 64, height: 64), presenter: renderer, sampling: .linear,
                into: pass(result), command: command) == true)
            #expect(reference.encode(layerInputs: inputs, into: pass(expected), commandBuffer: command))
            command.commit(); command.waitUntilCompleted()
            #expect(command.status == .completed)
            let lhs = try serializer.snapshot(texture: result)
            let rhs = try serializer.snapshot(texture: expected)
            #expect(lhs == rhs)
        }
        try compare()
        let patch = try texture(.init(red: 0.8, green: 0.03, blue: 0.1, alpha: 0.9), width: 8, height: 9)
        try serializer.restore(snapshot: serializer.snapshot(texture: patch), into: paint, destinationX: 0, destinationY: 19)
        try compare()
        #expect(cache.partialFrameCount == 1)
        inputs[1].opacity = 0.1
        try compare()
        #expect(cache.fullFrameCount == 2)
        journal.markAll()
        try compare()
        #expect(cache.fullFrameCount == 3)
        cache.discard()
        try compare()
        #expect(cache.fullFrameCount == 4)
    }
}

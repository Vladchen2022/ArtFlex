import Metal
import Testing
@testable import ArtFlex

struct LayerMaskStrokeRendererTests {
    @Test
    func pressureControlsMaskStrokeSizeAndOpacity() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let renderer = try LayerMaskStrokeRenderer(device: device)
        var brush = BrushSettings.stageOneDefault
        brush.size = 40
        brush.opacity = 1
        brush.tipShape = .softRound
        brush.pressureSensitivity = 1
        brush.pressureSizeAmount = 1
        brush.pressureOpacityAmount = 1
        brush.sizeLowerBound = 0
        brush.sizePressureCurve = .init(points: [.init(x: 0, y: 0), .init(x: 1, y: 1)])
        brush.opacityPressureCurve = .init(points: [.init(x: 0, y: 0), .init(x: 1, y: 1)])

        let lowTexture = try makeMaskTexture(device: device, width: 64, height: 64)
        let highTexture = try makeMaskTexture(device: device, width: 64, height: 64)
        _ = renderer.render(
            samples: [.init(location: .init(x: 32, y: 32), pressure: 0.1)],
            brush: brush,
            targetValue: 1,
            into: lowTexture,
            commandQueue: queue,
            waitUntilCompleted: true
        )
        _ = renderer.render(
            samples: [.init(location: .init(x: 32, y: 32), pressure: 1)],
            brush: brush,
            targetValue: 1,
            into: highTexture,
            commandQueue: queue,
            waitUntilCompleted: true
        )

        let low = readMask(lowTexture)
        let high = readMask(highTexture)
        let center = (32 * 64) + 32
        let offset = (32 * 64) + 40
        #expect(low[center] < high[center])
        #expect(low[offset] == 0)
        #expect(high[offset] > 0)
    }

    @Test
    func softTipProducesAFeatheredMaskEdge() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let renderer = try LayerMaskStrokeRenderer(device: device)
        var brush = BrushSettings.stageOneDefault
        brush.size = 40
        brush.opacity = 1
        brush.tipShape = .softRound
        brush.pressureSizeAmount = 0
        brush.pressureOpacityAmount = 0
        let texture = try makeMaskTexture(device: device, width: 64, height: 64)

        _ = renderer.render(
            samples: [.init(location: .init(x: 32, y: 32), pressure: 1)],
            brush: brush,
            targetValue: 1,
            into: texture,
            commandQueue: queue,
            waitUntilCompleted: true
        )

        let bytes = readMask(texture)
        let center = bytes[(32 * 64) + 32]
        let feather = bytes[(32 * 64) + 47]
        #expect(center > feather)
        #expect(feather > 0)
    }

    @Test
    func blackAndWhiteTargetsCanHideAndRevealTheSameMask() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let renderer = try LayerMaskStrokeRenderer(device: device)
        var brush = BrushSettings.stageOneDefault
        brush.size = 24
        brush.opacity = 1
        brush.tipShape = .hardRound
        brush.pressureSizeAmount = 0
        brush.pressureOpacityAmount = 0
        let texture = try makeMaskTexture(device: device, width: 48, height: 48)

        _ = renderer.render(
            samples: [.init(location: .init(x: 24, y: 24), pressure: 1)],
            brush: brush,
            targetValue: 1,
            into: texture,
            commandQueue: queue,
            waitUntilCompleted: true
        )
        #expect(readMask(texture)[(24 * 48) + 24] > 245)

        _ = renderer.render(
            samples: [.init(location: .init(x: 24, y: 24), pressure: 1)],
            brush: brush,
            targetValue: 0,
            into: texture,
            commandQueue: queue,
            waitUntilCompleted: true
        )
        #expect(readMask(texture)[(24 * 48) + 24] < 10)
    }

    @Test
    func highFrequencyMaskPacketsRemainContinuousAcrossCommandBuffers() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let renderer = try LayerMaskStrokeRenderer(device: device)
        var brush = BrushSettings.stageOneDefault
        brush.size = 14
        brush.opacity = 1
        brush.tipShape = .hardRound
        brush.pressureSizeAmount = 0
        brush.pressureOpacityAmount = 0
        let texture = try makeMaskTexture(device: device, width: 256, height: 64)

        var previous: CanvasStrokeSample?
        for x in stride(from: 12, through: 244, by: 2) {
            let current = CanvasStrokeSample(location: .init(x: Double(x), y: 32), pressure: 1)
            let samples = previous.map { [$0, current] } ?? [current]
            _ = renderer.render(
                samples: samples,
                brush: brush,
                targetValue: 1,
                into: texture,
                commandQueue: queue
            )
            previous = current
        }
        let fence = try #require(queue.makeCommandBuffer())
        fence.commit()
        fence.waitUntilCompleted()

        let bytes = readMask(texture)
        for x in 12...244 {
            #expect(bytes[(32 * 256) + x] > 245)
        }
    }

    private func makeMaskTexture(device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        var zeroes = [UInt8](repeating: 0, count: width * height)
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: &zeroes,
            bytesPerRow: width
        )
        return texture
    }

    private func readMask(_ texture: MTLTexture) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height)
        texture.getBytes(
            &bytes,
            bytesPerRow: texture.width,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )
        return bytes
    }
}

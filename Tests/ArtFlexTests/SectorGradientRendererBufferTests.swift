import Foundation
import Testing
@preconcurrency import Metal
@testable import ArtFlex

struct SectorGradientRendererBufferTests {
    @Test
    func inFlightSectorPreviewsKeepIndependentVertexGeometry() throws {
        guard let metal = MetalDeviceContext() else {
            Issue.record("Metal unavailable")
            return
        }
        let renderer = SectorGradientRenderer(device: metal.device)
        let serializer = LayerTextureSerializer(metalContext: metal)
        let firstTarget = try #require(makeRenderTarget(device: metal.device, width: 16, height: 16))
        let secondTarget = try #require(makeRenderTarget(device: metal.device, width: 16, height: 16))
        let firstCommandBuffer = try #require(metal.commandQueue.makeCommandBuffer())
        let secondCommandBuffer = try #require(metal.commandQueue.makeCommandBuffer())
        let solidRed = GradientSettings(stops: [
            GradientStop(position: 0, color: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1)),
            GradientStop(position: 1, color: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1))
        ])

        renderer.encode(
            into: renderPass(for: firstTarget),
            commandBuffer: firstCommandBuffer,
            canvasSize: CanvasSize(width: 16, height: 16),
            center: CanvasPoint(x: 4, y: 8),
            pathPoints: [
                CanvasPoint(x: 0, y: 0),
                CanvasPoint(x: 8, y: 8),
                CanvasPoint(x: 0, y: 16),
                CanvasPoint(x: 0, y: 0)
            ],
            maxRadius: 12,
            color: .black,
            settings: solidRed
        )
        renderer.encode(
            into: renderPass(for: secondTarget),
            commandBuffer: secondCommandBuffer,
            canvasSize: CanvasSize(width: 16, height: 16),
            center: CanvasPoint(x: 12, y: 8),
            pathPoints: [
                CanvasPoint(x: 8, y: 0),
                CanvasPoint(x: 16, y: 8),
                CanvasPoint(x: 8, y: 16),
                CanvasPoint(x: 8, y: 0)
            ],
            maxRadius: 12,
            color: .black,
            settings: solidRed
        )

        // Both command buffers stay uncommitted until both encodes finish. A shared mutable
        // vertex buffer would therefore make the first pass consume the second geometry.
        firstCommandBuffer.commit()
        secondCommandBuffer.commit()
        firstCommandBuffer.waitUntilCompleted()
        secondCommandBuffer.waitUntilCompleted()

        let firstLeft = try serializer.samplePixel(texture: firstTarget, x: 3, y: 8)
        let firstRight = try serializer.samplePixel(texture: firstTarget, x: 13, y: 8)
        let secondLeft = try serializer.samplePixel(texture: secondTarget, x: 3, y: 8)
        let secondRight = try serializer.samplePixel(texture: secondTarget, x: 13, y: 8)
        #expect(firstLeft.alpha > 0.9)
        #expect(firstRight.alpha < 0.1)
        #expect(secondLeft.alpha < 0.1)
        #expect(secondRight.alpha > 0.9)
    }

    @Test
    func completedSectorPreviewsKeepTheReusableVertexPoolBounded() throws {
        guard let metal = MetalDeviceContext() else {
            Issue.record("Metal unavailable")
            return
        }
        let renderer = SectorGradientRenderer(device: metal.device)
        let target = try #require(makeRenderTarget(device: metal.device, width: 16, height: 16))

        for pointCount in [800, 1_600, 3_200, 6_400, 12_800, 25_600, 51_200, 102_400] {
            let commandBuffer = try #require(metal.commandQueue.makeCommandBuffer())
            let points = (0..<pointCount).map { index in
                let angle = (Double(index) / Double(pointCount - 1)) * Double.pi * 2
                return CanvasPoint(
                    x: 8 + (cos(angle) * 7),
                    y: 8 + (sin(angle) * 7)
                )
            }
            renderer.encode(
                into: renderPass(for: target),
                commandBuffer: commandBuffer,
                canvasSize: CanvasSize(width: 16, height: 16),
                center: CanvasPoint(x: 8, y: 8),
                pathPoints: points,
                maxRadius: 8,
                color: .black
            )
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }

        let stats = renderer.debugReusableVertexBufferPoolStats()
        #expect(stats.count <= 6)
        #expect(stats.bytes <= 8 * 1024 * 1024)
    }
}

private func makeRenderTarget(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm_srgb,
        width: width,
        height: height,
        mipmapped: false
    )
    descriptor.storageMode = .private
    descriptor.usage = [.renderTarget, .shaderRead]
    return device.makeTexture(descriptor: descriptor)
}

private func renderPass(for texture: MTLTexture) -> MTLRenderPassDescriptor {
    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = texture
    descriptor.colorAttachments[0].loadAction = .clear
    descriptor.colorAttachments[0].storeAction = .store
    descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    return descriptor
}

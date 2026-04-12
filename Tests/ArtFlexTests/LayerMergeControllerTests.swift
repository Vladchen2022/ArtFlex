import Foundation
import Testing
@preconcurrency import Metal
@testable import ArtFlex

struct LayerMergeControllerTests {
    @Test
    func mergeVisibleCompositesVisibleLayersInOrder() throws {
        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal unavailable")
            return
        }

        let serializer = LayerTextureSerializer(metalContext: metalContext)
        let mergeController = LayerMergeController(serializer: serializer)
        let layerSurfaceStore = StageOneLayerSurfaceStore()

        guard
            let destinationTexture = layerSurfaceStore.makeTexture(width: 4, height: 4, metal: metalContext),
            let sourceTexture = layerSurfaceStore.makeTexture(width: 4, height: 4, metal: metalContext)
        else {
            Issue.record("Texture allocation failed")
            return
        }

        try serializer.restore(
            snapshot: opaqueColorSnapshot(width: 4, height: 4, red: 0, green: 0, blue: 255),
            into: destinationTexture
        )
        try serializer.restore(
            snapshot: opaqueColorSnapshot(width: 4, height: 4, red: 255, green: 0, blue: 0),
            into: sourceTexture
        )

        try mergeController.mergeVisible(
            layers: [
                (texture: destinationTexture, opacity: 1, isVisible: true),
                (texture: sourceTexture, opacity: 0.5, isVisible: true)
            ],
            into: destinationTexture
        )

        let sampled = try serializer.samplePixel(texture: destinationTexture, x: 0, y: 0)
        #expect(sampled.red > 0.45)
        #expect(sampled.blue > 0.45)
        #expect(sampled.green < 0.05)
        #expect(sampled.alpha > 0.99)
    }
}

private func opaqueColorSnapshot(
    width: Int,
    height: Int,
    red: UInt8,
    green: UInt8,
    blue: UInt8
) -> LayerTextureSnapshot {
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
    for offset in stride(from: 0, to: pixels.count, by: 4) {
        pixels[offset] = blue
        pixels[offset + 1] = green
        pixels[offset + 2] = red
        pixels[offset + 3] = 255
    }
    return LayerTextureSnapshot(
        width: width,
        height: height,
        bytesPerRow: bytesPerRow,
        pixelData: Data(pixels)
    )
}

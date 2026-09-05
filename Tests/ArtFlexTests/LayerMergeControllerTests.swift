import Foundation
import Testing
@preconcurrency import Metal
@testable import ArtFlex

struct LayerMergeControllerTests {
    @Test
    func compositeAllocationFailureDoesNotFallBackOrOverwriteDestination() throws {
        let metal = try #require(MetalDeviceContext())
        let presenter = try StageOneCanvasPresenter(device: metal.device)
        let controller = LayerMergeController(metalContext: metal, canvasPresenter: presenter)
        let store = StageOneLayerSurfaceStore()
        let source = try #require(store.makeTexture(width: 4, height: 4, metal: metal))
        let target = try #require(store.makeTexture(width: 4, height: 4, metal: metal))
        let serializer = LayerTextureSerializer(metalContext: metal)
        let before = opaqueColorSnapshot(width: 4, height: 4, red: 0, green: 0, blue: 255)
        try serializer.restore(snapshot: before, into: target)
        try serializer.restore(snapshot: opaqueColorSnapshot(width: 4, height: 4,
            red: 255, green: 0, blue: 0), into: source)
        presenter.debugPreventsCompositeTextureAllocation = true
        #expect(throws: (any Error).self) {
            try controller.mergeVisible(layers: [
                .init(texture: target, opacity: 1),
                .init(texture: source, opacity: 1, blendMode: .multiply)
            ], into: target)
        }
        #expect(try serializer.snapshot(texture: target) == before)
        presenter.debugPreventsCompositeTextureAllocation = false
        try controller.mergeVisible(layers: [
            .init(texture: target, opacity: 1),
            .init(texture: source, opacity: 1, blendMode: .multiply)
        ], into: target)
        #expect(try serializer.snapshot(texture: target) != before)
    }

    @Test
    func mergeVisibleCompositesVisibleLayersInOrder() throws {
        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal unavailable")
            return
        }

        let serializer = LayerTextureSerializer(metalContext: metalContext)
        let canvasPresenter = try StageOneCanvasPresenter(device: metalContext.device)
        let mergeController = LayerMergeController(
            metalContext: metalContext,
            canvasPresenter: canvasPresenter
        )
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

    @Test
    func enhancedCompositorAppliesMultiplyAndClipping() throws {
        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal unavailable")
            return
        }
        let serializer = LayerTextureSerializer(metalContext: metalContext)
        let presenter = try StageOneCanvasPresenter(device: metalContext.device)
        let controller = LayerMergeController(metalContext: metalContext, canvasPresenter: presenter)
        let store = StageOneLayerSurfaceStore()
        guard let base = store.makeTexture(width: 2, height: 1, metal: metalContext),
              let source = store.makeTexture(width: 2, height: 1, metal: metalContext),
              let targetMask = store.makeTexture(
                width: 2,
                height: 1,
                pixelFormat: .r8Unorm,
                metal: metalContext
              ) else {
            Issue.record("Texture allocation failed")
            return
        }

        let baseSnapshot = LayerTextureSnapshot(
            width: 2,
            height: 1,
            bytesPerRow: 8,
            pixelData: Data([255, 0, 0, 255, 0, 0, 0, 0])
        )
        try serializer.restore(snapshot: baseSnapshot, into: base)
        try serializer.restore(
            snapshot: opaqueColorSnapshot(width: 2, height: 1, red: 255, green: 0, blue: 0),
            into: source
        )
        try controller.mergeVisible(
            layers: [
                CanvasLayerCompositeInput(texture: base, opacity: 1),
                CanvasLayerCompositeInput(
                    texture: source,
                    opacity: 1,
                    blendMode: .multiply,
                    clipMaskTexture: base
                )
            ],
            into: base
        )

        let clippedOpaque = try serializer.samplePixel(texture: base, x: 0, y: 0)
        let clippedTransparent = try serializer.samplePixel(texture: base, x: 1, y: 0)
        #expect(clippedOpaque.red < 0.05)
        #expect(clippedOpaque.blue < 0.05)
        #expect(clippedOpaque.alpha > 0.99)
        #expect(clippedTransparent.alpha < 0.01)

        try serializer.restore(
            snapshot: opaqueColorSnapshot(width: 2, height: 1, red: 0, green: 0, blue: 255),
            into: base
        )
        try serializer.restore(
            snapshot: LayerTextureSnapshot(
                width: 2,
                height: 1,
                bytesPerRow: 2,
                pixelData: Data([0, 255])
            ),
            into: targetMask
        )
        try controller.mergeVisible(
            layers: [
                CanvasLayerCompositeInput(
                    texture: base,
                    opacity: 1,
                    layerMaskTexture: targetMask
                ),
                CanvasLayerCompositeInput(
                    texture: source,
                    opacity: 1,
                    clipMaskTexture: base,
                    clipLayerMaskTexture: targetMask
                )
            ],
            into: base
        )

        let maskedOut = try serializer.samplePixel(texture: base, x: 0, y: 0)
        let maskedIn = try serializer.samplePixel(texture: base, x: 1, y: 0)
        #expect(maskedOut.alpha < 0.01)
        #expect(maskedIn.red > 0.99)
        #expect(maskedIn.blue < 0.01)
        #expect(maskedIn.alpha > 0.99)
    }

    @Test
    func curveAdjustmentInputChangesAccumulatedBackdropWithoutPaintingPixels() throws {
        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal unavailable")
            return
        }
        let serializer = LayerTextureSerializer(metalContext: metalContext)
        let presenter = try StageOneCanvasPresenter(device: metalContext.device)
        let controller = LayerMergeController(metalContext: metalContext, canvasPresenter: presenter)
        let store = StageOneLayerSurfaceStore()
        guard let base = store.makeTexture(width: 2, height: 2, metal: metalContext),
              let adjustmentPlaceholder = store.makeTexture(width: 2, height: 2, metal: metalContext) else {
            Issue.record("Texture allocation failed")
            return
        }

        try serializer.restore(
            snapshot: opaqueColorSnapshot(width: 2, height: 2, red: 64, green: 64, blue: 64),
            into: base
        )
        try serializer.restore(
            snapshot: opaqueColorSnapshot(width: 2, height: 2, red: 0, green: 0, blue: 0),
            into: adjustmentPlaceholder
        )

        var parameters = CurveAdjustmentParameters.neutral
        parameters.rgbCurve = CurveChannelState(points: [
            .init(x: 0, y: 0),
            .init(x: 0.5, y: 0.85),
            .init(x: 1, y: 1)
        ])
        try controller.mergeVisible(
            layers: [
                CanvasLayerCompositeInput(texture: base, opacity: 1),
                CanvasLayerCompositeInput(
                    texture: adjustmentPlaceholder,
                    opacity: 1,
                    curveAdjustmentLUTs: CurveLUTBuilder.buildAll(from: parameters)
                )
            ],
            into: base
        )

        let adjusted = try serializer.samplePixel(texture: base, x: 0, y: 0)
        #expect(adjusted.red > 0.45)
        #expect(adjusted.green > 0.45)
        #expect(adjusted.blue > 0.45)
        #expect(adjusted.alpha > 0.99)
    }

    @Test
    func compositorReleasesIdleTexturesFromPreviousDrawableSize() throws {
        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal unavailable")
            return
        }
        let presenter = try StageOneCanvasPresenter(device: metalContext.device)
        let controller = LayerMergeController(metalContext: metalContext, canvasPresenter: presenter)
        let store = StageOneLayerSurfaceStore()

        for size in [64, 128] {
            guard let destination = store.makeTexture(width: size, height: size, metal: metalContext),
                  let source = store.makeTexture(width: size, height: size, metal: metalContext),
                  let mask = store.makeTexture(
                    width: size,
                    height: size,
                    pixelFormat: .r8Unorm,
                    metal: metalContext
                  ) else {
                Issue.record("Texture allocation failed")
                return
            }
            try controller.mergeVisible(
                layers: [
                    CanvasLayerCompositeInput(texture: destination, opacity: 1),
                    CanvasLayerCompositeInput(texture: source, opacity: 1, layerMaskTexture: mask)
                ],
                into: destination
            )

            let dimensions = presenter.debugCompositeTexturePoolDimensions()
            #expect(!dimensions.isEmpty)
            #expect(dimensions.allSatisfy { $0.width == size && $0.height == size })
        }
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

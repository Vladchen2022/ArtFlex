import Foundation
import Metal
import Testing
@testable import ArtFlex

struct TextureAdjustmentRendererTests {
    @Test(arguments: [ArtPixelFormat.rgba8, .rgba16Float])
    func previewIsDeterministicAndNeverMutatesBaseline(format: ArtPixelFormat) throws {
        let metal = try #require(MetalDeviceContext())
        var document = ArtDocument.stageOneDefault()
        document.canvasSize = .init(width: 64, height: 64)
        document.colorStandard = format == .rgba16Float ? .highPrecision : .stageOneDefault
        let store = StageOneLayerSurfaceStore()
        store.prepareTextures(for: document, metal: metal)
        let id = try #require(store.surfaceID(for: document.activeLayerID))
        let source = try #require(store.readTexture(for: id))
        let serializer = LayerTextureSerializer(metalContext: metal)
        let baseline = try serializer.snapshot(texture: source)
        let renderer = TextureAdjustmentRenderer(metal: metal, serializer: serializer)
        let state = TextureFillGestureState(layerID: document.activeLayerID, surfaceID: id,
            anchorPoint: .init(x: 16, y: 16), sessionSeed: 42, baseTexture: source,
            rawEdgePoints: [], tipSettings: .proceduralDefault,
            brush: WorkspaceState.stageOneDefault.toolSession.brush, color: .black)
        let mask = SelectionMaskRegion(originX: 16, originY: 16, width: 32, height: 32,
            alphaBytes: Data(repeating: 255, count: 32 * 32))
        let first = try renderer.render(state: state, mask: mask, angle: 0, alphaLocked: false, cancellation: WorkCancellation())
        let second = try renderer.render(state: state, mask: mask, angle: 0, alphaLocked: false, cancellation: WorkCancellation())
        let firstPixels = try serializer.snapshot(texture: first)
        #expect(try firstPixels == serializer.snapshot(texture: second))
        #expect(firstPixels != baseline)
        #expect(try serializer.snapshot(texture: source) == baseline)
        let outside = try serializer.snapshot(texture: first, originX: 0, originY: 0, width: 16, height: 16)
        #expect(outside.pixelData.allSatisfy { $0 == 0 })
        let cancelled = WorkCancellation()
        cancelled.cancel()
        #expect(throws: CancellationError.self) {
            try renderer.render(state: state, mask: mask, angle: 0, alphaLocked: false, cancellation: cancelled)
        }
        #expect(try serializer.snapshot(texture: source) == baseline)
    }
}

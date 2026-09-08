import Foundation
import Metal
import Testing
@testable import ArtFlex

struct SparseLayerTextureTests {
    @Test func compactionUsesActualOccupiedTilesAndPreservesEdgePixels() throws {
        let metal = try #require(MetalDeviceContext())
        guard SparseLayerTexture.isSupported(by: metal.device) else { return }
        var doc = ArtDocument.stageOneDefault()
        doc.canvasSize = .init(width: 2049, height: 1025)
        let store = StageOneLayerSurfaceStore(usesSparseStorage: true)
        store.prepareTextures(for: doc, metal: metal)
        let id = try #require(store.surfaceID(for: doc.activeLayerID))
        let dense = try #require(store.makeTexture(width: 2049, height: 1025, metal: metal))
        let serializer = LayerTextureSerializer(metalContext: metal)
        var bytes = Data(repeating: 0, count: 2049 * 1025 * 4)
        bytes[0] = 41
        bytes[3] = 255
        bytes[bytes.count - 1] = 255
        try serializer.restore(snapshot: .init(width: 2049, height: 1025, bytesPerRow: 2049 * 4, pixelData: bytes), into: dense)
        store.swapTexture(for: id, with: dense)
        store.compactTexture(for: id)
        let sparse = try #require(store.readTexture(for: id))
        #expect(sparse.heap?.type == .sparse)
        #expect(try serializer.snapshot(texture: sparse).pixelData == bytes)
        #expect(store.allocatedPixelBytes < bytes.count / 4)
    }

    @Test func mapsOnlyTouchedTilesAndPreservesPixelsWhenGrowing() throws {
        let metal = try #require(MetalDeviceContext())
        guard SparseLayerTexture.isSupported(by: metal.device) else { return }
        let layer = try #require(SparseLayerTexture(size: CanvasSize(width: 4096, height: 4096), metal: metal))
        let serializer = LayerTextureSerializer(metalContext: metal)
        #expect(layer.mappedTiles.isEmpty)
        #expect(layer.allocatedBytes < 4096 * 4096 * 4)
        let area = PixelRegion(originX: 3, originY: 5, width: 2, height: 2)
        try layer.prepareForWrite(in: area)
        #expect(layer.mappedTiles.count == 1)
        let pixels = Data(repeating: 127, count: 16)
        try serializer.restore(snapshot: .init(width: 2, height: 2, bytesPerRow: 8, pixelData: pixels),
                               into: layer.texture, destinationX: 3, destinationY: 5)
        try layer.prepareForWrite(in: PixelRegion(originX: 4000, originY: 4000, width: 10, height: 10))
        #expect(layer.mappedTiles.count == 2)
        #expect(try serializer.snapshot(texture: layer.texture, originX: 3, originY: 5, width: 2, height: 2).pixelData == pixels)
        #expect(try serializer.snapshot(texture: layer.texture, originX: 2000, originY: 2000, width: 2, height: 2).pixelData == Data(repeating: 0, count: 16))
        #expect(try serializer.snapshot(texture: layer.texture, originX: 4000, originY: 4000, width: 2, height: 2).pixelData == Data(repeating: 0, count: 16))
        let copy = try layer.cloned()
        #expect(copy.texture !== layer.texture)
        #expect(copy.mappedTiles == layer.mappedTiles)
        try serializer.restore(snapshot: .init(width: 2, height: 2, bytesPerRow: 8, pixelData: Data(repeating: 0, count: 16)),
                               into: copy.texture, destinationX: 3, destinationY: 5)
        #expect(try serializer.snapshot(texture: layer.texture, originX: 3, originY: 5, width: 2, height: 2).pixelData == pixels)
    }
}

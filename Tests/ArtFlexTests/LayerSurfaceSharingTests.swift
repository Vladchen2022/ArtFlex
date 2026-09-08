import Foundation
import Metal
import Testing
@testable import ArtFlex

struct LayerSurfaceSharingTests {
    @Test func contentAndMaskDetachOnlyForTheWrittenLayer() throws {
        let metal = try #require(MetalDeviceContext())
        let serializer = LayerTextureSerializer(metalContext: metal)
        var doc = ArtDocument.stageOneDefault()
        doc.canvasSize = .init(width: 16, height: 16)
        let first = doc.layers[0].id, second = doc.layers[1].id
        let original = StageOneLayerSurfaceStore()
        original.prepareTextures(for: doc, metal: metal)
        let a = try #require(original.surfaceID(for: first))
        let b = try #require(original.surfaceID(for: second))
        let originalA = try #require(original.texture(for: a))
        try serializer.restore(snapshot: .init(width: 16, height: 16, bytesPerRow: 64,
                                               pixelData: Data(repeating: 63, count: 1024)), into: originalA)
        let mask = try #require(original.makeTexture(width: 16, height: 16, pixelFormat: .r8Unorm, metal: metal))
        original.setMaskTexture(mask, for: first)
        original.fillMaskTexture(for: first, value: 1, metal: metal)
        let child = original.sharedCopy()
        #expect(original.readTexture(for: a) === child.readTexture(for: a))
        #expect(original.readTexture(for: b) === child.readTexture(for: b))
        #expect(original.readMaskTexture(for: first) === child.readMaskTexture(for: first))
        let childA = try #require(child.texture(for: a))
        #expect(childA !== original.readTexture(for: a))
        #expect(original.readTexture(for: b) === child.readTexture(for: b))
        #expect(try serializer.snapshot(texture: childA).pixelData == Data(repeating: 63, count: 1024))
        try serializer.restore(snapshot: .init(width: 16, height: 16, bytesPerRow: 64,
                                               pixelData: Data(repeating: 127, count: 1024)), into: childA)
        #expect(try serializer.snapshot(texture: originalA).pixelData == Data(repeating: 63, count: 1024))
        child.fillMaskTexture(for: first, value: 0, metal: metal)
        #expect(child.readMaskTexture(for: first) !== original.readMaskTexture(for: first))
        let originalMask = try #require(original.readMaskTexture(for: first))
        #expect(try serializer.snapshot(texture: originalMask).pixelData == Data(repeating: 255, count: 256))
        // Calling writable access again without another owner does not make another copy.
        #expect(child.texture(for: a) === childA)
    }

    @Test func sparseStoresShareThenDetachOnlyMappedContent() throws {
        let metal = try #require(MetalDeviceContext())
        guard SparseLayerTexture.isSupported(by: metal.device) else { return }
        var doc = ArtDocument.stageOneDefault()
        doc.canvasSize = .init(width: 4096, height: 4096)
        let store = StageOneLayerSurfaceStore(usesSparseStorage: true)
        store.prepareTextures(for: doc, metal: metal)
        let id = try #require(store.surfaceID(for: doc.activeLayerID))
        _ = try #require(store.writableTexture(for: id, region: .init(originX: 10, originY: 10, width: 2, height: 2)))
        let child = store.sharedCopy()
        #expect(child.readTexture(for: id) === store.readTexture(for: id))
        _ = try #require(child.writableTexture(for: id, region: .init(originX: 2000, originY: 2000, width: 2, height: 2)))
        #expect(child.readTexture(for: id) !== store.readTexture(for: id))
        #expect(child.allocatedPixelBytes < 4096 * 4096 * 4 / 100)
    }
}

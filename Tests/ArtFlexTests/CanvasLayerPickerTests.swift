import Foundation
import Metal
import Testing
@testable import ArtFlex

@MainActor
struct CanvasLayerPickerTests {
    @Test(arguments: [ArtPixelFormat.rgba8, .rgba16Float])
    func hitsUseStackOrderTransparencyGroupOpacityAndLocks(format: ArtPixelFormat) throws {
        let h = try PickerHarness(format: format)
        var doc = h.document
        #expect(try h.hits(doc).map(\.id) == [h.top, h.bottom])
        doc.layers[1].isLocked = true
        let locked = try h.hits(doc)
        #expect(locked.first?.isLocked == true)
        #expect(locked.first?.groupPath == "人物")
        doc.layers[1].opacity = 0
        #expect(try h.hits(doc).map(\.id) == [h.bottom])
        doc.layers[1].opacity = 1; doc.layers[1].isVisible = false
        #expect(try h.hits(doc).map(\.id) == [h.bottom])
        doc.layers[1].isVisible = true; doc.layers[2].isVisible = false
        #expect(try h.hits(doc).map(\.id) == [h.bottom])
        try writeConveniencePixels(.clear, texture: h.texture(h.bottom), serializer: h.serializer)
        #expect(try h.hits(doc).isEmpty)
        #expect(try h.hits(h.document, at: .init(x: -1, y: 0)).isEmpty)
        #expect(try h.hits(h.document, at: .init(x: 512, y: 0)).isEmpty)
        #expect(try h.hits(h.document, at: .init(x: .nan, y: 0)).isEmpty)
    }

    @Test(arguments: [ArtPixelFormat.rgba8, .rgba16Float])
    func masksClipsAndTheirPreviewsMatchCanonicalCoverage(format: ArtPixelFormat) throws {
        let h = try PickerHarness(format: format)
        var doc = h.document
        doc.layers[0].mask = .init(); doc.layers[2].mask = .init()
        doc.layers[2].clipTargetLayerID = h.bottom
        try h.surfaces.requireTextures(for: doc, metal: h.metal)
        #expect(h.surfaces.fillMaskTexture(for: h.bottom, value: 0, metal: h.metal))
        #expect(try h.hits(doc).isEmpty)
        #expect(h.surfaces.fillMaskTexture(for: h.bottom, value: 0.5, metal: h.metal))
        #expect(h.surfaces.fillMaskTexture(for: h.top, value: 0, metal: h.metal))
        #expect(try h.hits(doc).map(\.id) == [h.bottom])
        doc.layers[2].mask?.isEnabled = false
        #expect(try h.hits(doc).map(\.id) == [h.top, h.bottom])
        let pending = try h.picker.enqueuePreview(layerID: h.top, document: doc, surfaces: h.surfaces, serializer: h.serializer, metal: h.metal)
        let preview = try #require(pending.read().first)
        #expect(preview.width == 256 && preview.height == 128)
        let pixel = preview.linearPixel(x: 128, y: 64)
        #expect(abs(pixel.alpha - 0.5) < 0.01)
        #expect(abs(pixel.blue - 0.5) < 0.01)
        #expect(pixel.red < 0.01)
        try writeConveniencePixels(.clear, texture: h.texture(h.bottom), serializer: h.serializer)
        #expect(try h.hits(doc).isEmpty)
    }

    @Test func pointHitUsesActualPixelInsteadOfLayerBounds() throws {
        let h = try PickerHarness(format: .rgba8)
        let texture = try h.texture(h.top)
        try writeConveniencePixels(.clear, texture: texture, serializer: h.serializer)
        try h.serializer.restore(snapshot: .init(width: 1, height: 1, bytesPerRow: 4,
            pixelData: Data([255, 0, 0, 255])), into: texture, destinationX: 40, destinationY: 30)
        #expect(try h.hits(h.document, at: .init(x: 40.8, y: 30.2)).map(\.id) == [h.top, h.bottom])
        #expect(try h.hits(h.document, at: .init(x: 40, y: 31)).map(\.id) == [h.bottom])
        #expect(try h.hits(h.document, at: .init(x: 40, y: 225)).map(\.id) == [h.bottom])
    }

    @Test func queuedHitReadbackKeepsPointInTimePixels() throws {
        let h = try PickerHarness(format: .rgba8)
        let readback = try h.picker.enqueue(at: .init(x: 10, y: 10), document: h.document, surfaces: h.surfaces, serializer: h.serializer)
        try writeConveniencePixels(.clear, texture: h.texture(h.top), serializer: h.serializer)
        #expect(try readback.read().map(\.id) == [h.top, h.bottom])
        #expect(try h.hits(h.document).map(\.id) == [h.bottom])
    }
}

@MainActor
private struct PickerHarness {
    let metal: MetalDeviceContext
    let surfaces = StageOneLayerSurfaceStore()
    let serializer: LayerTextureSerializer
    let picker = CanvasLayerPicker()
    var document: ArtDocument
    let bottom = LayerID(), group = LayerID(), top = LayerID()
    init(format: ArtPixelFormat) throws {
        metal = try #require(MetalDeviceContext()); serializer = .init(metalContext: metal)
        document = ArtDocument.stageOneDefault()
        document.canvasSize = .init(width: 512, height: 256)
        document.colorStandard = format == .rgba16Float ? .highPrecision : .stageOneDefault
        document.layers = [
            .init(id: bottom, name: "下层", isVisible: true, isLocked: false, locksTransparentPixels: false, opacity: 1),
            .init(id: group, name: "人物", kind: .group, isVisible: true, isLocked: false, locksTransparentPixels: false, opacity: 1),
            .init(id: top, name: "上层", parentID: group, isVisible: true, isLocked: false, locksTransparentPixels: false, opacity: 1)
        ]
        document.activeLayerID = top
        try surfaces.requireTextures(for: document, metal: metal)
        try writeConveniencePixels(.init(red: 1, green: 0, blue: 0, alpha: 1), texture: texture(bottom), serializer: serializer)
        try writeConveniencePixels(.init(red: 0, green: 0, blue: 1, alpha: 1), texture: texture(top), serializer: serializer)
    }
    func texture(_ id: LayerID) throws -> MTLTexture {
        let surface = try #require(surfaces.surfaceID(for: id))
        return try #require(surfaces.texture(for: surface))
    }
    func hits(_ doc: ArtDocument, at point: CanvasPoint = .init(x: 10, y: 10)) throws -> [CanvasLayerPickCandidate] {
        try picker.enqueue(at: point, document: doc, surfaces: surfaces, serializer: serializer).read()
    }
}

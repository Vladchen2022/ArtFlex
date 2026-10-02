import Foundation
import Metal
import Testing
@testable import ArtFlex

struct BoundedSelectionOptimizationTests {
    @Test func fourKLocalSegmentUsesOnlyVisitedPagesAndReturnsExactPatch() throws {
        let settings = SmartSelectionSettings(tolerance: 0, isAntiAliased: false, isContiguous: true)
        var sampled = 0
        func pixel(_ x: Int, _ y: Int) -> PremultipliedSRGBAPixel {
            sampled += 1
            let value: UInt8 = (100..<164).contains(x) && (200..<264).contains(y) ? 0 : 255
            return .init(red: value, green: value, blue: value, alpha: 255)
        }
        let bounded = try #require(try SmartSelectionSegmenter.segment(originX: 0, originY: 0,
            width: 4096, height: 4096, seedPoint: .init(x: 120, y: 220), settings: settings,
            boundedResult: true, pixelAt: pixel))
        #expect(bounded.originX == 100 && bounded.originY == 200)
        #expect(bounded.width == 64 && bounded.height == 64)
        #expect(bounded.selectedPixelCount == 4096)
        #expect(bounded.alphaBytes.allSatisfy { $0 == 255 })
        #expect(bounded.workingStorageByteCount < 256 * 1024)
        #expect(sampled < 10_000)
        let dense = try #require(try SmartSelectionSegmenter.segment(originX: 0, originY: 0,
            width: 4096, height: 4096, seedPoint: .init(x: 120, y: 220), settings: settings, pixelAt: pixel))
        let boundedShape = SelectionShape.mask(canvasWidth: 4096, canvasHeight: 4096,
            patch: .init(originX: bounded.originX, originY: bounded.originY, width: bounded.width,
                         height: bounded.height, alphaBytes: Data(bounded.alphaBytes)))
        #expect(boundedShape.maskData?.alphaBytes == Data(dense.alphaBytes))
        #expect(boundedShape.maskData?.storedByteCount == 4096)
        print("ArtFlexLocalSelection canvas=4096 selected=4096 stateAndOutputBytes=\(bounded.workingStorageByteCount) storedMaskBytes=\(boundedShape.maskData!.storedByteCount)")
    }

    @Test func maskPatchKeepsLegacyEncodingAndRegionAccessExact() throws {
        let patch = SelectionMaskCombiner.Patch(originX: 10, originY: 20, width: 3, height: 2,
            alphaBytes: Data([0, 64, 255, 128, 255, 0]))
        let mask = SelectionMaskData(canvasWidth: 64, canvasHeight: 48, patch: patch)
        #expect(mask.storedByteCount == 6)
        #expect(mask.alphaByte(at: 20 * 64 + 11) == 64)
        #expect(mask.alphaByte(at: 0) == 0)
        #expect(mask.alphaByte(at: -1) == nil)
        #expect(mask.alphaBytes(in: .init(originX: 11, originY: 20, width: 2, height: 2)) == Data([64, 255, 255, 0]))
        let data = try JSONEncoder().encode(mask)
        let legacy = try JSONDecoder().decode(LegacySelectionMaskFixture.self, from: data)
        #expect(legacy.canvasWidth == 64 && legacy.canvasHeight == 48)
        #expect(legacy.alphaBytes.count == 64 * 48)
        #expect(legacy.alphaBytes[21 * 64 + 10] == 128)
        #expect(try JSONDecoder().decode(SelectionMaskData.self, from: data) == mask)
        #expect(try JSONDecoder().decode(SelectionMaskData.self, from: JSONEncoder().encode(legacy)) == mask)
    }

    @Test(arguments: SelectionCombineMode.allCases)
    func boundedBooleanAlgebraMatchesExistingFullCanvas(mode: SelectionCombineMode) throws {
        let size = CanvasSize(width: 32, height: 24)
        let baseShape = SelectionShape.mask(canvasWidth: size.width, canvasHeight: size.height,
            patch: .init(originX: 5, originY: 6, width: 3, height: 2, alphaBytes: Data([0, 64, 128, 255, 128, 64])))
        let incoming = SelectionMaskCombiner.Patch(originX: 6, originY: 5, width: 3, height: 3,
            alphaBytes: Data([0, 255, 128, 64, 128, 255, 255, 0, 64]))
        let baseMask = try #require(baseShape.maskData)
        let legacy = SelectionMaskCombiner.combineCanvas(base: baseMask.alphaBytes, baseBounds: baseShape.bounds,
            incoming: incoming, canvasWidth: size.width, canvasHeight: size.height, mode: mode)
        let bounded = SelectionMaskCombiner.combineBounded(base: baseMask, incoming: incoming,
            canvasWidth: size.width, canvasHeight: size.height, mode: mode)
        #expect(bounded.maskData?.alphaBytes == legacy.alphaBytes)
        #expect(bounded.bounds == legacy.bounds)
        #expect((bounded.maskData?.storedByteCount ?? 0) <= 12)
    }

    @Test func translationResizeAndMorphologyKeepOnlyTheirRegion() throws {
        let shape = SelectionShape.mask(canvasWidth: 4096, canvasHeight: 4096,
            patch: .init(originX: 2, originY: 3, width: 3, height: 2, alphaBytes: Data(repeating: 255, count: 6)))
        let moved = shape.translatedBy(x: -3, y: -3)
        #expect(moved.bounds == .init(origin: .init(x: 0, y: 0), size: .init(x: 2, y: 2)))
        #expect(moved.maskData?.storedByteCount == 4)
        let clipped = shape.clamped(to: .init(width: 4, height: 4))
        #expect(clipped.maskData?.storedByteCount == 2)
        let expanded = try #require(SelectionRefinement.expanded(shape, canvasSize: .init(width: 4096, height: 4096), radiusPixels: 2))
        #expect(expanded.bounds == .init(origin: .init(x: 0, y: 1), size: .init(x: 7, y: 6)))
        #expect(expanded.maskData?.storedByteCount == 42)
    }

#if DEBUG
    @Test(arguments: [false, true])
    func precisionFillMatchesLegacyIncludingFractionalSelectionAndAlphaLock(alphaLock: Bool) throws {
        let metal = try #require(MetalDeviceContext())
        let serializer = LayerTextureSerializer(metalContext: metal)
        let texture = try makePrecisionFixture(side: 96, metal: metal, serializer: serializer)
        let engine = BucketFillEngine(serializer: serializer)
        let layerID = LayerID()
        let selection = SelectionShape.mask(canvasWidth: 96, canvasHeight: 96,
            patch: .init(originX: 20, originY: 20, width: 24, height: 24,
                         alphaBytes: Data(repeating: 128, count: 24 * 24)))
        let settings = FillSettings(tolerance: 0.137, isContiguous: true, sampleSource: .currentLayer)
        let color = RGBAColor(red: 0.15, green: 0.7, blue: 0.3, alpha: 0.75)
        let current = try #require(try engine.makeFillPlan(layerID: layerID, texture: texture,
            at: .init(x: 24, y: 24), color: color, alphaLockEnabled: alphaLock,
            selectionShape: selection, isKnownTransparent: false, settings: settings))
        let legacy = try #require(try engine.debugMakeLegacyPrecisionFillPlan(layerID: layerID,
            destination: texture, reference: texture, point: .init(x: 24, y: 24), color: color,
            alphaLock: alphaLock, selection: selection, settings: settings))
        #expect(current.destinationX == legacy.destinationX && current.destinationY == legacy.destinationY)
        #expect(current.restoreSnapshot == legacy.restoreSnapshot)
        #expect(current.historySnapshot == legacy.historySnapshot)
    }
#endif

    @Test func fourKPrecisionFillReadsOneTileAndReturnsOnlyChangedRegion() throws {
        let metal = try #require(MetalDeviceContext())
        let serializer = LayerTextureSerializer(metalContext: metal)
        let texture = try makePrecisionFixture(side: 4096, metal: metal, serializer: serializer)
        let engine = BucketFillEngine(serializer: serializer)
        let plan = try #require(try engine.makeFillPlan(layerID: LayerID(), texture: texture,
            at: .init(x: 24, y: 24), color: .init(red: 0.1, green: 0.8, blue: 0.3, alpha: 1),
            alphaLockEnabled: false, selectionShape: nil, isKnownTransparent: false))
        #expect(plan.destinationX == 20 && plan.destinationY == 20)
        #expect(plan.restoreSnapshot.width == 32 && plan.restoreSnapshot.height == 32)
        #expect(plan.restoreSnapshot.encoding == .premultipliedRGBA16FloatLinear)
        #expect(plan.referenceReadbackByteCount == 512 * 512 * 8 + 8)
        #expect(plan.restoreSnapshot.pixelData.count == 32 * 32 * 8)
        print("ArtFlexLocalFill canvas=4096 format=rgba16Float referenceReadbackBytes=\(plan.referenceReadbackByteCount) historyBytes=\(plan.historySnapshot!.texture.pixelData.count) resultBytes=\(plan.restoreSnapshot.pixelData.count)")
    }
}

private struct LegacySelectionMaskFixture: Codable {
    var canvasWidth: Int
    var canvasHeight: Int
    var alphaBytes: Data
}

private func makePrecisionFixture(side: Int, metal: MetalDeviceContext,
                                  serializer: LayerTextureSerializer) throws -> MTLTexture {
    let store = StageOneLayerSurfaceStore()
    let texture = try #require(store.makeTexture(width: side, height: side, pixelFormat: .rgba16Float, metal: metal))
    var data = Data(count: side * side * 8)
    data.withUnsafeMutableBytes { raw in
        for y in 20..<52 {
            for x in 20..<52 {
                CanvasPixelCodec.write(.init(red: 0.2, green: 0.1, blue: 0.05, alpha: 0.5), into: raw,
                    offset: (y * side + x) * 8, encoding: .premultipliedRGBA16FloatLinear)
            }
        }
    }
    try serializer.restore(snapshot: .init(width: side, height: side, bytesPerRow: side * 8,
        pixelData: data, encoding: .premultipliedRGBA16FloatLinear), into: texture)
    return texture
}

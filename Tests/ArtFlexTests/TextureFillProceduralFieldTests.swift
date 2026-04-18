import Foundation
import Testing
@testable import ArtFlex

struct TextureFillProceduralFieldTests {
    @Test
    func sameRawPathAndSameSeedProduceDeterministicTextureField() {
        let mask = Data(repeating: 255, count: 32 * 32)
        let anchor = CanvasPoint(x: 4, y: 4)
        let previous = CanvasPoint(x: 24, y: 8)
        let current = CanvasPoint(x: 28, y: 24)
        let seed = TextureFillProceduralField.sessionSeed(anchorPoint: anchor)

        let first = TextureFillProceduralField.alphaBytes(
            baseMaskOriginX: 0,
            baseMaskOriginY: 0,
            width: 32,
            height: 32,
            baseMaskAlphaBytes: mask,
            anchorPoint: anchor,
            previousEdgePoint: previous,
            currentEdgePoint: current,
            sessionSeed: seed
        )
        let second = TextureFillProceduralField.alphaBytes(
            baseMaskOriginX: 0,
            baseMaskOriginY: 0,
            width: 32,
            height: 32,
            baseMaskAlphaBytes: mask,
            anchorPoint: anchor,
            previousEdgePoint: previous,
            currentEdgePoint: current,
            sessionSeed: seed
        )

        #expect(first == second)
    }

    @Test
    func importedStampMaskChangesTextureField() {
        let mask = Data(repeating: 255, count: 64 * 64)
        let anchor = CanvasPoint(x: 6, y: 6)
        let previous = CanvasPoint(x: 40, y: 10)
        let current = CanvasPoint(x: 44, y: 42)
        let seed = TextureFillProceduralField.sessionSeed(anchorPoint: anchor)

        var customStamp = [UInt8](repeating: 0, count: 16 * 16)
        for y in 4..<12 {
            for x in 6..<10 {
                customStamp[(y * 16) + x] = 255
            }
        }

        let procedural = TextureFillProceduralField.alphaBytes(
            baseMaskOriginX: 0,
            baseMaskOriginY: 0,
            width: 64,
            height: 64,
            baseMaskAlphaBytes: mask,
            anchorPoint: anchor,
            previousEdgePoint: previous,
            currentEdgePoint: current,
            sessionSeed: seed
        )
        let imported = TextureFillProceduralField.alphaBytes(
            baseMaskOriginX: 0,
            baseMaskOriginY: 0,
            width: 64,
            height: 64,
            baseMaskAlphaBytes: mask,
            anchorPoint: anchor,
            previousEdgePoint: previous,
            currentEdgePoint: current,
            sessionSeed: seed,
            stampMaskData: Data(customStamp)
        )

        #expect(procedural != imported)
    }

    @Test
    func importedMaskTilesContinuouslyAcrossRegion() {
        let mask = Data(repeating: 255, count: 64 * 64)
        let anchor = CanvasPoint(x: 0, y: 0)
        let previous = CanvasPoint(x: 32, y: 0)
        let current = CanvasPoint(x: 32, y: 32)
        let seed = TextureFillProceduralField.sessionSeed(anchorPoint: anchor)

        var customStamp = [UInt8](repeating: 0, count: 8 * 8)
        for y in 0..<8 {
            customStamp[(y * 8) + 0] = 255
            customStamp[(y * 8) + 1] = 255
        }

        let imported = TextureFillProceduralField.alphaBytes(
            baseMaskOriginX: 0,
            baseMaskOriginY: 0,
            width: 64,
            height: 64,
            baseMaskAlphaBytes: mask,
            anchorPoint: anchor,
            previousEdgePoint: previous,
            currentEdgePoint: current,
            sessionSeed: seed,
            stampMaskData: Data(customStamp)
        )
        let bytes = [UInt8](imported)

        let first = bytes[(4 * 64) + 1]
        let repeated = bytes[(4 * 64) + 23]
        let repeatedAgain = bytes[(4 * 64) + 45]

        #expect(first > 0)
        #expect(repeated == first)
        #expect(repeatedAgain == first)
    }

    @Test
    func importedSourceInfoChangesTileScale() {
        let mask = Data(repeating: 255, count: 128 * 128)
        let anchor = CanvasPoint(x: 0, y: 0)
        let previous = CanvasPoint(x: 64, y: 0)
        let current = CanvasPoint(x: 64, y: 64)
        let seed = TextureFillProceduralField.sessionSeed(anchorPoint: anchor)

        var customStamp = [UInt8](repeating: 0, count: 8 * 8)
        for y in 1..<4 {
            for x in 1..<3 {
                customStamp[(y * 8) + x] = 255
            }
        }
        for y in 4..<7 {
            for x in 5..<7 {
                customStamp[(y * 8) + x] = 255
            }
        }

        let small = TextureFillProceduralField.alphaBytes(
            baseMaskOriginX: 0,
            baseMaskOriginY: 0,
            width: 128,
            height: 128,
            baseMaskAlphaBytes: mask,
            anchorPoint: anchor,
            previousEdgePoint: previous,
            currentEdgePoint: current,
            sessionSeed: seed,
            stampMaskData: Data(customStamp),
            importedSourceInfo: .init(sourceLabel: "small", pixelWidth: 64, pixelHeight: 64)
        )
        let large = TextureFillProceduralField.alphaBytes(
            baseMaskOriginX: 0,
            baseMaskOriginY: 0,
            width: 128,
            height: 128,
            baseMaskAlphaBytes: mask,
            anchorPoint: anchor,
            previousEdgePoint: previous,
            currentEdgePoint: current,
            sessionSeed: seed,
            stampMaskData: Data(customStamp),
            importedSourceInfo: .init(sourceLabel: "large", pixelWidth: 512, pixelHeight: 512)
        )

        #expect(small != large)
    }

    @Test
    func importedRegionFieldDoesNotRepeatAtFixedTileIntervals() {
        let mask = Data(repeating: 255, count: 96 * 96)

        var customStamp = [UInt8](repeating: 0, count: 8 * 8)
        for y in 0..<8 {
            for x in 0..<8 {
                if x <= y / 2 {
                    customStamp[(y * 8) + x] = 255
                }
            }
        }

        let field = TextureFillProceduralField.importedRegionAlphaBytes(
            baseMaskOriginX: 0,
            baseMaskOriginY: 0,
            width: 96,
            height: 96,
            baseMaskAlphaBytes: mask,
            fieldBounds: CanvasRect(
                origin: .init(x: 0, y: 0),
                size: .init(x: 96, y: 96)
            ),
            stampMaskData: Data(customStamp),
            importedSourceInfo: .init(sourceLabel: "large", pixelWidth: 512, pixelHeight: 512)
        )
        let bytes = [UInt8](field)

        let left = bytes[(16 * 96) + 8]
        let middle = bytes[(16 * 96) + 32]
        let right = bytes[(16 * 96) + 56]

        #expect(left != middle || middle != right)
    }

    @Test
    func importedRegionFieldCoversFinalBoundsWithoutLetterboxing() {
        let mask = Data(repeating: 255, count: 96 * 96)
        let opaqueStamp = Data(repeating: 255, count: 8 * 8)

        let field = TextureFillProceduralField.importedRegionAlphaBytes(
            baseMaskOriginX: 0,
            baseMaskOriginY: 0,
            width: 96,
            height: 96,
            baseMaskAlphaBytes: mask,
            fieldBounds: CanvasRect(
                origin: .init(x: 0, y: 0),
                size: .init(x: 96, y: 96)
            ),
            stampMaskData: opaqueStamp,
            importedSourceInfo: .init(sourceLabel: "wide", pixelWidth: 512, pixelHeight: 256)
        )
        let bytes = [UInt8](field)

        let topCenter = bytes[(2 * 96) + 48]
        let bottomCenter = bytes[(93 * 96) + 48]

        #expect(topCenter > 0)
        #expect(bottomCenter > 0)
    }
}

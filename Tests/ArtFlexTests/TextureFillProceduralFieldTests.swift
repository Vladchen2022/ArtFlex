import Foundation
import Testing
@testable import ArtFlex

struct TextureFillProceduralFieldTests {
    @Test
    func sessionSeedChangesBetweenFillOperationsAtTheSameAnchor() {
        let anchor = CanvasPoint(x: 42.5, y: 17.25)

        let first = TextureFillProceduralField.sessionSeed(anchorPoint: anchor, sequence: 1)
        let second = TextureFillProceduralField.sessionSeed(anchorPoint: anchor, sequence: 2)

        #expect(first != second)
        #expect(first == TextureFillProceduralField.sessionSeed(anchorPoint: anchor, sequence: 1))
    }

    @Test
    func legacyTextureFillSettingsDecodeWithMaterialDefaults() throws {
        let data = try #require("{\"sourceSemantic\":\"procedural\"}".data(using: .utf8))

        let settings = try JSONDecoder().decode(TextureFillTipSettings.self, from: data)

        #expect(settings.materialScale == 1)
        #expect(settings.coverage == 0.58)
        #expect(settings.variation == 0.45)
        #expect(settings.paintJitterAmount == 0)
        #expect(settings.arrangement == .directional)
    }

    @Test
    func textureFillResponseKeepsDefaultsAndUsesIndependentTailStrengths() {
        #expect(TextureFillMaterialResponse.amplifiedCoverage(0.58) == 0.58)
        #expect(TextureFillMaterialResponse.amplifiedVariation(0.45) == 0.45)
        #expect(TextureFillMaterialResponse.amplifiedCoverage(1) == 2)
        #expect(TextureFillMaterialResponse.amplifiedVariation(1) == 4)
        #expect(TextureFillMaterialResponse.amplifiedCoverage(0.8) > 0.8)
        #expect(TextureFillMaterialResponse.amplifiedVariation(0.8) > 0.8)
    }

    @Test
    func textureFillArrangementRoundTripsThroughProjectState() throws {
        for arrangement in TextureFillArrangement.allCases {
            var settings = TextureFillTipSettings.proceduralDefault
            settings.arrangement = arrangement

            let data = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(TextureFillTipSettings.self, from: data)

            #expect(decoded.arrangement == arrangement)
        }
    }

    @Test
    func textureFillPaintJitterRoundTripsAndClampsToSupportedRange() throws {
        var settings = TextureFillTipSettings.proceduralDefault
        settings.paintJitterAmount = 0.64

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(TextureFillTipSettings.self, from: data)

        #expect(decoded.paintJitterAmount == 0.64)

        let clamped = TextureFillTipSettings(
            sourceSemantic: .procedural,
            tipAssetID: nil,
            importedSourceInfo: nil,
            customTipMaskData: nil,
            paintJitterAmount: 2
        )
        #expect(clamped.paintJitterAmount == 1)
    }

    @Test
    func importedRegionFieldDoesNotRepeatAtFixedTileIntervals() {
        let mask = Data(repeating: 255, count: 96 * 96)
        var customStamp = [UInt8](repeating: 0, count: 8 * 8)
        for y in 0..<8 {
            for x in 0..<8 where x <= y / 2 {
                customStamp[(y * 8) + x] = 255
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

        #expect(bytes[(2 * 96) + 48] > 0)
        #expect(bytes[(93 * 96) + 48] > 0)
    }
}

import Testing
@testable import ArtFlex

struct ColorStandardTests {
    @Test
    func stageOneColorStandardMatchesSpec() {
        let standard = ArtColorStandard.stageOneDefault

        #expect(standard.pixelFormat == .rgba8)
        #expect(standard.alphaMode == .premultiplied)
        #expect(standard.colorSpace == .sRGB)
    }

    @Test
    func premultipliedColorMultipliesRGBByAlpha() {
        let color = RGBAColor(red: 0.8, green: 0.5, blue: 0.25, alpha: 0.5)
        let premultiplied = color.premultiplied

        #expect(premultiplied.red == 0.4)
        #expect(premultiplied.green == 0.25)
        #expect(premultiplied.blue == 0.125)
        #expect(premultiplied.alpha == 0.5)
    }

    @Test
    func semiTransparentRedOverWhiteBecomesLightPink() {
        let red = RGBAColor(red: 1, green: 0, blue: 0, alpha: 0.5)
        let composited = LinearPremultipliedColor(srgbPremultiplied: red.premultiplied)
            .composited(over: .white)
            .srgbUnpremultipliedOverOpaqueBackground

        #expect(abs(composited.red - 0.862) < 0.02)
        #expect(abs(composited.green - 0.735) < 0.02)
        #expect(abs(composited.blue - 0.735) < 0.02)
    }

    @Test
    func semiTransparentRedOverBlackStaysDarkRed() {
        let red = RGBAColor(red: 1, green: 0, blue: 0, alpha: 0.5)
        let composited = LinearPremultipliedColor(srgbPremultiplied: red.premultiplied)
            .composited(over: .black)
            .srgbUnpremultipliedOverOpaqueBackground

        #expect(abs(composited.red - 0.5) < 0.02)
        #expect(composited.green < 0.01)
        #expect(composited.blue < 0.01)
    }

    @Test
    func complementaryPaletteEntriesReduceSaturationByHalf() throws {
        let baseHSV = HSVColor(h: 12, s: 0.9, v: 0.7)
        let state = ColorPanelState(
            mode: .blocks,
            baseHSV: baseHSV,
            basePaletteHSV: [baseHSV, baseHSV],
            baseSource: .synced,
            baseName: "",
            contrast: 50,
            contrastHue: 100,
            snapThreeStops: false,
            blocksLightness: 50,
            blocksSaturation: 100,
            pickerLightness: 50,
            pickerSaturation: 100,
            pickerHue: 0,
            pickerX: 0,
            pickerY: 1,
            lightingHue: 0,
            lightingStrength: 0
        )

        let renderedPalette = ColorBlocksEngine.renderPalette(for: state)
        let minimumRenderedSaturation = try #require(
            renderedPalette
                .map { ColorBlocksEngine.rgbToHsv($0).s }
                .min()
        )

        #expect(minimumRenderedSaturation <= baseHSV.s * 0.62)
        #expect(minimumRenderedSaturation >= baseHSV.s * 0.48)
    }

    @Test
    func pngFlattenLookupMatchesReferenceColorConversionForEveryBytePair() {
        for alphaByte in UInt8.min...UInt8.max {
            let alpha = Float(alphaByte) / 255
            for channelByte in UInt8.min...UInt8.max {
                let sourceLinear = LinearPremultipliedColor.srgbChannelToLinear(
                    Float(channelByte) / 255
                )
                let expectedSRGB = LinearPremultipliedColor.linearChannelToSRGB(
                    sourceLinear + (1 - alpha)
                )
                let expected = UInt8(clamping: Int((expectedSRGB * 255).rounded()))
                #expect(
                    PNGExporter.debugFlattenedOpaqueChannel(
                        srgbPremultipliedByte: channelByte,
                        alphaByte: alphaByte
                    ) == expected
                )
            }
        }
    }
}

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
}

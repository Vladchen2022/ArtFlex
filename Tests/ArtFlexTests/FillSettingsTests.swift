import Foundation
import Testing
@testable import ArtFlex

struct FillSettingsTests {
    @Test
    func defaultsPreserveExactContiguousAutomaticReferenceFill() {
        let settings = FillSettings.stageOneDefault
        #expect(settings.tolerance == 0)
        #expect(settings.isContiguous)
        #expect(settings.sampleSource == .automatic)
    }

    @Test
    func settingsDecodeClampsToleranceAndSuppliesLegacyDefaults() throws {
        let decoded = try JSONDecoder().decode(
            FillSettings.self,
            from: Data(#"{"tolerance":4}"#.utf8)
        )
        #expect(decoded.tolerance == 1)
        #expect(decoded.isContiguous)
        #expect(decoded.sampleSource == .automatic)
    }

    @Test
    func zeroToleranceUsesExactPremultipliedPixelEquality() {
        let lhs = PremultipliedSRGBAPixel(red: 128, green: 0, blue: 0, alpha: 128)
        let rhs = PremultipliedSRGBAPixel(red: 127, green: 0, blue: 0, alpha: 128)

        #expect(FillColorDistance.matches(lhs, lhs, tolerance: 0))
        #expect(FillColorDistance.matches(lhs, rhs, tolerance: 0) == false)
    }

    @Test
    func distanceUnpremultipliesSRGBBeforeComparisonAndIncludesAlpha() {
        let halfRed = PremultipliedSRGBAPixel(red: 128, green: 0, blue: 0, alpha: 128)
        let opaqueRed = PremultipliedSRGBAPixel(red: 255, green: 0, blue: 0, alpha: 255)
        let halfComponents = FillColorDistance.unpremultipliedComponents(of: halfRed)
        let distance = FillColorDistance.normalizedDistance(between: halfRed, and: opaqueRed)

        #expect(abs(halfComponents.red - 1) < 0.000_001)
        #expect(abs(distance - (127.0 / 255.0 / 2.0)) < 0.000_1)
    }

    @Test
    func fullyTransparentPixelsIgnoreUndefinedStoredRGB() {
        let dirtyClear = PremultipliedSRGBAPixel(red: 255, green: 17, blue: 91, alpha: 0)
        let canonicalClear = PremultipliedSRGBAPixel(red: 0, green: 0, blue: 0, alpha: 0)

        #expect(FillColorDistance.normalizedDistance(between: dirtyClear, and: canonicalClear) == 0)
        #expect(FillColorDistance.matches(dirtyClear, canonicalClear, tolerance: 0) == false)
        #expect(FillColorDistance.matches(dirtyClear, canonicalClear, tolerance: 0.001))
    }

    @Test
    func toleranceIncludesNearbyColorAndRejectsDistantHue() {
        let target = PremultipliedSRGBAPixel(red: 200, green: 100, blue: 50, alpha: 255)
        let nearby = PremultipliedSRGBAPixel(red: 204, green: 102, blue: 52, alpha: 255)
        let distant = PremultipliedSRGBAPixel(red: 40, green: 200, blue: 220, alpha: 255)

        #expect(FillColorDistance.matches(target, nearby, tolerance: 0.02))
        #expect(FillColorDistance.matches(target, distant, tolerance: 0.02) == false)
    }
}

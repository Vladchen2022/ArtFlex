import Testing
@testable import ArtFlex

struct ColorAdjustmentDomainTests {
    @Test
    func effectNeutralityUsesOnlyParametersOwnedByTheSelectedMode() {
        var parameters = ColorAdjustmentParameters.neutral
        parameters.vitalizationStrength = 0.6

        #expect(parameters.isNeutral(for: .standard))
        #expect(parameters.isNeutral(for: .vitalization) == false)

        parameters.vitalizationStrength = 0
        parameters.brightness = 0.4

        #expect(parameters.isNeutral(for: .standard) == false)
        #expect(parameters.isNeutral(for: .vitalization))
    }

    @Test
    func vitalityDefaultsAreActiveAndNormalized() {
        let parameters = ColorAdjustmentParameters.vitalizationDefault

        #expect(parameters.vitalizationStrength > 0)
        #expect(parameters.vitalizationBandScale >= 0 && parameters.vitalizationBandScale <= 1)
        #expect(parameters.vitalizationColorTolerance >= 0 && parameters.vitalizationColorTolerance <= 1)
    }
}

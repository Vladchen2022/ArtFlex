import Testing
@testable import ArtFlex

struct GeneratorFeatureSupportTests {
    @Test
    func allImplementedGeneratorKindsAreUserVisibleWithHonestModes() {
        #expect(GeneratorFeatureSupport.userVisibleKinds == GeneratorKind.allCases)

        for kind in GeneratorKind.allCases {
            let support = GeneratorFeatureSupport.support(for: kind)
            #expect(support.isUserVisible)
            #expect(support.supports(.selectedRegion))
            #expect(support.supports(.directStroke))
        }
    }

    @Test
    func seededRandomUsesStableSplitMixSequence() {
        var random = SeededGeneratorRandom(seed: 0)
        #expect(random.next() == 0xE220_A839_7B1D_CDAF)
        #expect(random.next() == 0x6E78_9E6A_A1B9_65F4)
    }

    @Test
    func equalSeedsReproduceAndDifferentStreamsDiverge() {
        var first = SeededGeneratorRandom(seed: 42)
        var second = SeededGeneratorRandom(seed: 42)
        let firstValues = (0..<8).map { _ in first.next() }
        let secondValues = (0..<8).map { _ in second.next() }

        #expect(firstValues == secondValues)
        #expect(
            SeededGeneratorRandom.derivedSeed(baseSeed: 42, streamID: 1)
                != SeededGeneratorRandom.derivedSeed(baseSeed: 42, streamID: 2)
        )
    }

    @Test
    func generatedFloatsStayInsideRequestedRange() {
        var random = SeededGeneratorRandom(seed: 7)
        for _ in 0..<1_000 {
            let unit = random.nextUnitFloat()
            #expect(unit >= 0 && unit < 1)
            let ranged = random.nextFloat(in: -2.5...4.25)
            #expect(ranged >= -2.5 && ranged <= 4.25)
        }
    }
}

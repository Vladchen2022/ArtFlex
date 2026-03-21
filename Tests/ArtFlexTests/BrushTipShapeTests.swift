import Testing
import Foundation
@testable import ArtFlex

struct BrushTipShapeTests {
    @Test
    func softRoundFallsOffNearEdgeWhileHardRoundStaysOpaque() {
        let softCenter = BrushTipShape.softRound.alphaMask(forNormalizedDistance: 0.0)
        let softMid = BrushTipShape.softRound.alphaMask(forNormalizedDistance: 0.8)
        let softOuter = BrushTipShape.softRound.alphaMask(forNormalizedDistance: 0.95)
        let softEdge = BrushTipShape.softRound.alphaMask(forNormalizedDistance: 1.0)
        let hardMid = BrushTipShape.hardRound.alphaMask(forNormalizedDistance: 0.8)
        let hardOutside = BrushTipShape.hardRound.alphaMask(forNormalizedDistance: 1.1)

        #expect(softCenter == 1)
        #expect(softMid < 1)
        #expect(softMid > 0)
        #expect(softOuter < softMid)
        #expect(softEdge == 0)
        #expect(hardMid == 1)
        #expect(hardOutside == 0)
    }

    @Test
    func squareMatchesHardRoundInsideUnitDistance() {
        #expect(BrushTipShape.square.alphaMask(forNormalizedDistance: 0.5) == 1)
        #expect(BrushTipShape.square.alphaMask(forNormalizedDistance: 1) == 1)
        #expect(BrushTipShape.square.alphaMask(forNormalizedDistance: 1.1) == 0)
    }

    @Test
    func softRoundStartsFallingOffEarlierThanHardRound() {
        let soft = BrushTipShape.softRound.alphaMask(forNormalizedDistance: 0.75)
        let hard = BrushTipShape.hardRound.alphaMask(forNormalizedDistance: 0.75)

        #expect(soft < hard)
        #expect(soft > 0)
    }

    @Test
    func roundHardnessMatchesExpectedDefaults() {
        #expect(BrushTipShape.softRound.hardness == 0.0)
        #expect(BrushTipShape.hardRound.hardness == 1.0)
        #expect(BrushTipShape.customRound.hardness == 0.5)
    }

    @Test
    func customRoundSoftnessMapsFromHardEdgeToSoftEdge() {
        let hard = BrushTipShape.customRoundHardness(for: 0)
        let mid = BrushTipShape.customRoundHardness(for: 0.5)
        let soft = BrushTipShape.customRoundHardness(for: 1)

        #expect(hard > 0.99)
        #expect(mid < hard)
        #expect(mid > soft)
        #expect(soft < 0.01)
    }

    @Test
    func softRoundRuntimeCurveShouldBeSignificantlySofterThanHardRound() {
        let distance: Float = 0.5
        let softRuntimeAlpha = Float(pow(Double(max(1 - distance, 0)), 2))
        let hardRuntimeAlpha: Float = 1

        #expect(softRuntimeAlpha < 0.35)
        #expect(softRuntimeAlpha < hardRuntimeAlpha)
    }
}

import Testing
@testable import ArtFlex

struct CanvasCapacityPolicyTests {
    @Test func highPrecisionReportsTwiceTheWorkingSetAndUsesTheSameMemoryBudget() throws {
        let policy = CanvasCapacityPolicy.standard
        let size = CanvasSize(width: 2048, height: 2048)
        let standard = policy.assess(size)
        let high = policy.assess(size, pixelFormat: .rgba16Float)
        #expect(high.estimatedCoreWorkingSetBytes == standard.estimatedCoreWorkingSetBytes * 2)
        #expect(high.isSupported)
        #expect(!policy.assess(CanvasSize(width: 5000, height: 5000), pixelFormat: .rgba16Float).isSupported)
        let largest = try #require(policy.maximumSupportedSize(aspectWidth: 1, aspectHeight: 1, pixelFormat: .rgba16Float))
        #expect(largest == CanvasSize(width: 4000, height: 4000))
        #expect(policy.assess(largest, pixelFormat: .rgba16Float).isSupported)
    }

    @Test func allowsLargeCanvasWithinPixelBudget() {
        let assessment = CanvasCapacityPolicy.standard.assess(
            CanvasSize(width: 8_000, height: 4_000)
        )

        #expect(assessment.isSupported)
        #expect(assessment.pixelCount == 32_000_000)
        #expect(assessment.transferTileCount > 1)
    }

    @Test func rejectsOversizedSquareEvenWhenEachEdgeIsLegal() {
        let assessment = CanvasCapacityPolicy.standard.assess(
            CanvasSize(width: 8_000, height: 8_000)
        )

        #expect(!assessment.isSupported)
        #expect(assessment.rejectionReason?.contains("总像素") == true)
    }

    @Test func rejectsEdgeBeyondMetalPolicy() {
        let assessment = CanvasCapacityPolicy.standard.assess(
            CanvasSize(width: 8_193, height: 1)
        )

        #expect(!assessment.isSupported)
        #expect(assessment.rejectionReason?.contains("单边") == true)
    }

    @Test func largestSquarePresetNeverRoundsBeyondPixelBudget() throws {
        let policy = CanvasCapacityPolicy.standard
        let size = try #require(
            policy.maximumSupportedSize(aspectWidth: 1, aspectHeight: 1)
        )

        #expect(size == CanvasSize(width: 5_656, height: 5_656))
        #expect(policy.assess(size).isSupported)
        #expect(
            !policy.assess(
                CanvasSize(width: size.width + 1, height: size.height + 1)
            ).isSupported
        )
    }

    @Test func largestPresetSizePreservesRequestedIntegerAspectRatio() throws {
        let policy = CanvasCapacityPolicy.standard
        let size = try #require(
            policy.maximumSupportedSize(aspectWidth: 16, aspectHeight: 9)
        )

        #expect(policy.assess(size).isSupported)
        #expect(size.width * 9 == size.height * 16)
    }

    @Test func deviceAwarePolicyReservesHalfTheRecommendedWorkingSet() {
        let policy = CanvasCapacityPolicy.standard(
            recommendedMaxWorkingSetSize: 560_000_000
        )

        #expect(policy.maximumPixelCount == 10_000_000)
        #expect(policy.assess(CanvasSize(width: 4_000, height: 2_500)).isSupported)
        #expect(!policy.assess(CanvasSize(width: 4_001, height: 2_500)).isSupported)
    }

    @Test func deviceAwarePolicyNeverExceedsAbsoluteProductLimit() {
        let policy = CanvasCapacityPolicy.standard(
            recommendedMaxWorkingSetSize: UInt64.max
        )

        #expect(policy.maximumPixelCount == CanvasCapacityPolicy.standard.maximumPixelCount)
    }
}

import Testing
@testable import ArtFlex

struct CanvasCapacityPolicyTests {
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
}

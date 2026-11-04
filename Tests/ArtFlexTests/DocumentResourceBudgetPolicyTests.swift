import Foundation
import Testing
@testable import ArtFlex

struct DocumentResourceBudgetPolicyTests {
    @Test func sparseResidencyDoesNotReduceArchiveOrFreezeBudgets() {
        let policy = DocumentResourceBudgetPolicy.standard(recommendedMaxWorkingSetSize: nil, archiveLimits: .standard)
        let dense = policy.assess(canvasSize: .init(width: 1_000, height: 1_000), paintLayerCount: 10, maskCount: 0, savedSnapshotCount: 0)
        let sparse = policy.assess(canvasSize: .init(width: 1_000, height: 1_000), paintLayerCount: 10, maskCount: 0, savedSnapshotCount: 0,
            allocatedLayerBytes: 4_000_000, measuredGPUResidentBytes: 5_000_000, reservedWorkingBytes: 1_000_000)
        #expect(sparse.footprint.estimatedInteractiveResidentBytes < dense.footprint.estimatedInteractiveResidentBytes)
        #expect(sparse.footprint.estimatedArchiveUncompressedBytes == dense.footprint.estimatedArchiveUncompressedBytes)
        #expect(sparse.footprint.liveLayerBytes == dense.footprint.liveLayerBytes)
        let busy = policy.assess(canvasSize: .init(width: 1_000, height: 1_000), paintLayerCount: 10, maskCount: 0, savedSnapshotCount: 0,
            allocatedLayerBytes: 4_000_000, measuredGPUResidentBytes: policy.maximumInteractiveResidentBytes)
        #expect(!busy.isSupported)
    }

    @Test func reservationsProtectConcurrentJobsAndReleaseOnScopeExit() throws {
        let budget = WorkingResourceBudget(maximumBytes: 100)
        do {
            let first = try budget.reserve(bytes: 60, residentBytes: 30)
            #expect(throws: (any Error).self) { try budget.reserve(bytes: 11, residentBytes: 30) }
            #expect(budget.reservedBytes == 60)
            withExtendedLifetime(first) {}
        }
        #expect(budget.reservedBytes == 0)
        let next = try budget.reserve(bytes: 70, residentBytes: 30)
        #expect(budget.reservedBytes == 70)
        #expect(throws: (any Error).self) { try budget.reserve(bytes: Int.max, residentBytes: 0) }
        withExtendedLifetime(next) {}
    }
    @Test func highPrecisionCountsDoubleColorStorageButNotDoubleMaskStorage() {
        let policy = DocumentResourceBudgetPolicy.standard(recommendedMaxWorkingSetSize: nil, archiveLimits: .standard)
        let half = policy.assess(canvasSize: .init(width: 1_000, height: 1_000),
            paintLayerCount: 2, maskCount: 1, savedSnapshotCount: 1, pixelFormat: .rgba16Float)
        #expect(half.footprint.liveLayerBytes == 17_000_000)
        #expect(half.footprint.savedSnapshotBytes == 8_000_000)
        #expect(half.footprint.estimatedTransientBytes == 32_000_000)
        var constrained = policy
        constrained.maximumInteractiveResidentBytes = 40_000_000
        #expect(constrained.assess(canvasSize: .init(width: 1_000, height: 1_000),
            paintLayerCount: 2, maskCount: 1, savedSnapshotCount: 1).isSupported)
        #expect(!constrained.assess(canvasSize: .init(width: 1_000, height: 1_000),
            paintLayerCount: 2, maskCount: 1, savedSnapshotCount: 1, pixelFormat: .rgba16Float).isSupported)
    }

    @Test
    func accountsForLayersMasksSnapshotsAndSaveDuplication() {
        let limits = ProjectArchiveReadLimits.standard
        let policy = DocumentResourceBudgetPolicy.standard(
            recommendedMaxWorkingSetSize: 16 * 1024 * 1024 * 1024,
            archiveLimits: limits
        )
        let assessment = policy.assess(
            canvasSize: CanvasSize(width: 1_000, height: 1_000),
            paintLayerCount: 10,
            maskCount: 3,
            savedSnapshotCount: 2,
            referenceImageBytes: 1_024,
            referenceImageResidentBytes: 5_000_000,
            historyResidentBytes: 3_000_000,
            additionalWorkingBytes: 2_000_000
        )

        #expect(assessment.footprint.liveLayerBytes == 43_000_000)
        #expect(assessment.footprint.savedSnapshotBytes == 8_000_000)
        #expect(assessment.footprint.referenceImageResidentBytes == 5_000_000)
        #expect(assessment.footprint.historyResidentBytes == 3_000_000)
        #expect(assessment.footprint.additionalWorkingBytes == 2_000_000)
        #expect(assessment.footprint.estimatedInteractiveResidentBytes == 77_000_000)
        #expect(assessment.footprint.estimatedSavePeakBytes > assessment.footprint.estimatedInteractiveResidentBytes)
        #expect(assessment.isSupported)
    }

    @Test
    func rejectsLayerGrowthBeforeWriterReaderCompatibilityIsLost() {
        var limits = ProjectArchiveReadLimits.standard
        limits.maximumTotalUncompressedBytes = 200 * 1024 * 1024
        let policy = DocumentResourceBudgetPolicy(
            maximumInteractiveResidentBytes: Int.max,
            maximumSavePeakBytes: Int.max,
            maximumArchiveUncompressedBytes: limits.maximumTotalUncompressedBytes,
            estimatedTransientBytesPerPixel: 16
        )

        let assessment = policy.assess(
            canvasSize: CanvasSize(width: 2_048, height: 2_048),
            paintLayerCount: 10,
            maskCount: 0,
            savedSnapshotCount: 0
        )

        #expect(!assessment.isSupported)
        #expect(assessment.rejectionReason?.contains("重新打开") == true)
    }
}

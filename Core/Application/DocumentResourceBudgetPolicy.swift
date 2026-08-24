import Foundation

struct DocumentResourceFootprint: Sendable, Equatable {
    var liveLayerBytes: Int
    var savedSnapshotBytes: Int
    /// Encoded bytes that will be written into the project archive.
    var referenceImageBytes: Int
    /// Encoded plus decoded reference-image bytes retained by the UI.
    var referenceImageResidentBytes: Int
    var historyResidentBytes: Int
    var additionalWorkingBytes: Int
    var estimatedTransientBytes: Int
    var estimatedInteractiveResidentBytes: Int
    var estimatedSavePeakBytes: Int
    var estimatedArchiveUncompressedBytes: Int
}

struct DocumentResourceAssessment: Sendable, Equatable {
    var footprint: DocumentResourceFootprint
    var isSupported: Bool
    var rejectionReason: String?
}

/// Defines the safe operating envelope for the current full-surface renderer. This is deliberately
/// separate from the canvas pixel limit: a legal canvas can still become unsafe after enough
/// layers, masks, or full-resolution snapshots are added.
struct DocumentResourceBudgetPolicy: Sendable, Equatable {
    var maximumInteractiveResidentBytes: Int
    var maximumSavePeakBytes: Int
    var maximumArchiveUncompressedBytes: Int
    var estimatedTransientBytesPerPixel: Int

    static func standard(
        recommendedMaxWorkingSetSize: UInt64?,
        archiveLimits: ProjectArchiveReadLimits
    ) -> DocumentResourceBudgetPolicy {
        let gibibyte = UInt64(1024 * 1024 * 1024)
        let recommended = recommendedMaxWorkingSetSize ?? 12 * gibibyte
        let interactive = min(32 * gibibyte, max(1 * gibibyte, recommended / 3))
        let savePeak = min(48 * gibibyte, max(2 * gibibyte, recommended / 2))
        return DocumentResourceBudgetPolicy(
            maximumInteractiveResidentBytes: Int(min(interactive, UInt64(Int.max))),
            maximumSavePeakBytes: Int(min(savePeak, UInt64(Int.max))),
            maximumArchiveUncompressedBytes: archiveLimits.maximumTotalUncompressedBytes,
            estimatedTransientBytesPerPixel: 16
        )
    }

    func assess(
        canvasSize: CanvasSize,
        paintLayerCount: Int,
        maskCount: Int,
        savedSnapshotCount: Int,
        referenceImageBytes: Int = 0,
        referenceImageResidentBytes: Int? = nil,
        historyResidentBytes: Int = 0,
        additionalWorkingBytes: Int = 0
    ) -> DocumentResourceAssessment {
        let pixelCount = Self.saturatingMultiply(canvasSize.width, canvasSize.height)
        let contentBytes = Self.saturatingMultiply(
            Self.saturatingMultiply(pixelCount, max(0, paintLayerCount)),
            4
        )
        let maskBytes = Self.saturatingMultiply(pixelCount, max(0, maskCount))
        let liveLayerBytes = Self.saturatingAdd(contentBytes, maskBytes)
        let savedSnapshotBytes = Self.saturatingMultiply(
            Self.saturatingMultiply(pixelCount, max(0, savedSnapshotCount)),
            4
        )
        let transientBytes = Self.saturatingMultiply(pixelCount, estimatedTransientBytesPerPixel)
        let resolvedReferenceResidentBytes = max(
            0,
            referenceImageResidentBytes ?? referenceImageBytes
        )
        let persistentInteractiveBytes = Self.saturatingAdd(
            Self.saturatingAdd(liveLayerBytes, savedSnapshotBytes),
            Self.saturatingAdd(
                resolvedReferenceResidentBytes,
                max(0, historyResidentBytes)
            )
        )
        let interactiveBytes = Self.saturatingAdd(
            Self.saturatingAdd(persistentInteractiveBytes, transientBytes),
            max(0, additionalWorkingBytes)
        )
        let captureBytes = Self.saturatingAdd(
            Self.saturatingAdd(liveLayerBytes, savedSnapshotBytes),
            max(0, referenceImageBytes)
        )
        let largestAssetBytes = max(
            Self.saturatingMultiply(pixelCount, 4),
            max(0, referenceImageBytes)
        )
        let savePeakBytes = Self.saturatingAdd(
            Self.saturatingAdd(
                Self.saturatingAdd(interactiveBytes, liveLayerBytes),
                captureBytes
            ),
            largestAssetBytes
        )
        let archiveBytes = Self.saturatingAdd(
            Self.saturatingAdd(captureBytes, 64 * 1024 * 1024),
            0
        )

        let rejectionReason: String?
        if canvasSize.width <= 0 || canvasSize.height <= 0 || pixelCount == Int.max {
            rejectionReason = "画布尺寸无效"
        } else if archiveBytes > maximumArchiveUncompressedBytes {
            rejectionReason = "当前图层、蒙版和快照预计会使工程超过可安全重新打开的上限"
        } else if interactiveBytes > maximumInteractiveResidentBytes {
            rejectionReason = "当前文档预计会超过设备的长期交互内存预算"
        } else if savePeakBytes > maximumSavePeakBytes {
            rejectionReason = "当前文档在保存时预计会超过设备的安全内存峰值"
        } else {
            rejectionReason = nil
        }

        return DocumentResourceAssessment(
            footprint: DocumentResourceFootprint(
                liveLayerBytes: liveLayerBytes,
                savedSnapshotBytes: savedSnapshotBytes,
                referenceImageBytes: max(0, referenceImageBytes),
                referenceImageResidentBytes: resolvedReferenceResidentBytes,
                historyResidentBytes: max(0, historyResidentBytes),
                additionalWorkingBytes: max(0, additionalWorkingBytes),
                estimatedTransientBytes: transientBytes,
                estimatedInteractiveResidentBytes: interactiveBytes,
                estimatedSavePeakBytes: savePeakBytes,
                estimatedArchiveUncompressedBytes: archiveBytes
            ),
            isSupported: rejectionReason == nil,
            rejectionReason: rejectionReason
        )
    }

    private static func saturatingMultiply(_ lhs: Int, _ rhs: Int) -> Int {
        guard lhs >= 0, rhs >= 0 else { return Int.max }
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? Int.max : value
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        guard lhs >= 0, rhs >= 0 else { return Int.max }
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : value
    }
}

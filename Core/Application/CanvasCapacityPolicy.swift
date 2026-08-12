import Foundation

struct CanvasCapacityAssessment: Sendable, Equatable {
    var canvasSize: CanvasSize
    var pixelCount: Int
    var transferTileCount: Int
    var estimatedCoreWorkingSetBytes: Int
    var isSupported: Bool
    var rejectionReason: String?
}

/// A conservative guard for the current Metal renderer. Pixel transfer is tiled,
/// while live paint surfaces are still full Metal textures, so both an edge and
/// total-pixel limit are required.
struct CanvasCapacityPolicy: Sendable, Equatable {
    static let standard = CanvasCapacityPolicy(
        maximumEdge: 8_192,
        maximumPixelCount: 32_000_000,
        estimatedCoreBytesPerPixel: 28
    )

    var maximumEdge: Int
    var maximumPixelCount: Int
    var estimatedCoreBytesPerPixel: Int

    /// Returns the largest exact integer multiple of an aspect ratio that the
    /// current renderer can support. Keeping this calculation beside `assess`
    /// prevents UI callers from rounding a nominal limit into an invalid size.
    func maximumSupportedSize(aspectWidth: Int, aspectHeight: Int) -> CanvasSize? {
        guard aspectWidth > 0, aspectHeight > 0 else { return nil }

        let (aspectPixels, aspectOverflow) = aspectWidth.multipliedReportingOverflow(
            by: aspectHeight
        )
        guard !aspectOverflow, aspectPixels > 0 else { return nil }

        let edgeScale = maximumEdge / max(aspectWidth, aspectHeight)
        let pixelScale = Int(
            sqrt(Double(maximumPixelCount) / Double(aspectPixels)).rounded(.down)
        )
        var scale = min(edgeScale, pixelScale)
        guard scale > 0 else { return nil }

        var size = CanvasSize(
            width: aspectWidth * scale,
            height: aspectHeight * scale
        )
        while scale > 0, !assess(size).isSupported {
            scale -= 1
            size = CanvasSize(
                width: aspectWidth * scale,
                height: aspectHeight * scale
            )
        }
        return scale > 0 ? size : nil
    }

    func assess(_ canvasSize: CanvasSize) -> CanvasCapacityAssessment {
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            return .init(
                canvasSize: canvasSize,
                pixelCount: 0,
                transferTileCount: 0,
                estimatedCoreWorkingSetBytes: 0,
                isSupported: false,
                rejectionReason: "画布宽高必须大于 0"
            )
        }
        let (pixelCount, pixelOverflow) = canvasSize.width.multipliedReportingOverflow(
            by: canvasSize.height
        )
        let (workingSet, byteOverflow) = pixelCount.multipliedReportingOverflow(
            by: estimatedCoreBytesPerPixel
        )
        let tileCount = TileGrid(canvasSize: canvasSize)?.tileCount ?? Int.max

        let rejectionReason: String?
        if pixelOverflow || byteOverflow {
            rejectionReason = "画布尺寸发生整数溢出"
        } else if canvasSize.width > maximumEdge || canvasSize.height > maximumEdge {
            rejectionReason = "单边不能超过 \(maximumEdge) 像素"
        } else if pixelCount > maximumPixelCount {
            rejectionReason = "总像素不能超过 \(maximumPixelCount.formatted())"
        } else {
            rejectionReason = nil
        }

        return .init(
            canvasSize: canvasSize,
            pixelCount: pixelOverflow ? Int.max : pixelCount,
            transferTileCount: tileCount,
            estimatedCoreWorkingSetBytes: byteOverflow ? Int.max : workingSet,
            isSupported: rejectionReason == nil,
            rejectionReason: rejectionReason
        )
    }
}

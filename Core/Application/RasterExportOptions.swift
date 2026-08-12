import Foundation

enum RasterExportFormat: String, Codable, Sendable, Equatable, CaseIterable {
    case png
    case jpeg
    case tiff

    var supportsAlpha: Bool {
        self != .jpeg
    }

    var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .tiff: "tiff"
        }
    }
}

enum RasterExportBackground: Codable, Sendable, Equatable {
    case transparent
    case white
    case custom(RGBAColor)
}

enum RasterExportScope: String, Codable, Sendable, Equatable, CaseIterable {
    case fullCanvas
    case visibleContent
}

enum RasterExportResize: Codable, Sendable, Equatable {
    case original
    case scale(Double)
    case width(Int)
    case height(Int)
    case exact(width: Int, height: Int)
}

struct RasterExportOptions: Codable, Sendable, Equatable {
    var format: RasterExportFormat
    var background: RasterExportBackground
    var scope: RasterExportScope
    var resize: RasterExportResize
    var dpi: Double
    var jpegQuality: Double

    init(
        format: RasterExportFormat = .png,
        background: RasterExportBackground = .white,
        scope: RasterExportScope = .fullCanvas,
        resize: RasterExportResize = .original,
        dpi: Double = 300,
        jpegQuality: Double = 0.92
    ) {
        self.format = format
        self.background = background
        self.scope = scope
        self.resize = resize
        self.dpi = dpi
        self.jpegQuality = jpegQuality
    }

    func validate() throws {
        guard dpi.isFinite, (1...12_000).contains(dpi) else {
            throw RasterExportError.invalidDPI(dpi)
        }
        guard jpegQuality.isFinite, (0...1).contains(jpegQuality) else {
            throw RasterExportError.invalidJPEGQuality(jpegQuality)
        }
        if format == .jpeg, background == .transparent {
            throw RasterExportError.transparentBackgroundUnsupported(format: format)
        }
        if case .custom(let color) = background {
            let channels = [color.red, color.green, color.blue, color.alpha]
            guard channels.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                throw RasterExportError.invalidBackgroundColor
            }
            guard color.alpha >= 0.9999 else {
                throw RasterExportError.customBackgroundMustBeOpaque
            }
        }

        switch resize {
        case .original:
            break
        case .scale(let scale):
            guard scale.isFinite, scale > 0, scale <= 16 else {
                throw RasterExportError.invalidScale(scale)
            }
        case .width(let width):
            guard width > 0 else { throw RasterExportError.invalidOutputDimensions }
        case .height(let height):
            guard height > 0 else { throw RasterExportError.invalidOutputDimensions }
        case .exact(let width, let height):
            guard width > 0, height > 0 else {
                throw RasterExportError.invalidOutputDimensions
            }
        }
    }

    func outputDimensions(sourceWidth: Int, sourceHeight: Int) throws -> (width: Int, height: Int) {
        try validate()
        guard sourceWidth > 0, sourceHeight > 0 else {
            throw RasterExportError.invalidSourceDimensions
        }

        switch resize {
        case .original:
            return (sourceWidth, sourceHeight)
        case .scale(let scale):
            return try Self.checkedDimensions(
                width: Double(sourceWidth) * scale,
                height: Double(sourceHeight) * scale
            )
        case .width(let width):
            let height = Double(sourceHeight) * Double(width) / Double(sourceWidth)
            return try Self.checkedDimensions(width: Double(width), height: height)
        case .height(let height):
            let width = Double(sourceWidth) * Double(height) / Double(sourceHeight)
            return try Self.checkedDimensions(width: width, height: Double(height))
        case .exact(let width, let height):
            return (width, height)
        }
    }

    private static func checkedDimensions(
        width: Double,
        height: Double
    ) throws -> (width: Int, height: Int) {
        guard
            width.isFinite,
            height.isFinite,
            width >= 1,
            height >= 1,
            // Double(Int.max) rounds to 2^63 on 64-bit platforms, which is
            // already outside Int and would trap during conversion.
            width < Double(Int.max),
            height < Double(Int.max)
        else {
            throw RasterExportError.invalidOutputDimensions
        }
        return (
            max(1, Int(width.rounded())),
            max(1, Int(height.rounded()))
        )
    }
}

enum RasterExportError: LocalizedError, Sendable, Equatable {
    case invalidSourceDimensions
    case invalidSourcePixelData
    case invalidOutputDimensions
    case invalidScale(Double)
    case invalidDPI(Double)
    case invalidJPEGQuality(Double)
    case transparentBackgroundUnsupported(format: RasterExportFormat)
    case invalidBackgroundColor
    case customBackgroundMustBeOpaque
    case noVisibleContent
    case outputExceedsLimits(width: Int, height: Int)
    case outputExceedsWorkingSetBudget(
        width: Int,
        height: Int,
        estimatedBytes: Int,
        maximumBytes: Int
    )
    case resamplingFailed(Int)
    case imageCreationFailed
    case destinationCreationFailed
    case destinationFinalizeFailed

    var errorDescription: String? {
        switch self {
        case .invalidSourceDimensions:
            return "导出源图像尺寸无效"
        case .invalidSourcePixelData:
            return "导出源像素数据无效"
        case .invalidOutputDimensions:
            return "导出目标尺寸无效"
        case .invalidScale(let scale):
            return "导出缩放比例无效：\(scale)"
        case .invalidDPI(let dpi):
            return "导出 DPI 无效：\(dpi)"
        case .invalidJPEGQuality(let quality):
            return "JPEG 质量无效：\(quality)"
        case .transparentBackgroundUnsupported(let format):
            return "\(format.rawValue.uppercased()) 不支持透明背景"
        case .invalidBackgroundColor:
            return "导出背景颜色无效"
        case .customBackgroundMustBeOpaque:
            return "自定义导出背景必须是不透明颜色"
        case .noVisibleContent:
            return "画布没有可导出的可见内容"
        case .outputExceedsLimits(let width, let height):
            return "导出尺寸超出安全上限：\(width)×\(height)"
        case .outputExceedsWorkingSetBudget(let width, let height, let estimatedBytes, let maximumBytes):
            let mebibyte = 1_024 * 1_024
            let estimatedMiB = max(
                1,
                (estimatedBytes / mebibyte) + (estimatedBytes % mebibyte == 0 ? 0 : 1)
            )
            let maximumMiB = max(1, maximumBytes / (1_024 * 1_024))
            return "导出尺寸 \(width)×\(height) 的预计峰值内存为 \(estimatedMiB) MiB，超过安全预算 \(maximumMiB) MiB"
        case .resamplingFailed(let status):
            return "导出图像缩放失败，状态码 \(status)"
        case .imageCreationFailed:
            return "无法创建导出图像"
        case .destinationCreationFailed:
            return "无法创建导出编码目标"
        case .destinationFinalizeFailed:
            return "无法完成导出文件编码"
        }
    }
}

import Accelerate
import Foundation

enum SelectionMaskFeatheringError: LocalizedError {
    case invalidDimensions
    case invalidRadius
    case convolutionFailed(vImage_Error)

    var errorDescription: String? {
        switch self {
        case .invalidDimensions:
            return "选区蒙版尺寸无效"
        case .invalidRadius:
            return "羽化半径无效"
        case .convolutionFailed:
            return "无法完成选区羽化"
        }
    }
}

enum VImageSelectionMaskFeatherer {
    static func feather(
        alphaBytes: Data,
        width: Int,
        height: Int,
        radiusPixels: Int
    ) throws -> Data {
        guard width > 0, height > 0, alphaBytes.count == width * height else {
            throw SelectionMaskFeatheringError.invalidDimensions
        }
        guard radiusPixels >= 0, radiusPixels <= 512 else {
            throw SelectionMaskFeatheringError.invalidRadius
        }
        guard radiusPixels > 0 else {
            return alphaBytes
        }

        let kernelSize = UInt32((radiusPixels * 2) + 1)
        var sourceBytes = alphaBytes
        var destinationBytes = Data(count: alphaBytes.count)
        var convolutionError = kvImageNoError

        sourceBytes.withUnsafeMutableBytes { sourceRawBuffer in
            destinationBytes.withUnsafeMutableBytes { destinationRawBuffer in
                guard
                    let sourceBaseAddress = sourceRawBuffer.baseAddress,
                    let destinationBaseAddress = destinationRawBuffer.baseAddress
                else {
                    convolutionError = kvImageNullPointerArgument
                    return
                }

                var sourceBuffer = vImage_Buffer(
                    data: sourceBaseAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width
                )
                var destinationBuffer = vImage_Buffer(
                    data: destinationBaseAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width
                )

                convolutionError = vImageTentConvolve_Planar8(
                    &sourceBuffer,
                    &destinationBuffer,
                    nil,
                    0,
                    0,
                    kernelSize,
                    kernelSize,
                    0,
                    vImage_Flags(kvImageBackgroundColorFill)
                )
            }
        }

        guard convolutionError == kvImageNoError else {
            throw SelectionMaskFeatheringError.convolutionFailed(convolutionError)
        }
        return destinationBytes
    }
}

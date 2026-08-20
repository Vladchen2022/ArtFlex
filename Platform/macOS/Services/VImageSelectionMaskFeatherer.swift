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

        // Two smaller tent passes approximate a Gaussian while preserving the
        // requested total support radius. A single tent pass still has visible
        // coverage at its last allocated pixel and then drops directly to zero,
        // which makes painted feathered selections look clipped at the outside.
        let firstPassRadius = radiusPixels / 2
        let secondPassRadius = radiusPixels - firstPassRadius
        var sourceBytes = alphaBytes
        var intermediateBytes = Data(count: alphaBytes.count)
        var destinationBytes = Data(count: alphaBytes.count)

        func tentConvolve(
            source: inout Data,
            destination: inout Data,
            radius: Int
        ) -> vImage_Error {
            guard radius > 0 else {
                destination = source
                return kvImageNoError
            }
            let kernelSize = UInt32((radius * 2) + 1)
            var convolutionError = kvImageNoError
            source.withUnsafeMutableBytes { sourceRawBuffer in
                destination.withUnsafeMutableBytes { destinationRawBuffer in
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
            return convolutionError
        }

        let firstPassError = tentConvolve(
            source: &sourceBytes,
            destination: &intermediateBytes,
            radius: firstPassRadius
        )
        guard firstPassError == kvImageNoError else {
            throw SelectionMaskFeatheringError.convolutionFailed(firstPassError)
        }
        let secondPassError = tentConvolve(
            source: &intermediateBytes,
            destination: &destinationBytes,
            radius: secondPassRadius
        )
        guard secondPassError == kvImageNoError else {
            throw SelectionMaskFeatheringError.convolutionFailed(secondPassError)
        }
        return destinationBytes
    }
}

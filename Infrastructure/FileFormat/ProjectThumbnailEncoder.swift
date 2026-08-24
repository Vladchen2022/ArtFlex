import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ProjectThumbnailEncodingError: LocalizedError {
    case invalidSnapshot
    case scalingFailed(Int)
    case imageCreationFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidSnapshot:
            return "无法从当前画布生成工程缩略图"
        case .scalingFailed(let code):
            return "工程缩略图缩放失败（\(code)）"
        case .imageCreationFailed:
            return "无法创建工程缩略图图像"
        case .encodingFailed:
            return "无法编码工程缩略图"
        }
    }
}

struct ProjectThumbnailEncoder {
    static let maximumDimension = 512

    func encodePNG(
        from snapshot: LayerTextureSnapshot,
        maximumDimension: Int = Self.maximumDimension
    ) throws -> Data {
        guard snapshot.width > 0,
              snapshot.height > 0,
              snapshot.bytesPerRow >= snapshot.width * 4,
              snapshot.pixelData.count >= snapshot.bytesPerRow * snapshot.height,
              maximumDimension > 0 else {
            throw ProjectThumbnailEncodingError.invalidSnapshot
        }

        let targetSize = Self.fittedSize(
            width: snapshot.width,
            height: snapshot.height,
            maximumDimension: maximumDimension
        )
        let targetBytesPerRow = targetSize.width * 4
        var scaledPixels = Data(count: targetBytesPerRow * targetSize.height)
        let scaleResult: vImage_Error = snapshot.pixelData.withUnsafeBytes { sourceBytes in
            scaledPixels.withUnsafeMutableBytes { destinationBytes in
                var source = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: sourceBytes.baseAddress),
                    height: vImagePixelCount(snapshot.height),
                    width: vImagePixelCount(snapshot.width),
                    rowBytes: snapshot.bytesPerRow
                )
                var destination = vImage_Buffer(
                    data: destinationBytes.baseAddress,
                    height: vImagePixelCount(targetSize.height),
                    width: vImagePixelCount(targetSize.width),
                    rowBytes: targetBytesPerRow
                )
                return vImageScale_ARGB8888(
                    &source,
                    &destination,
                    nil,
                    vImage_Flags(kvImageHighQualityResampling)
                )
            }
        }
        guard scaleResult == kvImageNoError else {
            throw ProjectThumbnailEncodingError.scalingFailed(Int(scaleResult))
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: scaledPixels as CFData),
              let image = CGImage(
                  width: targetSize.width,
                  height: targetSize.height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: targetBytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo.byteOrder32Little.union(
                      CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                  ),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else {
            throw ProjectThumbnailEncodingError.imageCreationFailed
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ProjectThumbnailEncodingError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ProjectThumbnailEncodingError.encodingFailed
        }
        return output as Data
    }

    private static func fittedSize(
        width: Int,
        height: Int,
        maximumDimension: Int
    ) -> (width: Int, height: Int) {
        guard max(width, height) > maximumDimension else {
            return (width, height)
        }
        let scale = Double(maximumDimension) / Double(max(width, height))
        return (
            max(1, Int((Double(width) * scale).rounded())),
            max(1, Int((Double(height) * scale).rounded()))
        )
    }
}

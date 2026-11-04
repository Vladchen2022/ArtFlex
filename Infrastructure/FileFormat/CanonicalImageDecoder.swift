import CoreGraphics
import Foundation

enum CanonicalImageDecoder {
    static func snapshot(from cgImage: CGImage, fittingWithin maximumSize: CanvasSize? = nil, preservesWideGamut: Bool = false) -> LayerTextureSnapshot? {
    let scale: Double
    if let maximumSize {
        scale = min(
            1,
            Double(maximumSize.width) / Double(max(cgImage.width, 1)),
            Double(maximumSize.height) / Double(max(cgImage.height, 1))
        )
    } else {
        scale = 1
    }
    let width = max(Int((Double(cgImage.width) * scale).rounded()), 1)
    let height = max(Int((Double(cgImage.height) * scale).rounded()), 1)
    if preservesWideGamut || cgImage.bitsPerComponent > 8 || cgImage.colorSpace?.isWideGamutRGB == true {
        let rowBytes = width * 8
        var pixels = Data(count: rowBytes * height)
        let success = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
                  let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                    bitsPerComponent: 16, bytesPerRow: rowBytes, space: space,
                    bitmapInfo: CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue |
                        CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(cgImage, in: .init(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard success else { return nil }
        return .init(width: width, height: height, bytesPerRow: rowBytes, pixelData: pixels,
            encoding: .premultipliedRGBA16FloatLinear)
    }
    let bytesPerRow = width * 4
    var rgbaBytes = [UInt8](repeating: 0, count: bytesPerRow * height)

    let drewImage = rgbaBytes.withUnsafeMutableBytes { rawBuffer -> Bool in
        guard
            let baseAddress = rawBuffer.baseAddress,
            let context = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).rawValue
            )
        else {
            return false
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }

    guard drewImage else {
        return nil
    }

    for index in stride(from: 0, to: rgbaBytes.count, by: 4) { rgbaBytes.swapAt(index, index + 2) }
    return LayerTextureSnapshot(
        width: width,
        height: height,
        bytesPerRow: bytesPerRow,
        pixelData: Data(rgbaBytes)
    )
    }
}

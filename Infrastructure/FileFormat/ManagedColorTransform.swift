import CoreGraphics
import Foundation

enum ManagedColorTransform {
    static func colorSpace(_ profile: ManagedRGBProfile) throws -> CGColorSpace {
        let space: CGColorSpace?
        switch profile.kind {
        case .sRGB: space = CGColorSpace(name: CGColorSpace.sRGB)
        case .displayP3: space = CGColorSpace(name: CGColorSpace.displayP3)
        case .icc:
            guard let data = profile.iccData, !data.isEmpty, data.count <= 4 * 1024 * 1024 else {
                throw CanvasResourceError(message: "ICC 文件为空或超过 4 MiB")
            }
            space = CGColorSpace(iccData: data as CFData)
        }
        guard let space, space.model == .rgb, space.numberOfComponents == 3 else {
            throw CanvasResourceError(message: "当前支持 RGB ICC 配置文件；此文件不是可用的 RGB 色彩空间")
        }
        return space
    }

    /// Quartz/ColorSync converts the float linear premultiplied buffer into the selected
    /// calibrated RGB profile. Return straight encoded components for ImageIO quantization.
    static func encodedComponents(from pixels: [Float], width: Int, height: Int, profile: ManagedRGBProfile) throws -> [Float] {
        guard width > 0, height > 0, pixels.count == width * height * 4,
              let sourceSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { throw CocoaError(.fileReadCorruptFile) }
        let targetSpace = try colorSpace(profile)
        let sourceData = pixels.withUnsafeBytes { Data($0) }
        let info: CGBitmapInfo = [.floatComponents, .byteOrder32Little, .init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)]
        guard let provider = CGDataProvider(data: sourceData as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128,
                bytesPerRow: width * 16, space: sourceSpace, bitmapInfo: info, provider: provider,
                decode: nil, shouldInterpolate: false, intent: .relativeColorimetric) else { throw CocoaError(.fileReadCorruptFile) }
        var output = [Float](repeating: 0, count: pixels.count)
        let success = output.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 32,
                bytesPerRow: width * 16, space: targetSpace, bitmapInfo: info.rawValue) else { return false }
            context.setRenderingIntent(.relativeColorimetric)
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(image, in: .init(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard success else { throw CanvasResourceError(message: "ColorSync 无法创建目标色彩转换") }
        for i in stride(from: 0, to: output.count, by: 4) {
            let alpha = output[i + 3]
            for c in 0..<3 { output[i + c] = alpha > 0 ? output[i + c] / alpha : 0 }
        }
        return output
    }
}

import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Uses the same linear premultiplied pixels as Metal. Resampling stays in Float32;
/// only the final ImageIO boundary converts to straight sRGB integer channels.
enum HighPrecisionRasterExporter {
    static func encode(snapshot: LayerTextureSnapshot, sourceBounds: RasterExportPixelBounds,
                       width: Int, height: Int, options: RasterExportOptions,
                       maximumWorkingSetBytes: Int) throws -> RasterExportResult {
        let resized = width != sourceBounds.width || height != sourceBounds.height
        let componentBytes = options.resolvedBitDepth.rawValue / 8
        let outputBytes = width * height * 4 * componentBytes
        let floatBytes = resized ? (sourceBounds.width * sourceBounds.height + width * height) * 16 : 0
        let estimate = snapshot.pixelData.count + outputBytes * 2 + floatBytes + 8 * 1024 * 1024
        guard estimate <= maximumWorkingSetBytes else {
            throw RasterExportError.outputExceedsWorkingSetBudget(width: width, height: height,
                estimatedBytes: estimate, maximumBytes: maximumWorkingSetBytes)
        }
        var scaled: [Float]?
        if resized {
            var source = [Float](repeating: 0, count: sourceBounds.width * sourceBounds.height * 4)
            snapshot.pixelData.withUnsafeBytes { bytes in
                for y in 0..<sourceBounds.height {
                    for x in 0..<sourceBounds.width {
                        let c = CanvasPixelCodec.read(bytes,
                            offset: (sourceBounds.originY + y) * snapshot.bytesPerRow + (sourceBounds.originX + x) * snapshot.encoding.bytesPerPixel,
                            encoding: snapshot.encoding)
                        let i = (y * sourceBounds.width + x) * 4
                        source[i] = c.red; source[i + 1] = c.green; source[i + 2] = c.blue; source[i + 3] = c.alpha
                    }
                }
            }
            var destination = [Float](repeating: 0, count: width * height * 4)
            let code = source.withUnsafeMutableBytes { input in
                destination.withUnsafeMutableBytes { output in
                    var src = vImage_Buffer(data: input.baseAddress, height: vImagePixelCount(sourceBounds.height),
                        width: vImagePixelCount(sourceBounds.width), rowBytes: sourceBounds.width * 16)
                    var dst = vImage_Buffer(data: output.baseAddress, height: vImagePixelCount(height),
                        width: vImagePixelCount(width), rowBytes: width * 16)
                    return vImageScale_ARGBFFFF(&src, &dst, nil, vImage_Flags(kvImageHighQualityResampling))
                }
            }
            guard code == kvImageNoError else { throw RasterExportError.resamplingFailed(Int(code)) }
            scaled = destination
        }
        let background: LinearPremultipliedColor?
        switch options.background {
        case .transparent: background = nil
        case .white: background = .white
        case .custom(let color):
            background = .init(red: LinearPremultipliedColor.srgbChannelToLinear(color.red),
                green: LinearPremultipliedColor.srgbChannelToLinear(color.green),
                blue: LinearPremultipliedColor.srgbChannelToLinear(color.blue), alpha: 1)
        }
        var pixels = Data(count: outputBytes)
        snapshot.pixelData.withUnsafeBytes { source in
            pixels.withUnsafeMutableBytes { output in
                for y in 0..<height {
                    for x in 0..<width {
                        let i = (y * width + x) * 4
                        var c: LinearPremultipliedColor
                        if let scaled {
                            c = .init(red: scaled[i], green: scaled[i + 1], blue: scaled[i + 2], alpha: scaled[i + 3])
                        } else {
                            c = CanvasPixelCodec.read(source,
                                offset: (y + sourceBounds.originY) * snapshot.bytesPerRow + (x + sourceBounds.originX) * snapshot.encoding.bytesPerPixel,
                                encoding: snapshot.encoding)
                        }
                        c.alpha = min(max(c.alpha, 0), 1)
                        if let background { c = c.composited(over: background) }
                        let divisor = c.alpha > 0 ? c.alpha : 1
                        let channels = [LinearPremultipliedColor.linearChannelToSRGB(c.red / divisor),
                            LinearPremultipliedColor.linearChannelToSRGB(c.green / divisor),
                            LinearPremultipliedColor.linearChannelToSRGB(c.blue / divisor), c.alpha]
                        for channel in 0..<4 {
                            let value = channels[channel].isFinite ? min(max(channels[channel], 0), 1) : 0
                            if componentBytes == 2 {
                                output.storeBytes(of: UInt16((value * 65535).rounded()).bigEndian,
                                    toByteOffset: (i + channel) * 2, as: UInt16.self)
                            } else { output[i + channel] = UInt8((value * 255).rounded()) }
                        }
                    }
                }
            }
        }
        var info = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        if componentBytes == 2 { info.formUnion(.byteOrder16Big) }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: componentBytes * 8,
                bitsPerPixel: componentBytes * 32, bytesPerRow: width * componentBytes * 4,
                space: space, bitmapInfo: info, provider: provider, decode: nil,
                shouldInterpolate: true, intent: .defaultIntent) else { throw RasterExportError.imageCreationFailed }
        let output = NSMutableData()
        let type: UTType = options.format == .png ? .png : options.format == .tiff ? .tiff : .jpeg
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            throw RasterExportError.destinationCreationFailed
        }
        let properties: [CFString: Any] = [kCGImagePropertyDPIWidth: options.dpi, kCGImagePropertyDPIHeight: options.dpi,
            kCGImageDestinationLossyCompressionQuality: options.jpegQuality]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw RasterExportError.destinationFinalizeFailed }
        return .init(encodedData: output as Data, pixelWidth: width, pixelHeight: height, sourceBounds: sourceBounds)
    }
}

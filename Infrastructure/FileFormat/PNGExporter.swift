import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

final class PNGExporter {
    func export(texture: MTLTexture, to fileURL: URL) throws {
        let outputBytes = try makeFlattenedRGBABytes(texture: texture)
        try writePNG(
            rgbaBytes: outputBytes,
            width: texture.width,
            height: texture.height,
            to: fileURL
        )
    }

    func export(snapshot: LayerTextureSnapshot, to fileURL: URL) throws {
        let outputBytes = makeFlattenedRGBABytes(snapshot: snapshot)
        try writePNG(
            rgbaBytes: outputBytes,
            width: snapshot.width,
            height: snapshot.height,
            to: fileURL
        )
    }

    private func makeFlattenedRGBABytes(texture: MTLTexture) throws -> [UInt8] {
        let width = texture.width
        let height = texture.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let region = MTLRegionMake2D(0, 0, width, height)

        guard let device = texture.device as MTLDevice? else {
            throw CocoaError(.fileWriteUnknown)
        }

        let stagingDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        stagingDescriptor.storageMode = .shared
        stagingDescriptor.usage = [.shaderRead, .shaderWrite]

        guard
            let stagingTexture = device.makeTexture(descriptor: stagingDescriptor),
            let commandQueue = device.makeCommandQueue(),
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let blitEncoder = commandBuffer.makeBlitCommandEncoder()
        else {
            throw CocoaError(.fileWriteUnknown)
        }

        blitEncoder.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: region.origin,
            sourceSize: region.size,
            to: stagingTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: region.origin
        )
        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var sourceBytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        stagingTexture.getBytes(
            &sourceBytes,
            bytesPerRow: bytesPerRow,
            from: region,
            mipmapLevel: 0
        )

        var outputBytes = [UInt8](repeating: 0, count: bytesPerRow * height)

        for y in 0..<height {
            for x in 0..<width {
                let sourceIndex = (y * bytesPerRow) + (x * bytesPerPixel)
                let destinationIndex = (y * bytesPerRow) + (x * bytesPerPixel)

                let blue = Float(sourceBytes[sourceIndex]) / 255
                let green = Float(sourceBytes[sourceIndex + 1]) / 255
                let red = Float(sourceBytes[sourceIndex + 2]) / 255
                let alpha = Float(sourceBytes[sourceIndex + 3]) / 255

                let composited = LinearPremultipliedColor(
                    red: LinearPremultipliedColor.srgbChannelToLinear(red),
                    green: LinearPremultipliedColor.srgbChannelToLinear(green),
                    blue: LinearPremultipliedColor.srgbChannelToLinear(blue),
                    alpha: alpha
                )
                .composited(over: .white)
                .srgbUnpremultipliedOverOpaqueBackground

                outputBytes[destinationIndex] = UInt8(clamping: Int((composited.red * 255).rounded()))
                outputBytes[destinationIndex + 1] = UInt8(clamping: Int((composited.green * 255).rounded()))
                outputBytes[destinationIndex + 2] = UInt8(clamping: Int((composited.blue * 255).rounded()))
                outputBytes[destinationIndex + 3] = 255
            }
        }

        return outputBytes
    }

    private func makeFlattenedRGBABytes(snapshot: LayerTextureSnapshot) -> [UInt8] {
        let width = snapshot.width
        let height = snapshot.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let sourceBytes = [UInt8](snapshot.pixelData)
        var outputBytes = [UInt8](repeating: 0, count: bytesPerRow * height)

        for y in 0..<height {
            for x in 0..<width {
                let sourceIndex = (y * bytesPerRow) + (x * bytesPerPixel)
                let destinationIndex = sourceIndex

                let blue = Float(sourceBytes[sourceIndex]) / 255
                let green = Float(sourceBytes[sourceIndex + 1]) / 255
                let red = Float(sourceBytes[sourceIndex + 2]) / 255
                let alpha = Float(sourceBytes[sourceIndex + 3]) / 255

                let composited = LinearPremultipliedColor(
                    red: LinearPremultipliedColor.srgbChannelToLinear(red),
                    green: LinearPremultipliedColor.srgbChannelToLinear(green),
                    blue: LinearPremultipliedColor.srgbChannelToLinear(blue),
                    alpha: alpha
                )
                .composited(over: .white)
                .srgbUnpremultipliedOverOpaqueBackground

                outputBytes[destinationIndex] = UInt8(clamping: Int((composited.red * 255).rounded()))
                outputBytes[destinationIndex + 1] = UInt8(clamping: Int((composited.green * 255).rounded()))
                outputBytes[destinationIndex + 2] = UInt8(clamping: Int((composited.blue * 255).rounded()))
                outputBytes[destinationIndex + 3] = 255
            }
        }

        return outputBytes
    }

    private func writePNG(
        rgbaBytes: [UInt8],
        width: Int,
        height: Int,
        to fileURL: URL
    ) throws {
        let bytesPerRow = width * 4
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)

        guard
            let provider = CGDataProvider(data: Data(rgbaBytes) as CFData),
            let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            ),
            let destination = CGImageDestinationCreateWithURL(
                fileURL as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            throw CocoaError(.fileWriteUnknown)
        }

        CGImageDestinationAddImage(destination, image, nil)

        if !CGImageDestinationFinalize(destination) {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

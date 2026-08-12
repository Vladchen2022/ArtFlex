import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct RasterExportPixelBounds: Sendable, Equatable {
    var originX: Int
    var originY: Int
    var width: Int
    var height: Int
}

struct RasterExportResult: Sendable, Equatable {
    var encodedData: Data
    var pixelWidth: Int
    var pixelHeight: Int
    var sourceBounds: RasterExportPixelBounds
}

struct RasterExporterLimits: Sendable, Equatable {
    var maximumDimension: Int
    var maximumWorkingSetBytes: Int

    static let standard = RasterExporterLimits(
        maximumDimension: 65_535,
        // The largest supported canvas is 32M pixels. A 768 MiB export budget
        // still admits that canvas at original size while rejecting output
        // sizes whose simultaneous raster and ImageIO buffers are unsafe.
        maximumWorkingSetBytes: 768 * 1_024 * 1_024
    )
}

final class RasterExporter: Sendable {
    private static let bytesPerPixel = 4
    private static let imageIOFixedOverheadBytes = 8 * 1_024 * 1_024
    private let limits: RasterExporterLimits

    init(limits: RasterExporterLimits = .standard) {
        self.limits = limits
    }

    @discardableResult
    func export(
        snapshot: LayerTextureSnapshot,
        options: RasterExportOptions,
        to fileURL: URL
    ) throws -> RasterExportResult {
        let result = try encode(snapshot: snapshot, options: options)
        try result.encodedData.write(to: fileURL, options: .atomic)
        return result
    }

    func encode(
        snapshot: LayerTextureSnapshot,
        options: RasterExportOptions
    ) throws -> RasterExportResult {
        try options.validate()
        try validate(snapshot)

        let sourceBounds = try resolvedSourceBounds(snapshot: snapshot, scope: options.scope)
        let outputDimensions = try options.outputDimensions(
            sourceWidth: sourceBounds.width,
            sourceHeight: sourceBounds.height
        )
        try validateExportWorkingSet(
            snapshot: snapshot,
            sourceBounds: sourceBounds,
            width: outputDimensions.width,
            height: outputDimensions.height,
            background: options.background
        )
        var bgraBytes = crop(snapshot: snapshot, to: sourceBounds)

        if outputDimensions.width != sourceBounds.width || outputDimensions.height != sourceBounds.height {
            bgraBytes = try scalePremultipliedBGRA(
                bgraBytes,
                sourceWidth: sourceBounds.width,
                sourceHeight: sourceBounds.height,
                destinationWidth: outputDimensions.width,
                destinationHeight: outputDimensions.height
            )
        }

        switch options.background {
        case .transparent:
            break
        case .white:
            flattenOntoOpaqueBackground(&bgraBytes, color: .white)
        case .custom(let color):
            flattenOntoOpaqueBackground(&bgraBytes, color: color)
        }

        let encoded = try encodeImage(
            bgraBytes: bgraBytes,
            width: outputDimensions.width,
            height: outputDimensions.height,
            options: options
        )
        return RasterExportResult(
            encodedData: encoded,
            pixelWidth: outputDimensions.width,
            pixelHeight: outputDimensions.height,
            sourceBounds: sourceBounds
        )
    }

    private func validate(_ snapshot: LayerTextureSnapshot) throws {
        let (minimumBytesPerRow, rowOverflow) = snapshot.width.multipliedReportingOverflow(by: 4)
        let (minimumByteCount, countOverflow) = snapshot.bytesPerRow.multipliedReportingOverflow(by: snapshot.height)
        guard
            !rowOverflow,
            !countOverflow,
            snapshot.width > 0,
            snapshot.height > 0,
            snapshot.bytesPerRow >= minimumBytesPerRow,
            snapshot.pixelData.count >= minimumByteCount
        else {
            throw RasterExportError.invalidSourcePixelData
        }
    }

    private func validateExportWorkingSet(
        snapshot: LayerTextureSnapshot,
        sourceBounds: RasterExportPixelBounds,
        width: Int,
        height: Int,
        background: RasterExportBackground
    ) throws {
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard
            !overflow,
            width > 0,
            height > 0,
            width <= limits.maximumDimension,
            height <= limits.maximumDimension
        else {
            throw RasterExportError.outputExceedsLimits(width: width, height: height)
        }

        let sourcePixelCount = saturatedMultiply(sourceBounds.width, sourceBounds.height)
        let sourceRasterBytes = saturatedMultiply(sourcePixelCount, Self.bytesPerPixel)
        let outputRasterBytes = saturatedMultiply(pixelCount, Self.bytesPerPixel)
        let snapshotResidentBytes = snapshot.pixelData.count

        let needsResampling = sourceBounds.width != width || sourceBounds.height != height
        let resamplingPeakBytes: Int
        if needsResampling {
            let sourceFloatPlaneBytes = saturatedMultiply(
                sourcePixelCount,
                MemoryLayout<Float>.stride
            )
            let destinationFloatPlaneBytes = saturatedMultiply(
                pixelCount,
                MemoryLayout<Float>.stride
            )
            let vImageTemporaryBytes = try scaleTemporaryBufferByteCount(
                sourceWidth: sourceBounds.width,
                sourceHeight: sourceBounds.height,
                destinationWidth: width,
                destinationHeight: height
            )
            resamplingPeakBytes = saturatedSum([
                snapshotResidentBytes,
                sourceRasterBytes,
                outputRasterBytes,
                sourceFloatPlaneBytes,
                destinationFloatPlaneBytes,
                vImageTemporaryBytes
            ])
        } else {
            // Cropping can require a second tightly packed raster even when
            // the output dimensions do not change.
            resamplingPeakBytes = saturatedSum([
                snapshotResidentBytes,
                sourceRasterBytes
            ])
        }

        // At the ImageIO boundary the working raster remains alive. A
        // transparent export also owns a straight-alpha copy. Conservatively
        // reserve three more output-sized buffers for provider/encoder scratch,
        // encoded NSMutableData growth, and the returned Data bridge. Opaque
        // export omits only the straight-alpha copy.
        let encodingRasterCopies = background == .transparent ? 5 : 4
        let encodingPeakBytes = saturatedSum([
            snapshotResidentBytes,
            saturatedMultiply(outputRasterBytes, encodingRasterCopies),
            Self.imageIOFixedOverheadBytes
        ])
        let estimatedPeakBytes = max(resamplingPeakBytes, encodingPeakBytes)
        guard estimatedPeakBytes <= limits.maximumWorkingSetBytes else {
            throw RasterExportError.outputExceedsWorkingSetBudget(
                width: width,
                height: height,
                estimatedBytes: estimatedPeakBytes,
                maximumBytes: limits.maximumWorkingSetBytes
            )
        }
    }

    private func saturatedMultiply(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? Int.max : value
    }

    private func saturatedSum(_ values: [Int]) -> Int {
        values.reduce(0) { partialResult, value in
            let (sum, overflow) = partialResult.addingReportingOverflow(value)
            return overflow ? Int.max : sum
        }
    }

    private func resolvedSourceBounds(
        snapshot: LayerTextureSnapshot,
        scope: RasterExportScope
    ) throws -> RasterExportPixelBounds {
        switch scope {
        case .fullCanvas:
            return RasterExportPixelBounds(
                originX: 0,
                originY: 0,
                width: snapshot.width,
                height: snapshot.height
            )
        case .visibleContent:
            return try visibleContentBounds(snapshot: snapshot)
        }
    }

    private func visibleContentBounds(snapshot: LayerTextureSnapshot) throws -> RasterExportPixelBounds {
        var minX = snapshot.width
        var minY = snapshot.height
        var maxX = -1
        var maxY = -1

        snapshot.pixelData.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for y in 0..<snapshot.height {
                let row = source.advanced(by: y * snapshot.bytesPerRow)
                for x in 0..<snapshot.width where row[(x * 4) + 3] > 0 {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }

        guard maxX >= minX, maxY >= minY else {
            throw RasterExportError.noVisibleContent
        }
        return RasterExportPixelBounds(
            originX: minX,
            originY: minY,
            width: (maxX - minX) + 1,
            height: (maxY - minY) + 1
        )
    }

    private func crop(
        snapshot: LayerTextureSnapshot,
        to bounds: RasterExportPixelBounds
    ) -> Data {
        let destinationBytesPerRow = bounds.width * 4
        let destinationByteCount = destinationBytesPerRow * bounds.height
        if bounds.originX == 0,
           bounds.originY == 0,
           bounds.width == snapshot.width,
           bounds.height == snapshot.height,
           snapshot.bytesPerRow == destinationBytesPerRow,
           snapshot.pixelData.count == destinationByteCount {
            return snapshot.pixelData
        }
        var destination = Data(count: destinationByteCount)
        snapshot.pixelData.withUnsafeBytes { sourceBuffer in
            destination.withUnsafeMutableBytes { destinationBuffer in
                guard
                    let source = sourceBuffer.bindMemory(to: UInt8.self).baseAddress,
                    let output = destinationBuffer.bindMemory(to: UInt8.self).baseAddress
                else {
                    return
                }
                for y in 0..<bounds.height {
                    let sourceRow = source.advanced(
                        by: ((bounds.originY + y) * snapshot.bytesPerRow) + (bounds.originX * 4)
                    )
                    let outputRow = output.advanced(by: y * destinationBytesPerRow)
                    outputRow.update(from: sourceRow, count: destinationBytesPerRow)
                }
            }
        }
        return destination
    }

    private func scalePremultipliedBGRA(
        _ sourceData: Data,
        sourceWidth: Int,
        sourceHeight: Int,
        destinationWidth: Int,
        destinationHeight: Int
    ) throws -> Data {
        let sourcePixelCount = sourceWidth * sourceHeight
        let destinationPixelCount = destinationWidth * destinationHeight
        var sourcePlane = [Float](repeating: 0, count: sourcePixelCount)
        var destinationPlane = [Float](repeating: 0, count: destinationPixelCount)
        var destination = Data(count: destinationPixelCount * Self.bytesPerPixel)
        let temporaryByteCount = try scaleTemporaryBufferByteCount(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            destinationWidth: destinationWidth,
            destinationHeight: destinationHeight
        )
        var temporaryBuffer = Data(count: temporaryByteCount)

        // Alpha is sampled first so resampled RGB can be clamped back to the
        // premultiplied invariant after a high-quality filter overshoots.
        for channelOffset in [3, 0, 1, 2] {
            sourceData.withUnsafeBytes { sourceBuffer in
                sourcePlane.withUnsafeMutableBufferPointer { planeBuffer in
                    guard
                        let source = sourceBuffer.bindMemory(to: UInt8.self).baseAddress,
                        let plane = planeBuffer.baseAddress
                    else {
                        return
                    }
                    if channelOffset == 3 {
                        for pixelIndex in 0..<sourcePixelCount {
                            plane[pixelIndex] = Float(source[(pixelIndex * 4) + channelOffset]) / 255
                        }
                    } else {
                        for pixelIndex in 0..<sourcePixelCount {
                            plane[pixelIndex] = Self.srgbToLinearLookup[
                                Int(source[(pixelIndex * 4) + channelOffset])
                            ]
                        }
                    }
                }
            }

            let status = sourcePlane.withUnsafeMutableBufferPointer { sourceBuffer in
                destinationPlane.withUnsafeMutableBufferPointer { destinationBuffer in
                    guard
                        let sourceBase = sourceBuffer.baseAddress,
                        let destinationBase = destinationBuffer.baseAddress
                    else {
                        return vImage_Error(kvImageNullPointerArgument)
                    }
                    var sourceImage = vImage_Buffer(
                        data: sourceBase,
                        height: vImagePixelCount(sourceHeight),
                        width: vImagePixelCount(sourceWidth),
                        rowBytes: sourceWidth * MemoryLayout<Float>.stride
                    )
                    var destinationImage = vImage_Buffer(
                        data: destinationBase,
                        height: vImagePixelCount(destinationHeight),
                        width: vImagePixelCount(destinationWidth),
                        rowBytes: destinationWidth * MemoryLayout<Float>.stride
                    )
                    if temporaryBuffer.isEmpty {
                        return vImageScale_PlanarF(
                            &sourceImage,
                            &destinationImage,
                            nil,
                            vImage_Flags(kvImageHighQualityResampling)
                        )
                    }
                    return temporaryBuffer.withUnsafeMutableBytes { temporaryBytes in
                        vImageScale_PlanarF(
                            &sourceImage,
                            &destinationImage,
                            temporaryBytes.baseAddress,
                            vImage_Flags(kvImageHighQualityResampling)
                        )
                    }
                }
            }
            guard status == kvImageNoError else {
                throw RasterExportError.resamplingFailed(Int(status))
            }

            destination.withUnsafeMutableBytes { destinationBuffer in
                destinationPlane.withUnsafeBufferPointer { planeBuffer in
                    guard
                        let output = destinationBuffer.bindMemory(to: UInt8.self).baseAddress,
                        let plane = planeBuffer.baseAddress
                    else {
                        return
                    }
                    for pixelIndex in 0..<destinationPixelCount {
                        let byteOffset = (pixelIndex * 4) + channelOffset
                        if channelOffset == 3 {
                            let alpha = min(max(plane[pixelIndex], 0), 1)
                            output[byteOffset] = UInt8(clamping: Int((alpha * 255).rounded()))
                        } else {
                            let alpha = Float(output[(pixelIndex * 4) + 3]) / 255
                            let linearPremultiplied = min(max(plane[pixelIndex], 0), alpha)
                            output[byteOffset] = UInt8(clamping: Int((
                                LinearPremultipliedColor.linearChannelToSRGB(linearPremultiplied) * 255
                            ).rounded()))
                        }
                    }
                }
            }
        }
        return destination
    }

    private func scaleTemporaryBufferByteCount(
        sourceWidth: Int,
        sourceHeight: Int,
        destinationWidth: Int,
        destinationHeight: Int
    ) throws -> Int {
        var sourceImage = vImage_Buffer(
            data: nil,
            height: vImagePixelCount(sourceHeight),
            width: vImagePixelCount(sourceWidth),
            rowBytes: sourceWidth * MemoryLayout<Float>.stride
        )
        var destinationImage = vImage_Buffer(
            data: nil,
            height: vImagePixelCount(destinationHeight),
            width: vImagePixelCount(destinationWidth),
            rowBytes: destinationWidth * MemoryLayout<Float>.stride
        )
        let result = vImageScale_PlanarF(
            &sourceImage,
            &destinationImage,
            nil,
            vImage_Flags(kvImageHighQualityResampling | kvImageGetTempBufferSize)
        )
        guard result >= 0 else {
            throw RasterExportError.resamplingFailed(Int(result))
        }
        return Int(result)
    }

    private static let srgbToLinearLookup: [Float] = (0...255).map { byte in
        LinearPremultipliedColor.srgbChannelToLinear(Float(byte) / 255)
    }

    private func flattenOntoOpaqueBackground(
        _ bgraBytes: inout Data,
        color: RGBAColor
    ) {
        let background = LinearPremultipliedColor(
            red: LinearPremultipliedColor.srgbChannelToLinear(color.red),
            green: LinearPremultipliedColor.srgbChannelToLinear(color.green),
            blue: LinearPremultipliedColor.srgbChannelToLinear(color.blue),
            alpha: 1
        )

        bgraBytes.withUnsafeMutableBytes { rawBuffer in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for offset in stride(from: 0, to: rawBuffer.count, by: 4) {
                let source = LinearPremultipliedColor(
                    bgraBlue: bytes[offset],
                    green: bytes[offset + 1],
                    red: bytes[offset + 2],
                    alpha: bytes[offset + 3]
                )
                let flattened = source.composited(over: background).bgra8PremultipliedBytes
                bytes[offset] = flattened.blue
                bytes[offset + 1] = flattened.green
                bytes[offset + 2] = flattened.red
                bytes[offset + 3] = 255
            }
        }
    }

    private func encodeImage(
        bgraBytes: Data,
        width: Int,
        height: Int,
        options: RasterExportOptions
    ) throws -> Data {
        let encodedPixelBytes: Data
        let bitmapInfo: CGBitmapInfo
        if options.background == .transparent {
            encodedPixelBytes = makeStraightRGBABytes(fromMetalBGRA: bgraBytes)
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        } else {
            encodedPixelBytes = bgraBytes
            bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
                CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            )
        }
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let provider = CGDataProvider(data: encodedPixelBytes as CFData)
        else {
            throw RasterExportError.imageCreationFailed
        }
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            throw RasterExportError.imageCreationFailed
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            typeIdentifier(for: options.format) as CFString,
            1,
            nil
        ) else {
            throw RasterExportError.destinationCreationFailed
        }

        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: options.dpi,
            kCGImagePropertyDPIHeight: options.dpi
        ]
        if options.format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = options.jpegQuality
            properties[kCGImagePropertyJFIFDictionary] = [
                kCGImagePropertyJFIFDensityUnit: 1,
                kCGImagePropertyJFIFXDensity: Int(options.dpi.rounded()),
                kCGImagePropertyJFIFYDensity: Int(options.dpi.rounded())
            ]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw RasterExportError.destinationFinalizeFailed
        }
        return output as Data
    }

    /// Metal sRGB render targets contain sRGB-encoded *linear-premultiplied* RGB.
    /// PNG and TIFF alpha are unassociated, so conversion must happen in linear
    /// space before handing bytes to ImageIO. Treating the Metal bytes as a
    /// CoreGraphics premultiplied bitmap changes translucent colors.
    private func makeStraightRGBABytes(fromMetalBGRA source: Data) -> Data {
        var output = Data(count: source.count)
        source.withUnsafeBytes { sourceBuffer in
            output.withUnsafeMutableBytes { outputBuffer in
                guard
                    let input = sourceBuffer.bindMemory(to: UInt8.self).baseAddress,
                    let destination = outputBuffer.bindMemory(to: UInt8.self).baseAddress
                else {
                    return
                }
                for offset in stride(from: 0, to: source.count, by: 4) {
                    let alphaByte = input[offset + 3]
                    let alpha = Float(alphaByte) / 255
                    if alpha <= 0.0001 {
                        destination[offset] = 0
                        destination[offset + 1] = 0
                        destination[offset + 2] = 0
                        destination[offset + 3] = 0
                        continue
                    }

                    func straightChannel(_ encodedPremultipliedByte: UInt8) -> UInt8 {
                        let linearPremultiplied = LinearPremultipliedColor.srgbChannelToLinear(
                            Float(encodedPremultipliedByte) / 255
                        )
                        let linearStraight = min(max(linearPremultiplied / alpha, 0), 1)
                        return UInt8(clamping: Int(
                            (LinearPremultipliedColor.linearChannelToSRGB(linearStraight) * 255).rounded()
                        ))
                    }

                    destination[offset] = straightChannel(input[offset + 2])
                    destination[offset + 1] = straightChannel(input[offset + 1])
                    destination[offset + 2] = straightChannel(input[offset])
                    destination[offset + 3] = alphaByte
                }
            }
        }
        return output
    }

    private func typeIdentifier(for format: RasterExportFormat) -> String {
        switch format {
        case .png:
            return UTType.png.identifier
        case .jpeg:
            return UTType.jpeg.identifier
        case .tiff:
            return UTType.tiff.identifier
        }
    }
}

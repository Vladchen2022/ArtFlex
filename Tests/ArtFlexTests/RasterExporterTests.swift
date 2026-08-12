import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ArtFlex

struct RasterExporterTests {
    @Test
    func transparentPNGConvertsMetalPremultiplicationToStraightAlphaWithoutColorShift() throws {
        let alphaByte: UInt8 = 128
        let alpha = Float(alphaByte) / 255
        let straightSRGBRed: Float = 0.5
        let storedMetalRed = UInt8(clamping: Int((
            LinearPremultipliedColor.linearChannelToSRGB(
                LinearPremultipliedColor.srgbChannelToLinear(straightSRGBRed) * alpha
            ) * 255
        ).rounded()))
        let snapshot = makeSnapshot(
            width: 1,
            height: 1,
            pixels: [[0, 0, storedMetalRed, alphaByte]]
        )

        let result = try RasterExporter().encode(
            snapshot: snapshot,
            options: RasterExportOptions(
                format: .png,
                background: .transparent,
                dpi: 144
            )
        )
        let decoded = try decode(result.encodedData)

        #expect(decoded.typeIdentifier == UTType.png.identifier)
        #expect(decoded.width == 1)
        #expect(decoded.height == 1)
        // The decode helper draws into a CoreGraphics premultiplied buffer, so
        // straight red 0.5 at alpha 0.5 becomes approximately 64 here.
        #expect(abs(Int(decoded.rgbaBytes[0]) - 64) <= 2)
        #expect(decoded.rgbaBytes[1] <= 2)
        #expect(decoded.rgbaBytes[2] <= 2)
        #expect(abs(Int(decoded.rgbaBytes[3]) - Int(alphaByte)) <= 2)
        let recoveredStraightRed = Float(decoded.rgbaBytes[0]) / Float(decoded.rgbaBytes[3])
        #expect(abs(recoveredStraightRed - straightSRGBRed) < 0.02)
    }

    @Test
    func opaqueBackgroundsCompositePremultipliedPixelsInLinearSpace() throws {
        let snapshot = makeSnapshot(
            width: 1,
            height: 1,
            pixels: [[0, 0, 188, 128]]
        )
        let exporter = RasterExporter()

        let white = try decode(exporter.encode(
            snapshot: snapshot,
            options: RasterExportOptions(format: .png, background: .white)
        ).encodedData)
        #expect(white.rgbaBytes[0] >= 253)
        #expect(abs(Int(white.rgbaBytes[1]) - 187) <= 3)
        #expect(abs(Int(white.rgbaBytes[2]) - 187) <= 3)
        #expect(white.rgbaBytes[3] == 255)

        let black = try decode(exporter.encode(
            snapshot: snapshot,
            options: RasterExportOptions(
                format: .png,
                background: .custom(.black)
            )
        ).encodedData)
        #expect(abs(Int(black.rgbaBytes[0]) - 188) <= 2)
        #expect(black.rgbaBytes[1] <= 2)
        #expect(black.rgbaBytes[2] <= 2)
        #expect(black.rgbaBytes[3] == 255)
    }

    @Test
    func visibleContentScopeCropsThenAspectScales() throws {
        var pixels = Array(repeating: [UInt8](repeating: 0, count: 4), count: 12)
        pixels[(1 * 4) + 1] = [20, 40, 60, 255]
        pixels[(2 * 4) + 2] = [80, 100, 120, 255]
        let snapshot = makeSnapshot(width: 4, height: 3, pixels: pixels)

        let result = try RasterExporter().encode(
            snapshot: snapshot,
            options: RasterExportOptions(
                format: .png,
                background: .transparent,
                scope: .visibleContent,
                resize: .width(4)
            )
        )

        #expect(result.sourceBounds == RasterExportPixelBounds(
            originX: 1,
            originY: 1,
            width: 2,
            height: 2
        ))
        #expect(result.pixelWidth == 4)
        #expect(result.pixelHeight == 4)
        let decoded = try decode(result.encodedData)
        #expect(decoded.width == 4)
        #expect(decoded.height == 4)
    }

    @Test
    func resizingSemiTransparentGradientInterpolatesLinearPremultipliedChannels() throws {
        let alphaByte: UInt8 = 128
        let halfLinearByte = UInt8(clamping: Int((
            LinearPremultipliedColor.linearChannelToSRGB(0.5) * 255
        ).rounded()))
        let snapshot = makeSnapshot(
            width: 2,
            height: 1,
            pixels: [
                [0, 0, 0, alphaByte],
                [halfLinearByte, halfLinearByte, halfLinearByte, alphaByte]
            ]
        )

        let result = try RasterExporter().encode(
            snapshot: snapshot,
            options: RasterExportOptions(
                format: .png,
                background: .transparent,
                resize: .exact(width: 3, height: 1)
            )
        )
        let decoded = try decode(result.encodedData)
        let middleOffset = 4

        // Linear-premultiplied interpolation produces linear 0.25 at alpha
        // 0.5. Once made straight and decoded into this premultiplied test
        // buffer, each display-space channel is approximately 188 * 0.5.
        for channelOffset in 0..<3 {
            #expect(abs(Int(decoded.rgbaBytes[middleOffset + channelOffset]) - 94) <= 3)
        }
        #expect(abs(Int(decoded.rgbaBytes[middleOffset + 3]) - Int(alphaByte)) <= 2)
    }

    @Test
    func resizingSemiTransparentEdgePreservesStraightColorAtPartialCoverage() throws {
        let halfAlphaRed = UInt8(clamping: Int((
            LinearPremultipliedColor.linearChannelToSRGB(0.5) * 255
        ).rounded()))
        let snapshot = makeSnapshot(
            width: 2,
            height: 1,
            pixels: [
                [0, 0, 0, 0],
                [0, 0, halfAlphaRed, 128]
            ]
        )

        let decoded = try decode(RasterExporter().encode(
            snapshot: snapshot,
            options: RasterExportOptions(
                format: .png,
                background: .transparent,
                resize: .exact(width: 3, height: 1)
            )
        ).encodedData)
        let middleOffset = 4

        #expect(abs(Int(decoded.rgbaBytes[middleOffset]) - 64) <= 3)
        #expect(decoded.rgbaBytes[middleOffset + 1] <= 2)
        #expect(decoded.rgbaBytes[middleOffset + 2] <= 2)
        #expect(abs(Int(decoded.rgbaBytes[middleOffset + 3]) - 64) <= 3)
    }

    @Test
    func exporterEncodesPNGJPEGAndTIFFWithDPI() throws {
        let snapshot = makeSnapshot(
            width: 2,
            height: 2,
            pixels: Array(repeating: [25, 50, 200, 255], count: 4)
        )
        let exporter = RasterExporter()
        let cases: [(RasterExportFormat, String)] = [
            (.png, UTType.png.identifier),
            (.jpeg, UTType.jpeg.identifier),
            (.tiff, UTType.tiff.identifier)
        ]

        for (format, expectedType) in cases {
            let result = try exporter.encode(
                snapshot: snapshot,
                options: RasterExportOptions(
                    format: format,
                    background: .white,
                    dpi: 240,
                    jpegQuality: 0.8
                )
            )
            let decoded = try decode(result.encodedData)
            #expect(decoded.typeIdentifier == expectedType)
            #expect(abs(decoded.dpiWidth - 240) < 1)
            #expect(abs(decoded.dpiHeight - 240) < 1)
        }
    }

    @Test
    func exporterRejectsTransparentJPEGAndEmptyContentCrop() throws {
        let clear = makeSnapshot(
            width: 2,
            height: 2,
            pixels: Array(repeating: [0, 0, 0, 0], count: 4)
        )

        #expect(throws: RasterExportError.transparentBackgroundUnsupported(format: .jpeg)) {
            try RasterExporter().encode(
                snapshot: clear,
                options: RasterExportOptions(format: .jpeg, background: .transparent)
            )
        }
        #expect(throws: RasterExportError.noVisibleContent) {
            try RasterExporter().encode(
                snapshot: clear,
                options: RasterExportOptions(
                    format: .png,
                    background: .transparent,
                    scope: .visibleContent
                )
            )
        }
    }

    @Test
    func resizeAndSafetyLimitsRejectInvalidOrExcessiveOutput() throws {
        let snapshot = makeSnapshot(
            width: 2,
            height: 1,
            pixels: Array(repeating: [0, 0, 0, 255], count: 2)
        )
        #expect(try RasterExportOptions(resize: .height(8)).outputDimensions(
            sourceWidth: 2,
            sourceHeight: 1
        ) == (16, 8))

        let constrained = RasterExporter(
            limits: RasterExporterLimits(
                maximumDimension: 8,
                maximumWorkingSetBytes: Int.max
            )
        )
        #expect(throws: RasterExportError.outputExceedsLimits(width: 16, height: 8)) {
            try constrained.encode(
                snapshot: snapshot,
                options: RasterExportOptions(resize: .height(8))
            )
        }

        #expect(throws: RasterExportError.invalidOutputDimensions) {
            try RasterExportOptions(resize: .width(Int.max)).outputDimensions(
                sourceWidth: 1,
                sourceHeight: 1
            )
        }
    }

    @Test
    func workingSetBudgetRejectsDangerousOutputBeforeRasterAllocation() throws {
        let snapshot = makeSnapshot(
            width: 1,
            height: 1,
            pixels: [[0, 0, 0, 255]]
        )

        do {
            _ = try RasterExporter().encode(
                snapshot: snapshot,
                options: RasterExportOptions(
                    format: .png,
                    background: .transparent,
                    resize: .exact(width: 20_000, height: 10_000)
                )
            )
            Issue.record("Expected the working-set preflight to reject the export")
        } catch let error as RasterExportError {
            guard case .outputExceedsWorkingSetBudget(
                let width,
                let height,
                let estimatedBytes,
                let maximumBytes
            ) = error else {
                Issue.record("Unexpected raster export error: \(error)")
                return
            }
            #expect(width == 20_000)
            #expect(height == 10_000)
            #expect(estimatedBytes > maximumBytes)
            #expect(maximumBytes == RasterExporterLimits.standard.maximumWorkingSetBytes)
        }
    }

    private func makeSnapshot(
        width: Int,
        height: Int,
        pixels: [[UInt8]]
    ) -> LayerTextureSnapshot {
        precondition(pixels.count == width * height)
        precondition(pixels.allSatisfy { $0.count == 4 })
        return LayerTextureSnapshot(
            width: width,
            height: height,
            bytesPerRow: width * 4,
            pixelData: Data(pixels.flatMap { $0 })
        )
    }

    private func decode(_ data: Data) throws -> DecodedRasterImage {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let typeIdentifier = try #require(CGImageSourceGetType(source) as String?)
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var rgbaBytes = Data(count: image.width * image.height * 4)
        let didDraw = rgbaBytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: image.width,
                    height: image.height,
                    bitsPerComponent: 8,
                    bytesPerRow: image.width * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        #expect(didDraw)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpiWidth = (properties?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 0
        let dpiHeight = (properties?[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue ?? 0
        return DecodedRasterImage(
            typeIdentifier: typeIdentifier,
            width: image.width,
            height: image.height,
            rgbaBytes: rgbaBytes,
            dpiWidth: dpiWidth,
            dpiHeight: dpiHeight
        )
    }
}

private struct DecodedRasterImage {
    var typeIdentifier: String
    var width: Int
    var height: Int
    var rgbaBytes: Data
    var dpiWidth: Double
    var dpiHeight: Double
}

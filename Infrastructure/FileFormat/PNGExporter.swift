import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

private final class PNGExportBufferPointers: @unchecked Sendable {
    let lookup: UnsafePointer<UInt8>
    let source: UnsafePointer<UInt8>
    let destination: UnsafeMutablePointer<UInt8>

    init(
        lookup: UnsafePointer<UInt8>,
        source: UnsafePointer<UInt8>,
        destination: UnsafeMutablePointer<UInt8>
    ) {
        self.lookup = lookup
        self.source = source
        self.destination = destination
    }
}

final class PNGExporter {
    private static let flattenedOpaqueChannelLookup: [UInt8] = {
        var lookup = [UInt8](repeating: 0, count: 256 * 256)
        for alphaByte in 0...255 {
            let alpha = Float(alphaByte) / 255
            let inverseAlpha = 1 - alpha
            for channelByte in 0...255 {
                let sourceLinear = LinearPremultipliedColor.srgbChannelToLinear(
                    Float(channelByte) / 255
                )
                let flattenedSRGB = LinearPremultipliedColor.linearChannelToSRGB(
                    sourceLinear + inverseAlpha
                )
                lookup[(alphaByte << 8) | channelByte] = UInt8(
                    clamping: Int((flattenedSRGB * 255).rounded())
                )
            }
        }
        return lookup
    }()

    private let serializer: LayerTextureSerializer

    init(serializer: LayerTextureSerializer) {
        self.serializer = serializer
    }

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
        let auditEnabled = PerformanceAuditStore.shared.isRecordingEnabled
        let startedAt = auditEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if auditEnabled {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
                PerformanceAuditStore.shared.recordDuration("PNGExporter.makeFlattenedRGBABytes", ms: ms)
            }
        }

        let snapshot = try serializer.snapshot(texture: texture)
        return makeFlattenedRGBABytes(snapshot: snapshot)
    }

    private func makeFlattenedRGBABytes(snapshot: LayerTextureSnapshot) -> [UInt8] {
        let auditEnabled = PerformanceAuditStore.shared.isRecordingEnabled
        let startedAt = auditEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if auditEnabled {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
                PerformanceAuditStore.shared.recordDuration("PNGExporter.transformBGRABytesForPNG", ms: ms)
            }
        }

        let width = snapshot.width
        let height = snapshot.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var outputBytes = [UInt8](repeating: 0, count: bytesPerRow * height)

        Self.flattenedOpaqueChannelLookup.withUnsafeBytes { lookupBuffer in
            snapshot.pixelData.withUnsafeBytes { sourceBuffer in
                outputBytes.withUnsafeMutableBytes { destinationBuffer in
                    guard snapshot.bytesPerRow >= bytesPerRow,
                          sourceBuffer.count >= snapshot.bytesPerRow * height,
                          let lookupBase = lookupBuffer.bindMemory(to: UInt8.self).baseAddress,
                          let sourceBase = sourceBuffer.bindMemory(to: UInt8.self).baseAddress,
                          let destinationBase = destinationBuffer.bindMemory(to: UInt8.self).baseAddress else {
                        return
                    }

                    let pointers = PNGExportBufferPointers(
                        lookup: UnsafePointer(lookupBase),
                        source: UnsafePointer(sourceBase),
                        destination: destinationBase
                    )
                    let processRow: @Sendable (Int) -> Void = { y in
                        var source = pointers.source.advanced(by: y * snapshot.bytesPerRow)
                        var destination = pointers.destination.advanced(by: y * bytesPerRow)
                        for _ in 0..<width {
                            let alphaIndex = Int(source[3]) << 8
                            destination[0] = pointers.lookup[alphaIndex | Int(source[2])]
                            destination[1] = pointers.lookup[alphaIndex | Int(source[1])]
                            destination[2] = pointers.lookup[alphaIndex | Int(source[0])]
                            destination[3] = 255
                            source = source.advanced(by: bytesPerPixel)
                            destination = destination.advanced(by: bytesPerPixel)
                        }
                    }
                    if width * height >= 512 * 512 {
                        DispatchQueue.concurrentPerform(iterations: height, execute: processRow)
                    } else {
                        for y in 0..<height {
                            processRow(y)
                        }
                    }
                }
            }
        }

        return outputBytes
    }

#if DEBUG
    static func debugFlattenedOpaqueChannel(
        srgbPremultipliedByte: UInt8,
        alphaByte: UInt8
    ) -> UInt8 {
        flattenedOpaqueChannelLookup[(Int(alphaByte) << 8) | Int(srgbPremultipliedByte)]
    }
#endif

    private func writePNG(
        rgbaBytes: [UInt8],
        width: Int,
        height: Int,
        to fileURL: URL
    ) throws {
        let auditEnabled = PerformanceAuditStore.shared.isRecordingEnabled
        let startedAt = auditEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if auditEnabled {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
                PerformanceAuditStore.shared.recordDuration("PNGExporter.writePNG", ms: ms)
            }
        }

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

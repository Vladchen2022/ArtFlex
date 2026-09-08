import AppKit
import Foundation

struct PixelClipboardPayload: Sendable, Equatable {
    var snapshot: LayerTextureSnapshot
    var originX: Int
    var originY: Int
    var sourceCanvasSize: CanvasSize
}

@MainActor
final class PixelClipboardController {
    private(set) var localPayload: PixelClipboardPayload?
    private var localPayloadPasteboardChangeCount: Int?

    func store(
        _ payload: PixelClipboardPayload,
        pasteboard: NSPasteboard = .general
    ) {
        localPayload = payload
        localPayloadPasteboardChangeCount = nil

        guard let image = makeImage(from: payload.snapshot) else {
            return
        }

        pasteboard.clearContents()
        if pasteboard.writeObjects([image]) {
            localPayloadPasteboardChangeCount = pasteboard.changeCount
        }
    }

    func preferredPayload(
        from pasteboard: NSPasteboard = .general
    ) -> PixelClipboardPayload? {
        if let localPayload {
            if let localPayloadPasteboardChangeCount {
                if pasteboard.changeCount == localPayloadPasteboardChangeCount {
                    return localPayload
                }
            } else {
                return localPayload
            }
        }

        return externalImagePayload(from: pasteboard)
    }

    func canvasImportPayload(
        from image: NSImage,
        fittingWithin canvasSize: CanvasSize,
        centeredAt center: CanvasPoint
    ) -> PixelClipboardPayload? {
        guard let snapshot = makeSnapshot(from: image, fittingWithin: canvasSize) else {
            return nil
        }

        return PixelClipboardPayload(
            snapshot: snapshot,
            originX: Int(center.x.rounded()) - (snapshot.width / 2),
            originY: Int(center.y.rounded()) - (snapshot.height / 2),
            sourceCanvasSize: canvasSize
        )
    }

    private func externalImagePayload(
        from pasteboard: NSPasteboard
    ) -> PixelClipboardPayload? {
        guard let image = importableImage(from: pasteboard) else {
            return nil
        }
        guard let snapshot = makeSnapshot(from: image) else {
            return nil
        }

        return PixelClipboardPayload(
            snapshot: snapshot,
            originX: 0,
            originY: 0,
            sourceCanvasSize: CanvasSize(width: snapshot.width, height: snapshot.height)
        )
    }
}

private func importableImage(from pasteboard: NSPasteboard) -> NSImage? {
    if let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage {
        return image
    }

    if let item = pasteboard.pasteboardItems?.first {
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = item.data(forType: type), let image = NSImage(data: data) {
                return image
            }
        }
    }

    return nil
}

private func makeImage(from snapshot: LayerTextureSnapshot) -> NSImage? {
    if snapshot.encoding == .premultipliedRGBA16FloatLinear {
        guard let provider = CGDataProvider(data: snapshot.pixelData as CFData),
              let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let image = CGImage(width: snapshot.width, height: snapshot.height,
                bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: snapshot.bytesPerRow,
                space: space, bitmapInfo: [.floatComponents, .byteOrder16Little,
                    CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: image, size: .init(width: snapshot.width, height: snapshot.height))
    }
    let rgbaBytes = bgraBytesToRGBA(Array(snapshot.pixelData))
    guard let provider = CGDataProvider(data: Data(rgbaBytes) as CFData) else {
        return nil
    }
    guard let cgImage = CGImage(
        width: snapshot.width,
        height: snapshot.height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: snapshot.bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: true,
        intent: .defaultIntent
    ) else {
        return nil
    }

    return NSImage(cgImage: cgImage, size: NSSize(width: snapshot.width, height: snapshot.height))
}

private func makeSnapshot(
    from image: NSImage,
    fittingWithin maximumSize: CanvasSize? = nil
) -> LayerTextureSnapshot? {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        return nil
    }

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
    if cgImage.bitsPerComponent > 8 {
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
                space: CGColorSpaceCreateDeviceRGB(),
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

    return LayerTextureSnapshot(
        width: width,
        height: height,
        bytesPerRow: bytesPerRow,
        pixelData: Data(rgbaBytesToBGRA(rgbaBytes))
    )
}

private func bgraBytesToRGBA(_ bytes: [UInt8]) -> [UInt8] {
    guard !bytes.isEmpty else { return bytes }
    var rgba = bytes
    for index in stride(from: 0, to: bytes.count, by: 4) {
        rgba[index] = bytes[index + 2]
        rgba[index + 1] = bytes[index + 1]
        rgba[index + 2] = bytes[index]
        rgba[index + 3] = bytes[index + 3]
    }
    return rgba
}

private func rgbaBytesToBGRA(_ bytes: [UInt8]) -> [UInt8] {
    guard !bytes.isEmpty else { return bytes }
    var bgra = bytes
    for index in stride(from: 0, to: bytes.count, by: 4) {
        bgra[index] = bytes[index + 2]
        bgra[index + 1] = bytes[index + 1]
        bgra[index + 2] = bytes[index]
        bgra[index + 3] = bytes[index + 3]
    }
    return bgra
}

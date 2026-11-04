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
        centeredAt center: CanvasPoint,
        preservesWideGamut: Bool = false
    ) -> PixelClipboardPayload? {
        guard let snapshot = makeSnapshot(from: image, fittingWithin: canvasSize, preservesWideGamut: preservesWideGamut) else {
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
    // Finder supplies both a file URL and a rendered file icon. Resolve the
    // original first (as ImagePaletteExtractor does), including its bit depth.
    // A missing/unreadable file must not silently become the fallback icon.
    if let url = (pasteboard.readObjects(forClasses: [NSURL.self], options: [
        .urlReadingFileURLsOnly: true
    ]) as? [URL])?.first {
        return NSImage(contentsOf: url)
    }
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
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
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
    fittingWithin maximumSize: CanvasSize? = nil,
    preservesWideGamut: Bool = false
) -> LayerTextureSnapshot? {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        return nil
    }

    return CanonicalImageDecoder.snapshot(from: cgImage, fittingWithin: maximumSize, preservesWideGamut: preservesWideGamut)
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

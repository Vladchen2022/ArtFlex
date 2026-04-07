import CoreGraphics
import CryptoKit
import Foundation

enum StageOneBrushPreviewRasterizer {
    private final class CachedImageBox: NSObject {
        let image: CGImage

        init(image: CGImage) {
            self.image = image
        }
    }

    private struct TipDescriptor {
        let shape: BrushTipShape
        let sourceSemantic: TipSourceSemantic
        let maskBytes: [UInt8]?
        let softness: Float
        let roundness: Float
        let angleDegrees: Float
    }

    private enum ContentMode {
        case stamp(TipDescriptor)
    }

    enum TipMaskPreviewRole {
        case library
        case editor
    }

    nonisolated(unsafe) private static let cache: NSCache<NSString, CachedImageBox> = {
        let cache = NSCache<NSString, CachedImageBox>()
        cache.countLimit = 512
        return cache
    }()

    static func resetCache() {
        cache.removeAllObjects()
    }

    static func stampImage(
        for brush: BrushSettings,
        resolution: Int = 128
    ) -> CGImage? {
        guard resolution > 0 else { return nil }
        let cacheKey = makeStampCacheKey(for: brush, resolution: resolution)
        if let cached = cache.object(forKey: cacheKey) {
            return cached.image
        }

        let descriptor = primaryDescriptor(for: brush, resolution: resolution)
        let alphaBytes = renderAlphaBytes(
            resolution: resolution,
            contentMode: .stamp(descriptor)
        )
        guard let image = makeImage(
            from: alphaBytes,
            resolution: resolution,
            cropToContent: descriptor.shape == .customRound && descriptor.sourceSemantic.usesImportedPreviewFit
        ) else {
            return nil
        }

        cache.setObject(CachedImageBox(image: image), forKey: cacheKey)
        return image
    }

    static func importedAssetImage(
        from maskData: Data?,
        resolution: Int = 128
    ) -> CGImage? {
        normalizedMaskPreviewImage(
            from: maskData,
            resolution: resolution,
            role: .library,
            cropToContent: true
        )
    }

    static func editorMaskImage(
        from maskData: Data?,
        resolution: Int = 128,
        cropToContent: Bool = false
    ) -> CGImage? {
        normalizedMaskPreviewImage(
            from: maskData,
            resolution: resolution,
            role: .editor,
            cropToContent: cropToContent
        )
    }

    static func normalizedMaskPreviewImage(
        from maskData: Data?,
        resolution: Int = 128,
        role: TipMaskPreviewRole,
        cropToContent: Bool = true
    ) -> CGImage? {
        guard resolution > 0 else { return nil }
        let cacheKey = makeMaskPreviewCacheKey(
            maskData: maskData,
            resolution: resolution,
            role: role,
            cropToContent: cropToContent
        )
        if let cached = cache.object(forKey: cacheKey) {
            return cached.image
        }

        guard let alphaBytes = resampledMaskBytes(maskData, targetResolution: resolution) else {
            return nil
        }

        let resolvedAlphaBytes: [UInt8]
        let resolvedResolution: Int
        if cropToContent, let cropped = cropAlphaBytes(alphaBytes, resolution: resolution) {
            resolvedAlphaBytes = cropped.bytes
            resolvedResolution = cropped.resolution
        } else {
            resolvedAlphaBytes = alphaBytes
            resolvedResolution = resolution
        }

        let bytesPerPixel = 4
        let bytesPerRow = resolvedResolution * bytesPerPixel
        let baseValue: UInt8 = role == .editor ? 255 : 0
        var rgba = [UInt8](repeating: baseValue, count: resolvedResolution * resolvedResolution * bytesPerPixel)

        for index in 0..<(resolvedResolution * resolvedResolution) {
            let offset = index * bytesPerPixel
            switch role {
            case .library:
                rgba[offset] = 255
                rgba[offset + 1] = 255
                rgba[offset + 2] = 255
                rgba[offset + 3] = resolvedAlphaBytes[index]
            case .editor:
                let grayscale = 255 - resolvedAlphaBytes[index]
                rgba[offset] = grayscale
                rgba[offset + 1] = grayscale
                rgba[offset + 2] = grayscale
                rgba[offset + 3] = 255
            }
        }

        guard
            let provider = CGDataProvider(data: Data(rgba) as CFData),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let image = CGImage(
                width: resolvedResolution,
                height: resolvedResolution,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else {
            return nil
        }

        cache.setObject(CachedImageBox(image: image), forKey: cacheKey)
        return image
    }

    static func stableRandom(x: Double, y: Double, index: Int, salt: UInt64) -> Double {
        var value = UInt64(bitPattern: Int64(index &* 1_103_515_245 &+ 12_345)) ^ salt
        value ^= UInt64(abs(Int64(x * 10_000)).magnitude &* 0x9E37_79B1)
        value ^= UInt64(abs(Int64(y * 10_000)).magnitude &* 0x85EB_CA77)
        value ^= value >> 16
        value &*= 0x45d9f3b
        value ^= value >> 16
        return Double(value & 0xffff) / Double(0xffff)
    }

    static func maskFingerprint(for data: Data?) -> String? {
        guard let data, data.isEmpty == false else { return nil }
        return stableMaskDigest(data)
    }

    private static func renderAlphaBytes(
        resolution: Int,
        contentMode: ContentMode
    ) -> [UInt8] {
        let total = resolution * resolution
        guard total > 0 else { return [] }
        let center = Double(resolution - 1) * 0.5
        let scale = max(center, 1)
        var alpha = [UInt8](repeating: 0, count: total)

        for y in 0..<resolution {
            for x in 0..<resolution {
                let localPoint = CGPoint(
                    x: (Double(x) - center) / scale,
                    y: (center - Double(y)) / scale
                )
                let value: Double
                switch contentMode {
                case .stamp(let descriptor):
                    value = tipAlpha(localPoint: localPoint, descriptor: descriptor)
                }
                alpha[(y * resolution) + x] = UInt8(clamping: Int((min(max(value, 0), 1) * 255).rounded()))
            }
        }

        return alpha
    }

    private static func primaryDescriptor(
        for brush: BrushSettings,
        resolution: Int
    ) -> TipDescriptor {
        tipDescriptor(
            shape: brush.tipShape,
            sourceSemantic: brush.customTipSourceSemantic,
            maskData: brush.customTipMaskData,
            softness: brush.customTipSoftness,
            roundness: brush.customTipRoundness,
            angleDegrees: brush.customTipAngleDegrees,
            resolution: resolution
        )
    }

    private static func tipDescriptor(
        shape: BrushTipShape,
        sourceSemantic: TipSourceSemantic,
        maskData: Data?,
        softness: Float,
        roundness: Float,
        angleDegrees: Float,
        resolution: Int
    ) -> TipDescriptor {
        TipDescriptor(
            shape: shape,
            sourceSemantic: sourceSemantic,
            maskBytes: resampledMaskBytes(maskData, targetResolution: resolution),
            softness: softness,
            roundness: roundness,
            angleDegrees: angleDegrees
        )
    }

    private static func tipAlpha(
        localPoint: CGPoint,
        descriptor: TipDescriptor
    ) -> Double {
        let radians = Double(descriptor.angleDegrees) * (.pi / 180.0)
        let cosine = cos(radians)
        let sine = sin(radians)
        let rotatedPoint = CGPoint(
            x: (localPoint.x * cosine) + (localPoint.y * sine),
            y: (-localPoint.x * sine) + (localPoint.y * cosine)
        )

        switch descriptor.shape {
        case .square:
            let squareDistance = max(abs(rotatedPoint.x), abs(rotatedPoint.y))
            return squareDistance <= 1 ? 1 : 0
        case .softRound:
            let roundDistance = hypot(localPoint.x, localPoint.y)
            guard roundDistance < 1 else { return 0 }
            let feather = min(max(1 - roundDistance, 0), 1)
            return feather * feather
        case .hardRound:
            let roundDistance = hypot(localPoint.x, localPoint.y)
            return smoothHardnessAlpha(distance: roundDistance, hardness: Double(descriptor.shape.hardness))
        case .customRound:
            let roundness = Double(min(max(descriptor.roundness, 0.25), 1))
            let shapedPoint = CGPoint(x: rotatedPoint.x / roundness, y: rotatedPoint.y)
            guard max(abs(shapedPoint.x), abs(shapedPoint.y)) < 1 else { return 0 }

            if let maskBytes = descriptor.maskBytes {
                return sampledCustomMaskAlpha(
                    maskBytes: maskBytes,
                    localPoint: shapedPoint,
                    softness: Double(descriptor.softness)
                )
            }

            let customDistance = hypot(shapedPoint.x, shapedPoint.y)
            let hardness = Double(BrushTipShape.customRoundHardness(for: descriptor.softness))
            return smoothHardnessAlpha(distance: customDistance, hardness: hardness)
        }
    }

    private static func sampledCustomMaskAlpha(
        maskBytes: [UInt8],
        localPoint: CGPoint,
        softness: Double
    ) -> Double {
        let resolution = Int(sqrt(Double(maskBytes.count)))
        guard resolution > 1 else { return 0 }

        let u = min(max((localPoint.x + 1) * 0.5, 0), 1)
        let v = min(max((localPoint.y + 1) * 0.5, 0), 1)
        let sampleX = u * Double(resolution - 1)
        let sampleY = (1 - v) * Double(resolution - 1)

        let x0 = Int(floor(sampleX))
        let y0 = Int(floor(sampleY))
        let x1 = min(x0 + 1, resolution - 1)
        let y1 = min(y0 + 1, resolution - 1)
        let tx = sampleX - Double(x0)
        let ty = sampleY - Double(y0)

        func sample(_ x: Int, _ y: Int) -> Double {
            Double(maskBytes[(y * resolution) + x]) / 255.0
        }

        let top = sample(x0, y0) * (1 - tx) + sample(x1, y0) * tx
        let bottom = sample(x0, y1) * (1 - tx) + sample(x1, y1) * tx
        let sampled = top * (1 - ty) + bottom * ty
        let exponent = (1 - softness) * 3.2 + softness * 0.75
        return pow(min(max(sampled, 0), 1), exponent)
    }

    private static func smoothHardnessAlpha(distance: Double, hardness: Double) -> Double {
        guard distance < 1 else { return 0 }
        if hardness >= 0.999 {
            return 1
        }
        if distance <= hardness {
            return 1
        }

        let normalized = min(max((distance - hardness) / max(1 - hardness, 0.0001), 0), 1)
        let smooth = normalized * normalized * (3 - (2 * normalized))
        return 1 - smooth
    }

    private static func resampledMaskBytes(
        _ data: Data?,
        targetResolution: Int
    ) -> [UInt8]? {
        guard targetResolution > 0, let data else { return nil }
        let sourceBytes = [UInt8](data)
        guard sourceBytes.isEmpty == false else { return nil }
        let sourceResolution = Int(sqrt(Double(sourceBytes.count)))
        guard sourceResolution * sourceResolution == sourceBytes.count else {
            return nil
        }
        guard sourceResolution != targetResolution else {
            return sourceBytes
        }
        return resampledMaskBytes(
            sourceBytes,
            width: sourceResolution,
            height: sourceResolution,
            targetResolution: targetResolution
        )
    }

    private static func makeImage(
        from alphaBytes: [UInt8],
        resolution: Int,
        cropToContent: Bool
    ) -> CGImage? {
        let resolvedAlphaBytes: [UInt8]
        let resolvedResolution: Int
        if cropToContent, let cropped = cropAlphaBytes(alphaBytes, resolution: resolution) {
            resolvedAlphaBytes = cropped.bytes
            resolvedResolution = cropped.resolution
        } else {
            resolvedAlphaBytes = alphaBytes
            resolvedResolution = resolution
        }

        let bytesPerPixel = 4
        let bytesPerRow = resolvedResolution * bytesPerPixel
        var rgba = [UInt8](repeating: 0, count: resolvedResolution * resolvedResolution * bytesPerPixel)

        for index in 0..<(resolvedResolution * resolvedResolution) {
            let offset = index * bytesPerPixel
            rgba[offset] = 255
            rgba[offset + 1] = 255
            rgba[offset + 2] = 255
            rgba[offset + 3] = resolvedAlphaBytes[index]
        }

        guard
            let provider = CGDataProvider(data: Data(rgba) as CFData),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let image = CGImage(
                width: resolvedResolution,
                height: resolvedResolution,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else {
            return nil
        }

        return image
    }

    private static func cropAlphaBytes(
        _ alphaBytes: [UInt8],
        resolution: Int
    ) -> (bytes: [UInt8], resolution: Int)? {
        guard let bounds = alphaBounds(alphaBytes, resolution: resolution) else {
            return nil
        }

        let width = bounds.maxX - bounds.minX + 1
        let height = bounds.maxY - bounds.minY + 1
        let side = max(width, height)
        guard side > 0 else { return nil }

        let offsetX = (side - width) / 2
        let offsetY = (side - height) / 2
        var destination = [UInt8](repeating: 0, count: side * side)

        for y in 0..<height {
            for x in 0..<width {
                let sourceIndex = ((bounds.minY + y) * resolution) + bounds.minX + x
                let destinationIndex = ((offsetY + y) * side) + offsetX + x
                destination[destinationIndex] = alphaBytes[sourceIndex]
            }
        }

        return (destination, side)
    }

    private static func alphaBounds(
        _ alphaBytes: [UInt8],
        resolution: Int
    ) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        var minX = resolution
        var minY = resolution
        var maxX = -1
        var maxY = -1

        for y in 0..<resolution {
            for x in 0..<resolution {
                if alphaBytes[(y * resolution) + x] > 0 {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }

        guard maxX >= minX, maxY >= minY else {
            return nil
        }

        return (minX, minY, maxX, maxY)
    }

    private static func makeStampCacheKey(
        for brush: BrushSettings,
        resolution: Int
    ) -> NSString {
        var hasher = Hasher()
        brushHasher(brush, into: &hasher)
        hasher.combine(resolution)
        hasher.combine("stamp")
        return NSString(string: String(hasher.finalize()))
    }

    private static func makeImportedAssetCacheKey(
        maskData: Data?,
        resolution: Int
    ) -> NSString {
        NSString(string: "imported-asset|\(stableMaskDigest(maskData))|\(resolution)")
    }

    private static func makeMaskPreviewCacheKey(
        maskData: Data?,
        resolution: Int,
        role: TipMaskPreviewRole,
        cropToContent: Bool
    ) -> NSString {
        NSString(
            string: "mask-preview|\(stableMaskDigest(maskData))|\(resolution)|\(role == .editor ? "editor" : "library")|\(cropToContent)"
        )
    }

    private static func brushHasher(
        _ brush: BrushSettings,
        into hasher: inout Hasher
    ) {
        hasher.combine(brush.tipShape.rawValue)
        hasher.combine(brush.customTipSourceSemantic.rawValue)
        hasher.combine(brush.customTipSoftness)
        hasher.combine(brush.customTipRoundness)
        hasher.combine(brush.customTipAngleDegrees)
        hasher.combine(maskFingerprint(for: brush.customTipMaskData))
        hasher.combine(maskFingerprint(for: brush.customTipEnvelopeMaskData))
    }

    private static func stableMaskDigest(_ data: Data?) -> String {
        guard let data, data.isEmpty == false else { return "nil" }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func resampledMaskBytes(
        _ sourceBytes: [UInt8],
        width: Int,
        height: Int,
        targetResolution: Int
    ) -> [UInt8]? {
        guard
            width > 0,
            height > 0,
            targetResolution > 0,
            sourceBytes.count == width * height,
            let colorSpace = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
            let provider = CGDataProvider(data: Data(sourceBytes) as CFData),
            let sourceImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
        else {
            return nil
        }

        let scale = min(
            Double(targetResolution) / Double(width),
            Double(targetResolution) / Double(height)
        )
        let drawWidth = max(1, min(targetResolution, Int(round(Double(width) * scale))))
        let drawHeight = max(1, min(targetResolution, Int(round(Double(height) * scale))))
        let offsetX = (targetResolution - drawWidth) / 2
        let offsetY = (targetResolution - drawHeight) / 2

        var destination = [UInt8](repeating: 0, count: targetResolution * targetResolution)
        guard let context = CGContext(
            data: &destination,
            width: targetResolution,
            height: targetResolution,
            bitsPerComponent: 8,
            bytesPerRow: targetResolution,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: targetResolution, height: targetResolution))
        context.interpolationQuality = .high
        context.draw(
            sourceImage,
            in: CGRect(x: offsetX, y: offsetY, width: drawWidth, height: drawHeight)
        )

        return destination
    }
}

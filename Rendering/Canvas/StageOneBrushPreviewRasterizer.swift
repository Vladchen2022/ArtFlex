import CoreGraphics
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

    nonisolated(unsafe) private static let cache: NSCache<NSString, CachedImageBox> = {
        let cache = NSCache<NSString, CachedImageBox>()
        cache.countLimit = 512
        return cache
    }()

    static func stampImage(
        for brush: BrushSettings,
        resolution: Int = 128
    ) -> CGImage? {
        guard resolution > 0 else { return nil }
        let cacheKey = makeStampCacheKey(for: brush, resolution: resolution)
        if let cached = cache.object(forKey: cacheKey) {
            return cached.image
        }

        let descriptor = tipDescriptor(
            shape: brush.tipShape,
            sourceSemantic: brush.customTipSourceSemantic,
            maskData: brush.customTipMaskData,
            softness: brush.customTipSoftness,
            roundness: brush.customTipRoundness,
            angleDegrees: brush.customTipAngleDegrees,
            resolution: resolution
        )
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
        guard resolution > 0 else { return nil }
        let cacheKey = makeImportedAssetCacheKey(maskData: maskData, resolution: resolution)
        if let cached = cache.object(forKey: cacheKey) {
            return cached.image
        }

        guard let alphaBytes = resampledMaskBytes(maskData, targetResolution: resolution),
              let image = makeImage(
                from: alphaBytes,
                resolution: resolution,
                cropToContent: true
              ) else {
            return nil
        }

        cache.setObject(CachedImageBox(image: image), forKey: cacheKey)
        return image
    }

    static func editorMaskImage(
        from maskData: Data?,
        resolution: Int = 128,
        cropToContent: Bool = false
    ) -> CGImage? {
        guard resolution > 0 else { return nil }
        let cacheKey = makeEditorMaskCacheKey(
            maskData: maskData,
            resolution: resolution,
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
        var rgba = [UInt8](repeating: 255, count: resolvedResolution * resolvedResolution * bytesPerPixel)

        for index in 0..<(resolvedResolution * resolvedResolution) {
            let grayscale = 255 - resolvedAlphaBytes[index]
            let offset = index * bytesPerPixel
            rgba[offset] = grayscale
            rgba[offset + 1] = grayscale
            rgba[offset + 2] = grayscale
            rgba[offset + 3] = 255
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

    static func compositeStampImage(
        for brush: BrushSettings,
        activeTool: ToolKind,
        resolution: Int = 128,
        previewPoint: CGPoint = .zero,
        sampleIndex: Int = 0,
        directionDegrees: Double = 0
    ) -> CGImage? {
        guard resolution > 0 else { return nil }
        guard
            (brush.dualTipCombineMode == .multiply ||
             brush.dualTipCombineMode == .subtract ||
             brush.dualTipCombineMode == .intersect)
        else {
            return nil
        }

        let cacheKey = makeCompositeCacheKey(
            for: brush,
            activeTool: activeTool,
            resolution: resolution,
            previewPoint: previewPoint,
            sampleIndex: sampleIndex,
            directionDegrees: directionDegrees
        )
        if let cached = cache.object(forKey: cacheKey) {
            return cached.image
        }

        let alphaBytes = renderAlphaBytes(
            resolution: resolution,
            contentMode: .composite(
                brush: brush,
                activeTool: activeTool,
                previewPoint: previewPoint,
                sampleIndex: sampleIndex,
                directionDegrees: directionDegrees
            )
        )
        guard let image = makeImage(from: alphaBytes, resolution: resolution, cropToContent: false) else {
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

    static func secondaryScatterOffset(
        for brush: BrushSettings,
        activeTool: ToolKind,
        point: CGPoint = .zero,
        sampleIndex: Int = 0
    ) -> CGPoint {
        let scatterAmount = secondaryResolvedScatterAmount(
            for: brush,
            activeTool: activeTool,
            point: point,
            sampleIndex: sampleIndex
        )
        guard scatterAmount > 0.0001 else {
            return .zero
        }

        let radial = pow(stableRandom(x: point.x, y: point.y, index: sampleIndex, salt: 0xD1B5_4A31), 0.55)
        let spreadAngle = stableRandom(x: point.x, y: point.y, index: sampleIndex, salt: 0xA24B_1C76) * (.pi * 2.0)
        let scatterRadius = scatterAmount * 0.18 * radial

        return CGPoint(
            x: cos(spreadAngle) * scatterRadius,
            y: sin(spreadAngle) * scatterRadius
        )
    }

    static func secondaryResolvedScatterAmount(
        for brush: BrushSettings,
        activeTool: ToolKind,
        point: CGPoint = .zero,
        sampleIndex: Int = 0
    ) -> Double {
        let baseScatter = brush.supportsSecondaryScatterRealDrawing(for: activeTool)
            ? Double(min(max(brush.secondaryScatter, 0), 5))
            : 0
        guard brush.supportsSecondaryScatterJitterRealDrawing(for: activeTool) else {
            return baseScatter
        }

        let jitterAmount = Double(min(max(brush.secondaryScatterJitter, 0), 1))
        guard jitterAmount > 0.0001 else {
            return baseScatter
        }

        let scatterRandom = stableRandom(
            x: point.x,
            y: point.y,
            index: sampleIndex,
            salt: 0x91E1_CF13
        )
        let jitterScale = max(1 + (((scatterRandom * 2) - 1) * jitterAmount), 0)
        return min(max(baseScatter * jitterScale, 0), 5)
    }

    static func secondarySpacingPhaseOffset(
        for brush: BrushSettings,
        activeTool: ToolKind,
        point: CGPoint = .zero,
        sampleIndex: Int = 0,
        directionDegrees: Double = 0
    ) -> CGPoint {
        let phase = secondaryResolvedSpacingPhase(
            for: brush,
            activeTool: activeTool,
            point: point,
            sampleIndex: sampleIndex
        )
        guard abs(phase) > 0.0001 else {
            return .zero
        }

        let normalizedSpacing = Double(min(max(brush.spacingPercent, 5), 150)) / 50.0
        let offsetDistance = phase * normalizedSpacing
        let radians = directionDegrees * (.pi / 180.0)

        return CGPoint(
            x: cos(radians) * offsetDistance,
            y: sin(radians) * offsetDistance
        )
    }

    static func secondaryResolvedSpacingPhase(
        for brush: BrushSettings,
        activeTool: ToolKind,
        point: CGPoint = .zero,
        sampleIndex: Int = 0
    ) -> Double {
        let basePhase = Double(min(max(brush.secondarySpacingPhase, -0.5), 0.5))
        let effectiveBasePhase = brush.supportsSecondarySpacingPhaseRealDrawing(for: activeTool)
            ? basePhase
            : 0
        guard brush.supportsSecondarySpacingPhaseJitterRealDrawing(for: activeTool) else {
            return effectiveBasePhase
        }

        let jitterAmount = Double(min(max(brush.secondarySpacingPhaseJitter, 0), 0.5))
        guard jitterAmount > 0.0001 else {
            return effectiveBasePhase
        }

        let phaseRandom = stableRandom(
            x: point.x,
            y: point.y,
            index: sampleIndex,
            salt: 0x4A1D_93E7
        )
        let jitterPhase = ((phaseRandom * 2) - 1) * jitterAmount
        return min(max(effectiveBasePhase + jitterPhase, -0.5), 0.5)
    }

    static func secondaryResolvedSizeRatio(
        for brush: BrushSettings,
        activeTool: ToolKind,
        point: CGPoint = .zero,
        sampleIndex: Int = 0
    ) -> Double {
        let baseRatio = Double(min(max(brush.secondarySizeRatio, 0.25), 0.95))
        guard brush.supportsSecondarySizeJitterRealDrawing(for: activeTool) else {
            return baseRatio
        }

        let jitterAmount = Double(min(max(brush.secondarySizeJitter, 0), 1))
        guard jitterAmount > 0.0001 else {
            return baseRatio
        }

        let sizeRandom = stableRandom(
            x: point.x,
            y: point.y,
            index: sampleIndex,
            salt: 0x71F4_1D29
        )
        let jitterScale = max(1 + (((sizeRandom * 2) - 1) * jitterAmount), 0.05)
        return min(max(baseRatio * jitterScale, 0.25), 0.95)
    }

    static func secondaryResolvedAngleDegrees(
        for brush: BrushSettings,
        activeTool: ToolKind,
        point: CGPoint = .zero,
        sampleIndex: Int = 0
    ) -> Double {
        let baseAngle = Double(brush.secondaryTipDescriptor.customTipAngleDegrees) +
            (brush.supportsSecondaryAngleOffsetRealDrawing(for: activeTool)
                ? Double(brush.secondaryAngleOffsetDegrees)
                : 0)
        guard brush.supportsSecondaryAngleJitterRealDrawing(for: activeTool) else {
            return baseAngle
        }

        let jitterAmount = Double(min(max(abs(brush.secondaryAngleJitterDegrees), 0), 180))
        guard jitterAmount > 0.0001 else {
            return baseAngle
        }

        let angleRandom = stableRandom(
            x: point.x,
            y: point.y,
            index: sampleIndex,
            salt: 0x5E2F_7A4C
        )
        let jitterDegrees = ((angleRandom * 2) - 1) * jitterAmount
        return baseAngle + jitterDegrees
    }

    private enum ContentMode {
        case stamp(TipDescriptor)
        case composite(
            brush: BrushSettings,
            activeTool: ToolKind,
            previewPoint: CGPoint,
            sampleIndex: Int,
            directionDegrees: Double
        )
    }

    private static func renderAlphaBytes(
        resolution: Int,
        contentMode: ContentMode
    ) -> [UInt8] {
        var alphaBytes = [UInt8](repeating: 0, count: resolution * resolution)

        for y in 0..<resolution {
            for x in 0..<resolution {
                let normalizedX = ((Double(x) + 0.5) / Double(resolution)) * 2.0 - 1.0
                let normalizedY = ((Double(y) + 0.5) / Double(resolution)) * 2.0 - 1.0

                let alpha: Double
                switch contentMode {
                case .stamp(let descriptor):
                    alpha = tipAlpha(
                        localPoint: CGPoint(x: normalizedX, y: normalizedY),
                        descriptor: descriptor
                    )
                case .composite(let brush, let activeTool, let previewPoint, let sampleIndex, let directionDegrees):
                    alpha = compositeAlpha(
                        localPoint: CGPoint(x: normalizedX, y: normalizedY),
                        brush: brush,
                        activeTool: activeTool,
                        previewPoint: previewPoint,
                        sampleIndex: sampleIndex,
                        directionDegrees: directionDegrees,
                        resolution: resolution
                    )
                }

                alphaBytes[(y * resolution) + x] = UInt8(clamping: Int((min(max(alpha, 0), 1) * 255.0).rounded()))
            }
        }

        return alphaBytes
    }

    private static func compositeAlpha(
        localPoint: CGPoint,
        brush: BrushSettings,
        activeTool: ToolKind,
        previewPoint: CGPoint,
        sampleIndex: Int,
        directionDegrees: Double,
        resolution: Int
    ) -> Double {
        let primaryDescriptor = tipDescriptor(
            shape: brush.tipShape,
            sourceSemantic: brush.customTipSourceSemantic,
            maskData: brush.customTipMaskData,
            softness: brush.customTipSoftness,
            roundness: brush.customTipRoundness,
            angleDegrees: brush.customTipAngleDegrees,
            resolution: resolution
        )
        let secondaryDescriptor = tipDescriptor(
            shape: brush.secondaryTipDescriptor.tipShape,
            sourceSemantic: brush.secondaryTipDescriptor.sourceSemantic,
            maskData: brush.secondaryTipDescriptor.customTipMaskData,
            softness: brush.secondaryTipDescriptor.customTipSoftness,
            roundness: brush.secondaryTipDescriptor.customTipRoundness,
            angleDegrees: Float(
                secondaryResolvedAngleDegrees(
                    for: brush,
                    activeTool: activeTool,
                    point: previewPoint,
                    sampleIndex: sampleIndex
                )
            ),
            resolution: resolution
        )

        let primaryAlpha = tipAlpha(localPoint: localPoint, descriptor: primaryDescriptor)
        guard primaryAlpha > 0 else {
            return 0
        }

        let sizeRatio = secondaryResolvedSizeRatio(
            for: brush,
            activeTool: activeTool,
            point: previewPoint,
            sampleIndex: sampleIndex
        )
        let secondaryOffset = secondaryScatterOffset(
            for: brush,
            activeTool: activeTool,
            point: previewPoint,
            sampleIndex: sampleIndex
        )
        let spacingPhaseOffset = secondarySpacingPhaseOffset(
            for: brush,
            activeTool: activeTool,
            point: previewPoint,
            sampleIndex: sampleIndex,
            directionDegrees: directionDegrees
        )
        let secondaryPoint = CGPoint(
            x: (localPoint.x - secondaryOffset.x - spacingPhaseOffset.x) / sizeRatio,
            y: (localPoint.y - secondaryOffset.y - spacingPhaseOffset.y) / sizeRatio
        )
        var secondaryAlpha = tipAlpha(localPoint: secondaryPoint, descriptor: secondaryDescriptor)
        if brush.supportsSecondaryInvertRealDrawing(for: activeTool) {
            secondaryAlpha = 1.0 - min(max(secondaryAlpha, 0), 1)
        }

        let strength = Double(min(max(brush.dualTipStrength, 0), 1))
        switch brush.dualTipCombineMode {
        case .multiply:
            let modulation = ((1.0 - strength) + (secondaryAlpha * strength))
            return primaryAlpha * modulation
        case .subtract:
            let subtraction = min(max(secondaryAlpha * strength, 0), 1)
            return primaryAlpha * (1.0 - subtraction)
        case .intersect:
            let pureIntersection = min(primaryAlpha, secondaryAlpha)
            return primaryAlpha + ((pureIntersection - primaryAlpha) * strength)
        }
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
        let radians = Double(descriptor.angleDegrees) * .pi / 180.0
        let cosine = cos(radians)
        let sine = sin(radians)
        let rotatedPoint = CGPoint(
            x: (localPoint.x * cosine) + (localPoint.y * sine),
            y: (-localPoint.x * sine) + (localPoint.y * cosine)
        )

        switch descriptor.shape {
        case .square:
            let squareDistance = max(abs(rotatedPoint.x), abs(rotatedPoint.y))
            return squareDistance <= 1.0 ? 1.0 : 0.0
        case .softRound:
            let roundDistance = hypot(localPoint.x, localPoint.y)
            guard roundDistance < 1.0 else { return 0.0 }
            let feather = max(0.0, 1.0 - roundDistance)
            return feather * feather
        case .customRound:
            let roundness = max(Double(descriptor.roundness), 0.25)
            let shapedPoint = CGPoint(
                x: rotatedPoint.x / roundness,
                y: rotatedPoint.y
            )
            if let maskBytes = descriptor.maskBytes {
                return sampledCustomMaskAlpha(
                    at: shapedPoint,
                    maskBytes: maskBytes,
                    softness: descriptor.softness
                )
            }

            let hardness = Double(BrushTipShape.customRoundHardness(for: descriptor.softness))
            let distance = hypot(shapedPoint.x, shapedPoint.y)
            return smoothHardnessAlpha(distance: distance, hardness: hardness)
        case .hardRound:
            let roundDistance = hypot(localPoint.x, localPoint.y)
            return smoothHardnessAlpha(distance: roundDistance, hardness: 1.0)
        }
    }

    private static func sampledCustomMaskAlpha(
        at point: CGPoint,
        maskBytes: [UInt8],
        softness: Float
    ) -> Double {
        guard max(abs(point.x), abs(point.y)) < 1.0 else {
            return 0.0
        }

        let resolution = Int(Double(maskBytes.count).squareRoot())
        guard resolution > 1 else {
            return 0.0
        }

        let u = min(max((point.x + 1.0) * 0.5, 0.0), 1.0)
        let v = min(max((point.y + 1.0) * 0.5, 0.0), 1.0)
        let x = u * Double(resolution - 1)
        let y = v * Double(resolution - 1)
        let x0 = Int(floor(x))
        let y0 = Int(floor(y))
        let x1 = min(x0 + 1, resolution - 1)
        let y1 = min(y0 + 1, resolution - 1)
        let tx = x - Double(x0)
        let ty = y - Double(y0)

        func sample(_ sampleX: Int, _ sampleY: Int) -> Double {
            let index = (sampleY * resolution) + sampleX
            return Double(maskBytes[index]) / 255.0
        }

        let top = (sample(x0, y0) * (1.0 - tx)) + (sample(x1, y0) * tx)
        let bottom = (sample(x0, y1) * (1.0 - tx)) + (sample(x1, y1) * tx)
        let sampledAlpha = (top * (1.0 - ty)) + (bottom * ty)
        let clampedSoftness = min(max(Double(softness), 0.0), 1.0)
        let exponent = (3.2 * (1.0 - clampedSoftness)) + (0.75 * clampedSoftness)
        return pow(min(max(sampledAlpha, 0.0), 1.0), exponent)
    }

    private static func smoothHardnessAlpha(distance: Double, hardness: Double) -> Double {
        guard distance < 1.0 else { return 0.0 }
        if hardness >= 0.999 {
            return 1.0
        }
        if distance <= hardness {
            return 1.0
        }

        let denominator = max(1.0 - hardness, 0.0001)
        let t = min(max((distance - hardness) / denominator, 0.0), 1.0)
        return 1.0 - (t * t * (3.0 - (2.0 * t)))
    }

    private static func resampledMaskBytes(
        _ data: Data?,
        targetResolution: Int
    ) -> [UInt8]? {
        guard let data else { return nil }
        let side = Int(Double(data.count).squareRoot())
        guard side > 0, side * side == data.count else { return nil }

        if side == targetResolution {
            return [UInt8](data)
        }

        let source = [UInt8](data)
        var destination = [UInt8](repeating: 0, count: targetResolution * targetResolution)

        for y in 0..<targetResolution {
            let sourceY = min(Int((Double(y) / Double(targetResolution)) * Double(side)), side - 1)
            for x in 0..<targetResolution {
                let sourceX = min(Int((Double(x) / Double(targetResolution)) * Double(side)), side - 1)
                destination[(y * targetResolution) + x] = source[(sourceY * side) + sourceX]
            }
        }

        return destination
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
        var rgba = [UInt8](repeating: 255, count: resolvedResolution * resolvedResolution * bytesPerPixel)

        for index in 0..<(resolvedResolution * resolvedResolution) {
            let alpha = resolvedAlphaBytes[index]
            let offset = index * bytesPerPixel
            rgba[offset + 3] = alpha
        }

        guard
            let provider = CGDataProvider(data: Data(rgba) as CFData),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else {
            return nil
        }

        return CGImage(
            width: resolvedResolution,
            height: resolvedResolution,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private static func cropAlphaBytes(
        _ alphaBytes: [UInt8],
        resolution: Int
    ) -> (bytes: [UInt8], resolution: Int)? {
        guard let bounds = alphaBounds(alphaBytes, resolution: resolution) else {
            return nil
        }

        let croppedResolution = max(bounds.width, bounds.height)
        var cropped = [UInt8](repeating: 0, count: croppedResolution * croppedResolution)

        let horizontalInset = (croppedResolution - bounds.width) / 2
        let verticalInset = (croppedResolution - bounds.height) / 2

        for y in 0..<bounds.height {
            for x in 0..<bounds.width {
                let sourceIndex = ((bounds.minY + y) * resolution) + bounds.minX + x
                let destinationIndex = ((verticalInset + y) * croppedResolution) + horizontalInset + x
                cropped[destinationIndex] = alphaBytes[sourceIndex]
            }
        }

        return (cropped, croppedResolution)
    }

    private static func alphaBounds(
        _ alphaBytes: [UInt8],
        resolution: Int
    ) -> (minX: Int, minY: Int, width: Int, height: Int)? {
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

        let inset = 2
        let originX = max(0, minX - inset)
        let originY = max(0, minY - inset)
        let width = min(resolution - originX, (maxX - minX + 1) + (inset * 2))
        let height = min(resolution - originY, (maxY - minY + 1) + (inset * 2))
        return (originX, originY, width, height)
    }

    private static func makeStampCacheKey(
        for brush: BrushSettings,
        resolution: Int
    ) -> NSString {
        let hasher = brushHasher(
            prefix: "stamp",
            brush: brush,
            activeTool: nil,
            resolution: resolution,
            previewPoint: .zero,
            sampleIndex: 0
        )
        return NSString(string: String(hasher))
    }

    private static func makeCompositeCacheKey(
        for brush: BrushSettings,
        activeTool: ToolKind,
        resolution: Int,
        previewPoint: CGPoint,
        sampleIndex: Int,
        directionDegrees: Double
    ) -> NSString {
        let hash = brushHasher(
            prefix: "composite",
            brush: brush,
            activeTool: activeTool,
            resolution: resolution,
            previewPoint: previewPoint,
            sampleIndex: sampleIndex,
            directionDegrees: directionDegrees
        )
        return NSString(string: String(hash))
    }

    private static func makeImportedAssetCacheKey(
        maskData: Data?,
        resolution: Int
    ) -> NSString {
        var hasher = Hasher()
        hasher.combine("imported-asset")
        hasher.combine(maskFingerprint(for: maskData))
        hasher.combine(resolution)
        return NSString(string: String(hasher.finalize()))
    }

    private static func makeEditorMaskCacheKey(
        maskData: Data?,
        resolution: Int,
        cropToContent: Bool
    ) -> NSString {
        var hasher = Hasher()
        hasher.combine("editor-mask")
        hasher.combine(maskFingerprint(for: maskData))
        hasher.combine(resolution)
        hasher.combine(cropToContent)
        return NSString(string: String(hasher.finalize()))
    }

    private static func brushHasher(
        prefix: String,
        brush: BrushSettings,
        activeTool: ToolKind?,
        resolution: Int,
        previewPoint: CGPoint,
        sampleIndex: Int,
        directionDegrees: Double = 0
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(prefix)
        hasher.combine(resolution)
        hasher.combine(activeTool?.rawValue)
        hasher.combine(sampleIndex)
        hasher.combine(Int((previewPoint.x * 1_000).rounded()))
        hasher.combine(Int((previewPoint.y * 1_000).rounded()))
        hasher.combine(Int((directionDegrees * 100).rounded()))

        hasher.combine(brush.tipShape.rawValue)
        hasher.combine(brush.customTipSourceSemantic.rawValue)
        hasher.combine(maskFingerprint(for: brush.customTipMaskData))
        hasher.combine(brush.customTipSoftness)
        hasher.combine(brush.customTipRoundness)
        hasher.combine(brush.customTipAngleDegrees)

        hasher.combine(brush.dualTipEnabled)
        hasher.combine(brush.dualTipCombineMode.rawValue)
        hasher.combine(brush.dualTipStrength)
        hasher.combine(brush.secondarySizeRatio)
        hasher.combine(brush.secondarySizeJitter)
        hasher.combine(brush.secondaryAngleJitterDegrees)
        hasher.combine(brush.secondaryAngleOffsetDegrees)
        hasher.combine(brush.secondarySpacingPhase)
        hasher.combine(brush.secondarySpacingPhaseJitter)
        hasher.combine(brush.spacingPercent)
        hasher.combine(brush.secondaryScatter)
        hasher.combine(brush.secondaryScatterJitter)
        hasher.combine(brush.secondaryInvert)

        let secondary = brush.secondaryTipDescriptor
        hasher.combine(secondary.tipShape.rawValue)
        hasher.combine(secondary.sourceSemantic.rawValue)
        hasher.combine(maskFingerprint(for: secondary.customTipMaskData))
        hasher.combine(secondary.customTipSoftness)
        hasher.combine(secondary.customTipRoundness)
        hasher.combine(secondary.customTipAngleDegrees)
        return hasher.finalize()
    }

    static func maskFingerprint(for data: Data?) -> String? {
        guard let data else { return nil }
        return BrushTipImageAssetID(maskData: data).rawValue
    }
}

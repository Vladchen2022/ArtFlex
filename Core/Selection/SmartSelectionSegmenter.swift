import Foundation

enum SmartSelectionDisplayMode: Sendable, Equatable {
    case tint
    case marchingAnts
}

struct SmartSelectionSettings: Codable, Sendable, Equatable {
    var tolerance: Float

    static let stageOneDefault = SmartSelectionSettings(tolerance: 0.18)

    init(tolerance: Float) {
        self.tolerance = Self.clampedTolerance(tolerance)
    }

    private enum CodingKeys: String, CodingKey {
        case tolerance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(tolerance: try container.decodeIfPresent(Float.self, forKey: .tolerance) ?? 0.18)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.clampedTolerance(tolerance), forKey: .tolerance)
    }

    private static func clampedTolerance(_ value: Float) -> Float {
        guard value.isFinite else { return stageOneDefault.tolerance }
        return min(max(value, 0), 1)
    }
}

struct SmartSelectionRaster: Sendable, Equatable {
    var originX: Int
    var originY: Int
    var width: Int
    var height: Int
    var bytesPerRow: Int
    var premultipliedBGRABytes: Data
}

struct SmartSelectionSegmentationResult: Sendable, Equatable {
    var originX: Int
    var originY: Int
    var width: Int
    var height: Int
    var alphaBytes: [UInt8]
    var selectedPixelCount: Int
    var selectedBounds: CanvasRect
}

/// Color-guided segmentation within a rough lasso.
///
/// The interaction follows the same foreground/background hint model as GrabCut:
/// the lasso boundary is treated as probable background and the strongest
/// contrasting connected region inside the lasso becomes the foreground seed.
/// It deliberately stays independent from AppKit/Metal so a Vision or graph-cut
/// backend can replace it without changing tool routing or selection semantics.
enum SmartSelectionSegmenter {
    private struct Feature {
        var lightness: Float
        var a: Float
        var b: Float
        var alpha: Float

        static let zero = Feature(lightness: 0, a: 0, b: 0, alpha: 0)

        static func + (lhs: Feature, rhs: Feature) -> Feature {
            Feature(
                lightness: lhs.lightness + rhs.lightness,
                a: lhs.a + rhs.a,
                b: lhs.b + rhs.b,
                alpha: lhs.alpha + rhs.alpha
            )
        }

        static func / (lhs: Feature, rhs: Float) -> Feature {
            guard rhs != 0 else { return .zero }
            return Feature(
                lightness: lhs.lightness / rhs,
                a: lhs.a / rhs,
                b: lhs.b / rhs,
                alpha: lhs.alpha / rhs
            )
        }
    }

    static func segment(
        raster: SmartSelectionRaster,
        lassoPoints: [CanvasPoint],
        settings: SmartSelectionSettings,
        candidateAlphaBytes: [UInt8]? = nil
    ) -> SmartSelectionSegmentationResult? {
        guard
            raster.width > 0,
            raster.height > 0,
            raster.bytesPerRow >= raster.width * 4,
            raster.premultipliedBGRABytes.count >= raster.bytesPerRow * raster.height,
            candidateAlphaBytes == nil || candidateAlphaBytes?.count == raster.width * raster.height,
            lassoPoints.count >= 3
        else {
            return nil
        }

        var lassoAlpha = rasterizedClosedPolygonMaskBytes(
            points: lassoPoints,
            originX: raster.originX,
            originY: raster.originY,
            width: raster.width,
            height: raster.height,
            // CGContext still antialiases at 1×. A second 2× buffer quadrupled
            // temporary memory and dominated large-ROI recognition latency.
            supersampleScale: 1
        )
        if let candidateAlphaBytes {
            for index in lassoAlpha.indices {
                lassoAlpha[index] = UInt8(clamping:
                    (Int(lassoAlpha[index]) * Int(candidateAlphaBytes[index]) + 127) / 255
                )
            }
        }
        guard lassoAlpha.contains(where: { $0 > 8 }) else { return nil }

        return raster.premultipliedBGRABytes.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            guard let seedIndex = foregroundSeedIndex(
                bytes: bytes,
                bytesPerRow: raster.bytesPerRow,
                lassoAlpha: lassoAlpha,
                width: raster.width,
                height: raster.height
            ) else {
                return nil
            }

            let seedX = seedIndex % raster.width
            let seedY = seedIndex / raster.width
            let reference = medianReferenceFeature(
                aroundX: seedX,
                y: seedY,
                bytes: bytes,
                bytesPerRow: raster.bytesPerRow,
                lassoAlpha: lassoAlpha,
                width: raster.width,
                height: raster.height
            )
            let maximumDistance = perceptualDistanceThreshold(for: settings.tolerance)
            let maximumDistanceSquared = maximumDistance * maximumDistance

            // 0 = unknown, 1 = rejected, 2 = accepted. Cache the predicate so
            // accepted pixels inspected from adjacent scanlines do not repeat
            // the relatively expensive OKLab conversion.
            var eligibility = [UInt8](repeating: 0, count: raster.width * raster.height)
            var result = [UInt8](repeating: 0, count: eligibility.count)
            var queue: [(x: Int, y: Int)] = [(seedX, seedY)]
            queue.reserveCapacity(min(raster.height * 2, 8_192))
            var selectedPixelCount = 0
            var selectedMinX = raster.width
            var selectedMinY = raster.height
            var selectedMaxX = -1
            var selectedMaxY = -1

            @inline(__always)
            func pixelQualifies(_ x: Int, _ y: Int) -> Bool {
                guard x >= 0, x < raster.width, y >= 0, y < raster.height else {
                    return false
                }
                let pixelIndex = (y * raster.width) + x
                guard result[pixelIndex] == 0 else { return false }
                switch eligibility[pixelIndex] {
                case 1:
                    return false
                case 2:
                    return true
                default:
                    guard lassoAlpha[pixelIndex] > 8 else {
                        eligibility[pixelIndex] = 1
                        return false
                    }
                    let candidate = feature(
                        atX: x,
                        y: y,
                        bytes: bytes,
                        bytesPerRow: raster.bytesPerRow
                    )
                    let accepted = perceptualDistanceSquared(candidate, reference) <= maximumDistanceSquared
                    eligibility[pixelIndex] = accepted ? 2 : 1
                    return accepted
                }
            }

            @inline(__always)
            func enqueueNeighborSegments(y: Int, minX: Int, maxX: Int) {
                guard y >= 0, y < raster.height else { return }
                var x = max(minX - 1, 0)
                let upperX = min(maxX + 1, raster.width - 1)
                while x <= upperX {
                    while x <= upperX, !pixelQualifies(x, y) {
                        x += 1
                    }
                    guard x <= upperX else { break }
                    queue.append((x, y))
                    x += 1
                    while x <= upperX, pixelQualifies(x, y) {
                        x += 1
                    }
                }
            }

            while let seed = queue.popLast() {
                guard pixelQualifies(seed.x, seed.y) else { continue }

                var leftX = seed.x
                while leftX > 0, pixelQualifies(leftX - 1, seed.y) {
                    leftX -= 1
                }
                var rightX = seed.x
                while rightX < raster.width - 1, pixelQualifies(rightX + 1, seed.y) {
                    rightX += 1
                }

                for x in leftX...rightX {
                    let pixelIndex = (seed.y * raster.width) + x
                    result[pixelIndex] = lassoAlpha[pixelIndex]
                    selectedPixelCount += 1
                    selectedMinX = min(selectedMinX, x)
                    selectedMinY = min(selectedMinY, seed.y)
                    selectedMaxX = max(selectedMaxX, x)
                    selectedMaxY = max(selectedMaxY, seed.y)
                }

                enqueueNeighborSegments(y: seed.y - 1, minX: leftX, maxX: rightX)
                enqueueNeighborSegments(y: seed.y + 1, minX: leftX, maxX: rightX)
            }

            guard selectedPixelCount > 0 else { return nil }
            return SmartSelectionSegmentationResult(
                originX: raster.originX,
                originY: raster.originY,
                width: raster.width,
                height: raster.height,
                alphaBytes: result,
                selectedPixelCount: selectedPixelCount,
                selectedBounds: CanvasRect(
                    origin: .init(
                        x: Double(raster.originX + selectedMinX),
                        y: Double(raster.originY + selectedMinY)
                    ),
                    size: .init(
                        x: Double(selectedMaxX - selectedMinX + 1),
                        y: Double(selectedMaxY - selectedMinY + 1)
                    )
                )
            )
        }
    }

    private static func foregroundSeedIndex(
        bytes: UnsafeBufferPointer<UInt8>,
        bytesPerRow: Int,
        lassoAlpha: [UInt8],
        width: Int,
        height: Int
    ) -> Int? {
        let centerX = Float(width - 1) * 0.5
        let centerY = Float(height - 1) * 0.5
        var boundaryFeature = Feature.zero
        var boundaryCount: Float = 0

        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width) + x
                guard lassoAlpha[index] > 127, isBoundaryPixel(x: x, y: y, mask: lassoAlpha, width: width, height: height) else {
                    continue
                }
                boundaryFeature = boundaryFeature + feature(
                    atX: x,
                    y: y,
                    bytes: bytes,
                    bytesPerRow: bytesPerRow
                )
                boundaryCount += 1
            }
        }

        let probableBackground = boundaryCount > 0 ? boundaryFeature / boundaryCount : nil
        let sampleStride = max(1, Int(sqrt(Double(width * height) / 20_000).rounded(.down)))
        let normalization = max(hypot(centerX, centerY), 1)
        var strongestIndex: Int?
        var strongestScore: Float = -.greatestFiniteMagnitude
        var nearestCenterIndex: Int?
        var nearestCenterDistance = Float.greatestFiniteMagnitude

        for y in stride(from: 0, to: height, by: sampleStride) {
            for x in stride(from: 0, to: width, by: sampleStride) {
                let index = (y * width) + x
                guard lassoAlpha[index] > 127 else { continue }
                let centerDistance = hypot(Float(x) - centerX, Float(y) - centerY)
                if centerDistance < nearestCenterDistance {
                    nearestCenterDistance = centerDistance
                    nearestCenterIndex = index
                }
                guard let probableBackground else { continue }
                let centrality = max(0, 1 - (centerDistance / normalization))
                let contrast = perceptualDistance(
                    feature(atX: x, y: y, bytes: bytes, bytesPerRow: bytesPerRow),
                    probableBackground
                )
                let score = contrast * (0.55 + (centrality * 0.45))
                if score > strongestScore {
                    strongestScore = score
                    strongestIndex = index
                }
            }
        }

        // When the boundary and interior are effectively the same color, the
        // lasso center is the least surprising target. Otherwise use the most
        // salient interior tone as the foreground hint.
        if strongestScore >= 0.025, let strongestIndex {
            return strongestIndex
        }
        return nearestCenterIndex
    }

    @inline(__always)
    private static func isBoundaryPixel(
        x: Int,
        y: Int,
        mask: [UInt8],
        width: Int,
        height: Int
    ) -> Bool {
        if x == 0 || y == 0 || x == width - 1 || y == height - 1 { return true }
        return mask[(y * width) + x - 1] <= 127
            || mask[(y * width) + x + 1] <= 127
            || mask[((y - 1) * width) + x] <= 127
            || mask[((y + 1) * width) + x] <= 127
    }

    private static func medianReferenceFeature(
        aroundX centerX: Int,
        y centerY: Int,
        bytes: UnsafeBufferPointer<UInt8>,
        bytesPerRow: Int,
        lassoAlpha: [UInt8],
        width: Int,
        height: Int
    ) -> Feature {
        var lightness: [Float] = []
        var a: [Float] = []
        var b: [Float] = []
        var alpha: [Float] = []
        let radius = 2

        for y in max(centerY - radius, 0)...min(centerY + radius, height - 1) {
            for x in max(centerX - radius, 0)...min(centerX + radius, width - 1) {
                guard lassoAlpha[(y * width) + x] > 127 else { continue }
                let value = feature(atX: x, y: y, bytes: bytes, bytesPerRow: bytesPerRow)
                lightness.append(value.lightness)
                a.append(value.a)
                b.append(value.b)
                alpha.append(value.alpha)
            }
        }

        guard !lightness.isEmpty else {
            return feature(atX: centerX, y: centerY, bytes: bytes, bytesPerRow: bytesPerRow)
        }
        return Feature(
            lightness: median(lightness),
            a: median(a),
            b: median(b),
            alpha: median(alpha)
        )
    }

    private static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) * 0.5
        }
        return sorted[middle]
    }

    @inline(__always)
    private static func feature(
        atX x: Int,
        y: Int,
        bytes: UnsafeBufferPointer<UInt8>,
        bytesPerRow: Int
    ) -> Feature {
        let offset = (y * bytesPerRow) + (x * 4)
        let alpha = Float(bytes[offset + 3]) / 255
        let red: Float
        let green: Float
        let blue: Float
        if alpha > 0.000_01 {
            red = min(max((Float(bytes[offset + 2]) / 255) / alpha, 0), 1)
            green = min(max((Float(bytes[offset + 1]) / 255) / alpha, 0), 1)
            blue = min(max((Float(bytes[offset]) / 255) / alpha, 0), 1)
        } else {
            red = 0
            green = 0
            blue = 0
        }
        let lab: OKLabColor
        if alpha >= 0.999 {
            lab = OKLabColor(
                linearRed: LinearPremultipliedColor.linearChannel(forSRGBByte: bytes[offset + 2]),
                green: LinearPremultipliedColor.linearChannel(forSRGBByte: bytes[offset + 1]),
                blue: LinearPremultipliedColor.linearChannel(forSRGBByte: bytes[offset])
            )
        } else {
            lab = OKLabColor(srgb: RGBAColor(red: red, green: green, blue: blue, alpha: alpha))
        }
        return Feature(lightness: lab.lightness, a: lab.a, b: lab.b, alpha: alpha)
    }

    @inline(__always)
    private static func perceptualDistance(_ lhs: Feature, _ rhs: Feature) -> Float {
        sqrt(perceptualDistanceSquared(lhs, rhs))
    }

    @inline(__always)
    private static func perceptualDistanceSquared(_ lhs: Feature, _ rhs: Feature) -> Float {
        let deltaLightness = lhs.lightness - rhs.lightness
        let deltaA = lhs.a - rhs.a
        let deltaB = lhs.b - rhs.b
        let deltaAlpha = lhs.alpha - rhs.alpha
        return (deltaLightness * deltaLightness)
            + (deltaA * deltaA)
            + (deltaB * deltaB)
            + ((deltaAlpha * deltaAlpha) * 0.2)
    }

    private static func perceptualDistanceThreshold(for tolerance: Float) -> Float {
        let normalized = min(max(tolerance, 0), 1)
        return 0.012 + (pow(normalized, 1.3) * 0.55)
    }
}

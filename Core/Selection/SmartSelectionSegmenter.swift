import Foundation

enum SmartSelectionDisplayMode: Sendable, Equatable {
    case tint
    case marchingAnts
}

enum MagicWandSampleSize: Int, Codable, Sendable, Equatable, CaseIterable {
    case point = 1
    case threeByThree = 3
    case fiveByFive = 5
    case elevenByEleven = 11
    case thirtyOneByThirtyOne = 31

    var dimension: Int { rawValue }
}

enum MagicWandSampleSource: String, Codable, Sendable, Equatable, CaseIterable {
    case currentLayer
    case allVisibleLayers
}

/// Magic Wand and geometry selections intentionally share one boolean-operation
/// model so a selection can be continued with a different tool.
typealias MagicWandSelectionMode = SelectionCombineMode

/// Photoshop-style fuzzy selection settings. Tolerance deliberately uses the
/// familiar 0...255 scale rather than the old ambiguous percentage.
struct SmartSelectionSettings: Codable, Sendable, Equatable {
    var tolerance: Int
    var sampleSize: MagicWandSampleSize
    var isAntiAliased: Bool
    var isContiguous: Bool
    var sampleSource: MagicWandSampleSource
    var selectionMode: MagicWandSelectionMode

    static let stageOneDefault = SmartSelectionSettings(
        tolerance: 32,
        sampleSize: .point,
        isAntiAliased: true,
        isContiguous: true,
        sampleSource: .allVisibleLayers,
        selectionMode: .replace
    )

    init(
        tolerance: Int,
        sampleSize: MagicWandSampleSize = .point,
        isAntiAliased: Bool = true,
        isContiguous: Bool = true,
        sampleSource: MagicWandSampleSource = .allVisibleLayers,
        selectionMode: MagicWandSelectionMode = .replace
    ) {
        self.tolerance = min(max(tolerance, 0), 255)
        self.sampleSize = sampleSize
        self.isAntiAliased = isAntiAliased
        self.isContiguous = isContiguous
        self.sampleSource = sampleSource
        self.selectionMode = selectionMode
    }

    private enum CodingKeys: String, CodingKey {
        case tolerance
        case sampleSize
        case isAntiAliased
        case isContiguous
        case sampleSource
        case selectionMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedTolerance: Int
        if let integer = try? container.decode(Int.self, forKey: .tolerance) {
            decodedTolerance = integer
        } else if let legacy = try? container.decode(Float.self, forKey: .tolerance) {
            decodedTolerance = Int((min(max(legacy, 0), 1) * 255).rounded())
        } else {
            decodedTolerance = Self.stageOneDefault.tolerance
        }
        self.init(
            tolerance: decodedTolerance,
            sampleSize: try container.decodeIfPresent(MagicWandSampleSize.self, forKey: .sampleSize) ?? .point,
            isAntiAliased: try container.decodeIfPresent(Bool.self, forKey: .isAntiAliased) ?? true,
            isContiguous: try container.decodeIfPresent(Bool.self, forKey: .isContiguous) ?? true,
            sampleSource: try container.decodeIfPresent(MagicWandSampleSource.self, forKey: .sampleSource) ?? .allVisibleLayers,
            selectionMode: try container.decodeIfPresent(MagicWandSelectionMode.self, forKey: .selectionMode) ?? .replace
        )
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

/// Seed-based fuzzy selector following the same model used by mature magic-wand
/// and contiguous-selection tools. The pixel provider lets the rendering layer
/// reuse it with either an in-memory composite or lazy Metal tiles.
enum SmartSelectionSegmenter {
    static func segment(
        raster: SmartSelectionRaster,
        seedPoint: CanvasPoint,
        settings: SmartSelectionSettings
    ) -> SmartSelectionSegmentationResult? {
        guard
            raster.width > 0,
            raster.height > 0,
            raster.bytesPerRow >= raster.width * 4,
            raster.premultipliedBGRABytes.count >= raster.bytesPerRow * raster.height
        else {
            return nil
        }

        return raster.premultipliedBGRABytes.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return try? segment(
                originX: raster.originX,
                originY: raster.originY,
                width: raster.width,
                height: raster.height,
                seedPoint: seedPoint,
                settings: settings
            ) { x, y in
                let offset = (y * raster.bytesPerRow) + (x * 4)
                return PremultipliedSRGBAPixel(
                    bgraBlue: bytes[offset],
                    green: bytes[offset + 1],
                    red: bytes[offset + 2],
                    alpha: bytes[offset + 3]
                )
            }
        }
    }

    static func segment(
        originX: Int,
        originY: Int,
        width: Int,
        height: Int,
        seedPoint: CanvasPoint,
        settings: SmartSelectionSettings,
        pixelAt: (Int, Int) throws -> PremultipliedSRGBAPixel
    ) throws -> SmartSelectionSegmentationResult? {
        guard width > 0, height > 0 else { return nil }
        let seedX = Int(seedPoint.x.rounded(.down)) - originX
        let seedY = Int(seedPoint.y.rounded(.down)) - originY
        guard seedX >= 0, seedX < width, seedY >= 0, seedY < height else { return nil }

        let reference = try sampledReferencePixel(
            centerX: seedX,
            centerY: seedY,
            width: width,
            height: height,
            sampleSize: settings.sampleSize,
            pixelAt: pixelAt
        )
        let threshold = Float(settings.tolerance) / 255
        let antialiasBand = settings.isAntiAliased ? max(2 / 255, threshold * 0.06) : 0

        @inline(__always)
        func coverage(_ pixel: PremultipliedSRGBAPixel) -> UInt8 {
            let distance = FillColorDistance.normalizedDistance(between: pixel, and: reference)
            if !settings.isAntiAliased {
                return distance <= threshold ? 255 : 0
            }
            if distance <= threshold { return 255 }
            guard distance < threshold + antialiasBand else { return 0 }
            let fraction = 1 - ((distance - threshold) / antialiasBand)
            return UInt8(clamping: Int((fraction * 255).rounded()))
        }

        var alpha = [UInt8](repeating: 0, count: width * height)
        var selectedPixelCount = 0
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1

        @inline(__always)
        func record(_ x: Int, _ y: Int, _ value: UInt8) {
            guard value > 0 else { return }
            let index = (y * width) + x
            guard alpha[index] == 0 else { return }
            alpha[index] = value
            selectedPixelCount += 1
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }

        if settings.isContiguous {
            // 0 unknown, 1 rejected, 2 accepted. This mirrors the scanline
            // flood-fill structure already used by BucketFillEngine, while the
            // one-pixel neighbor expansion preserves diagonal edge continuity.
            var eligibility = [UInt8](repeating: 0, count: width * height)
            var connected = [UInt8](repeating: 0, count: width * height)

            func acceptedCoverage(_ x: Int, _ y: Int) throws -> UInt8 {
                guard x >= 0, x < width, y >= 0, y < height else { return 0 }
                let index = (y * width) + x
                switch eligibility[index] {
                case 1: return 0
                case 2: return alpha[index]
                default:
                    let value = coverage(try pixelAt(x, y))
                    eligibility[index] = value > 0 ? 2 : 1
                    if value > 0 { alpha[index] = value }
                    return value
                }
            }

            let seedIndex = (seedY * width) + seedX
            eligibility[seedIndex] = 2
            alpha[seedIndex] = 255
            var queue: [(x: Int, y: Int)] = [(seedX, seedY)]
            queue.reserveCapacity(min(height * 2, 8_192))

            func enqueueSegments(y: Int, from startX: Int, through endX: Int) throws {
                guard y >= 0, y < height else { return }
                var x = max(startX, 0)
                let boundedEnd = min(endX, width - 1)
                while x <= boundedEnd {
                    while x <= boundedEnd {
                        if connected[(y * width) + x] == 0,
                           try acceptedCoverage(x, y) > 0 {
                            break
                        }
                        x += 1
                    }
                    guard x <= boundedEnd else { break }
                    queue.append((x, y))
                    while x <= boundedEnd,
                          connected[(y * width) + x] == 0,
                          try acceptedCoverage(x, y) > 0 {
                        x += 1
                    }
                }
            }

            while let seed = queue.popLast() {
                let seedIndex = (seed.y * width) + seed.x
                guard connected[seedIndex] == 0, try acceptedCoverage(seed.x, seed.y) > 0 else { continue }
                var left = seed.x
                while left > 0,
                      connected[(seed.y * width) + left - 1] == 0,
                      try acceptedCoverage(left - 1, seed.y) > 0 {
                    left -= 1
                }
                var right = seed.x
                while right < width - 1,
                      connected[(seed.y * width) + right + 1] == 0,
                      try acceptedCoverage(right + 1, seed.y) > 0 {
                    right += 1
                }

                for x in left...right {
                    let index = (seed.y * width) + x
                    connected[index] = 1
                    let value = alpha[index]
                    selectedPixelCount += 1
                    minX = min(minX, x)
                    minY = min(minY, seed.y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, seed.y)
                    alpha[index] = value
                }
                try enqueueSegments(y: seed.y - 1, from: left - 1, through: right + 1)
                try enqueueSegments(y: seed.y + 1, from: left - 1, through: right + 1)
            }

            for index in alpha.indices where connected[index] == 0 {
                alpha[index] = 0
            }
        } else {
            for y in 0..<height {
                for x in 0..<width {
                    record(x, y, coverage(try pixelAt(x, y)))
                }
            }
        }

        guard selectedPixelCount > 0, maxX >= minX, maxY >= minY else { return nil }
        return SmartSelectionSegmentationResult(
            originX: originX,
            originY: originY,
            width: width,
            height: height,
            alphaBytes: alpha,
            selectedPixelCount: selectedPixelCount,
            selectedBounds: CanvasRect(
                origin: CanvasPoint(x: Double(originX + minX), y: Double(originY + minY)),
                size: CanvasPoint(x: Double(maxX - minX + 1), y: Double(maxY - minY + 1))
            )
        )
    }

    private static func sampledReferencePixel(
        centerX: Int,
        centerY: Int,
        width: Int,
        height: Int,
        sampleSize: MagicWandSampleSize,
        pixelAt: (Int, Int) throws -> PremultipliedSRGBAPixel
    ) throws -> PremultipliedSRGBAPixel {
        let radius = sampleSize.dimension / 2
        let minX = max(centerX - radius, 0)
        let minY = max(centerY - radius, 0)
        let maxX = min(centerX + radius, width - 1)
        let maxY = min(centerY + radius, height - 1)
        var red: Float = 0
        var green: Float = 0
        var blue: Float = 0
        var alpha: Float = 0
        var count: Float = 0

        for y in minY...maxY {
            for x in minX...maxX {
                let components = FillColorDistance.unpremultipliedComponents(of: try pixelAt(x, y))
                red += components.red
                green += components.green
                blue += components.blue
                alpha += components.alpha
                count += 1
            }
        }
        guard count > 0 else { return try pixelAt(centerX, centerY) }
        red /= count
        green /= count
        blue /= count
        alpha /= count
        return PremultipliedSRGBAPixel(
            red: UInt8(clamping: Int((red * alpha * 255).rounded())),
            green: UInt8(clamping: Int((green * alpha * 255).rounded())),
            blue: UInt8(clamping: Int((blue * alpha * 255).rounded())),
            alpha: UInt8(clamping: Int((alpha * 255).rounded()))
        )
    }
}

import Foundation

struct GeneratorRasterSummary: Sendable, Equatable {
    var primitiveCount: Int
    var touchedPixelCount: Int
}

enum GeneratorRegionRasterizer {
    @discardableResult
    static func apply(
        settings: GeneratorSettings,
        color: RGBAColor,
        targetShape: SelectionShape?,
        originX: Int,
        originY: Int,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        bytes: inout [UInt8],
        seed: UInt64? = nil,
        encoding: CanvasPixelEncoding = .premultipliedBGRA8SRGB
    ) -> GeneratorRasterSummary {
        guard width > 0, height > 0, bytesPerRow >= width * encoding.bytesPerPixel, bytes.count >= bytesPerRow * height else {
            return .init(primitiveCount: 0, touchedPixelCount: 0)
        }

        let fallbackBounds = CanvasRect(
            origin: CanvasPoint(x: Double(originX), y: Double(originY)),
            size: CanvasPoint(x: Double(width), y: Double(height))
        )
        let bounds = targetShape?.bounds ?? fallbackBounds
        guard !bounds.isEmpty else {
            return .init(primitiveCount: 0, touchedPixelCount: 0)
        }

        var random = SeededGeneratorRandom(
            seed: seed ?? deterministicSeed(settings: settings, bounds: bounds)
        )
        var context = RasterContext(
            bytes: bytes,
            encoding: encoding,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            originX: originX,
            originY: originY,
            targetShape: targetShape,
            baseColor: color,
            opacity: min(max(settings.opacity, 0.05), 1)
        )

        let primitiveCount: Int
        switch settings.kind {
        case .automaticLines:
            primitiveCount = automaticLines(settings: settings, bounds: bounds, random: &random, context: &context)
        case .driftDraw:
            primitiveCount = driftDraw(settings: settings, bounds: bounds, random: &random, context: &context)
        case .elasticWhip:
            var variant = settings
            variant.density *= 0.72
            variant.drift = min(1, 0.35 + settings.drift * 0.65)
            primitiveCount = driftDraw(settings: variant, bounds: bounds, random: &random, context: &context)
        case .tremorTrace:
            var variant = settings
            variant.drift = min(1, 0.7 + settings.drift * 0.3)
            variant.branch *= 0.2
            primitiveCount = automaticLines(settings: variant, bounds: bounds, random: &random, context: &context)
        case .angularBreaks:
            var variant = settings
            variant.density = min(1, 0.25 + settings.density * 0.55)
            variant.drift = min(1, 0.45 + settings.drift * 0.5)
            primitiveCount = automaticLines(settings: variant, bounds: bounds, random: &random, context: &context)
        }

        bytes = context.bytes
        return GeneratorRasterSummary(
            primitiveCount: primitiveCount,
            touchedPixelCount: context.touchedPixels.count
        )
    }

    static func deterministicSeed(settings: GeneratorSettings, bounds: CanvasRect) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        func mix(_ value: UInt64) {
            hash ^= value
            hash &*= 0x0000_0100_0000_01B3
        }

        for byte in settings.kind.rawValue.utf8 {
            mix(UInt64(byte))
        }
        mix(UInt64(settings.density.bitPattern))
        mix(UInt64(settings.drift.bitPattern))
        mix(UInt64(settings.branch.bitPattern))
        mix(UInt64(settings.opacity.bitPattern))
        mix(bounds.minX.bitPattern)
        mix(bounds.minY.bitPattern)
        mix(bounds.maxX.bitPattern)
        mix(bounds.maxY.bitPattern)
        return hash
    }

    private static func automaticLines(
        settings: GeneratorSettings,
        bounds: CanvasRect,
        random: inout SeededGeneratorRandom,
        context: inout RasterContext
    ) -> Int {
        let shortEdge = Float(max(min(bounds.size.x, bounds.size.y), 1))
        let count = min(max(Int(sqrt(max(bounds.size.x * bounds.size.y, 1)) * Double(0.16 + settings.density * 0.42)), 8), 180)
        var rendered = 0
        for _ in 0..<count {
            guard let start = randomPoint(in: bounds, shape: context.targetShape, random: &random) else { continue }
            let length = shortEdge * (0.16 + settings.density * 0.5 + random.float(in: -0.05...0.1))
            let points = wanderingPath(
                start: start,
                length: length,
                segmentCount: max(6, Int(length / 10)),
                angle: random.float(in: 0...(Float.pi * 2)),
                drift: settings.drift,
                random: &random
            )
            context.drawPolyline(
                points,
                width: random.float(in: 1.2...3.8) * (0.7 + settings.density * 0.8),
                opacity: random.float(in: 0.2...0.48)
            )
            rendered += 1

            if points.count > 5, random.unit() < 0.06 + settings.branch * 0.32 {
                let index = min(max(Int(Float(points.count - 2) * random.float(in: 0.28...0.82)), 1), points.count - 2)
                let branch = wanderingPath(
                    start: points[index],
                    length: length * random.float(in: 0.28...0.6),
                    segmentCount: max(4, points.count / 2),
                    angle: random.float(in: 0...(Float.pi * 2)),
                    drift: min(settings.drift + 0.18, 1),
                    random: &random
                )
                context.drawPolyline(branch, width: random.float(in: 0.7...2.2), opacity: random.float(in: 0.14...0.34))
                rendered += 1
            }
        }
        return rendered
    }

    private static func inkBlots(
        settings: GeneratorSettings,
        bounds: CanvasRect,
        random: inout SeededGeneratorRandom,
        context: inout RasterContext
    ) -> Int {
        let shortEdge = Float(max(min(bounds.size.x, bounds.size.y), 1))
        let blotCount = min(max(Int(4 + settings.density * 22), 4), 28)
        var rendered = 0
        for _ in 0..<blotCount {
            guard let center = randomPoint(in: bounds, shape: context.targetShape, random: &random) else { continue }
            let baseRadius = max(2, shortEdge * random.float(in: 0.018...0.075) * (0.75 + settings.density))
            let satellites = min(max(Int(5 + settings.branch * 13), 5), 18)
            context.stampDisc(center: center, radius: baseRadius, softness: 0.16, opacity: random.float(in: 0.22...0.52))
            rendered += 1
            for index in 0..<satellites {
                let angle = (Float(index) / Float(satellites)) * Float.pi * 2 + random.float(in: -0.5...0.5) * settings.drift
                let distance = baseRadius * random.float(in: 0.28...1.05)
                let satelliteCenter = CanvasPoint(
                    x: center.x + Double(cos(angle) * distance),
                    y: center.y + Double(sin(angle) * distance)
                )
                context.stampDisc(
                    center: satelliteCenter,
                    radius: baseRadius * random.float(in: 0.32...0.82),
                    softness: random.float(in: 0.08...0.28),
                    opacity: random.float(in: 0.16...0.42)
                )
                rendered += 1
            }
        }
        return rendered
    }

    private static func fragmentField(
        settings: GeneratorSettings,
        bounds: CanvasRect,
        random: inout SeededGeneratorRandom,
        context: inout RasterContext
    ) -> Int {
        let shortEdge = Float(max(min(bounds.size.x, bounds.size.y), 1))
        let count = min(max(Int(12 + settings.density * 76), 12), 90)
        var rendered = 0
        for _ in 0..<count {
            guard let center = randomPoint(in: bounds, shape: context.targetShape, random: &random) else { continue }
            let radius = max(2, shortEdge * random.float(in: 0.012...0.055) * (0.65 + settings.density))
            let vertices = 3 + Int(random.next() % 4)
            let rotation = random.float(in: 0...(Float.pi * 2))
            var polygon: [CanvasPoint] = []
            polygon.reserveCapacity(vertices)
            for index in 0..<vertices {
                let angle = rotation + (Float(index) / Float(vertices)) * Float.pi * 2
                let localRadius = radius * random.float(in: 0.55...1.25)
                polygon.append(
                    CanvasPoint(
                        x: center.x + Double(cos(angle) * localRadius),
                        y: center.y + Double(sin(angle) * localRadius)
                    )
                )
            }
            context.fillPolygon(
                polygon,
                opacity: random.float(in: 0.12...0.4),
                colorScale: random.float(in: 0.78...1.18)
            )
            rendered += 1
        }
        return rendered
    }

    private static func brushStack(
        settings: GeneratorSettings,
        bounds: CanvasRect,
        random: inout SeededGeneratorRandom,
        context: inout RasterContext
    ) -> Int {
        let longEdge = Float(max(max(bounds.size.x, bounds.size.y), 1))
        let stackCount = min(max(Int(4 + settings.density * 18), 4), 24)
        var rendered = 0
        for _ in 0..<stackCount {
            guard let center = randomPoint(in: bounds, shape: context.targetShape, random: &random) else { continue }
            let angle = random.float(in: 0...(Float.pi * 2))
            let direction = CanvasPoint(x: Double(cos(angle)), y: Double(sin(angle)))
            let normal = CanvasPoint(x: -direction.y, y: direction.x)
            let strandCount = min(max(Int(3 + settings.branch * 9), 3), 12)
            let length = longEdge * random.float(in: 0.08...0.3)
            let spread = Float(strandCount) * random.float(in: 1.1...3.4)
            for strand in 0..<strandCount {
                let normalized = Float(strand) / Float(max(strandCount - 1, 1)) - 0.5
                let offset = normalized * spread
                let bend = random.float(in: -1...1) * length * (0.02 + settings.drift * 0.16)
                let start = CanvasPoint(
                    x: center.x - direction.x * Double(length * 0.5) + normal.x * Double(offset),
                    y: center.y - direction.y * Double(length * 0.5) + normal.y * Double(offset)
                )
                let middle = CanvasPoint(
                    x: center.x + normal.x * Double(offset + bend),
                    y: center.y + normal.y * Double(offset + bend)
                )
                let end = CanvasPoint(
                    x: center.x + direction.x * Double(length * 0.5) + normal.x * Double(offset * 0.7),
                    y: center.y + direction.y * Double(length * 0.5) + normal.y * Double(offset * 0.7)
                )
                context.drawPolyline(
                    [start, middle, end],
                    width: random.float(in: 0.8...2.4),
                    opacity: random.float(in: 0.12...0.32)
                )
                rendered += 1
            }
        }
        return rendered
    }

    private static func colorClusters(
        settings: GeneratorSettings,
        bounds: CanvasRect,
        random: inout SeededGeneratorRandom,
        context: inout RasterContext
    ) -> Int {
        let shortEdge = Float(max(min(bounds.size.x, bounds.size.y), 1))
        let clusterCount = min(max(Int(5 + settings.density * 24), 5), 30)
        var rendered = 0
        for _ in 0..<clusterCount {
            guard let center = randomPoint(in: bounds, shape: context.targetShape, random: &random) else { continue }
            let memberCount = min(max(Int(4 + settings.branch * 11), 4), 15)
            let spread = shortEdge * random.float(in: 0.018...0.065) * (0.6 + settings.drift)
            for _ in 0..<memberCount {
                let angle = random.float(in: 0...(Float.pi * 2))
                let distance = spread * sqrt(random.unit())
                let point = CanvasPoint(
                    x: center.x + Double(cos(angle) * distance),
                    y: center.y + Double(sin(angle) * distance)
                )
                context.stampDisc(
                    center: point,
                    radius: max(1.5, spread * random.float(in: 0.22...0.62)),
                    softness: random.float(in: 0.35...0.75),
                    opacity: random.float(in: 0.12...0.38),
                    colorScale: random.float(in: 0.72...1.26)
                )
                rendered += 1
            }
        }
        return rendered
    }

    private static func driftDraw(
        settings: GeneratorSettings,
        bounds: CanvasRect,
        random: inout SeededGeneratorRandom,
        context: inout RasterContext
    ) -> Int {
        let longEdge = Float(max(max(bounds.size.x, bounds.size.y), 1))
        let pathCount = min(max(Int(3 + settings.density * 17), 3), 20)
        var rendered = 0
        for _ in 0..<pathCount {
            guard let start = randomPoint(in: bounds, shape: context.targetShape, random: &random) else { continue }
            let length = longEdge * random.float(in: 0.18...0.52)
            let points = wanderingPath(
                start: start,
                length: length,
                segmentCount: max(12, Int(length / 7)),
                angle: random.float(in: 0...(Float.pi * 2)),
                drift: min(0.35 + settings.drift * 0.65, 1),
                random: &random
            )
            context.drawPolyline(
                points,
                width: random.float(in: 1.4...4.8) * (0.7 + settings.branch * 0.65),
                opacity: random.float(in: 0.16...0.38)
            )
            rendered += 1
        }
        return rendered
    }

    private static func randomPoint(
        in bounds: CanvasRect,
        shape: SelectionShape?,
        random: inout SeededGeneratorRandom
    ) -> CanvasPoint? {
        for _ in 0..<48 {
            let point = CanvasPoint(
                x: random.double(in: bounds.minX...bounds.maxX),
                y: random.double(in: bounds.minY...bounds.maxY)
            )
            if shape?.contains(point) ?? true {
                return point
            }
        }
        return nil
    }

    private static func wanderingPath(
        start: CanvasPoint,
        length: Float,
        segmentCount: Int,
        angle initialAngle: Float,
        drift: Float,
        random: inout SeededGeneratorRandom
    ) -> [CanvasPoint] {
        var points = [start]
        var current = start
        var angle = initialAngle
        var angularVelocity: Float = 0
        var wavePhase = random.float(in: 0...(Float.pi * 2))
        let step = max(length / Float(max(segmentCount, 1)), 1.5)
        for _ in 0..<segmentCount {
            angularVelocity += random.float(in: -0.11...0.11) * (0.25 + drift * 2.4)
            angularVelocity *= 0.78
            wavePhase += random.float(in: 0.16...0.48)
            angle += angularVelocity + sin(wavePhase) * 0.025 * drift
            current = CanvasPoint(
                x: current.x + Double(cos(angle) * step),
                y: current.y + Double(sin(angle) * step)
            )
            points.append(current)
        }
        return points
    }
}

private struct RasterContext {
    var bytes: [UInt8]
    var encoding: CanvasPixelEncoding
    var width: Int
    var height: Int
    var bytesPerRow: Int
    var originX: Int
    var originY: Int
    var targetShape: SelectionShape?
    var baseColor: RGBAColor
    var opacity: Float
    var touchedPixels: Set<Int> = []

    mutating func drawPolyline(
        _ points: [CanvasPoint],
        width lineWidth: Float,
        opacity lineOpacity: Float,
        colorScale: Float = 1
    ) {
        guard points.count >= 2 else { return }
        for index in 1..<points.count {
            let start = points[index - 1]
            let end = points[index]
            let dx = end.x - start.x
            let dy = end.y - start.y
            let distance = max(hypot(dx, dy), 0.0001)
            let steps = max(Int(distance / Double(max(lineWidth * 0.35, 0.6))), 1)
            for step in 0...steps {
                let t = Double(step) / Double(steps)
                let taper = Float(1 - abs((t * 2) - 1))
                stampDisc(
                    center: CanvasPoint(x: start.x + dx * t, y: start.y + dy * t),
                    radius: lineWidth * (0.68 + taper * 0.3),
                    softness: 0.5,
                    opacity: lineOpacity * (0.72 + taper * 0.28),
                    colorScale: colorScale
                )
            }
        }
    }

    mutating func stampDisc(
        center: CanvasPoint,
        radius: Float,
        softness: Float,
        opacity localOpacity: Float,
        colorScale: Float = 1
    ) {
        let radius = max(radius, 0.75)
        let minX = max(Int(floor(center.x - Double(radius))) - originX, 0)
        let maxX = min(Int(ceil(center.x + Double(radius))) - originX, width - 1)
        let minY = max(Int(floor(center.y - Double(radius))) - originY, 0)
        let maxY = min(Int(ceil(center.y + Double(radius))) - originY, height - 1)
        guard minX <= maxX, minY <= maxY else { return }

        let hardness = 1 - min(max(softness, 0), 1)
        for y in minY...maxY {
            for x in minX...maxX {
                let point = CanvasPoint(x: Double(originX + x) + 0.5, y: Double(originY + y) + 0.5)
                guard targetShape?.contains(point) ?? true else { continue }
                let normalized = Float(hypot(point.x - center.x, point.y - center.y)) / radius
                guard normalized <= 1 else { continue }
                let falloff: Float
                if normalized <= hardness {
                    falloff = 1
                } else {
                    let edge = max(1 - hardness, 0.0001)
                    let t = min(max((normalized - hardness) / edge, 0), 1)
                    falloff = 1 - t * t * (3 - 2 * t)
                }
                blendPixel(x: x, y: y, opacity: localOpacity * falloff, colorScale: colorScale)
            }
        }
    }

    mutating func fillPolygon(_ polygon: [CanvasPoint], opacity: Float, colorScale: Float) {
        guard polygon.count >= 3 else { return }
        let bounds = CanvasRect.bounding(points: polygon)
        let minX = max(Int(floor(bounds.minX)) - originX, 0)
        let maxX = min(Int(ceil(bounds.maxX)) - originX, width - 1)
        let minY = max(Int(floor(bounds.minY)) - originY, 0)
        let maxY = min(Int(ceil(bounds.maxY)) - originY, height - 1)
        guard minX <= maxX, minY <= maxY else { return }

        for y in minY...maxY {
            for x in minX...maxX {
                let point = CanvasPoint(x: Double(originX + x) + 0.5, y: Double(originY + y) + 0.5)
                guard (targetShape?.contains(point) ?? true), Self.polygon(polygon, contains: point) else { continue }
                blendPixel(x: x, y: y, opacity: opacity, colorScale: colorScale)
            }
        }
    }

    private mutating func blendPixel(x: Int, y: Int, opacity localOpacity: Float, colorScale: Float) {
        let alpha = min(max(localOpacity * opacity * baseColor.alpha, 0), 1)
        guard alpha > 0.001 else { return }
        let index = y * bytesPerRow + x * encoding.bytesPerPixel
        let destination = bytes.withUnsafeBytes { CanvasPixelCodec.read($0, offset: index, encoding: encoding) }
        let adjusted = RGBAColor(
            red: min(max(baseColor.red * colorScale, 0), 1),
            green: min(max(baseColor.green * colorScale, 0), 1),
            blue: min(max(baseColor.blue * colorScale, 0), 1),
            alpha: alpha
        )
        let source = LinearPremultipliedColor(srgbPremultiplied: adjusted.premultiplied)
        let output = source.composited(over: destination)
        bytes.withUnsafeMutableBytes { CanvasPixelCodec.write(output, into: $0, offset: index, encoding: encoding) }
        touchedPixels.insert(y * width + x)
    }

    private static func polygon(_ polygon: [CanvasPoint], contains point: CanvasPoint) -> Bool {
        var contains = false
        var previous = polygon[polygon.count - 1]
        for current in polygon {
            let deltaY = previous.y - current.y
            let safeDeltaY = abs(deltaY) < 0.000_001 ? 0.000_001 : deltaY
            let intersects = ((current.y > point.y) != (previous.y > point.y))
                && point.x < ((previous.x - current.x) * (point.y - current.y) / safeDeltaY) + current.x
            if intersects { contains.toggle() }
            previous = current
        }
        return contains
    }
}

private extension SeededGeneratorRandom {
    mutating func unit() -> Float {
        nextUnitFloat()
    }

    mutating func float(in range: ClosedRange<Float>) -> Float {
        nextFloat(in: range)
    }

    mutating func double(in range: ClosedRange<Double>) -> Double {
        guard range.lowerBound < range.upperBound else { return range.lowerBound }
        let unit = Double(next() >> 11) / Double(UInt64(1) << 53)
        return range.lowerBound + (range.upperBound - range.lowerBound) * unit
    }
}

import Foundation

struct CreativeShapeGeneratedShape: Sendable, Equatable {
    var center: CanvasPoint
    var boundaryPoints: [CanvasPoint]
    var color: RGBAColor
    var featherAmount: Float
}

struct CreativeShapeGeneratorPlan: Sendable, Equatable {
    var shapes: [CreativeShapeGeneratedShape]
    var seed: UInt64
}

struct CreativeShapeGeneratorColorContext: Sendable, Equatable {
    var selectedColor: RGBAColor
    var brushOpacity: Float
    var brushNoise: Float
    var paletteColors: [RGBAColor]
}

private struct CreativeShapeDeterministicSeedBuilder {
    private(set) var state: UInt64 = 0xcbf29ce484222325
    private static let prime: UInt64 = 0x100000001b3

    mutating func mix(_ value: UInt64) {
        state ^= value
        state &*= Self.prime
    }

    mutating func mix(_ value: Int) {
        mix(UInt64(bitPattern: Int64(value)))
    }

    mutating func mix(_ value: Float) {
        mix(UInt64(value.bitPattern))
    }

    mutating func mix(_ value: Double) {
        mix(value.bitPattern)
    }

    mutating func mix(_ value: String) {
        for byte in value.utf8 {
            mix(UInt64(byte))
        }
    }

    mutating func mix(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.isEmpty == false else {
            mix(0)
            return
        }
        let stride = max(bytes.count / 512, 1)
        var index = 0
        while index < bytes.count {
            mix(UInt64(bytes[index]))
            index += stride
        }
        mix(bytes.count)
    }
}

private struct CreativeShapeGeneratorRandom {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func float(in range: ClosedRange<Float>) -> Float {
        let fraction = Float(nextUInt64() & 0x00FF_FFFF) / Float(0x00FF_FFFF)
        return range.lowerBound + ((range.upperBound - range.lowerBound) * fraction)
    }

    mutating func double(in range: ClosedRange<Double>) -> Double {
        let fraction = Double(nextUInt64() & 0x001F_FFFF_FFFF_FFFF) / Double(0x001F_FFFF_FFFF_FFFF)
        return range.lowerBound + ((range.upperBound - range.lowerBound) * fraction)
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        guard range.lowerBound < range.upperBound else { return range.lowerBound }
        let delta = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(nextUInt64() % delta)
    }

    mutating func bool(probability: Float) -> Bool {
        float(in: 0...1) <= probability
    }
}

enum CreativeShapeGeneratorEngine {
    static func makePlan(
        selectionShape: SelectionShape,
        state: CreativeShapeGeneratorState,
        colorContext: CreativeShapeGeneratorColorContext,
        runtimeSeed: UInt64
    ) -> CreativeShapeGeneratorPlan? {
        guard state.isEnabled else { return nil }
        let clampedShape = selectionShape
        guard clampedShape.isEmpty == false else { return nil }

        let seed = resolvedSeed(
            selectionShape: clampedShape,
            state: state,
            colorContext: colorContext,
            runtimeSeed: runtimeSeed
        )
        var random = CreativeShapeGeneratorRandom(seed: seed)
        let bounds = clampedShape.bounds
        let shortestSide = max(Float(min(bounds.size.x, bounds.size.y)), 1)

        let baseCount = resolvedBaseCount(shapeSize: state.shapeSize)
        let countVariation = resolvedCountVariation(shapeJitter: state.shapeJitter, random: &random)
        let resolvedCount = max(1, Int((Double(baseCount) * countVariation).rounded()))
        let clusterAnchors = resolvedClusterAnchors(
            count: resolvedCount,
            selectionShape: clampedShape,
            shapeJitter: state.shapeJitter,
            random: &random
        )

        var shapes: [CreativeShapeGeneratedShape] = []
        shapes.reserveCapacity(resolvedCount)

        for index in 0..<resolvedCount {
            guard let center = resolvedCenterPoint(
                index: index,
                totalCount: resolvedCount,
                selectionShape: clampedShape,
                clusterAnchors: clusterAnchors,
                shapeJitter: state.shapeJitter,
                random: &random
            ) else { continue }
            let feature = clamp(
                state.shapeCharacteristic + (random.float(in: -0.55...0.55) * state.shapeJitter),
                0,
                1
            )
            let diameter = resolvedDiameter(
                shortestSide: shortestSide,
                shapeSize: state.shapeSize,
                shapeJitter: state.shapeJitter,
                random: &random
            )
            let boundaryPoints = organicShapePoints(
                center: center,
                diameter: diameter,
                organicity: feature,
                shapeJitter: state.shapeJitter,
                random: &random
            )
            guard boundaryPoints.count >= 3 else { continue }
            let selectionRelativePoint = normalizedPoint(center, in: bounds)
            let color = resolvedColor(
                for: state,
                selectionRelativePoint: selectionRelativePoint,
                shapeIndex: index,
                totalShapeCount: resolvedCount,
                colorContext: colorContext,
                imageSource: state.importedImage,
                random: &random
            )
            shapes.append(
                CreativeShapeGeneratedShape(
                    center: center,
                    boundaryPoints: boundaryPoints,
                    color: color,
                    featherAmount: resolvedFeatherAmount(
                        featherProbability: state.featherProbability,
                        shapeJitter: state.shapeJitter,
                        random: &random
                    )
                )
            )
            if index == 0 && state.shapeSize <= 0.001 {
                break
            }
        }

        guard shapes.isEmpty == false else { return nil }
        return CreativeShapeGeneratorPlan(
            shapes: reordered(shapes: shapes, shapeJitter: state.shapeJitter, random: &random),
            seed: seed
        )
    }

    private static func resolvedFeatherAmount(
        featherProbability: Float,
        shapeJitter: Float,
        random: inout CreativeShapeGeneratorRandom
    ) -> Float {
        let probability = clamp(featherProbability, 0, 1)
        guard probability > 0.0001, random.bool(probability: probability) else {
            return 0
        }

        let baseSoftness = random.float(in: 0.16...0.30)
        let contrastBoost = lerp(0.9, 1.22, shapeJitter)
        return clamp(baseSoftness * contrastBoost, 0.08, 0.36)
    }

    private static func resolvedSeed(
        selectionShape: SelectionShape,
        state: CreativeShapeGeneratorState,
        colorContext: CreativeShapeGeneratorColorContext,
        runtimeSeed: UInt64
    ) -> UInt64 {
        if state.shapeJitter > 0.0001 {
            return runtimeSeed
        }

        var builder = CreativeShapeDeterministicSeedBuilder()
        builder.mix(selectionShape.kind.rawValue)
        builder.mix(selectionShape.bounds.minX)
        builder.mix(selectionShape.bounds.minY)
        builder.mix(selectionShape.bounds.maxX)
        builder.mix(selectionShape.bounds.maxY)
        for point in sampled(points: selectionShape.pathPoints, limit: 24) {
            builder.mix(point.x)
            builder.mix(point.y)
        }
        builder.mix(state.selectedSource?.rawValue ?? "none")
        builder.mix(state.featherProbability)
        builder.mix(state.shapeCharacteristic)
        builder.mix(state.shapeSize)
        builder.mix(state.shapeJitter)
        builder.mix(state.colorJitter)
        builder.mix(colorContext.selectedColor.red)
        builder.mix(colorContext.selectedColor.green)
        builder.mix(colorContext.selectedColor.blue)
        builder.mix(colorContext.selectedColor.alpha)
        builder.mix(colorContext.brushOpacity)
        builder.mix(colorContext.brushNoise)
        for color in colorContext.paletteColors.prefix(25) {
            builder.mix(color.red)
            builder.mix(color.green)
            builder.mix(color.blue)
            builder.mix(color.alpha)
        }
        if let importedImage = state.importedImage {
            builder.mix(importedImage.fileName)
            builder.mix(importedImage.width)
            builder.mix(importedImage.height)
            builder.mix(importedImage.rgbaPixels)
        }
        return builder.state
    }

    private static func sampled(points: [CanvasPoint], limit: Int) -> [CanvasPoint] {
        guard points.count > limit, limit > 0 else { return points }
        let sampleStride = max(points.count / limit, 1)
        return Swift.stride(from: 0, to: points.count, by: sampleStride).map { points[$0] }
    }

    private static func resolvedBaseCount(shapeSize: Float) -> Int {
        let clamped = clamp(shapeSize, 0, 1)
        let maxCount = 8 + Int((clamped * 24).rounded())
        return max(1, Int((1 + (clamped * Float(maxCount - 1))).rounded()))
    }

    private static func resolvedCountVariation(
        shapeJitter: Float,
        random: inout CreativeShapeGeneratorRandom
    ) -> Double {
        let clamped = clamp(shapeJitter, 0, 1)
        guard clamped > 0.0001 else { return 1 }
        let contrast = Float(pow(Double(clamped), 1.15))
        let sparseTarget = random.float(in: 0.35...0.82)
        let denseTarget = random.float(in: 1.25...2.35)
        let target = random.bool(probability: 0.46) ? sparseTarget : denseTarget
        return Double(lerp(1, target, contrast))
    }

    private static func resolvedDiameter(
        shortestSide: Float,
        shapeSize: Float,
        shapeJitter: Float,
        random: inout CreativeShapeGeneratorRandom
    ) -> Float {
        let clamped = clamp(shapeSize, 0, 1)
        let minDiameter = shortestSide * lerp(0.70, 0.04, clamped)
        let maxDiameter = shortestSide * lerp(0.90, 0.12, clamped)
        var diameter = random.float(in: minDiameter...max(maxDiameter, minDiameter))
        if shapeJitter > 0.0001 {
            let contrast = Float(pow(Double(clamp(shapeJitter, 0, 1)), 1.1))
            let shrinkScale = random.float(in: 0.28...0.82)
            let growScale = random.float(in: 1.18...2.85)
            let targetScale = random.bool(probability: 0.5) ? shrinkScale : growScale
            diameter *= lerp(1, targetScale, contrast)
        }
        return max(diameter, shortestSide * 0.02)
    }

    private static func resolvedClusterAnchors(
        count: Int,
        selectionShape: SelectionShape,
        shapeJitter: Float,
        random: inout CreativeShapeGeneratorRandom
    ) -> [CanvasPoint] {
        guard count > 1, shapeJitter > 0.0001 else { return [] }
        let clusterCount = min(4, max(1, Int((shapeJitter * 3.2).rounded())))
        var anchors: [CanvasPoint] = []
        anchors.reserveCapacity(clusterCount)
        for _ in 0..<clusterCount {
            if let point = randomPoint(in: selectionShape, random: &random) {
                anchors.append(point)
            }
        }
        return anchors
    }

    private static func resolvedCenterPoint(
        index: Int,
        totalCount: Int,
        selectionShape: SelectionShape,
        clusterAnchors: [CanvasPoint],
        shapeJitter: Float,
        random: inout CreativeShapeGeneratorRandom
    ) -> CanvasPoint? {
        guard
            shapeJitter > 0.0001,
            clusterAnchors.isEmpty == false,
            totalCount > 1,
            random.bool(probability: lerp(0.18, 0.86, shapeJitter))
        else {
            return randomPoint(in: selectionShape, random: &random)
        }

        let anchor = clusterAnchors[min(index % clusterAnchors.count, clusterAnchors.count - 1)]
        let bounds = selectionShape.bounds
        let reach = min(bounds.size.x, bounds.size.y) * Double(lerp(0.06, 0.28, shapeJitter))
        for _ in 0..<24 {
            let angle = random.double(in: 0...(Double.pi * 2))
            let distance = random.double(in: 0...(reach * random.double(in: 0.25...1.0)))
            let point = CanvasPoint(
                x: anchor.x + (cos(angle) * distance),
                y: anchor.y + (sin(angle) * distance)
            )
            if selectionShape.contains(point) {
                return point
            }
        }

        return randomPoint(in: selectionShape, random: &random)
    }

    private static func randomPoint(
        in selectionShape: SelectionShape,
        random: inout CreativeShapeGeneratorRandom
    ) -> CanvasPoint? {
        let bounds = selectionShape.bounds
        for _ in 0..<36 {
            let point = CanvasPoint(
                x: random.double(in: bounds.minX...bounds.maxX),
                y: random.double(in: bounds.minY...bounds.maxY)
            )
            if selectionShape.contains(point) {
                return point
            }
        }

        let fallback = CanvasPoint(
            x: bounds.origin.x + (bounds.size.x * 0.5),
            y: bounds.origin.y + (bounds.size.y * 0.5)
        )
        return selectionShape.contains(fallback) ? fallback : nil
    }

    private static func normalizedPoint(_ point: CanvasPoint, in bounds: CanvasRect) -> CanvasPoint {
        let width = max(bounds.size.x, 0.0001)
        let height = max(bounds.size.y, 0.0001)
        return CanvasPoint(
            x: min(max((point.x - bounds.minX) / width, 0), 1),
            y: min(max((point.y - bounds.minY) / height, 0), 1)
        )
    }

    private static func organicShapePoints(
        center: CanvasPoint,
        diameter: Float,
        organicity: Float,
        shapeJitter: Float,
        random: inout CreativeShapeGeneratorRandom
    ) -> [CanvasPoint] {
        func reducedExaggeration(_ value: Double, anchor: Double = 1.0, keepRatio: Double = 0.4) -> Double {
            anchor + ((value - anchor) * keepRatio)
        }

        let clampedOrganicity = clamp(organicity, 0, 1)
        let pointCountLower = 8 + Int((clampedOrganicity * 4).rounded())
        let pointCountUpper = 12 + Int((clampedOrganicity * 6).rounded()) + Int((shapeJitter * 3).rounded())
        let pointCount = random.int(in: pointCountLower...max(pointCountLower, pointCountUpper))
        let baseRadius = Double(diameter) * 0.5
        let step = (Double.pi * 2) / Double(pointCount)
        let angularJitter = Double(lerp(0.14, 0.92, clampedOrganicity))
        let jitterLimit = min(Double.pi / 4, step * angularJitter)
        let innerRadiusScale = Double(lerp(0.88, 0.24, clampedOrganicity))
        let outerRadiusScale = Double(lerp(1.10, 2.35, clampedOrganicity))
        let lobeAmplitude = Double(lerp(0.04, 0.24, clampedOrganicity))
        let lobeCount = max(2, 2 + Int((clampedOrganicity * 5).rounded()))
        let phase = random.double(in: 0...(Double.pi * 2))
        let orientation = random.double(in: 0...(Double.pi * 2))
        let stretchBias = max(clampedOrganicity, shapeJitter * 0.8)
        let majorScaleMin = reducedExaggeration(Double(lerp(1.0, 1.4, stretchBias)))
        let majorScaleMax = reducedExaggeration(Double(lerp(1.2, 3.8, stretchBias)))
        var majorScale = random.double(
            in: min(majorScaleMin, majorScaleMax)...max(majorScaleMin, majorScaleMax)
        )
        let minorScaleMin = reducedExaggeration(Double(lerp(0.92, 0.74, stretchBias)))
        let minorScaleMax = reducedExaggeration(Double(lerp(0.88, 0.18, stretchBias)))
        var minorScale = random.double(
            in: min(minorScaleMin, minorScaleMax)...max(minorScaleMin, minorScaleMax)
        )
        if random.bool(probability: lerp(0.07, 0.31, stretchBias)) {
            majorScale *= random.double(
                in: reducedExaggeration(1.08)...reducedExaggeration(1.85)
            )
            minorScale *= random.double(
                in: reducedExaggeration(0.55)...reducedExaggeration(0.94)
            )
        }
        let pinchProbability = lerp(0.05, 0.22, stretchBias)
        let flutterAmplitude = Double(lerp(0.02, 0.18, shapeJitter))

        var controlPoints: [CanvasPoint] = []
        controlPoints.reserveCapacity(pointCount)

        for index in 0..<pointCount {
            let angle = (Double(index) * step) + random.double(in: -jitterLimit...jitterLimit)
            let lobe = 1 + (sin((angle * Double(lobeCount)) + phase) * lobeAmplitude)
            var radius = baseRadius * lobe * random.double(in: innerRadiusScale...outerRadiusScale)
            radius *= 1 + (sin((angle * Double(max(lobeCount - 1, 1))) - phase * 0.35) * flutterAmplitude)
            if random.bool(probability: pinchProbability) {
                radius *= random.double(
                    in: reducedExaggeration(0.24)...reducedExaggeration(0.74)
                )
            }
            let localX = cos(angle) * radius * majorScale
            let localY = sin(angle) * radius * minorScale
            let rotatedX = (localX * cos(orientation)) - (localY * sin(orientation))
            let rotatedY = (localX * sin(orientation)) + (localY * cos(orientation))
            controlPoints.append(
                CanvasPoint(
                    x: center.x + rotatedX,
                    y: center.y + rotatedY
                )
            )
        }

        let samplesPerSegment = max(8, 12 - Int((clampedOrganicity * 4).rounded()))
        return sampledClosedCatmullRom(controlPoints: controlPoints, samplesPerSegment: samplesPerSegment)
    }

    private static func sampledClosedCatmullRom(
        controlPoints: [CanvasPoint],
        samplesPerSegment: Int
    ) -> [CanvasPoint] {
        guard controlPoints.count >= 3 else { return controlPoints }
        let count = controlPoints.count
        var sampled: [CanvasPoint] = []
        sampled.reserveCapacity(count * samplesPerSegment)

        for index in 0..<count {
            let p0 = controlPoints[(index - 1 + count) % count]
            let p1 = controlPoints[index]
            let p2 = controlPoints[(index + 1) % count]
            let p3 = controlPoints[(index + 2) % count]

            for stepIndex in 0..<samplesPerSegment {
                let t = Double(stepIndex) / Double(samplesPerSegment)
                sampled.append(catmullRomPoint(p0: p0, p1: p1, p2: p2, p3: p3, t: t))
            }
        }

        return sampled
    }

    private static func catmullRomPoint(
        p0: CanvasPoint,
        p1: CanvasPoint,
        p2: CanvasPoint,
        p3: CanvasPoint,
        t: Double
    ) -> CanvasPoint {
        let t2 = t * t
        let t3 = t2 * t

        let x = 0.5 * (
            (2 * p1.x) +
            (-p0.x + p2.x) * t +
            ((2 * p0.x) - (5 * p1.x) + (4 * p2.x) - p3.x) * t2 +
            (-p0.x + (3 * p1.x) - (3 * p2.x) + p3.x) * t3
        )
        let y = 0.5 * (
            (2 * p1.y) +
            (-p0.y + p2.y) * t +
            ((2 * p0.y) - (5 * p1.y) + (4 * p2.y) - p3.y) * t2 +
            (-p0.y + (3 * p1.y) - (3 * p2.y) + p3.y) * t3
        )
        return CanvasPoint(x: x, y: y)
    }

    private static func resolvedColor(
        for state: CreativeShapeGeneratorState,
        selectionRelativePoint: CanvasPoint,
        shapeIndex: Int,
        totalShapeCount: Int,
        colorContext: CreativeShapeGeneratorColorContext,
        imageSource: CreativeShapeGeneratorImageSource?,
        random: inout CreativeShapeGeneratorRandom
    ) -> RGBAColor {
        let baseColor: RGBAColor
        switch state.selectedSource {
        case .currentColor:
            baseColor = colorContext.selectedColor
        case .paletteBlocks:
            let palette = colorContext.paletteColors.isEmpty ? [colorContext.selectedColor] : colorContext.paletteColors
            baseColor = palette[random.int(in: 0...(palette.count - 1))]
        case .externalImage:
            baseColor = sampledImageColor(
                at: selectionRelativePoint,
                imageSource: imageSource,
                fallback: colorContext.selectedColor,
                random: &random
            )
        case .none:
            baseColor = colorContext.selectedColor
        }

        let baseAlpha = clamp(baseColor.alpha * colorContext.brushOpacity, 0, 1)
        var color = RGBAColor(red: baseColor.red, green: baseColor.green, blue: baseColor.blue, alpha: baseAlpha)

        let panelJitter = clamp(state.colorJitter, 0, 1)
        let brushNoise = state.selectedSource == .currentColor ? clamp(colorContext.brushNoise, 0, 1) : 0
        if panelJitter > 0.0001 || brushNoise > 0.0001 {
            let normalizedIndex = totalShapeCount > 1
                ? (Float(shapeIndex) / Float(max(totalShapeCount - 1, 1))) * 2 - 1
                : 0
            color = jitteredColor(
                color,
                baseHueOffset: normalizedIndex * (0.34 * panelJitter),
                baseSaturationOffset: normalizedIndex * (0.42 * panelJitter),
                baseValueOffset: -normalizedIndex * (0.36 * panelJitter),
                hueRange: (0.42 * panelJitter) + (0.14 * brushNoise),
                saturationRange: (0.55 * panelJitter) + (0.20 * brushNoise),
                valueRange: (0.45 * panelJitter) + (0.18 * brushNoise),
                random: &random
            )
        }

        return color
    }

    private static func sampledImageColor(
        at normalizedPoint: CanvasPoint,
        imageSource: CreativeShapeGeneratorImageSource?,
        fallback: RGBAColor,
        random: inout CreativeShapeGeneratorRandom
    ) -> RGBAColor {
        guard let imageSource, imageSource.isValid else { return fallback }
        let width = imageSource.width
        let height = imageSource.height
        let bytes = [UInt8](imageSource.rgbaPixels)
        guard bytes.count == width * height * 4 else { return fallback }

        let baseX = clamp(Float(normalizedPoint.x), 0, 1)
        let baseY = clamp(Float(normalizedPoint.y), 0, 1)
        let offsetX = random.float(in: -0.08...0.08)
        let offsetY = random.float(in: -0.08...0.08)
        let sampledX = clamp(baseX + offsetX, 0, 1)
        let sampledY = clamp(baseY + offsetY, 0, 1)
        let pixelX = min(max(Int((sampledX * Float(width - 1)).rounded()), 0), width - 1)
        let pixelY = min(max(Int((sampledY * Float(height - 1)).rounded()), 0), height - 1)
        let index = ((pixelY * width) + pixelX) * 4
        guard index + 3 < bytes.count else { return fallback }

        let alpha = Float(bytes[index + 3]) / 255
        guard alpha > 0.001 else { return fallback }
        let red = (Float(bytes[index]) / 255) / alpha
        let green = (Float(bytes[index + 1]) / 255) / alpha
        let blue = (Float(bytes[index + 2]) / 255) / alpha

        return RGBAColor(
            red: clamp(red, 0, 1),
            green: clamp(green, 0, 1),
            blue: clamp(blue, 0, 1),
            alpha: 1
        )
    }

    private static func jitteredColor(
        _ color: RGBAColor,
        baseHueOffset: Float,
        baseSaturationOffset: Float,
        baseValueOffset: Float,
        hueRange: Float,
        saturationRange: Float,
        valueRange: Float,
        random: inout CreativeShapeGeneratorRandom
    ) -> RGBAColor {
        var hsv = ColorBlocksEngine.rgbToHsv(color)
        hsv.h = ColorBlocksEngine.wrapHue(
            hsv.h +
            (baseHueOffset * 360) +
            random.float(in: -(hueRange * 360)...(hueRange * 360))
        )
        hsv.s = clamp(
            hsv.s +
            baseSaturationOffset +
            random.float(in: -saturationRange...saturationRange),
            0,
            1
        )
        hsv.v = clamp(
            hsv.v +
            baseValueOffset +
            random.float(in: -valueRange...valueRange),
            0,
            1
        )
        return ColorBlocksEngine.hsvToRgb(hsv, alpha: color.alpha)
    }

    private static func reordered(
        shapes: [CreativeShapeGeneratedShape],
        shapeJitter: Float,
        random: inout CreativeShapeGeneratorRandom
    ) -> [CreativeShapeGeneratedShape] {
        guard shapeJitter > 0.0001, shapes.count > 1 else { return shapes }
        return shapes.enumerated()
            .map { index, shape in
                let shuffleWeight = Double(index) + random.double(in: -1...1) * Double(shapeJitter) * Double(shapes.count)
                return (shape, shuffleWeight)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    private static func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
        a + ((b - a) * clamp(t, 0, 1))
    }

    private static func clamp<T: Comparable>(_ value: T, _ minValue: T, _ maxValue: T) -> T {
        min(max(value, minValue), maxValue)
    }
}

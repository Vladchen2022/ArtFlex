import Foundation

struct CreativeShapeGeneratorTipMaterial: Sendable, Equatable {
    var id: BrushTipImageAssetID
    var maskData: Data
}

struct CreativeShapeGeneratedTipStamp: Sendable, Equatable {
    var materialID: BrushTipImageAssetID
    var size: CanvasPoint
    var rotationDegrees: Float
}

enum CreativeShapeGeneratedGeometry: Sendable, Equatable {
    case polygon([CanvasPoint])
    case tipStamp(CreativeShapeGeneratedTipStamp)
}

struct CreativeShapeGeneratedShape: Sendable, Equatable {
    var center: CanvasPoint
    var geometry: CreativeShapeGeneratedGeometry
    var color: RGBAColor
    var featherAmount: Float
}

struct CreativeShapeGeneratorPlan: Sendable, Equatable {
    var shapes: [CreativeShapeGeneratedShape]
    var tipMaterials: [CreativeShapeGeneratorTipMaterial]
    var seed: UInt64
    var bounds: CanvasRect
}

struct CreativeShapeGeneratorColorContext: Sendable, Equatable {
    var selectedColor: RGBAColor
    var brushOpacity: Float
    var brushNoise: Float
    var paletteColors: [RGBAColor]
}

private struct CreativeShapeGeneratorRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
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
        let width = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(nextUInt64() % width)
    }

    mutating func bool(probability: Float) -> Bool {
        float(in: 0...1) < probability
    }
}

private struct CreativeShapeFieldPrimitive {
    var start: CanvasPoint
    var end: CanvasPoint
    var startRadius: Double
    var endRadius: Double
}

enum CreativeShapeGeneratorEngine {
    static let maskResolution = 128

    static func makePlan(
        gesturePoints: [CanvasPoint],
        state: CreativeShapeGeneratorState,
        colorContext: CreativeShapeGeneratorColorContext,
        runtimeSeed: UInt64
    ) -> CreativeShapeGeneratorPlan? {
        guard state.isEnabled else { return nil }
        let sanitized = sanitizedGesturePoints(gesturePoints)
        guard sanitized.isEmpty == false else { return nil }

        var random = CreativeShapeGeneratorRandom(seed: runtimeSeed)
        let complexity = clamp(state.complexity, 0, 1)
        let tendency = clamp(state.formTendency, 0, 1)
        let openness = clamp(state.openness, 0, 1)
        let edgeCharacter = clamp(state.edgeCharacter, 0, 1)
        let surprise = clamp(state.surprise, 0, 1)

        let gestureLength = pathLength(sanitized)
        let rawBounds = CanvasRect.bounding(points: sanitized)
        let gestureScale = max(
            rawBounds.size.x,
            rawBounds.size.y,
            sqrt(max(gestureLength, 1)) * 5,
            24
        )
        let baseRadius = clamp(
            gestureScale * Double(lerp(0.22, 0.105, tendency)),
            7,
            72
        )
        let sampleCount = 9 + Int((complexity * 13).rounded())
        var skeleton = resampledPoints(sanitized, count: sampleCount)
        perturbSkeleton(
            &skeleton,
            radius: baseRadius,
            surprise: surprise,
            random: &random
        )

        var positive = makeMainPrimitives(
            skeleton: skeleton,
            baseRadius: baseRadius,
            tendency: tendency,
            surprise: surprise,
            random: &random
        )
        appendMasses(
            to: &positive,
            skeleton: skeleton,
            baseRadius: baseRadius,
            tendency: tendency,
            complexity: complexity,
            random: &random
        )
        appendBranches(
            to: &positive,
            skeleton: skeleton,
            baseRadius: baseRadius,
            tendency: tendency,
            complexity: complexity,
            surprise: surprise,
            random: &random
        )
        appendSatellites(
            to: &positive,
            skeleton: skeleton,
            baseRadius: baseRadius,
            complexity: complexity,
            surprise: surprise,
            random: &random
        )
        guard positive.isEmpty == false else { return nil }

        let negative = makeNegativePrimitives(
            skeleton: skeleton,
            baseRadius: baseRadius,
            openness: openness,
            complexity: complexity,
            edgeCharacter: edgeCharacter,
            surprise: surprise,
            random: &random
        )
        let bounds = fieldBounds(
            for: positive,
            edgePadding: baseRadius * Double(0.12 + (edgeCharacter * 0.28))
        )
        guard bounds.isEmpty == false else { return nil }

        let maskData = renderMask(
            positive: positive,
            negative: negative,
            bounds: bounds,
            edgeCharacter: edgeCharacter,
            seed: runtimeSeed
        )
        guard maskData.contains(where: { $0 > 0 }) else { return nil }

        let materialID = BrushTipImageAssetID(maskData: maskData)
        let color = resolvedColor(
            state: state,
            context: colorContext,
            random: &random
        )
        let center = CanvasPoint(
            x: bounds.origin.x + (bounds.size.x * 0.5),
            y: bounds.origin.y + (bounds.size.y * 0.5)
        )
        return CreativeShapeGeneratorPlan(
            shapes: [
                CreativeShapeGeneratedShape(
                    center: center,
                    geometry: .tipStamp(
                        CreativeShapeGeneratedTipStamp(
                            materialID: materialID,
                            size: bounds.size,
                            rotationDegrees: 0
                        )
                    ),
                    color: color,
                    featherAmount: 0
                )
            ],
            tipMaterials: [CreativeShapeGeneratorTipMaterial(id: materialID, maskData: maskData)],
            seed: runtimeSeed,
            bounds: bounds
        )
    }

    static func makePlan(
        selectionShape: SelectionShape,
        state: CreativeShapeGeneratorState,
        colorContext: CreativeShapeGeneratorColorContext,
        tipImageLibrary _: TipImageLibraryState = .empty,
        runtimeSeed: UInt64
    ) -> CreativeShapeGeneratorPlan? {
        makePlan(
            gesturePoints: selectionShape.pathPoints,
            state: state,
            colorContext: colorContext,
            runtimeSeed: runtimeSeed
        )
    }

    private static func sanitizedGesturePoints(_ points: [CanvasPoint]) -> [CanvasPoint] {
        guard let first = points.first else { return [] }
        var output = [first]
        output.reserveCapacity(min(points.count, 256))
        for point in points.dropFirst() {
            guard hypot(point.x - output[output.count - 1].x, point.y - output[output.count - 1].y) >= 0.5 else {
                continue
            }
            output.append(point)
        }
        if output.count == 1 {
            output.append(CanvasPoint(x: first.x + 0.01, y: first.y))
        }
        if output.count <= 256 { return output }
        return resampledPoints(output, count: 256)
    }

    private static func pathLength(_ points: [CanvasPoint]) -> Double {
        guard points.count > 1 else { return 0 }
        return zip(points, points.dropFirst()).reduce(0) { total, pair in
            total + hypot(pair.1.x - pair.0.x, pair.1.y - pair.0.y)
        }
    }

    private static func resampledPoints(_ points: [CanvasPoint], count: Int) -> [CanvasPoint] {
        guard let first = points.first else { return [] }
        guard points.count > 1, count > 1 else { return [first] }
        var cumulative = [0.0]
        cumulative.reserveCapacity(points.count)
        for index in 1..<points.count {
            cumulative.append(
                cumulative[index - 1] + hypot(
                    points[index].x - points[index - 1].x,
                    points[index].y - points[index - 1].y
                )
            )
        }
        guard let total = cumulative.last, total > 0.000_1 else { return [first] }

        var output: [CanvasPoint] = []
        output.reserveCapacity(count)
        var segmentIndex = 1
        for sampleIndex in 0..<count {
            let target = total * Double(sampleIndex) / Double(count - 1)
            while segmentIndex < cumulative.count - 1, cumulative[segmentIndex] < target {
                segmentIndex += 1
            }
            let lowerDistance = cumulative[segmentIndex - 1]
            let upperDistance = cumulative[segmentIndex]
            let progress = (target - lowerDistance) / max(upperDistance - lowerDistance, 0.000_1)
            let start = points[segmentIndex - 1]
            let end = points[segmentIndex]
            output.append(
                CanvasPoint(
                    x: start.x + ((end.x - start.x) * progress),
                    y: start.y + ((end.y - start.y) * progress)
                )
            )
        }
        return output
    }

    private static func perturbSkeleton(
        _ points: inout [CanvasPoint],
        radius: Double,
        surprise: Float,
        random: inout CreativeShapeGeneratorRandom
    ) {
        guard points.count > 2, surprise > 0.001 else { return }
        let phase = random.double(in: 0...(Double.pi * 2))
        for index in 1..<(points.count - 1) {
            let previous = points[index - 1]
            let next = points[index + 1]
            let tangentX = next.x - previous.x
            let tangentY = next.y - previous.y
            let length = max(hypot(tangentX, tangentY), 0.000_1)
            let progress = Double(index) / Double(points.count - 1)
            let envelope = sin(progress * Double.pi)
            let correlated = sin((progress * Double.pi * 3) + phase) * 0.55
            let randomPart = random.double(in: -0.45...0.45)
            let amount = radius * Double(surprise) * envelope * (correlated + randomPart)
            points[index] = CanvasPoint(
                x: points[index].x + ((-tangentY / length) * amount),
                y: points[index].y + ((tangentX / length) * amount)
            )
        }
    }

    private static func makeMainPrimitives(
        skeleton: [CanvasPoint],
        baseRadius: Double,
        tendency: Float,
        surprise: Float,
        random: inout CreativeShapeGeneratorRandom
    ) -> [CreativeShapeFieldPrimitive] {
        guard skeleton.count > 1 else { return [] }
        var output: [CreativeShapeFieldPrimitive] = []
        output.reserveCapacity(skeleton.count - 1)
        for index in 0..<(skeleton.count - 1) {
            let startProgress = Double(index) / Double(skeleton.count - 1)
            let endProgress = Double(index + 1) / Double(skeleton.count - 1)
            let taperPower = Double(lerp(0.20, 0.76, tendency))
            let endpointRadius = Double(lerp(0.24, 0.07, tendency))
            let startTaper = endpointRadius + ((1 - endpointRadius) * pow(max(sin(startProgress * Double.pi), 0.01), taperPower))
            let endTaper = endpointRadius + ((1 - endpointRadius) * pow(max(sin(endProgress * Double.pi), 0.01), taperPower))
            let variation = 1 + random.double(in: -0.16...0.16) * Double(surprise)
            output.append(
                CreativeShapeFieldPrimitive(
                    start: skeleton[index],
                    end: skeleton[index + 1],
                    startRadius: baseRadius * startTaper * variation,
                    endRadius: baseRadius * endTaper * variation
                )
            )
        }
        return output
    }

    private static func appendMasses(
        to primitives: inout [CreativeShapeFieldPrimitive],
        skeleton: [CanvasPoint],
        baseRadius: Double,
        tendency: Float,
        complexity: Float,
        random: inout CreativeShapeGeneratorRandom
    ) {
        let massAmount = 1 - tendency
        let count = 1 + Int((massAmount * (2 + (complexity * 3))).rounded())
        guard skeleton.isEmpty == false else { return }
        for _ in 0..<count {
            let index = random.int(in: 0...(skeleton.count - 1))
            let previous = skeleton[max(index - 1, 0)]
            let next = skeleton[min(index + 1, skeleton.count - 1)]
            let direction = normalizedDirection(from: previous, to: next)
            let side: Double = random.bool(probability: 0.5) ? 1 : -1
            let offset = baseRadius * random.double(in: 0.18...(0.48 + (Double(massAmount) * 0.62))) * side
            let center = CanvasPoint(
                x: skeleton[index].x - (direction.y * offset),
                y: skeleton[index].y + (direction.x * offset)
            )
            let angle = atan2(direction.y, direction.x) + random.double(in: -0.95...0.95)
            let halfLength = baseRadius * random.double(in: 0.45...(0.85 + (Double(massAmount) * 1.35)))
            let start = CanvasPoint(
                x: center.x - (cos(angle) * halfLength),
                y: center.y - (sin(angle) * halfLength)
            )
            let end = CanvasPoint(
                x: center.x + (cos(angle) * halfLength),
                y: center.y + (sin(angle) * halfLength)
            )
            let radius = baseRadius * random.double(in: 0.68...(0.92 + (Double(massAmount) * 0.58)))
            primitives.append(.init(
                start: start,
                end: end,
                startRadius: radius * random.double(in: 0.42...0.78),
                endRadius: radius
            ))
        }
    }

    private static func appendBranches(
        to primitives: inout [CreativeShapeFieldPrimitive],
        skeleton: [CanvasPoint],
        baseRadius: Double,
        tendency: Float,
        complexity: Float,
        surprise: Float,
        random: inout CreativeShapeGeneratorRandom
    ) {
        guard skeleton.count > 2 else { return }
        let branchCount = Int((complexity * (2.5 + (surprise * 3))).rounded())
        for _ in 0..<branchCount {
            let index = random.int(in: 1...(skeleton.count - 2))
            let origin = skeleton[index]
            let previous = skeleton[index - 1]
            let next = skeleton[index + 1]
            let baseAngle = atan2(next.y - previous.y, next.x - previous.x)
            let side: Double = random.bool(probability: 0.5) ? 1 : -1
            let branchAngle = baseAngle + side * random.double(in: 0.58...(0.94 + (Double(surprise) * 1.05)))
            let branchLength = baseRadius * random.double(in: 2.0...(3.6 + (Double(tendency) * 3.8)))
            let bend = random.double(in: -0.38...0.38) * Double(surprise)
            let middle = CanvasPoint(
                x: origin.x + (cos(branchAngle) * branchLength * 0.56),
                y: origin.y + (sin(branchAngle) * branchLength * 0.56)
            )
            let end = CanvasPoint(
                x: origin.x + (cos(branchAngle + bend) * branchLength),
                y: origin.y + (sin(branchAngle + bend) * branchLength)
            )
            let startRadius = baseRadius * random.double(in: 0.48...0.84)
            primitives.append(.init(
                start: origin,
                end: middle,
                startRadius: startRadius,
                endRadius: startRadius * 0.62
            ))
            primitives.append(.init(
                start: middle,
                end: end,
                startRadius: startRadius * 0.62,
                endRadius: startRadius * random.double(in: 0.06...0.20)
            ))
        }
    }

    private static func appendSatellites(
        to primitives: inout [CreativeShapeFieldPrimitive],
        skeleton: [CanvasPoint],
        baseRadius: Double,
        complexity: Float,
        surprise: Float,
        random: inout CreativeShapeGeneratorRandom
    ) {
        guard skeleton.count > 1, complexity > 0.2 else { return }
        let count = Int((complexity * (1.4 + (surprise * 2.6))).rounded())
        for _ in 0..<count {
            let index = random.int(in: 0...(skeleton.count - 1))
            let anchor = skeleton[index]
            let angle = random.double(in: 0...(Double.pi * 2))
            let distance = baseRadius * random.double(in: 1.1...(1.5 + (Double(surprise) * 1.8)))
            let center = CanvasPoint(
                x: anchor.x + (cos(angle) * distance),
                y: anchor.y + (sin(angle) * distance)
            )
            let lobeAngle = angle + random.double(in: -0.72...0.72)
            let halfLength = baseRadius * random.double(in: 0.24...0.68)
            let radius = baseRadius * random.double(in: 0.13...0.32)
            primitives.append(.init(
                start: CanvasPoint(
                    x: center.x - (cos(lobeAngle) * halfLength),
                    y: center.y - (sin(lobeAngle) * halfLength)
                ),
                end: CanvasPoint(
                    x: center.x + (cos(lobeAngle) * halfLength),
                    y: center.y + (sin(lobeAngle) * halfLength)
                ),
                startRadius: radius * 0.45,
                endRadius: radius
            ))
        }
    }

    private static func makeNegativePrimitives(
        skeleton: [CanvasPoint],
        baseRadius: Double,
        openness: Float,
        complexity: Float,
        edgeCharacter: Float,
        surprise: Float,
        random: inout CreativeShapeGeneratorRandom
    ) -> [CreativeShapeFieldPrimitive] {
        guard skeleton.count > 2, openness > 0.02 else { return [] }
        var output: [CreativeShapeFieldPrimitive] = []

        let holeCount = Int((openness * (1.2 + (complexity * 4.8))).rounded())
        for _ in 0..<holeCount {
            let index = random.int(in: 1...(skeleton.count - 2))
            let center = skeleton[index]
            let tangent = normalizedDirection(from: skeleton[index - 1], to: skeleton[index + 1])
            let offset = baseRadius * random.double(in: -0.22...0.22) * Double(surprise)
            let holeCenter = CanvasPoint(
                x: center.x + (-tangent.y * offset),
                y: center.y + (tangent.x * offset)
            )
            let radius = baseRadius * random.double(in: 0.18...(0.28 + (Double(openness) * 0.34)))
            let halfLength = radius * random.double(in: 0.18...(0.55 + (Double(openness) * 0.75)))
            output.append(.init(
                start: CanvasPoint(
                    x: holeCenter.x - (tangent.x * halfLength),
                    y: holeCenter.y - (tangent.y * halfLength)
                ),
                end: CanvasPoint(
                    x: holeCenter.x + (tangent.x * halfLength),
                    y: holeCenter.y + (tangent.y * halfLength)
                ),
                startRadius: radius * random.double(in: 0.55...0.88),
                endRadius: radius
            ))
        }

        let biteCount = Int(((openness * 2.4) + (edgeCharacter * 1.8)).rounded())
        for _ in 0..<biteCount {
            let index = random.int(in: 1...(skeleton.count - 2))
            let center = skeleton[index]
            let tangent = normalizedDirection(from: skeleton[index - 1], to: skeleton[index + 1])
            let side: Double = random.bool(probability: 0.5) ? 1 : -1
            let biteCenter = CanvasPoint(
                x: center.x + (-tangent.y * baseRadius * side * random.double(in: 0.72...1.02)),
                y: center.y + (tangent.x * baseRadius * side * random.double(in: 0.72...1.02))
            )
            let radius = baseRadius * random.double(in: 0.28...(0.42 + (Double(edgeCharacter) * 0.38)))
            let biteDirection = random.double(in: 0...(Double.pi * 2))
            let biteLength = radius * random.double(in: 0.2...0.9)
            output.append(.init(
                start: biteCenter,
                end: CanvasPoint(
                    x: biteCenter.x + (cos(biteDirection) * biteLength),
                    y: biteCenter.y + (sin(biteDirection) * biteLength)
                ),
                startRadius: radius,
                endRadius: radius * random.double(in: 0.42...0.78)
            ))
        }

        if openness > 0.48 {
            let crackCount = 1 + Int(((openness - 0.48) * 3.8).rounded())
            for _ in 0..<crackCount {
                let index = random.int(in: 1...(skeleton.count - 2))
                let center = skeleton[index]
                let tangent = normalizedDirection(from: skeleton[index - 1], to: skeleton[index + 1])
                let halfLength = baseRadius * random.double(in: 0.65...(1.05 + (Double(openness) * 0.65)))
                let start = CanvasPoint(
                    x: center.x - (tangent.y * halfLength),
                    y: center.y + (tangent.x * halfLength)
                )
                let end = CanvasPoint(
                    x: center.x + (tangent.y * halfLength),
                    y: center.y - (tangent.x * halfLength)
                )
                let radius = baseRadius * random.double(in: 0.055...(0.09 + (Double(edgeCharacter) * 0.09)))
                output.append(.init(start: start, end: end, startRadius: radius, endRadius: radius * 0.65))
            }
        }
        return output
    }

    private static func fieldBounds(
        for primitives: [CreativeShapeFieldPrimitive],
        edgePadding: Double
    ) -> CanvasRect {
        guard let first = primitives.first else {
            return CanvasRect(origin: .init(x: 0, y: 0), size: .init(x: 0, y: 0))
        }
        var minX = min(first.start.x - first.startRadius, first.end.x - first.endRadius)
        var minY = min(first.start.y - first.startRadius, first.end.y - first.endRadius)
        var maxX = max(first.start.x + first.startRadius, first.end.x + first.endRadius)
        var maxY = max(first.start.y + first.startRadius, first.end.y + first.endRadius)
        for primitive in primitives.dropFirst() {
            minX = min(minX, primitive.start.x - primitive.startRadius, primitive.end.x - primitive.endRadius)
            minY = min(minY, primitive.start.y - primitive.startRadius, primitive.end.y - primitive.endRadius)
            maxX = max(maxX, primitive.start.x + primitive.startRadius, primitive.end.x + primitive.endRadius)
            maxY = max(maxY, primitive.start.y + primitive.startRadius, primitive.end.y + primitive.endRadius)
        }
        let padding = max(edgePadding, 2)
        return CanvasRect(
            origin: CanvasPoint(x: minX - padding, y: minY - padding),
            size: CanvasPoint(x: max(maxX - minX + (padding * 2), 1), y: max(maxY - minY + (padding * 2), 1))
        )
    }

    private static func renderMask(
        positive: [CreativeShapeFieldPrimitive],
        negative: [CreativeShapeFieldPrimitive],
        bounds: CanvasRect,
        edgeCharacter: Float,
        seed: UInt64
    ) -> Data {
        var bytes = Data(count: maskResolution * maskResolution)
        let pixelScale = max(bounds.size.x, bounds.size.y) / Double(maskResolution)
        let antialiasWidth = max(pixelScale * 1.15, 0.7)
        let edgeAmplitude = pixelScale * Double(edgeCharacter) * 5.2

        bytes.withUnsafeMutableBytes { rawBuffer in
            guard let destination = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for y in 0..<maskResolution {
                for x in 0..<maskResolution {
                    let point = CanvasPoint(
                        x: bounds.minX + ((Double(x) + 0.5) / Double(maskResolution) * bounds.size.x),
                        y: bounds.minY + ((Double(y) + 0.5) / Double(maskResolution) * bounds.size.y)
                    )
                    var positiveDistance = -Double.infinity
                    for primitive in positive {
                        positiveDistance = max(positiveDistance, signedDistance(point, to: primitive))
                    }

                    if edgeCharacter > 0.001 {
                        let normalizedX = (Double(x) + 0.5) / Double(maskResolution)
                        let normalizedY = (Double(y) + 0.5) / Double(maskResolution)
                        let broad = valueNoise(x: normalizedX * 3.6, y: normalizedY * 3.6, seed: seed)
                        let medium = valueNoise(x: normalizedX * 9.5, y: normalizedY * 9.5, seed: seed &+ 0xA24B_AED4_963E_E407)
                        let fine = valueNoise(x: normalizedX * 23, y: normalizedY * 23, seed: seed &+ 0x9FB2_1C65_1E98_DF25)
                        positiveDistance += edgeAmplitude * ((broad * 0.54) + (medium * 0.32) + (fine * 0.14))
                    }

                    var finalDistance = positiveDistance
                    if negative.isEmpty == false {
                        var negativeDistance = -Double.infinity
                        for primitive in negative {
                            negativeDistance = max(negativeDistance, signedDistance(point, to: primitive))
                        }
                        finalDistance = min(finalDistance, -negativeDistance)
                    }
                    let alpha = smoothstep(-antialiasWidth, antialiasWidth, finalDistance)
                    destination[(y * maskResolution) + x] = UInt8(clamping: Int((alpha * 255).rounded()))
                }
            }
        }
        return bytes
    }

    private static func signedDistance(
        _ point: CanvasPoint,
        to primitive: CreativeShapeFieldPrimitive
    ) -> Double {
        let dx = primitive.end.x - primitive.start.x
        let dy = primitive.end.y - primitive.start.y
        let lengthSquared = (dx * dx) + (dy * dy)
        let progress: Double
        if lengthSquared <= 0.000_001 {
            progress = 0
        } else {
            progress = clamp(
                (((point.x - primitive.start.x) * dx) + ((point.y - primitive.start.y) * dy)) / lengthSquared,
                0,
                1
            )
        }
        let nearest = CanvasPoint(
            x: primitive.start.x + (dx * progress),
            y: primitive.start.y + (dy * progress)
        )
        let radius = primitive.startRadius + ((primitive.endRadius - primitive.startRadius) * progress)
        return radius - hypot(point.x - nearest.x, point.y - nearest.y)
    }

    private static func normalizedDirection(from start: CanvasPoint, to end: CanvasPoint) -> CanvasPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(hypot(dx, dy), 0.000_1)
        return CanvasPoint(x: dx / length, y: dy / length)
    }

    private static func valueNoise(x: Double, y: Double, seed: UInt64) -> Double {
        let x0 = Int(floor(x))
        let y0 = Int(floor(y))
        let tx = smoothFraction(x - Double(x0))
        let ty = smoothFraction(y - Double(y0))
        let top = mix(hashNoise(x: x0, y: y0, seed: seed), hashNoise(x: x0 + 1, y: y0, seed: seed), tx)
        let bottom = mix(hashNoise(x: x0, y: y0 + 1, seed: seed), hashNoise(x: x0 + 1, y: y0 + 1, seed: seed), tx)
        return mix(top, bottom, ty)
    }

    private static func hashNoise(x: Int, y: Int, seed: UInt64) -> Double {
        var value = seed
        value ^= UInt64(bitPattern: Int64(x)) &* 0x9E37_79B9_7F4A_7C15
        value ^= UInt64(bitPattern: Int64(y)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return (Double(value & 0x001F_FFFF_FFFF_FFFF) / Double(0x001F_FFFF_FFFF_FFFF) * 2) - 1
    }

    private static func resolvedColor(
        state: CreativeShapeGeneratorState,
        context: CreativeShapeGeneratorColorContext,
        random: inout CreativeShapeGeneratorRandom
    ) -> RGBAColor {
        let base: RGBAColor
        switch state.selectedSource {
        case .paletteBlocks:
            let colors = context.paletteColors.filter { $0.alpha > 0.02 }
            base = colors.isEmpty
                ? context.selectedColor
                : colors[random.int(in: 0...(colors.count - 1))]
        case .externalImage:
            base = sampledImageColor(from: state.importedImage, fallback: context.selectedColor, random: &random)
        case .currentColor, .none:
            base = context.selectedColor
        }

        let variation = min(max(context.brushNoise, 0), 1) * 0.35 + (state.surprise * 0.08)
        var hsv = ColorBlocksEngine.rgbToHsv(base)
        hsv.h += random.float(in: -18...18) * variation
        hsv.s = clamp(hsv.s + random.float(in: -0.08...0.08) * variation, 0, 1)
        hsv.v = clamp(hsv.v + random.float(in: -0.08...0.08) * variation, 0, 1)
        return ColorBlocksEngine.hsvToRgb(
            hsv,
            alpha: clamp(base.alpha * context.brushOpacity, 0, 1)
        )
    }

    private static func sampledImageColor(
        from source: CreativeShapeGeneratorImageSource?,
        fallback: RGBAColor,
        random: inout CreativeShapeGeneratorRandom
    ) -> RGBAColor {
        guard let source, source.isValid else { return fallback }
        let bytes = [UInt8](source.rgbaPixels)
        for _ in 0..<48 {
            let pixelIndex = random.int(in: 0...((source.width * source.height) - 1))
            let byteIndex = pixelIndex * 4
            let alpha = Float(bytes[byteIndex + 3]) / 255
            guard alpha > 0.05 else { continue }
            return RGBAColor(
                red: clamp((Float(bytes[byteIndex]) / 255) / alpha, 0, 1),
                green: clamp((Float(bytes[byteIndex + 1]) / 255) / alpha, 0, 1),
                blue: clamp((Float(bytes[byteIndex + 2]) / 255) / alpha, 0, 1),
                alpha: 1
            )
        }
        return fallback
    }

    private static func smoothFraction(_ value: Double) -> Double {
        value * value * (3 - (2 * value))
    }

    private static func smoothstep(_ minimum: Double, _ maximum: Double, _ value: Double) -> Double {
        let normalized = clamp((value - minimum) / max(maximum - minimum, 0.000_1), 0, 1)
        return normalized * normalized * (3 - (2 * normalized))
    }

    private static func mix(_ lhs: Double, _ rhs: Double, _ amount: Double) -> Double {
        lhs + ((rhs - lhs) * amount)
    }

    private static func lerp(_ lhs: Float, _ rhs: Float, _ amount: Float) -> Float {
        lhs + ((rhs - lhs) * clamp(amount, 0, 1))
    }

    private static func clamp<T: Comparable>(_ value: T, _ minimum: T, _ maximum: T) -> T {
        min(max(value, minimum), maximum)
    }
}

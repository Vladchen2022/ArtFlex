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

private enum CreativeShapeRole {
    case dominant
    case secondary
    case accent
}

private struct CreativeShapeCompositionAxis {
    var center: CanvasPoint
    var major: CanvasPoint
    var minor: CanvasPoint
    var angle: Double
    var majorSpan: Double
    var minorSpan: Double
}

private struct CreativeShapeColorRoles {
    var dominant: RGBAColor
    var secondary: RGBAColor
    var accent: RGBAColor
}

enum CreativeShapeGeneratorEngine {
    private static let attemptCount = 5
    private static let attemptSeedStride: UInt64 = 0x9E37_79B9_7F4A_7C15

    static func makePlan(
        selectionShape: SelectionShape,
        state: CreativeShapeGeneratorState,
        colorContext: CreativeShapeGeneratorColorContext,
        tipImageLibrary _: TipImageLibraryState = .empty,
        runtimeSeed: UInt64
    ) -> CreativeShapeGeneratorPlan? {
        guard state.isEnabled else { return nil }
        let selection = selectionShape
        guard selection.isEmpty == false, selection.bounds.isEmpty == false else { return nil }

        var bestPlan: CreativeShapeGeneratorPlan?
        var bestScore = -Double.infinity
        for attempt in 0..<attemptCount {
            let seed = runtimeSeed &+ (UInt64(attempt) &* attemptSeedStride)
            var random = CreativeShapeGeneratorRandom(seed: seed)
            guard let plan = buildPlan(
                selection: selection,
                state: state,
                colorContext: colorContext,
                seed: seed,
                random: &random
            ) else {
                continue
            }
            let score = compositionScore(plan: plan, state: state)
            if score > bestScore {
                bestScore = score
                bestPlan = plan
            }
        }
        return bestPlan
    }

    private static func buildPlan(
        selection: SelectionShape,
        state: CreativeShapeGeneratorState,
        colorContext: CreativeShapeGeneratorColorContext,
        seed: UInt64,
        random: inout CreativeShapeGeneratorRandom
    ) -> CreativeShapeGeneratorPlan? {
        guard let axis = compositionAxis(for: selection) else { return nil }
        let complexity = clamp(state.complexity, 0, 1)
        let coherence = clamp(state.coherence, 0, 1)
        let formElongation = clamp(state.formElongation, 0, 1)
        let edgeTexture = clamp(state.edgeTexture, 0, 1)
        let shapeCount = 5 + Int((complexity * 13).rounded())
        let colorRoles = resolvedColorRoles(for: state, context: colorContext, random: &random)
        let phase = random.double(in: 0...(Double.pi * 2))

        var shapes: [CreativeShapeGeneratedShape] = []
        shapes.reserveCapacity(shapeCount)

        for index in 0..<shapeCount {
            let role = resolvedRole(index: index, count: shapeCount, mode: state.structureMode)
            let skeleton = skeletonPoint(
                index: index,
                count: shapeCount,
                role: role,
                mode: state.structureMode,
                axis: axis,
                coherence: coherence,
                phase: phase,
                random: &random
            )
            let center = resolvedInteriorCenter(
                target: skeleton,
                axis: axis,
                selection: selection,
                coherence: coherence,
                random: &random
            )
            let diameter = resolvedDiameter(
                role: role,
                mode: state.structureMode,
                shortestSide: min(axis.majorSpan, axis.minorSpan),
                complexity: complexity,
                random: &random
            )
            let orientation = resolvedOrientation(
                center: center,
                mode: state.structureMode,
                axis: axis,
                coherence: coherence,
                phase: phase,
                random: &random
            )
            let aspect = resolvedAspect(
                role: role,
                mode: state.structureMode,
                coherence: coherence,
                formElongation: formElongation,
                random: &random
            )
            let boundary = organicPolygon(
                index: index,
                role: role,
                mode: state.structureMode,
                center: center,
                diameter: diameter,
                aspect: aspect,
                orientation: orientation,
                complexity: complexity,
                formElongation: formElongation,
                edgeTexture: edgeTexture,
                selection: selection,
                random: &random
            )
            guard boundary.count >= 3 else { continue }

            let color = resolvedShapeColor(
                role: role,
                index: index,
                roles: colorRoles,
                opacity: colorContext.brushOpacity,
                edgeTexture: edgeTexture,
                random: &random
            )
            let featherAmount = resolvedFeatherAmount(
                role: role,
                edgeTexture: edgeTexture,
                random: &random
            )
            shapes.append(
                CreativeShapeGeneratedShape(
                    center: center,
                    geometry: .polygon(boundary),
                    color: color,
                    featherAmount: featherAmount
                )
            )
        }

        guard shapes.isEmpty == false else { return nil }
        return CreativeShapeGeneratorPlan(
            shapes: orderedForRendering(shapes, mode: state.structureMode),
            tipMaterials: [],
            seed: seed,
            bounds: selection.bounds
        )
    }

    private static func resolvedRole(
        index: Int,
        count: Int,
        mode: CreativeShapeStructureMode
    ) -> CreativeShapeRole {
        if index == 0 || (mode == .fracture && index == 1) {
            return .dominant
        }
        let accentStart = max(2, Int((Float(count) * 0.72).rounded(.down)))
        return index >= accentStart ? .accent : .secondary
    }

    private static func compositionAxis(for selection: SelectionShape) -> CreativeShapeCompositionAxis? {
        let bounds = selection.bounds
        guard bounds.isEmpty == false else { return nil }
        let boundsCenter = CanvasPoint(
            x: bounds.origin.x + (bounds.size.x * 0.5),
            y: bounds.origin.y + (bounds.size.y * 0.5)
        )
        let center = interiorCentroid(for: selection) ?? firstInteriorGridPoint(in: selection) ?? boundsCenter
        let points = selection.pathPoints.isEmpty ? boundsCorners(bounds) : selection.pathPoints

        var covarianceXX = 0.0
        var covarianceYY = 0.0
        var covarianceXY = 0.0
        for point in points {
            let dx = point.x - center.x
            let dy = point.y - center.y
            covarianceXX += dx * dx
            covarianceYY += dy * dy
            covarianceXY += dx * dy
        }

        let angle: Double
        if abs(covarianceXX - covarianceYY) + abs(covarianceXY) < 0.0001 {
            angle = bounds.size.x >= bounds.size.y ? 0 : Double.pi * 0.5
        } else {
            angle = 0.5 * atan2(2 * covarianceXY, covarianceXX - covarianceYY)
        }
        let major = CanvasPoint(x: cos(angle), y: sin(angle))
        let minor = CanvasPoint(x: -sin(angle), y: cos(angle))
        return CreativeShapeCompositionAxis(
            center: center,
            major: major,
            minor: minor,
            angle: angle,
            majorSpan: max(bounds.size.x, bounds.size.y),
            minorSpan: max(min(bounds.size.x, bounds.size.y), 1)
        )
    }

    private static func skeletonPoint(
        index: Int,
        count: Int,
        role: CreativeShapeRole,
        mode: CreativeShapeStructureMode,
        axis: CreativeShapeCompositionAxis,
        coherence: Float,
        phase: Double,
        random: inout CreativeShapeGeneratorRandom
    ) -> CanvasPoint {
        let progress = count > 1 ? Double(index) / Double(count - 1) : 0.5
        let looseness = Double(1 - coherence)
        var majorOffset = 0.0
        var minorOffset = 0.0

        switch mode {
        case .cluster:
            if index > 0 {
                let goldenAngle = Double(index) * 2.399_963_229_728_653
                let radius = axis.minorSpan * (0.08 + (0.26 * sqrt(progress)))
                majorOffset = cos(goldenAngle + phase) * radius
                minorOffset = sin(goldenAngle + phase) * radius
            }
        case .growth:
            let growthProgress = index > 0 && count > 2
                ? Double(index - 1) / Double(count - 2)
                : 0
            majorOffset = (index == 0 ? -0.12 : (-0.06 + (growthProgress * 0.40))) * axis.majorSpan
            minorOffset = sin((progress * Double.pi * 2.4) + phase) * axis.minorSpan * (0.05 + (0.10 * looseness))
            if role == .accent {
                minorOffset += random.double(in: -0.12...0.12) * axis.minorSpan
            }
        case .flow:
            majorOffset = (-0.30 + (progress * 0.60)) * axis.majorSpan
            minorOffset = sin((progress * Double.pi * 2.0) + phase) * axis.minorSpan * (0.14 + (0.08 * looseness))
        case .fracture:
            let group = index % 3
            let groupOffsets = [-0.22, 0.02, 0.23]
            majorOffset = groupOffsets[group] * axis.majorSpan
            let localAngle = random.double(in: 0...(Double.pi * 2))
            let localRadius = axis.minorSpan * random.double(in: 0.03...(0.10 + (0.10 * looseness)))
            majorOffset += cos(localAngle) * localRadius
            minorOffset = sin(localAngle) * localRadius
        }

        return offset(axis.center, major: axis.major, majorAmount: majorOffset, minor: axis.minor, minorAmount: minorOffset)
    }

    private static func resolvedInteriorCenter(
        target: CanvasPoint,
        axis: CreativeShapeCompositionAxis,
        selection: SelectionShape,
        coherence: Float,
        random: inout CreativeShapeGeneratorRandom
    ) -> CanvasPoint {
        var resolvedTarget = constrainedPoint(target, from: axis.center, inside: selection)
        let randomBlend = Double(1 - coherence) * 0.42
        if randomBlend > 0.001, let randomPoint = randomInteriorPoint(in: selection, random: &random) {
            resolvedTarget = CanvasPoint(
                x: resolvedTarget.x + ((randomPoint.x - resolvedTarget.x) * randomBlend),
                y: resolvedTarget.y + ((randomPoint.y - resolvedTarget.y) * randomBlend)
            )
            resolvedTarget = constrainedPoint(resolvedTarget, from: axis.center, inside: selection)
        }
        return resolvedTarget
    }

    private static func resolvedDiameter(
        role: CreativeShapeRole,
        mode: CreativeShapeStructureMode,
        shortestSide: Double,
        complexity: Float,
        random: inout CreativeShapeGeneratorRandom
    ) -> Double {
        let complexityScale = Double(lerp(1.08, 0.80, complexity))
        let range: ClosedRange<Double>
        switch role {
        case .dominant:
            range = mode == .fracture ? 0.22...0.34 : 0.30...0.42
        case .secondary:
            range = 0.14...0.27
        case .accent:
            range = 0.05...0.12
        }
        return max(shortestSide * random.double(in: range) * complexityScale, 2)
    }

    private static func resolvedOrientation(
        center: CanvasPoint,
        mode: CreativeShapeStructureMode,
        axis: CreativeShapeCompositionAxis,
        coherence: Float,
        phase: Double,
        random: inout CreativeShapeGeneratorRandom
    ) -> Double {
        let deviation = Double(1 - coherence) * Double.pi * 0.62
        let base: Double
        switch mode {
        case .cluster:
            base = atan2(center.y - axis.center.y, center.x - axis.center.x)
        case .growth, .fracture:
            base = axis.angle
        case .flow:
            let relative = ((center.x - axis.center.x) * axis.major.x) + ((center.y - axis.center.y) * axis.major.y)
            let normalized = relative / max(axis.majorSpan, 1)
            let slope = cos((normalized + 0.5) * Double.pi * 2 + phase) * 0.42
            base = axis.angle + atan(slope)
        }
        return base + random.double(in: -deviation...deviation)
    }

    private static func resolvedAspect(
        role: CreativeShapeRole,
        mode: CreativeShapeStructureMode,
        coherence: Float,
        formElongation: Float,
        random: inout CreativeShapeGeneratorRandom
    ) -> Double {
        let baseRange: ClosedRange<Double>
        switch mode {
        case .cluster:
            baseRange = 1.10...2.15
        case .growth:
            baseRange = 1.30...3.40
        case .flow:
            baseRange = 1.55...4.20
        case .fracture:
            baseRange = 1.35...3.60
        }
        let roleScale: Double = role == .accent ? 0.82 : 1
        let randomAspect = random.double(in: baseRange) * roleScale
        let extensionAmount = Double(0.18 + (formElongation * 0.82))
        return 1 + ((randomAspect - 1) * extensionAmount * Double(0.68 + (coherence * 0.32)))
    }

    private static func organicPolygon(
        index: Int,
        role: CreativeShapeRole,
        mode: CreativeShapeStructureMode,
        center: CanvasPoint,
        diameter: Double,
        aspect: Double,
        orientation: Double,
        complexity: Float,
        formElongation: Float,
        edgeTexture: Float,
        selection: SelectionShape,
        random: inout CreativeShapeGeneratorRandom
    ) -> [CanvasPoint] {
        let ribbonProbability: Float
        switch mode {
        case .cluster:
            ribbonProbability = formElongation * 0.18
        case .growth:
            ribbonProbability = 0.12 + (formElongation * 0.58)
        case .flow:
            ribbonProbability = 0.24 + (formElongation * 0.68)
        case .fracture:
            ribbonProbability = 0.18 + (formElongation * 0.52)
        }
        let shouldUseRibbon = role != .accent && (
            (index == 0 && mode != .cluster && formElongation >= 0.35) ||
            random.bool(probability: ribbonProbability)
        )
        if shouldUseRibbon {
            return organicRibbonPolygon(
                center: center,
                diameter: diameter,
                aspect: aspect,
                orientation: orientation,
                complexity: complexity,
                edgeTexture: edgeTexture,
                selection: selection,
                random: &random
            )
        }

        return organicBlobPolygon(
            center: center,
            diameter: diameter,
            aspect: aspect,
            orientation: orientation,
            complexity: complexity,
            edgeTexture: edgeTexture,
            selection: selection,
            random: &random
        )
    }

    private static func organicBlobPolygon(
        center: CanvasPoint,
        diameter: Double,
        aspect: Double,
        orientation: Double,
        complexity: Float,
        edgeTexture: Float,
        selection: SelectionShape,
        random: inout CreativeShapeGeneratorRandom
    ) -> [CanvasPoint] {
        let controlPointCount = 10 + Int((complexity * 6).rounded()) + Int((edgeTexture * 5).rounded())
        let majorRadius = diameter * 0.5 * aspect
        let minorRadius = diameter * 0.5 * Double(lerp(0.96, 0.62, Float(min((aspect - 1) / 1.7, 1))))
        let phaseA = random.double(in: 0...(Double.pi * 2))
        let phaseB = random.double(in: 0...(Double.pi * 2))
        let lobeAmplitude = Double(lerp(0.025, 0.17, edgeTexture))
        let roughAmplitude = Double(lerp(0.008, 0.14, edgeTexture))
        let cosine = cos(orientation)
        let sine = sin(orientation)

        var pinches: [(angle: Double, width: Double, depth: Double)] = []
        for _ in 0..<(1 + Int((edgeTexture * 2).rounded())) {
            pinches.append((
                angle: random.double(in: 0...(Double.pi * 2)),
                width: random.double(in: 0.28...0.72),
                depth: random.double(in: 0.10...(0.16 + (Double(edgeTexture) * 0.34)))
            ))
        }
        var protrusions: [(angle: Double, width: Double, height: Double)] = []
        for _ in 0..<(1 + Int((edgeTexture * 1.5).rounded())) {
            protrusions.append((
                angle: random.double(in: 0...(Double.pi * 2)),
                width: random.double(in: 0.24...0.62),
                height: random.double(in: 0.08...(0.14 + (Double(edgeTexture) * 0.28)))
            ))
        }

        var controls: [CanvasPoint] = []
        controls.reserveCapacity(controlPointCount)
        for index in 0..<controlPointCount {
            let angle = (Double(index) / Double(controlPointCount)) * Double.pi * 2
            let correlated =
                sin((angle * 2) + phaseA) * lobeAmplitude +
                sin((angle * 3) + phaseB) * lobeAmplitude * 0.55
            let rough = random.double(in: -roughAmplitude...roughAmplitude)
            var featureScale = 0.0
            for pinch in pinches {
                let influence = featureInfluence(angle: angle, center: pinch.angle, width: pinch.width)
                featureScale -= influence * pinch.depth
            }
            for protrusion in protrusions {
                let influence = featureInfluence(angle: angle, center: protrusion.angle, width: protrusion.width)
                featureScale += influence * protrusion.height
            }
            let radiusScale = max(0.38, 1 + correlated + rough + featureScale)
            let localX = cos(angle) * majorRadius * radiusScale
            let localY = sin(angle) * minorRadius * radiusScale
            let candidate = CanvasPoint(
                x: center.x + (localX * cosine) - (localY * sine),
                y: center.y + (localX * sine) + (localY * cosine)
            )
            controls.append(constrainedPoint(candidate, from: center, inside: selection))
        }

        let samplesPerSegment = edgeTexture > 0.76 ? 1 : (edgeTexture > 0.38 ? 2 : 3)
        var smoothed: [CanvasPoint] = []
        smoothed.reserveCapacity(controlPointCount * samplesPerSegment)
        for index in 0..<controlPointCount {
            let p0 = controls[(index - 1 + controlPointCount) % controlPointCount]
            let p1 = controls[index]
            let p2 = controls[(index + 1) % controlPointCount]
            let p3 = controls[(index + 2) % controlPointCount]
            for sample in 0..<samplesPerSegment {
                let t = Double(sample) / Double(samplesPerSegment)
                let point = catmullRom(p0: p0, p1: p1, p2: p2, p3: p3, t: t)
                smoothed.append(constrainedPoint(point, from: center, inside: selection))
            }
        }
        return smoothed
    }

    private static func organicRibbonPolygon(
        center: CanvasPoint,
        diameter: Double,
        aspect: Double,
        orientation: Double,
        complexity: Float,
        edgeTexture: Float,
        selection: SelectionShape,
        random: inout CreativeShapeGeneratorRandom
    ) -> [CanvasPoint] {
        let pointCount = 7 + Int((complexity * 3).rounded()) + Int((edgeTexture * 3).rounded())
        let halfLength = diameter * 0.46 * aspect
        let baseHalfWidth = diameter * Double(lerp(0.22, 0.34, 1 - edgeTexture))
        let bend = diameter * random.double(in: 0.10...(0.18 + (Double(edgeTexture) * 0.30)))
            * (random.bool(probability: 0.5) ? 1 : -1)
        let wave = diameter * random.double(in: 0.02...(0.05 + (Double(edgeTexture) * 0.12)))
        let wavePhase = random.double(in: 0...(Double.pi * 2))
        let widthPhase = random.double(in: 0...(Double.pi * 2))
        let cosine = cos(orientation)
        let sine = sin(orientation)

        var centerline: [CanvasPoint] = []
        centerline.reserveCapacity(pointCount)
        for index in 0..<pointCount {
            let progress = Double(index) / Double(pointCount - 1)
            let localX = (-halfLength) + (progress * halfLength * 2)
            let localY = sin((progress - 0.5) * Double.pi) * bend
                + sin((progress * Double.pi * 2) + wavePhase) * wave
            let candidate = CanvasPoint(
                x: center.x + (localX * cosine) - (localY * sine),
                y: center.y + (localX * sine) + (localY * cosine)
            )
            centerline.append(constrainedPoint(candidate, from: center, inside: selection))
        }

        var left: [CanvasPoint] = []
        var right: [CanvasPoint] = []
        left.reserveCapacity(pointCount)
        right.reserveCapacity(pointCount)
        for index in centerline.indices {
            let previous = centerline[max(index - 1, 0)]
            let next = centerline[min(index + 1, centerline.count - 1)]
            let tangentX = next.x - previous.x
            let tangentY = next.y - previous.y
            let tangentLength = max(hypot(tangentX, tangentY), 0.000_1)
            let normalX = -tangentY / tangentLength
            let normalY = tangentX / tangentLength
            let progress = Double(index) / Double(pointCount - 1)
            let taper = 0.18 + (0.82 * pow(sin(progress * Double.pi), 0.62))
            let correlatedWidth = 1 + (sin((progress * Double.pi * 4) + widthPhase) * Double(edgeTexture) * 0.22)
            let notch = random.double(in: -(Double(edgeTexture) * 0.18)...(Double(edgeTexture) * 0.13))
            let halfWidth = max(baseHalfWidth * taper * correlatedWidth * (1 + notch), diameter * 0.035)
            let centerPoint = centerline[index]
            let leftCandidate = CanvasPoint(
                x: centerPoint.x + (normalX * halfWidth),
                y: centerPoint.y + (normalY * halfWidth)
            )
            let rightCandidate = CanvasPoint(
                x: centerPoint.x - (normalX * halfWidth),
                y: centerPoint.y - (normalY * halfWidth)
            )
            left.append(constrainedPoint(leftCandidate, from: centerPoint, inside: selection))
            right.append(constrainedPoint(rightCandidate, from: centerPoint, inside: selection))
        }

        return left + right.reversed()
    }

    private static func featureInfluence(angle: Double, center: Double, width: Double) -> Double {
        let rawDistance = abs(angle - center).truncatingRemainder(dividingBy: Double.pi * 2)
        let distance = min(rawDistance, (Double.pi * 2) - rawDistance)
        let normalized = max(0, 1 - (distance / max(width, 0.000_1)))
        return normalized * normalized * (3 - (2 * normalized))
    }

    private static func resolvedColorRoles(
        for state: CreativeShapeGeneratorState,
        context: CreativeShapeGeneratorColorContext,
        random: inout CreativeShapeGeneratorRandom
    ) -> CreativeShapeColorRoles {
        switch state.selectedSource {
        case .paletteBlocks:
            return paletteBlockRoles(colors: context.paletteColors, fallback: context.selectedColor, random: &random)
        case .externalImage:
            let colors = dominantImageColors(from: state.importedImage)
            return paletteBlockRoles(colors: colors, fallback: context.selectedColor, random: &random)
        case .currentColor, .none:
            let base = context.selectedColor.withAlpha(1)
            return CreativeShapeColorRoles(
                dominant: base,
                secondary: shiftedColor(base, hue: random.float(in: -22 ... -10), saturation: 0.05, value: -0.09),
                accent: shiftedColor(base, hue: random.float(in: 138...178), saturation: -0.08, value: 0.06)
            )
        }
    }

    private static func paletteBlockRoles(
        colors: [RGBAColor],
        fallback: RGBAColor,
        random: inout CreativeShapeGeneratorRandom
    ) -> CreativeShapeColorRoles {
        let palette = colors.filter { $0.alpha > 0.01 }
        guard palette.isEmpty == false else {
            let base = fallback.withAlpha(1)
            return CreativeShapeColorRoles(
                dominant: base,
                secondary: shiftedColor(base, hue: -16, saturation: 0.04, value: -0.08),
                accent: shiftedColor(base, hue: 155, saturation: -0.06, value: 0.05)
            )
        }

        let dominant = palette[random.int(in: 0...(palette.count - 1))].withAlpha(1)
        let dominantHSV = ColorBlocksEngine.rgbToHsv(dominant)
        let ranked = palette
            .map { color -> (RGBAColor, Float) in
                let hsv = ColorBlocksEngine.rgbToHsv(color)
                return (color.withAlpha(1), hueDistance(dominantHSV.h, hsv.h))
            }
            .sorted { $0.1 < $1.1 }
        let secondary = ranked.first(where: { $0.1 > 8 })?.0
            ?? shiftedColor(dominant, hue: -18, saturation: 0.03, value: -0.10)
        let accent = ranked.last(where: { $0.1 > 45 })?.0
            ?? shiftedColor(dominant, hue: 160, saturation: -0.05, value: 0.08)
        return CreativeShapeColorRoles(dominant: dominant, secondary: secondary, accent: accent)
    }

    private static func resolvedShapeColor(
        role: CreativeShapeRole,
        index: Int,
        roles: CreativeShapeColorRoles,
        opacity: Float,
        edgeTexture: Float,
        random: inout CreativeShapeGeneratorRandom
    ) -> RGBAColor {
        let base: RGBAColor
        switch role {
        case .dominant:
            base = roles.dominant
        case .secondary:
            base = index.isMultiple(of: 3) ? roles.dominant : roles.secondary
        case .accent:
            base = index.isMultiple(of: 2) ? roles.accent : roles.secondary
        }
        let hueRange = lerp(2, 9, edgeTexture)
        let valueRange = lerp(0.015, 0.075, edgeTexture)
        let varied = shiftedColor(
            base,
            hue: random.float(in: -hueRange...hueRange),
            saturation: random.float(in: -0.035...0.035),
            value: random.float(in: -valueRange...valueRange)
        )
        return varied.withAlpha(clamp(base.alpha * opacity, 0, 1))
    }

    private static func resolvedFeatherAmount(
        role: CreativeShapeRole,
        edgeTexture: Float,
        random: inout CreativeShapeGeneratorRandom
    ) -> Float {
        let probability = lerp(0.06, 0.48, edgeTexture)
        guard random.bool(probability: probability) else { return 0 }
        let roleScale: Float = role == .dominant ? 0.78 : 1
        return random.float(in: 0.06...lerp(0.10, 0.30, edgeTexture)) * roleScale
    }

    private static func dominantImageColors(from source: CreativeShapeGeneratorImageSource?) -> [RGBAColor] {
        guard let source, source.isValid else { return [] }
        let bytes = [UInt8](source.rgbaPixels)
        let binCount = 5 * 5 * 5
        var counts = [Int](repeating: 0, count: binCount)
        var redSums = [Float](repeating: 0, count: binCount)
        var greenSums = [Float](repeating: 0, count: binCount)
        var blueSums = [Float](repeating: 0, count: binCount)

        for index in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = Float(bytes[index + 3]) / 255
            guard alpha > 0.05 else { continue }
            let red = clamp((Float(bytes[index]) / 255) / alpha, 0, 1)
            let green = clamp((Float(bytes[index + 1]) / 255) / alpha, 0, 1)
            let blue = clamp((Float(bytes[index + 2]) / 255) / alpha, 0, 1)
            let r = min(Int(red * 5), 4)
            let g = min(Int(green * 5), 4)
            let b = min(Int(blue * 5), 4)
            let bin = (r * 25) + (g * 5) + b
            counts[bin] += 1
            redSums[bin] += red
            greenSums[bin] += green
            blueSums[bin] += blue
        }

        return counts.indices
            .filter { counts[$0] > 0 }
            .sorted { counts[$0] > counts[$1] }
            .prefix(6)
            .map { bin in
                let count = Float(counts[bin])
                return RGBAColor(
                    red: redSums[bin] / count,
                    green: greenSums[bin] / count,
                    blue: blueSums[bin] / count,
                    alpha: 1
                )
            }
    }

    private static func shiftedColor(
        _ color: RGBAColor,
        hue: Float,
        saturation: Float,
        value: Float
    ) -> RGBAColor {
        var hsv = ColorBlocksEngine.rgbToHsv(color)
        hsv.h = ColorBlocksEngine.wrapHue(hsv.h + hue)
        hsv.s = clamp(hsv.s + saturation, 0, 1)
        hsv.v = clamp(hsv.v + value, 0, 1)
        return ColorBlocksEngine.hsvToRgb(hsv, alpha: color.alpha)
    }

    private static func hueDistance(_ lhs: Float, _ rhs: Float) -> Float {
        let distance = abs(lhs - rhs).truncatingRemainder(dividingBy: 360)
        return min(distance, 360 - distance)
    }

    private static func orderedForRendering(
        _ shapes: [CreativeShapeGeneratedShape],
        mode: CreativeShapeStructureMode
    ) -> [CreativeShapeGeneratedShape] {
        guard mode != .fracture else { return shapes }
        return shapes.reversed()
    }

    private static func compositionScore(
        plan: CreativeShapeGeneratorPlan,
        state: CreativeShapeGeneratorState
    ) -> Double {
        let areas = plan.shapes.compactMap { shape -> Double? in
            guard case .polygon(let points) = shape.geometry else { return nil }
            return abs(polygonArea(points))
        }
        guard let largest = areas.max(), areas.isEmpty == false else { return -Double.infinity }
        let total = areas.reduce(0, +)
        let boundsArea = max(plan.bounds.size.x * plan.bounds.size.y, 1)
        let coverage = min(total / boundsArea, 1.5)
        let targetCoverage = 0.33 + (Double(state.complexity) * 0.18)
        let dominance = largest / max(total, 1)
        let targetDominance = state.structureMode == .fracture ? 0.28 : 0.40
        let connectedness = centerConnectedness(shapes: plan.shapes, bounds: plan.bounds)
        let targetConnectedness = 0.45 + (Double(state.coherence) * 0.45)
        return
            2.2 -
            (abs(coverage - targetCoverage) * 2.1) -
            (abs(dominance - targetDominance) * 1.5) -
            (abs(connectedness - targetConnectedness) * 1.2)
    }

    private static func centerConnectedness(
        shapes: [CreativeShapeGeneratedShape],
        bounds: CanvasRect
    ) -> Double {
        guard shapes.count > 1 else { return 1 }
        let scale = max(min(bounds.size.x, bounds.size.y), 1)
        var score = 0.0
        for index in 1..<shapes.count {
            let point = shapes[index].center
            let nearest = shapes[..<index].map { previous in
                hypot(point.x - previous.center.x, point.y - previous.center.y) / scale
            }.min() ?? 1
            score += max(0, 1 - (nearest / 0.42))
        }
        return score / Double(shapes.count - 1)
    }

    private static func constrainedPoint(
        _ target: CanvasPoint,
        from origin: CanvasPoint,
        inside selection: SelectionShape
    ) -> CanvasPoint {
        if selection.contains(target) { return target }
        guard selection.contains(origin) else {
            return firstInteriorGridPoint(in: selection) ?? target
        }
        var lower = 0.0
        var upper = 1.0
        for _ in 0..<18 {
            let t = (lower + upper) * 0.5
            let candidate = CanvasPoint(
                x: origin.x + ((target.x - origin.x) * t),
                y: origin.y + ((target.y - origin.y) * t)
            )
            if selection.contains(candidate) {
                lower = t
            } else {
                upper = t
            }
        }
        return CanvasPoint(
            x: origin.x + ((target.x - origin.x) * lower * 0.985),
            y: origin.y + ((target.y - origin.y) * lower * 0.985)
        )
    }

    private static func randomInteriorPoint(
        in selection: SelectionShape,
        random: inout CreativeShapeGeneratorRandom
    ) -> CanvasPoint? {
        let bounds = selection.bounds
        for _ in 0..<48 {
            let point = CanvasPoint(
                x: random.double(in: bounds.minX...bounds.maxX),
                y: random.double(in: bounds.minY...bounds.maxY)
            )
            if selection.contains(point) { return point }
        }
        return firstInteriorGridPoint(in: selection)
    }

    private static func firstInteriorGridPoint(in selection: SelectionShape) -> CanvasPoint? {
        let bounds = selection.bounds
        for row in 0..<12 {
            for column in 0..<12 {
                let point = CanvasPoint(
                    x: bounds.minX + ((Double(column) + 0.5) / 12 * bounds.size.x),
                    y: bounds.minY + ((Double(row) + 0.5) / 12 * bounds.size.y)
                )
                if selection.contains(point) { return point }
            }
        }
        return nil
    }

    private static func interiorCentroid(for selection: SelectionShape) -> CanvasPoint? {
        let points = selection.pathPoints
        guard points.count >= 3 else {
            let center = CanvasPoint(
                x: selection.bounds.origin.x + (selection.bounds.size.x * 0.5),
                y: selection.bounds.origin.y + (selection.bounds.size.y * 0.5)
            )
            return selection.contains(center) ? center : nil
        }
        var signedArea = 0.0
        var centerX = 0.0
        var centerY = 0.0
        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            let cross = (current.x * next.y) - (next.x * current.y)
            signedArea += cross
            centerX += (current.x + next.x) * cross
            centerY += (current.y + next.y) * cross
        }
        signedArea *= 0.5
        guard abs(signedArea) > 0.000_001 else { return nil }
        let factor = 1 / (6 * signedArea)
        let centroid = CanvasPoint(x: centerX * factor, y: centerY * factor)
        return selection.contains(centroid) ? centroid : nil
    }

    private static func boundsCorners(_ bounds: CanvasRect) -> [CanvasPoint] {
        [
            CanvasPoint(x: bounds.minX, y: bounds.minY),
            CanvasPoint(x: bounds.maxX, y: bounds.minY),
            CanvasPoint(x: bounds.maxX, y: bounds.maxY),
            CanvasPoint(x: bounds.minX, y: bounds.maxY)
        ]
    }

    private static func offset(
        _ origin: CanvasPoint,
        major: CanvasPoint,
        majorAmount: Double,
        minor: CanvasPoint,
        minorAmount: Double
    ) -> CanvasPoint {
        CanvasPoint(
            x: origin.x + (major.x * majorAmount) + (minor.x * minorAmount),
            y: origin.y + (major.y * majorAmount) + (minor.y * minorAmount)
        )
    }

    private static func catmullRom(
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

    private static func polygonArea(_ points: [CanvasPoint]) -> Double {
        guard points.count >= 3 else { return 0 }
        var area = 0.0
        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            area += (current.x * next.y) - (next.x * current.y)
        }
        return area * 0.5
    }

    private static func lerp(_ lhs: Float, _ rhs: Float, _ amount: Float) -> Float {
        lhs + ((rhs - lhs) * clamp(amount, 0, 1))
    }

    private static func clamp<T: Comparable>(_ value: T, _ minimum: T, _ maximum: T) -> T {
        min(max(value, minimum), maximum)
    }
}

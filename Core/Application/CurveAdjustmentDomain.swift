import Foundation
@preconcurrency import Metal

enum CurveChannel: String, CaseIterable, Equatable, Sendable, Codable {
    case rgb = "RGB"
    case red = "红"
    case green = "绿"
    case blue = "蓝"

    var displayName: String { rawValue }
}

struct CurveControlPoint: Equatable, Sendable, Codable {
    var x: Float
    var y: Float

    init(x: Float, y: Float) {
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
    }
}

struct CurveChannelState: Equatable, Sendable, Codable {
    static let minimumPointSpacing: Float = 0.01
    static let maximumPointCount = 14

    var points: [CurveControlPoint]

    init(points: [CurveControlPoint] = [
        .init(x: 0, y: 0),
        .init(x: 1, y: 1)
    ]) {
        self.points = Self.normalized(points)
    }

    static let identity = Self()

    var isIdentity: Bool {
        points == Self.identity.points
    }

    func insertingPoint(_ point: CurveControlPoint) -> (state: CurveChannelState, insertedIndex: Int)? {
        guard points.count < Self.maximumPointCount else { return nil }

        let insertionIndex = min(
            max(points.firstIndex(where: { $0.x > point.x }) ?? points.count - 1, 1),
            points.count - 1
        )
        let previous = points[insertionIndex - 1]
        let next = points[insertionIndex]
        let minX = previous.x + Self.minimumPointSpacing
        let maxX = next.x - Self.minimumPointSpacing
        guard minX <= maxX else { return nil }

        let insertedPoint = CurveControlPoint(
            x: min(max(point.x, minX), maxX),
            y: min(max(point.y, previous.y), next.y)
        )
        var nextPoints = points
        nextPoints.insert(insertedPoint, at: insertionIndex)
        return (CurveChannelState(points: nextPoints), insertionIndex)
    }

    func movingPoint(at index: Int, to point: CurveControlPoint) -> CurveChannelState {
        guard points.indices.contains(index) else { return self }
        let previous = index == 0 ? nil : points[index - 1]
        let next = index == points.count - 1 ? nil : points[index + 1]
        let updatedPoint = CurveControlPoint(
            x: min(
                max(point.x, (previous?.x ?? 0) + (previous == nil ? 0 : Self.minimumPointSpacing)),
                (next?.x ?? 1) - (next == nil ? 0 : Self.minimumPointSpacing)
            ),
            y: min(max(point.y, previous?.y ?? 0), next?.y ?? 1)
        )

        var nextPoints = points
        nextPoints[index] = updatedPoint
        return CurveChannelState(points: nextPoints)
    }

    func removingPoint(at index: Int) -> CurveChannelState {
        guard points.indices.contains(index) else { return self }
        guard index != 0, index != points.count - 1 else { return self }

        var nextPoints = points
        nextPoints.remove(at: index)
        return CurveChannelState(points: nextPoints)
    }

    private static func normalized(_ input: [CurveControlPoint]) -> [CurveControlPoint] {
        guard input.count >= 2 else {
            return [.init(x: 0, y: 0), .init(x: 1, y: 1)]
        }

        let sorted = input
            .map { CurveControlPoint(x: $0.x, y: $0.y) }
            .sorted { lhs, rhs in
                if abs(lhs.x - rhs.x) < 0.0001 {
                    return lhs.y < rhs.y
                }
                return lhs.x < rhs.x
            }

        var result = sorted

        if result.count > Self.maximumPointCount, let last = result.last {
            result = Array(result.prefix(Self.maximumPointCount - 1)) + [last]
        }

        for index in result.indices {
            let minimumX = index == 0 ? 0 : result[index - 1].x + Self.minimumPointSpacing
            let remainingPointCount = result.count - index - 1
            let maximumX = 1 - (Float(remainingPointCount) * Self.minimumPointSpacing)
            result[index].x = min(max(result[index].x, minimumX), maximumX)
        }

        for index in result.indices {
            let minimumY = index == 0 ? 0 : result[index - 1].y
            result[index].y = min(max(result[index].y, minimumY), 1)
        }

        return result
    }
}

struct CurveAdjustmentParameters: Equatable, Sendable, Codable {
    var selectedChannel: CurveChannel = .rgb
    var rgbCurve: CurveChannelState = .identity
    var redCurve: CurveChannelState = .identity
    var greenCurve: CurveChannelState = .identity
    var blueCurve: CurveChannelState = .identity

    static let neutral = Self()

    var isNeutral: Bool {
        rgbCurve.isIdentity &&
        redCurve.isIdentity &&
        greenCurve.isIdentity &&
        blueCurve.isIdentity
    }

    mutating func resetAll() {
        selectedChannel = .rgb
        rgbCurve = .identity
        redCurve = .identity
        greenCurve = .identity
        blueCurve = .identity
    }

    func state(for channel: CurveChannel) -> CurveChannelState {
        switch channel {
        case .rgb: return rgbCurve
        case .red: return redCurve
        case .green: return greenCurve
        case .blue: return blueCurve
        }
    }

    mutating func setState(_ state: CurveChannelState, for channel: CurveChannel) {
        switch channel {
        case .rgb: rgbCurve = state
        case .red: redCurve = state
        case .green: greenCurve = state
        case .blue: blueCurve = state
        }
    }
}

enum CurveAdjustmentResolutionReason: Equatable, Sendable {
    case toolChange
    case panelChange
    case layerChange
    case historyNavigation
    case documentOpen
    case closeOrQuit

    var continuesTriggeringActionAfterResolution: Bool { true }
}

enum CurveAdjustmentResolutionDecision: Equatable, Sendable {
    case apply
    case discard
    case cancel
}

enum CurveAdjustmentRegionReadMode: Sendable {
    case maskRed
    case sourceAlpha
}

enum CurveAdjustmentBrushMode: Equatable, Sendable {
    case paint
    case erase
}

struct CurvePaintedMaskState {
    var maskTexture: MTLTexture
    var paintedBounds: CanvasRect?
    var brushSamplingState: BrushStrokeSamplingState?
    var opacityCapSession: OpacityCapSessionResources?
}

struct CurveSelectionMaskState {
    var maskTexture: MTLTexture
    var bounds: CanvasRect
    var capturedSelectionShape: SelectionShape
    var capturedSelectionRevision: UInt64
}

struct CurveWholeLayerState {
    var effectBounds: CanvasRect?
    var capturedCanvasRevision: UInt64
}

enum CurveAdjustmentSource {
    case painted(CurvePaintedMaskState)
    case selection(CurveSelectionMaskState)
    case wholeLayer(CurveWholeLayerState)

    var effectiveBounds: CanvasRect? {
        switch self {
        case .painted(let state):
            return state.paintedBounds
        case .selection(let state):
            return state.bounds
        case .wholeLayer(let state):
            return state.effectBounds
        }
    }

    var sourceKindForOverlay: CurveAdjustmentOverlayState.SourceKind {
        switch self {
        case .painted:
            return .paintedMask
        case .selection:
            return .selection
        case .wholeLayer:
            return .wholeLayer
        }
    }
}

struct CurveLUTs: Equatable, Sendable {
    var composite: [Float]
    var red: [Float]
    var green: [Float]
    var blue: [Float]

    static let identity = Self(
        composite: (0..<256).map { Float($0) / 255.0 },
        red: (0..<256).map { Float($0) / 255.0 },
        green: (0..<256).map { Float($0) / 255.0 },
        blue: (0..<256).map { Float($0) / 255.0 }
    )
}

enum CurveLUTBuilder {
    static func buildAll(from parameters: CurveAdjustmentParameters, sampleCount: Int = 256) -> CurveLUTs {
        CurveLUTs(
            composite: buildChannelLUT(from: parameters.rgbCurve, sampleCount: sampleCount),
            red: buildChannelLUT(from: parameters.redCurve, sampleCount: sampleCount),
            green: buildChannelLUT(from: parameters.greenCurve, sampleCount: sampleCount),
            blue: buildChannelLUT(from: parameters.blueCurve, sampleCount: sampleCount)
        )
    }

    static func buildChannelLUT(from state: CurveChannelState, sampleCount: Int = 256) -> [Float] {
        let points = normalizedSortedPoints(state.points)
        guard sampleCount > 1 else { return [0] }

        var output = [Float]()
        output.reserveCapacity(sampleCount)
        for sampleIndex in 0..<sampleCount {
            let x = Float(sampleIndex) / Float(sampleCount - 1)
            output.append(sampleMonotoneCubic(points: points, x: x))
        }
        return output
    }

    static func sampleChannelValue(from state: CurveChannelState, at x: Float) -> Float {
        sampleMonotoneCubic(points: normalizedSortedPoints(state.points), x: x)
    }

    static func normalizedSortedPoints(_ input: [CurveControlPoint]) -> [CurveControlPoint] {
        CurveChannelState(points: input).points
    }

    private static func sampleMonotoneCubic(points: [CurveControlPoint], x: Float) -> Float {
        let x = min(max(x, 0), 1)
        guard points.count >= 2 else { return x }
        if x <= points[0].x {
            return points[0].y
        }
        if let last = points.last, x >= last.x {
            return last.y
        }

        let tangents = monotoneTangents(for: points)

        for index in 0..<(points.count - 1) {
            let a = points[index]
            let b = points[index + 1]
            if x >= a.x && x <= b.x {
                let span = max(b.x - a.x, 0.0001)
                let t = min(max((x - a.x) / span, 0), 1)
                let t2 = t * t
                let t3 = t2 * t

                let h00 = (2 * t3) - (3 * t2) + 1
                let h10 = t3 - (2 * t2) + t
                let h01 = (-2 * t3) + (3 * t2)
                let h11 = t3 - t2

                let value =
                    (h00 * a.y)
                    + (h10 * span * tangents[index])
                    + (h01 * b.y)
                    + (h11 * span * tangents[index + 1])
                return min(max(value, a.y), b.y)
            }
        }

        return points.last?.y ?? x
    }

    private static func monotoneTangents(for points: [CurveControlPoint]) -> [Float] {
        guard points.count >= 2 else { return points.map(\.y) }

        let segmentCount = points.count - 1
        var spans = [Float](repeating: 0, count: segmentCount)
        var slopes = [Float](repeating: 0, count: segmentCount)

        for index in 0..<segmentCount {
            let span = max(points[index + 1].x - points[index].x, 0.0001)
            spans[index] = span
            slopes[index] = (points[index + 1].y - points[index].y) / span
        }

        var tangents = [Float](repeating: 0, count: points.count)
        tangents[0] = slopes[0]
        tangents[points.count - 1] = slopes[segmentCount - 1]

        guard points.count > 2 else { return tangents }

        for index in 1..<(points.count - 1) {
            let previousSlope = slopes[index - 1]
            let nextSlope = slopes[index]
            if previousSlope <= 0 || nextSlope <= 0 {
                tangents[index] = 0
                continue
            }

            let previousSpan = spans[index - 1]
            let nextSpan = spans[index]
            let w1 = (2 * nextSpan) + previousSpan
            let w2 = nextSpan + (2 * previousSpan)
            tangents[index] = (w1 + w2) / ((w1 / previousSlope) + (w2 / nextSlope))
        }

        return tangents
    }
}

struct CurveAdjustmentSession {
    var layerID: LayerID
    var source: CurveAdjustmentSource
    var previewTexture: MTLTexture
    var parameters: CurveAdjustmentParameters = .neutral
    var luts: CurveLUTs = .identity
    var brushMode: CurveAdjustmentBrushMode = .paint
    var showsOriginalPreview: Bool = false

    init(
        layerID: LayerID,
        source: CurveAdjustmentSource,
        previewTexture: MTLTexture,
        parameters: CurveAdjustmentParameters = .neutral,
        brushMode: CurveAdjustmentBrushMode = .paint,
        showsOriginalPreview: Bool = false
    ) {
        self.layerID = layerID
        self.source = source
        self.previewTexture = previewTexture
        self.parameters = parameters
        self.luts = CurveLUTBuilder.buildAll(from: parameters)
        self.brushMode = brushMode
        self.showsOriginalPreview = showsOriginalPreview
    }

    var hasVisiblePreview: Bool {
        switch source {
        case .painted(let state):
            return state.paintedBounds != nil || !parameters.isNeutral
        case .selection, .wholeLayer:
            return !parameters.isNeutral
        }
    }

    var hasPendingCommittedEffect: Bool {
        guard !parameters.isNeutral else { return false }

        switch source {
        case .painted(let state):
            return state.paintedBounds != nil
        case .selection, .wholeLayer:
            return true
        }
    }

    mutating func setParameters(_ parameters: CurveAdjustmentParameters) {
        self.parameters = parameters
        self.luts = CurveLUTBuilder.buildAll(from: parameters)
    }
}

struct CurveAdjustmentOverlayState: Equatable {
    enum SourceKind: Equatable {
        case none
        case paintedMask
        case selection
        case wholeLayer
    }

    var isActive: Bool = false
    var selectedChannel: CurveChannel = .rgb
    var showsOriginalPreview: Bool = false
    var effectiveBounds: CanvasRect?
    var sourceKind: SourceKind = .none

    static let inactive = Self()
}

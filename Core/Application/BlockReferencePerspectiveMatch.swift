import Foundation

struct BlockReferencePerspectiveMatchLine: Identifiable, Sendable, Equatable {
    var id: UUID
    var axis: BlockReferenceAxis
    var start: CanvasPoint
    var end: CanvasPoint

    init(
        id: UUID = UUID(),
        axis: BlockReferenceAxis,
        start: CanvasPoint,
        end: CanvasPoint
    ) {
        self.id = id
        self.axis = axis
        self.start = start
        self.end = end
    }

    var length: Double {
        hypot(end.x - start.x, end.y - start.y)
    }
}

struct BlockReferencePerspectiveMatchState: Sendable, Equatable {
    var isActive = false
    var activeAxis: BlockReferenceAxis = .x
    var lines: [BlockReferencePerspectiveMatchLine] = []
    var draftLine: BlockReferencePerspectiveMatchLine?
    var planeAnchor: CanvasPoint?
    var isPickingPlaneAnchor = false

    func lines(for axis: BlockReferenceAxis) -> [BlockReferencePerspectiveMatchLine] {
        lines.filter { $0.axis == axis }
    }

    func lineCount(for axis: BlockReferenceAxis) -> Int {
        lines.reduce(into: 0) { count, line in
            if line.axis == axis { count += 1 }
        }
    }

    func vanishingPoint(for axis: BlockReferenceAxis) -> CanvasPoint? {
        blockReferencePerspectiveMatchVanishingPoint(lines: lines(for: axis))
    }

    func resolvedPlaneAnchor(canvasSize: CanvasSize) -> CanvasPoint? {
        planeAnchor ?? blockReferencePerspectiveMatchPlaneAnchor(
            xLines: lines(for: .x),
            yLines: lines(for: .y),
            canvasSize: canvasSize
        )
    }

    var hasAnyLines: Bool { !lines.isEmpty }
}

/// Locates the center of the surface described by the X/Y guide families.
/// When the guides follow opposite edges of one tabletop or floor patch, the
/// median of their cross-family intersections is the projected surface center.
func blockReferencePerspectiveMatchPlaneAnchor(
    xLines: [BlockReferencePerspectiveMatchLine],
    yLines: [BlockReferencePerspectiveMatchLine],
    canvasSize: CanvasSize
) -> CanvasPoint? {
    let width = Double(max(canvasSize.width, 1))
    let height = Double(max(canvasSize.height, 1))
    let expandedX = (-width * 0.5)...(width * 1.5)
    let expandedY = (-height * 0.5)...(height * 1.5)
    let intersections = xLines.flatMap { xLine in
        yLines.compactMap { yLine in
            blockReferencePerspectiveMatchLineIntersection(xLine, yLine)
        }
    }
    let preferred = intersections.filter {
        expandedX.contains($0.x) && expandedY.contains($0.y)
    }
    let points = preferred.isEmpty ? intersections : preferred
    guard !points.isEmpty else { return nil }
    func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) * 0.5
            : sorted[middle]
    }
    return CanvasPoint(
        x: median(points.map(\.x)),
        y: median(points.map(\.y))
    )
}

private func blockReferencePerspectiveMatchLineIntersection(
    _ first: BlockReferencePerspectiveMatchLine,
    _ second: BlockReferencePerspectiveMatchLine
) -> CanvasPoint? {
    let firstX = first.end.x - first.start.x
    let firstY = first.end.y - first.start.y
    let secondX = second.end.x - second.start.x
    let secondY = second.end.y - second.start.y
    let determinant = (firstX * secondY) - (firstY * secondX)
    guard determinant.isFinite, abs(determinant) > 0.000_000_1 else { return nil }
    let deltaX = second.start.x - first.start.x
    let deltaY = second.start.y - first.start.y
    let firstScale = ((deltaX * secondY) - (deltaY * secondX)) / determinant
    let point = CanvasPoint(
        x: first.start.x + firstX * firstScale,
        y: first.start.y + firstY * firstScale
    )
    return point.x.isFinite && point.y.isFinite ? point : nil
}

/// Keeps the recovered camera orientation/FOV but changes its framing so a
/// chosen world point projects exactly onto the matched image point.
func blockReferenceCamera(
    anchoring worldPoint: BlockVector3,
    at canvasPoint: CanvasPoint,
    camera: BlockReferenceCamera,
    canvasSize: CanvasSize
) -> BlockReferenceCamera {
    let width = Double(max(canvasSize.width, 1))
    let height = Double(max(canvasSize.height, 1))
    let aspect = width / height
    let ndcX = ((canvasPoint.x / width) - camera.principalPointNormalized.x) * 2
    let ndcY = (camera.principalPointNormalized.y - (canvasPoint.y / height)) * 2
    let fovScale = tan(camera.fieldOfViewDegrees * .pi / 360)
    let basis = blockCameraBasis(camera)
    let horizontalOffset = ndcX * camera.distance * fovScale * aspect
    let verticalOffset = ndcY * camera.distance * fovScale
    var result = camera
    result.target = worldPoint
        - basis.right * horizontalOffset
        - basis.up * verticalOffset
    result.normalize()
    return result
}

enum BlockReferencePerspectiveMatchQuality: Sendable, Equatable {
    case stable
    case approximate
    case poor

    var displayName: String {
        switch self {
        case .stable: return "拟合稳定"
        case .approximate: return "近似可用"
        case .poor: return "偏差较大"
        }
    }
}

struct BlockReferencePerspectiveMatchAssessment: Sendable, Equatable {
    var guide: PerspectiveGuideState
    var camera: BlockReferenceCamera
    var quality: BlockReferencePerspectiveMatchQuality
    var normalizedLineResidual: Double
}

/// Finds the point that minimizes the sum of squared distances to the supplied
/// image lines. The normalized line equations give every guide equal weight,
/// so a short but valid scene edge does not dominate a longer one.
func blockReferencePerspectiveMatchVanishingPoint(
    lines: [BlockReferencePerspectiveMatchLine]
) -> CanvasPoint? {
    perspectiveMatchVanishingPoint(segments: lines.map {
        PerspectiveMatchLineSegment(start: $0.start, end: $0.end)
    })
}

func blockReferencePerspectiveMatchGuide(
    state: BlockReferencePerspectiveMatchState,
    canvasSize: CanvasSize
) -> PerspectiveGuideState? {
    guard let x = state.vanishingPoint(for: .x),
          let y = state.vanishingPoint(for: .y),
          let z = state.vanishingPoint(for: .z) else { return nil }

    let xIsLeft = x.x <= y.x
    var guide = PerspectiveGuideState.initial(canvasSize: canvasSize)
    guide.mode = .threePoint
    guide.leftVanishingPoint = xIsLeft ? x : y
    guide.rightVanishingPoint = xIsLeft ? y : x
    guide.verticalVanishingPoint = z
    guide.verticalDirection = z.y < ((x.y + y.y) * 0.5) ? .above : .below
    guide.anchors = state.lines.map { line in
        let midpoint = CanvasPoint(
            x: (line.start.x + line.end.x) * 0.5,
            y: (line.start.y + line.end.y) * 0.5
        )
        let role: PerspectiveVanishingPointRole
        switch line.axis {
        case .x: role = xIsLeft ? .left : .right
        case .y: role = xIsLeft ? .right : .left
        case .z: role = .vertical
        }
        return PerspectiveGuideAnchor(
            position: midpoint,
            connectsLeft: role == .left,
            connectsRight: role == .right,
            connectsVertical: role == .vertical
        )
    }
    guide.isVisible = true
    guide.isLocked = true
    return guide
}

func makeBlockReferencePerspectiveMatchAssessment(
    state: BlockReferencePerspectiveMatchState,
    currentCamera: BlockReferenceCamera,
    canvasSize: CanvasSize
) -> BlockReferencePerspectiveMatchAssessment? {
    guard let guide = blockReferencePerspectiveMatchGuide(
        state: state,
        canvasSize: canvasSize
    ), let camera = blockReferenceCameraMatchingPerspectiveGuide(
        guide,
        currentCamera: currentCamera,
        canvasSize: canvasSize
    ) else { return nil }

    let width = Double(max(canvasSize.width, 1))
    let height = Double(max(canvasSize.height, 1))
    let axisVanishingPoints = Dictionary(uniqueKeysWithValues: BlockReferenceAxis.allCases.compactMap {
        axis in state.vanishingPoint(for: axis).map { (axis, $0) }
    })
    var squaredDistance = 0.0
    var sampleCount = 0
    for line in state.lines {
        guard let vanishingPoint = axisVanishingPoints[line.axis] else { continue }
        let dx = line.end.x - line.start.x
        let dy = line.end.y - line.start.y
        let length = hypot(dx, dy)
        guard length >= 1 else { continue }
        let distance = abs(
            dy * (vanishingPoint.x - line.start.x)
                - dx * (vanishingPoint.y - line.start.y)
        ) / length
        squaredDistance += distance * distance
        sampleCount += 1
    }
    let residual = sampleCount > 0
        ? sqrt(squaredDistance / Double(sampleCount)) / max(min(width, height), 1)
        : .infinity
    let principal = camera.principalPointNormalized
    let principalIsPlausible = (-0.25...1.25).contains(principal.x)
        && (-0.25...1.25).contains(principal.y)
    let quality: BlockReferencePerspectiveMatchQuality
    if residual <= 0.0025, principalIsPlausible {
        quality = .stable
    } else if residual <= 0.01 {
        quality = .approximate
    } else {
        quality = .poor
    }
    return BlockReferencePerspectiveMatchAssessment(
        guide: guide,
        camera: camera,
        quality: quality,
        normalizedLineResidual: residual
    )
}

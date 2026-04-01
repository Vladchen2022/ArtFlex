import Foundation

private let gradientLegLatchMinDistance = 10.0
private let gradientLeg2MinDistance = 10.0
private let gradientLegLatchAngleThresholdDegrees = 32.0
private let gradientHandleHitRadius = 14.0

enum LinearGradientHandle: Sendable, Equatable {
    case pointA
    case pointB
    case pointC
}

enum LinearGradientPhase: Sendable, Equatable {
    case idle
    case drawingLeg1
    case drawingLeg2
    case pendingPreview
    case editing
    case draggingHandle(LinearGradientHandle)
    case movingWholeGradient
}

enum SectorGradientPhase: Sendable, Equatable {
    case idle
    case drawing
}

struct LinearGradientGeometry: Sendable, Equatable {
    var pointA: CanvasPoint
    var pointB: CanvasPoint
    var pointC: CanvasPoint

    var pointD: CanvasPoint {
        CanvasPoint(
            x: pointA.x + (pointC.x - pointB.x),
            y: pointA.y + (pointC.y - pointB.y)
        )
    }

    var centerLineStart: CanvasPoint {
        CanvasPoint(
            x: (pointA.x + pointB.x) * 0.5,
            y: (pointA.y + pointB.y) * 0.5
        )
    }

    var centerLineEnd: CanvasPoint {
        let pointD = pointD
        return CanvasPoint(
            x: (pointD.x + pointC.x) * 0.5,
            y: (pointD.y + pointC.y) * 0.5
        )
    }
}

struct LinearGradientPreview: Sendable, Equatable {
    let pointA: CanvasPoint
    let pointB: CanvasPoint
    let pointC: CanvasPoint?
    let pointD: CanvasPoint

    var geometry: LinearGradientGeometry? {
        guard let pointC else { return nil }
        return LinearGradientGeometry(pointA: pointA, pointB: pointB, pointC: pointC)
    }
}

struct LinearGradientInteractionState: Sendable, Equatable {
    var phase: LinearGradientPhase = .idle
    var pointA: CanvasPoint?
    var pointB: CanvasPoint?
    var pointC: CanvasPoint?
    var dragStartPoint: CanvasPoint?
    var dragReferenceGeometry: LinearGradientGeometry?
    var leg1CandidatePoint: CanvasPoint?
    var hoverPoint: CanvasPoint?

    var geometry: LinearGradientGeometry? {
        guard let pointA, let pointB, let pointC else { return nil }
        return LinearGradientGeometry(pointA: pointA, pointB: pointB, pointC: pointC)
    }

    var preview: LinearGradientPreview? {
        guard let pointA, let pointB else { return nil }
        if let pointC {
            let geometry = LinearGradientGeometry(pointA: pointA, pointB: pointB, pointC: pointC)
            return LinearGradientPreview(
                pointA: geometry.pointA,
                pointB: geometry.pointB,
                pointC: geometry.pointC,
                pointD: geometry.pointD
            )
        }

        return LinearGradientPreview(
            pointA: pointA,
            pointB: pointB,
            pointC: nil,
            pointD: pointA
        )
    }

    var isActiveSession: Bool {
        phase != .idle
    }

    var isEditingSession: Bool {
        switch phase {
        case .editing, .draggingHandle, .movingWholeGradient:
            return true
        default:
            return false
        }
    }

    var isPendingPreview: Bool {
        phase == .pendingPreview
    }
}

struct SectorGradientGeometry: Sendable, Equatable {
    let center: CanvasPoint
    let pathPoints: [CanvasPoint]
    let bounds: CanvasRect
    let maxRadius: Double
}

struct SectorGradientPreview: Sendable, Equatable {
    let center: CanvasPoint
    let pathPoints: [CanvasPoint]
    let hoverPoint: CanvasPoint?
}

struct SectorGradientInteractionState: Sendable, Equatable {
    var phase: SectorGradientPhase = .idle
    var center: CanvasPoint?
    var pathPoints: [CanvasPoint] = []
    var hoverPoint: CanvasPoint?

    var geometry: SectorGradientGeometry? {
        guard let center else { return nil }
        let smoothedPathPoints = smoothedSectorGradientPoints(
            rawPoints: pathPoints,
            closingTo: center
        )
        return resolvedSectorGradientGeometry(center: center, pathPoints: smoothedPathPoints)
    }

    var preview: SectorGradientPreview? {
        guard let center else { return nil }
        return SectorGradientPreview(
            center: center,
            pathPoints: pathPoints,
            hoverPoint: hoverPoint
        )
    }

    var isActiveSession: Bool {
        phase != .idle
    }

    var isEditingSession: Bool {
        false
    }

    var isPendingPreview: Bool {
        false
    }
}

func normalizedAngleDelta(from start: Double, to end: Double) -> Double {
    var delta = end - start
    while delta <= -.pi { delta += .pi * 2 }
    while delta > .pi { delta -= .pi * 2 }
    return delta
}

func distanceBetween(_ lhs: CanvasPoint, _ rhs: CanvasPoint) -> Double {
    hypot(rhs.x - lhs.x, rhs.y - lhs.y)
}

private func angleDegreesBetween(_ lhs: CanvasPoint, _ rhs: CanvasPoint) -> Double {
    let lhsLength = hypot(lhs.x, lhs.y)
    let rhsLength = hypot(rhs.x, rhs.y)
    guard lhsLength > 0.0001, rhsLength > 0.0001 else { return 0 }
    let dot = ((lhs.x * rhs.x) + (lhs.y * rhs.y)) / (lhsLength * rhsLength)
    return acos(max(min(dot, 1), -1)) * 180 / .pi
}

func shouldLatchGradientLeg2(origin: CanvasPoint, leg1Point: CanvasPoint, currentPoint: CanvasPoint) -> Bool {
    let leg1Vector = CanvasPoint(x: leg1Point.x - origin.x, y: leg1Point.y - origin.y)
    let leg2Vector = CanvasPoint(x: currentPoint.x - leg1Point.x, y: currentPoint.y - leg1Point.y)
    guard hypot(leg1Vector.x, leg1Vector.y) >= gradientLegLatchMinDistance else { return false }
    guard hypot(leg2Vector.x, leg2Vector.y) >= gradientLeg2MinDistance else { return false }
    return angleDegreesBetween(leg1Vector, leg2Vector) >= gradientLegLatchAngleThresholdDegrees
}

func defaultLinearGradientPointC(pointA: CanvasPoint, pointB: CanvasPoint, canvasSize: CanvasSize) -> CanvasPoint {
    let dx = pointB.x - pointA.x
    let dy = pointB.y - pointA.y
    let length = max(hypot(dx, dy), 1)
    let defaultLength = max(length * 0.35, Double(min(canvasSize.width, canvasSize.height)) * 0.12)
    let unitPerpendicular = CanvasPoint(x: -dy / length, y: dx / length)
    return CanvasPoint(
        x: pointB.x + (unitPerpendicular.x * defaultLength),
        y: pointB.y + (unitPerpendicular.y * defaultLength)
    )
}

func resolvedSectorGradientGeometry(
    center: CanvasPoint,
    pathPoints: [CanvasPoint]
) -> SectorGradientGeometry? {
    guard pathPoints.count >= 3 else { return nil }
    let bounds = CanvasRect.bounding(points: pathPoints)
    guard !bounds.isEmpty else { return nil }
    let maxRadius = pathPoints.reduce(0.0) { partialResult, point in
        max(partialResult, distanceBetween(center, point))
    }
    guard maxRadius > 0.5 else { return nil }
    return SectorGradientGeometry(
        center: center,
        pathPoints: pathPoints,
        bounds: bounds,
        maxRadius: maxRadius
    )
}

func resolvedLinearGradientPreviewGeometry(
    preview: LinearGradientPreview,
    canvasSize: CanvasSize
) -> LinearGradientGeometry? {
    guard distanceBetween(preview.pointA, preview.pointB) > 0.5 else { return nil }
    let pointC = preview.pointC ?? defaultLinearGradientPointC(
        pointA: preview.pointA,
        pointB: preview.pointB,
        canvasSize: canvasSize
    )
    return LinearGradientGeometry(
        pointA: preview.pointA,
        pointB: preview.pointB,
        pointC: pointC
    )
}

func resolvedSectorGradientPreviewGeometry(
    preview: SectorGradientPreview
) -> SectorGradientGeometry? {
    var pathPoints = preview.pathPoints
    if let hoverPoint = preview.hoverPoint, pathPoints.last != hoverPoint {
        pathPoints.append(hoverPoint)
    }
    let smoothedPathPoints = smoothedSectorGradientPoints(
        rawPoints: pathPoints,
        closingTo: preview.center
    )
    return resolvedSectorGradientGeometry(center: preview.center, pathPoints: smoothedPathPoints)
}

func linearGradientPreviewContains(_ geometry: LinearGradientGeometry, point: CanvasPoint) -> Bool {
    let polygon = [geometry.pointA, geometry.pointB, geometry.pointC, geometry.pointD]
    return polygonContains(point: point, polygon: polygon)
}

func linearGradientHandleHitTest(_ geometry: LinearGradientGeometry, point: CanvasPoint) -> LinearGradientHandle? {
    if distanceBetween(point, geometry.pointA) <= gradientHandleHitRadius { return .pointA }
    if distanceBetween(point, geometry.pointB) <= gradientHandleHitRadius { return .pointB }
    if distanceBetween(point, geometry.pointC) <= gradientHandleHitRadius { return .pointC }
    return nil
}

func sectorGradientPreviewContains(_ geometry: SectorGradientGeometry, point: CanvasPoint) -> Bool {
    let shape = SelectionShape(
        kind: .lasso,
        bounds: geometry.bounds,
        pathPoints: geometry.pathPoints
    )
    return shape.contains(point)
}

func shouldShowGradientAnnotator(phase: LinearGradientPhase) -> Bool {
    switch phase {
    case .editing, .draggingHandle, .movingWholeGradient:
        return true
    default:
        return false
    }
}

func shouldShowGradientAnnotator(phase: SectorGradientPhase) -> Bool {
    false
}

func shouldShowGradientDraftOverlay(phase: LinearGradientPhase) -> Bool {
    switch phase {
    case .idle:
        return false
    case .drawingLeg1, .drawingLeg2, .pendingPreview, .editing, .draggingHandle, .movingWholeGradient:
        return true
    }
}

func shouldShowGradientDraftOverlay(phase: SectorGradientPhase) -> Bool {
    switch phase {
    case .idle:
        return false
    case .drawing:
        return true
    }
}

func shouldAutoApplyGradientForToolSwitch(phase: LinearGradientPhase) -> Bool {
    switch phase {
    case .pendingPreview, .editing, .draggingHandle, .movingWholeGradient:
        return true
    default:
        return false
    }
}

func shouldAutoApplyGradientForToolSwitch(phase: SectorGradientPhase) -> Bool {
    switch phase {
    case .idle, .drawing:
        return false
    }
}

private func polygonContains(point: CanvasPoint, polygon: [CanvasPoint]) -> Bool {
    guard polygon.count >= 3 else { return false }
    var isInside = false
    var previous = polygon.last!
    for current in polygon {
        let intersects = ((current.y > point.y) != (previous.y > point.y)) &&
            (point.x < (previous.x - current.x) * (point.y - current.y) / max(previous.y - current.y, 0.0001) + current.x)
        if intersects {
            isInside.toggle()
        }
        previous = current
    }
    return isInside
}

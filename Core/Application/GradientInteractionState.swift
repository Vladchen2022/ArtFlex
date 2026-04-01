import Foundation

private let gradientLegLatchMinDistance = 10.0
private let gradientLeg2MinDistance = 10.0
private let gradientLegLatchAngleThresholdDegrees = 32.0
private let gradientHandleHitRadius = 14.0
private let sectorFallbackSweepDegrees = 30.0

enum LinearGradientHandle: Sendable, Equatable {
    case pointA
    case pointB
    case pointC
}

enum SectorGradientHandle: Sendable, Equatable {
    case center
    case startEdge
    case endEdge
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
    case drawingLeg1
    case drawingLeg2
    case pendingPreview
    case editing
    case draggingHandle(SectorGradientHandle)
    case movingWholeGradient
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
    let startPoint: CanvasPoint
    let endPoint: CanvasPoint

    var radius: Double {
        max(distanceBetween(center, startPoint), distanceBetween(center, endPoint))
    }

    var startAngle: Double {
        atan2(startPoint.y - center.y, startPoint.x - center.x)
    }

    var endAngle: Double {
        atan2(endPoint.y - center.y, endPoint.x - center.x)
    }

    var sweepAngle: Double {
        normalizedAngleDelta(from: startAngle, to: endAngle)
    }

    var isFullCircle: Bool {
        abs(sweepAngle) >= (.pi * 1.85)
    }
}

struct SectorGradientPreview: Sendable, Equatable {
    let center: CanvasPoint
    let startPoint: CanvasPoint
    let geometry: SectorGradientGeometry?
    let endPoint: CanvasPoint?
}

struct SectorGradientInteractionState: Sendable, Equatable {
    var phase: SectorGradientPhase = .idle
    var center: CanvasPoint?
    var startPoint: CanvasPoint?
    var endPoint: CanvasPoint?
    var dragStartPoint: CanvasPoint?
    var dragReferenceGeometry: SectorGradientGeometry?
    var leg1CandidatePoint: CanvasPoint?
    var hoverPoint: CanvasPoint?

    var geometry: SectorGradientGeometry? {
        guard let center, let startPoint, let endPoint else { return nil }
        let geometry = SectorGradientGeometry(center: center, startPoint: startPoint, endPoint: endPoint)
        guard geometry.radius > 1, abs(geometry.sweepAngle) > 0.001 else { return nil }
        return geometry
    }

    var preview: SectorGradientPreview? {
        guard let center else { return nil }
        return SectorGradientPreview(
            center: center,
            startPoint: startPoint ?? center,
            geometry: geometry,
            endPoint: endPoint
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

func defaultSectorGradientEndPoint(center: CanvasPoint, startPoint: CanvasPoint) -> CanvasPoint {
    let radius = max(distanceBetween(center, startPoint), 1)
    let startAngle = atan2(startPoint.y - center.y, startPoint.x - center.x)
    let endAngle = startAngle + (sectorFallbackSweepDegrees * .pi / 180)
    return CanvasPoint(
        x: center.x + (cos(endAngle) * radius),
        y: center.y + (sin(endAngle) * radius)
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
    guard distanceBetween(preview.center, preview.startPoint) > 0.5 else { return nil }
    let endPoint = preview.endPoint ?? defaultSectorGradientEndPoint(
        center: preview.center,
        startPoint: preview.startPoint
    )
    let geometry = SectorGradientGeometry(
        center: preview.center,
        startPoint: preview.startPoint,
        endPoint: endPoint
    )
    guard geometry.radius > 1, abs(geometry.sweepAngle) > 0.001 else { return nil }
    return geometry
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

func sectorGradientHandleHitTest(_ geometry: SectorGradientGeometry, point: CanvasPoint) -> SectorGradientHandle? {
    if distanceBetween(point, geometry.center) <= gradientHandleHitRadius { return .center }
    if distanceBetween(point, geometry.startPoint) <= gradientHandleHitRadius { return .startEdge }
    if distanceBetween(point, geometry.endPoint) <= gradientHandleHitRadius { return .endEdge }
    return nil
}

func sectorGradientPreviewContains(_ geometry: SectorGradientGeometry, point: CanvasPoint) -> Bool {
    let dx = point.x - geometry.center.x
    let dy = point.y - geometry.center.y
    let radius = hypot(dx, dy)
    guard radius <= geometry.radius else { return false }

    if geometry.isFullCircle {
        return true
    }

    let angle = atan2(dy, dx)
    let relative = normalizedAngleDelta(from: geometry.startAngle, to: angle)
    if geometry.sweepAngle >= 0 {
        return relative >= 0 && relative <= geometry.sweepAngle
    } else {
        return relative <= 0 && relative >= geometry.sweepAngle
    }
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
    switch phase {
    case .editing, .draggingHandle, .movingWholeGradient:
        return true
    default:
        return false
    }
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
    case .drawingLeg1, .drawingLeg2, .pendingPreview, .editing, .draggingHandle, .movingWholeGradient:
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
    case .pendingPreview, .editing, .draggingHandle, .movingWholeGradient:
        return true
    default:
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

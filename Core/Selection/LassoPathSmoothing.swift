import CoreGraphics
import Foundation

struct ClosedLassoSmoothingConfiguration {
    let anchorMinimumDistance: Double
    let sampleStep: Double
    let outputMinimumDistance: Double
    let fallbackMinimumDistance: Double

    static let selectionDefault = ClosedLassoSmoothingConfiguration(
        anchorMinimumDistance: 6,
        sampleStep: 2.5,
        outputMinimumDistance: 0.75,
        fallbackMinimumDistance: 0.75
    )

    static let sectorGradient = ClosedLassoSmoothingConfiguration(
        anchorMinimumDistance: 3,
        sampleStep: 0.75,
        outputMinimumDistance: 0.2,
        fallbackMinimumDistance: 0.4
    )
}

func smoothedClosedLassoPoints(
    rawPoints: [CanvasPoint],
    closingTo endPoint: CanvasPoint
) -> [CanvasPoint] {
    smoothedClosedLassoPoints(
        rawPoints: rawPoints,
        closingTo: endPoint,
        configuration: .selectionDefault
    )
}

func smoothedClosedLassoPoints(
    rawPoints: [CanvasPoint],
    closingTo endPoint: CanvasPoint,
    configuration: ClosedLassoSmoothingConfiguration
) -> [CanvasPoint] {
    var points = rawPoints
    if points.isEmpty {
        points = [endPoint]
    } else if points.last != endPoint {
        points.append(endPoint)
    }

    let anchors = deduplicatedLassoPoints(points, minimumDistance: configuration.anchorMinimumDistance)
    guard anchors.count >= 3 else {
        return deduplicatedLassoPoints(points, minimumDistance: configuration.fallbackMinimumDistance)
    }

    guard let smoothedPath = smoothedClosedLassoPath(points: anchors) else {
        return deduplicatedLassoPoints(points, minimumDistance: configuration.fallbackMinimumDistance)
    }

    let smoothed = sampledPoints(
        from: smoothedPath,
        sampleStep: configuration.sampleStep
    )
    let output = deduplicatedLassoPoints(smoothed, minimumDistance: configuration.outputMinimumDistance)
    return output.count >= 3 ? output : deduplicatedLassoPoints(points, minimumDistance: configuration.fallbackMinimumDistance)
}

func smoothedSectorGradientPoints(
    rawPoints: [CanvasPoint],
    closingTo endPoint: CanvasPoint
) -> [CanvasPoint] {
    smoothedClosedLassoPoints(
        rawPoints: rawPoints,
        closingTo: endPoint,
        configuration: .sectorGradient
    )
}

func smoothedClosedLassoPath(points: [CanvasPoint]) -> CGPath? {
    guard points.count >= 3 else { return nil }
    return makeSmoothedClosedLassoPath(points: points)
}

private func deduplicatedLassoPoints(
    _ points: [CanvasPoint],
    minimumDistance: Double
) -> [CanvasPoint] {
    guard let first = points.first else { return [] }
    var output: [CanvasPoint] = [first]
    for point in points.dropFirst() {
        if distanceBetween(output[output.count - 1], point) >= minimumDistance {
            output.append(point)
        }
    }
    if let last = points.last, output.last != last {
        output.append(last)
    }
    return output
}

private func makeSmoothedClosedLassoPath(points: [CanvasPoint]) -> CGMutablePath {
    let path = CGMutablePath()
    guard points.count >= 3 else { return path }

    let lastMidpoint = midpointBetween(points[points.count - 1], points[0])
    path.move(to: CGPoint(x: lastMidpoint.x, y: lastMidpoint.y))

    for index in points.indices {
        let current = points[index]
        let next = points[(index + 1) % points.count]
        let midpoint = midpointBetween(current, next)
        path.addQuadCurve(
            to: CGPoint(x: midpoint.x, y: midpoint.y),
            control: CGPoint(x: current.x, y: current.y)
        )
    }

    path.closeSubpath()
    return path
}

private func sampledPoints(
    from path: CGPath,
    sampleStep: Double
) -> [CanvasPoint] {
    var sampled: [CanvasPoint] = []
    var currentPoint = CGPoint.zero
    var subpathStart = CGPoint.zero

    path.applyWithBlock { elementPointer in
        let element = elementPointer.pointee
        switch element.type {
        case .moveToPoint:
            let point = element.points[0]
            currentPoint = point
            subpathStart = point
            sampled.append(CanvasPoint(x: point.x, y: point.y))
        case .addLineToPoint:
            let end = element.points[0]
            sampled.append(contentsOf: sampleLine(from: currentPoint, to: end, step: sampleStep))
            currentPoint = end
        case .addQuadCurveToPoint:
            let control = element.points[0]
            let end = element.points[1]
            sampled.append(
                contentsOf: sampleQuadratic(
                    from: currentPoint,
                    control: control,
                    to: end,
                    step: sampleStep
                )
            )
            currentPoint = end
        case .closeSubpath:
            sampled.append(contentsOf: sampleLine(from: currentPoint, to: subpathStart, step: sampleStep))
            currentPoint = subpathStart
        default:
            break
        }
    }

    return sampled
}

private func sampleLine(
    from start: CGPoint,
    to end: CGPoint,
    step: Double
) -> [CanvasPoint] {
    let distance = hypot(end.x - start.x, end.y - start.y)
    let steps = max(Int(ceil(distance / max(step, 0.5))), 1)
    return (1...steps).map { index in
        let t = Double(index) / Double(steps)
        return CanvasPoint(
            x: start.x + ((end.x - start.x) * t),
            y: start.y + ((end.y - start.y) * t)
        )
    }
}

private func sampleQuadratic(
    from start: CGPoint,
    control: CGPoint,
    to end: CGPoint,
    step: Double
) -> [CanvasPoint] {
    let controlPolygonLength =
        hypot(control.x - start.x, control.y - start.y) +
        hypot(end.x - control.x, end.y - control.y)
    let steps = max(Int(ceil(controlPolygonLength / max(step, 0.5))), 2)

    return (1...steps).map { index in
        let t = Double(index) / Double(steps)
        let oneMinusT = 1 - t
        let x =
            (oneMinusT * oneMinusT * start.x) +
            (2 * oneMinusT * t * control.x) +
            (t * t * end.x)
        let y =
            (oneMinusT * oneMinusT * start.y) +
            (2 * oneMinusT * t * control.y) +
            (t * t * end.y)
        return CanvasPoint(x: x, y: y)
    }
}

private func midpointBetween(_ lhs: CanvasPoint, _ rhs: CanvasPoint) -> CanvasPoint {
    CanvasPoint(
        x: (lhs.x + rhs.x) * 0.5,
        y: (lhs.y + rhs.y) * 0.5
    )
}

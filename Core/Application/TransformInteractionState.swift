import Foundation
import CoreGraphics

enum TransformClearBehavior: Equatable {
    case none
    case cancel
    case apply
}

enum TransformResolutionReason: Equatable {
    case toolChange
    case layerChange
    case historyNavigation
    case documentOpen
}

enum TransformResolutionAction: Equatable {
    case none
    case applyAndClearSelection
    case cancelAndClearSelection
    case cancelAndPreserveSelection
}

enum FreeTransformHandle: String, CaseIterable, Sendable, Equatable {
    case topLeft
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left
    case rotation
}

enum FreeTransformInteractionMode: Sendable, Equatable {
    case move
    case scale(FreeTransformHandle)
    case rotate
    case meshPoint(Int)
    case meshArea(MeshWarpParameter)
}

enum FreeTransformToolMode: String, CaseIterable, Sendable, Equatable {
    case standard
    case mesh
}

struct MeshWarpVertex: Sendable, Equatable {
    var canvasPosition: CanvasPoint
    var textureCoordinate: CanvasPoint
}

struct MeshWarpParameter: Sendable, Equatable {
    var u: Double
    var v: Double
}

struct MeshWarpGrid: Sendable, Equatable {
    let sourceBounds: CanvasRect
    let columns: Int
    let rows: Int
    var controlPoints: [CanvasPoint]

    static func regular(
        bounds: CanvasRect,
        columns: Int = 4,
        rows: Int = 4
    ) -> MeshWarpGrid {
        let resolvedColumns = max(columns, 2)
        let resolvedRows = max(rows, 2)
        var points: [CanvasPoint] = []
        points.reserveCapacity(resolvedColumns * resolvedRows)

        for row in 0..<resolvedRows {
            let v = Double(row) / Double(resolvedRows - 1)
            for column in 0..<resolvedColumns {
                let u = Double(column) / Double(resolvedColumns - 1)
                points.append(
                    CanvasPoint(
                        x: bounds.minX + (bounds.size.x * u),
                        y: bounds.minY + (bounds.size.y * v)
                    )
                )
            }
        }

        return MeshWarpGrid(
            sourceBounds: bounds,
            columns: resolvedColumns,
            rows: resolvedRows,
            controlPoints: points
        )
    }

    var isIdentity: Bool {
        let identity = Self.regular(
            bounds: sourceBounds,
            columns: columns,
            rows: rows
        )
        guard identity.controlPoints.count == controlPoints.count else { return false }
        return zip(identity.controlPoints, controlPoints).allSatisfy { expected, actual in
            abs(expected.x - actual.x) < 0.0001 &&
            abs(expected.y - actual.y) < 0.0001
        }
    }

    var destinationBounds: CanvasRect? {
        guard let first = controlPoints.first else { return nil }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in controlPoints.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CanvasRect(
            origin: .init(x: minX, y: minY),
            size: .init(x: maxX - minX, y: maxY - minY)
        )
    }

    func point(row: Int, column: Int) -> CanvasPoint? {
        guard row >= 0, row < rows, column >= 0, column < columns else { return nil }
        let index = (row * columns) + column
        guard controlPoints.indices.contains(index) else { return nil }
        return controlPoints[index]
    }

    func movingControlPoint(at index: Int, by delta: CanvasPoint) -> MeshWarpGrid {
        guard controlPoints.indices.contains(index) else { return self }
        var next = self
        next.controlPoints[index] = CanvasPoint(
            x: controlPoints[index].x + delta.x,
            y: controlPoints[index].y + delta.y
        )
        return next
    }

    func movingControlPoints(at indices: Set<Int>, by delta: CanvasPoint) -> MeshWarpGrid {
        let validIndices = indices.filter(controlPoints.indices.contains)
        guard !validIndices.isEmpty else { return self }

        var next = self
        for index in validIndices {
            next.controlPoints[index] = CanvasPoint(
                x: controlPoints[index].x + delta.x,
                y: controlPoints[index].y + delta.y
            )
        }
        return next
    }

    func translated(by delta: CanvasPoint) -> MeshWarpGrid {
        var next = self
        next.controlPoints = controlPoints.map {
            CanvasPoint(x: $0.x + delta.x, y: $0.y + delta.y)
        }
        return next
    }

    func applying(_ transform: CGAffineTransform) -> MeshWarpGrid {
        var next = self
        next.controlPoints = controlPoints.map { point in
            let transformed = CGPoint(x: point.x, y: point.y).applying(transform)
            return CanvasPoint(x: transformed.x, y: transformed.y)
        }
        return next
    }

    func nearestControlPoint(to point: CanvasPoint, radius: Double) -> Int? {
        var bestIndex: Int?
        var bestDistance = max(radius, 0)
        for (index, controlPoint) in controlPoints.enumerated() {
            let distance = hypot(controlPoint.x - point.x, controlPoint.y - point.y)
            if distance <= bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    var cornerControlPointIndices: [Int] {
        guard columns >= 2, rows >= 2 else { return [] }
        return [
            0,
            columns - 1,
            (rows - 1) * columns,
            (rows * columns) - 1
        ]
    }

    func nearestCornerControlPoint(to point: CanvasPoint, radius: Double) -> Int? {
        var bestIndex: Int?
        var bestDistance = max(radius, 0)
        for index in cornerControlPointIndices where controlPoints.indices.contains(index) {
            let controlPoint = controlPoints[index]
            let distance = hypot(controlPoint.x - point.x, controlPoint.y - point.y)
            if distance <= bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    func surfacePoint(at parameter: MeshWarpParameter) -> CanvasPoint? {
        let weights = controlPointWeights(at: parameter)
        guard weights.count == controlPoints.count, !weights.isEmpty else { return nil }

        var result = CanvasPoint(x: 0, y: 0)
        for (point, weight) in zip(controlPoints, weights) {
            result.x += point.x * weight
            result.y += point.y * weight
        }
        return result
    }

    func movingSurface(at parameter: MeshWarpParameter, by delta: CanvasPoint) -> MeshWarpGrid {
        let weights = controlPointWeights(at: parameter)
        guard weights.count == controlPoints.count, !weights.isEmpty else { return self }

        let response = weights.reduce(0) { partial, weight in
            partial + (weight * weight)
        }
        guard response > 0.000_001 else { return self }

        var next = self
        for index in next.controlPoints.indices {
            let influence = weights[index] / response
            next.controlPoints[index] = CanvasPoint(
                x: controlPoints[index].x + (delta.x * influence),
                y: controlPoints[index].y + (delta.y * influence)
            )
        }
        return next
    }

    func surfaceParameter(containing point: CanvasPoint, subdivisions: Int = 24) -> MeshWarpParameter? {
        let steps = max(subdivisions, 4)
        let sampledPoints = sampledSurface(horizontalSteps: steps, verticalSteps: steps)
        guard sampledPoints.count == (steps + 1) * (steps + 1) else { return nil }

        for row in 0..<steps {
            let v0 = Double(row) / Double(steps)
            let v1 = Double(row + 1) / Double(steps)
            for column in 0..<steps {
                let u0 = Double(column) / Double(steps)
                let u1 = Double(column + 1) / Double(steps)
                let parameterA = MeshWarpParameter(u: u0, v: v0)
                let parameterB = MeshWarpParameter(u: u1, v: v0)
                let parameterC = MeshWarpParameter(u: u0, v: v1)
                let parameterD = MeshWarpParameter(u: u1, v: v1)
                let topLeftIndex = (row * (steps + 1)) + column
                let pointA = sampledPoints[topLeftIndex]
                let pointB = sampledPoints[topLeftIndex + 1]
                let pointC = sampledPoints[topLeftIndex + steps + 1]
                let pointD = sampledPoints[topLeftIndex + steps + 2]

                if let barycentric = Self.barycentricCoordinates(
                    for: point,
                    triangle: (pointA, pointC, pointB)
                ) {
                    return Self.interpolateParameter(
                        barycentric,
                        triangle: (parameterA, parameterC, parameterB)
                    )
                }
                if let barycentric = Self.barycentricCoordinates(
                    for: point,
                    triangle: (pointB, pointC, pointD)
                ) {
                    return Self.interpolateParameter(
                        barycentric,
                        triangle: (parameterB, parameterC, parameterD)
                    )
                }
            }
        }
        return nil
    }

    func tessellatedVertices(subdivisionsPerCell: Int = 8) -> [MeshWarpVertex] {
        guard columns >= 2, rows >= 2 else { return [] }
        guard controlPoints.count == columns * rows else { return [] }
        let subdivisions = max(subdivisionsPerCell, 1)
        let horizontalSteps = (columns - 1) * subdivisions
        let verticalSteps = (rows - 1) * subdivisions
        let sampledPoints = sampledSurface(
            horizontalSteps: horizontalSteps,
            verticalSteps: verticalSteps
        )
        guard sampledPoints.count == (horizontalSteps + 1) * (verticalSteps + 1) else { return [] }

        var vertices: [MeshWarpVertex] = []
        vertices.reserveCapacity(horizontalSteps * verticalSteps * 6)

        for row in 0..<verticalSteps {
            let v0 = Double(row) / Double(verticalSteps)
            let v1 = Double(row + 1) / Double(verticalSteps)
            for column in 0..<horizontalSteps {
                let u0 = Double(column) / Double(horizontalSteps)
                let u1 = Double(column + 1) / Double(horizontalSteps)
                let topLeftIndex = (row * (horizontalSteps + 1)) + column
                let pointA = sampledPoints[topLeftIndex]
                let pointB = sampledPoints[topLeftIndex + 1]
                let pointC = sampledPoints[topLeftIndex + horizontalSteps + 1]
                let pointD = sampledPoints[topLeftIndex + horizontalSteps + 2]
                let a = MeshWarpVertex(canvasPosition: pointA, textureCoordinate: .init(x: u0, y: v0))
                let b = MeshWarpVertex(canvasPosition: pointB, textureCoordinate: .init(x: u1, y: v0))
                let c = MeshWarpVertex(canvasPosition: pointC, textureCoordinate: .init(x: u0, y: v1))
                let d = MeshWarpVertex(canvasPosition: pointD, textureCoordinate: .init(x: u1, y: v1))
                vertices.append(contentsOf: [a, c, b, b, c, d])
            }
        }
        return vertices
    }

    private func sampledSurface(horizontalSteps: Int, verticalSteps: Int) -> [CanvasPoint] {
        guard horizontalSteps > 0, verticalSteps > 0 else { return [] }
        var points: [CanvasPoint] = []
        points.reserveCapacity((horizontalSteps + 1) * (verticalSteps + 1))
        for row in 0...verticalSteps {
            let v = Double(row) / Double(verticalSteps)
            for column in 0...horizontalSteps {
                let u = Double(column) / Double(horizontalSteps)
                guard let point = surfacePoint(at: .init(u: u, v: v)) else { return [] }
                points.append(point)
            }
        }
        return points
    }

    private func controlPointWeights(at parameter: MeshWarpParameter) -> [Double] {
        guard columns >= 2, rows >= 2 else { return [] }
        guard controlPoints.count == columns * rows else { return [] }
        let horizontalWeights = Self.bernsteinWeights(parameter: parameter.u, count: columns)
        let verticalWeights = Self.bernsteinWeights(parameter: parameter.v, count: rows)
        var weights: [Double] = []
        weights.reserveCapacity(controlPoints.count)
        for verticalWeight in verticalWeights {
            for horizontalWeight in horizontalWeights {
                weights.append(horizontalWeight * verticalWeight)
            }
        }
        return weights
    }

    private static func bernsteinWeights(parameter: Double, count: Int) -> [Double] {
        let degree = max(count - 1, 1)
        let t = min(max(parameter, 0), 1)
        return (0...degree).map { index in
            binomialCoefficient(degree, index) *
                pow(t, Double(index)) *
                pow(1 - t, Double(degree - index))
        }
    }

    private static func binomialCoefficient(_ n: Int, _ k: Int) -> Double {
        let resolvedK = min(k, n - k)
        guard resolvedK > 0 else { return 1 }
        return (1...resolvedK).reduce(1) { result, index in
            result * Double(n - resolvedK + index) / Double(index)
        }
    }

    private static func barycentricCoordinates(
        for point: CanvasPoint,
        triangle: (CanvasPoint, CanvasPoint, CanvasPoint)
    ) -> (Double, Double, Double)? {
        let (a, b, c) = triangle
        let ab = CanvasPoint(x: b.x - a.x, y: b.y - a.y)
        let ac = CanvasPoint(x: c.x - a.x, y: c.y - a.y)
        let ap = CanvasPoint(x: point.x - a.x, y: point.y - a.y)
        let denominator = (ab.x * ac.y) - (ab.y * ac.x)
        guard abs(denominator) > 0.000_001 else { return nil }

        let weightB = ((ap.x * ac.y) - (ap.y * ac.x)) / denominator
        let weightC = ((ab.x * ap.y) - (ab.y * ap.x)) / denominator
        let weightA = 1 - weightB - weightC
        let tolerance = -0.000_1
        guard weightA >= tolerance, weightB >= tolerance, weightC >= tolerance else { return nil }
        return (weightA, weightB, weightC)
    }

    private static func interpolateParameter(
        _ weights: (Double, Double, Double),
        triangle: (MeshWarpParameter, MeshWarpParameter, MeshWarpParameter)
    ) -> MeshWarpParameter {
        let (weightA, weightB, weightC) = weights
        let (a, b, c) = triangle
        return MeshWarpParameter(
            u: (a.u * weightA) + (b.u * weightB) + (c.u * weightC),
            v: (a.v * weightA) + (b.v * weightB) + (c.v * weightC)
        )
    }
}

func updatedMeshWarpControlPointSelection(
    current: Set<Int>,
    clickedIndex: Int,
    togglesSelection: Bool
) -> Set<Int> {
    guard clickedIndex >= 0 else { return current }

    if togglesSelection {
        var next = current
        if next.contains(clickedIndex) {
            next.remove(clickedIndex)
        } else {
            next.insert(clickedIndex)
        }
        return next
    }

    return current.contains(clickedIndex) ? current : [clickedIndex]
}

struct FreeTransformHandleMetrics: Sendable, Equatable {
    var hitRadius: Double
    var rotationHandleDistance: Double
}

func freeTransformHandleMetrics(
    canvasExtent: Double,
    displayExtent: Double,
    hitRadiusDisplayPoints: Double = 14,
    rotationHandleDistanceDisplayPoints: Double = 48
) -> FreeTransformHandleMetrics {
    let canvasUnitsPerDisplayPoint = canvasExtent / max(displayExtent, 0.0001)
    return FreeTransformHandleMetrics(
        hitRadius: max(hitRadiusDisplayPoints, 0) * canvasUnitsPerDisplayPoint,
        rotationHandleDistance: max(rotationHandleDistanceDisplayPoints, 0) * canvasUnitsPerDisplayPoint
    )
}

func freeTransformTranslatedPreview(
    dragStartPoint: CanvasPoint,
    currentPoint: CanvasPoint,
    startPreview: FreeTransformPreview
) -> FreeTransformPreview {
    let delta = CanvasPoint(
        x: currentPoint.x - dragStartPoint.x,
        y: currentPoint.y - dragStartPoint.y
    )
    return FreeTransformPreview(
        translation: CanvasPoint(
            x: startPreview.translation.x + delta.x,
            y: startPreview.translation.y + delta.y
        ),
        scaleX: startPreview.scaleX,
        scaleY: startPreview.scaleY,
        rotationRadians: startPreview.rotationRadians
    )
}

func freeTransformScaleAnchorPoint(for handle: FreeTransformHandle, bounds: CanvasRect) -> CanvasPoint {
    let minX = bounds.minX
    let minY = bounds.minY
    let maxX = bounds.maxX
    let maxY = bounds.maxY
    let midX = (minX + maxX) / 2
    let midY = (minY + maxY) / 2

    switch handle {
    case .topLeft:
        return .init(x: maxX, y: maxY)
    case .top:
        return .init(x: midX, y: maxY)
    case .topRight:
        return .init(x: minX, y: maxY)
    case .right:
        return .init(x: minX, y: midY)
    case .bottomRight:
        return .init(x: minX, y: minY)
    case .bottom:
        return .init(x: midX, y: minY)
    case .bottomLeft:
        return .init(x: maxX, y: minY)
    case .left:
        return .init(x: maxX, y: midY)
    case .rotation:
        return .init(x: midX, y: midY)
    }
}

func freeTransformScaledPreview(
    bounds: CanvasRect,
    handle: FreeTransformHandle,
    dragStartPoint: CanvasPoint,
    currentPoint: CanvasPoint,
    startPreview: FreeTransformPreview,
    uniformScale: Bool
) -> FreeTransformPreview {
    let startAffine = freeTransformAffineTransform(bounds: bounds, preview: startPreview)
    let inverted = startAffine.inverted()
    let startLocal = CGPoint(x: dragStartPoint.x, y: dragStartPoint.y).applying(inverted)
    let currentLocal = CGPoint(x: currentPoint.x, y: currentPoint.y).applying(inverted)
    let anchorLocal = freeTransformScaleAnchorPoint(for: handle, bounds: bounds)
    let affectsX = [
        FreeTransformHandle.topLeft, .left, .bottomLeft, .topRight, .right, .bottomRight
    ].contains(handle)
    let affectsY = [
        FreeTransformHandle.topLeft, .top, .topRight, .bottomLeft, .bottom, .bottomRight
    ].contains(handle)

    var xRatio: Double?
    if affectsX {
        let startDistance = startLocal.x - anchorLocal.x
        let currentDistance = currentLocal.x - anchorLocal.x
        if abs(startDistance) > 0.0001 {
            xRatio = max(abs(currentDistance / startDistance), 0.05)
        }
    }

    var yRatio: Double?
    if affectsY {
        let startDistance = startLocal.y - anchorLocal.y
        let currentDistance = currentLocal.y - anchorLocal.y
        if abs(startDistance) > 0.0001 {
            yRatio = max(abs(currentDistance / startDistance), 0.05)
        }
    }

    var nextScaleX = startPreview.scaleX
    var nextScaleY = startPreview.scaleY

    if uniformScale {
        let uniformRatio: Double?
        if let xRatio, let yRatio {
            uniformRatio = abs(xRatio - 1) >= abs(yRatio - 1) ? xRatio : yRatio
        } else {
            uniformRatio = xRatio ?? yRatio
        }

        if let uniformRatio {
            nextScaleX = max(startPreview.scaleX * uniformRatio, 0.05)
            nextScaleY = max(startPreview.scaleY * uniformRatio, 0.05)
        }
    } else {
        if let xRatio {
            nextScaleX = max(startPreview.scaleX * xRatio, 0.05)
        }
        if let yRatio {
            nextScaleY = max(startPreview.scaleY * yRatio, 0.05)
        }
    }

    let anchorWorld = CGPoint(x: anchorLocal.x, y: anchorLocal.y).applying(startAffine)
    let center = CGPoint(
        x: bounds.origin.x + (bounds.size.x / 2),
        y: bounds.origin.y + (bounds.size.y / 2)
    )
    let relativeAnchor = CGPoint(x: anchorLocal.x - center.x, y: anchorLocal.y - center.y)
    let rotatedScaledAnchor = relativeAnchor
        .applying(CGAffineTransform(scaleX: nextScaleX, y: nextScaleY))
        .applying(CGAffineTransform(rotationAngle: startPreview.rotationRadians))
    let nextTranslation = CanvasPoint(
        x: anchorWorld.x - center.x - rotatedScaledAnchor.x,
        y: anchorWorld.y - center.y - rotatedScaledAnchor.y
    )

    return FreeTransformPreview(
        translation: nextTranslation,
        scaleX: nextScaleX,
        scaleY: nextScaleY,
        rotationRadians: startPreview.rotationRadians
    )
}

func shouldShowFreeTransformHandles(
    activeTool: ToolKind,
    isApplyingTransformCommit: Bool,
    isTransformingSelection: Bool,
    isFreeTransformDragging: Bool,
    activeInteractionMode: FreeTransformInteractionMode?
) -> Bool {
    guard !isApplyingTransformCommit else { return false }
    guard activeTool == .freeTransform, isTransformingSelection else { return false }
    if isFreeTransformDragging, activeInteractionMode == .move {
        return false
    }
    return true
}

struct FreeTransformPreview: Sendable, Equatable {
    var translation: CanvasPoint = .init(x: 0, y: 0)
    var scaleX: Double = 1
    var scaleY: Double = 1
    var rotationRadians: Double = 0

    static let identity = FreeTransformPreview()

    var isIdentity: Bool {
        translation.x.rounded() == 0 &&
        translation.y.rounded() == 0 &&
        abs(scaleX - 1) < 0.0001 &&
        abs(scaleY - 1) < 0.0001 &&
        abs(rotationRadians) < 0.0001
    }
}

func freeTransformAffineTransform(
    bounds: CanvasRect,
    preview: FreeTransformPreview,
    pivotBounds: CanvasRect? = nil
) -> CGAffineTransform {
    let referenceBounds = pivotBounds ?? bounds
    let center = CGPoint(
        x: referenceBounds.origin.x + (referenceBounds.size.x / 2),
        y: referenceBounds.origin.y + (referenceBounds.size.y / 2)
    )

    var transform = CGAffineTransform.identity
    transform = transform.translatedBy(
        x: center.x + preview.translation.x,
        y: center.y + preview.translation.y
    )
    transform = transform.rotated(by: preview.rotationRadians)
    transform = transform.scaledBy(x: preview.scaleX, y: preview.scaleY)
    transform = transform.translatedBy(x: -center.x, y: -center.y)
    return transform
}

func freeTransformCornerPoints(
    bounds: CanvasRect,
    preview: FreeTransformPreview,
    pivotBounds: CanvasRect? = nil
) -> [CanvasPoint] {
    let transform = freeTransformAffineTransform(
        bounds: bounds,
        preview: preview,
        pivotBounds: pivotBounds
    )
    let points = [
        CGPoint(x: bounds.minX, y: bounds.minY),
        CGPoint(x: bounds.maxX, y: bounds.minY),
        CGPoint(x: bounds.maxX, y: bounds.maxY),
        CGPoint(x: bounds.minX, y: bounds.maxY)
    ]

    return points.map {
        let transformed = $0.applying(transform)
        return .init(x: transformed.x, y: transformed.y)
    }
}

func freeTransformHandlePoints(
    bounds: CanvasRect,
    preview: FreeTransformPreview,
    rotationHandleDistance: Double = 32
) -> [FreeTransformHandle: CanvasPoint] {
    let corners = freeTransformCornerPoints(bounds: bounds, preview: preview)
    guard corners.count == 4 else { return [:] }

    let topLeft = corners[0]
    let topRight = corners[1]
    let bottomRight = corners[2]
    let bottomLeft = corners[3]

    let topMid = CanvasPoint(
        x: (topLeft.x + topRight.x) / 2,
        y: (topLeft.y + topRight.y) / 2
    )
    let rightMid = CanvasPoint(
        x: (topRight.x + bottomRight.x) / 2,
        y: (topRight.y + bottomRight.y) / 2
    )
    let bottomMid = CanvasPoint(
        x: (bottomLeft.x + bottomRight.x) / 2,
        y: (bottomLeft.y + bottomRight.y) / 2
    )
    let leftMid = CanvasPoint(
        x: (topLeft.x + bottomLeft.x) / 2,
        y: (topLeft.y + bottomLeft.y) / 2
    )

    let topEdge = CanvasPoint(x: topRight.x - topLeft.x, y: topRight.y - topLeft.y)
    let edgeLength = max(hypot(topEdge.x, topEdge.y), 0.0001)
    let outwardNormal = CanvasPoint(
        x: -topEdge.y / edgeLength,
        y: topEdge.x / edgeLength
    )
    let rotationHandle = CanvasPoint(
        x: topMid.x - (outwardNormal.x * rotationHandleDistance),
        y: topMid.y - (outwardNormal.y * rotationHandleDistance)
    )

    return [
        .topLeft: topLeft,
        .top: topMid,
        .topRight: topRight,
        .right: rightMid,
        .bottomRight: bottomRight,
        .bottom: bottomMid,
        .bottomLeft: bottomLeft,
        .left: leftMid,
        .rotation: rotationHandle
    ]
}

func freeTransformContains(
    point: CanvasPoint,
    bounds: CanvasRect,
    preview: FreeTransformPreview
) -> Bool {
    let corners = freeTransformCornerPoints(bounds: bounds, preview: preview)
    guard corners.count == 4 else { return false }

    var inside = false
    var previous = corners[corners.count - 1]
    for current in corners {
        let deltaY = previous.y - current.y
        let safeDeltaY = abs(deltaY) < 0.000001 ? 0.000001 : deltaY
        let intersects = ((current.y > point.y) != (previous.y > point.y)) &&
            (point.x < ((previous.x - current.x) * (point.y - current.y) / safeDeltaY) + current.x)
        if intersects {
            inside.toggle()
        }
        previous = current
    }
    return inside
}

func freeTransformInteractionMode(
    point: CanvasPoint,
    bounds: CanvasRect?,
    preview: FreeTransformPreview,
    handleRadius: Double,
    rotationHandleDistance: Double
) -> FreeTransformInteractionMode {
    guard let bounds else {
        return .move
    }

    let handlePoints = freeTransformHandlePoints(
        bounds: bounds,
        preview: preview,
        rotationHandleDistance: rotationHandleDistance
    )

    if let rotationPoint = handlePoints[.rotation],
       hypot(rotationPoint.x - point.x, rotationPoint.y - point.y) <= handleRadius {
        return .rotate
    }

    for handle in FreeTransformHandle.allCases where handle != .rotation {
        if let handlePoint = handlePoints[handle],
           hypot(handlePoint.x - point.x, handlePoint.y - point.y) <= handleRadius {
            return .scale(handle)
        }
    }

    if freeTransformContains(point: point, bounds: bounds, preview: preview) {
        return .move
    }

    return .move
}

func meshWarpInteractionMode(
    point: CanvasPoint,
    grid: MeshWarpGrid?,
    handleRadius: Double
) -> FreeTransformInteractionMode {
    guard let grid else { return .move }
    if let index = grid.nearestCornerControlPoint(to: point, radius: handleRadius) {
        return .meshPoint(index)
    }
    if let parameter = grid.surfaceParameter(containing: point) {
        return .meshArea(parameter)
    }
    return .move
}

struct TransformInteractionState: Sendable, Equatable {
    var dragStartPoint: CanvasPoint?
    var accumulatedOffset: CanvasPoint = .init(x: 0, y: 0)
    var isActive = false
    var interactionMode: FreeTransformInteractionMode = .move
    var preview = FreeTransformPreview.identity
    var dragStartPreview = FreeTransformPreview.identity
    var meshWarpGrid: MeshWarpGrid?
    var dragStartMeshWarpGrid: MeshWarpGrid?

    var hasPendingOffset: Bool {
        accumulatedOffset.x.rounded() != 0 || accumulatedOffset.y.rounded() != 0
    }

    var hasPendingTransform: Bool {
        !preview.isIdentity || meshWarpGrid?.isIdentity == false
    }

    mutating func beginSession(at point: CanvasPoint, mode: FreeTransformInteractionMode = .move) {
        isActive = true
        dragStartPoint = point
        interactionMode = mode
        dragStartPreview = preview
        dragStartMeshWarpGrid = meshWarpGrid
    }

    mutating func beginDrag(at point: CanvasPoint, mode: FreeTransformInteractionMode = .move) {
        dragStartPoint = point
        interactionMode = mode
        dragStartPreview = preview
        dragStartMeshWarpGrid = meshWarpGrid
    }

    mutating func finishDrag(at point: CanvasPoint) -> CanvasPoint {
        guard let dragStartPoint else {
            return .init(x: 0, y: 0)
        }

        let delta = CanvasPoint(
            x: (point.x - dragStartPoint.x).rounded(),
            y: (point.y - dragStartPoint.y).rounded()
        )

        self.dragStartPoint = nil
        if case .move = interactionMode {
            preview.translation = CanvasPoint(
                x: dragStartPreview.translation.x + delta.x,
                y: dragStartPreview.translation.y + delta.y
            )
            accumulatedOffset = preview.translation
        }
        return delta
    }

    mutating func endInteraction() {
        dragStartPoint = nil
        dragStartPreview = preview
        dragStartMeshWarpGrid = meshWarpGrid
    }

    func clearBehavior() -> TransformClearBehavior {
        guard isActive else { return .none }
        return hasPendingTransform ? .apply : .cancel
    }

    func resolutionAction(for reason: TransformResolutionReason) -> TransformResolutionAction {
        guard isActive else { return .none }

        switch reason {
        case .toolChange, .layerChange:
            return hasPendingTransform ? .applyAndClearSelection : .cancelAndClearSelection
        case .historyNavigation:
            return .cancelAndPreserveSelection
        case .documentOpen:
            return .cancelAndClearSelection
        }
    }

    mutating func reset() {
        dragStartPoint = nil
        accumulatedOffset = .init(x: 0, y: 0)
        interactionMode = .move
        preview = .identity
        dragStartPreview = .identity
        meshWarpGrid = nil
        dragStartMeshWarpGrid = nil
        isActive = false
    }
}

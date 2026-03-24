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
    preview: FreeTransformPreview
) -> CGAffineTransform {
    let center = CGPoint(
        x: bounds.origin.x + (bounds.size.x / 2),
        y: bounds.origin.y + (bounds.size.y / 2)
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
    preview: FreeTransformPreview
) -> [CanvasPoint] {
    let transform = freeTransformAffineTransform(bounds: bounds, preview: preview)
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

struct TransformInteractionState: Sendable, Equatable {
    var dragStartPoint: CanvasPoint?
    var accumulatedOffset: CanvasPoint = .init(x: 0, y: 0)
    var isActive = false
    var interactionMode: FreeTransformInteractionMode = .move
    var preview = FreeTransformPreview.identity
    var dragStartPreview = FreeTransformPreview.identity

    var hasPendingOffset: Bool {
        accumulatedOffset.x.rounded() != 0 || accumulatedOffset.y.rounded() != 0
    }

    var hasPendingTransform: Bool {
        !preview.isIdentity
    }

    mutating func beginSession(at point: CanvasPoint, mode: FreeTransformInteractionMode = .move) {
        isActive = true
        dragStartPoint = point
        interactionMode = mode
        dragStartPreview = preview
    }

    mutating func beginDrag(at point: CanvasPoint, mode: FreeTransformInteractionMode = .move) {
        dragStartPoint = point
        interactionMode = mode
        dragStartPreview = preview
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
        isActive = false
    }
}

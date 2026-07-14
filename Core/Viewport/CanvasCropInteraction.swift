import Foundation

enum CanvasCropHandle: String, CaseIterable, Sendable {
    case topLeft
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left
}

enum CanvasCropDragMode: Sendable, Equatable {
    case create
    case move
    case resize(CanvasCropHandle)
}

struct CanvasCropInteractionState: Sendable, Equatable {
    var bounds: CanvasRect?
    var dragMode: CanvasCropDragMode?
    var dragStartPoint: CanvasPoint?
    var dragStartBounds: CanvasRect?

    var isDragging: Bool {
        dragMode != nil
    }

    mutating func begin(
        at rawPoint: CanvasPoint,
        canvasSize: CanvasSize,
        handleRadius: Double
    ) {
        let point = pixelAligned(rawPoint)
        dragStartPoint = point
        dragStartBounds = bounds

        if let bounds,
           let handle = hitHandle(at: point, bounds: bounds, radius: max(handleRadius, 1)) {
            dragMode = .resize(handle)
            return
        }
        if let bounds, bounds.contains(point) {
            dragMode = .move
            return
        }

        dragMode = .create
        dragStartBounds = nil
        bounds = CanvasRect(origin: point, size: .init(x: 0, y: 0))
    }

    mutating func update(to rawPoint: CanvasPoint, canvasSize: CanvasSize) {
        guard let dragMode, let dragStartPoint else { return }
        let point = pixelAligned(rawPoint)

        switch dragMode {
        case .create:
            bounds = CanvasRect.fromPoints(dragStartPoint, point)
        case .move:
            guard let startBounds = dragStartBounds else { return }
            let deltaX = point.x - dragStartPoint.x
            let deltaY = point.y - dragStartPoint.y
            bounds = CanvasRect(
                origin: CanvasPoint(
                    x: startBounds.minX + deltaX,
                    y: startBounds.minY + deltaY
                ),
                size: startBounds.size
            )
        case .resize(let handle):
            guard let startBounds = dragStartBounds else { return }
            bounds = resizedBounds(
                startBounds,
                handle: handle,
                point: point
            )
        }
    }

    mutating func end(at point: CanvasPoint, canvasSize: CanvasSize) {
        update(to: point, canvasSize: canvasSize)
        dragMode = nil
        dragStartPoint = nil
        dragStartBounds = nil
        if let bounds, bounds.size.x < 1 || bounds.size.y < 1 {
            self.bounds = CanvasRect(
                origin: .init(x: 0, y: 0),
                size: .init(x: Double(canvasSize.width), y: Double(canvasSize.height))
            )
        }
    }

    mutating func cancel() {
        self = .init()
    }

    func pixelBounds(in _: CanvasSize) -> CanvasRect? {
        guard let bounds else { return nil }
        let resolved = CanvasRect(
            origin: CanvasPoint(x: bounds.minX.rounded(), y: bounds.minY.rounded()),
            size: CanvasPoint(
                x: (bounds.maxX - bounds.minX).rounded(),
                y: (bounds.maxY - bounds.minY).rounded()
            )
        )
        guard resolved.size.x >= 1, resolved.size.y >= 1 else { return nil }
        return resolved
    }

    private func resizedBounds(
        _ start: CanvasRect,
        handle: CanvasCropHandle,
        point: CanvasPoint
    ) -> CanvasRect {
        var minX = start.minX
        var minY = start.minY
        var maxX = start.maxX
        var maxY = start.maxY

        switch handle {
        case .topLeft:
            minX = point.x
            minY = point.y
        case .top:
            minY = point.y
        case .topRight:
            maxX = point.x
            minY = point.y
        case .right:
            maxX = point.x
        case .bottomRight:
            maxX = point.x
            maxY = point.y
        case .bottom:
            maxY = point.y
        case .bottomLeft:
            minX = point.x
            maxY = point.y
        case .left:
            minX = point.x
        }

        if minX > maxX { swap(&minX, &maxX) }
        if minY > maxY { swap(&minY, &maxY) }
        if maxX - minX < 1 { maxX = minX + 1 }
        if maxY - minY < 1 { maxY = minY + 1 }
        return CanvasRect(
            origin: CanvasPoint(x: minX, y: minY),
            size: CanvasPoint(x: maxX - minX, y: maxY - minY)
        )
    }

    private func hitHandle(
        at point: CanvasPoint,
        bounds: CanvasRect,
        radius: Double
    ) -> CanvasCropHandle? {
        let midX = (bounds.minX + bounds.maxX) / 2
        let midY = (bounds.minY + bounds.maxY) / 2
        let points: [(CanvasCropHandle, CanvasPoint)] = [
            (.topLeft, .init(x: bounds.minX, y: bounds.minY)),
            (.top, .init(x: midX, y: bounds.minY)),
            (.topRight, .init(x: bounds.maxX, y: bounds.minY)),
            (.right, .init(x: bounds.maxX, y: midY)),
            (.bottomRight, .init(x: bounds.maxX, y: bounds.maxY)),
            (.bottom, .init(x: midX, y: bounds.maxY)),
            (.bottomLeft, .init(x: bounds.minX, y: bounds.maxY)),
            (.left, .init(x: bounds.minX, y: midY))
        ]
        return points.first { _, handlePoint in
            let dx = point.x - handlePoint.x
            let dy = point.y - handlePoint.y
            return (dx * dx) + (dy * dy) <= radius * radius
        }?.0
    }

    private func pixelAligned(_ point: CanvasPoint) -> CanvasPoint {
        CanvasPoint(x: point.x.rounded(), y: point.y.rounded())
    }
}

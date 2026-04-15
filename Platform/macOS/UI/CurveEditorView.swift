import AppKit
import SwiftUI

struct CurveEditorView: NSViewRepresentable {
    var state: CurveChannelState
    var isEnabled: Bool
    var onChange: (CurveChannelState) -> Void

    func makeNSView(context: Context) -> CurveEditorNSView {
        let view = CurveEditorNSView()
        view.update(state: state, isEnabled: isEnabled, onChange: onChange)
        return view
    }

    func updateNSView(_ nsView: CurveEditorNSView, context: Context) {
        nsView.update(state: state, isEnabled: isEnabled, onChange: onChange)
    }
}

final class CurveEditorNSView: NSView {
    private let graphInset: CGFloat = 12
    private let gridDivisions = 4
    private let pointHitRadius: CGFloat = 8
    private let curveHitDistance: CGFloat = 12

    private var channelState: CurveChannelState = .identity
    private var isEditorEnabled = true
    private var onChange: ((CurveChannelState) -> Void)?
    private var selectedPointIndex: Int?
    private var draggingPointIndex: Int?
    private var contextualMenuPointIndex: Int?

    override var acceptsFirstResponder: Bool { true }

    func update(
        state: CurveChannelState,
        isEnabled: Bool,
        onChange: @escaping (CurveChannelState) -> Void
    ) {
        channelState = state
        isEditorEnabled = isEnabled
        self.onChange = onChange
        if let selectedPointIndex, !state.points.indices.contains(selectedPointIndex) {
            self.selectedPointIndex = nil
            draggingPointIndex = nil
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let context = NSGraphicsContext.current?.cgContext
        let drawBounds = bounds.insetBy(dx: 0.5, dy: 0.5)
        let graphRect = graphBounds

        NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
        dirtyRect.fill()

        let panelPath = NSBezierPath(roundedRect: drawBounds, xRadius: 10, yRadius: 10)
        NSColor.white.withAlphaComponent(0.06).setFill()
        panelPath.fill()
        NSColor.white.withAlphaComponent(0.08).setStroke()
        panelPath.lineWidth = 1
        panelPath.stroke()

        context?.saveGState()

        let gridPath = NSBezierPath()
        for index in 0...gridDivisions {
            let progress = CGFloat(index) / CGFloat(gridDivisions)
            let x = graphRect.minX + (graphRect.width * progress)
            gridPath.move(to: CGPoint(x: x, y: graphRect.minY))
            gridPath.line(to: CGPoint(x: x, y: graphRect.maxY))

            let y = graphRect.minY + (graphRect.height * progress)
            gridPath.move(to: CGPoint(x: graphRect.minX, y: y))
            gridPath.line(to: CGPoint(x: graphRect.maxX, y: y))
        }
        NSColor.white.withAlphaComponent(0.10).setStroke()
        gridPath.lineWidth = 1
        gridPath.stroke()

        let diagonalPath = NSBezierPath()
        diagonalPath.move(to: CGPoint(x: graphRect.minX, y: graphRect.minY))
        diagonalPath.line(to: CGPoint(x: graphRect.maxX, y: graphRect.maxY))
        NSColor.white.withAlphaComponent(0.18).setStroke()
        diagonalPath.lineWidth = 1
        diagonalPath.stroke()

        let curvePath = sampledCurvePath(in: graphRect)
        NSColor.white.withAlphaComponent(isEditorEnabled ? 0.96 : 0.36).setStroke()
        curvePath.lineWidth = 2
        curvePath.stroke()

        for (index, point) in channelState.points.enumerated() {
            let viewPoint = viewPoint(for: point, in: graphRect)
            let isSelected = selectedPointIndex == index
            let rect = CGRect(x: viewPoint.x - 4.5, y: viewPoint.y - 4.5, width: 9, height: 9)
            let circle = NSBezierPath(ovalIn: rect)
            let fillColor: NSColor = isSelected
                ? NSColor.controlAccentColor
                : NSColor.white.withAlphaComponent(isEditorEnabled ? 0.94 : 0.34)
            fillColor.setFill()
            circle.fill()
            NSColor.black.withAlphaComponent(isSelected ? 0.18 : 0.34).setStroke()
            circle.lineWidth = 1
            circle.stroke()
        }

        if !isEditorEnabled {
            NSColor.black.withAlphaComponent(0.18).setFill()
            graphRect.fill()
        }

        context?.restoreGState()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEditorEnabled else { return }
        window?.makeFirstResponder(self)

        let clickPoint = convert(event.locationInWindow, from: nil)
        let graphRect = graphBounds
        guard graphRect.contains(clickPoint) else {
            selectedPointIndex = nil
            draggingPointIndex = nil
            needsDisplay = true
            return
        }

        if let hitIndex = hitPointIndex(at: clickPoint, in: graphRect) {
            selectedPointIndex = hitIndex
            if event.clickCount >= 2, hitIndex != 0, hitIndex != channelState.points.count - 1 {
                channelState = channelState.removingPoint(at: hitIndex)
                selectedPointIndex = nil
                draggingPointIndex = nil
                onChange?(channelState)
            } else {
                draggingPointIndex = hitIndex
            }
            needsDisplay = true
            return
        }

        let normalizedPoint = normalizedPoint(for: clickPoint, in: graphRect)
        if distanceToCurve(from: clickPoint, in: graphRect) <= curveHitDistance,
           let insertion = channelState.insertingPoint(normalizedPoint) {
            channelState = insertion.state
            selectedPointIndex = insertion.insertedIndex
            draggingPointIndex = insertion.insertedIndex
            onChange?(channelState)
            needsDisplay = true
            return
        }

        selectedPointIndex = nil
        draggingPointIndex = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEditorEnabled else { return }
        guard let draggingPointIndex else { return }

        let point = convert(event.locationInWindow, from: nil)
        let nextState = channelState.movingPoint(
            at: draggingPointIndex,
            to: normalizedPoint(for: point, in: graphBounds)
        )
        guard nextState != channelState else { return }
        channelState = nextState
        selectedPointIndex = draggingPointIndex
        onChange?(channelState)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        draggingPointIndex = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard isEditorEnabled else { return nil }
        let clickPoint = convert(event.locationInWindow, from: nil)
        let graphRect = graphBounds
        guard graphRect.contains(clickPoint) else { return nil }

        let targetIndex = hitPointIndex(at: clickPoint, in: graphRect) ?? selectedPointIndex
        guard let targetIndex,
              targetIndex != 0,
              targetIndex != channelState.points.count - 1 else {
            return nil
        }

        window?.makeFirstResponder(self)
        selectedPointIndex = targetIndex
        draggingPointIndex = nil
        contextualMenuPointIndex = targetIndex
        needsDisplay = true

        let menu = NSMenu(title: "曲线锚点")
        let deleteItem = NSMenuItem(
            title: "删除锚点",
            action: #selector(deleteContextualMenuPoint),
            keyEquivalent: ""
        )
        deleteItem.target = self
        menu.addItem(deleteItem)
        return menu
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            if deleteSelectedIntermediatePoint() {
                return
            }
            super.keyDown(with: event)
            return
        }

        super.keyDown(with: event)
    }

    @objc
    private func deleteContextualMenuPoint(_ sender: Any?) {
        guard let contextualMenuPointIndex else { return }
        deletePoint(at: contextualMenuPointIndex)
        self.contextualMenuPointIndex = nil
    }

    private var graphBounds: CGRect {
        bounds.insetBy(dx: graphInset, dy: graphInset)
    }

    private func hitPointIndex(at point: CGPoint, in rect: CGRect) -> Int? {
        channelState.points.firstIndex { controlPoint in
            hypot(viewPoint(for: controlPoint, in: rect).x - point.x, viewPoint(for: controlPoint, in: rect).y - point.y) <= pointHitRadius
        }
    }

    private func normalizedPoint(for point: CGPoint, in rect: CGRect) -> CurveControlPoint {
        let x = Float((point.x - rect.minX) / max(rect.width, 1))
        let y = Float((point.y - rect.minY) / max(rect.height, 1))
        return CurveControlPoint(x: x, y: y)
    }

    private func viewPoint(for point: CurveControlPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + (CGFloat(point.x) * rect.width),
            y: rect.minY + (CGFloat(point.y) * rect.height)
        )
    }

    private func sampledCurvePath(in rect: CGRect) -> NSBezierPath {
        let path = NSBezierPath()
        let sampleCount = 128
        for sampleIndex in 0..<sampleCount {
            let x = Float(sampleIndex) / Float(sampleCount - 1)
            let point = CGPoint(
                x: rect.minX + (CGFloat(x) * rect.width),
                y: rect.minY + (CGFloat(sampledValue(at: x)) * rect.height)
            )
            if sampleIndex == 0 {
                path.move(to: point)
            } else {
                path.line(to: point)
            }
        }
        return path
    }

    private func sampledValue(at x: Float) -> Float {
        let points = channelState.points
        guard points.count >= 2 else { return x }
        if x <= points[0].x {
            return points[0].y
        }
        if let last = points.last, x >= last.x {
            return last.y
        }

        for index in 0..<(points.count - 1) {
            let start = points[index]
            let end = points[index + 1]
            if x >= start.x && x <= end.x {
                let span = max(end.x - start.x, 0.0001)
                let t = (x - start.x) / span
                return start.y + ((end.y - start.y) * t)
            }
        }
        return points.last?.y ?? x
    }

    private func distanceToCurve(from point: CGPoint, in rect: CGRect) -> CGFloat {
        let sampleCount = 64
        var previousPoint: CGPoint?
        var bestDistance = CGFloat.greatestFiniteMagnitude

        for sampleIndex in 0..<sampleCount {
            let x = Float(sampleIndex) / Float(sampleCount - 1)
            let currentPoint = CGPoint(
                x: rect.minX + (CGFloat(x) * rect.width),
                y: rect.minY + (CGFloat(sampledValue(at: x)) * rect.height)
            )
            if let previousPoint {
                bestDistance = min(bestDistance, distance(from: point, toSegmentStart: previousPoint, end: currentPoint))
            }
            previousPoint = currentPoint
        }

        return bestDistance
    }

    private func distance(from point: CGPoint, toSegmentStart start: CGPoint, end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = (dx * dx) + (dy * dy)
        guard lengthSquared > 0.0001 else {
            return hypot(point.x - start.x, point.y - start.y)
        }

        let t = max(0, min(1, (((point.x - start.x) * dx) + ((point.y - start.y) * dy)) / lengthSquared))
        let projection = CGPoint(x: start.x + (dx * t), y: start.y + (dy * t))
        return hypot(point.x - projection.x, point.y - projection.y)
    }

    @discardableResult
    private func deleteSelectedIntermediatePoint() -> Bool {
        guard let selectedPointIndex else { return false }
        return deletePoint(at: selectedPointIndex)
    }

    @discardableResult
    private func deletePoint(at index: Int) -> Bool {
        guard index != 0, index != channelState.points.count - 1 else { return false }
        guard channelState.points.indices.contains(index) else { return false }
        channelState = channelState.removingPoint(at: index)
        selectedPointIndex = nil
        draggingPointIndex = nil
        contextualMenuPointIndex = nil
        onChange?(channelState)
        needsDisplay = true
        return true
    }
}

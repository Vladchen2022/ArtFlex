import AppKit
import SwiftUI

enum CurveEditorAppearance {
    case dark
    case light
}

struct CurveEditorView: NSViewRepresentable {
    var state: CurveChannelState
    var isEnabled: Bool
    var appearance: CurveEditorAppearance = .dark
    var allowsEndpointMovement: Bool = true
    var allowsPointInsertion: Bool = true
    var allowsPointRemoval: Bool = true
    var onEditingChanged: (Bool) -> Void = { _ in }
    var onChange: (CurveChannelState) -> Void

    func makeNSView(context: Context) -> CurveEditorNSView {
        let view = CurveEditorNSView()
        view.update(
            state: state,
            isEnabled: isEnabled,
            appearance: appearance,
            allowsEndpointMovement: allowsEndpointMovement,
            allowsPointInsertion: allowsPointInsertion,
            allowsPointRemoval: allowsPointRemoval,
            onEditingChanged: onEditingChanged,
            onChange: onChange
        )
        return view
    }

    func updateNSView(_ nsView: CurveEditorNSView, context: Context) {
        nsView.update(
            state: state,
            isEnabled: isEnabled,
            appearance: appearance,
            allowsEndpointMovement: allowsEndpointMovement,
            allowsPointInsertion: allowsPointInsertion,
            allowsPointRemoval: allowsPointRemoval,
            onEditingChanged: onEditingChanged,
            onChange: onChange
        )
    }
}

final class CurveEditorNSView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // macOS 14+ defaults to false; a scrolled-off curve must not paint
        // its dirty rectangle over sibling controls in the hosting view.
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        clipsToBounds = true
    }

    private let graphInset: CGFloat = 12
    private let gridDivisions = 4
    private let pointHitRadius: CGFloat = 8
    private let curveHitDistance: CGFloat = 12

    private var channelState: CurveChannelState = .identity
    private var isEditorEnabled = true
    private var editorAppearance: CurveEditorAppearance = .dark
    private var allowsEndpointMovement = true
    private var allowsPointInsertion = true
    private var allowsPointRemoval = true
    private var onChange: ((CurveChannelState) -> Void)?
    private var onEditingChanged: ((Bool) -> Void)?
    private var selectedPointIndex: Int?
    private var draggingPointIndex: Int?
    private var contextualMenuPointIndex: Int?

    override var acceptsFirstResponder: Bool { true }

    func update(
        state: CurveChannelState,
        isEnabled: Bool,
        appearance: CurveEditorAppearance,
        allowsEndpointMovement: Bool,
        allowsPointInsertion: Bool,
        allowsPointRemoval: Bool,
        onEditingChanged: @escaping (Bool) -> Void = { _ in },
        onChange: @escaping (CurveChannelState) -> Void
    ) {
        channelState = state
        isEditorEnabled = isEnabled
        self.editorAppearance = appearance
        self.allowsEndpointMovement = allowsEndpointMovement
        self.allowsPointInsertion = allowsPointInsertion
        self.allowsPointRemoval = allowsPointRemoval
        self.onChange = onChange
        self.onEditingChanged = onEditingChanged
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

        colors.background.setFill()
        bounds.fill()

        let panelPath = NSBezierPath(roundedRect: drawBounds, xRadius: 10, yRadius: 10)
        colors.panelFill.setFill()
        panelPath.fill()
        colors.panelStroke.setStroke()
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
        colors.grid.setStroke()
        gridPath.lineWidth = 1
        gridPath.stroke()

        let diagonalPath = NSBezierPath()
        diagonalPath.move(to: CGPoint(x: graphRect.minX, y: graphRect.minY))
        diagonalPath.line(to: CGPoint(x: graphRect.maxX, y: graphRect.maxY))
        colors.diagonal.setStroke()
        diagonalPath.lineWidth = 1
        diagonalPath.stroke()

        let curvePath = sampledCurvePath(in: graphRect)
        colors.curve(isEnabled: isEditorEnabled).setStroke()
        curvePath.lineWidth = 2
        curvePath.stroke()

        for (index, point) in channelState.points.enumerated() {
            let viewPoint = viewPoint(for: point, in: graphRect)
            let isSelected = selectedPointIndex == index
            let rect = CGRect(x: viewPoint.x - 4.5, y: viewPoint.y - 4.5, width: 9, height: 9)
            let circle = NSBezierPath(ovalIn: rect)
            let fillColor: NSColor = isSelected
                ? NSColor.controlAccentColor
                : colors.pointFill(isEnabled: isEditorEnabled)
            fillColor.setFill()
            circle.fill()
            colors.pointStroke(isSelected: isSelected).setStroke()
            circle.lineWidth = 1
            circle.stroke()
        }

        if !isEditorEnabled {
            colors.disabledOverlay.setFill()
            graphRect.fill()
        }

        context?.restoreGState()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEditorEnabled else { return }
        window?.makeFirstResponder(self)

        let clickPoint = convert(event.locationInWindow, from: nil)
        let graphRect = graphBounds
        if let hitIndex = hitPointIndex(at: clickPoint, in: graphRect) {
            onEditingChanged?(true)
            selectedPointIndex = hitIndex
            if allowsPointRemoval,
               event.clickCount >= 2,
               hitIndex != 0,
               hitIndex != channelState.points.count - 1 {
                channelState = channelState.removingPoint(at: hitIndex)
                selectedPointIndex = nil
                draggingPointIndex = nil
                onChange?(channelState)
                onEditingChanged?(false)
            } else {
                draggingPointIndex = hitIndex
            }
            needsDisplay = true
            return
        }

        // Endpoint handles straddle the graph border. Hit-test the whole
        // handle before rejecting empty space outside the plotting area.
        guard graphRect.contains(clickPoint) else {
            selectedPointIndex = nil
            draggingPointIndex = nil
            needsDisplay = true
            return
        }

        let normalizedPoint = normalizedPoint(for: clickPoint, in: graphRect)
        if allowsPointInsertion,
           distanceToCurve(from: clickPoint, in: graphRect) <= curveHitDistance,
           let insertion = channelState.insertingPoint(normalizedPoint) {
            onEditingChanged?(true)
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
        if !allowsEndpointMovement,
           (draggingPointIndex == 0 || draggingPointIndex == channelState.points.count - 1) {
            return
        }

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
        if draggingPointIndex != nil { onEditingChanged?(false) }
        draggingPointIndex = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard isEditorEnabled, allowsPointRemoval else { return nil }
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
        CurveLUTBuilder.sampleChannelValue(from: channelState, at: x)
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
        onEditingChanged?(true)
        channelState = channelState.removingPoint(at: index)
        selectedPointIndex = nil
        draggingPointIndex = nil
        contextualMenuPointIndex = nil
        onChange?(channelState)
        onEditingChanged?(false)
        needsDisplay = true
        return true
    }

    private var colors: CurveEditorPalette {
        switch editorAppearance {
        case .dark:
            return CurveEditorPalette(
                background: NSColor(calibratedWhite: 0.10, alpha: 1),
                panelFill: NSColor.white.withAlphaComponent(0.06),
                panelStroke: NSColor.white.withAlphaComponent(0.08),
                grid: NSColor.white.withAlphaComponent(0.10),
                diagonal: NSColor.white.withAlphaComponent(0.18),
                curveEnabled: NSColor.white.withAlphaComponent(0.96),
                curveDisabled: NSColor.white.withAlphaComponent(0.36),
                pointEnabled: NSColor.white.withAlphaComponent(0.94),
                pointDisabled: NSColor.white.withAlphaComponent(0.34),
                pointStrokeSelected: NSColor.black.withAlphaComponent(0.18),
                pointStrokeNormal: NSColor.black.withAlphaComponent(0.34),
                disabledOverlay: NSColor.black.withAlphaComponent(0.18)
            )
        case .light:
            return CurveEditorPalette(
                background: NSColor(calibratedWhite: 0.96, alpha: 1),
                panelFill: NSColor.white,
                panelStroke: NSColor.black.withAlphaComponent(0.08),
                grid: NSColor.black.withAlphaComponent(0.08),
                diagonal: NSColor.black.withAlphaComponent(0.12),
                curveEnabled: NSColor.controlAccentColor.withAlphaComponent(0.96),
                curveDisabled: NSColor.controlAccentColor.withAlphaComponent(0.36),
                pointEnabled: NSColor.white,
                pointDisabled: NSColor(calibratedWhite: 0.90, alpha: 1),
                pointStrokeSelected: NSColor.controlAccentColor.withAlphaComponent(0.68),
                pointStrokeNormal: NSColor.black.withAlphaComponent(0.18),
                disabledOverlay: NSColor.white.withAlphaComponent(0.36)
            )
        }
    }
}

private struct CurveEditorPalette {
    let background: NSColor
    let panelFill: NSColor
    let panelStroke: NSColor
    let grid: NSColor
    let diagonal: NSColor
    let curveEnabled: NSColor
    let curveDisabled: NSColor
    let pointEnabled: NSColor
    let pointDisabled: NSColor
    let pointStrokeSelected: NSColor
    let pointStrokeNormal: NSColor
    let disabledOverlay: NSColor

    func curve(isEnabled: Bool) -> NSColor {
        isEnabled ? curveEnabled : curveDisabled
    }

    func pointFill(isEnabled: Bool) -> NSColor {
        isEnabled ? pointEnabled : pointDisabled
    }

    func pointStroke(isSelected: Bool) -> NSColor {
        isSelected ? pointStrokeSelected : pointStrokeNormal
    }
}

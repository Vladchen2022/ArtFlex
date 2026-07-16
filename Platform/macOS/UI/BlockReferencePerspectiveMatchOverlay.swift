import SwiftUI

struct BlockReferencePerspectiveMatchOverlay: View {
    let state: BlockReferencePerspectiveMatchState
    let transform: CanvasViewportTransform

    var body: some View {
        Canvas { context, size in
            let documentPath = Path { path in
                let corners = [
                    CanvasPoint(x: 0, y: 0),
                    CanvasPoint(x: Double(transform.canvasSize.width), y: 0),
                    CanvasPoint(
                        x: Double(transform.canvasSize.width),
                        y: Double(transform.canvasSize.height)
                    ),
                    CanvasPoint(x: 0, y: Double(transform.canvasSize.height))
                ].map(transform.canvasToViewport)
                guard let first = corners.first else { return }
                path.move(to: CGPoint(x: first.x, y: first.y))
                for corner in corners.dropFirst() {
                    path.addLine(to: CGPoint(x: corner.x, y: corner.y))
                }
                path.closeSubpath()
            }
            var clipped = context
            clipped.clip(to: documentPath)

            for line in state.lines {
                draw(line, in: clipped, isDraft: false)
            }
            if let draft = state.draftLine {
                draw(draft, in: clipped, isDraft: true)
            }
            for axis in BlockReferenceAxis.allCases {
                guard let point = state.vanishingPoint(for: axis) else { continue }
                drawVanishingPoint(point, axis: axis, in: context, size: size)
            }
            if let anchor = state.resolvedPlaneAnchor(canvasSize: transform.canvasSize) {
                drawPlaneAnchor(anchor, in: context)
            }
        }
    }

    private func drawPlaneAnchor(_ point: CanvasPoint, in context: GraphicsContext) {
        let viewport = transform.canvasToViewport(point)
        let color = Color.cyan
        let outer = CGRect(x: viewport.x - 10, y: viewport.y - 10, width: 20, height: 20)
        context.fill(Path(ellipseIn: outer), with: .color(Color.black.opacity(0.72)))
        context.stroke(Path(ellipseIn: outer), with: .color(color), lineWidth: 2.2)
        var cross = Path()
        cross.move(to: CGPoint(x: viewport.x - 14, y: viewport.y))
        cross.addLine(to: CGPoint(x: viewport.x + 14, y: viewport.y))
        cross.move(to: CGPoint(x: viewport.x, y: viewport.y - 14))
        cross.addLine(to: CGPoint(x: viewport.x, y: viewport.y + 14))
        context.stroke(cross, with: .color(color.opacity(0.95)), lineWidth: 1.5)
        context.draw(
            Text(state.planeAnchor == nil ? "自动工作面中心" : "工作面中心")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.white),
            at: CGPoint(x: viewport.x, y: viewport.y - 22)
        )
    }

    private func draw(
        _ line: BlockReferencePerspectiveMatchLine,
        in context: GraphicsContext,
        isDraft: Bool
    ) {
        let color = axisColor(line.axis)
        let dx = line.end.x - line.start.x
        let dy = line.end.y - line.start.y
        let length = hypot(dx, dy)
        guard length > 0.000_001 else { return }
        let directionX = dx / length
        let directionY = dy / length
        let extent = Double(max(transform.canvasSize.width, transform.canvasSize.height)) * 4
        let extensionStart = transform.canvasToViewport(CanvasPoint(
            x: line.start.x - directionX * extent,
            y: line.start.y - directionY * extent
        ))
        let extensionEnd = transform.canvasToViewport(CanvasPoint(
            x: line.start.x + directionX * extent,
            y: line.start.y + directionY * extent
        ))
        var extensionPath = Path()
        extensionPath.move(to: CGPoint(x: extensionStart.x, y: extensionStart.y))
        extensionPath.addLine(to: CGPoint(x: extensionEnd.x, y: extensionEnd.y))
        context.stroke(
            extensionPath,
            with: .color(color.opacity(isDraft ? 0.38 : 0.24)),
            style: StrokeStyle(lineWidth: 1.2, dash: [7, 5])
        )

        let start = transform.canvasToViewport(line.start)
        let end = transform.canvasToViewport(line.end)
        var segment = Path()
        segment.move(to: CGPoint(x: start.x, y: start.y))
        segment.addLine(to: CGPoint(x: end.x, y: end.y))
        context.stroke(
            segment,
            with: .color(color.opacity(isDraft ? 0.72 : 0.96)),
            style: StrokeStyle(lineWidth: isDraft ? 2 : 2.8, lineCap: .round)
        )

        for point in [start, end] {
            let handle = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
            context.fill(Path(ellipseIn: handle), with: .color(Color.black.opacity(0.72)))
            context.stroke(Path(ellipseIn: handle), with: .color(color), lineWidth: 1.5)
        }
        let midpoint = CGPoint(x: (start.x + end.x) * 0.5, y: (start.y + end.y) * 0.5)
        context.draw(
            Text(line.axis.displayName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.white),
            at: midpoint
        )
    }

    private func drawVanishingPoint(
        _ point: CanvasPoint,
        axis: BlockReferenceAxis,
        in context: GraphicsContext,
        size: CGSize
    ) {
        let viewport = transform.canvasToViewport(point)
        guard viewport.x >= -18, viewport.x <= size.width + 18,
              viewport.y >= -18, viewport.y <= size.height + 18 else { return }
        let color = axisColor(axis)
        let rect = CGRect(x: viewport.x - 8, y: viewport.y - 8, width: 16, height: 16)
        context.fill(Path(ellipseIn: rect), with: .color(Color.black.opacity(0.78)))
        context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: 2)
        context.draw(
            Text("\(axis.displayName) 消失点")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.white),
            at: CGPoint(x: viewport.x, y: viewport.y - 16)
        )
    }

    private func axisColor(_ axis: BlockReferenceAxis) -> Color {
        switch axis {
        case .x: return Color(red: 0.98, green: 0.24, blue: 0.2)
        case .y: return Color(red: 0.18, green: 0.82, blue: 0.34)
        case .z: return Color(red: 0.2, green: 0.52, blue: 1)
        }
    }
}

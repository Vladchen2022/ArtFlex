import SwiftUI

struct PerspectiveGuideMatchOverlay: View {
    let state: PerspectiveGuideMatchState
    let candidate: PerspectiveGuideState?
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

            if let candidate {
                drawExtendedLine(
                    from: candidate.leftVanishingPoint,
                    through: candidate.rightVanishingPoint,
                    in: clipped,
                    color: Color.cyan.opacity(0.92),
                    lineWidth: 2,
                    dash: [9, 6]
                )
            }

            for line in state.lines {
                draw(line, in: clipped, isDraft: false)
            }
            if let draft = state.draftLine {
                draw(draft, in: clipped, isDraft: true)
            }

            for role in PerspectiveGuideMatchRole.allCases {
                guard let point = state.vanishingPoint(for: role) else { continue }
                drawVanishingPoint(point, role: role, in: context, size: size)
            }
        }
    }

    private func draw(
        _ line: PerspectiveGuideMatchLine,
        in context: GraphicsContext,
        isDraft: Bool
    ) {
        let color = roleColor(line.role)
        drawExtendedLine(
            from: line.start,
            through: line.end,
            in: context,
            color: color.opacity(isDraft ? 0.34 : 0.2),
            lineWidth: 1.1,
            dash: [7, 5]
        )

        let start = transform.canvasToViewport(line.start)
        let end = transform.canvasToViewport(line.end)
        var segment = Path()
        segment.move(to: CGPoint(x: start.x, y: start.y))
        segment.addLine(to: CGPoint(x: end.x, y: end.y))
        context.stroke(
            segment,
            with: .color(color.opacity(isDraft ? 0.72 : 0.98)),
            style: StrokeStyle(lineWidth: isDraft ? 2 : 2.8, lineCap: .round)
        )
        for point in [start, end] {
            let rect = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
            context.fill(Path(ellipseIn: rect), with: .color(Color.black.opacity(0.72)))
            context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: 1.5)
        }
        context.draw(
            Text(line.role.displayName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.white),
            at: CGPoint(x: (start.x + end.x) * 0.5, y: (start.y + end.y) * 0.5)
        )
    }

    private func drawExtendedLine(
        from first: CanvasPoint,
        through second: CanvasPoint,
        in context: GraphicsContext,
        color: Color,
        lineWidth: CGFloat,
        dash: [CGFloat]
    ) {
        let dx = second.x - first.x
        let dy = second.y - first.y
        let length = hypot(dx, dy)
        guard length > 0.000_001 else { return }
        let extent = max(
            Double(max(transform.canvasSize.width, transform.canvasSize.height)) * 4,
            abs(first.x), abs(first.y), abs(second.x), abs(second.y), 1_000
        )
        let directionX = dx / length
        let directionY = dy / length
        let start = transform.canvasToViewport(CanvasPoint(
            x: first.x - directionX * extent,
            y: first.y - directionY * extent
        ))
        let end = transform.canvasToViewport(CanvasPoint(
            x: first.x + directionX * extent,
            y: first.y + directionY * extent
        ))
        var path = Path()
        path.move(to: CGPoint(x: start.x, y: start.y))
        path.addLine(to: CGPoint(x: end.x, y: end.y))
        context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: dash)
        )
    }

    private func drawVanishingPoint(
        _ point: CanvasPoint,
        role: PerspectiveGuideMatchRole,
        in context: GraphicsContext,
        size: CGSize
    ) {
        let viewport = transform.canvasToViewport(point)
        guard viewport.x >= -18, viewport.x <= size.width + 18,
              viewport.y >= -18, viewport.y <= size.height + 18 else { return }
        let color = roleColor(role)
        let rect = CGRect(x: viewport.x - 9, y: viewport.y - 9, width: 18, height: 18)
        context.fill(Path(ellipseIn: rect), with: .color(Color.black.opacity(0.76)))
        context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: 2)
        context.draw(
            Text(role.displayName)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.white),
            at: CGPoint(x: viewport.x, y: viewport.y)
        )
    }

    private func roleColor(_ role: PerspectiveGuideMatchRole) -> Color {
        switch role {
        case .left: return .red
        case .right: return .green
        case .vertical: return .blue
        }
    }
}

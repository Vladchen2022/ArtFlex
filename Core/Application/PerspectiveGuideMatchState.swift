import Foundation

enum PerspectiveGuideMatchRole: String, CaseIterable, Sendable, Equatable, Hashable {
    case left
    case right
    case vertical

    var displayName: String {
        switch self {
        case .left: return "左侧"
        case .right: return "右侧"
        case .vertical: return "上/下"
        }
    }
}

struct PerspectiveMatchLineSegment: Sendable, Equatable {
    var start: CanvasPoint
    var end: CanvasPoint

    var length: Double {
        hypot(end.x - start.x, end.y - start.y)
    }
}

struct PerspectiveGuideMatchLine: Identifiable, Sendable, Equatable {
    var id: UUID
    var role: PerspectiveGuideMatchRole
    var segment: PerspectiveMatchLineSegment

    init(
        id: UUID = UUID(),
        role: PerspectiveGuideMatchRole,
        start: CanvasPoint,
        end: CanvasPoint
    ) {
        self.id = id
        self.role = role
        segment = PerspectiveMatchLineSegment(start: start, end: end)
    }

    var start: CanvasPoint {
        get { segment.start }
        set { segment.start = newValue }
    }

    var end: CanvasPoint {
        get { segment.end }
        set { segment.end = newValue }
    }

    var length: Double { segment.length }
}

struct PerspectiveGuideMatchState: Sendable, Equatable {
    var isActive = false
    var activeRole: PerspectiveGuideMatchRole = .left
    var lines: [PerspectiveGuideMatchLine] = []
    var draftLine: PerspectiveGuideMatchLine?

    func lines(for role: PerspectiveGuideMatchRole) -> [PerspectiveGuideMatchLine] {
        lines.filter { $0.role == role }
    }

    func lineCount(for role: PerspectiveGuideMatchRole) -> Int {
        lines.reduce(into: 0) { count, line in
            if line.role == role { count += 1 }
        }
    }

    func vanishingPoint(for role: PerspectiveGuideMatchRole) -> CanvasPoint? {
        perspectiveMatchVanishingPoint(segments: lines(for: role).map(\.segment))
    }

    var isComplete: Bool {
        PerspectiveGuideMatchRole.allCases.allSatisfy { lineCount(for: $0) >= 2 }
    }

    var hasAnyLines: Bool { !lines.isEmpty }
}

/// Finds the point minimizing squared perpendicular distance to all supplied
/// image lines. Normalizing each equation prevents long traced segments from
/// receiving more weight than shorter, equally valid scene edges.
func perspectiveMatchVanishingPoint(
    segments: [PerspectiveMatchLineSegment]
) -> CanvasPoint? {
    let equations = segments.compactMap { segment -> (a: Double, b: Double, c: Double)? in
        let dx = segment.end.x - segment.start.x
        let dy = segment.end.y - segment.start.y
        let length = hypot(dx, dy)
        guard length >= 1 else { return nil }
        let a = dy / length
        let b = -dx / length
        let c = -((a * segment.start.x) + (b * segment.start.y))
        return (a, b, c)
    }
    guard equations.count >= 2 else { return nil }

    var aa = 0.0
    var ab = 0.0
    var bb = 0.0
    var ac = 0.0
    var bc = 0.0
    for equation in equations {
        aa += equation.a * equation.a
        ab += equation.a * equation.b
        bb += equation.b * equation.b
        ac += equation.a * equation.c
        bc += equation.b * equation.c
    }
    let determinant = (aa * bb) - (ab * ab)
    guard determinant.isFinite, abs(determinant) > 0.000_000_000_1 else { return nil }
    let x = ((ab * bc) - (bb * ac)) / determinant
    let y = ((ab * ac) - (aa * bc)) / determinant
    guard x.isFinite, y.isFinite else { return nil }
    return CanvasPoint(x: x, y: y)
}

func matchedPerspectiveGuide(
    state: PerspectiveGuideMatchState,
    preserving styleSource: PerspectiveGuideState?,
    canvasSize: CanvasSize
) -> PerspectiveGuideState? {
    guard let firstHorizontal = state.vanishingPoint(for: .left),
          let secondHorizontal = state.vanishingPoint(for: .right),
          let vertical = state.vanishingPoint(for: .vertical) else { return nil }

    let firstRoleResolvesLeft = firstHorizontal.x <= secondHorizontal.x
    let left = firstRoleResolvesLeft ? firstHorizontal : secondHorizontal
    let right = firstRoleResolvesLeft ? secondHorizontal : firstHorizontal
    var guide = styleSource ?? .initial(canvasSize: canvasSize)
    guide.mode = .threePoint
    guide.leftVanishingPoint = left
    guide.rightVanishingPoint = right
    guide.verticalVanishingPoint = vertical

    let horizonY: Double
    let horizonDeltaX = right.x - left.x
    if abs(horizonDeltaX) > 0.000_001 {
        let t = (vertical.x - left.x) / horizonDeltaX
        horizonY = left.y + ((right.y - left.y) * t)
    } else {
        horizonY = (left.y + right.y) * 0.5
    }
    guide.verticalDirection = vertical.y < horizonY ? .above : .below
    guide.anchors = state.lines.map { line in
        let midpoint = CanvasPoint(
            x: (line.start.x + line.end.x) * 0.5,
            y: (line.start.y + line.end.y) * 0.5
        )
        let resolvedRole: PerspectiveVanishingPointRole
        switch line.role {
        case .left:
            resolvedRole = firstRoleResolvesLeft ? .left : .right
        case .right:
            resolvedRole = firstRoleResolvesLeft ? .right : .left
        case .vertical:
            resolvedRole = .vertical
        }
        return PerspectiveGuideAnchor(
            position: midpoint,
            connectsLeft: resolvedRole == .left,
            connectsRight: resolvedRole == .right,
            connectsVertical: resolvedRole == .vertical
        )
    }
    guide.isVisible = true
    guide.isLocked = false
    guide.normalizeStyle()
    return guide
}

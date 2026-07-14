import Foundation

enum PerspectiveGuideMode: String, Codable, CaseIterable, Sendable, Equatable {
    case onePoint
    case twoPoint
    case threePoint

    var displayName: String {
        switch self {
        case .onePoint:
            return "一点"
        case .twoPoint:
            return "两点"
        case .threePoint:
            return "三点"
        }
    }
}

enum PerspectiveVerticalDirection: String, Codable, CaseIterable, Sendable, Equatable {
    case above
    case below

    var displayName: String {
        switch self {
        case .above:
            return "上方"
        case .below:
            return "下方"
        }
    }
}

enum PerspectiveVanishingPointRole: String, Codable, CaseIterable, Sendable, Equatable {
    case left
    case right
    case vertical
}

struct PerspectiveGuideAnchor: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var position: CanvasPoint
    var connectsLeft: Bool
    var connectsRight: Bool
    var connectsVertical: Bool

    init(
        id: UUID = UUID(),
        position: CanvasPoint,
        connectsLeft: Bool = true,
        connectsRight: Bool = true,
        connectsVertical: Bool = true
    ) {
        self.id = id
        self.position = position
        self.connectsLeft = connectsLeft
        self.connectsRight = connectsRight
        self.connectsVertical = connectsVertical
    }

    func connects(to role: PerspectiveVanishingPointRole) -> Bool {
        switch role {
        case .left:
            return connectsLeft
        case .right:
            return connectsRight
        case .vertical:
            return connectsVertical
        }
    }

    mutating func setConnection(_ isEnabled: Bool, to role: PerspectiveVanishingPointRole) {
        switch role {
        case .left:
            connectsLeft = isEnabled
        case .right:
            connectsRight = isEnabled
        case .vertical:
            connectsVertical = isEnabled
        }
    }
}

struct PerspectiveGuideState: Codable, Sendable, Equatable {
    var mode: PerspectiveGuideMode
    var verticalDirection: PerspectiveVerticalDirection
    var leftVanishingPoint: CanvasPoint
    var rightVanishingPoint: CanvasPoint
    var verticalVanishingPoint: CanvasPoint
    var anchors: [PerspectiveGuideAnchor]
    var color: RGBAColor
    var opacity: Float
    var lineWidth: Float
    var isVisible: Bool
    var isLocked: Bool

    static func initial(canvasSize: CanvasSize) -> PerspectiveGuideState {
        let width = Double(max(canvasSize.width, 1))
        let height = Double(max(canvasSize.height, 1))
        return PerspectiveGuideState(
            mode: .threePoint,
            verticalDirection: .above,
            leftVanishingPoint: CanvasPoint(x: width * 0.12, y: height * 0.44),
            rightVanishingPoint: CanvasPoint(x: width * 0.88, y: height * 0.44),
            verticalVanishingPoint: CanvasPoint(x: width * 0.5, y: height * 0.1),
            anchors: [],
            color: RGBAColor(red: 0.12, green: 0.68, blue: 1, alpha: 1),
            opacity: 0.56,
            lineWidth: 1.2,
            isVisible: true,
            isLocked: false
        )
    }

    var activeVanishingPointRoles: [PerspectiveVanishingPointRole] {
        switch mode {
        case .onePoint:
            return [.left]
        case .twoPoint:
            return [.left, .right]
        case .threePoint:
            return [.left, .right, .vertical]
        }
    }

    func vanishingPoint(for role: PerspectiveVanishingPointRole) -> CanvasPoint {
        switch role {
        case .left:
            return leftVanishingPoint
        case .right:
            return rightVanishingPoint
        case .vertical:
            return verticalVanishingPoint
        }
    }

    mutating func setVanishingPoint(_ point: CanvasPoint, for role: PerspectiveVanishingPointRole) {
        switch role {
        case .left:
            leftVanishingPoint = point
        case .right:
            rightVanishingPoint = point
        case .vertical:
            verticalVanishingPoint = point
            let horizonY = (leftVanishingPoint.y + rightVanishingPoint.y) * 0.5
            verticalDirection = point.y < horizonY ? .above : .below
        }
    }

    mutating func setMode(_ newMode: PerspectiveGuideMode, canvasSize: CanvasSize) {
        guard mode != newMode else { return }
        let width = Double(max(canvasSize.width, 1))
        let height = Double(max(canvasSize.height, 1))
        let horizonY = (leftVanishingPoint.y + rightVanishingPoint.y) * 0.5

        if newMode == .onePoint {
            leftVanishingPoint = CanvasPoint(
                x: (leftVanishingPoint.x + rightVanishingPoint.x) * 0.5,
                y: horizonY
            )
        } else if mode == .onePoint {
            leftVanishingPoint = CanvasPoint(x: width * 0.12, y: leftVanishingPoint.y)
            rightVanishingPoint = CanvasPoint(x: width * 0.88, y: leftVanishingPoint.y)
        }

        if newMode == .threePoint {
            verticalVanishingPoint = CanvasPoint(
                x: width * 0.5,
                y: verticalDirection == .above ? height * 0.1 : height * 0.9
            )
        }
        mode = newMode
    }

    mutating func setVerticalDirection(
        _ direction: PerspectiveVerticalDirection,
        canvasSize: CanvasSize
    ) {
        verticalDirection = direction
        let width = Double(max(canvasSize.width, 1))
        let height = Double(max(canvasSize.height, 1))
        verticalVanishingPoint = CanvasPoint(
            x: width * 0.5,
            y: direction == .above ? height * 0.1 : height * 0.9
        )
    }

    func makeAnchor(at point: CanvasPoint) -> PerspectiveGuideAnchor {
        PerspectiveGuideAnchor(
            position: point,
            connectsLeft: true,
            connectsRight: mode != .onePoint,
            connectsVertical: mode == .threePoint
        )
    }

    mutating func normalizeStyle() {
        opacity = min(max(opacity, 0.05), 1)
        lineWidth = min(max(lineWidth, 0.5), 4)
        color.red = min(max(color.red, 0), 1)
        color.green = min(max(color.green, 0), 1)
        color.blue = min(max(color.blue, 0), 1)
        color.alpha = 1
    }

    func cropped(originX: Int, originY: Int) -> PerspectiveGuideState {
        let delta = CanvasPoint(x: -Double(originX), y: -Double(originY))
        var result = self
        result.leftVanishingPoint = result.leftVanishingPoint.translated(by: delta)
        result.rightVanishingPoint = result.rightVanishingPoint.translated(by: delta)
        result.verticalVanishingPoint = result.verticalVanishingPoint.translated(by: delta)
        result.anchors = result.anchors.map { anchor in
            var translated = anchor
            translated.position = anchor.position.translated(by: delta)
            return translated
        }
        return result
    }
}

enum PerspectiveGuideInteractionTarget: Sendable, Equatable {
    case vanishingPoint(PerspectiveVanishingPointRole)
    case horizon
    case anchor(UUID)
}

func perspectiveGuideHitTarget(
    state: PerspectiveGuideState,
    point: CanvasPoint,
    hitRadius: Double,
    canvasSize: CanvasSize
) -> PerspectiveGuideInteractionTarget? {
    let radius = max(hitRadius, 0)

    for anchor in state.anchors.reversed()
    where distanceBetween(anchor.position, point) <= radius {
        return .anchor(anchor.id)
    }

    for role in state.activeVanishingPointRoles.reversed()
    where distanceBetween(state.vanishingPoint(for: role), point) <= radius {
        return .vanishingPoint(role)
    }

    let horizonStart: CanvasPoint
    let horizonEnd: CanvasPoint
    if state.mode == .onePoint {
        horizonStart = CanvasPoint(x: 0, y: state.leftVanishingPoint.y)
        horizonEnd = CanvasPoint(x: Double(max(canvasSize.width, 1)), y: state.leftVanishingPoint.y)
    } else {
        horizonStart = state.leftVanishingPoint
        horizonEnd = state.rightVanishingPoint
    }
    if perspectiveDistanceFromPointToLineSegment(point, start: horizonStart, end: horizonEnd) <= radius {
        return .horizon
    }
    return nil
}

func perspectiveDistanceFromPointToLineSegment(
    _ point: CanvasPoint,
    start: CanvasPoint,
    end: CanvasPoint
) -> Double {
    let axisX = end.x - start.x
    let axisY = end.y - start.y
    let axisLengthSquared = (axisX * axisX) + (axisY * axisY)
    guard axisLengthSquared > 0.000_001 else {
        return distanceBetween(point, start)
    }
    let projection = min(
        max((((point.x - start.x) * axisX) + ((point.y - start.y) * axisY)) / axisLengthSquared, 0),
        1
    )
    let closest = CanvasPoint(
        x: start.x + (axisX * projection),
        y: start.y + (axisY * projection)
    )
    return distanceBetween(point, closest)
}

private extension CanvasPoint {
    func translated(by delta: CanvasPoint) -> CanvasPoint {
        CanvasPoint(x: x + delta.x, y: y + delta.y)
    }
}

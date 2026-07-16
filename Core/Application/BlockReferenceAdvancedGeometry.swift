import Foundation

struct BlockReferenceModuleGeometry: Sendable, Equatable {
    var dimensions: BlockDimensions
    var faces: [[BlockVector3]]
}

enum BlockHumanJoint: String, CaseIterable, Sendable, Equatable, Hashable {
    case pelvis
    case head
    case torso
    case leftShoulder
    case rightShoulder
    case leftElbow
    case rightElbow
    case leftHip
    case rightHip
    case leftKnee
    case rightKnee

    var displayName: String {
        switch self {
        case .pelvis: return "骨盆"
        case .head: return "头"
        case .torso: return "躯干"
        case .leftShoulder: return "左肩"
        case .rightShoulder: return "右肩"
        case .leftElbow: return "左肘"
        case .rightElbow: return "右肘"
        case .leftHip: return "左髋"
        case .rightHip: return "右髋"
        case .leftKnee: return "左膝"
        case .rightKnee: return "右膝"
        }
    }

    var rotationAxes: [BlockReferenceAxis] {
        switch self {
        case .pelvis:
            return [.z]
        case .head, .torso, .leftShoulder, .rightShoulder, .leftHip, .rightHip:
            return [.x, .y, .z]
        case .leftElbow, .rightElbow, .leftKnee, .rightKnee:
            return [.x]
        }
    }
}

func blockReferenceHumanPose(
    _ original: BlockHumanPose,
    rotating joint: BlockHumanJoint,
    around axis: BlockReferenceAxis,
    by degrees: Double
) -> BlockHumanPose {
    var pose = original
    switch (joint, axis) {
    case (.pelvis, .z): pose.pelvisYawDegrees += degrees
    case (.head, .x): pose.headPitchDegrees += degrees
    case (.head, .y): pose.headRollDegrees += degrees
    case (.head, .z): pose.headYawDegrees += degrees
    case (.torso, .x): pose.torsoPitchDegrees += degrees
    case (.torso, .y): pose.torsoRollDegrees += degrees
    case (.torso, .z): pose.torsoYawDegrees += degrees
    case (.leftShoulder, .x): pose.leftShoulderFlexionDegrees += degrees
    case (.leftShoulder, .y): pose.leftShoulderDegrees += degrees
    case (.rightShoulder, .x): pose.rightShoulderFlexionDegrees += degrees
    case (.rightShoulder, .y): pose.rightShoulderDegrees -= degrees
    case (.leftShoulder, .z): pose.leftShoulderTwistDegrees += degrees
    case (.rightShoulder, .z): pose.rightShoulderTwistDegrees += degrees
    case (.leftElbow, .x): pose.leftElbowDegrees += degrees
    case (.rightElbow, .x): pose.rightElbowDegrees += degrees
    case (.leftHip, .x): pose.leftHipDegrees += degrees
    case (.leftHip, .y): pose.leftHipAbductionDegrees += degrees
    case (.rightHip, .x): pose.rightHipDegrees += degrees
    case (.rightHip, .y): pose.rightHipAbductionDegrees -= degrees
    case (.leftHip, .z): pose.leftHipTwistDegrees += degrees
    case (.rightHip, .z): pose.rightHipTwistDegrees += degrees
    case (.leftKnee, .x): pose.leftKneeDegrees -= degrees
    case (.rightKnee, .x): pose.rightKneeDegrees -= degrees
    default: break
    }
    pose.normalize()
    return pose
}

struct BlockReferenceHumanRig: Sendable, Equatable {
    var geometry: BlockReferenceModuleGeometry
    var joints: [BlockHumanJoint: BlockVector3]
    var jointAxes: [BlockHumanJoint: [BlockReferenceAxis: BlockVector3]]
}

func blockReferenceAdvancedModuleGeometry(
    kind: BlockReferenceModuleKind,
    parameters: BlockReferenceModuleParameters = .default,
    pose: BlockHumanPose = .standing
) -> BlockReferenceModuleGeometry? {
    var parameters = parameters
    parameters.normalize()
    switch kind {
    case .poseableHuman:
        return blockReferencePoseableHumanGeometry(pose: pose)
    case .stairs:
        let count = parameters.count
        let stepDepth = parameters.secondarySize
        let stepHeight = parameters.thickness
        let width = 120.0
        var faces: [[BlockVector3]] = []
        for index in 0..<count {
            let dimensions = BlockDimensions(
                width: width,
                depth: stepDepth,
                height: stepHeight * Double(index + 1)
            )
            faces += blockReferenceTranslatedFaces(
                blockBoxFaces(dimensions: dimensions),
                by: BlockVector3(
                    x: 0,
                    y: Double(index) * stepDepth,
                    z: 0
                )
            )
        }
        return BlockReferenceModuleGeometry(
            dimensions: .init(
                width: width,
                depth: stepDepth * Double(count),
                height: stepHeight * Double(count)
            ),
            faces: faces
        )

    case .doorFrame:
        let frame = max(parameters.thickness, 4)
        let width = 100.0
        let depth = max(parameters.secondarySize, 8)
        let height = 220.0
        let side = BlockDimensions(width: frame, depth: depth, height: height - frame)
        let top = BlockDimensions(width: width, depth: depth, height: frame)
        let faces = blockReferenceTranslatedFaces(blockBoxFaces(dimensions: side), by: .zero)
            + blockReferenceTranslatedFaces(blockBoxFaces(dimensions: side), by: .init(x: width - frame, y: 0, z: 0))
            + blockReferenceTranslatedFaces(blockBoxFaces(dimensions: top), by: .init(x: 0, y: 0, z: height - frame))
        return .init(dimensions: .init(width: width, depth: depth, height: height), faces: faces)

    case .roomBox:
        let thickness = max(parameters.thickness, 4)
        let width = 360.0
        let depth = max(parameters.secondarySize * 8, 240)
        let height = 260.0
        let floor = BlockDimensions(width: width, depth: depth, height: thickness)
        let back = BlockDimensions(width: width, depth: thickness, height: height)
        let side = BlockDimensions(width: thickness, depth: depth, height: height)
        let faces = blockReferenceTranslatedFaces(blockBoxFaces(dimensions: floor), by: .zero)
            + blockReferenceTranslatedFaces(blockBoxFaces(dimensions: back), by: .zero)
            + blockReferenceTranslatedFaces(blockBoxFaces(dimensions: side), by: .zero)
        return .init(dimensions: .init(width: width, depth: depth, height: height), faces: faces)

    case .table:
        let topThickness = max(parameters.thickness, 4)
        let width = 140.0
        let depth = max(parameters.secondarySize * 2, 60)
        let height = 76.0
        let legSize = max(topThickness * 0.7, 4)
        let top = BlockDimensions(width: width, depth: depth, height: topThickness)
        let leg = BlockDimensions(width: legSize, depth: legSize, height: height - topThickness)
        var faces = blockReferenceTranslatedFaces(
            blockBoxFaces(dimensions: top),
            by: .init(x: 0, y: 0, z: height - topThickness)
        )
        for x in [0.0, width - legSize] {
            for y in [0.0, depth - legSize] {
                faces += blockReferenceTranslatedFaces(
                    blockBoxFaces(dimensions: leg),
                    by: .init(x: x, y: y, z: 0)
                )
            }
        }
        return .init(dimensions: .init(width: width, depth: depth, height: height), faces: faces)

    case .standingHuman, .seatedHuman:
        return nil
    }
}

func blockReferencePoseableHumanGeometry(pose rawPose: BlockHumanPose) -> BlockReferenceModuleGeometry {
    blockReferencePoseableHumanRig(pose: rawPose).geometry
}

func blockReferencePoseableHumanRig(pose rawPose: BlockHumanPose) -> BlockReferenceHumanRig {
    var pose = rawPose
    pose.normalize()
    let totalHeight = 170.0
    let hipCenter = BlockVector3(x: 0, y: 0, z: 82)
    let pelvisFrame = BlockHumanJointFrame.identity
        .rotatedLocally(around: .z, degrees: pose.pelvisYawDegrees)
    let torsoFrame = pelvisFrame
        .rotatedLocally(around: .x, degrees: pose.torsoPitchDegrees)
        .rotatedLocally(around: .y, degrees: pose.torsoRollDegrees)
        .rotatedLocally(around: .z, degrees: pose.torsoYawDegrees)
    let shoulderCenter = hipCenter + torsoFrame.z * 50
    let neckCenter = shoulderCenter + torsoFrame.z * 5
    let headFrame = torsoFrame
        .rotatedLocally(around: .x, degrees: pose.headPitchDegrees)
        .rotatedLocally(around: .y, degrees: pose.headRollDegrees)
        .rotatedLocally(around: .z, degrees: pose.headYawDegrees)
    let headCenter = neckCenter + headFrame.z * 14

    var faces: [[BlockVector3]] = []
    let pelvisDimensions = BlockDimensions(width: 29, depth: 20, height: 15)
    faces += blockReferenceOrientedBoxFaces(
        center: hipCenter,
        dimensions: pelvisDimensions,
        frame: pelvisFrame
    )
    faces += blockReferenceOrientedBoxFaces(
        center: (hipCenter + shoulderCenter) * 0.5,
        dimensions: .init(width: 30, depth: 20, height: 50),
        frame: torsoFrame
    )
    faces += blockReferenceTranslatedFaces(
        blockSphereFaces(dimensions: .init(width: 23, depth: 21, height: 25), radialSegments: 6),
        by: headCenter - .init(x: 0, y: 0, z: 12.5)
    )

    var joints: [BlockHumanJoint: BlockVector3] = [
        .pelvis: hipCenter,
        .head: headCenter,
        .torso: (hipCenter + shoulderCenter) * 0.5
    ]
    var jointAxes: [BlockHumanJoint: [BlockReferenceAxis: BlockVector3]] = [
        .pelvis: [.x: .unitX, .y: .unitY, .z: .unitZ],
        .torso: pelvisFrame.axisDirections,
        .head: torsoFrame.axisDirections
    ]
    let shoulderHalf = 20.0
    for side in [-1.0, 1.0] {
        let shoulder = shoulderCenter + torsoFrame.x * (side * shoulderHalf)
        let shoulderAbduction = side < 0 ? pose.leftShoulderDegrees : pose.rightShoulderDegrees
        let shoulderFlexion = side < 0
            ? pose.leftShoulderFlexionDegrees
            : pose.rightShoulderFlexionDegrees
        let shoulderTwist = side < 0
            ? pose.leftShoulderTwistDegrees
            : pose.rightShoulderTwistDegrees
        let elbowAngle = side < 0 ? pose.leftElbowDegrees : pose.rightElbowDegrees
        let shoulderParentAxes = torsoFrame.axisDirections
        let armFrame = torsoFrame
            .rotatedLocally(around: .x, degrees: shoulderFlexion)
            .rotatedLocally(around: .y, degrees: side < 0 ? shoulderAbduction : -shoulderAbduction)
            .rotatedLocally(around: .z, degrees: shoulderTwist)
        let upperDirection = -armFrame.z
        let elbow = shoulder + upperDirection * 30
        let forearmDirection = blockRotateAroundAxis(
            upperDirection,
            axis: armFrame.x,
            degrees: elbowAngle
        )
        let hand = elbow + forearmDirection * 27
        faces += blockReferenceSegmentBoxFaces(start: shoulder, end: elbow, width: 9, depth: 9)
        faces += blockReferenceSegmentBoxFaces(start: elbow, end: hand, width: 8, depth: 8)

        let hip = hipCenter + pelvisFrame.x * (side * 11)
        let hipAngle = side < 0 ? pose.leftHipDegrees : pose.rightHipDegrees
        let hipAbduction = side < 0 ? pose.leftHipAbductionDegrees : pose.rightHipAbductionDegrees
        let hipTwist = side < 0 ? pose.leftHipTwistDegrees : pose.rightHipTwistDegrees
        let kneeAngle = side < 0 ? pose.leftKneeDegrees : pose.rightKneeDegrees
        let hipParentAxes = pelvisFrame.axisDirections
        let legFrame = pelvisFrame
            .rotatedLocally(around: .x, degrees: hipAngle)
            .rotatedLocally(around: .y, degrees: side < 0 ? hipAbduction : -hipAbduction)
            .rotatedLocally(around: .z, degrees: hipTwist)
        let thighDirection = -legFrame.z
        let knee = hip + thighDirection * 43
        let calfDirection = blockRotateAroundAxis(
            thighDirection,
            axis: legFrame.x,
            degrees: -kneeAngle
        )
        let foot = knee + calfDirection * 43
        faces += blockReferenceSegmentBoxFaces(start: hip, end: knee, width: 14, depth: 15)
        faces += blockReferenceSegmentBoxFaces(start: knee, end: foot, width: 11, depth: 12)
        if side < 0 {
            joints[.leftShoulder] = shoulder
            joints[.leftElbow] = elbow
            joints[.leftHip] = hip
            joints[.leftKnee] = knee
            jointAxes[.leftShoulder] = [
                .x: shoulderParentAxes[.x]!,
                .y: shoulderParentAxes[.y]!,
                .z: armFrame.z
            ]
            jointAxes[.leftElbow] = [.x: armFrame.x, .y: armFrame.y, .z: armFrame.z]
            jointAxes[.leftHip] = [
                .x: hipParentAxes[.x]!,
                .y: hipParentAxes[.y]!,
                .z: legFrame.z
            ]
            jointAxes[.leftKnee] = [.x: legFrame.x, .y: legFrame.y, .z: legFrame.z]
        } else {
            joints[.rightShoulder] = shoulder
            joints[.rightElbow] = elbow
            joints[.rightHip] = hip
            joints[.rightKnee] = knee
            jointAxes[.rightShoulder] = [
                .x: shoulderParentAxes[.x]!,
                .y: shoulderParentAxes[.y]!,
                .z: armFrame.z
            ]
            jointAxes[.rightElbow] = [.x: armFrame.x, .y: armFrame.y, .z: armFrame.z]
            jointAxes[.rightHip] = [
                .x: hipParentAxes[.x]!,
                .y: hipParentAxes[.y]!,
                .z: legFrame.z
            ]
            jointAxes[.rightKnee] = [.x: legFrame.x, .y: legFrame.y, .z: legFrame.z]
        }
    }
    return BlockReferenceHumanRig(
        geometry: BlockReferenceModuleGeometry(
            dimensions: .init(width: 80, depth: 90, height: totalHeight),
            faces: faces
        ),
        joints: joints,
        jointAxes: jointAxes
    )
}

private struct BlockHumanJointFrame: Sendable, Equatable {
    var x: BlockVector3
    var y: BlockVector3
    var z: BlockVector3

    static let identity = BlockHumanJointFrame(x: .unitX, y: .unitY, z: .unitZ)

    var axisDirections: [BlockReferenceAxis: BlockVector3] {
        [.x: x, .y: y, .z: z]
    }

    func rotatedLocally(around axis: BlockReferenceAxis, degrees: Double) -> BlockHumanJointFrame {
        let worldAxis: BlockVector3
        switch axis {
        case .x: worldAxis = x
        case .y: worldAxis = y
        case .z: worldAxis = z
        }
        return BlockHumanJointFrame(
            x: blockRotateAroundAxis(x, axis: worldAxis, degrees: degrees).normalized(fallback: x),
            y: blockRotateAroundAxis(y, axis: worldAxis, degrees: degrees).normalized(fallback: y),
            z: blockRotateAroundAxis(z, axis: worldAxis, degrees: degrees).normalized(fallback: z)
        )
    }
}

private func blockReferenceOrientedBoxFaces(
    center: BlockVector3,
    dimensions: BlockDimensions,
    frame: BlockHumanJointFrame
) -> [[BlockVector3]] {
    let centerOffset = BlockVector3(x: 0, y: 0, z: dimensions.height * 0.5)
    return blockBoxFaces(dimensions: dimensions).map { face in
        face.map { point in
            let local = point - centerOffset
            return center + frame.x * local.x + frame.y * local.y + frame.z * local.z
        }
    }
}

func blockReferenceHumanJointWorldPoints(
    object: BlockReferenceObject
) -> [BlockHumanJoint: BlockVector3] {
    guard object.moduleKind == .poseableHuman else { return [:] }
    let rig = blockReferencePoseableHumanRig(pose: object.humanPose ?? .standing)
    let base = rig.geometry.dimensions
    let scale = BlockVector3(
        x: object.dimensions.width / base.width,
        y: object.dimensions.depth / base.depth,
        z: object.dimensions.height / base.height
    )
    return rig.joints.mapValues { point in
        blockTransformPoint(
            .init(x: point.x * scale.x, y: point.y * scale.y, z: point.z * scale.z),
            object: object
        )
    }
}

func blockReferenceHumanJointWorldAxes(
    object: BlockReferenceObject,
    joint: BlockHumanJoint
) -> [BlockReferenceAxis: BlockVector3] {
    guard object.moduleKind == .poseableHuman else { return [:] }
    let rig = blockReferencePoseableHumanRig(pose: object.humanPose ?? .standing)
    let base = rig.geometry.dimensions
    let scale = BlockVector3(
        x: object.dimensions.width / base.width,
        y: object.dimensions.depth / base.depth,
        z: object.dimensions.height / base.height
    )
    return (rig.jointAxes[joint] ?? [:]).mapValues { axis in
        let scaled = BlockVector3(
            x: axis.x * scale.x,
            y: axis.y * scale.y,
            z: axis.z * scale.z
        ).normalized(fallback: axis)
        return blockRotate(scaled, rotation: object.rotation).normalized(fallback: axis)
    }
}

func blockReferenceHumanJointHitTest(
    object: BlockReferenceObject,
    canvasPoint: CanvasPoint,
    camera: BlockReferenceCamera,
    canvasSize: CanvasSize,
    screenScale: Double
) -> BlockHumanJoint? {
    let tolerance = 13 / max(screenScale, 0.000_001)
    return blockReferenceHumanJointWorldPoints(object: object)
        .compactMap { joint, point -> (BlockHumanJoint, Double, Double)? in
            guard let projected = projectBlockPoint(point, camera: camera, canvasSize: canvasSize) else { return nil }
            let distance = hypot(
                projected.canvasPoint.x - canvasPoint.x,
                projected.canvasPoint.y - canvasPoint.y
            )
            return distance <= tolerance ? (joint, distance, projected.cameraDepth) : nil
        }
        .sorted { lhs, rhs in
            abs(lhs.1 - rhs.1) > 0.5 ? lhs.1 < rhs.1 : lhs.2 < rhs.2
        }
        .first?.0
}

func blockReferenceSceneSnapshot(name: String, scene: BlockReferenceScene) -> BlockReferenceSceneSnapshot {
    BlockReferenceSceneSnapshot(
        name: name,
        objects: scene.objects,
        measurements: scene.measurements,
        workingPlane: scene.workingPlane,
        constructionLines: scene.constructionLines,
        savedWorkingPlanes: scene.savedWorkingPlanes,
        groups: scene.groups,
        camera: scene.camera,
        section: scene.section
    )
}

func blockReferenceVanishingPoint(
    direction: BlockVector3,
    camera: BlockReferenceCamera,
    canvasSize: CanvasSize
) -> CanvasPoint? {
    guard !camera.isOrthographic else { return nil }
    let basis = blockCameraBasis(camera)
    let forward = direction.dot(basis.forward)
    guard abs(forward) > 0.000_001 else { return nil }
    let width = Double(max(canvasSize.width, 1))
    let height = Double(max(canvasSize.height, 1))
    let aspect = width / height
    let fovScale = tan(camera.fieldOfViewDegrees * .pi / 360)
    let ndcX = direction.dot(basis.right) / (forward * fovScale * aspect)
    let ndcY = direction.dot(basis.up) / (forward * fovScale)
    return CanvasPoint(
        x: (camera.principalPointNormalized.x + ndcX * 0.5) * width,
        y: (camera.principalPointNormalized.y - ndcY * 0.5) * height
    )
}

struct BlockReferencePerspectiveEdgeLine: Sendable, Equatable {
    var axis: BlockReferenceAxis
    var edgeStart: CanvasPoint
    var edgeEnd: CanvasPoint
    var lineStart: CanvasPoint
    var lineEnd: CanvasPoint
}

/// Builds live perspective extensions from the selected object's real feature
/// edges. Because the source edges are projected with the current camera on
/// every frame, the guide remains attached while orbiting or panning.
func blockReferencePerspectiveEdgeLines(
    object: BlockReferenceObject,
    camera: BlockReferenceCamera,
    canvasSize: CanvasSize,
    maximumLinesPerAxis: Int = 2
) -> [BlockReferencePerspectiveEdgeLine] {
    guard !camera.isOrthographic, maximumLinesPerAxis > 0 else { return [] }
    let faces = blockObjectFaces(object)
    let featureMask = blockReferenceFeatureEdgeMask(faces: faces)
    let axisDirections = Dictionary(uniqueKeysWithValues: BlockReferenceAxis.allCases.map {
        ($0, blockRotate($0.unitVector, rotation: object.rotation).normalized(fallback: $0.unitVector))
    })
    let center = CanvasPoint(
        x: Double(max(canvasSize.width, 1)) * 0.5,
        y: Double(max(canvasSize.height, 1)) * 0.5
    )
    var candidates: [BlockReferenceAxis: [(CanvasPoint, CanvasPoint, Double)]] = [:]
    var visited: Set<BlockPerspectiveEdgeKey> = []

    for face in faces {
        let mask = featureMask[face.faceIndex]
            ?? Array(repeating: true, count: face.vertices.count)
        for index in face.vertices.indices where mask[index] {
            let start = face.vertices[index]
            let end = face.vertices[(index + 1) % face.vertices.count]
            let key = BlockPerspectiveEdgeKey(start, end)
            guard visited.insert(key).inserted else { continue }
            let direction = (end - start).normalized(fallback: .unitX)
            guard let axis = BlockReferenceAxis.allCases.max(by: {
                abs(direction.dot(axisDirections[$0] ?? $0.unitVector))
                    < abs(direction.dot(axisDirections[$1] ?? $1.unitVector))
            }), abs(direction.dot(axisDirections[axis] ?? axis.unitVector)) >= 0.965,
            let projectedStart = projectBlockPoint(start, camera: camera, canvasSize: canvasSize)?.canvasPoint,
            let projectedEnd = projectBlockPoint(end, camera: camera, canvasSize: canvasSize)?.canvasPoint else {
                continue
            }
            let length = hypot(
                projectedEnd.x - projectedStart.x,
                projectedEnd.y - projectedStart.y
            )
            guard length >= 4 else { continue }
            let midpoint = CanvasPoint(
                x: (projectedStart.x + projectedEnd.x) * 0.5,
                y: (projectedStart.y + projectedEnd.y) * 0.5
            )
            let centerDistance = hypot(midpoint.x - center.x, midpoint.y - center.y)
            candidates[axis, default: []].append((projectedStart, projectedEnd, centerDistance))
        }
    }

    var result: [BlockReferencePerspectiveEdgeLine] = []
    for axis in BlockReferenceAxis.allCases {
        let resolved = (candidates[axis] ?? [])
            .sorted { $0.2 < $1.2 }
            .prefix(maximumLinesPerAxis)
        for candidate in resolved {
            guard let extended = blockPerspectiveCanvasLine(
                through: candidate.0,
                and: candidate.1,
                canvasSize: canvasSize
            ) else { continue }
            result.append(.init(
                axis: axis,
                edgeStart: candidate.0,
                edgeEnd: candidate.1,
                lineStart: extended.0,
                lineEnd: extended.1
            ))
        }
    }
    return result
}

private struct BlockPerspectiveEdgeKey: Hashable {
    var first: BlockVector3
    var second: BlockVector3

    init(_ a: BlockVector3, _ b: BlockVector3) {
        if BlockPerspectiveEdgeKey.less(a, b) {
            first = a
            second = b
        } else {
            first = b
            second = a
        }
    }

    private static func less(_ lhs: BlockVector3, _ rhs: BlockVector3) -> Bool {
        if lhs.x != rhs.x { return lhs.x < rhs.x }
        if lhs.y != rhs.y { return lhs.y < rhs.y }
        return lhs.z < rhs.z
    }
}

private func blockPerspectiveCanvasLine(
    through first: CanvasPoint,
    and second: CanvasPoint,
    canvasSize: CanvasSize
) -> (CanvasPoint, CanvasPoint)? {
    let dx = second.x - first.x
    let dy = second.y - first.y
    guard hypot(dx, dy) > 0.000_001 else { return nil }
    let width = Double(max(canvasSize.width, 1))
    let height = Double(max(canvasSize.height, 1))
    var points: [CanvasPoint] = []
    func append(_ t: Double) {
        let point = CanvasPoint(x: first.x + dx * t, y: first.y + dy * t)
        guard point.x >= -0.01, point.x <= width + 0.01,
              point.y >= -0.01, point.y <= height + 0.01 else { return }
        if points.allSatisfy({ hypot($0.x - point.x, $0.y - point.y) > 0.1 }) {
            points.append(point)
        }
    }
    if abs(dx) > 0.000_001 {
        append((0 - first.x) / dx)
        append((width - first.x) / dx)
    }
    if abs(dy) > 0.000_001 {
        append((0 - first.y) / dy)
        append((height - first.y) / dy)
    }
    guard points.count >= 2 else { return nil }
    var best = (points[0], points[1])
    var bestDistance = 0.0
    for i in points.indices {
        for j in points.indices where j > i {
            let distance = hypot(points[i].x - points[j].x, points[i].y - points[j].y)
            if distance > bestDistance {
                bestDistance = distance
                best = (points[i], points[j])
            }
        }
    }
    return best
}

/// Returns the optical principal point implied by three mutually orthogonal
/// vanishing points. Under the square-pixel/zero-skew camera model this is the
/// orthocenter of their image-space triangle.
func blockReferencePrincipalPoint(
    vanishingPoints: [CanvasPoint]
) -> CanvasPoint? {
    guard vanishingPoints.count == 3 else { return nil }
    let a = vanishingPoints[0]
    let b = vanishingPoints[1]
    let c = vanishingPoints[2]
    let firstSide = CanvasPoint(x: b.x - c.x, y: b.y - c.y)
    let secondSide = CanvasPoint(x: a.x - c.x, y: a.y - c.y)
    let firstResult = a.x * firstSide.x + a.y * firstSide.y
    let secondResult = b.x * secondSide.x + b.y * secondSide.y
    let determinant = firstSide.x * secondSide.y - firstSide.y * secondSide.x
    let scale = max(
        hypot(firstSide.x, firstSide.y) * hypot(secondSide.x, secondSide.y),
        1
    )
    guard determinant.isFinite, abs(determinant) > scale * 0.000_000_000_1 else {
        return nil
    }
    let point = CanvasPoint(
        x: (firstResult * secondSide.y - firstSide.y * secondResult) / determinant,
        y: (firstSide.x * secondResult - firstResult * secondSide.x) / determinant
    )
    return point.x.isFinite && point.y.isFinite ? point : nil
}

/// Recovers the complete perspective camera supported by the editor from
/// three orthogonal vanishing points. The principal point is solved rather
/// than assumed, and roll is retained instead of forcing the image vertical
/// axis through the canvas center. Sign ambiguity is resolved by choosing the
/// valid orientation closest to the current view.
func blockReferenceCameraMatchingPerspectiveGuide(
    _ guide: PerspectiveGuideState,
    currentCamera: BlockReferenceCamera,
    canvasSize: CanvasSize
) -> BlockReferenceCamera? {
    guard guide.mode == .threePoint else { return nil }
    let width = Double(max(canvasSize.width, 1))
    let height = Double(max(canvasSize.height, 1))
    let points = [guide.leftVanishingPoint, guide.rightVanishingPoint, guide.verticalVanishingPoint]
    guard let principalPoint = blockReferencePrincipalPoint(vanishingPoints: points) else {
        return nil
    }
    let centered = points.map {
        CanvasPoint(x: $0.x - principalPoint.x, y: principalPoint.y - $0.y)
    }
    let focalSquaredCandidates = [
        -(centered[0].x * centered[1].x + centered[0].y * centered[1].y),
        -(centered[0].x * centered[2].x + centered[0].y * centered[2].y),
        -(centered[1].x * centered[2].x + centered[1].y * centered[2].y)
    ]
    guard focalSquaredCandidates.allSatisfy({ $0.isFinite && $0 > 1 }) else { return nil }
    let focal = sqrt(focalSquaredCandidates.reduce(0, +) / Double(focalSquaredCandidates.count))
    let fov = 2 * atan(height / (2 * focal)) * 180 / .pi
    guard fov.isFinite, (10...120).contains(fov) else { return nil }

    let cameraDirections = centered.map {
        BlockVector3(x: $0.x / focal, y: $0.y / focal, z: 1).normalized()
    }
    var best: (score: Double, yaw: Double, pitch: Double, roll: Double)?
    for sx in [-1.0, 1.0] {
        for sy in [-1.0, 1.0] {
            for sz in [-1.0, 1.0] {
                let x = cameraDirections[0] * sx
                let y = cameraDirections[1] * sy
                let z = cameraDirections[2] * sz
                let right = BlockVector3(x: x.x, y: y.x, z: z.x).normalized(fallback: .unitX)
                let up = BlockVector3(x: x.y, y: y.y, z: z.y).normalized(fallback: .unitZ)
                let forward = BlockVector3(x: x.z, y: y.z, z: z.z).normalized(fallback: .unitY)
                let determinant = right.dot(up.cross(forward))
                guard determinant < -0.25 else { continue }
                let fromTarget = -forward
                let yaw = atan2(fromTarget.y, fromTarget.x) * 180 / .pi
                let pitch = asin(min(max(fromTarget.z, -1), 1)) * 180 / .pi
                var baseRight = forward.cross(.unitZ).normalized(fallback: .unitX)
                if abs(forward.dot(.unitZ)) > 0.995 {
                    baseRight = forward.cross(.unitY).normalized(fallback: .unitX)
                }
                let baseUp = baseRight.cross(forward).normalized(fallback: .unitZ)
                let roll = atan2(right.dot(baseUp), right.dot(baseRight)) * 180 / .pi
                func angleDelta(_ lhs: Double, _ rhs: Double) -> Double {
                    abs(atan2(
                        sin((lhs - rhs) * .pi / 180),
                        cos((lhs - rhs) * .pi / 180)
                    ) * 180 / .pi)
                }
                let yawDelta = angleDelta(yaw, currentCamera.yawDegrees)
                let rollDelta = angleDelta(roll, currentCamera.rollDegrees)
                let orthogonalityError = abs(x.dot(y)) + abs(x.dot(z)) + abs(y.dot(z))
                let score = yawDelta
                    + abs(pitch - currentCamera.pitchDegrees)
                    + rollDelta
                    + orthogonalityError * 100
                if best == nil || score < best!.score { best = (score, yaw, pitch, roll) }
            }
        }
    }
    guard let best else { return nil }
    var camera = currentCamera
    camera.yawDegrees = best.yaw
    camera.pitchDegrees = best.pitch
    camera.rollDegrees = best.roll
    camera.fieldOfViewDegrees = fov
    camera.principalPointNormalized = CanvasPoint(
        x: principalPoint.x / width,
        y: principalPoint.y / height
    )
    camera.isOrthographic = false
    camera.normalize()
    return camera
}

/// Clips a convex face against the active section plane. A cap is intentionally
/// omitted: this is a drawing reference, not a mesh-authoring Boolean.
func blockReferenceClipFace(
    _ vertices: [BlockVector3],
    section: BlockSectionSettings
) -> [BlockVector3] {
    guard section.isEnabled, vertices.count >= 3 else { return vertices }
    let normal = section.plane.normal * (section.isInverted ? -1 : 1)
    func distance(_ point: BlockVector3) -> Double {
        (point - section.plane.origin).dot(normal)
    }
    var output: [BlockVector3] = []
    for index in vertices.indices {
        let current = vertices[index]
        let previous = vertices[(index + vertices.count - 1) % vertices.count]
        let currentDistance = distance(current)
        let previousDistance = distance(previous)
        let currentInside = currentDistance >= 0
        let previousInside = previousDistance >= 0
        if currentInside != previousInside {
            let denominator = previousDistance - currentDistance
            if abs(denominator) > 0.000_001 {
                let t = previousDistance / denominator
                output.append(previous + (current - previous) * t)
            }
        }
        if currentInside { output.append(current) }
    }
    return output
}

private func blockReferenceDirection(pitchDegrees: Double, yawDegrees: Double) -> BlockVector3 {
    let pitch = pitchDegrees * .pi / 180
    let yaw = yawDegrees * .pi / 180
    return BlockVector3(
        x: sin(yaw) * cos(pitch),
        y: -sin(pitch),
        z: cos(yaw) * cos(pitch)
    ).normalized(fallback: .unitZ)
}

private func blockReferenceAnatomicalLimbDirection(
    flexionDegrees: Double,
    abductionDegrees: Double,
    side: Double
) -> BlockVector3 {
    let flexed = blockRotateAroundAxis(
        -.unitZ,
        axis: .unitX,
        degrees: flexionDegrees
    )
    return blockRotateAroundAxis(
        flexed,
        axis: .unitY,
        degrees: -side * abductionDegrees
    ).normalized(fallback: -.unitZ)
}

private func blockReferenceSegmentBoxFaces(
    start: BlockVector3,
    end: BlockVector3,
    width: Double,
    depth: Double
) -> [[BlockVector3]] {
    let direction = (end - start).normalized(fallback: .unitZ)
    let reference: BlockVector3 = abs(direction.z) < 0.9 ? .unitZ : .unitY
    let axisU = direction.cross(reference).normalized(fallback: .unitX) * (width * 0.5)
    let axisV = direction.cross(axisU.normalized()).normalized(fallback: .unitY) * (depth * 0.5)
    let vertices = [
        start - axisU - axisV, start + axisU - axisV,
        start + axisU + axisV, start - axisU + axisV,
        end - axisU - axisV, end + axisU - axisV,
        end + axisU + axisV, end - axisU + axisV
    ]
    return [
        [vertices[0], vertices[3], vertices[2], vertices[1]],
        [vertices[4], vertices[5], vertices[6], vertices[7]],
        [vertices[0], vertices[1], vertices[5], vertices[4]],
        [vertices[1], vertices[2], vertices[6], vertices[5]],
        [vertices[2], vertices[3], vertices[7], vertices[6]],
        [vertices[3], vertices[0], vertices[4], vertices[7]]
    ]
}

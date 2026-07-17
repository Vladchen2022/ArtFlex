import Foundation

struct BlockVector3: Codable, Sendable, Equatable, Hashable {
    var x: Double
    var y: Double
    var z: Double

    static let zero = BlockVector3(x: 0, y: 0, z: 0)
    static let unitX = BlockVector3(x: 1, y: 0, z: 0)
    static let unitY = BlockVector3(x: 0, y: 1, z: 0)
    static let unitZ = BlockVector3(x: 0, y: 0, z: 1)

    static func + (lhs: BlockVector3, rhs: BlockVector3) -> BlockVector3 {
        BlockVector3(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }

    static func - (lhs: BlockVector3, rhs: BlockVector3) -> BlockVector3 {
        BlockVector3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    static prefix func - (value: BlockVector3) -> BlockVector3 {
        BlockVector3(x: -value.x, y: -value.y, z: -value.z)
    }

    static func * (lhs: BlockVector3, rhs: Double) -> BlockVector3 {
        BlockVector3(x: lhs.x * rhs, y: lhs.y * rhs, z: lhs.z * rhs)
    }

    static func / (lhs: BlockVector3, rhs: Double) -> BlockVector3 {
        guard abs(rhs) > 0.000_000_1 else { return .zero }
        return lhs * (1 / rhs)
    }

    var lengthSquared: Double { dot(self) }
    var length: Double { sqrt(lengthSquared) }

    func dot(_ other: BlockVector3) -> Double {
        (x * other.x) + (y * other.y) + (z * other.z)
    }

    func cross(_ other: BlockVector3) -> BlockVector3 {
        BlockVector3(
            x: (y * other.z) - (z * other.y),
            y: (z * other.x) - (x * other.z),
            z: (x * other.y) - (y * other.x)
        )
    }

    func normalized(fallback: BlockVector3 = .unitZ) -> BlockVector3 {
        let magnitude = length
        return magnitude > 0.000_000_1 ? self / magnitude : fallback
    }

    func distance(to other: BlockVector3) -> Double {
        (self - other).length
    }
}

enum BlockPrimitiveKind: String, Codable, CaseIterable, Sendable, Equatable {
    case box
    case cylinder
    case cone
    case sphere

    var displayName: String {
        switch self {
        case .box: return "方块"
        case .cylinder: return "圆柱"
        case .cone: return "圆锥"
        case .sphere: return "球体"
        }
    }

    var symbolName: String {
        switch self {
        case .box: return "cube"
        case .cylinder: return "cylinder"
        case .cone: return "cone"
        case .sphere: return "circle"
        }
    }
}

enum BlockReferenceModuleKind: String, Codable, CaseIterable, Sendable, Equatable {
    case squareFrustum
    case squarePyramid
    case hemisphere
    case torus
    case hollowCylinder
    case sedan
    case suv
    case smallTruck
    case largeTruck
    case bicycle
    case motorcycle
    case standingHuman
    case seatedHuman
    case poseableHuman
    case stairs
    case doorFrame
    case roomBox
    case table

    var displayName: String {
        switch self {
        case .squareFrustum: return "四边梯形体"
        case .squarePyramid: return "四边方锥体"
        case .hemisphere: return "半圆体"
        case .torus: return "圆环体"
        case .hollowCylinder: return "圆筒体"
        case .sedan: return "小轿车"
        case .suv: return "SUV汽车"
        case .smallTruck: return "小型卡车"
        case .largeTruck: return "中大型卡车"
        case .bicycle: return "自行车"
        case .motorcycle: return "摩托车"
        case .standingHuman: return "站姿人体"
        case .seatedHuman: return "坐姿人体"
        case .poseableHuman: return "可摆姿人体"
        case .stairs: return "楼梯"
        case .doorFrame: return "门框"
        case .roomBox: return "房间盒"
        case .table: return "桌体"
        }
    }

    var symbolName: String {
        switch self {
        case .squareFrustum: return "square.3.layers.3d"
        case .squarePyramid: return "pyramid"
        case .hemisphere: return "circle.bottomhalf.filled"
        case .torus: return "circle.dotted.circle"
        case .hollowCylinder: return "cylinder.split.1x2"
        case .sedan: return "car.side"
        case .suv: return "suv.side"
        case .smallTruck: return "box.truck"
        case .largeTruck: return "truck.box"
        case .bicycle: return "bicycle"
        case .motorcycle: return "motorcycle"
        case .standingHuman: return "figure.stand"
        case .seatedHuman: return "figure.seated.side"
        case .poseableHuman: return "figure.arms.open"
        case .stairs: return "stairs"
        case .doorFrame: return "door.left.hand.open"
        case .roomBox: return "cube.transparent"
        case .table: return "table.furniture"
        }
    }

    var isHumanReference: Bool {
        switch self {
        case .standingHuman, .seatedHuman, .poseableHuman: return true
        case .squareFrustum, .squarePyramid, .hemisphere, .torus, .hollowCylinder,
             .sedan, .suv, .smallTruck, .largeTruck, .bicycle, .motorcycle,
             .stairs, .doorFrame, .roomBox, .table:
            return false
        }
    }

    var isTransportationReference: Bool {
        switch self {
        case .sedan, .suv, .smallTruck, .largeTruck, .bicycle, .motorcycle:
            return true
        case .squareFrustum, .squarePyramid, .hemisphere, .torus, .hollowCylinder,
             .standingHuman, .seatedHuman, .poseableHuman,
             .stairs, .doorFrame, .roomBox, .table:
            return false
        }
    }

    var isBasicGeometryReference: Bool {
        switch self {
        case .squareFrustum, .squarePyramid, .hemisphere, .torus, .hollowCylinder:
            return true
        case .standingHuman, .seatedHuman, .poseableHuman,
             .sedan, .suv, .smallTruck, .largeTruck, .bicycle, .motorcycle,
             .stairs, .doorFrame, .roomBox, .table:
            return false
        }
    }

    var isParametric: Bool {
        switch self {
        case .stairs, .doorFrame, .roomBox, .table: return true
        case .squareFrustum, .squarePyramid, .hemisphere, .torus, .hollowCylinder,
             .sedan, .suv, .smallTruck, .largeTruck, .bicycle, .motorcycle,
             .standingHuman, .seatedHuman, .poseableHuman:
            return false
        }
    }
}

enum BlockReferenceEditorMode: String, Codable, CaseIterable, Sendable, Equatable {
    case select
    case box
    case cylinder
    case cone
    case sphere
    case measure
    case pickWorkPlane
    case setPivot

    var displayName: String {
        switch self {
        case .select: return "选择"
        case .box: return "方块"
        case .cylinder: return "圆柱"
        case .cone: return "圆锥"
        case .sphere: return "球体"
        case .measure: return "测量"
        case .pickWorkPlane: return "取工作面"
        case .setPivot: return "拾取枢轴"
        }
    }

    var primitiveKind: BlockPrimitiveKind? {
        switch self {
        case .box: return .box
        case .cylinder: return .cylinder
        case .cone: return .cone
        case .sphere: return .sphere
        case .select, .measure, .pickWorkPlane, .setPivot: return nil
        }
    }
}

enum BlockReferenceSnapKind: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case grid
    case center
    case vertex
    case midpoint
    case faceCenter

    var displayName: String {
        switch self {
        case .grid: return "网格"
        case .center: return "中心"
        case .vertex: return "端点"
        case .midpoint: return "中点"
        case .faceCenter: return "面心"
        }
    }
}

enum BlockReferenceAxis: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case x
    case y
    case z

    var displayName: String { rawValue.uppercased() }

    var unitVector: BlockVector3 {
        switch self {
        case .x: return .unitX
        case .y: return .unitY
        case .z: return .unitZ
        }
    }
}

enum BlockReferenceGizmoCoordinateSpace: String, Codable, CaseIterable, Sendable, Equatable {
    case world
    case local
    case workingPlane

    var displayName: String {
        switch self {
        case .world: return "世界"
        case .local: return "局部"
        case .workingPlane: return "工作面"
        }
    }
}

enum BlockReferencePivotMode: String, Codable, CaseIterable, Sendable, Equatable {
    case selectionCenter
    case activeObject
    case workingPlaneOrigin
    case custom

    var displayName: String {
        switch self {
        case .selectionCenter: return "选择中心"
        case .activeObject: return "活动物体"
        case .workingPlaneOrigin: return "工作面"
        case .custom: return "自定枢轴"
        }
    }
}

enum BlockReferenceNumericTransformKind: String, Sendable, Equatable {
    case move
    case rotate
    case scale

    var displayName: String {
        switch self {
        case .move: return "移动"
        case .rotate: return "旋转"
        case .scale: return "缩放"
        }
    }
}

struct BlockReferenceGizmoHandle: Sendable, Equatable, Hashable {
    var kind: BlockReferenceNumericTransformKind
    var axis: BlockReferenceAxis
    var isUniformScale: Bool = false
}

enum BlockReferenceNavigationMode: Sendable, Equatable {
    case orbit
    case pan
    case zoom
}

struct BlockDimensions: Codable, Sendable, Equatable {
    var width: Double
    var depth: Double
    var height: Double

    static let stageOneDefault = BlockDimensions(width: 120, depth: 120, height: 120)

    mutating func normalize() {
        width = min(max(abs(width), 1), 10_000)
        depth = min(max(abs(depth), 1), 10_000)
        height = min(max(abs(height), 1), 10_000)
    }
}

/// ArtFlex-owned polygon data for block-reference results that are no longer a primitive.
/// Vertices are stored in object-local coordinates so transforms and dimension editing remain reusable.
struct BlockReferenceCustomMesh: Codable, Sendable, Equatable {
    static let maximumFaceCount = 512
    static let maximumVerticesPerFace = 128

    var faces: [[BlockVector3]]
    var baseDimensions: BlockDimensions

    init(faces: [[BlockVector3]], baseDimensions: BlockDimensions) {
        self.faces = faces
        self.baseDimensions = baseDimensions
        normalize()
    }

    mutating func normalize() {
        baseDimensions.normalize()
        faces = Array(faces.prefix(Self.maximumFaceCount)).compactMap { face in
            guard (3...Self.maximumVerticesPerFace).contains(face.count),
                  face.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
                return nil
            }
            return face
        }
    }
}

struct BlockEulerRotation: Codable, Sendable, Equatable {
    var xDegrees: Double
    var yDegrees: Double
    var zDegrees: Double

    static let zero = BlockEulerRotation(xDegrees: 0, yDegrees: 0, zDegrees: 0)

    mutating func normalize() {
        xDegrees = normalizedDegrees(xDegrees)
        yDegrees = normalizedDegrees(yDegrees)
        zDegrees = normalizedDegrees(zDegrees)
    }

    private func normalizedDegrees(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        var result = value.truncatingRemainder(dividingBy: 360)
        if result > 180 { result -= 360 }
        if result < -180 { result += 360 }
        return result
    }
}

struct BlockReferenceObject: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var name: String
    var kind: BlockPrimitiveKind
    var position: BlockVector3
    var rotation: BlockEulerRotation
    var dimensions: BlockDimensions
    var customMesh: BlockReferenceCustomMesh?
    var moduleKind: BlockReferenceModuleKind?
    var moduleBasePointOffset: BlockVector3?
    var isVisible: Bool
    var isLocked: Bool
    var groupID: UUID?
    var style: BlockReferenceObjectStyle
    var humanPose: BlockHumanPose?
    var moduleParameters: BlockReferenceModuleParameters?

    init(
        id: UUID = UUID(),
        name: String,
        kind: BlockPrimitiveKind,
        position: BlockVector3,
        rotation: BlockEulerRotation = .zero,
        dimensions: BlockDimensions,
        customMesh: BlockReferenceCustomMesh? = nil,
        moduleKind: BlockReferenceModuleKind? = nil,
        moduleBasePointOffset: BlockVector3? = nil,
        isVisible: Bool = true,
        isLocked: Bool = false,
        groupID: UUID? = nil,
        style: BlockReferenceObjectStyle = .default,
        humanPose: BlockHumanPose? = nil,
        moduleParameters: BlockReferenceModuleParameters? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.position = position
        self.rotation = rotation
        self.dimensions = dimensions
        self.customMesh = customMesh
        self.moduleKind = moduleKind
        self.moduleBasePointOffset = moduleBasePointOffset
        self.isVisible = isVisible
        self.isLocked = isLocked
        self.groupID = groupID
        self.style = style
        self.humanPose = humanPose
        self.moduleParameters = moduleParameters
        normalize()
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case position
        case rotation
        case dimensions
        case customMesh
        case moduleKind
        case moduleBasePointOffset
        case isVisible
        case isLocked
        case groupID
        case style
        case humanPose
        case moduleParameters
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(BlockPrimitiveKind.self, forKey: .kind)
        position = try container.decode(BlockVector3.self, forKey: .position)
        rotation = try container.decode(BlockEulerRotation.self, forKey: .rotation)
        dimensions = try container.decode(BlockDimensions.self, forKey: .dimensions)
        customMesh = try container.decodeIfPresent(BlockReferenceCustomMesh.self, forKey: .customMesh)
        moduleKind = try container.decodeIfPresent(BlockReferenceModuleKind.self, forKey: .moduleKind)
        moduleBasePointOffset = try container.decodeIfPresent(
            BlockVector3.self,
            forKey: .moduleBasePointOffset
        )
        isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        groupID = try container.decodeIfPresent(UUID.self, forKey: .groupID)
        style = try container.decodeIfPresent(BlockReferenceObjectStyle.self, forKey: .style) ?? .default
        humanPose = try container.decodeIfPresent(BlockHumanPose.self, forKey: .humanPose)
        moduleParameters = try container.decodeIfPresent(BlockReferenceModuleParameters.self, forKey: .moduleParameters)
        normalize()
        regenerateDerivedModuleGeometryIfNeeded()
    }

    mutating func normalize() {
        if !position.x.isFinite { position.x = 0 }
        if !position.y.isFinite { position.y = 0 }
        if !position.z.isFinite { position.z = 0 }
        rotation.normalize()
        dimensions.normalize()
        customMesh?.normalize()
        if moduleBasePointOffset?.x.isFinite == false { moduleBasePointOffset?.x = 0 }
        if moduleBasePointOffset?.y.isFinite == false { moduleBasePointOffset?.y = 0 }
        if moduleBasePointOffset?.z.isFinite == false { moduleBasePointOffset?.z = 0 }
        style.normalize()
        humanPose?.normalize()
        moduleParameters?.normalize()
    }

    private mutating func regenerateDerivedModuleGeometryIfNeeded() {
        guard
            let moduleKind,
            let geometry = blockReferenceAdvancedModuleGeometry(
                kind: moduleKind,
                parameters: moduleParameters ?? .default,
                pose: humanPose ?? .standing
            )
        else { return }
        customMesh = BlockReferenceCustomMesh(
            faces: geometry.faces,
            baseDimensions: geometry.dimensions
        )
    }

    var geometryDisplayName: String {
        if let moduleKind { return moduleKind.displayName }
        guard customMesh != nil else { return kind.displayName }
        return name.contains("镜像") ? "镜像体块" : "布尔结果"
    }

    var geometrySymbolName: String {
        if let moduleKind { return moduleKind.symbolName }
        return customMesh == nil ? kind.symbolName : "circle.grid.cross"
    }

    var allowsGeometryEditing: Bool {
        moduleKind == nil
            || moduleKind?.isParametric == true
            || moduleKind?.isBasicGeometryReference == true
    }
    var allowsBooleanOperations: Bool { moduleKind == nil }
}

struct BlockReferenceObjectTransformSnapshot: Sendable, Equatable {
    var position: BlockVector3
    var rotation: BlockEulerRotation
    var dimensions: BlockDimensions

    init(
        position: BlockVector3,
        rotation: BlockEulerRotation,
        dimensions: BlockDimensions = .stageOneDefault
    ) {
        self.position = position
        self.rotation = rotation
        self.dimensions = dimensions
    }
}

struct BlockWorkingPlane: Codable, Sendable, Equatable {
    var origin: BlockVector3
    var axisU: BlockVector3
    var axisV: BlockVector3
    var normal: BlockVector3
    var sourceObjectID: UUID?
    var sourceFaceIndex: Int?

    static let ground = BlockWorkingPlane(
        origin: .zero,
        axisU: .unitX,
        axisV: .unitY,
        normal: .unitZ,
        sourceObjectID: nil,
        sourceFaceIndex: nil
    )

    init(
        origin: BlockVector3,
        axisU: BlockVector3,
        axisV: BlockVector3,
        normal: BlockVector3,
        sourceObjectID: UUID? = nil,
        sourceFaceIndex: Int? = nil
    ) {
        self.origin = origin
        let resolvedNormal = normal.normalized()
        let resolvedU = (axisU - resolvedNormal * axisU.dot(resolvedNormal)).normalized(fallback: .unitX)
        let resolvedV = resolvedNormal.cross(resolvedU).normalized(fallback: axisV.normalized(fallback: .unitY))
        self.axisU = resolvedU
        self.axisV = resolvedV
        self.normal = resolvedNormal
        self.sourceObjectID = sourceObjectID
        self.sourceFaceIndex = sourceFaceIndex
    }

    func worldPoint(u: Double, v: Double, height: Double = 0) -> BlockVector3 {
        origin + (axisU * u) + (axisV * v) + (normal * height)
    }

    func coordinates(of point: BlockVector3) -> (u: Double, v: Double, height: Double) {
        let delta = point - origin
        return (delta.dot(axisU), delta.dot(axisV), delta.dot(normal))
    }
}

struct BlockMeasurementGuide: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var start: BlockVector3
    var end: BlockVector3

    init(id: UUID = UUID(), start: BlockVector3, end: BlockVector3) {
        self.id = id
        self.start = start
        self.end = end
    }

    var length: Double { start.distance(to: end) }
}

struct BlockReferenceCamera: Codable, Sendable, Equatable {
    var target: BlockVector3
    var yawDegrees: Double
    var pitchDegrees: Double
    var distance: Double
    var fieldOfViewDegrees: Double
    var isOrthographic: Bool
    var rollDegrees: Double = 0
    /// Optical principal point in normalized canvas coordinates. Keeping this
    /// separate from framing lets a cropped or letterboxed reference image be
    /// calibrated without pretending its optical center is the canvas center.
    var principalPointNormalized = CanvasPoint(x: 0.5, y: 0.5)

    static let stageOneDefault = BlockReferenceCamera(
        target: BlockVector3(x: 0, y: 0, z: 70),
        yawDegrees: -45,
        pitchDegrees: 30,
        distance: 760,
        fieldOfViewDegrees: 42,
        isOrthographic: false
    )

    mutating func normalize() {
        yawDegrees = yawDegrees.isFinite ? yawDegrees.truncatingRemainder(dividingBy: 360) : -45
        pitchDegrees = min(max(pitchDegrees.isFinite ? pitchDegrees : 30, -89.9), 89.9)
        distance = min(max(distance.isFinite ? distance : 760, 20), 20_000)
        fieldOfViewDegrees = min(max(fieldOfViewDegrees.isFinite ? fieldOfViewDegrees : 42, 10), 120)
        rollDegrees = rollDegrees.isFinite ? rollDegrees.truncatingRemainder(dividingBy: 360) : 0
        principalPointNormalized.x = min(max(
            principalPointNormalized.x.isFinite ? principalPointNormalized.x : 0.5,
            -2
        ), 3)
        principalPointNormalized.y = min(max(
            principalPointNormalized.y.isFinite ? principalPointNormalized.y : 0.5,
            -2
        ), 3)
    }
}

extension BlockReferenceCamera {
    private enum CodingKeys: String, CodingKey {
        case target
        case yawDegrees
        case pitchDegrees
        case distance
        case fieldOfViewDegrees
        case isOrthographic
        case rollDegrees
        case principalPointNormalized
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decode(BlockVector3.self, forKey: .target)
        yawDegrees = try container.decode(Double.self, forKey: .yawDegrees)
        pitchDegrees = try container.decode(Double.self, forKey: .pitchDegrees)
        distance = try container.decode(Double.self, forKey: .distance)
        fieldOfViewDegrees = try container.decode(Double.self, forKey: .fieldOfViewDegrees)
        isOrthographic = try container.decode(Bool.self, forKey: .isOrthographic)
        rollDegrees = try container.decodeIfPresent(Double.self, forKey: .rollDegrees) ?? 0
        principalPointNormalized = try container.decodeIfPresent(
            CanvasPoint.self,
            forKey: .principalPointNormalized
        ) ?? CanvasPoint(x: 0.5, y: 0.5)
        normalize()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(target, forKey: .target)
        try container.encode(yawDegrees, forKey: .yawDegrees)
        try container.encode(pitchDegrees, forKey: .pitchDegrees)
        try container.encode(distance, forKey: .distance)
        try container.encode(fieldOfViewDegrees, forKey: .fieldOfViewDegrees)
        try container.encode(isOrthographic, forKey: .isOrthographic)
        try container.encode(rollDegrees, forKey: .rollDegrees)
        try container.encode(principalPointNormalized, forKey: .principalPointNormalized)
    }
}

enum BlockReferenceDisplayMode: String, Codable, CaseIterable, Sendable, Equatable {
    case wireframe
    case solid

    var displayName: String {
        switch self {
        case .wireframe: return "线框"
        case .solid: return "实体"
        }
    }
}

struct BlockReferenceDisplaySettings: Codable, Sendable, Equatable {
    var opacity: Float
    var showsFaces: Bool
    var showsEdges: Bool
    var isVisible: Bool
    var isFrozen: Bool
    var mode: BlockReferenceDisplayMode
    var showsPerspectiveGuides: Bool

    static let stageOneDefault = BlockReferenceDisplaySettings(
        opacity: 0.52,
        showsFaces: true,
        showsEdges: true,
        isVisible: true,
        isFrozen: false,
        mode: .solid,
        showsPerspectiveGuides: false
    )

    private enum CodingKeys: String, CodingKey {
        case opacity
        case showsFaces
        case showsEdges
        case isVisible
        case isFrozen
        case mode
        case showsPerspectiveGuides
    }

    init(
        opacity: Float,
        showsFaces: Bool,
        showsEdges: Bool,
        isVisible: Bool,
        isFrozen: Bool,
        mode: BlockReferenceDisplayMode,
        showsPerspectiveGuides: Bool = false
    ) {
        self.opacity = opacity
        self.showsFaces = showsFaces
        self.showsEdges = showsEdges
        self.isVisible = isVisible
        self.isFrozen = isFrozen
        self.mode = mode
        self.showsPerspectiveGuides = showsPerspectiveGuides
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        opacity = try container.decode(Float.self, forKey: .opacity)
        showsFaces = try container.decode(Bool.self, forKey: .showsFaces)
        showsEdges = try container.decode(Bool.self, forKey: .showsEdges)
        isVisible = try container.decode(Bool.self, forKey: .isVisible)
        isFrozen = try container.decode(Bool.self, forKey: .isFrozen)
        mode = try container.decodeIfPresent(BlockReferenceDisplayMode.self, forKey: .mode)
            ?? .wireframe
        showsPerspectiveGuides = try container.decodeIfPresent(Bool.self, forKey: .showsPerspectiveGuides) ?? false
    }

    mutating func normalize() {
        opacity = min(max(opacity, 0.05), 1)
    }
}

struct BlockReferenceSnapSettings: Codable, Sendable, Equatable {
    var enabledKinds: Set<BlockReferenceSnapKind>
    var gridSpacing: Double
    var screenTolerancePoints: Double

    static let stageOneDefault = BlockReferenceSnapSettings(
        enabledKinds: Set(BlockReferenceSnapKind.allCases),
        gridSpacing: 20,
        screenTolerancePoints: 12
    )

    mutating func normalize() {
        gridSpacing = min(max(abs(gridSpacing), 1), 1_000)
        screenTolerancePoints = min(max(abs(screenTolerancePoints), 2), 40)
    }
}

struct BlockReferenceScene: Codable, Sendable, Equatable {
    var objects: [BlockReferenceObject]
    var measurements: [BlockMeasurementGuide]
    var workingPlane: BlockWorkingPlane
    var camera: BlockReferenceCamera
    var display: BlockReferenceDisplaySettings
    var snap: BlockReferenceSnapSettings
    var groups: [BlockReferenceGroup]
    var cameraSlots: [BlockReferenceCameraSlot]
    var constructionLines: [BlockConstructionLine]
    var savedWorkingPlanes: [BlockSavedWorkingPlane]
    var section: BlockSectionSettings
    var snapshots: [BlockReferenceSceneSnapshot]
    var pivotMode: BlockReferencePivotMode
    var customPivot: BlockVector3
    var customModuleInstances: [BlockReferenceCustomModuleInstance]

    init(
        objects: [BlockReferenceObject],
        measurements: [BlockMeasurementGuide],
        workingPlane: BlockWorkingPlane,
        camera: BlockReferenceCamera,
        display: BlockReferenceDisplaySettings,
        snap: BlockReferenceSnapSettings,
        groups: [BlockReferenceGroup] = [],
        cameraSlots: [BlockReferenceCameraSlot] = [],
        constructionLines: [BlockConstructionLine] = [],
        savedWorkingPlanes: [BlockSavedWorkingPlane] = [],
        section: BlockSectionSettings = .disabled,
        snapshots: [BlockReferenceSceneSnapshot] = [],
        pivotMode: BlockReferencePivotMode = .selectionCenter,
        customPivot: BlockVector3 = .zero,
        customModuleInstances: [BlockReferenceCustomModuleInstance] = []
    ) {
        self.objects = objects
        self.measurements = measurements
        self.workingPlane = workingPlane
        self.camera = camera
        self.display = display
        self.snap = snap
        self.groups = groups
        self.cameraSlots = cameraSlots
        self.constructionLines = constructionLines
        self.savedWorkingPlanes = savedWorkingPlanes
        self.section = section
        self.snapshots = snapshots
        self.pivotMode = pivotMode
        self.customPivot = customPivot
        self.customModuleInstances = customModuleInstances
        normalize()
    }

    private enum CodingKeys: String, CodingKey {
        case objects, measurements, workingPlane, camera, display, snap
        case groups, cameraSlots, constructionLines, savedWorkingPlanes, section, snapshots
        case pivotMode, customPivot, customModuleInstances
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        objects = try container.decodeIfPresent([BlockReferenceObject].self, forKey: .objects) ?? []
        measurements = try container.decodeIfPresent([BlockMeasurementGuide].self, forKey: .measurements) ?? []
        workingPlane = try container.decodeIfPresent(BlockWorkingPlane.self, forKey: .workingPlane) ?? .ground
        camera = try container.decodeIfPresent(BlockReferenceCamera.self, forKey: .camera) ?? .stageOneDefault
        display = try container.decodeIfPresent(BlockReferenceDisplaySettings.self, forKey: .display) ?? .stageOneDefault
        snap = try container.decodeIfPresent(BlockReferenceSnapSettings.self, forKey: .snap) ?? .stageOneDefault
        groups = try container.decodeIfPresent([BlockReferenceGroup].self, forKey: .groups) ?? []
        cameraSlots = try container.decodeIfPresent([BlockReferenceCameraSlot].self, forKey: .cameraSlots) ?? []
        constructionLines = try container.decodeIfPresent([BlockConstructionLine].self, forKey: .constructionLines) ?? []
        savedWorkingPlanes = try container.decodeIfPresent([BlockSavedWorkingPlane].self, forKey: .savedWorkingPlanes) ?? []
        section = try container.decodeIfPresent(BlockSectionSettings.self, forKey: .section) ?? .disabled
        snapshots = try container.decodeIfPresent([BlockReferenceSceneSnapshot].self, forKey: .snapshots) ?? []
        pivotMode = try container.decodeIfPresent(BlockReferencePivotMode.self, forKey: .pivotMode) ?? .selectionCenter
        customPivot = try container.decodeIfPresent(BlockVector3.self, forKey: .customPivot) ?? .zero
        customModuleInstances = try container.decodeIfPresent(
            [BlockReferenceCustomModuleInstance].self,
            forKey: .customModuleInstances
        ) ?? []
        normalize()
    }

    static let empty = BlockReferenceScene(
        objects: [],
        measurements: [],
        workingPlane: .ground,
        camera: .stageOneDefault,
        display: .stageOneDefault,
        snap: .stageOneDefault
    )

    mutating func normalize() {
        objects = objects.map { object in
            var normalized = object
            normalized.normalize()
            return normalized
        }
        let validObjectIDs = Set(objects.map(\.id))
        var claimedModuleObjectIDs = Set<UUID>()
        customModuleInstances = customModuleInstances.compactMap { instance in
            var repaired = instance
            repaired.objectIDs = repaired.objectIDs.filter {
                validObjectIDs.contains($0) && claimedModuleObjectIDs.insert($0).inserted
            }
            return repaired.objectIDs.isEmpty ? nil : repaired
        }
        groups = groups.filter { group in objects.contains(where: { $0.groupID == group.id }) }
        let validGroupIDs = Set(groups.map(\.id))
        for index in objects.indices where objects[index].groupID.map({ !validGroupIDs.contains($0) }) == true {
            objects[index].groupID = nil
        }
        measurements = Array(measurements.prefix(256))
        cameraSlots = Array(
            Dictionary(grouping: cameraSlots, by: \.index)
                .compactMap { $0.value.last }
                .sorted { $0.index < $1.index }
                .prefix(5)
        )
        constructionLines = Array(constructionLines.prefix(256))
        savedWorkingPlanes = Array(savedWorkingPlanes.prefix(16))
        snapshots = Array(snapshots.prefix(6))
        if let sourceID = workingPlane.sourceObjectID, !validObjectIDs.contains(sourceID) {
            workingPlane = .ground
        }
        camera.normalize()
        display.normalize()
        snap.normalize()
    }
}

enum BlockCreationPhase: Sendable, Equatable {
    case idle
    case drawingBase
    case awaitingExtrusion
    case extruding
    case movingObject
    case transformingGizmo
    case posingHuman
    case measuring
}

struct BlockHumanJointDragSession: Sendable, Equatable {
    var objectID: UUID
    var joint: BlockHumanJoint
    var axis: BlockReferenceAxis
    var worldAxis: BlockVector3
    var jointWorldPoint: BlockVector3
    var startCanvasPoint: CanvasPoint
    var originalPose: BlockHumanPose
    var lastRotationVector: BlockVector3?
    var lastScreenAngle: Double?
    var accumulatedDegrees: Double = 0
}

struct BlockCreationDraft: Sendable, Equatable {
    var kind: BlockPrimitiveKind
    var plane: BlockWorkingPlane
    var baseStart: BlockVector3
    var baseEnd: BlockVector3
    var height: Double

    var center: BlockVector3 {
        let start = plane.coordinates(of: baseStart)
        let end = plane.coordinates(of: baseEnd)
        return plane.worldPoint(u: (start.u + end.u) * 0.5, v: (start.v + end.v) * 0.5)
    }

    var baseCorners: [BlockVector3] {
        let start = plane.coordinates(of: baseStart)
        let end = plane.coordinates(of: baseEnd)
        let minimumU = min(start.u, end.u)
        let maximumU = max(start.u, end.u)
        let minimumV = min(start.v, end.v)
        let maximumV = max(start.v, end.v)
        return [
            plane.worldPoint(u: minimumU, v: minimumV),
            plane.worldPoint(u: maximumU, v: minimumV),
            plane.worldPoint(u: maximumU, v: maximumV),
            plane.worldPoint(u: minimumU, v: maximumV)
        ]
    }

    var dimensions: BlockDimensions {
        let start = plane.coordinates(of: baseStart)
        let end = plane.coordinates(of: baseEnd)
        let width = max(abs(end.u - start.u), 1)
        let depth = max(abs(end.v - start.v), 1)
        if kind == .sphere {
            let diameter = max(width, depth)
            return BlockDimensions(width: diameter, depth: diameter, height: diameter)
        }
        return BlockDimensions(width: width, depth: depth, height: max(abs(height), 1))
    }
}

struct BlockReferenceNumericTransform: Sendable, Equatable {
    var objectID: UUID
    var kind: BlockReferenceNumericTransformKind
    var axis: BlockReferenceAxis?
    var input: String
    var originalPosition: BlockVector3
    var originalRotation: BlockEulerRotation
    var originalTransforms: [UUID: BlockReferenceObjectTransformSnapshot]
    var originalModuleBasePoints: [UUID: BlockVector3]
    var originalCustomPivot: BlockVector3?
    var pivot: BlockVector3
    var axisDirections: [BlockReferenceAxis: BlockVector3]
    var coordinateSpace: BlockReferenceGizmoCoordinateSpace

    init(
        objectID: UUID,
        kind: BlockReferenceNumericTransformKind,
        axis: BlockReferenceAxis?,
        input: String,
        originalPosition: BlockVector3,
        originalRotation: BlockEulerRotation,
        originalTransforms: [UUID: BlockReferenceObjectTransformSnapshot]? = nil,
        originalModuleBasePoints: [UUID: BlockVector3] = [:],
        originalCustomPivot: BlockVector3? = nil,
        pivot: BlockVector3? = nil,
        axisDirections: [BlockReferenceAxis: BlockVector3]? = nil,
        coordinateSpace: BlockReferenceGizmoCoordinateSpace = .world
    ) {
        self.objectID = objectID
        self.kind = kind
        self.axis = axis
        self.input = input
        self.originalPosition = originalPosition
        self.originalRotation = originalRotation
        self.originalTransforms = originalTransforms ?? [
            objectID: BlockReferenceObjectTransformSnapshot(
                position: originalPosition,
                rotation: originalRotation,
                dimensions: .stageOneDefault
            )
        ]
        self.originalModuleBasePoints = originalModuleBasePoints
        self.originalCustomPivot = originalCustomPivot
        self.pivot = pivot ?? originalPosition
        self.axisDirections = axisDirections ?? Dictionary(
            uniqueKeysWithValues: BlockReferenceAxis.allCases.map { ($0, $0.unitVector) }
        )
        self.coordinateSpace = coordinateSpace
    }

    var value: Double? {
        let normalized = input.replacingOccurrences(of: ",", with: ".")
        guard !normalized.isEmpty, normalized != "-", normalized != ".", normalized != "-." else {
            return nil
        }
        guard let parsed = Double(normalized), parsed.isFinite else { return nil }
        return parsed
    }

    func applying(to object: BlockReferenceObject) -> BlockReferenceObject {
        guard let snapshot = originalTransforms[object.id],
              let value else { return object }
        var result = object
        switch kind {
        case .move:
            guard let axis else { return object }
            let direction = axisDirections[axis]?.normalized(fallback: axis.unitVector) ?? axis.unitVector
            result.position = snapshot.position + direction * value
        case .rotate:
            guard let axis else { return object }
            let direction = axisDirections[axis]?.normalized(fallback: axis.unitVector) ?? axis.unitVector
            result.position = pivot + blockRotateAroundAxis(
                snapshot.position - pivot,
                axis: direction,
                degrees: value
            )
            result.rotation = blockRotation(
                applyingWorldAxisVector: direction,
                degrees: value,
                to: snapshot.rotation
            )
        case .scale:
            let factor = min(max(abs(value), 0.01), 100)
            if let axis {
                let direction = axisDirections[axis]?.normalized(fallback: axis.unitVector) ?? axis.unitVector
                let offset = snapshot.position - pivot
                result.position = snapshot.position + direction * (offset.dot(direction) * (factor - 1))
                switch axis {
                case .x: result.dimensions.width = snapshot.dimensions.width * factor
                case .y: result.dimensions.depth = snapshot.dimensions.depth * factor
                case .z: result.dimensions.height = snapshot.dimensions.height * factor
                }
            } else {
                result.position = pivot + (snapshot.position - pivot) * factor
                result.dimensions = BlockDimensions(
                    width: snapshot.dimensions.width * factor,
                    depth: snapshot.dimensions.depth * factor,
                    height: snapshot.dimensions.height * factor
                )
            }
        }
        if object.moduleKind != nil,
           let localBasePoint = object.moduleBasePointOffset {
            var originalObject = object
            originalObject.position = snapshot.position
            originalObject.rotation = snapshot.rotation
            originalObject.dimensions = snapshot.dimensions
            let transformedBasePoint = applying(
                to: blockTransformPoint(localBasePoint, object: originalObject)
            )
            result.moduleBasePointOffset = blockInverseTransformPoint(
                transformedBasePoint,
                object: result
            )
        }
        result.normalize()
        return result
    }

    func applying(to point: BlockVector3) -> BlockVector3 {
        guard let value else { return point }
        switch kind {
        case .move:
            guard let axis else { return point }
            let direction = axisDirections[axis]?.normalized(fallback: axis.unitVector) ?? axis.unitVector
            return point + direction * value
        case .rotate:
            guard let axis else { return point }
            let direction = axisDirections[axis]?.normalized(fallback: axis.unitVector) ?? axis.unitVector
            return pivot + blockRotateAroundAxis(point - pivot, axis: direction, degrees: value)
        case .scale:
            let factor = min(max(abs(value), 0.01), 100)
            guard let axis else { return pivot + (point - pivot) * factor }
            let direction = axisDirections[axis]?.normalized(fallback: axis.unitVector) ?? axis.unitVector
            let offset = point - pivot
            return point + direction * (offset.dot(direction) * (factor - 1))
        }
    }

    var summary: String {
        let axisText = axis.map { "\($0.displayName)轴" } ?? "选择轴"
        let inputText = input.isEmpty ? "输入数值" : input
        return "\(kind.displayName) · \(axisText) · \(inputText)"
    }
}

struct BlockReferenceGizmoAdjustment: Sendable, Equatable {
    var objectID: UUID
    var handle: BlockReferenceGizmoHandle
    var input: String
    var originalPosition: BlockVector3
    var originalRotation: BlockEulerRotation
    var originalTransforms: [UUID: BlockReferenceObjectTransformSnapshot]
    var originalModuleBasePoints: [UUID: BlockVector3]
    var originalCustomPivot: BlockVector3?
    var pivot: BlockVector3
    var axisDirections: [BlockReferenceAxis: BlockVector3]

    init(
        objectID: UUID,
        handle: BlockReferenceGizmoHandle,
        input: String,
        originalPosition: BlockVector3,
        originalRotation: BlockEulerRotation,
        originalTransforms: [UUID: BlockReferenceObjectTransformSnapshot]? = nil,
        originalModuleBasePoints: [UUID: BlockVector3] = [:],
        originalCustomPivot: BlockVector3? = nil,
        pivot: BlockVector3? = nil,
        axisDirections: [BlockReferenceAxis: BlockVector3]? = nil
    ) {
        self.objectID = objectID
        self.handle = handle
        self.input = input
        self.originalPosition = originalPosition
        self.originalRotation = originalRotation
        self.originalTransforms = originalTransforms ?? [
            objectID: BlockReferenceObjectTransformSnapshot(
                position: originalPosition,
                rotation: originalRotation,
                dimensions: .stageOneDefault
            )
        ]
        self.originalModuleBasePoints = originalModuleBasePoints
        self.originalCustomPivot = originalCustomPivot
        self.pivot = pivot ?? originalPosition
        self.axisDirections = axisDirections ?? Dictionary(
            uniqueKeysWithValues: BlockReferenceAxis.allCases.map { ($0, $0.unitVector) }
        )
    }

    var value: Double? {
        let normalized = input.replacingOccurrences(of: ",", with: ".")
        guard !normalized.isEmpty, normalized != "-", normalized != ".", normalized != "-." else {
            return nil
        }
        guard let parsed = Double(normalized), parsed.isFinite else { return nil }
        return parsed
    }

    var numericTransform: BlockReferenceNumericTransform {
        BlockReferenceNumericTransform(
            objectID: objectID,
            kind: handle.kind,
            axis: handle.isUniformScale ? nil : handle.axis,
            input: input,
            originalPosition: originalPosition,
            originalRotation: originalRotation,
            originalTransforms: originalTransforms,
            originalModuleBasePoints: originalModuleBasePoints,
            originalCustomPivot: originalCustomPivot,
            pivot: pivot,
            axisDirections: axisDirections
        )
    }

    func applying(to object: BlockReferenceObject) -> BlockReferenceObject {
        numericTransform.applying(to: object)
    }
}

struct BlockReferenceGizmoDragSession: Sendable, Equatable {
    var adjustment: BlockReferenceGizmoAdjustment
    var startCanvasPoint: CanvasPoint
    var axisCanvasDirection: CanvasPoint?
    var worldUnitsPerCanvasPixel: Double?
    var lastRotationVector: BlockVector3?
    var lastScreenAngle: Double?
    var accumulatedValue: Double = 0
}

struct BlockReferenceEditorState: Sendable, Equatable {
    var mode: BlockReferenceEditorMode = .select
    var buildsDirectlyOnSurfaces = false
    var selectedObjectID: UUID?
    var selectedObjectIDs: Set<UUID> = []
    var selectedFaceIndex: Int?
    var gizmoCoordinateSpace: BlockReferenceGizmoCoordinateSpace = .world
    var phase: BlockCreationPhase = .idle
    var draft: BlockCreationDraft?
    var draftMeasurement: BlockMeasurementGuide?
    var snapPoint: BlockVector3?
    var numericTransform: BlockReferenceNumericTransform?
    var hoveredGizmoHandle: BlockReferenceGizmoHandle?
    var activeGizmoHandle: BlockReferenceGizmoHandle?
    var gizmoLiveValue: Double?
    var gizmoAdjustment: BlockReferenceGizmoAdjustment?
    var awaitsMirrorAxis = false
    var selectedHumanJoint: BlockHumanJoint?
    var activeHumanJointAxis: BlockReferenceAxis?
    var perspectiveMatch = BlockReferencePerspectiveMatchState()
    var instruction: String = "选择体块，或选择一种几何体开始建立。"

    var resolvedSelectedObjectIDs: Set<UUID> {
        if selectedObjectIDs.isEmpty, let selectedObjectID {
            return [selectedObjectID]
        }
        return selectedObjectIDs
    }
}

func blockReferenceExpandedSelectionIDs(
    in scene: BlockReferenceScene,
    selection: Set<UUID>
) -> Set<UUID> {
    let existingSelection = selection.intersection(scene.objects.map(\.id))
    let selectedGroupIDs = Set(
        scene.objects
            .filter { existingSelection.contains($0.id) }
            .compactMap(\.groupID)
    )
    guard !selectedGroupIDs.isEmpty else { return existingSelection }
    return existingSelection.union(
        scene.objects
            .filter { $0.groupID.map(selectedGroupIDs.contains) == true }
            .map(\.id)
    )
}

func blockReferenceSelectedModuleBasePoint(
    in scene: BlockReferenceScene,
    selection: Set<UUID>,
    activeObjectID: UUID?
) -> BlockVector3? {
    let selectedIDs = blockReferenceExpandedSelectionIDs(in: scene, selection: selection)
    guard !selectedIDs.isEmpty else { return nil }

    let exactInstances = scene.customModuleInstances.filter {
        Set($0.objectIDs) == selectedIDs
    }
    if let activeObjectID,
       let instance = exactInstances.first(where: { $0.objectIDs.contains(activeObjectID) }) {
        return instance.basePoint
    }
    if let instance = exactInstances.first {
        return instance.basePoint
    }

    guard selectedIDs.count == 1,
          let objectID = activeObjectID ?? selectedIDs.first,
          selectedIDs.contains(objectID),
          !scene.customModuleInstances.contains(where: { $0.objectIDs.contains(objectID) }),
          let object = scene.objects.first(where: { $0.id == objectID })
    else { return nil }
    return blockReferenceObjectModuleBasePoint(object)
}

@discardableResult
func blockReferenceSetSelectedModuleBasePoint(
    _ basePoint: BlockVector3,
    in scene: inout BlockReferenceScene,
    selection: Set<UUID>,
    activeObjectID: UUID?
) -> Bool {
    let selectedIDs = blockReferenceExpandedSelectionIDs(in: scene, selection: selection)
    guard !selectedIDs.isEmpty else { return false }

    let exactInstanceIndices = scene.customModuleInstances.indices.filter {
        Set(scene.customModuleInstances[$0].objectIDs) == selectedIDs
    }
    let instanceIndex = activeObjectID.flatMap { activeID in
        exactInstanceIndices.first(where: {
            scene.customModuleInstances[$0].objectIDs.contains(activeID)
        })
    } ?? exactInstanceIndices.first
    if let instanceIndex {
        scene.customModuleInstances[instanceIndex].basePoint = basePoint
        return true
    }

    guard selectedIDs.count == 1,
          let objectID = activeObjectID ?? selectedIDs.first,
          selectedIDs.contains(objectID),
          !scene.customModuleInstances.contains(where: { $0.objectIDs.contains(objectID) }),
          let objectIndex = scene.objects.firstIndex(where: { $0.id == objectID }),
          scene.objects[objectIndex].moduleKind != nil
    else { return false }
    scene.objects[objectIndex].moduleBasePointOffset = blockInverseTransformPoint(
        basePoint,
        object: scene.objects[objectIndex]
    )
    return true
}

import Foundation

/// Drawing-reference metadata intentionally kept independent from SwiftUI/AppKit.
/// These values are part of the ArtDocument and therefore travel with the canvas.
enum BlockReferenceColorTag: String, Codable, CaseIterable, Sendable, Equatable {
    case neutral
    case red
    case orange
    case yellow
    case green
    case blue
    case purple

    var displayName: String {
        switch self {
        case .neutral: return "默认"
        case .red: return "红"
        case .orange: return "橙"
        case .yellow: return "黄"
        case .green: return "绿"
        case .blue: return "蓝"
        case .purple: return "紫"
        }
    }
}

struct BlockReferenceObjectStyle: Codable, Sendable, Equatable {
    var colorTag: BlockReferenceColorTag
    var opacity: Float
    var showsOccludedEdges: Bool
    var participatesInSnapping: Bool
    var includedInFrozenReference: Bool

    static let `default` = BlockReferenceObjectStyle(
        colorTag: .neutral,
        opacity: 1,
        showsOccludedEdges: false,
        participatesInSnapping: true,
        includedInFrozenReference: true
    )

    mutating func normalize() {
        opacity = min(max(opacity.isFinite ? opacity : 1, 0.05), 1)
    }
}

struct BlockReferenceGroup: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var name: String
    var pivot: BlockVector3

    init(id: UUID = UUID(), name: String, pivot: BlockVector3) {
        self.id = id
        self.name = name
        self.pivot = pivot
    }
}

struct BlockReferenceCameraSlot: Identifiable, Codable, Sendable, Equatable {
    var id: Int { index }
    var index: Int
    var name: String
    var camera: BlockReferenceCamera
    var isLocked: Bool

    init(index: Int, name: String, camera: BlockReferenceCamera, isLocked: Bool = false) {
        self.index = min(max(index, 1), 5)
        self.name = name
        self.camera = camera
        self.isLocked = isLocked
    }
}

struct BlockConstructionLine: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var name: String
    var origin: BlockVector3
    var direction: BlockVector3
    var isVisible: Bool

    init(
        id: UUID = UUID(),
        name: String,
        origin: BlockVector3,
        direction: BlockVector3,
        isVisible: Bool = true
    ) {
        self.id = id
        self.name = name
        self.origin = origin
        self.direction = direction.normalized(fallback: .unitX)
        self.isVisible = isVisible
    }
}

struct BlockSavedWorkingPlane: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var name: String
    var plane: BlockWorkingPlane

    init(id: UUID = UUID(), name: String, plane: BlockWorkingPlane) {
        self.id = id
        self.name = name
        self.plane = plane
    }
}

struct BlockSectionSettings: Codable, Sendable, Equatable {
    var isEnabled: Bool
    var plane: BlockWorkingPlane
    var isInverted: Bool

    static let disabled = BlockSectionSettings(
        isEnabled: false,
        plane: .ground,
        isInverted: false
    )
}

/// A bounded scene-state checkpoint. Snapshots deliberately do not contain other
/// snapshots, preventing recursive project growth.
struct BlockReferenceSceneSnapshot: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var name: String
    var objects: [BlockReferenceObject]
    var measurements: [BlockMeasurementGuide]
    var workingPlane: BlockWorkingPlane
    var constructionLines: [BlockConstructionLine]
    var savedWorkingPlanes: [BlockSavedWorkingPlane]
    var groups: [BlockReferenceGroup]
    var camera: BlockReferenceCamera
    var section: BlockSectionSettings
    // Optional for compatibility with snapshots saved before the workflow revision.
    var customModuleInstances: [BlockReferenceCustomModuleInstance]?
    var pivotMode: BlockReferencePivotMode?
    var customPivot: BlockVector3?
    var display: BlockReferenceDisplaySettings?
    var snap: BlockReferenceSnapSettings?
    var cameraSlots: [BlockReferenceCameraSlot]?

    init(
        id: UUID = UUID(),
        name: String,
        objects: [BlockReferenceObject],
        measurements: [BlockMeasurementGuide],
        workingPlane: BlockWorkingPlane,
        constructionLines: [BlockConstructionLine],
        savedWorkingPlanes: [BlockSavedWorkingPlane],
        groups: [BlockReferenceGroup],
        camera: BlockReferenceCamera,
        section: BlockSectionSettings,
        customModuleInstances: [BlockReferenceCustomModuleInstance]? = nil,
        pivotMode: BlockReferencePivotMode? = nil,
        customPivot: BlockVector3? = nil,
        display: BlockReferenceDisplaySettings? = nil,
        snap: BlockReferenceSnapSettings? = nil,
        cameraSlots: [BlockReferenceCameraSlot]? = nil
    ) {
        self.id = id
        self.name = name
        self.objects = objects
        self.measurements = measurements
        self.workingPlane = workingPlane
        self.constructionLines = constructionLines
        self.savedWorkingPlanes = savedWorkingPlanes
        self.groups = groups
        self.camera = camera
        self.section = section
        self.customModuleInstances = customModuleInstances
        self.pivotMode = pivotMode
        self.customPivot = customPivot
        self.display = display
        self.snap = snap
        self.cameraSlots = cameraSlots
    }
}

struct BlockHumanPose: Codable, Sendable, Equatable {
    /// Axial rotation of the pelvis around the upright body axis.
    var pelvisYawDegrees: Double
    var torsoPitchDegrees: Double
    var torsoYawDegrees: Double
    var torsoRollDegrees: Double
    var headPitchDegrees: Double
    var headYawDegrees: Double
    var headRollDegrees: Double
    /// Legacy shoulder values now mean anatomical abduction/adduction.
    var leftShoulderDegrees: Double
    var rightShoulderDegrees: Double
    var leftShoulderFlexionDegrees: Double
    var rightShoulderFlexionDegrees: Double
    var leftShoulderTwistDegrees: Double
    var rightShoulderTwistDegrees: Double
    var leftElbowDegrees: Double
    var rightElbowDegrees: Double
    /// Hip values mean flexion/extension in the sagittal plane.
    var leftHipDegrees: Double
    var rightHipDegrees: Double
    var leftHipAbductionDegrees: Double
    var rightHipAbductionDegrees: Double
    var leftHipTwistDegrees: Double
    var rightHipTwistDegrees: Double
    var leftKneeDegrees: Double
    var rightKneeDegrees: Double

    init(
        pelvisYawDegrees: Double = 0,
        torsoPitchDegrees: Double,
        torsoYawDegrees: Double,
        torsoRollDegrees: Double = 0,
        headPitchDegrees: Double,
        headYawDegrees: Double = 0,
        headRollDegrees: Double = 0,
        leftShoulderDegrees: Double,
        rightShoulderDegrees: Double,
        leftShoulderFlexionDegrees: Double = 0,
        rightShoulderFlexionDegrees: Double = 0,
        leftShoulderTwistDegrees: Double = 0,
        rightShoulderTwistDegrees: Double = 0,
        leftElbowDegrees: Double,
        rightElbowDegrees: Double,
        leftHipDegrees: Double,
        rightHipDegrees: Double,
        leftHipAbductionDegrees: Double = 0,
        rightHipAbductionDegrees: Double = 0,
        leftHipTwistDegrees: Double = 0,
        rightHipTwistDegrees: Double = 0,
        leftKneeDegrees: Double,
        rightKneeDegrees: Double
    ) {
        self.pelvisYawDegrees = pelvisYawDegrees
        self.torsoPitchDegrees = torsoPitchDegrees
        self.torsoYawDegrees = torsoYawDegrees
        self.torsoRollDegrees = torsoRollDegrees
        self.headPitchDegrees = headPitchDegrees
        self.headYawDegrees = headYawDegrees
        self.headRollDegrees = headRollDegrees
        self.leftShoulderDegrees = leftShoulderDegrees
        self.rightShoulderDegrees = rightShoulderDegrees
        self.leftShoulderFlexionDegrees = leftShoulderFlexionDegrees
        self.rightShoulderFlexionDegrees = rightShoulderFlexionDegrees
        self.leftShoulderTwistDegrees = leftShoulderTwistDegrees
        self.rightShoulderTwistDegrees = rightShoulderTwistDegrees
        self.leftElbowDegrees = leftElbowDegrees
        self.rightElbowDegrees = rightElbowDegrees
        self.leftHipDegrees = leftHipDegrees
        self.rightHipDegrees = rightHipDegrees
        self.leftHipAbductionDegrees = leftHipAbductionDegrees
        self.rightHipAbductionDegrees = rightHipAbductionDegrees
        self.leftHipTwistDegrees = leftHipTwistDegrees
        self.rightHipTwistDegrees = rightHipTwistDegrees
        self.leftKneeDegrees = leftKneeDegrees
        self.rightKneeDegrees = rightKneeDegrees
        normalize()
    }

    static let standing = BlockHumanPose(
        torsoPitchDegrees: 0, torsoYawDegrees: 0, headPitchDegrees: 0,
        leftShoulderDegrees: 6, rightShoulderDegrees: 6,
        leftElbowDegrees: 0, rightElbowDegrees: 0,
        leftHipDegrees: 0, rightHipDegrees: 0,
        leftKneeDegrees: 0, rightKneeDegrees: 0
    )

    mutating func normalize() {
        pelvisYawDegrees = pelvisYawDegrees.clamped(to: -180...180)
        torsoPitchDegrees = torsoPitchDegrees.clamped(to: -60...60)
        torsoYawDegrees = torsoYawDegrees.clamped(to: -90...90)
        torsoRollDegrees = torsoRollDegrees.clamped(to: -60...60)
        headPitchDegrees = headPitchDegrees.clamped(to: -60...60)
        headYawDegrees = headYawDegrees.clamped(to: -80...80)
        headRollDegrees = headRollDegrees.clamped(to: -45...45)
        leftShoulderDegrees = leftShoulderDegrees.clamped(to: -30...170)
        rightShoulderDegrees = rightShoulderDegrees.clamped(to: -30...170)
        leftShoulderFlexionDegrees = leftShoulderFlexionDegrees.clamped(to: -80...180)
        rightShoulderFlexionDegrees = rightShoulderFlexionDegrees.clamped(to: -80...180)
        leftShoulderTwistDegrees = leftShoulderTwistDegrees.clamped(to: -90...90)
        rightShoulderTwistDegrees = rightShoulderTwistDegrees.clamped(to: -90...90)
        leftElbowDegrees = leftElbowDegrees.clamped(to: 0...150)
        rightElbowDegrees = rightElbowDegrees.clamped(to: 0...150)
        leftHipDegrees = leftHipDegrees.clamped(to: -120...120)
        rightHipDegrees = rightHipDegrees.clamped(to: -120...120)
        leftHipAbductionDegrees = leftHipAbductionDegrees.clamped(to: -45...60)
        rightHipAbductionDegrees = rightHipAbductionDegrees.clamped(to: -45...60)
        leftHipTwistDegrees = leftHipTwistDegrees.clamped(to: -60...60)
        rightHipTwistDegrees = rightHipTwistDegrees.clamped(to: -60...60)
        leftKneeDegrees = leftKneeDegrees.clamped(to: 0...150)
        rightKneeDegrees = rightKneeDegrees.clamped(to: 0...150)
    }

    private enum CodingKeys: String, CodingKey {
        case pelvisYawDegrees
        case torsoPitchDegrees, torsoYawDegrees, torsoRollDegrees
        case headPitchDegrees, headYawDegrees, headRollDegrees
        case leftShoulderDegrees, rightShoulderDegrees
        case leftShoulderFlexionDegrees, rightShoulderFlexionDegrees
        case leftShoulderTwistDegrees, rightShoulderTwistDegrees
        case leftElbowDegrees, rightElbowDegrees
        case leftHipDegrees, rightHipDegrees
        case leftHipAbductionDegrees, rightHipAbductionDegrees
        case leftHipTwistDegrees, rightHipTwistDegrees
        case leftKneeDegrees, rightKneeDegrees
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            pelvisYawDegrees: try container.decodeIfPresent(Double.self, forKey: .pelvisYawDegrees) ?? 0,
            torsoPitchDegrees: try container.decodeIfPresent(Double.self, forKey: .torsoPitchDegrees) ?? 0,
            torsoYawDegrees: try container.decodeIfPresent(Double.self, forKey: .torsoYawDegrees) ?? 0,
            torsoRollDegrees: try container.decodeIfPresent(Double.self, forKey: .torsoRollDegrees) ?? 0,
            headPitchDegrees: try container.decodeIfPresent(Double.self, forKey: .headPitchDegrees) ?? 0,
            headYawDegrees: try container.decodeIfPresent(Double.self, forKey: .headYawDegrees) ?? 0,
            headRollDegrees: try container.decodeIfPresent(Double.self, forKey: .headRollDegrees) ?? 0,
            leftShoulderDegrees: try container.decodeIfPresent(Double.self, forKey: .leftShoulderDegrees) ?? 6,
            rightShoulderDegrees: try container.decodeIfPresent(Double.self, forKey: .rightShoulderDegrees) ?? 6,
            leftShoulderFlexionDegrees: try container.decodeIfPresent(Double.self, forKey: .leftShoulderFlexionDegrees) ?? 0,
            rightShoulderFlexionDegrees: try container.decodeIfPresent(Double.self, forKey: .rightShoulderFlexionDegrees) ?? 0,
            leftShoulderTwistDegrees: try container.decodeIfPresent(Double.self, forKey: .leftShoulderTwistDegrees) ?? 0,
            rightShoulderTwistDegrees: try container.decodeIfPresent(Double.self, forKey: .rightShoulderTwistDegrees) ?? 0,
            leftElbowDegrees: try container.decodeIfPresent(Double.self, forKey: .leftElbowDegrees) ?? 0,
            rightElbowDegrees: try container.decodeIfPresent(Double.self, forKey: .rightElbowDegrees) ?? 0,
            leftHipDegrees: try container.decodeIfPresent(Double.self, forKey: .leftHipDegrees) ?? 0,
            rightHipDegrees: try container.decodeIfPresent(Double.self, forKey: .rightHipDegrees) ?? 0,
            leftHipAbductionDegrees: try container.decodeIfPresent(Double.self, forKey: .leftHipAbductionDegrees) ?? 0,
            rightHipAbductionDegrees: try container.decodeIfPresent(Double.self, forKey: .rightHipAbductionDegrees) ?? 0,
            leftHipTwistDegrees: try container.decodeIfPresent(Double.self, forKey: .leftHipTwistDegrees) ?? 0,
            rightHipTwistDegrees: try container.decodeIfPresent(Double.self, forKey: .rightHipTwistDegrees) ?? 0,
            leftKneeDegrees: try container.decodeIfPresent(Double.self, forKey: .leftKneeDegrees) ?? 0,
            rightKneeDegrees: try container.decodeIfPresent(Double.self, forKey: .rightKneeDegrees) ?? 0
        )
    }
}

struct BlockReferenceModuleParameters: Codable, Sendable, Equatable {
    var count: Int
    var secondarySize: Double
    var thickness: Double

    static let `default` = BlockReferenceModuleParameters(count: 5, secondarySize: 30, thickness: 12)

    mutating func normalize() {
        count = min(max(count, 1), 32)
        secondarySize = min(max(abs(secondarySize), 1), 10_000)
        thickness = min(max(abs(thickness), 1), 10_000)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        guard isFinite else { return 0 }
        return min(max(self, range.lowerBound), range.upperBound)
    }
}

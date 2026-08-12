import Foundation

enum LayerKind: String, Codable, Sendable, Equatable {
    case paint
    case group
}

enum LayerBlendMode: String, Codable, CaseIterable, Sendable, Equatable {
    case normal
    case multiply
    case screen
    case add
    case overlay
    case softLight
    case darken
    case lighten

    var displayName: String {
        switch self {
        case .normal: "正常"
        case .multiply: "正片叠底"
        case .screen: "滤色"
        case .add: "添加"
        case .overlay: "叠加"
        case .softLight: "柔光"
        case .darken: "变暗"
        case .lighten: "变亮"
        }
    }
}

struct LayerMaskDescriptor: Codable, Sendable, Equatable {
    var isEnabled: Bool

    init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }
}

struct LayerID: Hashable, Codable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

struct LayerRecord: Codable, Sendable, Equatable {
    let id: LayerID
    var name: String
    var kind: LayerKind
    var parentID: LayerID?
    var isVisible: Bool
    var isLocked: Bool
    var locksTransparentPixels: Bool
    var opacity: Float
    var blendMode: LayerBlendMode
    var clipTargetLayerID: LayerID?
    var isReference: Bool
    var mask: LayerMaskDescriptor?
    var adjustment: CanvasAdjustmentDescriptor?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case parentID
        case isVisible
        case isLocked
        case locksTransparentPixels
        case opacity
        case blendMode
        case clipTargetLayerID
        case isReference
        case mask
        case adjustment
    }

    init(
        id: LayerID,
        name: String,
        kind: LayerKind = .paint,
        parentID: LayerID? = nil,
        isVisible: Bool,
        isLocked: Bool,
        locksTransparentPixels: Bool,
        opacity: Float,
        blendMode: LayerBlendMode = .normal,
        clipTargetLayerID: LayerID? = nil,
        isReference: Bool = false,
        mask: LayerMaskDescriptor? = nil,
        adjustment: CanvasAdjustmentDescriptor? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.parentID = parentID
        self.isVisible = isVisible
        self.isLocked = isLocked
        self.locksTransparentPixels = locksTransparentPixels
        self.opacity = opacity
        self.blendMode = blendMode
        self.clipTargetLayerID = clipTargetLayerID
        self.isReference = isReference
        self.mask = mask
        self.adjustment = adjustment
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(LayerID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decodeIfPresent(LayerKind.self, forKey: .kind) ?? .paint
        parentID = try container.decodeIfPresent(LayerID.self, forKey: .parentID)
        isVisible = try container.decode(Bool.self, forKey: .isVisible)
        isLocked = try container.decode(Bool.self, forKey: .isLocked)
        locksTransparentPixels = try container.decodeIfPresent(Bool.self, forKey: .locksTransparentPixels) ?? false
        opacity = try container.decode(Float.self, forKey: .opacity)
        blendMode = try container.decodeIfPresent(LayerBlendMode.self, forKey: .blendMode) ?? .normal
        clipTargetLayerID = try container.decodeIfPresent(LayerID.self, forKey: .clipTargetLayerID)
        isReference = try container.decodeIfPresent(Bool.self, forKey: .isReference) ?? false
        mask = try container.decodeIfPresent(LayerMaskDescriptor.self, forKey: .mask)
        adjustment = try container.decodeIfPresent(CanvasAdjustmentDescriptor.self, forKey: .adjustment)
    }

    var isPaintLayer: Bool { kind == .paint }

    var isGroup: Bool { kind == .group }

    var isAdjustmentLayer: Bool { kind == .paint && adjustment != nil }

    static let defaultBackgroundLayerName = "背景"

    static func stageOneDefault() -> LayerRecord {
        LayerRecord(
            id: LayerID(),
            name: Self.defaultBackgroundLayerName,
            isVisible: true,
            isLocked: false,
            locksTransparentPixels: false,
            opacity: 1
        )
    }
}

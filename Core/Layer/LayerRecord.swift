import Foundation

struct LayerID: Hashable, Codable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

struct LayerRecord: Codable, Sendable, Equatable {
    let id: LayerID
    var name: String
    var isVisible: Bool
    var isLocked: Bool
    var locksTransparentPixels: Bool
    var opacity: Float

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case isVisible
        case isLocked
        case locksTransparentPixels
        case opacity
    }

    init(
        id: LayerID,
        name: String,
        isVisible: Bool,
        isLocked: Bool,
        locksTransparentPixels: Bool,
        opacity: Float
    ) {
        self.id = id
        self.name = name
        self.isVisible = isVisible
        self.isLocked = isLocked
        self.locksTransparentPixels = locksTransparentPixels
        self.opacity = opacity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(LayerID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isVisible = try container.decode(Bool.self, forKey: .isVisible)
        isLocked = try container.decode(Bool.self, forKey: .isLocked)
        locksTransparentPixels = try container.decodeIfPresent(Bool.self, forKey: .locksTransparentPixels) ?? false
        opacity = try container.decode(Float.self, forKey: .opacity)
    }

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

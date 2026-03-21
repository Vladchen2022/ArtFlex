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
    var opacity: Float

    static func stageOneDefault() -> LayerRecord {
        LayerRecord(
            id: LayerID(),
            name: "图层 1",
            isVisible: true,
            isLocked: false,
            opacity: 1
        )
    }
}

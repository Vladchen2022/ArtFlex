import Foundation

enum EyedropperSampleSize: String, Codable, CaseIterable, Sendable, Equatable {
    case point
    case threeByThree
    case fiveByFive

    var radius: Int {
        switch self {
        case .point:
            0
        case .threeByThree:
            1
        case .fiveByFive:
            2
        }
    }
}

enum EyedropperSampleStatistic: String, Codable, CaseIterable, Sendable, Equatable {
    case average
    case median
}

enum EyedropperSampleSource: String, Codable, CaseIterable, Sendable, Equatable {
    case currentLayer
    case allVisibleLayers
    case displayedColor
}

struct EyedropperSettings: Codable, Sendable, Equatable {
    var sampleSize: EyedropperSampleSize
    var statistic: EyedropperSampleStatistic
    var source: EyedropperSampleSource
    var preservesTransparency: Bool
    var returnsToPreviousTool: Bool

    static let stageOneDefault = EyedropperSettings(
        sampleSize: .threeByThree,
        statistic: .average,
        source: .displayedColor,
        preservesTransparency: false,
        returnsToPreviousTool: false
    )
}

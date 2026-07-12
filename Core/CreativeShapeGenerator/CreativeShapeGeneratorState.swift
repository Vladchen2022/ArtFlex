import Foundation

enum CreativeShapeGeneratorColorSource: String, Codable, Sendable, Equatable, CaseIterable, Identifiable {
    case currentColor
    case paletteBlocks
    case externalImage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .currentColor:
            return "当前颜色"
        case .paletteBlocks:
            return "色块组合"
        case .externalImage:
            return "外部图片"
        }
    }
}

struct CreativeShapeGeneratorImageSource: Codable, Sendable, Equatable {
    var fileName: String
    var width: Int
    var height: Int
    var rgbaPixels: Data

    static let targetDimension = 128

    var isValid: Bool {
        width == Self.targetDimension &&
        height == Self.targetDimension &&
        rgbaPixels.count == width * height * 4
    }
}

struct CreativeShapeGeneratorState: Codable, Sendable, Equatable {
    var selectedSource: CreativeShapeGeneratorColorSource?
    var formTendency: Float
    var complexity: Float
    var openness: Float
    var edgeCharacter: Float
    var surprise: Float
    var importedImage: CreativeShapeGeneratorImageSource?

    static let stageOneDefault = CreativeShapeGeneratorState(
        selectedSource: nil,
        formTendency: 0.58,
        complexity: 0.48,
        openness: 0.34,
        edgeCharacter: 0.38,
        surprise: 0.32,
        importedImage: nil
    )

    enum CodingKeys: String, CodingKey {
        case selectedSource
        case formTendency
        case complexity
        case openness
        case edgeCharacter
        case surprise
        case importedImage

        // Previous structured generator keys.
        case structureMode
        case coherence
        case formElongation
        case edgeTexture

        // Original stage-one generator keys.
        case shapeCharacteristic
        case shapeSize
        case shapeJitter
        case featherProbability
    }

    init(
        selectedSource: CreativeShapeGeneratorColorSource?,
        formTendency: Float = 0.58,
        complexity: Float = 0.48,
        openness: Float = 0.34,
        edgeCharacter: Float = 0.38,
        surprise: Float = 0.32,
        importedImage: CreativeShapeGeneratorImageSource?
    ) {
        self.selectedSource = selectedSource
        self.formTendency = formTendency
        self.complexity = complexity
        self.openness = openness
        self.edgeCharacter = edgeCharacter
        self.surprise = surprise
        self.importedImage = importedImage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.stageOneDefault
        selectedSource = try container.decodeIfPresent(CreativeShapeGeneratorColorSource.self, forKey: .selectedSource)
        complexity = try container.decodeIfPresent(Float.self, forKey: .complexity)
            ?? container.decodeIfPresent(Float.self, forKey: .shapeSize)
            ?? defaults.complexity

        let legacyMode = try container.decodeIfPresent(String.self, forKey: .structureMode)
        if let storedTendency = try container.decodeIfPresent(Float.self, forKey: .formTendency) {
            formTendency = storedTendency
        } else if let storedElongation = try container.decodeIfPresent(Float.self, forKey: .formElongation) {
            formTendency = storedElongation
        } else {
            formTendency = switch legacyMode {
            case "cluster": 0.18
            case "flow": 0.86
            case "fracture": 0.62
            default: defaults.formTendency
            }
        }

        if let storedOpenness = try container.decodeIfPresent(Float.self, forKey: .openness) {
            openness = storedOpenness
        } else {
            openness = legacyMode == "fracture" ? 0.68 : defaults.openness
        }

        if let storedEdge = try container.decodeIfPresent(Float.self, forKey: .edgeCharacter) {
            edgeCharacter = storedEdge
        } else if let previousEdge = try container.decodeIfPresent(Float.self, forKey: .edgeTexture) {
            edgeCharacter = previousEdge
        } else {
            let legacyCharacteristic = try container.decodeIfPresent(Float.self, forKey: .shapeCharacteristic)
            let legacyFeather = try container.decodeIfPresent(Float.self, forKey: .featherProbability)
            edgeCharacter = ((legacyCharacteristic ?? defaults.edgeCharacter) +
                (legacyFeather ?? defaults.edgeCharacter)) * 0.5
        }

        if let storedSurprise = try container.decodeIfPresent(Float.self, forKey: .surprise) {
            surprise = storedSurprise
        } else if let previousCoherence = try container.decodeIfPresent(Float.self, forKey: .coherence) {
            surprise = 1 - previousCoherence
        } else if let legacyJitter = try container.decodeIfPresent(Float.self, forKey: .shapeJitter) {
            surprise = legacyJitter
        } else {
            surprise = defaults.surprise
        }
        importedImage = try container.decodeIfPresent(CreativeShapeGeneratorImageSource.self, forKey: .importedImage)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(selectedSource, forKey: .selectedSource)
        try container.encode(formTendency, forKey: .formTendency)
        try container.encode(complexity, forKey: .complexity)
        try container.encode(openness, forKey: .openness)
        try container.encode(edgeCharacter, forKey: .edgeCharacter)
        try container.encode(surprise, forKey: .surprise)
        try container.encodeIfPresent(importedImage, forKey: .importedImage)
    }

    var isEnabled: Bool {
        guard let selectedSource else { return false }
        switch selectedSource {
        case .currentColor, .paletteBlocks:
            return true
        case .externalImage:
            return importedImage?.isValid == true
        }
    }
}

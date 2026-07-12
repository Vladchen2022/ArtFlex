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

enum CreativeShapeStructureMode: String, Codable, Sendable, Equatable, CaseIterable, Identifiable {
    case cluster
    case growth
    case flow
    case fracture

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cluster:
            return "聚合"
        case .growth:
            return "生长"
        case .flow:
            return "流动"
        case .fracture:
            return "断裂"
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
    var structureMode: CreativeShapeStructureMode
    var complexity: Float
    var coherence: Float
    var formElongation: Float
    var edgeTexture: Float
    var importedImage: CreativeShapeGeneratorImageSource?

    static let stageOneDefault = CreativeShapeGeneratorState(
        selectedSource: nil,
        structureMode: .growth,
        complexity: 0.48,
        coherence: 0.72,
        formElongation: 0.58,
        edgeTexture: 0.38,
        importedImage: nil
    )

    enum CodingKeys: String, CodingKey {
        case selectedSource
        case structureMode
        case complexity
        case coherence
        case formElongation
        case edgeTexture
        case importedImage

        // Legacy stage-one generator keys.
        case shapeCharacteristic
        case shapeSize
        case shapeJitter
        case colorJitter
        case featherProbability
    }

    init(
        selectedSource: CreativeShapeGeneratorColorSource?,
        structureMode: CreativeShapeStructureMode = .growth,
        complexity: Float = 0.48,
        coherence: Float = 0.72,
        formElongation: Float = 0.58,
        edgeTexture: Float = 0.38,
        importedImage: CreativeShapeGeneratorImageSource?
    ) {
        self.selectedSource = selectedSource
        self.structureMode = structureMode
        self.complexity = complexity
        self.coherence = coherence
        self.formElongation = formElongation
        self.edgeTexture = edgeTexture
        self.importedImage = importedImage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.stageOneDefault
        selectedSource = try container.decodeIfPresent(CreativeShapeGeneratorColorSource.self, forKey: .selectedSource)
        structureMode = try container.decodeIfPresent(CreativeShapeStructureMode.self, forKey: .structureMode) ?? defaults.structureMode
        complexity = try container.decodeIfPresent(Float.self, forKey: .complexity)
            ?? container.decodeIfPresent(Float.self, forKey: .shapeSize)
            ?? defaults.complexity
        if let storedCoherence = try container.decodeIfPresent(Float.self, forKey: .coherence) {
            coherence = storedCoherence
        } else if let legacyJitter = try container.decodeIfPresent(Float.self, forKey: .shapeJitter) {
            coherence = 1 - legacyJitter
        } else {
            coherence = defaults.coherence
        }
        formElongation = try container.decodeIfPresent(Float.self, forKey: .formElongation)
            ?? defaults.formElongation
        if let storedTexture = try container.decodeIfPresent(Float.self, forKey: .edgeTexture) {
            edgeTexture = storedTexture
        } else {
            let legacyCharacteristic = try container.decodeIfPresent(Float.self, forKey: .shapeCharacteristic)
            let legacyFeather = try container.decodeIfPresent(Float.self, forKey: .featherProbability)
            edgeTexture = ((legacyCharacteristic ?? defaults.edgeTexture) + (legacyFeather ?? defaults.edgeTexture)) * 0.5
        }
        importedImage = try container.decodeIfPresent(CreativeShapeGeneratorImageSource.self, forKey: .importedImage)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(selectedSource, forKey: .selectedSource)
        try container.encode(structureMode, forKey: .structureMode)
        try container.encode(complexity, forKey: .complexity)
        try container.encode(coherence, forKey: .coherence)
        try container.encode(formElongation, forKey: .formElongation)
        try container.encode(edgeTexture, forKey: .edgeTexture)
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

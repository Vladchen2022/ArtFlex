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
    var usesTipImageShapes: Bool
    var featherProbability: Float
    var shapeCharacteristic: Float
    var shapeSize: Float
    var shapeJitter: Float
    var colorJitter: Float
    var importedImage: CreativeShapeGeneratorImageSource?

    static let stageOneDefault = CreativeShapeGeneratorState(
        selectedSource: nil,
        usesTipImageShapes: false,
        featherProbability: 0.2,
        shapeCharacteristic: 0.4,
        shapeSize: 0.45,
        shapeJitter: 0.35,
        colorJitter: 0.18,
        importedImage: nil
    )

    enum CodingKeys: String, CodingKey {
        case selectedSource
        case usesTipImageShapes
        case featherProbability
        case shapeCharacteristic
        case shapeSize
        case shapeJitter
        case colorJitter
        case importedImage
    }

    init(
        selectedSource: CreativeShapeGeneratorColorSource?,
        usesTipImageShapes: Bool = false,
        featherProbability: Float = 0.2,
        shapeCharacteristic: Float,
        shapeSize: Float,
        shapeJitter: Float,
        colorJitter: Float,
        importedImage: CreativeShapeGeneratorImageSource?
    ) {
        self.selectedSource = selectedSource
        self.usesTipImageShapes = usesTipImageShapes
        self.featherProbability = featherProbability
        self.shapeCharacteristic = shapeCharacteristic
        self.shapeSize = shapeSize
        self.shapeJitter = shapeJitter
        self.colorJitter = colorJitter
        self.importedImage = importedImage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.stageOneDefault
        selectedSource = try container.decodeIfPresent(CreativeShapeGeneratorColorSource.self, forKey: .selectedSource)
        usesTipImageShapes = try container.decodeIfPresent(Bool.self, forKey: .usesTipImageShapes) ?? defaults.usesTipImageShapes
        featherProbability = try container.decodeIfPresent(Float.self, forKey: .featherProbability) ?? defaults.featherProbability
        shapeCharacteristic = try container.decodeIfPresent(Float.self, forKey: .shapeCharacteristic) ?? defaults.shapeCharacteristic
        shapeSize = try container.decodeIfPresent(Float.self, forKey: .shapeSize) ?? defaults.shapeSize
        shapeJitter = try container.decodeIfPresent(Float.self, forKey: .shapeJitter) ?? defaults.shapeJitter
        colorJitter = try container.decodeIfPresent(Float.self, forKey: .colorJitter) ?? defaults.colorJitter
        importedImage = try container.decodeIfPresent(CreativeShapeGeneratorImageSource.self, forKey: .importedImage)
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

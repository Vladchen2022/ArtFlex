import Foundation

enum BrushBuildMode: String, Codable, Sendable, Equatable, CaseIterable {
    case buildUp
    case opacityCap

    var displayName: String {
        switch self {
        case .buildUp:
            return "叠加"
        case .opacityCap:
            return "不透明度封顶"
        }
    }
}

enum BrushTipShape: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case hardRound
    case softRound
    case square
    case customRound

    var displayName: String {
        switch self {
        case .softRound:
            return "柔边圆"
        case .hardRound:
            return "硬边圆"
        case .square:
            return "方形"
        case .customRound:
            return "自定义"
        }
    }

    var hardness: Float {
        switch self {
        case .softRound:
            return 0.0
        case .hardRound:
            return 1.0
        case .square:
            return 1.0
        case .customRound:
            return 0.5
        }
    }

    static func customRoundHardness(for softness: Float) -> Float {
        let clampedSoftness = min(max(softness, 0), 1)
        return (1 - clampedSoftness) * 0.995
    }

    func alphaMask(forNormalizedDistance distance: Float) -> Float {
        switch self {
        case .softRound, .hardRound, .customRound:
            if distance >= 1 {
                return 0
            }

            if hardness >= 0.999 {
                return 1
            }

            if distance <= hardness {
                return 1
            }

            let t = min(max((distance - hardness) / (1 - hardness), 0), 1)
            return 1 - (t * t * (3 - (2 * t)))
        case .square:
            return distance <= 1 ? 1 : 0
        }
    }
}

enum DualTipCombineMode: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case subtract
    case multiply
    case intersect

    var displayName: String {
        switch self {
        case .subtract:
            return "减去"
        case .multiply:
            return "调制"
        case .intersect:
            return "相交"
        }
    }
}

enum TipSourceSemantic: String, Codable, Sendable, Equatable, Hashable {
    case procedural
    case customMask
    case importedImage

    var usesImportedPreviewFit: Bool {
        self == .importedImage
    }
}

struct ImportedTipSourceInfo: Codable, Sendable, Equatable {
    var sourceLabel: String
    var pixelWidth: Int
    var pixelHeight: Int

    var formattedSummary: String {
        "\(sourceLabel) · \(pixelWidth)x\(pixelHeight)"
    }
}

struct SecondaryTipDescriptor: Codable, Sendable, Equatable {
    var tipShape: BrushTipShape
    var sourceSemantic: TipSourceSemantic
    var tipAssetID: BrushTipImageAssetID?
    var importedSourceInfo: ImportedTipSourceInfo?
    var customTipMaskData: Data?
    var customTipSoftness: Float
    var customTipRoundness: Float
    var customTipAngleDegrees: Float

    static let stageOneDefault = SecondaryTipDescriptor(
        tipShape: .hardRound,
        sourceSemantic: .procedural,
        tipAssetID: nil,
        importedSourceInfo: nil,
        customTipMaskData: nil,
        customTipSoftness: 0.5,
        customTipRoundness: 1,
        customTipAngleDegrees: 0
    )

    enum CodingKeys: String, CodingKey {
        case tipShape
        case sourceSemantic
        case tipAssetID
        case importedSourceInfo
        case customTipMaskData
        case customTipSoftness
        case customTipRoundness
        case customTipAngleDegrees
    }

    init(
        tipShape: BrushTipShape,
        sourceSemantic: TipSourceSemantic = .procedural,
        tipAssetID: BrushTipImageAssetID? = nil,
        importedSourceInfo: ImportedTipSourceInfo? = nil,
        customTipMaskData: Data? = nil,
        customTipSoftness: Float = 0.5,
        customTipRoundness: Float = 1,
        customTipAngleDegrees: Float = 0
    ) {
        self.tipShape = tipShape
        self.sourceSemantic = sourceSemantic
        self.tipAssetID = tipAssetID
        self.importedSourceInfo = importedSourceInfo
        self.customTipMaskData = customTipMaskData
        self.customTipSoftness = customTipSoftness
        self.customTipRoundness = customTipRoundness
        self.customTipAngleDegrees = customTipAngleDegrees
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.stageOneDefault

        tipShape = try container.decodeIfPresent(BrushTipShape.self, forKey: .tipShape) ?? defaults.tipShape
        sourceSemantic = try container.decodeIfPresent(TipSourceSemantic.self, forKey: .sourceSemantic) ?? defaults.sourceSemantic
        tipAssetID = try container.decodeIfPresent(BrushTipImageAssetID.self, forKey: .tipAssetID) ?? defaults.tipAssetID
        importedSourceInfo = try container.decodeIfPresent(ImportedTipSourceInfo.self, forKey: .importedSourceInfo) ?? defaults.importedSourceInfo
        customTipMaskData = try container.decodeIfPresent(Data.self, forKey: .customTipMaskData) ?? defaults.customTipMaskData
        customTipSoftness = try container.decodeIfPresent(Float.self, forKey: .customTipSoftness) ?? defaults.customTipSoftness
        customTipRoundness = try container.decodeIfPresent(Float.self, forKey: .customTipRoundness) ?? defaults.customTipRoundness
        customTipAngleDegrees = try container.decodeIfPresent(Float.self, forKey: .customTipAngleDegrees) ?? defaults.customTipAngleDegrees
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tipShape, forKey: .tipShape)
        try container.encode(sourceSemantic, forKey: .sourceSemantic)
        try container.encodeIfPresent(tipAssetID, forKey: .tipAssetID)
        try container.encodeIfPresent(importedSourceInfo, forKey: .importedSourceInfo)
        try container.encodeIfPresent(customTipMaskData, forKey: .customTipMaskData)
        try container.encode(customTipSoftness, forKey: .customTipSoftness)
        try container.encode(customTipRoundness, forKey: .customTipRoundness)
        try container.encode(customTipAngleDegrees, forKey: .customTipAngleDegrees)
    }
}

extension BrushTipShape {
    var isPhaseOneDualTipSupportedRound: Bool {
        self == .hardRound || self == .softRound
    }

    var supportsDualTipRealDrawingPrimary: Bool {
        isPhaseOneDualTipSupportedRound || self == .customRound
    }
}

extension SecondaryTipDescriptor {
    var supportsPhaseOneDualTipRealDrawing: Bool {
        tipShape.isPhaseOneDualTipSupportedRound || tipShape == .customRound
    }

    var supportsPhaseTwoDualTipSubtractRealDrawing: Bool {
        tipShape.isPhaseOneDualTipSupportedRound || tipShape == .customRound
    }

    var supportsPhaseTwoDualTipIntersectRealDrawing: Bool {
        tipShape.isPhaseOneDualTipSupportedRound || tipShape == .customRound
    }
}

enum ToolKind: String, Codable, Sendable {
    case brush
    case eraser
    case smudge
    case eyedropper
    case bucket
    case polygonSelection
    case lassoFill
    case straightLine
    case linearGradient
    case sectorGradient
    case rectangleSelection
    case ellipseSelection
    case lassoSelection
    case canvasRotate
    case freeTransform
}

extension ToolKind {
    var sidebarIconName: String {
        switch self {
        case .brush:
            return "paintbrush"
        case .eraser:
            return "eraser"
        case .eyedropper:
            return "eyedropper"
        case .bucket:
            return "paintbrush.pointed"
        case .lassoSelection:
            return "lasso"
        case .polygonSelection:
            return "point.3.connected.trianglepath.dotted"
        case .lassoFill:
            return "wand.and.stars"
        case .rectangleSelection:
            return "rectangle.dashed"
        case .ellipseSelection:
            return "circle.dashed"
        case .straightLine:
            return "line.diagonal"
        case .linearGradient:
            return "line.diagonal.arrow"
        case .sectorGradient:
            return "circle.lefthalf.filled"
        case .smudge:
            return "hand.draw"
        case .canvasRotate:
            return "rotate.3d"
        case .freeTransform:
            return "arrow.up.left.and.arrow.down.right"
        }
    }

    var displayName: String {
        switch self {
        case .brush:
            return "画笔"
        case .eraser:
            return "橡皮"
        case .eyedropper:
            return "吸管"
        case .bucket:
            return "油漆桶"
        case .lassoSelection:
            return "套索选区"
        case .polygonSelection:
            return "几何选区"
        case .lassoFill:
            return "套索填充"
        case .rectangleSelection:
            return "矩形选区"
        case .ellipseSelection:
            return "椭圆选区"
        case .straightLine:
            return "直线"
        case .linearGradient:
            return "直线渐变"
        case .sectorGradient:
            return "扇形渐变"
        case .smudge:
            return "涂抹"
        case .canvasRotate:
            return "画布旋转"
        case .freeTransform:
            return "移动变形"
        }
    }

    var shortcutKey: String? {
        switch self {
        case .brush:
            return "B"
        case .eraser:
            return "E"
        case .eyedropper:
            return nil
        case .bucket:
            return "G"
        case .lassoSelection, .polygonSelection:
            return "L"
        case .lassoFill:
            return "K"
        case .rectangleSelection, .ellipseSelection:
            return "M"
        case .straightLine:
            return "U"
        case .linearGradient, .sectorGradient:
            return "G"
        case .smudge:
            return "T"
        case .canvasRotate:
            return "R"
        case .freeTransform:
            return "V"
        }
    }
}

struct ToolSidebarGroup: Identifiable, Equatable, Sendable {
    let id: String
    let tools: [ToolKind]
    let shortcutKey: String?

    var defaultTool: ToolKind {
        tools[0]
    }

    var isGrouped: Bool {
        tools.count > 1
    }

    func contains(_ tool: ToolKind) -> Bool {
        tools.contains(tool)
    }

    static let orderedGroups: [ToolSidebarGroup] = [
        .init(id: "brush", tools: [.brush], shortcutKey: "B"),
        .init(id: "eraser", tools: [.eraser], shortcutKey: "E"),
        .init(id: "eyedropper", tools: [.eyedropper], shortcutKey: nil),
        .init(id: "bucket", tools: [.bucket, .linearGradient, .sectorGradient], shortcutKey: "G"),
        .init(id: "selection-l", tools: [.lassoSelection, .polygonSelection], shortcutKey: "L"),
        .init(id: "lasso-fill", tools: [.lassoFill], shortcutKey: "K"),
        .init(id: "selection-m", tools: [.rectangleSelection, .ellipseSelection], shortcutKey: "M"),
        .init(id: "straight-line", tools: [.straightLine], shortcutKey: "U"),
        .init(id: "smudge", tools: [.smudge], shortcutKey: "T"),
        .init(id: "canvas-rotate", tools: [.canvasRotate], shortcutKey: "R"),
        .init(id: "free-transform", tools: [.freeTransform], shortcutKey: "V")
    ]

    static func group(containing tool: ToolKind) -> ToolSidebarGroup? {
        orderedGroups.first { $0.contains(tool) }
    }

    static func group(forShortcutKey key: String) -> ToolSidebarGroup? {
        orderedGroups.first { $0.shortcutKey == key.uppercased() }
    }

    static var defaultSurfaceTools: [String: ToolKind] {
        Dictionary(uniqueKeysWithValues: orderedGroups.map { ($0.id, $0.defaultTool) })
    }
}

enum PressureCurvePreset: String, CaseIterable, Sendable {
    case softStart
    case balanced
    case quickRamp

    var displayName: String {
        switch self {
        case .softStart:
            return "轻起笔"
        case .balanced:
            return "均衡"
        case .quickRamp:
            return "快速增压"
        }
    }

    var opacityValues: (low: Float, mid: Float, high: Float) {
        switch self {
        case .softStart:
            return (0.02, 0.28, 0.72)
        case .balanced:
            return (0.05, 0.4, 0.82)
        case .quickRamp:
            return (0.12, 0.62, 0.92)
        }
    }

    var sizeValues: (low: Float, mid: Float, high: Float) {
        switch self {
        case .softStart:
            return (0.08, 0.42, 0.82)
        case .balanced:
            return (0.18, 0.52, 0.88)
        case .quickRamp:
            return (0.28, 0.68, 0.95)
        }
    }
}

struct BrushSettings: Codable, Sendable, Equatable {
    var size: Float
    var opacity: Float
    var buildMode: BrushBuildMode
    var tipShape: BrushTipShape
    var dualTipEnabled: Bool
    var secondaryTipDescriptor: SecondaryTipDescriptor
    var dualTipCombineMode: DualTipCombineMode
    var dualTipStrength: Float
    var secondarySizeRatio: Float
    var secondarySizeJitter: Float
    var secondaryAngleJitterDegrees: Float
    var secondaryAngleOffsetDegrees: Float
    var secondarySpacingPhase: Float
    var secondarySpacingPhaseJitter: Float
    var secondaryScatter: Float
    var secondaryScatterJitter: Float
    var secondaryInvert: Bool
    var spacingPercent: Float
    var scatterAmount: Float
    var jitterAmount: Float
    var colorJitterAmount: Float
    var stampRotationDegrees: Float
    var followsStrokeDirection: Bool
    var customTipSourceSemantic: TipSourceSemantic
    var customTipAssetID: BrushTipImageAssetID?
    var customTipImportedSourceInfo: ImportedTipSourceInfo?
    var customTipMaskData: Data?
    var customTipSoftness: Float
    var customTipRoundness: Float
    var customTipAngleDegrees: Float
    var pressureSensitivity: Float
    var sizeLowerBound: Float
    var pressureSizeAmount: Float
    var pressureOpacityAmount: Float
    var sizeCurveLow: Float
    var sizeCurveMid: Float
    var sizeCurveHigh: Float
    var opacityCurveLow: Float
    var opacityCurveMid: Float
    var opacityCurveHigh: Float

    static let stageOneDefault = BrushSettings(
        size: 24,
        opacity: 1,
        buildMode: .buildUp,
        tipShape: .hardRound,
        dualTipEnabled: false,
        secondaryTipDescriptor: .stageOneDefault,
        dualTipCombineMode: .multiply,
        dualTipStrength: 1,
        secondarySizeRatio: 1,
        secondarySizeJitter: 0,
        secondaryAngleJitterDegrees: 0,
        secondaryAngleOffsetDegrees: 0,
        secondarySpacingPhase: 0,
        secondarySpacingPhaseJitter: 0,
        secondaryScatter: 0,
        secondaryScatterJitter: 0,
        secondaryInvert: false,
        spacingPercent: 15,
        scatterAmount: 0,
        jitterAmount: 0,
        colorJitterAmount: 0,
        stampRotationDegrees: 0,
        followsStrokeDirection: false,
        customTipSourceSemantic: .procedural,
        customTipAssetID: nil,
        customTipImportedSourceInfo: nil,
        customTipMaskData: nil,
        customTipSoftness: 0.5,
        customTipRoundness: 1,
        customTipAngleDegrees: 0,
        pressureSensitivity: 1,
        sizeLowerBound: 0,
        pressureSizeAmount: 1,
        pressureOpacityAmount: 1,
        sizeCurveLow: 0.18,
        sizeCurveMid: 0.52,
        sizeCurveHigh: 0.88,
        opacityCurveLow: 0.05,
        opacityCurveMid: 0.4,
        opacityCurveHigh: 0.82
    )

    enum CodingKeys: String, CodingKey {
        case size
        case opacity
        case buildMode
        case tipShape
        case dualTipEnabled
        case secondaryTipDescriptor
        case dualTipCombineMode
        case dualTipStrength
        case secondarySizeRatio
        case secondarySizeJitter
        case secondaryAngleJitterDegrees
        case secondaryAngleOffsetDegrees
        case secondarySpacingPhase
        case secondarySpacingPhaseJitter
        case secondaryScatter
        case secondaryScatterJitter
        case secondaryInvert
        case spacingPercent
        case scatterAmount
        case jitterAmount
        case colorJitterAmount
        case stampRotationDegrees
        case followsStrokeDirection
        case customTipSourceSemantic
        case customTipAssetID
        case customTipImportedSourceInfo
        case customTipMaskData
        case customTipSoftness
        case customTipRoundness
        case customTipAngleDegrees
        case pressureSensitivity
        case sizeLowerBound
        case pressureSizeAmount
        case pressureOpacityAmount
        case sizeCurveLow
        case sizeCurveMid
        case sizeCurveHigh
        case opacityCurveLow
        case opacityCurveMid
        case opacityCurveHigh
    }

    init(
        size: Float,
        opacity: Float,
        buildMode: BrushBuildMode,
        tipShape: BrushTipShape,
        dualTipEnabled: Bool = false,
        secondaryTipDescriptor: SecondaryTipDescriptor = .stageOneDefault,
        dualTipCombineMode: DualTipCombineMode = .multiply,
        dualTipStrength: Float = 1,
        secondarySizeRatio: Float = 1,
        secondarySizeJitter: Float = 0,
        secondaryAngleJitterDegrees: Float = 0,
        secondaryAngleOffsetDegrees: Float = 0,
        secondarySpacingPhase: Float = 0,
        secondarySpacingPhaseJitter: Float = 0,
        secondaryScatter: Float = 0,
        secondaryScatterJitter: Float = 0,
        secondaryInvert: Bool = false,
        spacingPercent: Float,
        scatterAmount: Float,
        jitterAmount: Float,
        colorJitterAmount: Float = 0,
        stampRotationDegrees: Float,
        followsStrokeDirection: Bool,
        customTipSourceSemantic: TipSourceSemantic = .procedural,
        customTipAssetID: BrushTipImageAssetID? = nil,
        customTipImportedSourceInfo: ImportedTipSourceInfo? = nil,
        customTipMaskData: Data? = nil,
        customTipSoftness: Float,
        customTipRoundness: Float,
        customTipAngleDegrees: Float,
        pressureSensitivity: Float,
        sizeLowerBound: Float,
        pressureSizeAmount: Float,
        pressureOpacityAmount: Float,
        sizeCurveLow: Float,
        sizeCurveMid: Float,
        sizeCurveHigh: Float,
        opacityCurveLow: Float,
        opacityCurveMid: Float,
        opacityCurveHigh: Float
    ) {
        self.size = size
        self.opacity = opacity
        self.buildMode = buildMode
        self.tipShape = tipShape
        self.dualTipEnabled = dualTipEnabled
        self.secondaryTipDescriptor = secondaryTipDescriptor
        self.dualTipCombineMode = dualTipCombineMode
        self.dualTipStrength = dualTipStrength
        self.secondarySizeRatio = secondarySizeRatio
        self.secondarySizeJitter = secondarySizeJitter
        self.secondaryAngleJitterDegrees = secondaryAngleJitterDegrees
        self.secondaryAngleOffsetDegrees = secondaryAngleOffsetDegrees
        self.secondarySpacingPhase = secondarySpacingPhase
        self.secondarySpacingPhaseJitter = secondarySpacingPhaseJitter
        self.secondaryScatter = secondaryScatter
        self.secondaryScatterJitter = secondaryScatterJitter
        self.secondaryInvert = secondaryInvert
        self.spacingPercent = spacingPercent
        self.scatterAmount = scatterAmount
        self.jitterAmount = jitterAmount
        self.colorJitterAmount = colorJitterAmount
        self.stampRotationDegrees = stampRotationDegrees
        self.followsStrokeDirection = followsStrokeDirection
        self.customTipSourceSemantic = customTipSourceSemantic
        self.customTipAssetID = customTipAssetID
        self.customTipImportedSourceInfo = customTipImportedSourceInfo
        self.customTipMaskData = customTipMaskData
        self.customTipSoftness = customTipSoftness
        self.customTipRoundness = customTipRoundness
        self.customTipAngleDegrees = customTipAngleDegrees
        self.pressureSensitivity = pressureSensitivity
        self.sizeLowerBound = sizeLowerBound
        self.pressureSizeAmount = pressureSizeAmount
        self.pressureOpacityAmount = pressureOpacityAmount
        self.sizeCurveLow = sizeCurveLow
        self.sizeCurveMid = sizeCurveMid
        self.sizeCurveHigh = sizeCurveHigh
        self.opacityCurveLow = opacityCurveLow
        self.opacityCurveMid = opacityCurveMid
        self.opacityCurveHigh = opacityCurveHigh
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BrushSettings.stageOneDefault

        size = try container.decodeIfPresent(Float.self, forKey: .size) ?? defaults.size
        opacity = try container.decodeIfPresent(Float.self, forKey: .opacity) ?? defaults.opacity
        buildMode = try container.decodeIfPresent(BrushBuildMode.self, forKey: .buildMode) ?? defaults.buildMode
        tipShape = try container.decodeIfPresent(BrushTipShape.self, forKey: .tipShape) ?? defaults.tipShape
        dualTipEnabled = try container.decodeIfPresent(Bool.self, forKey: .dualTipEnabled) ?? defaults.dualTipEnabled
        secondaryTipDescriptor = try container.decodeIfPresent(SecondaryTipDescriptor.self, forKey: .secondaryTipDescriptor) ?? defaults.secondaryTipDescriptor
        dualTipCombineMode = try container.decodeIfPresent(DualTipCombineMode.self, forKey: .dualTipCombineMode) ?? defaults.dualTipCombineMode
        dualTipStrength = try container.decodeIfPresent(Float.self, forKey: .dualTipStrength) ?? defaults.dualTipStrength
        secondarySizeRatio = try container.decodeIfPresent(Float.self, forKey: .secondarySizeRatio) ?? defaults.secondarySizeRatio
        secondarySizeJitter = try container.decodeIfPresent(Float.self, forKey: .secondarySizeJitter) ?? defaults.secondarySizeJitter
        secondaryAngleJitterDegrees = try container.decodeIfPresent(Float.self, forKey: .secondaryAngleJitterDegrees) ?? defaults.secondaryAngleJitterDegrees
        secondaryAngleOffsetDegrees = try container.decodeIfPresent(Float.self, forKey: .secondaryAngleOffsetDegrees) ?? defaults.secondaryAngleOffsetDegrees
        secondarySpacingPhase = try container.decodeIfPresent(Float.self, forKey: .secondarySpacingPhase) ?? defaults.secondarySpacingPhase
        secondarySpacingPhaseJitter = try container.decodeIfPresent(Float.self, forKey: .secondarySpacingPhaseJitter) ?? defaults.secondarySpacingPhaseJitter
        secondaryScatter = try container.decodeIfPresent(Float.self, forKey: .secondaryScatter) ?? defaults.secondaryScatter
        secondaryScatterJitter = try container.decodeIfPresent(Float.self, forKey: .secondaryScatterJitter) ?? defaults.secondaryScatterJitter
        secondaryInvert = try container.decodeIfPresent(Bool.self, forKey: .secondaryInvert) ?? defaults.secondaryInvert
        spacingPercent = try container.decodeIfPresent(Float.self, forKey: .spacingPercent) ?? defaults.spacingPercent
        scatterAmount = try container.decodeIfPresent(Float.self, forKey: .scatterAmount) ?? defaults.scatterAmount
        jitterAmount = try container.decodeIfPresent(Float.self, forKey: .jitterAmount) ?? defaults.jitterAmount
        colorJitterAmount = try container.decodeIfPresent(Float.self, forKey: .colorJitterAmount) ?? defaults.colorJitterAmount
        stampRotationDegrees = try container.decodeIfPresent(Float.self, forKey: .stampRotationDegrees) ?? defaults.stampRotationDegrees
        followsStrokeDirection = try container.decodeIfPresent(Bool.self, forKey: .followsStrokeDirection) ?? defaults.followsStrokeDirection
        customTipSourceSemantic = try container.decodeIfPresent(TipSourceSemantic.self, forKey: .customTipSourceSemantic) ?? defaults.customTipSourceSemantic
        customTipAssetID = try container.decodeIfPresent(BrushTipImageAssetID.self, forKey: .customTipAssetID) ?? defaults.customTipAssetID
        customTipImportedSourceInfo = try container.decodeIfPresent(ImportedTipSourceInfo.self, forKey: .customTipImportedSourceInfo) ?? defaults.customTipImportedSourceInfo
        customTipMaskData = try container.decodeIfPresent(Data.self, forKey: .customTipMaskData) ?? defaults.customTipMaskData
        customTipSoftness = try container.decodeIfPresent(Float.self, forKey: .customTipSoftness) ?? defaults.customTipSoftness
        customTipRoundness = try container.decodeIfPresent(Float.self, forKey: .customTipRoundness) ?? defaults.customTipRoundness
        customTipAngleDegrees = try container.decodeIfPresent(Float.self, forKey: .customTipAngleDegrees) ?? defaults.customTipAngleDegrees
        pressureSensitivity = try container.decodeIfPresent(Float.self, forKey: .pressureSensitivity) ?? defaults.pressureSensitivity
        sizeLowerBound = try container.decodeIfPresent(Float.self, forKey: .sizeLowerBound) ?? defaults.sizeLowerBound
        pressureSizeAmount = try container.decodeIfPresent(Float.self, forKey: .pressureSizeAmount) ?? defaults.pressureSizeAmount
        pressureOpacityAmount = try container.decodeIfPresent(Float.self, forKey: .pressureOpacityAmount) ?? defaults.pressureOpacityAmount
        sizeCurveLow = try container.decodeIfPresent(Float.self, forKey: .sizeCurveLow) ?? defaults.sizeCurveLow
        sizeCurveMid = try container.decodeIfPresent(Float.self, forKey: .sizeCurveMid) ?? defaults.sizeCurveMid
        sizeCurveHigh = try container.decodeIfPresent(Float.self, forKey: .sizeCurveHigh) ?? defaults.sizeCurveHigh
        opacityCurveLow = try container.decodeIfPresent(Float.self, forKey: .opacityCurveLow) ?? defaults.opacityCurveLow
        opacityCurveMid = try container.decodeIfPresent(Float.self, forKey: .opacityCurveMid) ?? defaults.opacityCurveMid
        opacityCurveHigh = try container.decodeIfPresent(Float.self, forKey: .opacityCurveHigh) ?? defaults.opacityCurveHigh
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(size, forKey: .size)
        try container.encode(opacity, forKey: .opacity)
        try container.encode(buildMode, forKey: .buildMode)
        try container.encode(tipShape, forKey: .tipShape)
        try container.encode(dualTipEnabled, forKey: .dualTipEnabled)
        try container.encode(secondaryTipDescriptor, forKey: .secondaryTipDescriptor)
        try container.encode(dualTipCombineMode, forKey: .dualTipCombineMode)
        try container.encode(dualTipStrength, forKey: .dualTipStrength)
        try container.encode(secondarySizeRatio, forKey: .secondarySizeRatio)
        try container.encode(secondarySizeJitter, forKey: .secondarySizeJitter)
        try container.encode(secondaryAngleJitterDegrees, forKey: .secondaryAngleJitterDegrees)
        try container.encode(secondaryAngleOffsetDegrees, forKey: .secondaryAngleOffsetDegrees)
        try container.encode(secondarySpacingPhase, forKey: .secondarySpacingPhase)
        try container.encode(secondarySpacingPhaseJitter, forKey: .secondarySpacingPhaseJitter)
        try container.encode(secondaryScatter, forKey: .secondaryScatter)
        try container.encode(secondaryScatterJitter, forKey: .secondaryScatterJitter)
        try container.encode(secondaryInvert, forKey: .secondaryInvert)
        try container.encode(spacingPercent, forKey: .spacingPercent)
        try container.encode(scatterAmount, forKey: .scatterAmount)
        try container.encode(jitterAmount, forKey: .jitterAmount)
        try container.encode(colorJitterAmount, forKey: .colorJitterAmount)
        try container.encode(stampRotationDegrees, forKey: .stampRotationDegrees)
        try container.encode(followsStrokeDirection, forKey: .followsStrokeDirection)
        try container.encode(customTipSourceSemantic, forKey: .customTipSourceSemantic)
        try container.encodeIfPresent(customTipAssetID, forKey: .customTipAssetID)
        try container.encodeIfPresent(customTipImportedSourceInfo, forKey: .customTipImportedSourceInfo)
        try container.encodeIfPresent(customTipMaskData, forKey: .customTipMaskData)
        try container.encode(customTipSoftness, forKey: .customTipSoftness)
        try container.encode(customTipRoundness, forKey: .customTipRoundness)
        try container.encode(customTipAngleDegrees, forKey: .customTipAngleDegrees)
        try container.encode(pressureSensitivity, forKey: .pressureSensitivity)
        try container.encode(sizeLowerBound, forKey: .sizeLowerBound)
        try container.encode(pressureSizeAmount, forKey: .pressureSizeAmount)
        try container.encode(pressureOpacityAmount, forKey: .pressureOpacityAmount)
        try container.encode(sizeCurveLow, forKey: .sizeCurveLow)
        try container.encode(sizeCurveMid, forKey: .sizeCurveMid)
        try container.encode(sizeCurveHigh, forKey: .sizeCurveHigh)
        try container.encode(opacityCurveLow, forKey: .opacityCurveLow)
        try container.encode(opacityCurveMid, forKey: .opacityCurveMid)
        try container.encode(opacityCurveHigh, forKey: .opacityCurveHigh)
    }

    func supportsPhaseOneDualTipRealDrawing(for tool: ToolKind) -> Bool {
        dualTipEnabled &&
        dualTipCombineMode == .multiply &&
        (tool == .brush || tool == .eraser) &&
        tipShape.supportsDualTipRealDrawingPrimary &&
        secondaryTipDescriptor.supportsPhaseOneDualTipRealDrawing
    }

    func supportsPhaseTwoDualTipSubtractRealDrawing(for tool: ToolKind) -> Bool {
        dualTipEnabled &&
        dualTipCombineMode == .subtract &&
        (tool == .brush || tool == .eraser) &&
        tipShape.supportsDualTipRealDrawingPrimary &&
        secondaryTipDescriptor.supportsPhaseTwoDualTipSubtractRealDrawing
    }

    func supportsPhaseTwoDualTipIntersectRealDrawing(for tool: ToolKind) -> Bool {
        dualTipEnabled &&
        dualTipCombineMode == .intersect &&
        (tool == .brush || tool == .eraser) &&
        tipShape.supportsDualTipRealDrawingPrimary &&
        secondaryTipDescriptor.supportsPhaseTwoDualTipIntersectRealDrawing
    }

    func supportsSecondaryScatterRealDrawing(for tool: ToolKind) -> Bool {
        secondaryScatter > 0.0001 &&
        (
            supportsPhaseOneDualTipRealDrawing(for: tool) ||
            supportsPhaseTwoDualTipSubtractRealDrawing(for: tool) ||
            supportsPhaseTwoDualTipIntersectRealDrawing(for: tool)
        )
    }

    func supportsSecondaryAngleOffsetRealDrawing(for tool: ToolKind) -> Bool {
        abs(secondaryAngleOffsetDegrees) > 0.0001 &&
        secondaryTipDescriptor.tipShape == .customRound &&
        (
            supportsPhaseOneDualTipRealDrawing(for: tool) ||
            supportsPhaseTwoDualTipSubtractRealDrawing(for: tool) ||
            supportsPhaseTwoDualTipIntersectRealDrawing(for: tool)
        )
    }

    func supportsSecondarySizeJitterRealDrawing(for tool: ToolKind) -> Bool {
        secondarySizeJitter > 0.0001 &&
        (
            supportsPhaseOneDualTipRealDrawing(for: tool) ||
            supportsPhaseTwoDualTipSubtractRealDrawing(for: tool) ||
            supportsPhaseTwoDualTipIntersectRealDrawing(for: tool)
        )
    }

    func supportsSecondaryAngleJitterRealDrawing(for tool: ToolKind) -> Bool {
        abs(secondaryAngleJitterDegrees) > 0.0001 &&
        secondaryTipDescriptor.tipShape == .customRound &&
        (
            supportsPhaseOneDualTipRealDrawing(for: tool) ||
            supportsPhaseTwoDualTipSubtractRealDrawing(for: tool) ||
            supportsPhaseTwoDualTipIntersectRealDrawing(for: tool)
        )
    }

    func supportsSecondarySpacingPhaseRealDrawing(for tool: ToolKind) -> Bool {
        abs(secondarySpacingPhase) > 0.0001 &&
        (
            supportsPhaseOneDualTipRealDrawing(for: tool) ||
            supportsPhaseTwoDualTipSubtractRealDrawing(for: tool) ||
            supportsPhaseTwoDualTipIntersectRealDrawing(for: tool)
        )
    }

    func supportsSecondarySpacingPhaseJitterRealDrawing(for tool: ToolKind) -> Bool {
        secondarySpacingPhaseJitter > 0.0001 &&
        (
            supportsPhaseOneDualTipRealDrawing(for: tool) ||
            supportsPhaseTwoDualTipSubtractRealDrawing(for: tool) ||
            supportsPhaseTwoDualTipIntersectRealDrawing(for: tool)
        )
    }

    func supportsSecondaryScatterJitterRealDrawing(for tool: ToolKind) -> Bool {
        secondaryScatter > 0.0001 &&
        secondaryScatterJitter > 0.0001 &&
        (
            supportsPhaseOneDualTipRealDrawing(for: tool) ||
            supportsPhaseTwoDualTipSubtractRealDrawing(for: tool) ||
            supportsPhaseTwoDualTipIntersectRealDrawing(for: tool)
        )
    }

    func supportsSecondaryInvertRealDrawing(for tool: ToolKind) -> Bool {
        secondaryInvert &&
        (
            supportsPhaseOneDualTipRealDrawing(for: tool) ||
            supportsPhaseTwoDualTipSubtractRealDrawing(for: tool) ||
            supportsPhaseTwoDualTipIntersectRealDrawing(for: tool)
        )
    }
}

struct ToolSessionState: Codable, Sendable, Equatable {
    var activeTool: ToolKind
    var brush: BrushSettings
    var selectedColor: RGBAColor

    static let stageOneDefault = ToolSessionState(
        activeTool: .brush,
        brush: .stageOneDefault,
        selectedColor: .black
    )
}

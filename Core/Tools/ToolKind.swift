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

    var hasVisibleRotation: Bool {
        switch self {
        case .hardRound, .softRound:
            return false
        case .square, .customRound:
            return true
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

enum ToolKind: String, Codable, Sendable {
    case brush
    case eraser
    case smudge
    case brightnessAdjust
    case colorVitalization
    case eyedropper
    case bucket
    case polygonSelection
    case lassoFill
    case textureFill
    case straightLine
    case linearGradient
    case sectorGradient
    case rectangleSelection
    case ellipseSelection
    case lassoSelection
    case smartSelection
    case canvasRotate
    case canvasCrop
    case freeTransform
    case perspective
    case blockReference
}

enum LassoFillMode: String, CaseIterable, Sendable, Equatable {
    case color
    case texture

    var displayName: String {
        switch self {
        case .color:
            return "颜色填充"
        case .texture:
            return "纹理填充"
        }
    }
}

extension ToolKind {
    var supportsOutsideCanvasSelectionStart: Bool {
        switch self {
        case .polygonSelection, .lassoFill, .textureFill,
             .rectangleSelection, .ellipseSelection, .lassoSelection:
            return true
        default:
            return false
        }
    }

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
        case .smartSelection:
            return "wand.and.stars.inverse"
        case .polygonSelection:
            return "point.3.connected.trianglepath.dotted"
        case .lassoFill:
            return "wand.and.stars"
        case .textureFill:
            return "square.grid.3x3.fill"
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
        case .brightnessAdjust:
            return "slider.horizontal.3"
        case .colorVitalization:
            return "wand.and.rays"
        case .canvasRotate:
            return "rotate.3d"
        case .canvasCrop:
            return "crop"
        case .freeTransform:
            return "arrow.up.left.and.arrow.down.right"
        case .perspective:
            return "triangle"
        case .blockReference:
            return "cube.transparent"
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
        case .smartSelection:
            return "魔棒选区"
        case .polygonSelection:
            return "几何选区"
        case .lassoFill:
            return "套索填充"
        case .textureFill:
            return "纹理填充"
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
        case .brightnessAdjust:
            return "色彩调整"
        case .colorVitalization:
            return "颜色活化"
        case .canvasRotate:
            return "画布旋转"
        case .canvasCrop:
            return "画布裁剪"
        case .freeTransform:
            return "移动变形"
        case .perspective:
            return "透视"
        case .blockReference:
            return "体块参考"
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
        case .lassoSelection, .smartSelection, .polygonSelection:
            return "L"
        case .lassoFill, .textureFill:
            return "K"
        case .rectangleSelection, .ellipseSelection:
            return "M"
        case .straightLine:
            return "U"
        case .linearGradient, .sectorGradient:
            return "G"
        case .smudge:
            return "T"
        case .brightnessAdjust:
            return "O"
        case .colorVitalization:
            return nil
        case .canvasRotate:
            return "R"
        case .canvasCrop:
            return "C"
        case .freeTransform:
            return "V"
        case .perspective:
            return "P"
        case .blockReference:
            return nil
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
        tools.count > 1 && id != "lasso-fill"
    }

    func contains(_ tool: ToolKind) -> Bool {
        tools.contains(tool)
    }

    static let orderedGroups: [ToolSidebarGroup] = [
        .init(id: "brush", tools: [.brush], shortcutKey: "B"),
        .init(id: "eraser", tools: [.eraser], shortcutKey: "E"),
        .init(id: "eyedropper", tools: [.eyedropper], shortcutKey: nil),
        .init(id: "bucket", tools: [.bucket, .linearGradient, .sectorGradient], shortcutKey: "G"),
        .init(id: "selection-l", tools: [.lassoSelection, .smartSelection, .polygonSelection], shortcutKey: "L"),
        .init(id: "lasso-fill", tools: [.lassoFill, .textureFill], shortcutKey: "K"),
        .init(id: "selection-m", tools: [.rectangleSelection, .ellipseSelection], shortcutKey: "M"),
        .init(id: "straight-line", tools: [.straightLine], shortcutKey: "U"),
        .init(id: "smudge", tools: [.smudge], shortcutKey: "T"),
        .init(id: "color-adjust", tools: [.brightnessAdjust], shortcutKey: "O"),
        .init(id: "color-vitalization", tools: [.colorVitalization], shortcutKey: nil),
        .init(id: "canvas-rotate", tools: [.canvasRotate], shortcutKey: "R"),
        .init(id: "canvas-crop", tools: [.canvasCrop], shortcutKey: "C"),
        .init(id: "free-transform", tools: [.freeTransform], shortcutKey: "V"),
        .init(id: "perspective", tools: [.perspective], shortcutKey: "P"),
        .init(id: "block-reference", tools: [.blockReference], shortcutKey: nil)
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

    var opacityCurveState: CurveChannelState {
        BrushSettings.legacyPressureCurveState(
            low: opacityValues.low,
            mid: opacityValues.mid,
            high: opacityValues.high
        )
    }

    var sizeCurveState: CurveChannelState {
        BrushSettings.legacyPressureCurveState(
            low: sizeValues.low,
            mid: sizeValues.mid,
            high: sizeValues.high
        )
    }
}

struct CompoundPressureMixSettings: Codable, Equatable, Sendable {
    var primaryAtLowPressure: Float
    var primaryAtMidPressure: Float
    var primaryAtHighPressure: Float

    static let `default` = CompoundPressureMixSettings(
        primaryAtLowPressure: 0.0,
        primaryAtMidPressure: 0.45,
        primaryAtHighPressure: 1.00
    )

    static let primaryOnly = CompoundPressureMixSettings(
        primaryAtLowPressure: 1,
        primaryAtMidPressure: 1,
        primaryAtHighPressure: 1
    )

    static let secondaryOnly = CompoundPressureMixSettings(
        primaryAtLowPressure: 0,
        primaryAtMidPressure: 0,
        primaryAtHighPressure: 0
    )

    static let balanced = CompoundPressureMixSettings(
        primaryAtLowPressure: 0.5,
        primaryAtMidPressure: 0.5,
        primaryAtHighPressure: 0.5
    )

    static let reversed = CompoundPressureMixSettings(
        primaryAtLowPressure: 1,
        primaryAtMidPressure: 0.45,
        primaryAtHighPressure: 0
    )

    static let secondaryAtMidPressure = CompoundPressureMixSettings(
        primaryAtLowPressure: 1,
        primaryAtMidPressure: 0,
        primaryAtHighPressure: 1
    )

    func resolvedPrimaryWeight(for pressure: Float) -> Float {
        let clampedPressure = min(max(pressure, 0), 1)
        if clampedPressure <= 0.5 {
            let t = clampedPressure / 0.5
            return primaryAtLowPressure + ((primaryAtMidPressure - primaryAtLowPressure) * t)
        } else {
            let t = (clampedPressure - 0.5) / 0.5
            return primaryAtMidPressure + ((primaryAtHighPressure - primaryAtMidPressure) * t)
        }
    }
}

enum CompoundBrushMode: String, Codable, Equatable, Sendable, CaseIterable {
    case textureBlend
    case subtract
    case overlay
    case intersect

    var displayName: String {
        switch self {
        case .textureBlend:
            return "纹理出现处"
        case .subtract:
            return "纹理空白处"
        case .overlay:
            return "叠加遮罩"
        case .intersect:
            return "旧版相交"
        }
    }

    static let editorCases: [CompoundBrushMode] = [.textureBlend, .subtract, .overlay]

    var editorEquivalent: CompoundBrushMode {
        self == .intersect ? .textureBlend : self
    }
}

enum CompoundSecondarySizeMode: String, Codable, Equatable, Sendable, CaseIterable {
    case absolutePixels
    case relativeToPrimary

    var displayName: String {
        switch self {
        case .absolutePixels:
            return "绝对像素"
        case .relativeToPrimary:
            return "相对主笔尖"
        }
    }
}

struct CompoundSecondaryTipSettings: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case tipShape
        case sourceSemantic
        case tipAssetID
        case importedSourceInfo
        case customTipMaskData
        case softness
        case roundness
        case angleDegrees
        case followsStrokeDirection
        case sizeMode
        case size
        case relativeSizeRatio
        case spacingPercent
        case pressureSizeAmount
        case pressureOpacityAmount
        case sizeCurveLow
        case sizeCurveMid
        case sizeCurveHigh
        case opacityCurveLow
        case opacityCurveMid
        case opacityCurveHigh
        case opacityPressureCurve
        case tileRandomRotation
    }

    var tipShape: BrushTipShape
    var sourceSemantic: TipSourceSemantic
    var tipAssetID: BrushTipImageAssetID?
    var importedSourceInfo: ImportedTipSourceInfo?
    var customTipMaskData: Data?

    var softness: Float
    var roundness: Float
    var angleDegrees: Float
    var followsStrokeDirection: Bool

    var sizeMode: CompoundSecondarySizeMode
    var size: Float
    var relativeSizeRatio: Float
    var spacingPercent: Float

    var pressureSizeAmount: Float
    var pressureOpacityAmount: Float

    var sizeCurveLow: Float
    var sizeCurveMid: Float
    var sizeCurveHigh: Float

    var opacityCurveLow: Float
    var opacityCurveMid: Float
    var opacityCurveHigh: Float
    var opacityPressureCurve: CurveChannelState?

    /// 0 = no random rotation, 1 = full 360° random rotation per tile
    var tileRandomRotation: Float

    static let `default` = CompoundSecondaryTipSettings(
        tipShape: .softRound,
        sourceSemantic: .procedural,
        tipAssetID: nil,
        importedSourceInfo: nil,
        customTipMaskData: nil,
        softness: 0.45,
        roundness: 1.0,
        angleDegrees: 0,
        followsStrokeDirection: false,
        sizeMode: .relativeToPrimary,
        size: 24,
        relativeSizeRatio: 1.8,
        spacingPercent: 25,
        pressureSizeAmount: 0.30,
        pressureOpacityAmount: 1.00,
        sizeCurveLow: 0.20,
        sizeCurveMid: 0.60,
        sizeCurveHigh: 1.00,
        opacityCurveLow: 0.20,
        opacityCurveMid: 0.60,
        opacityCurveHigh: 1.00,
        opacityPressureCurve: nil,
        tileRandomRotation: 1.0
    )

    func resolvedSizeFactor(for pressure: Float) -> Float {
        let curved = BrushSettings.samplePressureCurve(
            pressure: pressure,
            low: sizeCurveLow,
            mid: sizeCurveMid,
            high: sizeCurveHigh
        )
        let response = min(max(pressureSizeAmount, 0), 1)
        return (1 - response) + (response * curved)
    }

    func resolvedOpacityFactor(for pressure: Float) -> Float {
        resolvedOpacityFactor(for: pressure, pressureSensitivity: 1)
    }

    func resolvedOpacityFactor(
        for pressure: Float,
        pressureSensitivity: Float
    ) -> Float {
        let remappedPressure = BrushSettings.remappedOpacityPressure(
            pressure: pressure,
            pressureSensitivity: pressureSensitivity
        )
        let curved = opacityPressureCurve.map {
            CurveLUTBuilder.sampleChannelValue(from: $0, at: remappedPressure)
        } ?? BrushSettings.resolvedOpacityCurvePressure(
            pressure: pressure,
            pressureSensitivity: pressureSensitivity,
            low: opacityCurveLow,
            mid: opacityCurveMid,
            high: opacityCurveHigh
        )
        let response = min(max(pressureOpacityAmount, 0), 1)
        return BrushSettings.resolvedPressureFactor(
            responseAmount: response,
            curvedPressure: curved
        )
    }

    func resolvedBaseSize(for primarySize: Float) -> Float {
        switch sizeMode {
        case .absolutePixels:
            return min(max(size, 1), 512)
        case .relativeToPrimary:
            let clampedRatio = min(max(relativeSizeRatio, 0.05), 4.0)
            return min(max(primarySize * clampedRatio, 1), 512)
        }
    }

    init(
        tipShape: BrushTipShape,
        sourceSemantic: TipSourceSemantic,
        tipAssetID: BrushTipImageAssetID?,
        importedSourceInfo: ImportedTipSourceInfo?,
        customTipMaskData: Data?,
        softness: Float,
        roundness: Float,
        angleDegrees: Float,
        followsStrokeDirection: Bool,
        sizeMode: CompoundSecondarySizeMode,
        size: Float,
        relativeSizeRatio: Float,
        spacingPercent: Float,
        pressureSizeAmount: Float,
        pressureOpacityAmount: Float,
        sizeCurveLow: Float,
        sizeCurveMid: Float,
        sizeCurveHigh: Float,
        opacityCurveLow: Float,
        opacityCurveMid: Float,
        opacityCurveHigh: Float,
        opacityPressureCurve: CurveChannelState? = nil,
        tileRandomRotation: Float = 1.0
    ) {
        self.tipShape = tipShape
        self.sourceSemantic = sourceSemantic
        self.tipAssetID = tipAssetID
        self.importedSourceInfo = importedSourceInfo
        self.customTipMaskData = customTipMaskData
        self.softness = softness
        self.roundness = roundness
        self.angleDegrees = angleDegrees
        self.followsStrokeDirection = followsStrokeDirection
        self.sizeMode = sizeMode
        self.size = size
        self.relativeSizeRatio = relativeSizeRatio
        self.spacingPercent = spacingPercent
        self.pressureSizeAmount = pressureSizeAmount
        self.pressureOpacityAmount = pressureOpacityAmount
        self.sizeCurveLow = sizeCurveLow
        self.sizeCurveMid = sizeCurveMid
        self.sizeCurveHigh = sizeCurveHigh
        self.opacityCurveLow = opacityCurveLow
        self.opacityCurveMid = opacityCurveMid
        self.opacityCurveHigh = opacityCurveHigh
        self.opacityPressureCurve = opacityPressureCurve
        self.tileRandomRotation = tileRandomRotation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CompoundSecondaryTipSettings.default

        tipShape = try container.decodeIfPresent(BrushTipShape.self, forKey: .tipShape) ?? defaults.tipShape
        sourceSemantic = try container.decodeIfPresent(TipSourceSemantic.self, forKey: .sourceSemantic) ?? defaults.sourceSemantic
        tipAssetID = try container.decodeIfPresent(BrushTipImageAssetID.self, forKey: .tipAssetID)
        importedSourceInfo = try container.decodeIfPresent(ImportedTipSourceInfo.self, forKey: .importedSourceInfo)
        customTipMaskData = try container.decodeIfPresent(Data.self, forKey: .customTipMaskData)
        softness = try container.decodeIfPresent(Float.self, forKey: .softness) ?? defaults.softness
        roundness = try container.decodeIfPresent(Float.self, forKey: .roundness) ?? defaults.roundness
        angleDegrees = try container.decodeIfPresent(Float.self, forKey: .angleDegrees) ?? defaults.angleDegrees
        followsStrokeDirection = try container.decodeIfPresent(Bool.self, forKey: .followsStrokeDirection) ?? defaults.followsStrokeDirection
        sizeMode = try container.decodeIfPresent(CompoundSecondarySizeMode.self, forKey: .sizeMode) ?? defaults.sizeMode
        size = try container.decodeIfPresent(Float.self, forKey: .size) ?? defaults.size
        relativeSizeRatio = try container.decodeIfPresent(Float.self, forKey: .relativeSizeRatio) ?? defaults.relativeSizeRatio
        spacingPercent = try container.decodeIfPresent(Float.self, forKey: .spacingPercent) ?? defaults.spacingPercent
        pressureSizeAmount = try container.decodeIfPresent(Float.self, forKey: .pressureSizeAmount) ?? defaults.pressureSizeAmount
        pressureOpacityAmount = try container.decodeIfPresent(Float.self, forKey: .pressureOpacityAmount) ?? defaults.pressureOpacityAmount
        sizeCurveLow = try container.decodeIfPresent(Float.self, forKey: .sizeCurveLow) ?? defaults.sizeCurveLow
        sizeCurveMid = try container.decodeIfPresent(Float.self, forKey: .sizeCurveMid) ?? defaults.sizeCurveMid
        sizeCurveHigh = try container.decodeIfPresent(Float.self, forKey: .sizeCurveHigh) ?? defaults.sizeCurveHigh
        opacityCurveLow = try container.decodeIfPresent(Float.self, forKey: .opacityCurveLow) ?? defaults.opacityCurveLow
        opacityCurveMid = try container.decodeIfPresent(Float.self, forKey: .opacityCurveMid) ?? defaults.opacityCurveMid
        opacityCurveHigh = try container.decodeIfPresent(Float.self, forKey: .opacityCurveHigh) ?? defaults.opacityCurveHigh
        opacityPressureCurve = try container.decodeIfPresent(CurveChannelState.self, forKey: .opacityPressureCurve)
        tileRandomRotation = try container.decodeIfPresent(Float.self, forKey: .tileRandomRotation) ?? defaults.tileRandomRotation
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tipShape, forKey: .tipShape)
        try container.encode(sourceSemantic, forKey: .sourceSemantic)
        try container.encodeIfPresent(tipAssetID, forKey: .tipAssetID)
        try container.encodeIfPresent(importedSourceInfo, forKey: .importedSourceInfo)
        try container.encodeIfPresent(customTipMaskData, forKey: .customTipMaskData)
        try container.encode(softness, forKey: .softness)
        try container.encode(roundness, forKey: .roundness)
        try container.encode(angleDegrees, forKey: .angleDegrees)
        try container.encode(followsStrokeDirection, forKey: .followsStrokeDirection)
        try container.encode(sizeMode, forKey: .sizeMode)
        try container.encode(size, forKey: .size)
        try container.encode(relativeSizeRatio, forKey: .relativeSizeRatio)
        try container.encode(spacingPercent, forKey: .spacingPercent)
        try container.encode(pressureSizeAmount, forKey: .pressureSizeAmount)
        try container.encode(pressureOpacityAmount, forKey: .pressureOpacityAmount)
        try container.encode(sizeCurveLow, forKey: .sizeCurveLow)
        try container.encode(sizeCurveMid, forKey: .sizeCurveMid)
        try container.encode(sizeCurveHigh, forKey: .sizeCurveHigh)
        try container.encode(opacityCurveLow, forKey: .opacityCurveLow)
        try container.encode(opacityCurveMid, forKey: .opacityCurveMid)
        try container.encode(opacityCurveHigh, forKey: .opacityCurveHigh)
        try container.encodeIfPresent(opacityPressureCurve, forKey: .opacityPressureCurve)
        try container.encode(tileRandomRotation, forKey: .tileRandomRotation)
    }
}

struct CompoundBrushSettings: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case enabled
        case mode
        case secondary
        case pressureMix
        case globalPressureSizeAmount
        case globalPressureOpacityAmount
        case globalPaintJitterAmount
        case globalPaintContrastAmount
    }

    var enabled: Bool
    var mode: CompoundBrushMode
    var secondary: CompoundSecondaryTipSettings
    var pressureMix: CompoundPressureMixSettings
    var globalPressureSizeAmount: Float
    var globalPressureOpacityAmount: Float
    var globalPaintJitterAmount: Float
    var globalPaintContrastAmount: Float

    static let disabledDefault = CompoundBrushSettings(
        enabled: false,
        mode: .textureBlend,
        secondary: .default,
        pressureMix: .default,
        globalPressureSizeAmount: 0,
        globalPressureOpacityAmount: 0,
        globalPaintJitterAmount: 0,
        globalPaintContrastAmount: 0
    )

    init(
        enabled: Bool,
        mode: CompoundBrushMode,
        secondary: CompoundSecondaryTipSettings,
        pressureMix: CompoundPressureMixSettings,
        globalPressureSizeAmount: Float = 0,
        globalPressureOpacityAmount: Float = 0,
        globalPaintJitterAmount: Float = 0,
        globalPaintContrastAmount: Float = 0
    ) {
        self.enabled = enabled
        self.mode = mode
        self.secondary = secondary
        self.pressureMix = pressureMix
        self.globalPressureSizeAmount = globalPressureSizeAmount
        self.globalPressureOpacityAmount = globalPressureOpacityAmount
        self.globalPaintJitterAmount = globalPaintJitterAmount
        self.globalPaintContrastAmount = globalPaintContrastAmount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CompoundBrushSettings.disabledDefault
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        mode = try container.decodeIfPresent(CompoundBrushMode.self, forKey: .mode) ?? defaults.mode
        secondary = try container.decodeIfPresent(CompoundSecondaryTipSettings.self, forKey: .secondary) ?? defaults.secondary
        pressureMix = try container.decodeIfPresent(CompoundPressureMixSettings.self, forKey: .pressureMix) ?? defaults.pressureMix
        globalPressureSizeAmount = try container.decodeIfPresent(Float.self, forKey: .globalPressureSizeAmount)
            ?? defaults.globalPressureSizeAmount
        globalPressureOpacityAmount = try container.decodeIfPresent(Float.self, forKey: .globalPressureOpacityAmount)
            ?? defaults.globalPressureOpacityAmount
        globalPaintJitterAmount = try container.decodeIfPresent(Float.self, forKey: .globalPaintJitterAmount)
            ?? defaults.globalPaintJitterAmount
        globalPaintContrastAmount = try container.decodeIfPresent(Float.self, forKey: .globalPaintContrastAmount)
            ?? defaults.globalPaintContrastAmount
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(mode, forKey: .mode)
        try container.encode(secondary, forKey: .secondary)
        try container.encode(pressureMix, forKey: .pressureMix)
        try container.encode(globalPressureSizeAmount, forKey: .globalPressureSizeAmount)
        try container.encode(globalPressureOpacityAmount, forKey: .globalPressureOpacityAmount)
        try container.encode(globalPaintJitterAmount, forKey: .globalPaintJitterAmount)
        try container.encode(globalPaintContrastAmount, forKey: .globalPaintContrastAmount)
    }
}

struct BrushSettings: Codable, Sendable, Equatable {
    var size: Float
    var opacity: Float
    var buildMode: BrushBuildMode
    var tipShape: BrushTipShape
    var spacingPercent: Float
    var scatterAmount: Float
    var jitterAmount: Float
    var sizeJitterAmount: Float
    var angleJitterAmount: Float
    var colorJitterAmount: Float
    var paintJitterAmount: Float
    var paintContrastAmount: Float
    var oilPaint: OilPaintBrushSettings
    var stampRotationDegrees: Float
    var followsStrokeDirection: Bool
    var customTipSourceSemantic: TipSourceSemantic
    var customTipAssetID: BrushTipImageAssetID?
    var customTipImportedSourceInfo: ImportedTipSourceInfo?
    var customTipMaskData: Data?
    var customTipEnvelopeMaskData: Data?
    var customTipSoftness: Float
    var customTipRoundness: Float
    var customTipAngleDegrees: Float
    var pressureSensitivity: Float
    var sizeLowerBound: Float
    var pressureSizeAmount: Float
    var pressureOpacityAmount: Float
    var buildUpOpacityCompensationAmount: Float
    var sizeCurveLow: Float
    var sizeCurveMid: Float
    var sizeCurveHigh: Float
    var sizePressureCurve: CurveChannelState?
    var opacityCurveLow: Float
    var opacityCurveMid: Float
    var opacityCurveHigh: Float
    var opacityPressureCurve: CurveChannelState?
    var compoundBrush: CompoundBrushSettings

    static let stageOneDefault = BrushSettings(
        size: 24,
        opacity: 1,
        buildMode: .buildUp,
        tipShape: .hardRound,
        spacingPercent: 15,
        scatterAmount: 0,
        jitterAmount: 0,
        sizeJitterAmount: 0,
        angleJitterAmount: 0,
        colorJitterAmount: 0,
        paintJitterAmount: 0,
        paintContrastAmount: 0,
        oilPaint: .disabled,
        stampRotationDegrees: 0,
        followsStrokeDirection: false,
        customTipSourceSemantic: .procedural,
        customTipAssetID: nil,
        customTipImportedSourceInfo: nil,
        customTipMaskData: nil,
        customTipEnvelopeMaskData: nil,
        customTipSoftness: 0.5,
        customTipRoundness: 1,
        customTipAngleDegrees: 0,
        pressureSensitivity: 1,
        sizeLowerBound: 0,
        pressureSizeAmount: 0,
        pressureOpacityAmount: 0,
        buildUpOpacityCompensationAmount: 1,
        sizeCurveLow: 0.18,
        sizeCurveMid: 0.52,
        sizeCurveHigh: 0.88,
        sizePressureCurve: nil,
        opacityCurveLow: 0.05,
        opacityCurveMid: 0.4,
        opacityCurveHigh: 0.82,
        opacityPressureCurve: nil,
        compoundBrush: .disabledDefault
    )

    enum CodingKeys: String, CodingKey {
        case size
        case opacity
        case buildMode
        case tipShape
        case spacingPercent
        case scatterAmount
        case jitterAmount
        case sizeJitterAmount
        case angleJitterAmount
        case colorJitterAmount
        case paintJitterAmount
        case paintContrastAmount
        case oilPaint
        case stampRotationDegrees
        case followsStrokeDirection
        case customTipSourceSemantic
        case customTipAssetID
        case customTipImportedSourceInfo
        case customTipMaskData
        case customTipEnvelopeMaskData
        case customTipSoftness
        case customTipRoundness
        case customTipAngleDegrees
        case pressureSensitivity
        case sizeLowerBound
        case pressureSizeAmount
        case pressureOpacityAmount
        case buildUpOpacityCompensationAmount
        case sizeCurveLow
        case sizeCurveMid
        case sizeCurveHigh
        case sizePressureCurve
        case opacityCurveLow
        case opacityCurveMid
        case opacityCurveHigh
        case opacityPressureCurve
        case compoundBrush
    }

    init(
        size: Float,
        opacity: Float,
        buildMode: BrushBuildMode,
        tipShape: BrushTipShape,
        spacingPercent: Float,
        scatterAmount: Float,
        jitterAmount: Float,
        sizeJitterAmount: Float? = nil,
        angleJitterAmount: Float? = nil,
        colorJitterAmount: Float = 0,
        paintJitterAmount: Float = 0,
        paintContrastAmount: Float = 0,
        oilPaint: OilPaintBrushSettings = .disabled,
        stampRotationDegrees: Float,
        followsStrokeDirection: Bool,
        customTipSourceSemantic: TipSourceSemantic = .procedural,
        customTipAssetID: BrushTipImageAssetID? = nil,
        customTipImportedSourceInfo: ImportedTipSourceInfo? = nil,
        customTipMaskData: Data? = nil,
        customTipEnvelopeMaskData: Data? = nil,
        customTipSoftness: Float,
        customTipRoundness: Float,
        customTipAngleDegrees: Float,
        pressureSensitivity: Float,
        sizeLowerBound: Float,
        pressureSizeAmount: Float,
        pressureOpacityAmount: Float,
        buildUpOpacityCompensationAmount: Float = 1,
        sizeCurveLow: Float,
        sizeCurveMid: Float,
        sizeCurveHigh: Float,
        sizePressureCurve: CurveChannelState? = nil,
        opacityCurveLow: Float,
        opacityCurveMid: Float,
        opacityCurveHigh: Float,
        opacityPressureCurve: CurveChannelState? = nil,
        compoundBrush: CompoundBrushSettings = .disabledDefault
    ) {
        self.size = size
        self.opacity = opacity
        self.buildMode = buildMode
        self.tipShape = tipShape
        self.spacingPercent = spacingPercent
        self.scatterAmount = scatterAmount
        self.jitterAmount = jitterAmount
        self.sizeJitterAmount = sizeJitterAmount ?? jitterAmount
        self.angleJitterAmount = angleJitterAmount ?? jitterAmount
        self.colorJitterAmount = colorJitterAmount
        self.paintJitterAmount = paintJitterAmount
        self.paintContrastAmount = paintContrastAmount
        self.oilPaint = oilPaint
        self.stampRotationDegrees = stampRotationDegrees
        self.followsStrokeDirection = followsStrokeDirection
        self.customTipSourceSemantic = customTipSourceSemantic
        self.customTipAssetID = customTipAssetID
        self.customTipImportedSourceInfo = customTipImportedSourceInfo
        self.customTipMaskData = customTipMaskData
        self.customTipEnvelopeMaskData = customTipEnvelopeMaskData
        self.customTipSoftness = customTipSoftness
        self.customTipRoundness = customTipRoundness
        self.customTipAngleDegrees = customTipAngleDegrees
        self.pressureSensitivity = pressureSensitivity
        self.sizeLowerBound = sizeLowerBound
        self.pressureSizeAmount = pressureSizeAmount
        self.pressureOpacityAmount = pressureOpacityAmount
        self.buildUpOpacityCompensationAmount = buildUpOpacityCompensationAmount
        self.sizeCurveLow = sizeCurveLow
        self.sizeCurveMid = sizeCurveMid
        self.sizeCurveHigh = sizeCurveHigh
        self.sizePressureCurve = sizePressureCurve.map(Self.normalizedPressureCurveState(_:))
        self.opacityCurveLow = opacityCurveLow
        self.opacityCurveMid = opacityCurveMid
        self.opacityCurveHigh = opacityCurveHigh
        self.opacityPressureCurve = opacityPressureCurve.map(Self.normalizedPressureCurveState(_:))
        self.compoundBrush = compoundBrush
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BrushSettings.stageOneDefault

        size = try container.decodeIfPresent(Float.self, forKey: .size) ?? defaults.size
        opacity = try container.decodeIfPresent(Float.self, forKey: .opacity) ?? defaults.opacity
        buildMode = try container.decodeIfPresent(BrushBuildMode.self, forKey: .buildMode) ?? defaults.buildMode
        tipShape = try container.decodeIfPresent(BrushTipShape.self, forKey: .tipShape) ?? defaults.tipShape
        spacingPercent = try container.decodeIfPresent(Float.self, forKey: .spacingPercent) ?? defaults.spacingPercent
        scatterAmount = try container.decodeIfPresent(Float.self, forKey: .scatterAmount) ?? defaults.scatterAmount
        jitterAmount = try container.decodeIfPresent(Float.self, forKey: .jitterAmount) ?? defaults.jitterAmount
        sizeJitterAmount = try container.decodeIfPresent(Float.self, forKey: .sizeJitterAmount) ?? jitterAmount
        angleJitterAmount = try container.decodeIfPresent(Float.self, forKey: .angleJitterAmount) ?? jitterAmount
        colorJitterAmount = try container.decodeIfPresent(Float.self, forKey: .colorJitterAmount) ?? defaults.colorJitterAmount
        paintJitterAmount = try container.decodeIfPresent(Float.self, forKey: .paintJitterAmount) ?? defaults.paintJitterAmount
        paintContrastAmount = try container.decodeIfPresent(Float.self, forKey: .paintContrastAmount) ?? defaults.paintContrastAmount
        oilPaint = try container.decodeIfPresent(OilPaintBrushSettings.self, forKey: .oilPaint) ?? defaults.oilPaint
        stampRotationDegrees = try container.decodeIfPresent(Float.self, forKey: .stampRotationDegrees) ?? defaults.stampRotationDegrees
        followsStrokeDirection = try container.decodeIfPresent(Bool.self, forKey: .followsStrokeDirection) ?? defaults.followsStrokeDirection
        customTipSourceSemantic = try container.decodeIfPresent(TipSourceSemantic.self, forKey: .customTipSourceSemantic) ?? defaults.customTipSourceSemantic
        customTipAssetID = try container.decodeIfPresent(BrushTipImageAssetID.self, forKey: .customTipAssetID) ?? defaults.customTipAssetID
        customTipImportedSourceInfo = try container.decodeIfPresent(ImportedTipSourceInfo.self, forKey: .customTipImportedSourceInfo) ?? defaults.customTipImportedSourceInfo
        customTipMaskData = try container.decodeIfPresent(Data.self, forKey: .customTipMaskData) ?? defaults.customTipMaskData
        customTipEnvelopeMaskData = try container.decodeIfPresent(Data.self, forKey: .customTipEnvelopeMaskData) ?? defaults.customTipEnvelopeMaskData
        customTipSoftness = try container.decodeIfPresent(Float.self, forKey: .customTipSoftness) ?? defaults.customTipSoftness
        customTipRoundness = try container.decodeIfPresent(Float.self, forKey: .customTipRoundness) ?? defaults.customTipRoundness
        customTipAngleDegrees = try container.decodeIfPresent(Float.self, forKey: .customTipAngleDegrees) ?? defaults.customTipAngleDegrees
        pressureSensitivity = try container.decodeIfPresent(Float.self, forKey: .pressureSensitivity) ?? defaults.pressureSensitivity
        sizeLowerBound = try container.decodeIfPresent(Float.self, forKey: .sizeLowerBound) ?? defaults.sizeLowerBound
        pressureSizeAmount = try container.decodeIfPresent(Float.self, forKey: .pressureSizeAmount) ?? defaults.pressureSizeAmount
        pressureOpacityAmount = try container.decodeIfPresent(Float.self, forKey: .pressureOpacityAmount) ?? defaults.pressureOpacityAmount
        buildUpOpacityCompensationAmount = try container.decodeIfPresent(Float.self, forKey: .buildUpOpacityCompensationAmount)
            ?? defaults.buildUpOpacityCompensationAmount
        sizeCurveLow = try container.decodeIfPresent(Float.self, forKey: .sizeCurveLow) ?? defaults.sizeCurveLow
        sizeCurveMid = try container.decodeIfPresent(Float.self, forKey: .sizeCurveMid) ?? defaults.sizeCurveMid
        sizeCurveHigh = try container.decodeIfPresent(Float.self, forKey: .sizeCurveHigh) ?? defaults.sizeCurveHigh
        sizePressureCurve = try container.decodeIfPresent(CurveChannelState.self, forKey: .sizePressureCurve)
            .map(Self.normalizedPressureCurveState(_:))
        opacityCurveLow = try container.decodeIfPresent(Float.self, forKey: .opacityCurveLow) ?? defaults.opacityCurveLow
        opacityCurveMid = try container.decodeIfPresent(Float.self, forKey: .opacityCurveMid) ?? defaults.opacityCurveMid
        opacityCurveHigh = try container.decodeIfPresent(Float.self, forKey: .opacityCurveHigh) ?? defaults.opacityCurveHigh
        opacityPressureCurve = try container.decodeIfPresent(CurveChannelState.self, forKey: .opacityPressureCurve)
            .map(Self.normalizedPressureCurveState(_:))
        compoundBrush = try container.decodeIfPresent(CompoundBrushSettings.self, forKey: .compoundBrush) ?? defaults.compoundBrush
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(size, forKey: .size)
        try container.encode(opacity, forKey: .opacity)
        try container.encode(buildMode, forKey: .buildMode)
        try container.encode(tipShape, forKey: .tipShape)
        try container.encode(spacingPercent, forKey: .spacingPercent)
        try container.encode(scatterAmount, forKey: .scatterAmount)
        try container.encode(jitterAmount, forKey: .jitterAmount)
        try container.encode(sizeJitterAmount, forKey: .sizeJitterAmount)
        try container.encode(angleJitterAmount, forKey: .angleJitterAmount)
        try container.encode(colorJitterAmount, forKey: .colorJitterAmount)
        try container.encode(paintJitterAmount, forKey: .paintJitterAmount)
        try container.encode(paintContrastAmount, forKey: .paintContrastAmount)
        try container.encode(oilPaint, forKey: .oilPaint)
        try container.encode(stampRotationDegrees, forKey: .stampRotationDegrees)
        try container.encode(followsStrokeDirection, forKey: .followsStrokeDirection)
        try container.encode(customTipSourceSemantic, forKey: .customTipSourceSemantic)
        try container.encodeIfPresent(customTipAssetID, forKey: .customTipAssetID)
        try container.encodeIfPresent(customTipImportedSourceInfo, forKey: .customTipImportedSourceInfo)
        try container.encodeIfPresent(customTipMaskData, forKey: .customTipMaskData)
        try container.encodeIfPresent(customTipEnvelopeMaskData, forKey: .customTipEnvelopeMaskData)
        try container.encode(customTipSoftness, forKey: .customTipSoftness)
        try container.encode(customTipRoundness, forKey: .customTipRoundness)
        try container.encode(customTipAngleDegrees, forKey: .customTipAngleDegrees)
        try container.encode(pressureSensitivity, forKey: .pressureSensitivity)
        try container.encode(sizeLowerBound, forKey: .sizeLowerBound)
        try container.encode(pressureSizeAmount, forKey: .pressureSizeAmount)
        try container.encode(pressureOpacityAmount, forKey: .pressureOpacityAmount)
        try container.encode(buildUpOpacityCompensationAmount, forKey: .buildUpOpacityCompensationAmount)
        try container.encode(sizeCurveLow, forKey: .sizeCurveLow)
        try container.encode(sizeCurveMid, forKey: .sizeCurveMid)
        try container.encode(sizeCurveHigh, forKey: .sizeCurveHigh)
        try container.encodeIfPresent(sizePressureCurve, forKey: .sizePressureCurve)
        try container.encode(opacityCurveLow, forKey: .opacityCurveLow)
        try container.encode(opacityCurveMid, forKey: .opacityCurveMid)
        try container.encode(opacityCurveHigh, forKey: .opacityCurveHigh)
        try container.encodeIfPresent(opacityPressureCurve, forKey: .opacityPressureCurve)
        try container.encode(compoundBrush, forKey: .compoundBrush)
    }

    var resolvedSizePressureCurveState: CurveChannelState {
        sizePressureCurve ?? Self.legacyPressureCurveState(
            low: sizeCurveLow,
            mid: sizeCurveMid,
            high: sizeCurveHigh
        )
    }

    var resolvedOpacityPressureCurveState: CurveChannelState {
        opacityPressureCurve ?? Self.legacyPressureCurveState(
            low: opacityCurveLow,
            mid: opacityCurveMid,
            high: opacityCurveHigh
        )
    }

    mutating func setLegacySizeCurveValues(
        low: Float,
        mid: Float,
        high: Float
    ) {
        let state = Self.legacyPressureCurveState(low: low, mid: mid, high: high)
        setSizePressureCurveState(state)
    }

    mutating func setLegacyOpacityCurveValues(
        low: Float,
        mid: Float,
        high: Float
    ) {
        let state = Self.legacyPressureCurveState(low: low, mid: mid, high: high)
        setOpacityPressureCurveState(state)
    }

    mutating func setSizePressureCurveState(_ state: CurveChannelState) {
        let normalized = Self.normalizedPressureCurveState(state)
        sizePressureCurve = normalized
        let compatibilityValues = Self.legacyPressureCurveValues(from: normalized)
        sizeCurveLow = compatibilityValues.low
        sizeCurveMid = compatibilityValues.mid
        sizeCurveHigh = compatibilityValues.high
    }

    mutating func setOpacityPressureCurveState(_ state: CurveChannelState) {
        let normalized = Self.normalizedPressureCurveState(state)
        opacityPressureCurve = normalized
        let compatibilityValues = Self.legacyPressureCurveValues(from: normalized)
        opacityCurveLow = compatibilityValues.low
        opacityCurveMid = compatibilityValues.mid
        opacityCurveHigh = compatibilityValues.high
    }

    static func samplePressureCurve(
        pressure: Float,
        low: Float,
        mid: Float,
        high: Float
    ) -> Float {
        samplePressureCurve(
            pressure: pressure,
            state: legacyPressureCurveState(low: low, mid: mid, high: high)
        )
    }

    static func samplePressureCurve(
        pressure: Float,
        state: CurveChannelState
    ) -> Float {
        CurveLUTBuilder.sampleChannelValue(
            from: normalizedPressureCurveState(state),
            at: pressure
        )
    }

    static func pressureCurveControlPoints(
        low: Float,
        mid: Float,
        high: Float
    ) -> [CurveControlPoint] {
        let clampedLow = min(max(low, 0), 0.85)
        let clampedMid = min(max(mid, clampedLow), 0.95)
        let clampedHigh = min(max(high, clampedMid), 1)
        return [
            .init(x: 0.0, y: 0.0),
            .init(x: 0.2, y: clampedLow),
            .init(x: 0.5, y: clampedMid),
            .init(x: 0.8, y: clampedHigh),
            .init(x: 1.0, y: 1.0)
        ]
    }

    static func legacyPressureCurveState(
        low: Float,
        mid: Float,
        high: Float
    ) -> CurveChannelState {
        normalizedPressureCurveState(
            CurveChannelState(points: pressureCurveControlPoints(low: low, mid: mid, high: high))
        )
    }

    static func legacyPressureCurveValues(
        from state: CurveChannelState
    ) -> (low: Float, mid: Float, high: Float) {
        let normalized = normalizedPressureCurveState(state)
        return (
            low: CurveLUTBuilder.sampleChannelValue(from: normalized, at: 0.2),
            mid: CurveLUTBuilder.sampleChannelValue(from: normalized, at: 0.5),
            high: CurveLUTBuilder.sampleChannelValue(from: normalized, at: 0.8)
        )
    }

    static func normalizedPressureCurveState(_ state: CurveChannelState) -> CurveChannelState {
        var points = state.points
        if points.count < 2 {
            points = [.init(x: 0, y: 0), .init(x: 1, y: 1)]
        }
        points[0] = .init(x: 0, y: 0)
        points[points.count - 1] = .init(x: 1, y: 1)
        return CurveChannelState(points: points)
    }

    static func resolvedPressureFactor(
        responseAmount: Float,
        curvedPressure: Float
    ) -> Float {
        let response = min(max(responseAmount, 0), 1)
        return (1 - response) + (response * curvedPressure)
    }

    static func resolvedSizeJitterMultiplier(
        randomUnitValue: Float,
        amount: Float
    ) -> Float {
        let random = min(max(randomUnitValue, 0), 1)
        let clampedAmount = min(max(amount, 0), 1)
        return max(1 + (clampedAmount * ((random * 2) - 1)), 0.05)
    }

    var effectivePaintJitterAmount: Float {
        compoundBrush.enabled
            ? compoundBrush.globalPaintJitterAmount
            : paintJitterAmount
    }

    var effectivePaintContrastAmount: Float {
        0
    }

    static func remappedOpacityPressure(
        pressure: Float,
        pressureSensitivity: Float
    ) -> Float {
        let clamped = min(max(pressure, 0), 1)
        let sensitivity = min(max(pressureSensitivity, 0), 2)
        guard sensitivity > 0.0001 else {
            return 1
        }
        return pow(clamped, sensitivity)
    }

    static func resolvedOpacityCurvePressure(
        pressure: Float,
        pressureSensitivity: Float,
        low: Float,
        mid: Float,
        high: Float
    ) -> Float {
        let remapped = remappedOpacityPressure(
            pressure: pressure,
            pressureSensitivity: pressureSensitivity
        )
        return samplePressureCurve(
            pressure: remapped,
            low: low,
            mid: mid,
            high: high
        )
    }

    static func resolvedOpacityCurvePressure(
        pressure: Float,
        pressureSensitivity: Float,
        state: CurveChannelState
    ) -> Float {
        let remapped = remappedOpacityPressure(
            pressure: pressure,
            pressureSensitivity: pressureSensitivity
        )
        return samplePressureCurve(
            pressure: remapped,
            state: state
        )
    }

    static func resolvedSizeCurvePressure(
        pressure: Float,
        pressureSensitivity: Float,
        sizeLowerBound: Float,
        state: CurveChannelState
    ) -> Float {
        let remapped = remappedOpacityPressure(
            pressure: pressure,
            pressureSensitivity: pressureSensitivity
        )
        let curved = samplePressureCurve(pressure: remapped, state: state)
        let lowerBound = min(max(sizeLowerBound, 0), 1)
        return lowerBound + ((1 - lowerBound) * curved)
    }

    static func spacingCompensatedBuildUpAlpha(
        targetVisibleAlpha: Float,
        spacingPx: Float,
        stampDiameterPx: Float
    ) -> Float {
        let target = min(max(targetVisibleAlpha, 0), 1)
        guard target > 0 else { return 0 }
        let advanceRatio = min(max(spacingPx / max(stampDiameterPx, 1), 0.02), 1)
        guard advanceRatio < 0.999 else { return target }
        return 1 - pow(max(1 - target, 0), advanceRatio)
    }

    static func resolvedBuildUpVisibleAlpha(
        targetVisibleAlpha: Float,
        spacingPx: Float,
        stampDiameterPx: Float,
        compensationAmount: Float
    ) -> Float {
        let target = min(max(targetVisibleAlpha, 0), 1)
        let amount = min(max(compensationAmount, 0), 1)
        guard amount > 0.0001 else { return target }
        let compensated = spacingCompensatedBuildUpAlpha(
            targetVisibleAlpha: target,
            spacingPx: spacingPx,
            stampDiameterPx: stampDiameterPx
        )
        return target + ((compensated - target) * amount)
    }

    static func resolvedBuildUpCompensationAmount(
        automaticCompensationAmount: Float,
        brushCompensationAmount: Float
    ) -> Float {
        let automatic = min(max(automaticCompensationAmount, 0), 1)
        let brush = min(max(brushCompensationAmount, 0), 1)
        return automatic * brush
    }
}

extension BrushSettings {
    /// Rendering modes that need a stroke-scoped mask session instead of the
    /// ordinary per-stamp color pipeline. Overlay compound brushes must keep A
    /// and B in independent accumulation textures so their own stamp cadences
    /// survive until the final pixel blend.
    var requiresStrokeMaskSession: Bool {
        buildMode == .opacityCap || (
            buildMode == .buildUp &&
            compoundBrush.enabled &&
            compoundBrush.mode == .overlay
        )
    }

    var primaryTipAsCompoundSecondary: CompoundSecondaryTipSettings {
        CompoundSecondaryTipSettings(
            tipShape: tipShape,
            sourceSemantic: customTipSourceSemantic,
            tipAssetID: customTipAssetID,
            importedSourceInfo: customTipImportedSourceInfo,
            customTipMaskData: customTipMaskData,
            softness: customTipSoftness,
            roundness: customTipRoundness,
            angleDegrees: stampRotationDegrees,
            followsStrokeDirection: followsStrokeDirection,
            sizeMode: .relativeToPrimary,
            size: size,
            relativeSizeRatio: 1,
            spacingPercent: spacingPercent,
            pressureSizeAmount: pressureSizeAmount,
            pressureOpacityAmount: pressureOpacityAmount,
            sizeCurveLow: sizeCurveLow,
            sizeCurveMid: sizeCurveMid,
            sizeCurveHigh: sizeCurveHigh,
            opacityCurveLow: opacityCurveLow,
            opacityCurveMid: opacityCurveMid,
            opacityCurveHigh: opacityCurveHigh,
            opacityPressureCurve: opacityPressureCurve,
            tileRandomRotation: compoundBrush.secondary.tileRandomRotation
        )
    }

    mutating func copyPrimaryTipToCompoundSecondary() {
        compoundBrush.secondary = primaryTipAsCompoundSecondary
    }

    mutating func copyCompoundSecondaryTipToPrimary() {
        let secondary = compoundBrush.secondary
        tipShape = secondary.tipShape
        customTipSourceSemantic = secondary.sourceSemantic
        customTipAssetID = secondary.tipAssetID
        customTipImportedSourceInfo = secondary.importedSourceInfo
        customTipMaskData = secondary.customTipMaskData
        customTipEnvelopeMaskData = secondary.customTipMaskData
        customTipSoftness = secondary.softness
        customTipRoundness = secondary.roundness
        customTipAngleDegrees = secondary.angleDegrees
        stampRotationDegrees = secondary.angleDegrees
        followsStrokeDirection = secondary.followsStrokeDirection
        size = secondary.resolvedBaseSize(for: size)
        spacingPercent = secondary.spacingPercent
        pressureSizeAmount = secondary.pressureSizeAmount
        pressureOpacityAmount = secondary.pressureOpacityAmount
        sizeCurveLow = secondary.sizeCurveLow
        sizeCurveMid = secondary.sizeCurveMid
        sizeCurveHigh = secondary.sizeCurveHigh
        sizePressureCurve = nil
        opacityCurveLow = secondary.opacityCurveLow
        opacityCurveMid = secondary.opacityCurveMid
        opacityCurveHigh = secondary.opacityCurveHigh
        opacityPressureCurve = secondary.opacityPressureCurve
    }

    mutating func swapCompoundPrimaryAndSecondaryTips() {
        var originalPrimary = primaryTipAsCompoundSecondary
        originalPrimary.sizeMode = .absolutePixels
        originalPrimary.size = size
        copyCompoundSecondaryTipToPrimary()
        compoundBrush.secondary = originalPrimary
    }
}

enum TextureFillArrangement: String, Codable, Equatable, Sendable, CaseIterable {
    case directional
    case interwoven
    case radial
    case scattered

    var displayName: String {
        switch self {
        case .directional:
            return "流向"
        case .interwoven:
            return "交织"
        case .radial:
            return "环形"
        case .scattered:
            return "散布"
        }
    }

}

struct TextureFillTipSettings: Codable, Equatable, Sendable {
    var sourceSemantic: TipSourceSemantic
    var tipAssetID: BrushTipImageAssetID?
    var importedSourceInfo: ImportedTipSourceInfo?
    var customTipMaskData: Data?
    var arrangement: TextureFillArrangement
    var materialScale: Float
    var coverage: Float
    var variation: Float
    var paintJitterAmount: Float

    static let proceduralDefault = TextureFillTipSettings(
        sourceSemantic: .procedural,
        tipAssetID: nil,
        importedSourceInfo: nil,
        customTipMaskData: nil,
        arrangement: .directional,
        materialScale: 1,
        coverage: 0.58,
        variation: 0.45,
        paintJitterAmount: 0
    )

    private enum CodingKeys: String, CodingKey {
        case sourceSemantic
        case tipAssetID
        case importedSourceInfo
        case customTipMaskData
        case arrangement
        case materialScale
        case coverage
        case variation
        case paintJitterAmount
    }

    init(
        sourceSemantic: TipSourceSemantic,
        tipAssetID: BrushTipImageAssetID?,
        importedSourceInfo: ImportedTipSourceInfo?,
        customTipMaskData: Data?,
        arrangement: TextureFillArrangement = .directional,
        materialScale: Float = 1,
        coverage: Float = 0.58,
        variation: Float = 0.45,
        paintJitterAmount: Float = 0
    ) {
        self.sourceSemantic = sourceSemantic
        self.tipAssetID = tipAssetID
        self.importedSourceInfo = importedSourceInfo
        self.customTipMaskData = customTipMaskData
        self.arrangement = arrangement
        self.materialScale = min(max(materialScale, 0.25), 3)
        self.coverage = min(max(coverage, 0.1), 1)
        self.variation = min(max(variation, 0), 1)
        self.paintJitterAmount = min(max(paintJitterAmount, 0), 1)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sourceSemantic: try container.decode(TipSourceSemantic.self, forKey: .sourceSemantic),
            tipAssetID: try container.decodeIfPresent(BrushTipImageAssetID.self, forKey: .tipAssetID),
            importedSourceInfo: try container.decodeIfPresent(ImportedTipSourceInfo.self, forKey: .importedSourceInfo),
            customTipMaskData: try container.decodeIfPresent(Data.self, forKey: .customTipMaskData),
            arrangement: try container.decodeIfPresent(TextureFillArrangement.self, forKey: .arrangement) ?? .directional,
            materialScale: try container.decodeIfPresent(Float.self, forKey: .materialScale) ?? 1,
            coverage: try container.decodeIfPresent(Float.self, forKey: .coverage) ?? 0.58,
            variation: try container.decodeIfPresent(Float.self, forKey: .variation) ?? 0.45,
            paintJitterAmount: try container.decodeIfPresent(Float.self, forKey: .paintJitterAmount) ?? 0
        )
    }
}

struct ToolSessionState: Codable, Sendable, Equatable {
    var activeTool: ToolKind {
        didSet {
            guard activeTool != oldValue else { return }
            synchronizeActiveBrushForToolChange(from: oldValue)
        }
    }
    var brush: BrushSettings {
        didSet {
            guard !isSynchronizingBrushSlots else { return }
            synchronizeStoredBrushesFromActiveBrush()
        }
    }
    var selectedColor: RGBAColor
    var drawingBrush: BrushSettings
    var smudgeBrush: BrushSettings
    var eraserBrush: BrushSettings
    var smudgeBrushUsesIndependentSettings: Bool
    var textureFillTip: TextureFillTipSettings
    var textureFillBrushOverride: BrushSettings?
    var eyedropper: EyedropperSettings
    var oilPaintReservoir: OilPaintPigmentReservoirState
    var oilPaintOutputMode: OilPaintOutputMode

    private var isSynchronizingBrushSlots = false

    init(
        activeTool: ToolKind,
        brush: BrushSettings,
        selectedColor: RGBAColor,
        drawingBrush: BrushSettings? = nil,
        smudgeBrush: BrushSettings? = nil,
        eraserBrush: BrushSettings? = nil,
        smudgeBrushUsesIndependentSettings: Bool = false,
        textureFillTip: TextureFillTipSettings = .proceduralDefault,
        textureFillBrushOverride: BrushSettings? = nil,
        eyedropper: EyedropperSettings = .stageOneDefault,
        oilPaintReservoir: OilPaintPigmentReservoirState? = nil,
        oilPaintOutputMode: OilPaintOutputMode = .reservoir
    ) {
        self.activeTool = activeTool
        self.brush = brush
        self.selectedColor = selectedColor
        self.drawingBrush = drawingBrush ?? brush
        self.smudgeBrush = smudgeBrush ?? brush
        self.eraserBrush = eraserBrush ?? brush
        self.smudgeBrushUsesIndependentSettings = smudgeBrushUsesIndependentSettings
        self.textureFillTip = textureFillTip
        self.textureFillBrushOverride = textureFillBrushOverride
        self.eyedropper = eyedropper
        self.oilPaintReservoir = oilPaintReservoir ?? OilPaintPigmentReservoirState(cleanColor: selectedColor)
        self.oilPaintOutputMode = oilPaintOutputMode
        synchronizeOnInitialization()
    }

    private enum CodingKeys: String, CodingKey {
        case activeTool
        case brush
        case selectedColor
        case drawingBrush
        case smudgeBrush
        case eraserBrush
        case smudgeBrushUsesIndependentSettings
        case textureFillTip
        case textureFillBrushOverride
        case eyedropper
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let activeTool = try container.decode(ToolKind.self, forKey: .activeTool)
        let brush = try container.decode(BrushSettings.self, forKey: .brush)
        let selectedColor = try container.decode(RGBAColor.self, forKey: .selectedColor)
        let decodedDrawingBrush = try container.decodeIfPresent(BrushSettings.self, forKey: .drawingBrush)
        let decodedSmudgeBrush = try container.decodeIfPresent(BrushSettings.self, forKey: .smudgeBrush)
        let decodedEraserBrush = try container.decodeIfPresent(BrushSettings.self, forKey: .eraserBrush)
        let decodedSmudgeUsesIndependent = try container.decodeIfPresent(Bool.self, forKey: .smudgeBrushUsesIndependentSettings)
        self.init(
            activeTool: activeTool,
            brush: brush,
            selectedColor: selectedColor,
            drawingBrush: decodedDrawingBrush ?? brush,
            smudgeBrush: decodedSmudgeBrush ?? brush,
            eraserBrush: decodedEraserBrush ?? brush,
            smudgeBrushUsesIndependentSettings: decodedSmudgeUsesIndependent ?? (activeTool == .smudge),
            textureFillTip: try container.decodeIfPresent(TextureFillTipSettings.self, forKey: .textureFillTip)
                ?? .proceduralDefault,
            textureFillBrushOverride: try container.decodeIfPresent(BrushSettings.self, forKey: .textureFillBrushOverride),
            eyedropper: try container.decodeIfPresent(EyedropperSettings.self, forKey: .eyedropper)
                ?? .stageOneDefault
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(activeTool, forKey: .activeTool)
        try container.encode(brush, forKey: .brush)
        try container.encode(selectedColor, forKey: .selectedColor)
        try container.encode(drawingBrush, forKey: .drawingBrush)
        try container.encode(smudgeBrush, forKey: .smudgeBrush)
        try container.encode(eraserBrush, forKey: .eraserBrush)
        try container.encode(smudgeBrushUsesIndependentSettings, forKey: .smudgeBrushUsesIndependentSettings)
        try container.encode(textureFillTip, forKey: .textureFillTip)
        try container.encodeIfPresent(textureFillBrushOverride, forKey: .textureFillBrushOverride)
        try container.encode(eyedropper, forKey: .eyedropper)
    }

    mutating func commitSelectedColor(_ color: RGBAColor) {
        selectedColor = color
        guard brush.oilPaint.isEnabled, brush.effectivePaintJitterAmount > 0.001 else {
            oilPaintReservoir.wash(with: color)
            return
        }
    }

    @discardableResult
    mutating func loadSelectedColorIntoOilPaintReservoir() -> Bool {
        guard brush.oilPaint.isEnabled, brush.effectivePaintJitterAmount > 0.001 else {
            return false
        }
        oilPaintReservoir.load(selectedColor, amount: brush.oilPaint.newColorLoad)
        return true
    }

    mutating func washOilPaintReservoir() {
        oilPaintReservoir.wash(with: selectedColor)
    }

    var activeOilPaintPalette: BrushPigmentPalette {
        guard activeTool == .brush,
              brush.oilPaint.isEnabled,
              oilPaintOutputMode == .reservoir,
              brush.effectivePaintJitterAmount > 0.001 else {
            return .empty
        }
        return oilPaintReservoir.palette(lightnessFollow: brush.oilPaint.lightnessFollow)
    }

    static let stageOneDefault: ToolSessionState = {
        var brush = BrushSettings.stageOneDefault
        brush.size = 60
        return ToolSessionState(
            activeTool: .brush,
            brush: brush,
            selectedColor: .black,
            drawingBrush: brush,
            smudgeBrush: brush,
            eraserBrush: brush,
            smudgeBrushUsesIndependentSettings: false,
            textureFillTip: .proceduralDefault,
            eyedropper: .stageOneDefault
        )
    }()

    private var effectiveSmudgeBrush: BrushSettings {
        smudgeBrushUsesIndependentSettings ? smudgeBrush : drawingBrush
    }

    private mutating func synchronizeOnInitialization() {
        switch activeTool {
        case .smudge:
            if !smudgeBrushUsesIndependentSettings {
                smudgeBrush = drawingBrush
            }
            brush = effectiveSmudgeBrush
        case .eraser:
            brush = eraserBrush
        default:
            drawingBrush = brush
            if !smudgeBrushUsesIndependentSettings {
                smudgeBrush = drawingBrush
            }
            brush = drawingBrush
        }
    }

    private mutating func synchronizeStoredBrushesFromActiveBrush() {
        switch activeTool {
        case .smudge:
            smudgeBrush = brush
            smudgeBrushUsesIndependentSettings = true
        case .eraser:
            eraserBrush = brush
        default:
            drawingBrush = brush
            if !smudgeBrushUsesIndependentSettings {
                smudgeBrush = drawingBrush
            }
        }
    }

    private mutating func synchronizeActiveBrushForToolChange(from previousTool: ToolKind) {
        switch previousTool {
        case .smudge:
            smudgeBrush = brush
        case .eraser:
            eraserBrush = brush
        default:
            drawingBrush = brush
            if !smudgeBrushUsesIndependentSettings {
                smudgeBrush = drawingBrush
            }
        }

        if activeTool == .smudge, !smudgeBrushUsesIndependentSettings {
            smudgeBrush = drawingBrush
        }

        isSynchronizingBrushSlots = true
        switch activeTool {
        case .smudge:
            brush = effectiveSmudgeBrush
        case .eraser:
            brush = eraserBrush
        default:
            brush = drawingBrush
        }
        isSynchronizingBrushSlots = false
    }
}

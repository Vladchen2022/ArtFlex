import Foundation

extension BrushSettings {
    mutating func setCompoundBrushEnabledUsingArtistDefault(_ enabled: Bool) {
        if engineV2 != nil, enabled, compoundBrush.primary == nil {
            compoundBrush.primary = primaryTipAsCompoundSecondary
        }
        let startsNewCompoundConfiguration = enabled
            && compoundBrush.enabled == false
            && compoundBrush == .disabledDefault
        compoundBrush.enabled = enabled
        if startsNewCompoundConfiguration {
            buildMode = .buildUp
        }
        if enabled {
            materializeCompoundPrimaryTipIfNeeded()
        }
    }
}

/// Artist-facing starting points for the compound-brush mask system.
/// Recipes preserve the selected primary tip and ordinary visual parameters.
/// A brush entering compound mode for the first time starts with natural build-up;
/// a previously configured compound brush keeps its chosen build mode.
enum CompoundBrushRecipe: String, CaseIterable, Identifiable, Sendable {
    case fineGrain
    case dryBrush
    case bristleBreakup
    case brokenImpasto

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fineGrain: return "细颗粒"
        case .dryBrush: return "干刷破边"
        case .bristleBreakup: return "鬃毛分叉"
        case .brokenImpasto: return "斑驳厚涂"
        }
    }

    var detail: String {
        switch self {
        case .fineGrain: return "细密、均匀的内部纹理"
        case .dryBrush: return "明显留白和断续边缘"
        case .bristleBreakup: return "沿笔迹拉开的纤维感"
        case .brokenImpasto: return "大块、随机的厚涂斑驳"
        }
    }

    func applying(to source: BrushSettings) -> BrushSettings {
        var brush = source
        brush.setCompoundBrushEnabledUsingArtistDefault(true)
        brush.compoundBrush.secondary.sizeMode = .relativeToPrimary

        switch self {
        case .fineGrain:
            brush.compoundBrush.mode = .textureBlend
            brush.compoundBrush.setUniformTextureStrength(0.52)
            brush.compoundBrush.secondary.relativeSizeRatio = 0.42
            brush.compoundBrush.secondary.spacingPercent = 30
            brush.compoundBrush.secondary.followsStrokeDirection = true
            brush.compoundBrush.secondary.tileRandomRotation = 0.12

        case .dryBrush:
            brush.compoundBrush.mode = .subtract
            brush.compoundBrush.setUniformTextureStrength(0.78)
            brush.compoundBrush.secondary.relativeSizeRatio = 0.86
            brush.compoundBrush.secondary.spacingPercent = 24
            brush.compoundBrush.secondary.followsStrokeDirection = true
            brush.compoundBrush.secondary.tileRandomRotation = 0.2

        case .bristleBreakup:
            brush.compoundBrush.mode = .textureBlend
            brush.compoundBrush.setUniformTextureStrength(0.82)
            brush.compoundBrush.secondary.relativeSizeRatio = 0.62
            brush.compoundBrush.secondary.spacingPercent = 18
            brush.compoundBrush.secondary.followsStrokeDirection = true
            brush.compoundBrush.secondary.tileRandomRotation = 0.06

        case .brokenImpasto:
            brush.compoundBrush.mode = .subtract
            brush.compoundBrush.setUniformTextureStrength(0.64)
            brush.compoundBrush.secondary.relativeSizeRatio = 1.28
            brush.compoundBrush.secondary.spacingPercent = 44
            brush.compoundBrush.secondary.followsStrokeDirection = true
            brush.compoundBrush.secondary.tileRandomRotation = 0.55
        }

        return brush
    }
}

enum CompoundTexturePressurePreset: String, CaseIterable, Identifiable, Sendable {
    case constant
    case increases
    case decreases
    case middlePeak

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .constant: return "固定比例"
        case .increases: return "重压增强 B"
        case .decreases: return "轻压 B / 重压 A"
        case .middlePeak: return "中压增强 B"
        }
    }

    func pressureMix(preserving strength: Float) -> CompoundPressureMixSettings {
        let amount = min(max(strength, 0), 1)
        let strengths: (Float, Float, Float)
        switch self {
        case .constant:
            strengths = (amount, amount, amount)
        case .increases:
            strengths = (amount * 0.18, amount * 0.62, amount)
        case .decreases:
            strengths = (amount, amount * 0.62, amount * 0.18)
        case .middlePeak:
            strengths = (amount * 0.2, amount, amount * 0.2)
        }
        return CompoundPressureMixSettings(
            primaryAtLowPressure: 1 - strengths.0,
            primaryAtMidPressure: 1 - strengths.1,
            primaryAtHighPressure: 1 - strengths.2
        )
    }
}

enum CompoundTextureOrientation: String, CaseIterable, Identifiable, Sendable {
    case fixed
    case followsStroke
    case varied

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fixed: return "固定"
        case .followsStroke: return "跟随笔迹"
        case .varied: return "随机变化"
        }
    }
}

extension CompoundBrushSettings {
    var textureStrengthAtLowPressure: Float {
        1 - min(max(pressureMix.primaryAtLowPressure, 0), 1)
    }

    var textureStrengthAtMidPressure: Float {
        1 - min(max(pressureMix.primaryAtMidPressure, 0), 1)
    }

    var textureStrengthAtHighPressure: Float {
        1 - min(max(pressureMix.primaryAtHighPressure, 0), 1)
    }

    var displayedTextureStrength: Float {
        min(max(secondaryStrength, 0), 1)
    }

    var hasVariableTextureStrength: Bool {
        let low = textureStrengthAtLowPressure
        let mid = textureStrengthAtMidPressure
        let high = textureStrengthAtHighPressure
        return max(low, max(mid, high)) - min(low, min(mid, high)) > 0.02
    }

    mutating func setUniformTextureStrength(_ strength: Float) {
        secondaryStrength = min(max(strength, 0), 1)
    }

    mutating func applyTexturePressurePreset(_ preset: CompoundTexturePressurePreset) {
        pressureMix = preset.pressureMix(preserving: 1)
    }

    mutating func restoreLightTextureHeavyPrimaryMix() {
        pressureMix = .default
    }

    var textureOrientation: CompoundTextureOrientation {
        if secondary.tileRandomRotation > 0.05 {
            return .varied
        }
        return secondary.followsStrokeDirection ? .followsStroke : .fixed
    }

    mutating func setTextureOrientation(_ orientation: CompoundTextureOrientation) {
        switch orientation {
        case .fixed:
            secondary.followsStrokeDirection = false
            secondary.tileRandomRotation = 0
        case .followsStroke:
            secondary.followsStrokeDirection = true
            secondary.tileRandomRotation = 0
        case .varied:
            secondary.followsStrokeDirection = true
            secondary.tileRandomRotation = max(secondary.tileRandomRotation, 0.45)
        }
    }
}

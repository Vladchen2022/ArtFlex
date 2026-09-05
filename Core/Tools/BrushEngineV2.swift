import Foundation

/// Versioned paint semantics. Absence of this record always means the legacy
/// engine; opening an archive must never silently reinterpret a saved brush.
struct BrushEngineV2: Codable, Equatable, Sendable {
    enum Combination: String, Codable, CaseIterable, Identifiable {
        case pressureBlend = "压力双笔尖"
        case stampMask = "盖印遮罩"
        case overlayMask = "叠加蒙版"
        var id: String { rawValue }
    }

    var version = 2
    var flow: Float = 1
    var pressureFlow: Float = 0
    var minimumFlow: Float = 0.35
    var inputMaximum: Float = 0.75
    var combination: Combination = .pressureBlend
    var clipsToRange = false
    var primaryFlow: Float = 1
    var secondaryFlow: Float = 1
    var primaryContribution = CompoundPressureMixSettings.default
    var secondaryContribution = complementarySecondary
    var primaryVariants: [Data] = []
    var secondaryVariants: [Data] = []
    var primaryContrast: Float = 1
    var secondaryContrast: Float = 1
    /// Present only for imported reference presets; never embeds a local path.
    var referenceName: String?

    static let complementarySecondary = CompoundPressureMixSettings(
        primaryAtLowPressure: 1, primaryAtMidPressure: 0.55, primaryAtHighPressure: 0
    )

    func pressure(_ raw: Float) -> Float {
        min(max(raw / max(inputMaximum, 0.05), 0), 1)
    }

    func resolvedFlow(_ raw: Float) -> Float {
        let response = minimumFlow + (1 - minimumFlow) * pressure(raw)
        return min(max(flow * (1 - pressureFlow + pressureFlow * response), 0), 1)
    }

    func contribution(primary: Bool, pressure raw: Float) -> Float {
        let curve = primary ? primaryContribution : secondaryContribution
        return min(max(curve.resolvedPrimaryWeight(for: pressure(raw)), 0), 1)
    }

}

extension BrushSettings {
    var quickSpacingPercent: Float {
        get { engineV2 != nil && compoundBrush.enabled ? resolvedCompoundPrimaryTip.spacingPercent : spacingPercent }
        set {
            if engineV2 != nil && compoundBrush.enabled { materializeCompoundPrimaryTipIfNeeded(); compoundBrush.primary?.spacingPercent=newValue }
            else { spacingPercent=newValue }
        }
    }
    var quickSizeJitterAmount: Float {
        get { engineV2 != nil && compoundBrush.enabled ? resolvedCompoundPrimaryTip.sizeJitterAmount : sizeJitterAmount }
        set {
            if engineV2 != nil && compoundBrush.enabled { materializeCompoundPrimaryTipIfNeeded(); compoundBrush.primary?.sizeJitterAmount=newValue }
            else { sizeJitterAmount=newValue }
        }
    }
    /// An explicit draft operation. The source preset remains unchanged until
    /// the user saves a copy or deliberately updates that preset.
    mutating func rebuildWithV2() {
        materializeCompoundPrimaryTipIfNeeded()
        engineV2 = BrushEngineV2()
        buildMode = .opacityCap
        opacity = 1
        pressureOpacityAmount = 0
        pressureSensitivity = 1
        buildUpOpacityCompensationAmount = 0
        compoundBrush.globalPressureOpacityAmount = 0
        compoundBrush.secondaryStrength = 1
        compoundBrush.mode = .textureBlend
        compoundBrush.primary?.opacity = 1
        compoundBrush.primary?.pressureOpacityAmount = 0
        compoundBrush.secondary.opacity = 1
        compoundBrush.secondary.pressureOpacityAmount = 0
        if !compoundBrush.enabled { compoundBrush.primary = nil }
    }

    static var v2Default: BrushSettings {
        var brush = stageOneDefault
        brush.rebuildWithV2()
        return brush
    }

    static var v2Crayon: BrushSettings {
        var brush = v2Default
        brush.size = 60
        brush.compoundBrush.enabled = true
        var a = brush.primaryTipAsCompoundSecondary
        a.tipShape = .customRound
        a.sourceSemantic = .customMask
        a.customTipMaskData = crayonMask(seed: 43, dense: true)
        a.spacingPercent = 9
        a.angleJitterAmount = 0.12
        a.softness = 0
        var b = a
        b.customTipMaskData = crayonMask(seed: 137, dense: false)
        b.spacingPercent = 65
        b.angleJitterAmount = 1
        b.sizeJitterAmount = 0.08
        brush.compoundBrush.primary = a
        brush.compoundBrush.secondary = b
        brush.engineV2?.secondaryVariants = [271,389,521].map { crayonMask(seed: UInt32($0), dense: false) }
        return brush
    }

    private static func crayonMask(seed: UInt32, dense: Bool) -> Data {
        let side = 128
        var bytes = [UInt8](repeating: 0, count: side*side)
        func random(_ x: Int, _ y: Int) -> Float {
            var n = UInt32(x) &* 374761393 &+ UInt32(y) &* 668265263 &+ seed
            n = (n ^ (n >> 13)) &* 1274126177
            return Float(n & 65535)/65535
        }
        for y in 0..<side { for x in 0..<side {
            let nx = Float(x-64)/62, ny = Float(y-64)/62
            let r = sqrt(nx*nx+ny*ny)
            let edge = 0.96 + random(x/8,y/8)*0.04
            guard r < edge else { continue }
            let cell = random(x/3,y/3)
            let grain = random(x,y)
            let opacity: Float = dense ? (cell>0.025 ? 0.88+grain*0.12 : 0)
                : (cell>0.55 ? 0.68+grain*0.32 : 0)
            bytes[y*side+x] = UInt8(opacity*255)
        } }
        return Data(bytes)
    }
}

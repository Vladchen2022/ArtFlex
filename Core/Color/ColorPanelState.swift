import Foundation

enum ColorPanelMode: String, Codable, Sendable, Equatable {
    case picker
    case blocks
}

enum ColorPanelBaseSource: String, Codable, Sendable, Equatable {
    case synced
    case random
    case image
}

struct HSVColor: Codable, Sendable, Equatable {
    var h: Float
    var s: Float
    var v: Float

    static let black = HSVColor(h: 0, s: 0, v: 0)
}

struct ColorPanelState: Codable, Sendable, Equatable {
    var mode: ColorPanelMode
    var baseHSV: HSVColor
    var basePaletteHSV: [HSVColor]?
    var baseSource: ColorPanelBaseSource
    var baseName: String
    var contrast: Float
    var contrastHue: Float
    var snapThreeStops: Bool
    var blocksLightness: Float
    var blocksSaturation: Float
    var pickerLightness: Float
    var pickerSaturation: Float
    var pickerHue: Float
    var pickerX: Float
    var pickerY: Float
    var lightingHue: Float
    var lightingStrength: Float

    static let stageOneDefault = ColorPanelState(
        mode: .picker,
        baseHSV: .black,
        basePaletteHSV: nil,
        baseSource: .synced,
        baseName: "",
        contrast: 50,
        contrastHue: 0,
        snapThreeStops: false,
        blocksLightness: 50,
        blocksSaturation: 50,
        pickerLightness: 50,
        pickerSaturation: 100,
        pickerHue: 0,
        pickerX: 0,
        pickerY: 1,
        lightingHue: 0,
        lightingStrength: 0
    )

    enum CodingKeys: String, CodingKey {
        case mode
        case baseHSV
        case basePaletteHSV
        case baseSource
        case baseName
        case contrast
        case contrastHue
        case snapThreeStops
        case blocksLightness
        case blocksSaturation
        case pickerLightness
        case pickerSaturation
        case pickerHue
        case pickerX
        case pickerY
        case lightingHue
        case lightingStrength
    }

    init(
        mode: ColorPanelMode,
        baseHSV: HSVColor,
        basePaletteHSV: [HSVColor]?,
        baseSource: ColorPanelBaseSource,
        baseName: String,
        contrast: Float,
        contrastHue: Float,
        snapThreeStops: Bool,
        blocksLightness: Float,
        blocksSaturation: Float,
        pickerLightness: Float,
        pickerSaturation: Float,
        pickerHue: Float,
        pickerX: Float,
        pickerY: Float,
        lightingHue: Float,
        lightingStrength: Float
    ) {
        self.mode = mode
        self.baseHSV = baseHSV
        self.basePaletteHSV = basePaletteHSV
        self.baseSource = baseSource
        self.baseName = baseName
        self.contrast = contrast
        self.contrastHue = contrastHue
        self.snapThreeStops = snapThreeStops
        self.blocksLightness = blocksLightness
        self.blocksSaturation = blocksSaturation
        self.pickerLightness = pickerLightness
        self.pickerSaturation = pickerSaturation
        self.pickerHue = pickerHue
        self.pickerX = pickerX
        self.pickerY = pickerY
        self.lightingHue = lightingHue
        self.lightingStrength = lightingStrength
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(ColorPanelMode.self, forKey: .mode) ?? .picker
        baseHSV = try container.decodeIfPresent(HSVColor.self, forKey: .baseHSV) ?? .black
        basePaletteHSV = try container.decodeIfPresent([HSVColor].self, forKey: .basePaletteHSV)
        baseSource = try container.decodeIfPresent(ColorPanelBaseSource.self, forKey: .baseSource) ?? .synced
        baseName = try container.decodeIfPresent(String.self, forKey: .baseName) ?? ""
        contrast = try container.decodeIfPresent(Float.self, forKey: .contrast) ?? 50
        contrastHue = try container.decodeIfPresent(Float.self, forKey: .contrastHue) ?? 0
        snapThreeStops = try container.decodeIfPresent(Bool.self, forKey: .snapThreeStops) ?? false
        blocksLightness = try container.decodeIfPresent(Float.self, forKey: .blocksLightness) ?? 50
        blocksSaturation = try container.decodeIfPresent(Float.self, forKey: .blocksSaturation) ?? 50
        pickerLightness = try container.decodeIfPresent(Float.self, forKey: .pickerLightness) ?? 50
        pickerSaturation = try container.decodeIfPresent(Float.self, forKey: .pickerSaturation) ?? 100
        pickerHue = try container.decodeIfPresent(Float.self, forKey: .pickerHue) ?? 0
        pickerX = try container.decodeIfPresent(Float.self, forKey: .pickerX) ?? 0
        pickerY = try container.decodeIfPresent(Float.self, forKey: .pickerY) ?? 1
        lightingHue = try container.decodeIfPresent(Float.self, forKey: .lightingHue) ?? 0
        lightingStrength = try container.decodeIfPresent(Float.self, forKey: .lightingStrength) ?? 0
    }

    var activeLightness: Float {
        get { mode == .picker ? pickerLightness : blocksLightness }
        set {
            if mode == .picker {
                pickerLightness = newValue
            } else {
                blocksLightness = newValue
            }
        }
    }

    var activeSaturation: Float {
        get { mode == .picker ? pickerSaturation : blocksSaturation }
        set {
            if mode == .picker {
                pickerSaturation = newValue
            } else {
                blocksSaturation = newValue
            }
        }
    }
}

enum ColorBlocksEngine {
    static func clamp<T: Comparable>(_ value: T, _ lower: T, _ upper: T) -> T {
        min(max(value, lower), upper)
    }

    static func wrapHue(_ hue: Float) -> Float {
        var wrapped = hue.truncatingRemainder(dividingBy: 360)
        if wrapped < 0 {
            wrapped += 360
        }
        return wrapped
    }

    static func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
        a + (b - a) * t
    }

    static func rgbToHsv(_ color: RGBAColor) -> HSVColor {
        let r = color.red
        let g = color.green
        let b = color.blue
        let maxValue = max(r, max(g, b))
        let minValue = min(r, min(g, b))
        let delta = maxValue - minValue

        var hue: Float = 0
        if delta != 0 {
            if maxValue == r {
                hue = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
            } else if maxValue == g {
                hue = 60 * (((b - r) / delta) + 2)
            } else {
                hue = 60 * (((r - g) / delta) + 4)
            }
        }

        if hue < 0 {
            hue += 360
        }

        let saturation: Float = maxValue == 0 ? 0 : delta / maxValue
        return HSVColor(h: hue, s: saturation, v: maxValue)
    }

    static func hsvToRgb(_ hsv: HSVColor, alpha: Float = 1) -> RGBAColor {
        let hue = wrapHue(hsv.h)
        let saturation = clamp(hsv.s, 0, 1)
        let value = clamp(hsv.v, 0, 1)
        let c = value * saturation
        let x = c * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = value - c

        let rgb: (Float, Float, Float)
        switch hue {
        case 0..<60:
            rgb = (c, x, 0)
        case 60..<120:
            rgb = (x, c, 0)
        case 120..<180:
            rgb = (0, c, x)
        case 180..<240:
            rgb = (0, x, c)
        case 240..<300:
            rgb = (x, 0, c)
        default:
            rgb = (c, 0, x)
        }

        return RGBAColor(
            red: rgb.0 + m,
            green: rgb.1 + m,
            blue: rgb.2 + m,
            alpha: alpha
        )
    }

    static func pickerColor(from state: ColorPanelState) -> RGBAColor {
        let currentL = clamp(state.pickerLightness, 0, 100)
        let currentS = clamp(state.pickerSaturation, 0, 100)
        let maxV: Float = currentL <= 50 ? currentL / 50 : 1
        let minV: Float = currentL > 50 ? (currentL - 50) / 50 : 0
        let maxS = currentS / 100
        let saturation = clamp(state.pickerX, 0, 1) * maxS
        let vBase = 1 - clamp(state.pickerY, 0, 1)
        let value = vBase * (maxV - minV) + minV
        let color = hsvToRgb(
            HSVColor(
                h: state.pickerHue,
                s: saturation,
                v: value
            )
        )
        return applyLighting(to: color, state: state)
    }

    static func syncPicker(to color: RGBAColor, state: inout ColorPanelState) {
        let hsv = rgbToHsv(color)
        state.pickerHue = hsv.h

        let currentL = clamp(state.pickerLightness, 0, 100)
        let currentS = clamp(state.pickerSaturation, 0, 100)
        let maxV: Float = currentL <= 50 ? currentL / 50 : 1
        let minV: Float = currentL > 50 ? (currentL - 50) / 50 : 0
        let maxS = max(currentS / 100, 0.0001)
        let sBase = hsv.s / maxS
        let vBase = (hsv.v - minV) / max(maxV - minV, 0.0001)

        state.pickerX = clamp(sBase, 0, 1)
        state.pickerY = clamp(1 - vBase, 0, 1)
    }

    static func snapValue(_ value: Float, enabled: Bool) -> Float {
        guard enabled else { return value }
        for snap in [25 as Float, 50, 75] where abs(value - snap) <= 3 {
            return snap
        }
        return value
    }

    static func satBand(baseSaturation: Float, saturationPercent: Float) -> ClosedRange<Float> {
        let normalizedSlider = clamp(saturationPercent / 100, 0, 1)
        let scale = normalizedSlider * 2
        let center = clamp(baseSaturation * scale, 0, 1)
        let halfWidth: Float = 0.10
        let minimumWidth: Float = 0.06
        var lower = clamp(center - halfWidth, 0, 1)
        var upper = clamp(center + halfWidth, 0, 1)
        if upper - lower < minimumWidth {
            let mid = (lower + upper) / 2
            lower = clamp(mid - minimumWidth / 2, 0, 1)
            upper = clamp(mid + minimumWidth / 2, 0, 1)
        }
        return lower...upper
    }

    static func defaultBasePalette(baseHSV: HSVColor, total: Int = 25) -> [HSVColor] {
        let lightnessPercent: Float = 50
        let saturationPercent: Float = 50
        let contrastPercent: Float = 50
        let lightnessN = clamp(lightnessPercent / 100, 0, 1)
        let contrastN = clamp(contrastPercent / 100, 0, 1)
        let saturationBand = satBand(baseSaturation: baseHSV.s, saturationPercent: saturationPercent)
        let valueCenter = lerp(0.30, 0.90, lightnessN)
        let valueMin = clamp(valueCenter - 0.18, 0.08, 0.92)
        let valueMax = clamp(valueCenter + 0.18, 0.18, 1.0)
        let hueJitter = lerp(10, 35, contrastN)
        let valueJitter = lerp(0.01, 0.05, contrastN)

        return (0..<total).map { index in
            let row = Float(index / 5)
            let rowValue = lerp(valueMax, valueMin, row / 4)
            return HSVColor(
                h: wrapHue(baseHSV.h + randomFloat(in: -hueJitter...hueJitter)),
                s: randomFloat(in: saturationBand),
                v: clamp(rowValue + randomFloat(in: -valueJitter...valueJitter), 0.06, 0.98)
            )
        }
    }

    static func makeRandomBasePalette(baseHSV: HSVColor, state: ColorPanelState, total: Int = 25) -> [HSVColor] {
        let contrastN = clamp(state.contrast / 100, 0, 1)
        let lightnessN = clamp(state.blocksLightness / 100, 0, 1)
        let saturationBand = satBand(baseSaturation: baseHSV.s, saturationPercent: state.blocksSaturation)
        let valueCenter = lerp(0.30, 0.90, lightnessN)
        let valueMin = clamp(valueCenter - 0.18, 0.08, 0.92)
        let valueMax = clamp(valueCenter + 0.18, 0.18, 1.0)
        let hueJitter = lerp(10, 35, contrastN)
        let valueJitter = lerp(0.01, 0.05, contrastN)

        return (0..<total).map { index in
            let row = Float(index / 5)
            let rowValue = lerp(valueMax, valueMin, row / 4)
            return HSVColor(
                h: wrapHue(baseHSV.h + randomFloat(in: -hueJitter...hueJitter)),
                s: randomFloat(in: saturationBand),
                v: clamp(rowValue + randomFloat(in: -valueJitter...valueJitter), 0.06, 0.98)
            )
        }
    }

    static func renderPalette(for state: ColorPanelState) -> [RGBAColor] {
        let basePalette = state.basePaletteHSV ?? defaultBasePalette(baseHSV: state.baseHSV)
        let lightnessN = clamp(state.blocksLightness / 100, 0, 1)
        let contrastN = clamp(state.contrast / 100, 0, 1)
        let xN = clamp(state.contrastHue / 100, 0, 1)
        let saturationBand = satBand(baseSaturation: state.baseHSV.s, saturationPercent: state.blocksSaturation)
        let targetValue = lerp(0.30, 0.90, lightnessN)
        let contrastFactor = lerp(0.35, 1.75, contrastN)
        let meanValue = basePalette.map(\.v).reduce(0, +) / Float(max(basePalette.count, 1))
        let baseHue = state.baseHSV.h

        return basePalette.enumerated().map { index, color in
            var hsv = color
            hsv.v = clamp(targetValue + (color.v - meanValue) * contrastFactor, 0.06, 0.98)
            hsv.s = clamp(color.s, saturationBand.lowerBound, saturationBand.upperBound)

            if xN > 0 {
                let seed = Float(index) * 37.17 + baseHue * 0.013
                let useContrast = pseudoRandom(seed) < xN * 0.55
                if useContrast {
                    let offset = (pseudoRandom(seed * 1.91) - 0.5) * 50 * xN
                    let targetHue = wrapHue(baseHue + 180 + offset)
                    hsv.h = blendHue(from: hsv.h, to: targetHue, amount: 0.25 + xN * 0.55)
                }
            }

            return applyLighting(to: hsvToRgb(hsv), state: state)
        }
    }

    static func applyLighting(to color: RGBAColor, state: ColorPanelState) -> RGBAColor {
        let amount = clamp(state.lightingStrength / 100, 0, 1)
        guard amount > 0.0001 else { return color }

        let baseHSV = rgbToHsv(color)
        let lightColor = hsvToRgb(HSVColor(h: wrapHue(state.lightingHue), s: 1, v: 1))

        let screenRed: Float = 1 - ((1 - color.red) * (1 - lightColor.red))
        let screenGreen: Float = 1 - ((1 - color.green) * (1 - lightColor.green))
        let screenBlue: Float = 1 - ((1 - color.blue) * (1 - lightColor.blue))

        let baseLuminance = (0.2126 * color.red) + (0.7152 * color.green) + (0.0722 * color.blue)
        let luminanceWeight = lerp(0.10, 0.92, baseLuminance)
        let chromaWeight = lerp(0.16, 0.68, baseHSV.s)
        let blend = amount * (luminanceWeight * 0.72 + chromaWeight * 0.28)

        let screenMixed = RGBAColor(
            red: lerp(color.red, screenRed, blend),
            green: lerp(color.green, screenGreen, blend),
            blue: lerp(color.blue, screenBlue, blend),
            alpha: color.alpha
        )

        var litHSV = rgbToHsv(screenMixed)
        let hueShift = amount * lerp(0.10, 0.42, max(baseHSV.s, 0.15))
        let saturationBoost = amount * lerp(0.06, 0.22, 1 - min(baseHSV.s, 1))
        let valueBoost = amount * lerp(0.01, 0.10, baseHSV.v)
        litHSV.h = blendHue(from: litHSV.h, to: state.lightingHue, amount: hueShift)
        litHSV.s = clamp(litHSV.s + saturationBoost, 0, 1)
        litHSV.v = clamp(litHSV.v + valueBoost * 0.45, 0, 1)
        return hsvToRgb(litHSV, alpha: color.alpha)
    }

    static func orderPaletteForGrid(_ colors: [RGBAColor]) -> [RGBAColor] {
        let mapped = colors.map { color in
            let hsv = rgbToHsv(color)
            return (color: color, hue: hsv.h, value: hsv.v)
        }
        let sortedByValue = mapped.sorted { $0.value > $1.value }
        var output: [RGBAColor] = []

        for rowIndex in 0..<5 {
            let start = rowIndex * 5
            let end = min(start + 5, sortedByValue.count)
            let row = sortedByValue[start..<end].sorted { $0.hue < $1.hue }
            output.append(contentsOf: row.map(\.color))
        }

        return output
    }

    static func paletteFromImageColors(_ colors: [RGBAColor]) -> [HSVColor] {
        let ordered = orderPaletteForGrid(colors)
        return ordered.map(rgbToHsv)
    }

    private static func blendHue(from a: Float, to b: Float, amount: Float) -> Float {
        let delta = shortestHueDelta(from: a, to: b)
        return wrapHue(a + delta * clamp(amount, 0, 1))
    }

    private static func shortestHueDelta(from a: Float, to b: Float) -> Float {
        var delta = wrapHue(b) - wrapHue(a)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }

    private static func pseudoRandom(_ seed: Float) -> Float {
        let value = sin(seed * 12.9898) * 43758.5453
        return value - floor(value)
    }

    private static func randomFloat(in range: ClosedRange<Float>) -> Float {
        Float.random(in: range)
    }
}

import Foundation
import Testing
@testable import ArtFlex

struct DualTipBrushSettingsTests {
    @Test
    func legacySecondaryTipDescriptorDecodeFallsBackToSafeDefaults() throws {
        let legacyJSON = """
        {
          "tipShape": "softRound"
        }
        """

        let decoded = try JSONDecoder().decode(
            SecondaryTipDescriptor.self,
            from: Data(legacyJSON.utf8)
        )

        #expect(decoded.tipShape == .softRound)
        #expect(decoded.customTipMaskData == nil)
        #expect(decoded.customTipSoftness == 0.5)
        #expect(decoded.customTipRoundness == 1)
        #expect(decoded.customTipAngleDegrees == 0)
    }

    @Test
    func legacyBrushSettingsDecodeFallsBackToPhaseZeroDualTipDefaults() throws {
        let legacyJSON = """
        {
          "size": 36,
          "opacity": 0.72,
          "buildMode": "buildUp",
          "tipShape": "softRound"
        }
        """

        let decoded = try JSONDecoder().decode(
            BrushSettings.self,
            from: Data(legacyJSON.utf8)
        )

        #expect(decoded.dualTipEnabled == false)
        #expect(decoded.secondaryTipDescriptor.tipShape == .hardRound)
        #expect(decoded.dualTipCombineMode == .multiply)
        #expect(decoded.dualTipStrength == 1)
        #expect(decoded.secondarySizeRatio == 1)
        #expect(decoded.secondaryAngleOffsetDegrees == 0)
        #expect(decoded.secondaryScatter == 0)
        #expect(decoded.secondaryInvert == false)
        #expect(decoded.size == 36)
        #expect(decoded.opacity == 0.72)
        #expect(decoded.tipShape == .softRound)
    }

    @Test
    func brushPresetRoundTripPreservesDualTipPhaseZeroFields() throws {
        var brush = BrushSettings.stageOneDefault
        brush.dualTipEnabled = true
        brush.secondaryTipDescriptor = SecondaryTipDescriptor(
            tipShape: .customRound,
            customTipMaskData: Data([0, 64, 255, 128]),
            customTipSoftness: 0.36,
            customTipRoundness: 0.71,
            customTipAngleDegrees: 41
        )
        brush.dualTipCombineMode = .subtract
        brush.dualTipStrength = 0.42
        brush.secondarySizeRatio = 1.8
        brush.secondaryAngleOffsetDegrees = -35
        brush.secondaryScatter = 1.25
        brush.secondaryInvert = true

        let preset = BrushPreset(
            id: "dual-tip-phase-zero",
            name: "Dual Tip Phase 0",
            brush: brush,
            isBuiltIn: false,
            slotIndex: 3
        )

        let encoded = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(BrushPreset.self, from: encoded)

        #expect(decoded == preset)
    }

    @Test
    func legacyBrushPresetDecodeFallsBackToPhaseZeroDualTipDefaults() throws {
        let legacyPresetJSON = """
        {
          "id": "legacy",
          "name": "Legacy Brush",
          "brush": {
            "size": 24,
            "opacity": 1,
            "buildMode": "buildUp",
            "tipShape": "hardRound"
          },
          "isBuiltIn": false
        }
        """

        let decoded = try JSONDecoder().decode(
            BrushPreset.self,
            from: Data(legacyPresetJSON.utf8)
        )

        #expect(decoded.brush.dualTipEnabled == false)
        #expect(decoded.brush.secondaryTipDescriptor.tipShape == .hardRound)
        #expect(decoded.brush.dualTipCombineMode == .multiply)
        #expect(decoded.brush.secondaryInvert == false)
    }

    @Test
    func phaseOneRealDrawingSupportGateStaysNarrow() {
        var supported = BrushSettings.stageOneDefault
        supported.dualTipEnabled = true
        supported.tipShape = .hardRound
        supported.secondaryTipDescriptor = SecondaryTipDescriptor(tipShape: .softRound)
        supported.dualTipCombineMode = .multiply

        #expect(supported.supportsPhaseOneDualTipRealDrawing(for: .brush))
        #expect(supported.supportsPhaseOneDualTipRealDrawing(for: .eraser))

        var disabled = supported
        disabled.dualTipEnabled = false
        #expect(disabled.supportsPhaseOneDualTipRealDrawing(for: .brush) == false)

        var wrongMode = supported
        wrongMode.dualTipCombineMode = .subtract
        #expect(wrongMode.supportsPhaseOneDualTipRealDrawing(for: .brush) == false)

        var wrongPrimaryShape = supported
        wrongPrimaryShape.tipShape = .square
        #expect(wrongPrimaryShape.supportsPhaseOneDualTipRealDrawing(for: .brush) == false)

        var wrongSecondaryShape = supported
        wrongSecondaryShape.secondaryTipDescriptor = SecondaryTipDescriptor(tipShape: .square)
        #expect(wrongSecondaryShape.supportsPhaseOneDualTipRealDrawing(for: .brush) == false)

        var customSecondary = supported
        customSecondary.secondaryTipDescriptor = SecondaryTipDescriptor(
            tipShape: .customRound,
            customTipMaskData: Data([255, 0, 255]),
            customTipSoftness: 0.4,
            customTipRoundness: 0.7,
            customTipAngleDegrees: 23
        )
        #expect(customSecondary.supportsPhaseOneDualTipRealDrawing(for: .brush))

        var customPrimary = supported
        customPrimary.tipShape = .customRound
        customPrimary.customTipMaskData = Data([255, 128, 64])
        #expect(customPrimary.supportsPhaseOneDualTipRealDrawing(for: .brush) == false)

        #expect(supported.supportsPhaseOneDualTipRealDrawing(for: .smudge) == false)
    }

    @Test
    func phaseTwoSubtractRealDrawingSupportGateStaysNarrow() {
        var supported = BrushSettings.stageOneDefault
        supported.dualTipEnabled = true
        supported.tipShape = .softRound
        supported.secondaryTipDescriptor = SecondaryTipDescriptor(tipShape: .hardRound)
        supported.dualTipCombineMode = .subtract

        #expect(supported.supportsPhaseTwoDualTipSubtractRealDrawing(for: .brush))
        #expect(supported.supportsPhaseTwoDualTipSubtractRealDrawing(for: .eraser))

        var disabled = supported
        disabled.dualTipEnabled = false
        #expect(disabled.supportsPhaseTwoDualTipSubtractRealDrawing(for: .brush) == false)

        var wrongModeMultiply = supported
        wrongModeMultiply.dualTipCombineMode = .multiply
        #expect(wrongModeMultiply.supportsPhaseTwoDualTipSubtractRealDrawing(for: .brush) == false)

        var wrongModeIntersect = supported
        wrongModeIntersect.dualTipCombineMode = .intersect
        #expect(wrongModeIntersect.supportsPhaseTwoDualTipSubtractRealDrawing(for: .brush) == false)

        var wrongPrimaryShape = supported
        wrongPrimaryShape.tipShape = .square
        #expect(wrongPrimaryShape.supportsPhaseTwoDualTipSubtractRealDrawing(for: .brush) == false)

        var wrongSecondaryShape = supported
        wrongSecondaryShape.secondaryTipDescriptor = SecondaryTipDescriptor(tipShape: .square)
        #expect(wrongSecondaryShape.supportsPhaseTwoDualTipSubtractRealDrawing(for: .brush) == false)

        var customSecondary = supported
        customSecondary.secondaryTipDescriptor = SecondaryTipDescriptor(
            tipShape: .customRound,
            customTipMaskData: Data([255, 128, 32]),
            customTipSoftness: 0.55,
            customTipRoundness: 0.62,
            customTipAngleDegrees: 17
        )
        #expect(customSecondary.supportsPhaseTwoDualTipSubtractRealDrawing(for: .brush))

        var customPrimary = supported
        customPrimary.tipShape = .customRound
        customPrimary.customTipMaskData = Data([255, 32, 16])
        #expect(customPrimary.supportsPhaseTwoDualTipSubtractRealDrawing(for: .brush) == false)

        #expect(supported.supportsPhaseTwoDualTipSubtractRealDrawing(for: .smudge) == false)
    }

    @Test
    func multiplyAndIntersectRemainSeparatedAfterSubtractFollowUp() {
        var multiplyBrush = BrushSettings.stageOneDefault
        multiplyBrush.dualTipEnabled = true
        multiplyBrush.tipShape = .hardRound
        multiplyBrush.secondaryTipDescriptor = SecondaryTipDescriptor(tipShape: .softRound)
        multiplyBrush.dualTipCombineMode = .multiply

        #expect(multiplyBrush.supportsPhaseOneDualTipRealDrawing(for: .brush))
        #expect(multiplyBrush.supportsPhaseTwoDualTipSubtractRealDrawing(for: .brush) == false)

        var intersectBrush = multiplyBrush
        intersectBrush.dualTipCombineMode = .intersect

        #expect(intersectBrush.supportsPhaseOneDualTipRealDrawing(for: .brush) == false)
        #expect(intersectBrush.supportsPhaseTwoDualTipSubtractRealDrawing(for: .brush) == false)
    }

    @Test
    func builtInDualTipPhaseOneDemoPresetsStayWithinCurrentSupportedRange() {
        let presets = BrushPreset.builtInDualTipPhaseOneDemoPresets

        #expect(presets.count == 3)
        #expect(Set(presets.map(\.id)).count == presets.count)
        #expect(presets.allSatisfy { $0.isBuiltIn })
        #expect(presets.map(\.name) == [
            "Dual Tip · 收口型",
            "Dual Tip · 柔边压缩",
            "Dual Tip · 强调制"
        ])
        #expect(presets.map(\.slotIndex) == [4, 5, 6])

        for preset in presets {
            #expect(preset.brush.dualTipEnabled)
            #expect(preset.brush.dualTipCombineMode == .multiply)
            #expect(preset.brush.tipShape.isPhaseOneDualTipSupportedRound)
            #expect(preset.brush.secondaryTipDescriptor.supportsPhaseOneDualTipRealDrawing)
            #expect(preset.brush.supportsPhaseOneDualTipRealDrawing(for: .brush))
            #expect(preset.brush.supportsPhaseTwoDualTipSubtractRealDrawing(for: .brush) == false)
            #expect(preset.brush.secondarySizeRatio >= 0.25)
            #expect(preset.brush.secondarySizeRatio <= 0.95)
        }
    }

    @Test
    func ensuringBuiltInDualTipPhaseOneDemoPresetsRehydratesExamplesWithoutLosingCustomPresets() {
        var customBrush = BrushSettings.stageOneDefault
        customBrush.tipShape = .customRound
        let customPreset = BrushPreset(
            id: "custom-phase-one-check",
            name: "Custom Phase 1 Check",
            brush: customBrush,
            isBuiltIn: false,
            slotIndex: 6
        )

        let restoredLikeLibrary = BrushLibraryState(
            presets: [
                BrushPreset(
                    id: "builtin-dual-tip-tighten",
                    name: "Old Builtin Copy",
                    brush: .stageOneDefault,
                    isBuiltIn: false,
                    slotIndex: 99
                ),
                customPreset
            ],
            selectedPresetID: customPreset.id
        )

        let merged = restoredLikeLibrary.ensuringBuiltInDualTipPhaseOneDemoPresets()

        #expect(merged.presets.count == 4)
        #expect(merged.selectedPresetID == customPreset.id)
        #expect(merged.presets.contains(where: { $0.id == customPreset.id }))
        #expect(merged.presets.filter { BrushPreset.builtInDualTipPhaseOneDemoPresetIDs.contains($0.id) }.count == 3)
        #expect(merged.presets.first(where: { $0.id == "builtin-dual-tip-tighten" })?.isBuiltIn == true)
        #expect(merged.presets.first(where: { $0.id == "builtin-dual-tip-tighten" })?.name == "Dual Tip · 收口型")
    }

    @Test
    func dualTipPhaseOneDemoHighlightOnlyAppliesToBuiltInExamples() {
        let builtInPresets = BrushPreset.builtInDualTipPhaseOneDemoPresets

        #expect(builtInPresets.allSatisfy { $0.isDualTipPhaseOneDemoPreset })

        let customPreset = BrushPreset(
            id: "custom-test-preset",
            name: "Custom Test",
            brush: .stageOneDefault,
            isBuiltIn: false,
            slotIndex: 9
        )

        #expect(customPreset.isDualTipPhaseOneDemoPreset == false)
    }
}

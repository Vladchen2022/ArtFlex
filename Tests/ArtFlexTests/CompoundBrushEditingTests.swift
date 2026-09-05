import Testing
import CoreGraphics
import Foundation
@testable import ArtFlex

struct CompoundBrushEditingTests {
    @Test
    func tipLibrarySheetUsesIdealSizeButNeverExceedsEditorViewport() {
        let roomy = CompoundBrushTipLibraryLayout.size(
            fitting: CGSize(width: 1040, height: 760)
        )
        #expect(roomy == CGSize(width: 820, height: 600))

        let narrow = CompoundBrushTipLibraryLayout.size(
            fitting: CGSize(width: 760, height: 660)
        )
        #expect(narrow == CGSize(width: 728, height: 600))

        let short = CompoundBrushTipLibraryLayout.size(
            fitting: CGSize(width: 760, height: 520)
        )
        #expect(short == CGSize(width: 728, height: 488))
    }

    @Test
    func firstCompoundEnableUsesNaturalBuildUpButReenablePreservesConfiguredMode() {
        var newBrush = BrushSettings.stageOneDefault
        newBrush.buildMode = .opacityCap
        newBrush.setCompoundBrushEnabledUsingArtistDefault(true)

        #expect(newBrush.compoundBrush.enabled)
        #expect(newBrush.buildMode == .buildUp)

        var configuredBrush = BrushSettings.stageOneDefault
        configuredBrush.compoundBrush.secondary.relativeSizeRatio = 1.7
        configuredBrush.buildMode = .opacityCap
        configuredBrush.setCompoundBrushEnabledUsingArtistDefault(true)

        #expect(configuredBrush.compoundBrush.enabled)
        #expect(configuredBrush.buildMode == .opacityCap)
    }

    @Test
    func enablingCompoundBrushPreservesRangeAndMaterializesIndependentPrimaryTip() throws {
        var brush = BrushSettings.stageOneDefault
        brush.tipShape = .square
        brush.spacingPercent = 7
        brush.scatterAmount = 0.35
        brush.setCompoundBrushEnabledUsingArtistDefault(true)

        let primary = try #require(brush.compoundBrush.primary)
        #expect(brush.tipShape == .square)
        #expect(brush.spacingPercent == 7)
        #expect(primary.tipShape == .square)
        #expect(primary.spacingPercent == 7)
        #expect(primary.scatterAmount == 0.35)

        brush.compoundBrush.primary?.spacingPercent = 31
        brush.compoundBrush.primary?.opacity = 0.72
        brush.compoundBrush.primary?.sizeJitterAmount = 0.44
        let data = try JSONEncoder().encode(brush)
        let decoded = try JSONDecoder().decode(BrushSettings.self, from: data)

        #expect(decoded.spacingPercent == 7)
        #expect(decoded.compoundBrush.primary?.spacingPercent == 31)
        #expect(decoded.compoundBrush.primary?.opacity == 0.72)
        #expect(decoded.compoundBrush.primary?.sizeJitterAmount == 0.44)
    }

    @Test
    func drawingPadConvertsAppKitYAxisToTopDownRasterCoordinates() {
        let bounds = CGRect(x: 10, y: 20, width: 200, height: 100)

        let nearTop = CompoundBrushDrawingPadCoordinateMapper.rasterPoint(
            forAppKitPoint: CGPoint(x: 60, y: 110),
            in: bounds,
            resolution: 101
        )
        let nearBottom = CompoundBrushDrawingPadCoordinateMapper.rasterPoint(
            forAppKitPoint: CGPoint(x: 160, y: 30),
            in: bounds,
            resolution: 101
        )

        #expect(abs(nearTop.x - 25) < 0.001)
        #expect(abs(nearTop.y - 10) < 0.001)
        #expect(abs(nearBottom.x - 75) < 0.001)
        #expect(abs(nearBottom.y - 90) < 0.001)
        #expect(nearTop.y < nearBottom.y)
    }

    @Test
    func pressureMixCurveUsesWholePlotCoordinatesAndSelectsNearestPoint() {
        let plot = CGRect(x: 20, y: 20, width: 300, height: 100)

        #expect(CompoundPressureMixCurveInteraction.nearestControlPoint(toX: 24, in: plot) == 0)
        #expect(CompoundPressureMixCurveInteraction.nearestControlPoint(toX: 176, in: plot) == 1)
        #expect(CompoundPressureMixCurveInteraction.nearestControlPoint(toX: 318, in: plot) == 2)
        #expect(abs(CompoundPressureMixCurveInteraction.secondaryStrength(atY: 20, in: plot) - 1) < 0.0001)
        #expect(abs(CompoundPressureMixCurveInteraction.secondaryStrength(atY: 70, in: plot) - 0.5) < 0.0001)
        #expect(abs(CompoundPressureMixCurveInteraction.secondaryStrength(atY: 120, in: plot)) < 0.0001)
    }

    @Test
    func primaryAndSecondaryTipsCanBeCopiedAndSwapped() {
        var brush = BrushSettings.stageOneDefault
        brush.compoundBrush.enabled = true
        brush.tipShape = .square
        brush.size = 64
        brush.spacingPercent = 23
        brush.pressureSizeAmount = 0.72
        brush.materializeCompoundPrimaryTipIfNeeded()
        brush.compoundBrush.primary?.tipShape = .customRound
        brush.compoundBrush.primary?.spacingPercent = 41
        brush.compoundBrush.secondary.tipShape = .softRound
        brush.compoundBrush.secondary.sizeMode = .absolutePixels
        brush.compoundBrush.secondary.size = 19
        brush.compoundBrush.secondary.spacingPercent = 88
        brush.compoundBrush.secondary.pressureSizeAmount = 0.18

        let originalRangeShape = brush.tipShape
        let originalRangeSpacing = brush.spacingPercent
        let originalPrimary = brush.resolvedCompoundPrimaryTip
        let originalSecondary = brush.compoundBrush.secondary
        brush.swapCompoundPrimaryAndSecondaryTips()

        #expect(brush.tipShape == originalRangeShape)
        #expect(brush.spacingPercent == originalRangeSpacing)
        #expect(brush.resolvedCompoundPrimaryTip.tipShape == originalSecondary.tipShape)
        #expect(brush.resolvedCompoundPrimaryTip.spacingPercent == originalSecondary.spacingPercent)
        #expect(brush.compoundBrush.secondary.tipShape == originalPrimary.tipShape)
        #expect(brush.compoundBrush.secondary.spacingPercent == originalPrimary.spacingPercent)

        brush.copyPrimaryTipToCompoundSecondary()
        #expect(brush.compoundBrush.secondary.tipShape == brush.resolvedCompoundPrimaryTip.tipShape)
        #expect(brush.compoundBrush.secondary.spacingPercent == brush.resolvedCompoundPrimaryTip.spacingPercent)
    }

    @Test
    func diagnosticsFlagSparseSecondaryAndDenseScatteredBrushes() {
        var brush = BrushSettings.stageOneDefault
        brush.compoundBrush.enabled = true
        brush.spacingPercent = 5
        brush.scatterAmount = 1
        brush.compoundBrush.secondary.spacingPercent = 160
        brush.compoundBrush.secondary.relativeSizeRatio = 0.1

        let ids = Set(CompoundBrushDiagnostics.evaluate(brush).map(\.id))
        #expect(ids.contains("secondary-spacing-gaps"))
        #expect(ids.contains("secondary-too-small"))
    }

    @Test
    func textureStrengthDoesNotFlattenPressureMix() {
        var settings = CompoundBrushSettings.disabledDefault
        let originalMix = settings.pressureMix
        settings.setUniformTextureStrength(0.72)

        #expect(settings.pressureMix == originalMix)
        #expect(abs(settings.secondaryStrength - 0.72) < 0.0001)
        #expect(abs(settings.displayedTextureStrength - 0.72) < 0.0001)
        #expect(settings.hasVariableTextureStrength)
    }

    @Test
    func legacyUniformTextureStrengthMigratesToIndependentStrengthAndPressureCrossover() throws {
        var current = CompoundBrushSettings.disabledDefault
        current.pressureMix = .secondaryOnly
        let encoded = try JSONEncoder().encode(current)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "secondaryStrength")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let migrated = try JSONDecoder().decode(CompoundBrushSettings.self, from: legacyData)

        #expect(migrated.pressureMix == .default)
        #expect(migrated.secondaryStrength == 1)
        #expect(migrated.pressureMix.resolvedPrimaryWeight(for: 0) == 0)
        #expect(migrated.pressureMix.resolvedPrimaryWeight(for: 1) == 1)
    }

    @Test
    func pressurePresetsProduceExpectedTextureDirection() {
        let increasing = CompoundTexturePressurePreset.increases.pressureMix(preserving: 0.8)
        let increasingLow = 1 - increasing.primaryAtLowPressure
        let increasingHigh = 1 - increasing.primaryAtHighPressure
        #expect(increasingLow < increasingHigh)

        let decreasing = CompoundTexturePressurePreset.decreases.pressureMix(preserving: 0.8)
        let decreasingLow = 1 - decreasing.primaryAtLowPressure
        let decreasingHigh = 1 - decreasing.primaryAtHighPressure
        #expect(decreasingLow > decreasingHigh)

        let middle = CompoundTexturePressurePreset.middlePeak.pressureMix(preserving: 0.8)
        let middleStrength = 1 - middle.primaryAtMidPressure
        #expect(middleStrength > 1 - middle.primaryAtLowPressure)
        #expect(middleStrength > 1 - middle.primaryAtHighPressure)
    }

    @Test
    func quickRecipesPreserveOrdinaryBrushIdentity() {
        var source = BrushSettings.stageOneDefault
        source.tipShape = .square
        source.size = 137
        source.opacity = 0.43
        source.spacingPercent = 17
        source.paintJitterAmount = 0.38

        for recipe in CompoundBrushRecipe.allCases {
            let result = recipe.applying(to: source)
            #expect(result.compoundBrush.enabled)
            #expect(result.compoundBrush.secondary.sizeMode == .relativeToPrimary)
            #expect(result.tipShape == source.tipShape)
            #expect(result.size == source.size)
            #expect(result.opacity == source.opacity)
            #expect(result.spacingPercent == source.spacingPercent)
            #expect(result.paintJitterAmount == source.paintJitterAmount)
        }
    }

    @Test
    func textureOrientationRoundTripsThroughExistingRenderFields() {
        var settings = CompoundBrushSettings.disabledDefault

        settings.setTextureOrientation(.fixed)
        #expect(settings.textureOrientation == .fixed)
        #expect(settings.secondary.followsStrokeDirection == false)
        #expect(settings.secondary.tileRandomRotation == 0)

        settings.setTextureOrientation(.followsStroke)
        #expect(settings.textureOrientation == .followsStroke)
        #expect(settings.secondary.followsStrokeDirection)
        #expect(settings.secondary.tileRandomRotation == 0)

        settings.setTextureOrientation(.varied)
        #expect(settings.textureOrientation == .varied)
        #expect(settings.secondary.followsStrokeDirection)
        #expect(settings.secondary.tileRandomRotation >= 0.45)
    }
}

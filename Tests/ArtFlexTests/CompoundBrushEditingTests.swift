import Testing
import CoreGraphics
@testable import ArtFlex

struct CompoundBrushEditingTests {
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
    func primaryAndSecondaryTipsCanBeCopiedAndSwapped() {
        var brush = BrushSettings.stageOneDefault
        brush.tipShape = .square
        brush.size = 64
        brush.spacingPercent = 23
        brush.pressureSizeAmount = 0.72
        brush.compoundBrush.secondary.tipShape = .softRound
        brush.compoundBrush.secondary.sizeMode = .absolutePixels
        brush.compoundBrush.secondary.size = 19
        brush.compoundBrush.secondary.spacingPercent = 88
        brush.compoundBrush.secondary.pressureSizeAmount = 0.18

        let originalPrimary = brush.primaryTipAsCompoundSecondary
        let originalSecondary = brush.compoundBrush.secondary
        brush.swapCompoundPrimaryAndSecondaryTips()

        #expect(brush.tipShape == originalSecondary.tipShape)
        #expect(brush.size == originalSecondary.size)
        #expect(brush.spacingPercent == originalSecondary.spacingPercent)
        #expect(brush.compoundBrush.secondary.tipShape == originalPrimary.tipShape)
        #expect(brush.compoundBrush.secondary.spacingPercent == originalPrimary.spacingPercent)
        #expect(brush.compoundBrush.secondary.resolvedBaseSize(for: brush.size) == 64)

        brush.copyPrimaryTipToCompoundSecondary()
        #expect(brush.compoundBrush.secondary.tipShape == brush.tipShape)
        #expect(brush.compoundBrush.secondary.spacingPercent == brush.spacingPercent)
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
    func textureStrengthUsesArtistFacingInverseOfPrimaryWeight() {
        var settings = CompoundBrushSettings.disabledDefault
        settings.setUniformTextureStrength(0.72)

        #expect(abs(settings.pressureMix.primaryAtLowPressure - 0.28) < 0.0001)
        #expect(abs(settings.pressureMix.primaryAtMidPressure - 0.28) < 0.0001)
        #expect(abs(settings.pressureMix.primaryAtHighPressure - 0.28) < 0.0001)
        #expect(abs(settings.displayedTextureStrength - 0.72) < 0.0001)
        #expect(settings.hasVariableTextureStrength == false)
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

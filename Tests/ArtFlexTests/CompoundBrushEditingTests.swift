import Testing
@testable import ArtFlex

struct CompoundBrushEditingTests {
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
}

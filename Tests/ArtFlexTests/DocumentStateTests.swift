import Testing
@testable import ArtFlex

struct DocumentStateTests {
    @Test
    func stageOneDocumentStartsWithSingleLayerAndDefaultCanvas() {
        let document = ArtDocument.stageOneDefault()

        #expect(document.canvasSize == .stageOneDefault)
        #expect(document.layers.count == 1)
        #expect(document.layers.first?.name == LayerRecord.defaultBackgroundLayerName)
        #expect(document.layers.first?.isLocked == false)
        #expect(document.activeLayerID == document.layers.first?.id)
        #expect(document.colorStandard == .stageOneDefault)
    }

    @Test
    func workspaceStateIncludesDocumentToolSessionAndViewport() {
        let workspace = WorkspaceState.stageOneDefault

        #expect(workspace.document.layers.count == 1)
        #expect(workspace.toolSession.activeTool == .brush)
        #expect(workspace.viewport == .stageOneDefault)
    }

    @Test
    func toolKindSupportsSmudgeWithoutChangingDefaultTool() {
        let workspace = WorkspaceState.stageOneDefault

        #expect(ToolKind(rawValue: "smudge") == .smudge)
        #expect(workspace.toolSession.activeTool == .brush)
    }

    @Test
    func workspaceStartsWithDualTipPhaseOneDemoBrushLibrary() {
        let workspace = WorkspaceState.stageOneDefault

        #expect(workspace.brushLibrary.presets.count == 3)
        #expect(workspace.brushLibrary.selectedPresetID == nil)
        #expect(workspace.brushLibrary.presets.map(\.name) == [
            "Dual Tip · 收口型",
            "Dual Tip · 柔边压缩",
            "Dual Tip · 强调制"
        ])
        #expect(workspace.brushLibrary.presets.allSatisfy { $0.isBuiltIn })
        #expect(workspace.toolSession.brush.tipShape == .hardRound)
        #expect(workspace.toolSession.brush.dualTipEnabled == false)
        #expect(workspace.toolSession.brush.secondaryTipDescriptor.tipShape == .hardRound)
        #expect(workspace.toolSession.brush.secondaryTipDescriptor.customTipMaskData == nil)
        #expect(workspace.toolSession.brush.secondaryTipDescriptor.customTipSoftness == 0.5)
        #expect(workspace.toolSession.brush.secondaryTipDescriptor.customTipRoundness == 1)
        #expect(workspace.toolSession.brush.secondaryTipDescriptor.customTipAngleDegrees == 0)
        #expect(workspace.toolSession.brush.dualTipCombineMode == .multiply)
        #expect(workspace.toolSession.brush.dualTipStrength == 1)
        #expect(workspace.toolSession.brush.secondarySizeRatio == 1)
        #expect(workspace.toolSession.brush.secondaryAngleOffsetDegrees == 0)
        #expect(workspace.toolSession.brush.secondaryScatter == 0)
        #expect(workspace.toolSession.brush.secondaryInvert == false)
        #expect(workspace.toolSession.brush.customTipSoftness == 0.5)
        #expect(workspace.toolSession.brush.customTipRoundness == 1)
        #expect(workspace.toolSession.brush.customTipAngleDegrees == 0)
        #expect(workspace.toolSession.brush.buildMode == .buildUp)
        #expect(workspace.toolSession.brush.jitterAmount == 0)
        #expect(workspace.toolSession.brush.colorJitterAmount == 0)
        #expect(workspace.toolSession.brush.pressureSensitivity == 1)
        #expect(workspace.toolSession.brush.sizeLowerBound == 0)
        #expect(workspace.toolSession.brush.pressureSizeAmount == 1)
        #expect(workspace.toolSession.brush.pressureOpacityAmount == 1)
        #expect(workspace.toolSession.brush.sizeCurveLow == 0.18)
        #expect(workspace.toolSession.brush.sizeCurveMid == 0.52)
        #expect(workspace.toolSession.brush.sizeCurveHigh == 0.88)
        #expect(workspace.toolSession.brush.opacityCurveLow == 0.05)
        #expect(workspace.toolSession.brush.opacityCurveMid == 0.4)
        #expect(workspace.toolSession.brush.opacityCurveHigh == 0.82)
        #expect(workspace.generator == .stageOneDefault)
    }

    @Test
    func activeMergeDownContextReturnsActiveLayerAndImmediateLowerLayer() {
        var document = ArtDocument.stageOneDefault()
        let secondLayer = document.addLayer(named: "Layer 2")
        let thirdLayer = document.addLayer(named: "Layer 3")
        document.setActiveLayer(thirdLayer.id)

        let context = document.activeMergeDownContext

        #expect(context?.source.id == thirdLayer.id)
        #expect(context?.destination.id == secondLayer.id)
    }

    @Test
    func completeMergeDownRemovesSourceLayerAndActivatesDestination() {
        var document = ArtDocument.stageOneDefault()
        let secondLayer = document.addLayer(named: "Layer 2")
        _ = document.addLayer(named: "Layer 3")

        guard let context = document.activeMergeDownContext else {
            Issue.record("Expected a valid merge-down context")
            return
        }

        let merged = document.completeMergeDown(
            using: context,
            mergedVisibility: false,
            mergedOpacity: 1
        )

        #expect(merged)
        #expect(document.layers.count == 2)
        #expect(document.activeLayerID == secondLayer.id)
        #expect(document.layers.contains(where: { $0.id == context.source.id }) == false)
        #expect(document.layers.first(where: { $0.id == secondLayer.id })?.isVisible == false)
        #expect(document.layers.first(where: { $0.id == secondLayer.id })?.opacity == 1)
    }

    @Test
    func mergeVisibleContextUsesTopmostVisibleLayerAsTarget() {
        var document = ArtDocument.stageOneDefault()
        let secondLayer = document.addLayer(named: "Layer 2")
        let thirdLayer = document.addLayer(named: "Layer 3")
        document.setLayerVisibility(secondLayer.id, isVisible: false)

        let context = document.mergeVisibleContext

        #expect(context?.visibleLayers.map(\.id) == [document.layers[0].id, thirdLayer.id])
        #expect(context?.target.id == thirdLayer.id)
    }

    @Test
    func completeMergeVisibleRemovesOtherVisibleLayersAndActivatesTarget() {
        var document = ArtDocument.stageOneDefault()
        let secondLayer = document.addLayer(named: "Layer 2")
        let thirdLayer = document.addLayer(named: "Layer 3")
        document.setLayerVisibility(secondLayer.id, isVisible: false)

        guard let context = document.mergeVisibleContext else {
            Issue.record("Expected a visible merge context")
            return
        }

        let merged = document.completeMergeVisible(
            using: context,
            mergedVisibility: true,
            mergedOpacity: 1
        )

        #expect(merged)
        #expect(document.activeLayerID == thirdLayer.id)
        #expect(document.layers.map(\.id) == [secondLayer.id, thirdLayer.id])
        #expect(document.layers.first(where: { $0.id == thirdLayer.id })?.opacity == 1)
    }
}

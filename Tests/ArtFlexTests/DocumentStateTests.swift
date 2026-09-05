import Testing
@testable import ArtFlex

struct DocumentStateTests {
    @Test
    func stageOneDocumentStartsWithBackgroundAndTransparentDrawingLayer() {
        let document = ArtDocument.stageOneDefault()

        #expect(document.canvasSize == .stageOneDefault)
        #expect(document.metadata.accumulatedPaintingTime == 0)
        #expect(document.layers.count == 2)
        #expect(document.layers.first?.name == LayerRecord.defaultBackgroundLayerName)
        #expect(document.layers.first?.isLocked == false)
        #expect(document.layers.last?.isLocked == false)
        #expect(document.activeLayerID == document.layers.last?.id)
        #expect(document.colorStandard == .stageOneDefault)
    }

    @Test
    func workspaceStateIncludesDocumentToolSessionAndViewport() {
        let workspace = WorkspaceState.stageOneDefault

        #expect(workspace.document.layers.count == 2)
        #expect(workspace.toolSession.activeTool == .brush)
        #expect(workspace.toolSession.brush.size == 60)
        #expect(workspace.toolSession.brush.opacity == 1)
        #expect(workspace.viewport == .stageOneDefault)
    }

    @Test
    func toolKindSupportsSmudgeWithoutChangingDefaultTool() {
        let workspace = WorkspaceState.stageOneDefault

        #expect(ToolKind(rawValue: "smudge") == .smudge)
        #expect(workspace.toolSession.activeTool == .brush)
    }

    @Test
    func compoundBrushEditorExposesOnlyDistinctRenderModes() {
        #expect(CompoundBrushMode.editorCases == [.textureBlend, .subtract, .maskedOverlay])
        #expect(CompoundBrushMode.intersect.editorEquivalent == .textureBlend)
        #expect(CompoundBrushMode.textureBlend.displayName == "压力双笔尖")
        #expect(CompoundBrushMode.subtract.displayName == "纹理空白处")
        #expect(CompoundBrushMode.maskedOverlay.displayName == "真实遮罩")
        #expect(CompoundBrushMode.overlay.displayName == "旧版叠加")
    }

    @Test
    func workspaceStartsWithEmptyBrushLibrary() {
        let workspace = WorkspaceState.stageOneDefault

        #expect(workspace.brushLibrary.presets.isEmpty)
        #expect(workspace.brushLibrary.selectedPresetID == nil)
        #expect(workspace.patternLibrary.items.isEmpty)
        #expect(workspace.patternLibrary.selectedItemID == nil)
        #expect(workspace.toolSession.brush.tipShape == .hardRound)
        #expect(workspace.toolSession.brush.size == 60)
        #expect(workspace.toolSession.brush.customTipSourceSemantic == .procedural)
        #expect(workspace.toolSession.brush.customTipSoftness == 0.5)
        #expect(workspace.toolSession.brush.customTipRoundness == 1)
        #expect(workspace.toolSession.brush.customTipAngleDegrees == 0)
        #expect(workspace.toolSession.brush.buildMode == .buildUp)
        #expect(workspace.toolSession.brush.jitterAmount == 0)
        #expect(workspace.toolSession.brush.colorJitterAmount == 0)
        #expect(workspace.toolSession.brush.pressureSensitivity == 1)
        #expect(workspace.toolSession.brush.sizeLowerBound == 0)
        #expect(workspace.toolSession.brush.pressureSizeAmount == 0)
        #expect(workspace.toolSession.brush.pressureOpacityAmount == 0)
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
        #expect(document.layers.count == 3)
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

        #expect(context?.visibleLayers.map(\.id) == [document.layers[0].id, document.layers[1].id, thirdLayer.id])
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

    @Test
    func duplicateActiveLayerPreservesTransparentPixelLockState() {
        var document = ArtDocument.stageOneDefault()
        let activeLayerID = document.activeLayerID
        document.toggleLayerTransparentPixelLock(activeLayerID)

        let duplicated = document.duplicateActiveLayer()

        #expect(document.layers.first(where: { $0.id == activeLayerID })?.locksTransparentPixels == true)
        #expect(duplicated?.locksTransparentPixels == true)
    }

    @Test
    func layerGroupControlsChildVisibilityLockAndOpacity() {
        var document = ArtDocument.stageOneDefault()
        let childID = document.activeLayerID
        let group = document.addGroup(containing: Set([childID]))
        document.setLayerOpacity(group.id, opacity: 0.5)
        document.toggleLayerLock(group.id)

        #expect(document.isLayerEffectivelyVisible(childID))
        #expect(document.isLayerEffectivelyLocked(childID))
        #expect(document.effectiveLayerOpacity(childID) == 0.5)

        document.setLayerVisibility(group.id, isVisible: false)
        #expect(!document.isLayerEffectivelyVisible(childID))
        let didUngroup = document.removeGroupKeepingChildren(group.id)
        #expect(didUngroup)
        #expect(document.layer(childID)?.parentID == nil)
    }

    @Test
    func clippingTargetsNearestLowerPaintLayerInTheSameGroup() {
        var document = ArtDocument.stageOneDefault()
        let lowerID = document.activeLayerID
        let upper = document.addLayer(named: "Upper")
        let group = document.addGroup(containing: Set([lowerID, upper.id]))

        let didClip = document.toggleLayerClipping(upper.id)
        #expect(didClip)
        #expect(document.layer(upper.id)?.clipTargetLayerID == lowerID)
        #expect(document.layer(upper.id)?.parentID == group.id)
    }
}

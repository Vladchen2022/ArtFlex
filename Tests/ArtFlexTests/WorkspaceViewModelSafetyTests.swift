import AppKit
import Foundation
import Metal
import Testing
@testable import ArtFlex

struct WorkspaceViewModelSafetyTests {
    @Test
    @MainActor
    func initialWorkspaceStartsWithOpaqueWhiteBackgroundLayer() throws {
        let harness = try BrushEditingBoundaryHarness()
        let backgroundLayerID = try #require(harness.viewModel.workspace.document.layers.first?.id)

        #expect(harness.viewModel.workspace.document.layers.count == 2)
        #expect(harness.viewModel.workspace.document.layers.first?.name == LayerRecord.defaultBackgroundLayerName)
        #expect(harness.viewModel.workspace.document.activeLayerID == harness.viewModel.workspace.document.layers.last?.id)
        #expect(try harness.color(atX: 0, y: 0, layerID: backgroundLayerID).alpha > 0.99)
        #expect(try harness.color(atX: 0, y: 0, layerID: backgroundLayerID).red > 0.99)
        #expect(try harness.color(atX: 0, y: 0, layerID: backgroundLayerID).green > 0.99)
        #expect(try harness.color(atX: 0, y: 0, layerID: backgroundLayerID).blue > 0.99)
    }

    @Test
    @MainActor
    func exportPNGFlushesPendingBrushCommitsBeforeReadingLayerTexture() throws {
        let harness = try BrushEditingBoundaryHarness()
        try harness.makePendingBrushCommit()
        PerformanceAuditStore.shared.reset()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: url) }

        try harness.viewModel.exportPNG(to: url)

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(harness.bootstrap.strokeEngine.hasPendingBrushCommitJobs == false)
        #expect(PerformanceAuditStore.shared.snapshot().latestDuration("HistoryController.captureCheckpoint") != nil)
        #expect(try harness.alpha(atX: 12, y: 12) > 0.01)
    }

    @Test
    @MainActor
    func createNewCanvasDiscardFlushesPendingBrushCommitsBeforeResettingState() throws {
        let harness = try BrushEditingBoundaryHarness()
        try harness.makePendingBrushCommit()
        PerformanceAuditStore.shared.reset()
        harness.viewModel.setBrushOpacity(0.42)

        harness.viewModel.createNewCanvasDiscardingUnsavedChanges(
            name: "Safety Test",
            canvasSize: .init(width: 32, height: 32),
            resolutionDPI: 72
        )

        let backgroundLayerID = try #require(harness.viewModel.workspace.document.layers.first?.id)
        #expect(harness.bootstrap.strokeEngine.hasPendingBrushCommitJobs == false)
        #expect(harness.viewModel.workspace.document.canvasSize == .init(width: 32, height: 32))
        #expect(harness.viewModel.workspace.document.layers.first?.name == LayerRecord.defaultBackgroundLayerName)
        #expect(harness.viewModel.workspace.document.layers.count == 2)
        #expect(harness.viewModel.workspace.document.activeLayerID == harness.viewModel.workspace.document.layers.last?.id)
        #expect(harness.viewModel.workspace.toolSession.brush.size == 60)
        #expect(harness.viewModel.workspace.toolSession.brush.opacity == 1)
        #expect(PerformanceAuditStore.shared.snapshot().latestDuration("HistoryController.captureCheckpoint") != nil)
        #expect(try harness.color(atX: 0, y: 0, layerID: backgroundLayerID).alpha > 0.99)
        #expect(try harness.color(atX: 0, y: 0, layerID: backgroundLayerID).red > 0.99)
        #expect(try harness.color(atX: 0, y: 0, layerID: backgroundLayerID).green > 0.99)
        #expect(try harness.color(atX: 0, y: 0, layerID: backgroundLayerID).blue > 0.99)
    }

    @Test
    @MainActor
    func directSetActiveLayerOpacityFlushesPendingBrushCommitsFirst() throws {
        let harness = try BrushEditingBoundaryHarness()
        try harness.makePendingBrushCommit()
        PerformanceAuditStore.shared.reset()

        harness.viewModel.setActiveLayerOpacity(0.5)

        let activeLayerID = harness.viewModel.workspace.document.activeLayerID
        #expect(harness.bootstrap.strokeEngine.hasPendingBrushCommitJobs == false)
        #expect(harness.viewModel.workspace.document.layers.first(where: { $0.id == activeLayerID })?.opacity == 0.5)
        #expect(harness.viewModel.canUndo)
        #expect(PerformanceAuditStore.shared.snapshot().latestDuration("HistoryController.captureCheckpoint") != nil)
        #expect(try harness.alpha(atX: 12, y: 12) > 0.01)
    }

    @Test
    @MainActor
    func canvasViewportLockBlocksZoomAndRotation() throws {
        let harness = try BrushEditingBoundaryHarness()
        harness.viewModel.updateCanvasViewportSize(.init(width: 1200, height: 900))
        harness.viewModel.updateCanvasToolHover(to: .init(x: 720, y: 360))
        harness.viewModel.setViewportRotation(18)

        let baselineViewport = harness.viewModel.workspace.viewport
        harness.viewModel.setCanvasViewportLocked(true)
        harness.viewModel.zoomIn()
        harness.viewModel.setViewportOffset(x: 120, y: -60)
        harness.viewModel.setViewportRotation(42)

        #expect(harness.viewModel.workspace.viewport.zoomScale == baselineViewport.zoomScale)
        #expect(harness.viewModel.workspace.viewport.contentOffset == baselineViewport.contentOffset)
        #expect(harness.viewModel.workspace.viewport.rotationDegrees == baselineViewport.rotationDegrees)
    }

    @Test
    @MainActor
    func toggleLayerTransparentPixelLockUpdatesActiveLayerState() throws {
        let harness = try BrushEditingBoundaryHarness()
        let activeLayerID = harness.viewModel.workspace.document.activeLayerID

        #expect(harness.viewModel.workspace.document.layers.first(where: { $0.id == activeLayerID })?.locksTransparentPixels == false)
        harness.viewModel.toggleLayerTransparentPixelLock(activeLayerID)
        #expect(harness.viewModel.workspace.document.layers.first(where: { $0.id == activeLayerID })?.locksTransparentPixels == true)
    }

    @Test
    @MainActor
    func toggleWorkspaceChromeVisibilityUpdatesUIState() throws {
        let harness = try BrushEditingBoundaryHarness()

        #expect(harness.viewModel.isWorkspaceChromeHidden == false)
        harness.viewModel.toggleWorkspaceChromeVisibility()
        #expect(harness.viewModel.isWorkspaceChromeHidden == true)
        harness.viewModel.toggleWorkspaceChromeVisibility()
        #expect(harness.viewModel.isWorkspaceChromeHidden == false)
    }

    @Test
    @MainActor
    func selectingToolFromUIPublishesOperationStatusMessage() throws {
        let harness = try BrushEditingBoundaryHarness()

        harness.viewModel.selectToolFromUI(.eraser)

        #expect(harness.viewModel.workspace.toolSession.activeTool == .eraser)
        #expect(harness.viewModel.status?.message == "选择了橡皮")
        #expect(harness.viewModel.status?.shortcutLabel == "E")
    }

    @Test
    @MainActor
    func toolShortcutStatusIncludesShortcutLabel() throws {
        let harness = try BrushEditingBoundaryHarness()

        let handled = harness.viewModel.handleToolShortcutKey("B", modifiers: [])

        #expect(handled == true)
        #expect(harness.viewModel.workspace.toolSession.activeTool == .brush)
        #expect(harness.viewModel.status?.message == "选择了画笔")
        #expect(harness.viewModel.status?.shortcutLabel == "B")
    }

    @Test
    @MainActor
    func colorAdjustmentToolFirstStrokeCreatesBlueMaskPreview() async throws {
        let harness = try BrushEditingBoundaryHarness()
        let activeLayerID = harness.viewModel.workspace.document.activeLayerID

        try fillOpaqueRect(
            in: harness,
            layerID: activeLayerID,
            originX: 48,
            originY: 48,
            width: 120,
            height: 120,
            color: .init(red: 1, green: 1, blue: 1, alpha: 1)
        )

        harness.viewModel.selectTool(.brightnessAdjust)
        harness.viewModel.beginStrokeIfNeeded()
        harness.viewModel.applyStroke(samples: [
            .init(location: .init(x: 96, y: 96), pressure: 1),
            .init(location: .init(x: 112, y: 112), pressure: 1)
        ])
        harness.viewModel.endStroke()

        try await waitForColorAdjustmentPreview(in: harness)

        #expect(harness.viewModel.colorAdjustmentOverlayState.isActive)
        #expect(harness.viewModel.colorAdjustmentOverlayState.sourceKind == .paintedMask)

        let previewPixel = try harness.colorAdjustmentPreviewColor(atX: 104, y: 104)
        #expect(previewPixel.blue > previewPixel.red)
        #expect(previewPixel.blue > previewPixel.green)
    }

    @Test
    @MainActor
    func colorAdjustmentToolEKeySwitchesToEraseMaskMode() throws {
        let harness = try BrushEditingBoundaryHarness()

        harness.viewModel.selectTool(.brightnessAdjust)
        let handled = harness.viewModel.handleKeyDown(
            makeCanvasKeyEvent(type: .keyDown, characters: "e", charactersIgnoringModifiers: "e", modifiers: [], keyCode: 14)
        )

        #expect(handled == true)
        #expect(harness.viewModel.workspace.toolSession.activeTool == .brightnessAdjust)
        #expect(harness.viewModel.colorAdjustmentBrushMode == .erase)
    }

    @Test
    @MainActor
    func colorAdjustmentToolBKeyReturnsMaskModeToPaint() throws {
        let harness = try BrushEditingBoundaryHarness()
        harness.viewModel.selectTool(.brightnessAdjust)
        _ = harness.viewModel.handleKeyDown(
            makeCanvasKeyEvent(type: .keyDown, characters: "e", charactersIgnoringModifiers: "e", modifiers: [], keyCode: 14)
        )

        let handled = harness.viewModel.handleKeyDown(
            makeCanvasKeyEvent(type: .keyDown, characters: "b", charactersIgnoringModifiers: "b", modifiers: [], keyCode: 11)
        )

        #expect(handled == true)
        #expect(harness.viewModel.workspace.toolSession.activeTool == .brightnessAdjust)
        #expect(harness.viewModel.colorAdjustmentBrushMode == .paint)
    }

    @Test
    @MainActor
    func colorAdjustmentToolSwitchingToEraseKeepsExistingMaskPreviewVisible() async throws {
        let harness = try BrushEditingBoundaryHarness()
        let activeLayerID = harness.viewModel.workspace.document.activeLayerID

        try fillOpaqueRect(
            in: harness,
            layerID: activeLayerID,
            originX: 48,
            originY: 48,
            width: 120,
            height: 120,
            color: .init(red: 1, green: 1, blue: 1, alpha: 1)
        )

        harness.viewModel.selectTool(.brightnessAdjust)
        harness.viewModel.beginStrokeIfNeeded()
        harness.viewModel.applyStroke(samples: [.init(location: .init(x: 96, y: 96), pressure: 1)])
        harness.viewModel.endStroke()
        try await waitForColorAdjustmentPreview(in: harness)

        let previewTextureBefore = harness.viewModel.brushDisplayTexture(for: activeLayerID)
        _ = harness.viewModel.handleKeyDown(
            makeCanvasKeyEvent(type: .keyDown, characters: "e", charactersIgnoringModifiers: "e", modifiers: [], keyCode: 14)
        )
        let previewTextureAfter = harness.viewModel.brushDisplayTexture(for: activeLayerID)

        #expect(harness.viewModel.colorAdjustmentBrushMode == .erase)
        #expect(harness.viewModel.colorAdjustmentSession != nil)
        #expect(harness.viewModel.colorAdjustmentOverlayState.isActive)
        #expect(previewTextureBefore != nil)
        #expect(previewTextureAfter != nil)
    }

    @Test
    @MainActor
    func colorAdjustmentToolEscDiscardsSessionAndPreview() async throws {
        let harness = try BrushEditingBoundaryHarness()
        let activeLayerID = harness.viewModel.workspace.document.activeLayerID

        try fillOpaqueRect(
            in: harness,
            layerID: activeLayerID,
            originX: 48,
            originY: 48,
            width: 120,
            height: 120,
            color: .init(red: 1, green: 1, blue: 1, alpha: 1)
        )

        harness.viewModel.selectTool(.brightnessAdjust)
        harness.viewModel.beginStrokeIfNeeded()
        harness.viewModel.applyStroke(samples: [.init(location: .init(x: 96, y: 96), pressure: 1)])
        harness.viewModel.endStroke()

        try await waitForColorAdjustmentPreview(in: harness)

        let handled = harness.viewModel.handleKeyDown(
            makeCanvasKeyEvent(type: .keyDown, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", modifiers: [], keyCode: 53)
        )

        #expect(handled == true)
        #expect(harness.viewModel.colorAdjustmentSession == nil)
        #expect(harness.viewModel.colorAdjustmentOverlayState.isActive == false)
        #expect(harness.viewModel.brushDisplayTexture(for: activeLayerID) == nil)
    }

    @Test
    @MainActor
    func applyingBrushPresetWhileColorAdjustmentToolIsActiveKeepsToolSelected() throws {
        let harness = try BrushEditingBoundaryHarness()

        harness.viewModel.selectTool(.brightnessAdjust)
        harness.viewModel.saveCurrentBrushPreset()
        let presetID = try #require(
            harness.viewModel.workspace.brushLibrary.selectedPresetID
            ?? harness.viewModel.workspace.brushLibrary.presets.first?.id
        )

        harness.viewModel.applyBrushPreset(presetID)

        #expect(harness.viewModel.workspace.toolSession.activeTool == .brightnessAdjust)
    }

    @Test
    @MainActor
    func copyPixelsAndPastePixelsInsertNewLayerAboveCurrentActiveLayer() throws {
        let harness = try BrushEditingBoundaryHarness()
        let sourceLayerID = harness.viewModel.workspace.document.activeLayerID
        let backgroundLayerID = try #require(harness.viewModel.workspace.document.layers.first?.id)

        try fillOpaqueRect(
            in: harness,
            layerID: sourceLayerID,
            originX: 12,
            originY: 18,
            width: 6,
            height: 5,
            color: .init(red: 1, green: 0, blue: 0, alpha: 1)
        )

        harness.viewModel.copyPixels()
        harness.viewModel.selectLayer(backgroundLayerID)
        harness.viewModel.pastePixels()

        let layers = harness.viewModel.workspace.document.layers
        #expect(layers.count == 3)
        #expect(harness.viewModel.workspace.document.activeLayerID == layers[1].id)
        #expect(try harness.alpha(atX: 14, y: 20, layerID: layers[1].id) > 0.95)
        #expect(try harness.alpha(atX: 14, y: 20, layerID: sourceLayerID) > 0.95)
        #expect(harness.viewModel.status?.message == "已粘贴为新图层")
    }

    @Test
    @MainActor
    func cutPixelsWithSelectionClearsSourceAndCanPasteBackInPlace() throws {
        let harness = try BrushEditingBoundaryHarness()
        let sourceLayerID = harness.viewModel.workspace.document.activeLayerID

        try fillOpaqueRect(
            in: harness,
            layerID: sourceLayerID,
            originX: 10,
            originY: 14,
            width: 8,
            height: 8,
            color: .init(red: 0, green: 0, blue: 1, alpha: 1)
        )

        makeRectangleSelection(
            in: harness.viewModel,
            minX: 11,
            minY: 15,
            maxX: 16,
            maxY: 20
        )

        harness.viewModel.cutPixels()
        #expect(try harness.alpha(atX: 13, y: 17, layerID: sourceLayerID) < 0.01)

        harness.viewModel.pastePixels()
        let pastedLayerID = harness.viewModel.workspace.document.activeLayerID
        #expect(pastedLayerID != sourceLayerID)
        #expect(try harness.alpha(atX: 13, y: 17, layerID: pastedLayerID) > 0.95)
        #expect(harness.viewModel.status?.message == "已粘贴为新图层")
    }

    @Test
    @MainActor
    func compoundGlobalPressureControlsStayDecoupledFromPrimaryInternalPressureControls() throws {
        let harness = try BrushEditingBoundaryHarness()

        harness.viewModel.setCompoundBrushEnabled(true)
        harness.viewModel.setCompoundPrimaryPressureSizeAmount(0.22)
        harness.viewModel.setCompoundPrimaryPressureOpacityAmount(0.33)
        harness.viewModel.setPressureSizeAmount(0.74)
        harness.viewModel.setPressureOpacityAmount(0.81)

        let brush = harness.viewModel.workspace.toolSession.brush
        #expect(brush.compoundBrush.enabled == true)
        #expect(brush.pressureSizeAmount == 0.22)
        #expect(brush.pressureOpacityAmount == 0.33)
        #expect(brush.compoundBrush.globalPressureSizeAmount == 0.74)
        #expect(brush.compoundBrush.globalPressureOpacityAmount == 0.81)
        #expect(harness.viewModel.displayedPressureSizeAmount == 0.74)
        #expect(harness.viewModel.displayedPressureOpacityAmount == 0.81)
    }

    @Test
    @MainActor
    func compoundGlobalPaintNoiseControlsStayDecoupledFromPrimaryBrushNoiseControls() throws {
        let harness = try BrushEditingBoundaryHarness()

        harness.viewModel.setPaintJitterAmount(0.21)
        harness.viewModel.setPaintContrastAmount(0.32)
        harness.viewModel.setCompoundBrushEnabled(true)
        harness.viewModel.setPaintJitterAmount(0.73)
        harness.viewModel.setPaintContrastAmount(0.84)

        let brush = harness.viewModel.workspace.toolSession.brush
        #expect(brush.compoundBrush.enabled == true)
        #expect(brush.paintJitterAmount == 0.21)
        #expect(brush.paintContrastAmount == 0.32)
        #expect(brush.compoundBrush.globalPaintJitterAmount == 0.73)
        #expect(brush.compoundBrush.globalPaintContrastAmount == 0.84)
        #expect(harness.viewModel.displayedPaintJitterAmount == 0.73)
        #expect(harness.viewModel.displayedPaintContrastAmount == 0)
    }

    @Test
    @MainActor
    func buildUpOpacityCompensationControlUpdatesBrushSetting() throws {
        let harness = try BrushEditingBoundaryHarness()

        harness.viewModel.setBuildUpOpacityCompensationAmount(0.38)

        #expect(harness.viewModel.workspace.toolSession.brush.buildUpOpacityCompensationAmount == 0.38)
        #expect(harness.viewModel.displayedBuildUpOpacityCompensationAmount == 0.38)
    }

    @Test
    @MainActor
    func fillAtPointStartsDrawingStatsTracking() throws {
        let harness = try BrushEditingBoundaryHarness()

        #expect(harness.viewModel.drawingStatsController.snapshot.isActiveSessionRunning == false)
        harness.viewModel.fillAtPoint(.init(x: 12, y: 12))
        #expect(harness.viewModel.drawingStatsController.snapshot.isActiveSessionRunning == true)
    }

    @Test
    @MainActor
    func rectangleSelectionStartsDrawingStatsTracking() throws {
        let harness = try BrushEditingBoundaryHarness()

        harness.viewModel.selectTool(.rectangleSelection)
        #expect(harness.viewModel.drawingStatsController.snapshot.isActiveSessionRunning == false)

        harness.viewModel.beginSelection(kind: .rectangle, at: .init(x: 8, y: 8))
        harness.viewModel.updateSelection(to: .init(x: 24, y: 24))
        harness.viewModel.commitSelection(at: .init(x: 24, y: 24))

        #expect(harness.viewModel.drawingStatsController.snapshot.isActiveSessionRunning == true)
    }

    @Test
    @MainActor
    func selectingCreativeShapeGeneratorSourceSwitchesToLassoTool() throws {
        let harness = try BrushEditingBoundaryHarness()

        harness.viewModel.selectTool(.brush)
        harness.viewModel.selectCreativeShapeGeneratorSource(.currentColor)

        #expect(harness.viewModel.workspace.toolSession.activeTool == .lassoSelection)
    }

    @Test
    @MainActor
    func changingSelectedColorSwitchesCreativeGeneratorBackToCurrentColorSource() throws {
        let harness = try BrushEditingBoundaryHarness()

        harness.viewModel.selectCreativeShapeGeneratorSource(.paletteBlocks)
        #expect(harness.viewModel.workspace.creativeShapeGenerator.selectedSource == .paletteBlocks)

        harness.viewModel.setSelectedColor(.init(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))

        #expect(harness.viewModel.workspace.creativeShapeGenerator.selectedSource == .currentColor)
    }

    @Test
    @MainActor
    func navigatorZoomPercentUpdatesViewportScale() throws {
        let harness = try BrushEditingBoundaryHarness()

        harness.viewModel.setNavigatorZoomPercent(250)

        #expect(abs(harness.viewModel.workspace.viewport.zoomScale - 2.5) < 0.0001)
        #expect(abs(harness.viewModel.navigatorZoomPercent - 250) < 0.0001)
    }

    @Test
    @MainActor
    func navigatorSceneSnapshotUsesDefaultViewportAndHidesSelection() throws {
        let harness = try BrushEditingBoundaryHarness()

        harness.viewModel.updateCanvasViewportSize(.init(width: 1200, height: 900))
        harness.viewModel.setNavigatorZoomPercent(180)
        harness.viewModel.selectTool(.rectangleSelection)
        harness.viewModel.beginSelection(kind: .rectangle, at: .init(x: 8, y: 8))
        harness.viewModel.updateSelection(to: .init(x: 24, y: 24))
        harness.viewModel.commitSelection(at: .init(x: 24, y: 24))

        let snapshot = harness.viewModel.navigatorSceneSnapshot
        #expect(snapshot.renderSnapshot.viewport == .stageOneDefault)
        #expect(snapshot.selectionShape == nil)
    }

    @Test
    @MainActor
    func manualNavigatorPreviewRefreshBumpsProxyRevisionAndKeepsDefaultViewport() throws {
        let harness = try BrushEditingBoundaryHarness()

        harness.viewModel.updateCanvasViewportSize(.init(width: 1200, height: 900))
        harness.viewModel.setNavigatorZoomPercent(180)
        harness.viewModel.selectTool(.rectangleSelection)
        harness.viewModel.beginSelection(kind: .rectangle, at: .init(x: 8, y: 8))
        harness.viewModel.updateSelection(to: .init(x: 24, y: 24))
        harness.viewModel.commitSelection(at: .init(x: 24, y: 24))

        let initialRevision = harness.viewModel.navigatorPreviewProxy.redrawRevision
        harness.viewModel.refreshNavigatorPreviewNow()

        #expect(harness.viewModel.navigatorPreviewProxy.redrawRevision == initialRevision + 1)
        #expect(harness.viewModel.navigatorPreviewProxy.sceneSnapshot.renderSnapshot.viewport == .stageOneDefault)
        #expect(harness.viewModel.navigatorPreviewProxy.sceneSnapshot.selectionShape == nil)
    }

    @Test
    @MainActor
    func canvasLuminosityReferenceDefersHiddenRefreshAndCatchesUpWhenVisible() async throws {
        let harness = try BrushEditingBoundaryHarness()

        harness.viewModel.setReferenceImageInspectorVisible(true)
        harness.viewModel.toggleCanvasLuminosityReference()

        let luminositySlotID = try await harness.waitForSelectedReferenceImageSlotID()
        let initialPixels = try #require(harness.viewModel.referenceImageSlots[luminositySlotID].asset?.rgbaPixels)

        harness.viewModel.setReferenceImageInspectorVisible(false)
        harness.viewModel.setSelectedColor(.init(red: 0, green: 0, blue: 0, alpha: 1))
        harness.viewModel.fillAtPoint(.init(x: 12, y: 12))

        try? await Task.sleep(for: .milliseconds(2300))
        #expect(harness.viewModel.referenceImageSlots[luminositySlotID].asset?.rgbaPixels == initialPixels)

        harness.viewModel.setReferenceImageInspectorVisible(true)
        try await harness.waitForReferenceImagePixelsChange(slotID: luminositySlotID, from: initialPixels)

        let refreshedPixels = try #require(harness.viewModel.referenceImageSlots[luminositySlotID].asset?.rgbaPixels)
        #expect(refreshedPixels != initialPixels)
    }

    @Test
    @MainActor
    func togglingCreativeGeneratorTipImageModeUpdatesWorkspaceState() throws {
        let harness = try BrushEditingBoundaryHarness()

        #expect(harness.viewModel.workspace.creativeShapeGenerator.usesTipImageShapes == false)
        harness.viewModel.setCreativeShapeGeneratorUsesTipImageShapes(true)
        #expect(harness.viewModel.workspace.creativeShapeGenerator.usesTipImageShapes == true)
        harness.viewModel.setCreativeShapeGeneratorUsesTipImageShapes(false)
        #expect(harness.viewModel.workspace.creativeShapeGenerator.usesTipImageShapes == false)
    }

    @Test
    @MainActor
    func selectingExternalImageSourceTwiceClearsLoadedImage() throws {
        let harness = try BrushEditingBoundaryHarness()

        harness.bootstrap.workspaceStore.updateCreativeShapeGenerator { generator in
            generator.importedImage = CreativeShapeGeneratorImageSource(
                fileName: "test.png",
                width: CreativeShapeGeneratorImageSource.targetDimension,
                height: CreativeShapeGeneratorImageSource.targetDimension,
                rgbaPixels: Data(repeating: 255, count: CreativeShapeGeneratorImageSource.targetDimension * CreativeShapeGeneratorImageSource.targetDimension * 4)
            )
        }
        harness.viewModel.selectTool(.brush)

        harness.viewModel.selectCreativeShapeGeneratorSource(.externalImage)
        #expect(harness.viewModel.workspace.creativeShapeGenerator.selectedSource == .externalImage)

        harness.viewModel.selectCreativeShapeGeneratorSource(.externalImage)
        #expect(harness.viewModel.workspace.creativeShapeGenerator.importedImage == nil)
        #expect(harness.viewModel.workspace.creativeShapeGenerator.selectedSource == nil)
    }

    @Test
    @MainActor
    func clearingSelectedReferenceImageSwitchesToNextLoadedSlotWithoutReorderingSlots() throws {
        let harness = try BrushEditingBoundaryHarness()

        harness.viewModel.replaceReferenceImageSlotAsset(makeReferenceImageAsset(fileName: "one.png"), at: 0)
        harness.viewModel.replaceReferenceImageSlotAsset(makeReferenceImageAsset(fileName: "three.png"), at: 2)
        harness.viewModel.replaceReferenceImageSlotAsset(makeReferenceImageAsset(fileName: "five.png"), at: 4)

        harness.viewModel.activateReferenceImageSlot(2)
        #expect(harness.viewModel.selectedReferenceImageSlotID == 2)

        harness.viewModel.clearSelectedReferenceImage()

        #expect(harness.viewModel.referenceImageSlots[0].asset != nil)
        #expect(harness.viewModel.referenceImageSlots[2].asset == nil)
        #expect(harness.viewModel.referenceImageSlots[4].asset != nil)
        #expect(harness.viewModel.selectedReferenceImageSlotID == 4)
    }

    @Test
    @MainActor
    func referenceImageColorPickUpdatesSelectedColorWithoutChangingActiveTool() throws {
        let harness = try BrushEditingBoundaryHarness()
        let originalColor = harness.viewModel.workspace.toolSession.selectedColor
        let pickedColor = RGBAColor(red: 0.82, green: 0.31, blue: 0.18, alpha: 1)

        harness.viewModel.selectTool(.smudge)
        harness.viewModel.confirmReferenceImagePickedColor(pickedColor)

        #expect(harness.viewModel.workspace.toolSession.activeTool == .smudge)
        #expect(harness.viewModel.workspace.toolSession.selectedColor == pickedColor)
        #expect(harness.viewModel.referenceImagePreviewColor == pickedColor)
        #expect(harness.viewModel.referenceImagePreviousPickedColor == originalColor)
    }

    @Test
    @MainActor
    func selectingColorBlockUpdatesReferenceImagePreviousColorMemory() throws {
        let harness = try BrushEditingBoundaryHarness()
        let originalColor = harness.viewModel.workspace.toolSession.selectedColor

        harness.viewModel.selectColorBlock(at: 0)

        #expect(harness.viewModel.referenceImagePreviousPickedColor == originalColor)
        #expect(harness.viewModel.workspace.toolSession.selectedColor != originalColor)
    }

    @Test
    @MainActor
    func strokeCaptureViewForwardsUnhandledKeyboardEvents() {
        let view = StrokeCaptureMTKView(frame: .init(x: 0, y: 0, width: 120, height: 120), device: nil)
        var handledKeyDown = false
        var handledKeyUp = false
        var handledFlagsChange = false

        view.keyDownEventHandler = { event in
            handledKeyDown = event.charactersIgnoringModifiers?.lowercased() == "z"
            return handledKeyDown
        }
        view.keyUpEventHandler = { event in
            handledKeyUp = event.charactersIgnoringModifiers?.lowercased() == "z"
            return handledKeyUp
        }
        view.modifierFlagsChangedEventHandler = { modifiers in
            handledFlagsChange = modifiers.contains(.shift)
            return handledFlagsChange
        }

        view.keyDown(with: makeCanvasKeyEvent(type: .keyDown, characters: "Z", charactersIgnoringModifiers: "z", modifiers: [.shift], keyCode: 6))
        view.keyUp(with: makeCanvasKeyEvent(type: .keyUp, characters: "Z", charactersIgnoringModifiers: "z", modifiers: [], keyCode: 6))
        view.flagsChanged(with: makeCanvasKeyEvent(type: .flagsChanged, characters: "", charactersIgnoringModifiers: "", modifiers: [.shift], keyCode: 56))

        #expect(handledKeyDown)
        #expect(handledKeyUp)
        #expect(handledFlagsChange)
    }

    @Test
    @MainActor
    func smudgeToolRemembersItsPreviousBrushSettings() throws {
        let harness = try BrushEditingBoundaryHarness()

        harness.viewModel.setBrushSize(144)
        #expect(harness.viewModel.workspace.toolSession.brush.size == 144)

        harness.viewModel.selectTool(.smudge)
        #expect(harness.viewModel.workspace.toolSession.brush.size == 144)

        harness.viewModel.setBrushSize(38)
        #expect(harness.viewModel.workspace.toolSession.brush.size == 38)

        harness.viewModel.selectTool(.brush)
        #expect(harness.viewModel.workspace.toolSession.brush.size == 144)

        harness.viewModel.setBrushSize(220)
        #expect(harness.viewModel.workspace.toolSession.brush.size == 220)

        harness.viewModel.selectTool(.smudge)
        #expect(harness.viewModel.workspace.toolSession.brush.size == 38)
    }

    @Test
    @MainActor
    func importingDistinctTipImagesKeepsDistinctLibraryMasks() throws {
        let viewModel = try makeWorkspaceViewModelForTipImportTests()
        let circleURL = try makeTemporaryTipImageURL(fileName: "circle", image: makeCircularTipSourceImage())
        let scatterURL = try makeTemporaryTipImageURL(fileName: "scatter", image: makeScatterTipSourceImage())
        defer {
            try? FileManager.default.removeItem(at: circleURL)
            try? FileManager.default.removeItem(at: scatterURL)
        }

        let imported = viewModel.importTipImageLibraryItems(from: [circleURL, scatterURL])
        #expect(imported.count == 2)

        let storedMasks = imported.compactMap { viewModel.workspace.tipImageLibrary.item(id: $0)?.maskData }
        #expect(storedMasks.count == 2)
        #expect(storedMasks[0] != storedMasks[1])
    }

    @Test
    @MainActor
    func importingTipImageRemovesThinGuideLinesFromFinalMask() throws {
        let viewModel = try makeWorkspaceViewModelForTipImportTests()

        #expect(viewModel.importBrushTipImage(from: makeGuidedBlobTipSourceImage(), sourceDescription: "guided"))
        guard let maskData = viewModel.workspace.toolSession.brush.customTipMaskData else {
            Issue.record("Expected imported tip mask data.")
            return
        }

        let rowMass = maskRowMasses(maskData, resolution: 256)
        let significantRows = rowMass.enumerated().filter { $0.element > 255.0 }.map(\.offset)
        guard let first = significantRows.first, let last = significantRows.last else {
            Issue.record("Expected non-empty imported tip mask.")
            return
        }

        #expect(first > 10)
        #expect(last < 245)
        #expect(rowMass[0] < 1)
        #expect(rowMass[255] < 1)
    }

    @Test
    @MainActor
    func updatingCustomTipMaskKeepsSelectedPresetUntouchedAndBumpsStrokeResetToken() throws {
        let harness = try BrushEditingBoundaryHarness()
        harness.viewModel.saveCurrentBrushPreset()

        let selectedPresetID = try #require(
            harness.viewModel.workspace.brushLibrary.selectedPresetID ??
            harness.viewModel.workspace.brushLibrary.presets.first?.id
        )
        harness.viewModel.applyBrushPreset(selectedPresetID)

        let selectedPresetBrush = try #require(
            harness.viewModel.workspace.brushLibrary.preset(id: selectedPresetID)?.brush
        )
        let previousStrokeResetToken = harness.viewModel.strokeResetToken
        let customMask = makeVerticalTipMask(side: 16)

        harness.viewModel.updateCustomTipMask(customMask)

        #expect(harness.viewModel.strokeResetToken == previousStrokeResetToken + 1)
        #expect(harness.viewModel.workspace.toolSession.brush.tipShape == .customRound)
        #expect(harness.viewModel.workspace.toolSession.brush.customTipMaskData == customMask)
        #expect(harness.viewModel.workspace.toolSession.brush != selectedPresetBrush)
        #expect(harness.viewModel.workspace.brushLibrary.preset(id: selectedPresetID)?.brush == selectedPresetBrush)
    }

    @Test
    @MainActor
    func savingBrushPresetPreservesBuildUpOpacityCompensationAmount() throws {
        let harness = try BrushEditingBoundaryHarness()
        harness.viewModel.setBuildUpOpacityCompensationAmount(0.41)

        harness.viewModel.saveCurrentBrushPreset()

        let selectedPresetID = try #require(
            harness.viewModel.workspace.brushLibrary.selectedPresetID ??
            harness.viewModel.workspace.brushLibrary.presets.first?.id
        )
        let savedPresetBrush = try #require(
            harness.viewModel.workspace.brushLibrary.preset(id: selectedPresetID)?.brush
        )

        #expect(savedPresetBrush.buildUpOpacityCompensationAmount == 0.41)

        harness.viewModel.setBuildUpOpacityCompensationAmount(0.9)
        harness.viewModel.applyBrushPreset(selectedPresetID)

        #expect(harness.viewModel.workspace.toolSession.brush.buildUpOpacityCompensationAmount == 0.41)
    }

    @Test
    @MainActor
    func applyingBrushTipDraftCommitsWithoutCanvasStroke() throws {
        let harness = try BrushEditingBoundaryHarness()
        let previousStrokeResetToken = harness.viewModel.strokeResetToken
        let baselineBrush = harness.viewModel.workspace.toolSession.brush
        let draftMask = makeVerticalTipMask(side: 16)

        harness.viewModel.updateBrushTipDraft(draftMask)

        #expect(harness.viewModel.hasPendingBrushTipDraft)
        #expect(harness.viewModel.brushTipDraftMaskData == draftMask)
        #expect(harness.viewModel.workspace.toolSession.brush == baselineBrush)
        #expect(harness.viewModel.strokeResetToken == previousStrokeResetToken)

        #expect(harness.viewModel.applyBrushTipDraft())
        #expect(harness.viewModel.hasPendingBrushTipDraft == false)
        #expect(harness.viewModel.brushTipDraftMaskData == nil)
        #expect(harness.viewModel.workspace.toolSession.brush.customTipMaskData == draftMask)
        #expect(harness.viewModel.strokeResetToken == previousStrokeResetToken + 1)
    }

    @Test
    @MainActor
    func pendingBrushTipDraftDoesNotAutoCommitWhenMainCanvasStrokeBegins() throws {
        let harness = try BrushEditingBoundaryHarness()
        let previousStrokeResetToken = harness.viewModel.strokeResetToken
        let baselineBrush = harness.viewModel.workspace.toolSession.brush
        let draftMask = makeVerticalTipMask(side: 16)

        harness.viewModel.updateBrushTipDraft(draftMask)
        harness.viewModel.setBrushSize(90)
        try drawSingleMainCanvasStamp(in: harness.viewModel, at: .init(x: 180, y: 180))

        #expect(harness.viewModel.hasPendingBrushTipDraft)
        #expect(harness.viewModel.brushTipDraftMaskData == draftMask)
        #expect(harness.viewModel.workspace.toolSession.brush.tipShape == baselineBrush.tipShape)
        #expect(harness.viewModel.workspace.toolSession.brush.customTipSourceSemantic == baselineBrush.customTipSourceSemantic)
        #expect(harness.viewModel.workspace.toolSession.brush.customTipMaskData == baselineBrush.customTipMaskData)
        #expect(harness.viewModel.workspace.toolSession.brush.customTipEnvelopeMaskData == baselineBrush.customTipEnvelopeMaskData)
        #expect(harness.viewModel.strokeResetToken == previousStrokeResetToken)

        let appliedBounds = try #require(
            try activeDisplayOpaqueBounds(
                in: harness.viewModel,
                minX: 120,
                minY: 90,
                maxX: 240,
                maxY: 270
            )
        )
        #expect(abs(Double(appliedBounds.width - appliedBounds.height)) < Double(max(appliedBounds.width, appliedBounds.height)) * 0.35)
    }

    @Test
    @MainActor
    func clearBrushTipDraftRequiresManualApplyToClearCommittedTip() throws {
        let harness = try BrushEditingBoundaryHarness()
        let baselineMask = makeVerticalTipMask(side: 16)
        harness.viewModel.updateCustomTipMask(baselineMask)
        let committedStrokeResetToken = harness.viewModel.strokeResetToken

        harness.viewModel.clearBrushTipDraft()

        #expect(harness.viewModel.hasPendingBrushTipDraft)
        #expect(harness.viewModel.brushTipDraftMaskData == nil)
        #expect(harness.viewModel.workspace.toolSession.brush.customTipMaskData == baselineMask)
        #expect(harness.viewModel.strokeResetToken == committedStrokeResetToken)

        harness.viewModel.setBrushSize(90)
        try drawSingleMainCanvasStamp(in: harness.viewModel, at: .init(x: 220, y: 220))
        #expect(harness.viewModel.hasPendingBrushTipDraft)
        #expect(harness.viewModel.brushTipDraftMaskData == nil)
        #expect(harness.viewModel.workspace.toolSession.brush.customTipMaskData == baselineMask)
        #expect(harness.viewModel.strokeResetToken == committedStrokeResetToken)

        #expect(harness.viewModel.applyBrushTipDraft())
        #expect(harness.viewModel.hasPendingBrushTipDraft == false)
        #expect(harness.viewModel.workspace.toolSession.brush.customTipMaskData == nil)
        #expect(harness.viewModel.workspace.toolSession.brush.customTipSourceSemantic == .procedural)
        #expect(harness.viewModel.strokeResetToken == committedStrokeResetToken + 1)
    }
}

@MainActor
private struct BrushEditingBoundaryHarness {
    let bootstrap: AppBootstrap
    let viewModel: WorkspaceViewModel

    init() throws {
        guard let metalContext = MetalDeviceContext() else {
            throw BoundaryHarnessError.metalUnavailable
        }
        let bootstrap = try AppBootstrap(
            workspaceStore: WorkspaceStore(),
            metalContext: metalContext,
            layerSurfaceStore: StageOneLayerSurfaceStore()
        )
        let viewModel = WorkspaceViewModel(bootstrap: bootstrap, installsZoomKeyboardMonitor: false)
        self.bootstrap = bootstrap
        self.viewModel = viewModel
    }

    func makePendingBrushCommit() throws {
        viewModel.beginStrokeIfNeeded()
        viewModel.applyStroke(
            samples: [
                .init(location: .init(x: 10, y: 10), pressure: 1),
                .init(location: .init(x: 18, y: 18), pressure: 1)
            ]
        )
        viewModel.endStroke()

        guard let commandBuffer = bootstrap.metalContext.commandQueue.makeCommandBuffer() else {
            throw BoundaryHarnessError.commandBufferUnavailable
        }
        _ = viewModel.flushPendingBrushWork(into: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        #expect(bootstrap.strokeEngine.hasPendingBrushCommitJobs)
    }

    func alpha(atX x: Int, y: Int) throws -> Float {
        try color(atX: x, y: y).alpha
    }

    func alpha(atX x: Int, y: Int, layerID: LayerID) throws -> Float {
        try color(atX: x, y: y, layerID: layerID).alpha
    }

    func color(atX x: Int, y: Int, layerID: LayerID? = nil) throws -> RGBAColor {
        let resolvedLayerID = layerID ?? viewModel.workspace.document.activeLayerID
        guard
            let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: resolvedLayerID),
            let texture = bootstrap.layerSurfaceStore.texture(for: surfaceID)
        else {
            throw BoundaryHarnessError.textureUnavailable
        }
        return try bootstrap.textureSerializer.samplePixel(texture: texture, x: x, y: y)
    }

    func colorAdjustmentPreviewColor(atX x: Int, y: Int) throws -> RGBAColor {
        let activeLayerID = viewModel.workspace.document.activeLayerID
        guard let texture = viewModel.brushDisplayTexture(for: activeLayerID) else {
            throw BoundaryHarnessError.textureUnavailable
        }
        return try bootstrap.textureSerializer.samplePixel(texture: texture, x: x, y: y)
    }

    func waitForSelectedReferenceImageSlotID(timeoutIterations: Int = 400) async throws -> Int {
        for _ in 0..<timeoutIterations {
            if let slotID = viewModel.selectedReferenceImageSlotID,
               viewModel.referenceImageSlots[slotID].asset != nil {
                return slotID
            }

            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }

        throw BoundaryHarnessError.referenceImageTimeout
    }

    func waitForReferenceImagePixelsChange(
        slotID: Int,
        from previousPixels: Data,
        timeoutIterations: Int = 400
    ) async throws {
        for _ in 0..<timeoutIterations {
            if let currentPixels = viewModel.referenceImageSlots[slotID].asset?.rgbaPixels,
               currentPixels != previousPixels {
                return
            }

            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }

        throw BoundaryHarnessError.referenceImageTimeout
    }
}

private enum BoundaryHarnessError: Error {
    case metalUnavailable
    case commandBufferUnavailable
    case textureUnavailable
    case referenceImageTimeout
}

@MainActor
private func makeWorkspaceViewModelForTipImportTests() throws -> WorkspaceViewModel {
    guard let metalContext = MetalDeviceContext() else {
        throw BoundaryHarnessError.metalUnavailable
    }
    let bootstrap = try AppBootstrap(
        workspaceStore: WorkspaceStore(),
        metalContext: metalContext,
        layerSurfaceStore: StageOneLayerSurfaceStore()
    )
    return WorkspaceViewModel(bootstrap: bootstrap, installsZoomKeyboardMonitor: false)
}

@MainActor
private func makeTemporaryTipImageURL(fileName: String, image: NSImage) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(fileName)
        .appendingPathExtension("png")
    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:])
    else {
        throw CocoaError(.fileWriteUnknown)
    }
    try png.write(to: url)
    return url
}

@MainActor
private func sampleActiveLayerAlpha(
    in viewModel: WorkspaceViewModel,
    serializer: LayerTextureSerializer,
    x: Int,
    y: Int
) throws -> Float {
    let activeLayerID = viewModel.workspace.document.activeLayerID
    guard
        let surfaceID = viewModel.layerSurfaceStore.surfaceID(for: activeLayerID),
        let texture = viewModel.layerSurfaceStore.texture(for: surfaceID)
    else {
        throw BoundaryHarnessError.textureUnavailable
    }

    return try serializer.samplePixel(texture: texture, x: x, y: y).alpha
}

@MainActor
private func fillOpaqueRect(
    in harness: BrushEditingBoundaryHarness,
    layerID: LayerID,
    originX: Int,
    originY: Int,
    width: Int,
    height: Int,
    color: RGBAColor
) throws {
    guard
        let surfaceID = harness.bootstrap.layerSurfaceStore.surfaceID(for: layerID),
        let texture = harness.bootstrap.layerSurfaceStore.texture(for: surfaceID)
    else {
        throw BoundaryHarnessError.textureUnavailable
    }

    let pixelCount = width * height
    let bgraPixel = [
        UInt8((color.blue * color.alpha * 255).rounded()),
        UInt8((color.green * color.alpha * 255).rounded()),
        UInt8((color.red * color.alpha * 255).rounded()),
        UInt8((color.alpha * 255).rounded())
    ]
    var bytes = [UInt8]()
    bytes.reserveCapacity(pixelCount * 4)
    for _ in 0..<pixelCount {
        bytes.append(contentsOf: bgraPixel)
    }

    let snapshot = LayerTextureSnapshot(
        width: width,
        height: height,
        bytesPerRow: width * 4,
        pixelData: Data(bytes)
    )
    try harness.bootstrap.textureSerializer.restore(
        snapshot: snapshot,
        into: texture,
        destinationX: originX,
        destinationY: originY
    )
}

@MainActor
private func makeRectangleSelection(
    in viewModel: WorkspaceViewModel,
    minX: Double,
    minY: Double,
    maxX: Double,
    maxY: Double
) {
    let start = CanvasPoint(x: minX, y: minY)
    let end = CanvasPoint(x: maxX, y: maxY)
    viewModel.selectTool(.rectangleSelection)
    viewModel.beginSelection(kind: .rectangle, at: start)
    viewModel.updateSelection(to: end)
    viewModel.commitSelection(at: end)
}

@MainActor
private func drawSingleMainCanvasStamp(
    in viewModel: WorkspaceViewModel,
    at point: CanvasPoint
) throws {
    viewModel.beginStrokeIfNeeded()
    viewModel.applyStroke(samples: [.init(location: point, pressure: 1)])
    viewModel.endStroke()

    guard let commandBuffer = viewModel.metalContext.commandQueue.makeCommandBuffer() else {
        throw BoundaryHarnessError.commandBufferUnavailable
    }

    _ = viewModel.flushPendingBrushWork(into: commandBuffer)
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
}

@MainActor
private func activeDisplayOpaqueBounds(
    in viewModel: WorkspaceViewModel,
    minX: Int,
    minY: Int,
    maxX: Int,
    maxY: Int,
    alphaThreshold: UInt8 = 8
) throws -> (width: Int, height: Int)? {
    let activeLayerID = viewModel.workspace.document.activeLayerID
    let serializer = LayerTextureSerializer(metalContext: viewModel.metalContext)

    guard
        let texture = viewModel.brushDisplayTexture(for: activeLayerID)
            ?? viewModel.layerSurfaceStore.surfaceID(for: activeLayerID)
            .flatMap(viewModel.layerSurfaceStore.texture(for:))
    else {
        throw BoundaryHarnessError.textureUnavailable
    }

    let snapshot = try serializer.snapshot(texture: texture)
    return opaqueBounds(
        in: snapshot,
        minX: minX,
        minY: minY,
        maxX: maxX,
        maxY: maxY,
        alphaThreshold: alphaThreshold
    )
}

private func opaqueBounds(
    in snapshot: LayerTextureSnapshot,
    minX: Int,
    minY: Int,
    maxX: Int,
    maxY: Int,
    alphaThreshold: UInt8
) -> (width: Int, height: Int)? {
    let clampedMinX = max(0, minX)
    let clampedMinY = max(0, minY)
    let clampedMaxX = min(snapshot.width - 1, maxX)
    let clampedMaxY = min(snapshot.height - 1, maxY)
    guard clampedMaxX >= clampedMinX, clampedMaxY >= clampedMinY else { return nil }

    var foundMinX = Int.max
    var foundMinY = Int.max
    var foundMaxX = Int.min
    var foundMaxY = Int.min

    snapshot.pixelData.withUnsafeBytes { rawBuffer in
        let bytes = rawBuffer.bindMemory(to: UInt8.self)
        for y in clampedMinY...clampedMaxY {
            let rowOffset = y * snapshot.bytesPerRow
            for x in clampedMinX...clampedMaxX {
                let alpha = bytes[rowOffset + (x * 4) + 3]
                guard alpha > alphaThreshold else { continue }
                foundMinX = min(foundMinX, x)
                foundMinY = min(foundMinY, y)
                foundMaxX = max(foundMaxX, x)
                foundMaxY = max(foundMaxY, y)
            }
        }
    }

    guard foundMaxX >= foundMinX, foundMaxY >= foundMinY else { return nil }
    return (
        width: foundMaxX - foundMinX + 1,
        height: foundMaxY - foundMinY + 1
    )
}

@MainActor
private func makeCircularTipSourceImage(size: Int = 96) -> NSImage {
    makeTipSourceImage(size: size) { context in
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillEllipse(in: CGRect(x: 18, y: 18, width: 60, height: 60))
    }
}

@MainActor
private func makeScatterTipSourceImage(size: Int = 96) -> NSImage {
    makeTipSourceImage(size: size) { context in
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        let circles: [CGRect] = [
            CGRect(x: 20, y: 56, width: 12, height: 12),
            CGRect(x: 34, y: 44, width: 10, height: 10),
            CGRect(x: 48, y: 30, width: 11, height: 11),
            CGRect(x: 58, y: 50, width: 13, height: 13),
            CGRect(x: 42, y: 62, width: 9, height: 9),
            CGRect(x: 30, y: 26, width: 10, height: 10)
        ]
        for rect in circles {
            context.fillEllipse(in: rect)
        }
    }
}

@MainActor
private func makeGuidedBlobTipSourceImage(size: Int = 96) -> NSImage {
    makeTipSourceImage(size: size) { context in
        context.setStrokeColor(CGColor(gray: 0.78, alpha: 1))
        context.setLineWidth(1)
        context.move(to: CGPoint(x: 6, y: 18))
        context.addLine(to: CGPoint(x: 90, y: 18))
        context.move(to: CGPoint(x: 6, y: 78))
        context.addLine(to: CGPoint(x: 90, y: 78))
        context.strokePath()

        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillEllipse(in: CGRect(x: 24, y: 34, width: 24, height: 20))
        context.fillEllipse(in: CGRect(x: 40, y: 38, width: 22, height: 20))
        context.fillEllipse(in: CGRect(x: 34, y: 24, width: 18, height: 18))
        context.fill(CGRect(x: 30, y: 32, width: 22, height: 12))
    }
}

@MainActor
private func makeTipSourceImage(size: Int, draw: (CGContext) -> Void) -> NSImage {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    var bytes = [UInt8](repeating: 255, count: size * size * 4)
    let bytesPerRow = size * 4
    let context = CGContext(
        data: &bytes,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    context.interpolationQuality = .high
    draw(context)
    let cgImage = context.makeImage()!
    return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
}

private func maskRowMasses(_ maskData: Data, resolution: Int) -> [Double] {
    let bytes = [UInt8](maskData)
    guard bytes.count == resolution * resolution else { return [] }
    var rows = [Double](repeating: 0, count: resolution)
    for y in 0..<resolution {
        let offset = y * resolution
        for x in 0..<resolution {
            rows[y] += Double(bytes[offset + x])
        }
    }
    return rows
}

@MainActor
private func waitForColorAdjustmentPreview(
    in harness: BrushEditingBoundaryHarness,
    timeoutIterations: Int = 200
) async throws {
    let activeLayerID = harness.viewModel.workspace.document.activeLayerID
    for _ in 0..<timeoutIterations {
        if harness.viewModel.brushDisplayTexture(for: activeLayerID) != nil,
           harness.viewModel.colorAdjustmentOverlayState.isActive {
            return
        }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(10))
    }
    throw BoundaryHarnessError.textureUnavailable
}

private func makeVerticalTipMask(side: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: side * side)
    let centerX = side / 2
    for y in 0..<side {
        bytes[(y * side) + centerX] = 255
    }
    return Data(bytes)
}

@MainActor
private func makeReferenceImageAsset(
    fileName: String,
    color: RGBAColor = .init(red: 0.25, green: 0.55, blue: 0.85, alpha: 1)
) -> ReferenceImageAsset {
    let width = 2
    let height = 2
    let red = UInt8(clamping: Int((color.red * color.alpha * 255).rounded()))
    let green = UInt8(clamping: Int((color.green * color.alpha * 255).rounded()))
    let blue = UInt8(clamping: Int((color.blue * color.alpha * 255).rounded()))
    let alpha = UInt8(clamping: Int((color.alpha * 255).rounded()))
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for index in stride(from: 0, to: bytes.count, by: 4) {
        bytes[index] = red
        bytes[index + 1] = green
        bytes[index + 2] = blue
        bytes[index + 3] = alpha
    }
    let rgbaPixels = Data(bytes)

    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let provider = CGDataProvider(data: rgbaPixels as CFData)!
    let cgImage = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: true,
        intent: .defaultIntent
    )!

    return ReferenceImageAsset(
        fileName: fileName,
        width: width,
        height: height,
        rgbaPixels: rgbaPixels,
        cgImage: cgImage
    )
}

@MainActor
private func makeCanvasKeyEvent(
    type: NSEvent.EventType,
    characters: String,
    charactersIgnoringModifiers: String,
    modifiers: NSEvent.ModifierFlags,
    keyCode: UInt16
) -> NSEvent {
    NSEvent.keyEvent(
        with: type,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: charactersIgnoringModifiers,
        isARepeat: false,
        keyCode: keyCode
    )!
}

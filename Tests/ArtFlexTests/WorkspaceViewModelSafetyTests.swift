import AppKit
import Combine
import Foundation
import Metal
import Testing
@testable import ArtFlex

struct WorkspaceViewModelSafetyTests {
    @Test
    @MainActor
    func quickColorPickerPreviewDoesNotPublishWholeWorkspaceAndStillCommits() throws {
        let harness = try BrushEditingBoundaryHarness()
        harness.viewModel.updateCanvasToolHover(to: .init(x: 120, y: 120))
        let keyDownHandled = harness.viewModel.handleKeyDown(
            makeCanvasKeyEvent(
                type: .keyDown,
                characters: "Z",
                charactersIgnoringModifiers: "z",
                modifiers: [.shift],
                keyCode: 6
            )
        )
        #expect(keyDownHandled)
        let initialState = try #require(harness.viewModel.quickColorPickerState)

        var workspacePublicationCount = 0
        let observation = harness.viewModel.objectWillChange.sink {
            workspacePublicationCount += 1
        }
        for index in 0..<240 {
            let progress = Float(index) / 239
            harness.viewModel.setQuickColorPickerHue(progress * 359)
            harness.viewModel.setQuickColorPickerPoint(x: progress, y: 1 - progress)
        }
        #expect(workspacePublicationCount == 0)

        var expectedPanel = initialState.panel
        expectedPanel.pickerHue = 359
        expectedPanel.pickerX = 1
        expectedPanel.pickerY = 0
        let expectedColor = ColorBlocksEngine.pickerColor(from: expectedPanel)
        let keyUpHandled = harness.viewModel.handleKeyUp(
            makeCanvasKeyEvent(
                type: .keyUp,
                characters: "Z",
                charactersIgnoringModifiers: "z",
                modifiers: [],
                keyCode: 6
            )
        )
        #expect(keyUpHandled)
        #expect(harness.viewModel.quickColorPickerState == nil)
        #expect(harness.viewModel.workspace.toolSession.selectedColor == expectedColor)
        _ = observation
    }

    @Test
    func recentBrushAdjustmentDefaultsToOneSelectionWhenRecentStrokesExist() {
        #expect(WorkspaceViewModel.resolvedRecentBrushAdjustmentSelectionCount(preferredCount: 0, limit: 0) == 0)
        #expect(WorkspaceViewModel.resolvedRecentBrushAdjustmentSelectionCount(preferredCount: 0, limit: 1) == 1)
        #expect(WorkspaceViewModel.resolvedRecentBrushAdjustmentSelectionCount(preferredCount: 0, limit: 7) == 1)
        #expect(WorkspaceViewModel.resolvedRecentBrushAdjustmentSelectionCount(preferredCount: 3, limit: 7) == 3)
        #expect(WorkspaceViewModel.resolvedRecentBrushAdjustmentSelectionCount(preferredCount: 12, limit: 7) == 7)
    }

    @Test
    func openingProjectKeepsGlobalBrushAndPatternLibraries() {
        var currentWorkspace = WorkspaceState.stageOneDefault
        currentWorkspace.brushLibrary = BrushLibraryState(
            presets: [
                BrushPreset(
                    id: "global-brush",
                    name: "Global Brush",
                    brush: .stageOneDefault,
                    isBuiltIn: false,
                    slotIndex: 0
                )
            ],
            selectedPresetID: "global-brush",
            recentPresetIDs: ["global-brush"]
        )
        let globalPatternID = UUID(uuidString: "00000000-0000-0000-0000-000000001001")!
        currentWorkspace.patternLibrary = PatternLibraryState(
            items: [
                PatternLibraryItem(
                    id: globalPatternID,
                    displayName: "Global Pattern",
                    slotIndex: 0,
                    importRecipe: PatternImportRecipe(),
                    originalFilename: "global.png",
                    sourcePixelWidth: 64,
                    sourcePixelHeight: 64,
                    renderAssetLocation: .managedCopy(relativePath: "renders/aa/global.png"),
                    thumbnailLocation: .managedCopy(relativePath: "thumbnails/aa/global.png")
                )
            ],
            selectedItemID: globalPatternID,
            recentItemIDs: [globalPatternID]
        )

        var openedWorkspace = WorkspaceState.stageOneDefault
        openedWorkspace.document.metadata.name = "Opened Project"
        openedWorkspace.brushLibrary = BrushLibraryState(
            presets: [
                BrushPreset(
                    id: "project-brush",
                    name: "Project Brush",
                    brush: .stageOneDefault,
                    isBuiltIn: false,
                    slotIndex: 0
                )
            ],
            selectedPresetID: "project-brush"
        )
        let projectPatternID = UUID(uuidString: "00000000-0000-0000-0000-000000001002")!
        openedWorkspace.patternLibrary = PatternLibraryState(
            items: [
                PatternLibraryItem(
                    id: projectPatternID,
                    displayName: "Project Pattern",
                    slotIndex: 0,
                    importRecipe: PatternImportRecipe(),
                    originalFilename: "project.png",
                    sourcePixelWidth: 64,
                    sourcePixelHeight: 64,
                    renderAssetLocation: .managedCopy(relativePath: "renders/bb/project.png"),
                    thumbnailLocation: .managedCopy(relativePath: "thumbnails/bb/project.png")
                )
            ],
            selectedItemID: projectPatternID
        )

        let resolvedWorkspace = WorkspaceViewModel.workspaceForOpenedProject(
            openedWorkspace,
            currentWorkspace: currentWorkspace
        )

        #expect(resolvedWorkspace.document.metadata.name == "Opened Project")
        #expect(resolvedWorkspace.brushLibrary == currentWorkspace.brushLibrary)
        #expect(resolvedWorkspace.patternLibrary == currentWorkspace.patternLibrary)
    }

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
    func navigatorDistinguishesFitZoomFromActualPixels() throws {
        let harness = try BrushEditingBoundaryHarness()
        harness.viewModel.updateCanvasViewportSize(.init(width: 1200, height: 900))

        harness.viewModel.fitCanvasToWindow()
        let fitPercent = harness.viewModel.navigatorZoomPercent
        #expect(fitPercent > 35)
        #expect(fitPercent < 45)

        harness.viewModel.setCanvasToActualPixels()
        #expect(abs(harness.viewModel.navigatorZoomPercent - 100) < 0.001)

        harness.viewModel.fitCanvasToWindow()
        #expect(abs(harness.viewModel.navigatorZoomPercent - fitPercent) < 0.001)
    }

    @Test
    @MainActor
    func toggleLayerTransparentPixelLockUpdatesActiveLayerState() throws {
        let harness = try BrushEditingBoundaryHarness()
        let activeLayerID = harness.viewModel.workspace.document.activeLayerID

        #expect(harness.viewModel.workspace.document.layers.first(where: { $0.id == activeLayerID })?.locksTransparentPixels == false)
        harness.viewModel.toggleLayerTransparentPixelLock(activeLayerID)
        #expect(harness.viewModel.workspace.document.layers.first(where: { $0.id == activeLayerID })?.locksTransparentPixels == true)
        #expect(harness.viewModel.status?.message == "已锁定透明像素")

        harness.viewModel.toggleLayerTransparentPixelLock(activeLayerID)
        #expect(harness.viewModel.workspace.document.layers.first(where: { $0.id == activeLayerID })?.locksTransparentPixels == false)
        #expect(harness.viewModel.status?.message == "已解除锁定透明像素")
    }

    @Test
    @MainActor
    func brushWithTransparentPixelLockPreservesSemitransparentAlpha() throws {
        let harness = try BrushEditingBoundaryHarness()
        let activeLayerID = harness.viewModel.workspace.document.activeLayerID
        let sampleX = 96
        let sampleY = 96

        try fillOpaqueRect(
            in: harness,
            layerID: activeLayerID,
            originX: 72,
            originY: 72,
            width: 48,
            height: 48,
            color: .init(red: 0.08, green: 0.12, blue: 0.72, alpha: 0.36)
        )
        let basePixel = try harness.color(atX: sampleX, y: sampleY, layerID: activeLayerID)

        harness.viewModel.setBrushSize(24)
        harness.viewModel.setSelectedColor(.init(red: 0.88, green: 0.08, blue: 0.04, alpha: 1))
        harness.viewModel.toggleLayerTransparentPixelLock(activeLayerID)
        try drawSingleMainCanvasStamp(in: harness.viewModel, at: .init(x: Double(sampleX), y: Double(sampleY)))
        _ = harness.viewModel.flushBrushEditingBoundary(reason: "test.transparentPixelLockBrush")

        let paintedPixel = try harness.color(atX: sampleX, y: sampleY, layerID: activeLayerID)
        #expect(abs(paintedPixel.alpha - basePixel.alpha) < 0.03)
        #expect(paintedPixel.red > basePixel.red + 0.04)
    }

    @Test
    @MainActor
    func selectionFillWithTransparentPixelLockPreservesSemitransparentAlpha() throws {
        let harness = try BrushEditingBoundaryHarness()
        let activeLayerID = harness.viewModel.workspace.document.activeLayerID
        let sampleX = 96
        let sampleY = 96

        try fillOpaqueRect(
            in: harness,
            layerID: activeLayerID,
            originX: 72,
            originY: 72,
            width: 48,
            height: 48,
            color: .init(red: 0.08, green: 0.12, blue: 0.72, alpha: 0.36)
        )
        let basePixel = try harness.color(atX: sampleX, y: sampleY, layerID: activeLayerID)

        makeRectangleSelection(in: harness.viewModel, minX: 80, minY: 80, maxX: 112, maxY: 112)
        harness.viewModel.setSelectedColor(.init(red: 0.88, green: 0.08, blue: 0.04, alpha: 1))
        harness.viewModel.toggleLayerTransparentPixelLock(activeLayerID)
        harness.viewModel.fillSelectionContents()

        let filledPixel = try harness.color(atX: sampleX, y: sampleY, layerID: activeLayerID)
        #expect(abs(filledPixel.alpha - basePixel.alpha) < 0.03)
        #expect(filledPixel.red > basePixel.red + 0.04)
    }

    @Test
    @MainActor
    func bucketFillWithTransparentPixelLockPreservesSemitransparentAlpha() throws {
        let harness = try BrushEditingBoundaryHarness()
        let activeLayerID = harness.viewModel.workspace.document.activeLayerID
        let sampleX = 96
        let sampleY = 96

        try fillOpaqueRect(
            in: harness,
            layerID: activeLayerID,
            originX: 72,
            originY: 72,
            width: 48,
            height: 48,
            color: .init(red: 0.08, green: 0.12, blue: 0.72, alpha: 0.36)
        )
        let basePixel = try harness.color(atX: sampleX, y: sampleY, layerID: activeLayerID)

        harness.viewModel.setSelectedColor(.init(red: 0.88, green: 0.08, blue: 0.04, alpha: 1))
        harness.viewModel.toggleLayerTransparentPixelLock(activeLayerID)
        harness.viewModel.fillAtPoint(.init(x: Double(sampleX), y: Double(sampleY)))

        let filledPixel = try harness.color(atX: sampleX, y: sampleY, layerID: activeLayerID)
        #expect(abs(filledPixel.alpha - basePixel.alpha) < 0.03)
        #expect(filledPixel.red > basePixel.red + 0.04)
    }

    @Test
    @MainActor
    func requestedBucketFillCompletesWithoutBlockingTheCallingInteraction() async throws {
        let harness = try BrushEditingBoundaryHarness()
        let activeLayerID = harness.viewModel.workspace.document.activeLayerID
        harness.viewModel.setSelectedColor(.init(red: 0.82, green: 0.08, blue: 0.04, alpha: 1))

        harness.viewModel.requestFillAtPoint(.init(x: 12, y: 12))

        #expect(harness.viewModel.isBucketFillInProgress)
        for _ in 0..<500 where harness.viewModel.isBucketFillInProgress {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(harness.viewModel.isBucketFillInProgress == false)
        let pixel = try harness.color(atX: 12, y: 12, layerID: activeLayerID)
        #expect(pixel.red > 0.75)
        #expect(pixel.green < 0.15)
        #expect(harness.viewModel.canUndo)
    }

    @Test
    @MainActor
    func layerOpacityDragPublishesOneContentChangeWithoutInvalidatingThumbnails() throws {
        let harness = try BrushEditingBoundaryHarness()
        let initialContentRevision = harness.viewModel.canvasContentRevision
        let initialThumbnailRevision = harness.viewModel.layerThumbnailRevision

        harness.viewModel.beginActiveLayerOpacityChange()
        harness.viewModel.setActiveLayerOpacity(0.8)
        harness.viewModel.setActiveLayerOpacity(0.6)
        harness.viewModel.setActiveLayerOpacity(0.4)

        #expect(harness.viewModel.canvasContentRevision == initialContentRevision)
        #expect(harness.viewModel.layerThumbnailRevision == initialThumbnailRevision)

        harness.viewModel.endActiveLayerOpacityChange()

        #expect(harness.viewModel.canvasContentRevision == initialContentRevision + 1)
        #expect(harness.viewModel.layerThumbnailRevision == initialThumbnailRevision)
        let activeLayerID = harness.viewModel.workspace.document.activeLayerID
        #expect(
            harness.viewModel.workspace.document.layers.first(where: { $0.id == activeLayerID })?.opacity == 0.4
        )
    }

    @Test
    @MainActor
    func unchangedLayerOpacityInteractionDoesNotCreateUndoHistory() throws {
        let harness = try BrushEditingBoundaryHarness()
        #expect(harness.viewModel.canUndo == false)

        harness.viewModel.beginActiveLayerOpacityChange()
        harness.viewModel.setActiveLayerOpacity(1)
        harness.viewModel.endActiveLayerOpacityChange()

        #expect(harness.viewModel.canUndo == false)
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
    func eyedropperCanReturnToPreviousToolAfterSuccessfulSample() throws {
        let harness = try BrushEditingBoundaryHarness()
        harness.viewModel.selectTool(.smudge)
        harness.viewModel.selectTool(.eyedropper)

        harness.viewModel.sampleColor(at: .init(x: 10, y: 10))
        #expect(harness.viewModel.workspace.toolSession.activeTool == .eyedropper)

        harness.viewModel.selectTool(.smudge)
        harness.viewModel.selectTool(.eyedropper)
        harness.viewModel.setEyedropperReturnsToPreviousTool(true)
        harness.viewModel.sampleColor(at: .init(x: 10, y: 10))

        #expect(harness.viewModel.workspace.toolSession.activeTool == .smudge)
        #expect(harness.viewModel.workspace.toolSession.selectedColor.red > 0.99)
        #expect(harness.viewModel.workspace.toolSession.selectedColor.green > 0.99)
        #expect(harness.viewModel.workspace.toolSession.selectedColor.blue > 0.99)
    }

    @Test
    @MainActor
    func reselectingCurrentToolKeepsItsInProgressInteraction() throws {
        let harness = try BrushEditingBoundaryHarness()
        harness.viewModel.selectTool(.straightLine)
        harness.viewModel.beginStraightLineDrag(at: .init(x: 20, y: 30))

        harness.viewModel.selectToolFromUI(.straightLine)

        guard case .drawingLine = harness.viewModel.straightLineState.phase else {
            Issue.record("Reselecting the current tool unexpectedly cleared its draft")
            return
        }
        #expect(harness.viewModel.straightLineState.pointA == .init(x: 20, y: 30))
    }

    @Test
    @MainActor
    func straightLineDragStaysEditableUntilPointerExitAndKeepsAdjustedSize() throws {
        let harness = try BrushEditingBoundaryHarness()
        harness.viewModel.selectTool(.straightLine)
        harness.viewModel.setBrushSize(12)

        harness.viewModel.beginStraightLineDrag(at: .init(x: 10, y: 32))
        harness.viewModel.updateStraightLineDrag(along: [.init(x: 56, y: 32)])
        harness.viewModel.endStraightLineDrag(at: .init(x: 56, y: 32))

        #expect(harness.viewModel.straightLineState.phase == .pending)
        #expect(try harness.alpha(atX: 32, y: 32) < 0.01)

        harness.viewModel.setBrushSize(40)
        #expect(harness.viewModel.straightLineState.phase == .pending)
        #expect(harness.viewModel.workspace.toolSession.brush.size == 40)
        harness.viewModel.handleCanvasPointerExit()
        #expect(harness.viewModel.straightLineState.phase == .idle)
        _ = harness.viewModel.flushBrushEditingBoundary(reason: "straightLine.test")

        #expect(try harness.alpha(atX: 32, y: 32) > 0.9)
        harness.viewModel.beginStraightLineDrag(at: .init(x: 10, y: 64))
        #expect(harness.viewModel.straightLineState.baseBrushSize == 40)
    }

    @Test
    @MainActor
    func asyncLayerThumbnailReloadsAfterLayerContentInvalidation() async throws {
        let harness = try BrushEditingBoundaryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID

        let initialImage = try #require(
            await harness.viewModel.loadLayerThumbnail(for: layerID, maxDimension: 36)
        )
        #expect(initialImage.width == 36)
        #expect(initialImage.height == 36)

        let initialRevision = harness.viewModel.layerThumbnailRevision
        harness.viewModel.fillAtPoint(.init(x: 24, y: 24))
        #expect(harness.viewModel.layerThumbnailRevision > initialRevision)

        let updatedImage = try #require(
            await harness.viewModel.loadLayerThumbnail(for: layerID, maxDimension: 36)
        )
        #expect(updatedImage.width == 36)
        #expect(updatedImage.height == 36)
    }

    @Test
    @MainActor
    func layerAndToolMetadataChangesDoNotInvalidatePixelThumbnails() throws {
        let harness = try BrushEditingBoundaryHarness()
        let layerID = harness.viewModel.workspace.document.activeLayerID
        let initialRevision = harness.viewModel.layerThumbnailRevision

        harness.viewModel.selectTool(.eraser)
        harness.viewModel.toggleLayerLock(layerID)
        harness.viewModel.toggleLayerTransparentPixelLock(layerID)
        harness.viewModel.setLayerVisibility(layerID, isVisible: false)
        harness.viewModel.renameLayer(layerID, to: "Renamed")

        #expect(harness.viewModel.layerThumbnailRevision == initialRevision)
        #expect(harness.viewModel.workspace.toolSession.activeTool == .eraser)
        #expect(harness.viewModel.workspace.document.layers.first(where: { $0.id == layerID })?.name == "Renamed")
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
    func selectingNonBrushToolBakesRecentBrushAdjustmentIntoLayerPixels() throws {
        let harness = try BrushEditingBoundaryHarness()
        let activeLayerID = harness.viewModel.workspace.document.activeLayerID

        try enqueueRecentBrushAdjustmentStroke(
            in: harness,
            point: .init(location: .init(x: 96, y: 96), pressure: 1)
        )
        try enqueueRecentBrushAdjustmentStroke(
            in: harness,
            point: .init(location: .init(x: 320, y: 320), pressure: 1)
        )

        harness.viewModel.setQuickColorPickerRecentBrushSelectionCount(1)
        harness.viewModel.setQuickColorPickerRecentBrushOpacity(0.2)

        #expect(harness.bootstrap.strokeEngine.hasPendingBrushCommitJobs)
        #expect(harness.viewModel.brushDisplayTexture(for: activeLayerID) != nil)

        harness.viewModel.selectTool(.eraser)

        let earlierStrokeAlpha = try harness.alpha(atX: 96, y: 96, layerID: activeLayerID)
        let adjustedRecentStrokeAlpha = try harness.alpha(atX: 320, y: 320, layerID: activeLayerID)

        #expect(harness.viewModel.workspace.toolSession.activeTool == .eraser)
        #expect(harness.bootstrap.strokeEngine.hasPendingBrushCommitJobs == false)
        #expect(earlierStrokeAlpha > 0.25)
        #expect(adjustedRecentStrokeAlpha > 0.01)
        #expect(adjustedRecentStrokeAlpha < earlierStrokeAlpha * 0.5)
        #expect(harness.viewModel.brushDisplayTexture(for: activeLayerID) == nil)
    }

    @Test
    @MainActor
    func undoAfterForcedDrainOfMultiplePendingBrushCommitsRevertsOneStrokePerUndo() throws {
        let harness = try BrushEditingBoundaryHarness()
        let activeLayerID = harness.viewModel.workspace.document.activeLayerID

        try enqueueRecentBrushAdjustmentStroke(
            in: harness,
            point: .init(location: .init(x: 96, y: 96), pressure: 1)
        )
        try enqueueRecentBrushAdjustmentStroke(
            in: harness,
            point: .init(location: .init(x: 320, y: 320), pressure: 1)
        )

        #expect(harness.bootstrap.strokeEngine.hasPendingBrushCommitJobs)

        harness.viewModel.undo()

        let earlierStrokeAlphaAfterFirstUndo = try harness.alpha(atX: 96, y: 96, layerID: activeLayerID)
        let recentStrokeAlphaAfterFirstUndo = try harness.alpha(atX: 320, y: 320, layerID: activeLayerID)

        #expect(harness.bootstrap.strokeEngine.hasPendingBrushCommitJobs == false)
        #expect(earlierStrokeAlphaAfterFirstUndo > 0.25)
        #expect(recentStrokeAlphaAfterFirstUndo < 0.01)

        harness.viewModel.undo()

        let earlierStrokeAlphaAfterSecondUndo = try harness.alpha(atX: 96, y: 96, layerID: activeLayerID)
        #expect(earlierStrokeAlphaAfterSecondUndo < 0.01)
    }

    @Test
    @MainActor
    func startingNewBrushStrokeBakesRecentBrushAdjustmentSuffixBeforeContinuing() throws {
        let harness = try BrushEditingBoundaryHarness()
        let activeLayerID = harness.viewModel.workspace.document.activeLayerID

        try enqueueRecentBrushAdjustmentStroke(
            in: harness,
            point: .init(location: .init(x: 96, y: 96), pressure: 1)
        )
        try enqueueRecentBrushAdjustmentStroke(
            in: harness,
            point: .init(location: .init(x: 320, y: 320), pressure: 1)
        )

        harness.viewModel.setQuickColorPickerRecentBrushSelectionCount(1)
        harness.viewModel.setQuickColorPickerRecentBrushOpacity(0.2)

        #expect(harness.bootstrap.strokeEngine.hasPendingBrushCommitJobs)

        harness.viewModel.beginStrokeIfNeeded()

        let earlierStrokeAlpha = try harness.alpha(atX: 96, y: 96, layerID: activeLayerID)
        let adjustedRecentStrokeAlpha = try harness.alpha(atX: 320, y: 320, layerID: activeLayerID)

        #expect(harness.bootstrap.strokeEngine.hasPendingBrushCommitJobs == false)
        #expect(earlierStrokeAlpha > 0.25)
        #expect(adjustedRecentStrokeAlpha > 0.01)
        #expect(adjustedRecentStrokeAlpha < earlierStrokeAlpha * 0.5)
    }

    @Test
    @MainActor
    func selectingDifferentLayerBakesRecentBrushAdjustmentIntoPreviousLayerPixels() throws {
        let harness = try BrushEditingBoundaryHarness()
        let originalLayerID = harness.viewModel.workspace.document.activeLayerID

        harness.viewModel.addLayer()
        let secondaryLayerID = harness.viewModel.workspace.document.activeLayerID
        harness.viewModel.selectLayer(originalLayerID)

        try enqueueRecentBrushAdjustmentStroke(
            in: harness,
            point: .init(location: .init(x: 96, y: 96), pressure: 1)
        )
        try enqueueRecentBrushAdjustmentStroke(
            in: harness,
            point: .init(location: .init(x: 320, y: 320), pressure: 1)
        )

        harness.viewModel.setQuickColorPickerRecentBrushSelectionCount(1)
        harness.viewModel.setQuickColorPickerRecentBrushOpacity(0.2)

        #expect(harness.bootstrap.strokeEngine.hasPendingBrushCommitJobs)

        harness.viewModel.selectLayer(secondaryLayerID)

        let earlierStrokeAlpha = try harness.alpha(atX: 96, y: 96, layerID: originalLayerID)
        let adjustedRecentStrokeAlpha = try harness.alpha(atX: 320, y: 320, layerID: originalLayerID)

        #expect(harness.viewModel.workspace.document.activeLayerID == secondaryLayerID)
        #expect(harness.bootstrap.strokeEngine.hasPendingBrushCommitJobs == false)
        #expect(earlierStrokeAlpha > 0.25)
        #expect(adjustedRecentStrokeAlpha > 0.01)
        #expect(adjustedRecentStrokeAlpha < earlierStrokeAlpha * 0.5)
    }

    @Test
    @MainActor
    func recentBrushAdjustmentSettersIgnoreNoOpValuesToAvoidExtraRedrawChurn() throws {
        let harness = try BrushEditingBoundaryHarness()

        try enqueueRecentBrushAdjustmentStroke(
            in: harness,
            point: .init(location: .init(x: 96, y: 96), pressure: 1)
        )
        try enqueueRecentBrushAdjustmentStroke(
            in: harness,
            point: .init(location: .init(x: 320, y: 320), pressure: 1)
        )

        harness.viewModel.setQuickColorPickerRecentBrushSelectionCount(1)
        harness.viewModel.setQuickColorPickerRecentBrushOpacity(0.6)

        let redrawRevisionAfterAdjustment = harness.viewModel.recentBrushAdjustmentRedrawRevision

        harness.viewModel.setQuickColorPickerRecentBrushSelectionCount(1)
        harness.viewModel.setQuickColorPickerRecentBrushOpacity(0.6)
        harness.viewModel.setQuickColorPickerRecentBrushBrightness(0)
        harness.viewModel.setQuickColorPickerRecentBrushSaturation(0)
        harness.viewModel.setQuickColorPickerRecentBrushSelectionEditing(false)
        harness.viewModel.setQuickColorPickerRecentBrushOpacityEditing(false)

        #expect(harness.viewModel.recentBrushAdjustmentRedrawRevision == redrawRevisionAfterAdjustment)
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
    func brushPresetShortcutWhileColorAdjustmentToolIsActiveKeepsToolSelected() throws {
        let harness = try BrushEditingBoundaryHarness()

        harness.viewModel.selectTool(.brightnessAdjust)
        harness.viewModel.saveCurrentBrushPreset()

        let handled = harness.viewModel.handleKeyDown(
            makeCanvasKeyEvent(type: .keyDown, characters: "1", charactersIgnoringModifiers: "1", modifiers: [], keyCode: 18)
        )

        #expect(handled == true)
        #expect(harness.viewModel.workspace.toolSession.activeTool == .brightnessAdjust)
    }

    @Test
    @MainActor
    func colorAdjustmentBrightnessPreviewKeepsPaintedMaskSession() async throws {
        let harness = try BrushEditingBoundaryHarness()
        let activeLayerID = harness.viewModel.workspace.document.activeLayerID

        try fillOpaqueRect(
            in: harness,
            layerID: activeLayerID,
            originX: 48,
            originY: 48,
            width: 120,
            height: 120,
            color: .init(red: 0.24, green: 0.28, blue: 0.32, alpha: 1)
        )

        harness.viewModel.selectTool(.brightnessAdjust)
        harness.viewModel.beginStrokeIfNeeded()
        harness.viewModel.applyStroke(samples: [
            .init(location: .init(x: 96, y: 96), pressure: 1),
            .init(location: .init(x: 112, y: 112), pressure: 1)
        ])
        harness.viewModel.endStroke()

        try await waitForColorAdjustmentPreview(in: harness)

        let basePixel = try harness.color(atX: 104, y: 104, layerID: activeLayerID)
        let baselineRevision = harness.viewModel.colorAdjustmentRedrawRevision
        harness.viewModel.setColorAdjustmentBrightness(0.55)
        try await waitForColorAdjustmentRedrawRevision(in: harness, after: baselineRevision)

        let previewPixel = try harness.colorAdjustmentPreviewColor(atX: 104, y: 104)
        #expect(previewPixel.red > basePixel.red + 0.05)
        #expect(previewPixel.green > basePixel.green + 0.05)
        #expect(previewPixel.blue > basePixel.blue + 0.05)
        #expect(abs(harness.viewModel.colorAdjustmentParameters.brightness - 0.55) < 0.001)

        guard let session = harness.viewModel.colorAdjustmentSession else {
            Issue.record("Expected active color adjustment session")
            return
        }

        switch session.source {
        case .painted(let paintedState):
            #expect(paintedState.paintedBounds != nil)
        case .selection, .wholeLayer:
            Issue.record("Expected painted mask session during stage B")
        }
    }

    @Test
    @MainActor
    func colorAdjustmentPaintingMoreMaskKeepsParametersApplied() async throws {
        let harness = try BrushEditingBoundaryHarness()
        let activeLayerID = harness.viewModel.workspace.document.activeLayerID

        try fillOpaqueRect(
            in: harness,
            layerID: activeLayerID,
            originX: 40,
            originY: 40,
            width: 160,
            height: 160,
            color: .init(red: 0.22, green: 0.26, blue: 0.3, alpha: 1)
        )

        harness.viewModel.selectTool(.brightnessAdjust)
        harness.viewModel.beginStrokeIfNeeded()
        harness.viewModel.applyStroke(samples: [.init(location: .init(x: 84, y: 84), pressure: 1)])
        harness.viewModel.endStroke()
        try await waitForColorAdjustmentPreview(in: harness)

        let parameterRevision = harness.viewModel.colorAdjustmentRedrawRevision
        harness.viewModel.setColorAdjustmentBrightness(0.65)
        try await waitForColorAdjustmentRedrawRevision(in: harness, after: parameterRevision)

        let targetPoint = CanvasPoint(x: 152, y: 152)
        let basePixel = try harness.color(atX: Int(targetPoint.x), y: Int(targetPoint.y), layerID: activeLayerID)
        let repaintRevision = harness.viewModel.colorAdjustmentRedrawRevision
        harness.viewModel.beginStrokeIfNeeded()
        harness.viewModel.applyStroke(samples: [.init(location: targetPoint, pressure: 1)])
        harness.viewModel.endStroke()
        try await waitForColorAdjustmentRedrawRevision(in: harness, after: repaintRevision)

        let previewPixel = try harness.colorAdjustmentPreviewColor(atX: Int(targetPoint.x), y: Int(targetPoint.y))
        #expect(previewPixel.red > basePixel.red + 0.05)
        #expect(previewPixel.green > basePixel.green + 0.05)
        #expect(previewPixel.blue > basePixel.blue + 0.05)
        #expect(abs(harness.viewModel.colorAdjustmentParameters.brightness - 0.65) < 0.001)
    }

    @Test
    @MainActor
    func colorAdjustmentResetDefaultsKeepsPaintedMaskOverlayVisible() async throws {
        let harness = try BrushEditingBoundaryHarness()
        let activeLayerID = harness.viewModel.workspace.document.activeLayerID

        try fillOpaqueRect(
            in: harness,
            layerID: activeLayerID,
            originX: 48,
            originY: 48,
            width: 120,
            height: 120,
            color: .init(red: 0.3, green: 0.3, blue: 0.3, alpha: 1)
        )

        harness.viewModel.selectTool(.brightnessAdjust)
        harness.viewModel.beginStrokeIfNeeded()
        harness.viewModel.applyStroke(samples: [.init(location: .init(x: 96, y: 96), pressure: 1)])
        harness.viewModel.endStroke()
        try await waitForColorAdjustmentPreview(in: harness)

        let adjustmentRevision = harness.viewModel.colorAdjustmentRedrawRevision
        harness.viewModel.setColorAdjustmentBrightness(0.7)
        try await waitForColorAdjustmentRedrawRevision(in: harness, after: adjustmentRevision)

        let resetRevision = harness.viewModel.colorAdjustmentRedrawRevision
        harness.viewModel.resetColorAdjustmentParameters()
        try await waitForColorAdjustmentRedrawRevision(in: harness, after: resetRevision)

        let previewPixel = try harness.colorAdjustmentPreviewColor(atX: 96, y: 96)
        #expect(harness.viewModel.colorAdjustmentParameters.isNeutral)
        #expect(previewPixel.blue > previewPixel.red)
        #expect(previewPixel.blue > previewPixel.green)

        guard let session = harness.viewModel.colorAdjustmentSession else {
            Issue.record("Expected active color adjustment session after reset")
            return
        }

        switch session.source {
        case .painted(let paintedState):
            #expect(paintedState.paintedBounds != nil)
        case .selection, .wholeLayer:
            Issue.record("Expected painted mask session during stage B")
        }
    }

    @Test
    @MainActor
    func colorAdjustmentHoldPreviewTemporarilyShowsOriginalLayer() async throws {
        let harness = try BrushEditingBoundaryHarness()
        let activeLayerID = harness.viewModel.workspace.document.activeLayerID

        try fillOpaqueRect(
            in: harness,
            layerID: activeLayerID,
            originX: 48,
            originY: 48,
            width: 120,
            height: 120,
            color: .init(red: 0.24, green: 0.24, blue: 0.24, alpha: 1)
        )

        harness.viewModel.selectTool(.brightnessAdjust)
        harness.viewModel.beginStrokeIfNeeded()
        harness.viewModel.applyStroke(samples: [.init(location: .init(x: 96, y: 96), pressure: 1)])
        harness.viewModel.endStroke()
        try await waitForColorAdjustmentPreview(in: harness)

        let adjustmentRevision = harness.viewModel.colorAdjustmentRedrawRevision
        harness.viewModel.setColorAdjustmentContrast(0.6)
        try await waitForColorAdjustmentRedrawRevision(in: harness, after: adjustmentRevision)

        #expect(harness.viewModel.brushDisplayTexture(for: activeLayerID) != nil)
        harness.viewModel.setColorAdjustmentShowsOriginalPreview(true)
        #expect(harness.viewModel.colorAdjustmentOverlayState.showsOriginalPreview)
        #expect(harness.viewModel.brushDisplayTexture(for: activeLayerID) == nil)

        harness.viewModel.setColorAdjustmentShowsOriginalPreview(false)
        #expect(harness.viewModel.colorAdjustmentOverlayState.showsOriginalPreview == false)
        #expect(harness.viewModel.brushDisplayTexture(for: activeLayerID) != nil)
    }

    @Test
    @MainActor
    func colorAdjustmentSelectionPreviewUsesCommittedSelectionWithoutPainting() async throws {
        let harness = try BrushEditingBoundaryHarness()
        let activeLayerID = harness.viewModel.workspace.document.activeLayerID
        let insideSelectionX = 96
        let insideSelectionY = 96
        let outsideSelectionX = 150
        let outsideSelectionY = 150

        try fillOpaqueRect(
            in: harness,
            layerID: activeLayerID,
            originX: 48,
            originY: 48,
            width: 140,
            height: 140,
            color: .init(red: 0.24, green: 0.28, blue: 0.32, alpha: 1)
        )
        makeRectangleSelection(
            in: harness.viewModel,
            minX: 72,
            minY: 72,
            maxX: 124,
            maxY: 124
        )

        let insideBasePixel = try harness.color(atX: insideSelectionX, y: insideSelectionY, layerID: activeLayerID)
        let outsideBasePixel = try harness.color(atX: outsideSelectionX, y: outsideSelectionY, layerID: activeLayerID)

        #expect(harness.viewModel.workspace.toolSession.activeTool == .rectangleSelection)
        harness.viewModel.setColorAdjustmentBrightness(0.55)
        try await waitForColorAdjustmentPreview(in: harness)

        let insidePreviewPixel = try harness.colorAdjustmentPreviewColor(atX: insideSelectionX, y: insideSelectionY)
        let outsidePreviewPixel = try harness.colorAdjustmentPreviewColor(atX: outsideSelectionX, y: outsideSelectionY)
        #expect(insidePreviewPixel.red > insideBasePixel.red + 0.05)
        #expect(insidePreviewPixel.green > insideBasePixel.green + 0.05)
        #expect(insidePreviewPixel.blue > insideBasePixel.blue + 0.05)
        #expect(abs(outsidePreviewPixel.red - outsideBasePixel.red) < 0.02)
        #expect(abs(outsidePreviewPixel.green - outsideBasePixel.green) < 0.02)
        #expect(abs(outsidePreviewPixel.blue - outsideBasePixel.blue) < 0.02)
        #expect(harness.viewModel.colorAdjustmentOverlayState.sourceKind == .selection)
        #expect(harness.viewModel.selectionOverlayProxy.isHiddenForTransientAdjustment)

        guard let session = harness.viewModel.colorAdjustmentSession else {
            Issue.record("Expected selection color adjustment session")
            return
        }

        switch session.source {
        case .selection:
            break
        case .painted, .wholeLayer:
            Issue.record("Expected committed selection source")
        }
    }

    @Test
    @MainActor
    func colorAdjustmentSelectionSessionRebuildsWhenCommittedSelectionChanges() async throws {
        let harness = try BrushEditingBoundaryHarness()
        let activeLayerID = harness.viewModel.workspace.document.activeLayerID
        let firstSelectionX = 92
        let firstSelectionY = 92
        let secondSelectionX = 152
        let secondSelectionY = 152

        try fillOpaqueRect(
            in: harness,
            layerID: activeLayerID,
            originX: 48,
            originY: 48,
            width: 140,
            height: 140,
            color: .init(red: 0.24, green: 0.28, blue: 0.32, alpha: 1)
        )
        makeRectangleSelection(
            in: harness.viewModel,
            minX: 72,
            minY: 72,
            maxX: 116,
            maxY: 116
        )

        let firstBasePixel = try harness.color(atX: firstSelectionX, y: firstSelectionY, layerID: activeLayerID)
        let secondBasePixel = try harness.color(atX: secondSelectionX, y: secondSelectionY, layerID: activeLayerID)

        harness.viewModel.setColorAdjustmentBrightness(0.55)
        try await waitForColorAdjustmentPreview(in: harness)

        let baselineRevision = harness.viewModel.colorAdjustmentRedrawRevision
        makeRectangleSelection(
            in: harness.viewModel,
            minX: 136,
            minY: 136,
            maxX: 172,
            maxY: 172
        )
        try await waitForColorAdjustmentRedrawRevision(
            in: harness,
            after: baselineRevision
        )

        let firstPreviewPixel = try harness.colorAdjustmentPreviewColor(atX: firstSelectionX, y: firstSelectionY)
        let secondPreviewPixel = try harness.colorAdjustmentPreviewColor(atX: secondSelectionX, y: secondSelectionY)
        #expect(abs(firstPreviewPixel.red - firstBasePixel.red) < 0.02)
        #expect(abs(firstPreviewPixel.green - firstBasePixel.green) < 0.02)
        #expect(abs(firstPreviewPixel.blue - firstBasePixel.blue) < 0.02)
        #expect(secondPreviewPixel.red > secondBasePixel.red + 0.05)
        #expect(secondPreviewPixel.green > secondBasePixel.green + 0.05)
        #expect(secondPreviewPixel.blue > secondBasePixel.blue + 0.05)

        guard let session = harness.viewModel.colorAdjustmentSession else {
            Issue.record("Expected rebuilt selection color adjustment session")
            return
        }
        switch session.source {
        case .selection(let selectionState):
            #expect(selectionState.capturedSelectionRevision == harness.viewModel.selectionRevision)
            #expect(selectionState.capturedSelectionShape.bounds.origin.x > 130)
        case .painted, .wholeLayer:
            Issue.record("Expected rebuilt selection source")
        }
    }

    @Test
    @MainActor
    func colorAdjustmentWholeLayerPreviewUsesActiveLayerWithoutPainting() async throws {
        let harness = try BrushEditingBoundaryHarness()
        let activeLayerID = harness.viewModel.workspace.document.activeLayerID
        let opaqueX = 96
        let opaqueY = 96
        let transparentX = 16
        let transparentY = 16

        try fillOpaqueRect(
            in: harness,
            layerID: activeLayerID,
            originX: 48,
            originY: 48,
            width: 120,
            height: 120,
            color: .init(red: 0.24, green: 0.28, blue: 0.32, alpha: 1)
        )

        let opaqueBasePixel = try harness.color(atX: opaqueX, y: opaqueY, layerID: activeLayerID)
        let transparentBasePixel = try harness.color(atX: transparentX, y: transparentY, layerID: activeLayerID)

        #expect(harness.viewModel.workspace.toolSession.activeTool != .brightnessAdjust)
        harness.viewModel.setColorAdjustmentBrightness(0.55)
        try await waitForColorAdjustmentPreview(in: harness)

        let opaquePreviewPixel = try harness.colorAdjustmentPreviewColor(atX: opaqueX, y: opaqueY)
        let transparentPreviewPixel = try harness.colorAdjustmentPreviewColor(atX: transparentX, y: transparentY)
        #expect(opaquePreviewPixel.red > opaqueBasePixel.red + 0.05)
        #expect(opaquePreviewPixel.green > opaqueBasePixel.green + 0.05)
        #expect(opaquePreviewPixel.blue > opaqueBasePixel.blue + 0.05)
        #expect(abs(transparentPreviewPixel.alpha - transparentBasePixel.alpha) < 0.02)
        #expect(harness.viewModel.colorAdjustmentOverlayState.sourceKind == .wholeLayer)

        guard let session = harness.viewModel.colorAdjustmentSession else {
            Issue.record("Expected whole-layer color adjustment session")
            return
        }

        switch session.source {
        case .wholeLayer:
            break
        case .painted, .selection:
            Issue.record("Expected whole-layer source")
        }
    }

    @Test
    @MainActor
    func colorAdjustmentWholeLayerPreviewOverridesRetainedBrushDisplayTexture() async throws {
        let harness = try BrushEditingBoundaryHarness()
        let activeLayerID = harness.viewModel.workspace.document.activeLayerID
        let opaqueX = 96
        let opaqueY = 96

        try fillOpaqueRect(
            in: harness,
            layerID: activeLayerID,
            originX: 48,
            originY: 48,
            width: 120,
            height: 120,
            color: .init(red: 0.24, green: 0.28, blue: 0.32, alpha: 1)
        )

        try drawSingleMainCanvasStamp(in: harness.viewModel, at: .init(x: 180, y: 180))
        #expect(harness.bootstrap.strokeEngine.displayTexture(for: activeLayerID) != nil)

        let opaqueBasePixel = try harness.color(atX: opaqueX, y: opaqueY, layerID: activeLayerID)
        harness.viewModel.setColorAdjustmentBrightness(0.55)
        try await waitForColorAdjustmentPreview(in: harness)

        let opaquePreviewPixel = try harness.colorAdjustmentPreviewColor(atX: opaqueX, y: opaqueY)
        #expect(opaquePreviewPixel.red > opaqueBasePixel.red + 0.05)
        #expect(opaquePreviewPixel.green > opaqueBasePixel.green + 0.05)
        #expect(opaquePreviewPixel.blue > opaqueBasePixel.blue + 0.05)
    }

    @Test
    @MainActor
    func colorAdjustmentWholeLayerPreviewFlushesPendingBrushCommitAndInvalidatesStaleBoundsCache() async throws {
        let harness = try BrushEditingBoundaryHarness()
        let activeLayerID = harness.viewModel.workspace.document.activeLayerID
        let freshStrokeX = 180
        let freshStrokeY = 180

        try fillOpaqueRect(
            in: harness,
            layerID: activeLayerID,
            originX: 48,
            originY: 48,
            width: 48,
            height: 48,
            color: .init(red: 0.24, green: 0.28, blue: 0.32, alpha: 1)
        )

        harness.viewModel.setSelectedColor(.init(red: 0.22, green: 0.34, blue: 0.46, alpha: 1))
        try drawSingleMainCanvasStamp(in: harness.viewModel, at: .init(x: Double(freshStrokeX), y: Double(freshStrokeY)))
        let staleBounds = try #require(harness.viewModel.activeEditableLayerEffectBoundsForColorAdjustment())
        #expect(staleBounds.origin.x + staleBounds.size.x < Double(freshStrokeX))

        harness.viewModel.setColorAdjustmentBrightness(0.55)
        try await waitForColorAdjustmentPreview(in: harness)

        let previewPixel = try harness.colorAdjustmentPreviewColor(atX: freshStrokeX, y: freshStrokeY)
        #expect(previewPixel.alpha > 0.4)
        #expect(previewPixel.red > 0.26)
        #expect(previewPixel.green > 0.38)
        #expect(previewPixel.blue > 0.50)
    }

    @Test
    @MainActor
    func colorAdjustmentWholeLayerSessionRebuildsWhenCanvasContentChanges() async throws {
        let harness = try BrushEditingBoundaryHarness()
        let activeLayerID = harness.viewModel.workspace.document.activeLayerID
        let initialOpaqueX = 64
        let initialOpaqueY = 64
        let newStrokeX = 172
        let newStrokeY = 172

        try fillOpaqueRect(
            in: harness,
            layerID: activeLayerID,
            originX: 48,
            originY: 48,
            width: 36,
            height: 36,
            color: .init(red: 0.24, green: 0.28, blue: 0.32, alpha: 1)
        )

        harness.viewModel.setColorAdjustmentBrightness(0.55)
        try await waitForColorAdjustmentPreview(in: harness)

        let initialBasePixel = try harness.color(atX: initialOpaqueX, y: initialOpaqueY, layerID: activeLayerID)
        let initialPreviewPixel = try harness.colorAdjustmentPreviewColor(atX: initialOpaqueX, y: initialOpaqueY)
        #expect(initialPreviewPixel.red > initialBasePixel.red + 0.05)

        harness.viewModel.setSelectedColor(.init(red: 0.32, green: 0.46, blue: 0.58, alpha: 1))
        let baselineRevision = harness.viewModel.colorAdjustmentRedrawRevision
        try drawSingleMainCanvasStamp(
            in: harness.viewModel,
            at: .init(x: Double(newStrokeX), y: Double(newStrokeY))
        )
        _ = harness.viewModel.flushBrushEditingBoundary(
            reason: "test.colorAdjustmentWholeLayerSessionRebuildsWhenCanvasContentChanges"
        )
        try await waitForColorAdjustmentRedrawRevision(
            in: harness,
            after: baselineRevision
        )

        let newBasePixel = try harness.color(atX: newStrokeX, y: newStrokeY, layerID: activeLayerID)
        let newPreviewPixel = try harness.colorAdjustmentPreviewColor(atX: newStrokeX, y: newStrokeY)
        #expect(newBasePixel.alpha > 0.05)
        #expect(newPreviewPixel.red > newBasePixel.red + 0.03)
        #expect(newPreviewPixel.green > newBasePixel.green + 0.03)
        #expect(newPreviewPixel.blue > newBasePixel.blue + 0.03)

        guard let session = harness.viewModel.colorAdjustmentSession else {
            Issue.record("Expected rebuilt whole-layer color adjustment session")
            return
        }
        switch session.source {
        case .wholeLayer(let wholeLayerState):
            #expect(wholeLayerState.capturedCanvasRevision == harness.viewModel.canvasContentRevision)
            let effectBounds = try #require(wholeLayerState.effectBounds)
            #expect(effectBounds.size.x < Double(harness.viewModel.workspace.document.canvasSize.width))
            #expect(effectBounds.size.y < Double(harness.viewModel.workspace.document.canvasSize.height))
            #expect(effectBounds.origin.x <= Double(newStrokeX))
            #expect(effectBounds.origin.y <= Double(newStrokeY))
        case .painted, .selection:
            Issue.record("Expected rebuilt whole-layer source")
        }
    }

    @Test
    @MainActor
    func curveAdjustmentWholeLayerPreviewUsesActiveLayerWithoutPainting() async throws {
        let harness = try BrushEditingBoundaryHarness()
        let activeLayerID = harness.viewModel.workspace.document.activeLayerID
        let opaqueX = 96
        let opaqueY = 96
        let transparentX = 16
        let transparentY = 16

        try fillOpaqueRect(
            in: harness,
            layerID: activeLayerID,
            originX: 48,
            originY: 48,
            width: 120,
            height: 120,
            color: .init(red: 0.48, green: 0.48, blue: 0.48, alpha: 1)
        )

        let opaqueBasePixel = try harness.color(atX: opaqueX, y: opaqueY, layerID: activeLayerID)
        let transparentBasePixel = try harness.color(atX: transparentX, y: transparentY, layerID: activeLayerID)

        #expect(harness.viewModel.beginCurveAdjustmentFromWholeLayerIfNeeded(showFeedback: false))
        let baselineRevision = harness.viewModel.colorAdjustmentRedrawRevision
        harness.viewModel.updateCurveAdjustmentChannelPoints(
            [
                .init(x: 0, y: 0),
                .init(x: 0.5, y: 0.25),
                .init(x: 1, y: 1)
            ],
            channel: .rgb
        )
        try await waitForColorAdjustmentRedrawRevision(in: harness, after: baselineRevision)

        let opaquePreviewPixel = try harness.colorAdjustmentPreviewColor(atX: opaqueX, y: opaqueY)
        let transparentPreviewPixel = try harness.colorAdjustmentPreviewColor(atX: transparentX, y: transparentY)
        #expect(opaquePreviewPixel.red < opaqueBasePixel.red - 0.04)
        #expect(opaquePreviewPixel.green < opaqueBasePixel.green - 0.04)
        #expect(opaquePreviewPixel.blue < opaqueBasePixel.blue - 0.04)
        #expect(abs(transparentPreviewPixel.alpha - transparentBasePixel.alpha) < 0.02)
        #expect(harness.viewModel.curveAdjustmentOverlayState.sourceKind == .wholeLayer)

        guard let session = harness.viewModel.curveAdjustmentSession else {
            Issue.record("Expected whole-layer curve adjustment session")
            return
        }

        switch session.source {
        case .wholeLayer:
            break
        case .painted, .selection:
            Issue.record("Expected whole-layer curve source")
        }
    }

    @Test
    @MainActor
    func curveAdjustmentWholeLayerPreviewOverridesRetainedBrushDisplayTexture() async throws {
        let harness = try BrushEditingBoundaryHarness()
        let activeLayerID = harness.viewModel.workspace.document.activeLayerID
        let opaqueX = 96
        let opaqueY = 96

        try fillOpaqueRect(
            in: harness,
            layerID: activeLayerID,
            originX: 48,
            originY: 48,
            width: 120,
            height: 120,
            color: .init(red: 0.48, green: 0.48, blue: 0.48, alpha: 1)
        )

        try drawSingleMainCanvasStamp(in: harness.viewModel, at: .init(x: 180, y: 180))
        #expect(harness.bootstrap.strokeEngine.displayTexture(for: activeLayerID) != nil)

        let opaqueBasePixel = try harness.color(atX: opaqueX, y: opaqueY, layerID: activeLayerID)
        #expect(harness.viewModel.beginCurveAdjustmentFromWholeLayerIfNeeded(showFeedback: false))
        let baselineRevision = harness.viewModel.colorAdjustmentRedrawRevision
        harness.viewModel.updateCurveAdjustmentChannelPoints(
            [
                .init(x: 0, y: 0),
                .init(x: 0.5, y: 0.25),
                .init(x: 1, y: 1)
            ],
            channel: .rgb
        )
        try await waitForColorAdjustmentRedrawRevision(in: harness, after: baselineRevision)

        let opaquePreviewPixel = try harness.colorAdjustmentPreviewColor(atX: opaqueX, y: opaqueY)
        #expect(opaquePreviewPixel.red < opaqueBasePixel.red - 0.04)
        #expect(opaquePreviewPixel.green < opaqueBasePixel.green - 0.04)
        #expect(opaquePreviewPixel.blue < opaqueBasePixel.blue - 0.04)
    }

    @Test
    @MainActor
    func curveAdjustmentWholeLayerPreviewFlushesPendingBrushCommitAndInvalidatesStaleBoundsCache() async throws {
        let harness = try BrushEditingBoundaryHarness()
        let activeLayerID = harness.viewModel.workspace.document.activeLayerID
        let freshStrokeX = 180
        let freshStrokeY = 180

        try fillOpaqueRect(
            in: harness,
            layerID: activeLayerID,
            originX: 48,
            originY: 48,
            width: 48,
            height: 48,
            color: .init(red: 0.48, green: 0.48, blue: 0.48, alpha: 1)
        )

        harness.viewModel.setSelectedColor(.init(red: 0.46, green: 0.46, blue: 0.46, alpha: 1))
        try drawSingleMainCanvasStamp(in: harness.viewModel, at: .init(x: Double(freshStrokeX), y: Double(freshStrokeY)))
        let staleBounds = try #require(harness.viewModel.activeEditableLayerEffectBoundsForCurveAdjustment())
        #expect(staleBounds.origin.x + staleBounds.size.x < Double(freshStrokeX))

        #expect(harness.viewModel.beginCurveAdjustmentFromWholeLayerIfNeeded(showFeedback: false))
        let baselineRevision = harness.viewModel.colorAdjustmentRedrawRevision
        harness.viewModel.updateCurveAdjustmentChannelPoints(
            [
                .init(x: 0, y: 0),
                .init(x: 0.5, y: 0.25),
                .init(x: 1, y: 1)
            ],
            channel: .rgb
        )
        try await waitForColorAdjustmentRedrawRevision(in: harness, after: baselineRevision)

        let previewPixel = try harness.colorAdjustmentPreviewColor(atX: freshStrokeX, y: freshStrokeY)
        #expect(previewPixel.alpha > 0.4)
        #expect(previewPixel.red < 0.42)
        #expect(previewPixel.green < 0.42)
        #expect(previewPixel.blue < 0.42)
    }

    @Test
    @MainActor
    func curveAdjustmentWholeLayerNeutralSessionDoesNotExposePreviewTexture() throws {
        let harness = try BrushEditingBoundaryHarness()
        let activeLayerID = harness.viewModel.workspace.document.activeLayerID

        try fillOpaqueRect(
            in: harness,
            layerID: activeLayerID,
            originX: 48,
            originY: 48,
            width: 120,
            height: 120,
            color: .init(red: 0.48, green: 0.48, blue: 0.48, alpha: 1)
        )

        #expect(harness.viewModel.beginCurveAdjustmentFromWholeLayerIfNeeded(showFeedback: false))
        #expect(harness.viewModel.curveAdjustmentSession != nil)
        #expect(harness.viewModel.canConfirmCurveAdjustmentSession == false)
        #expect(harness.viewModel.canPreviewCurveAdjustmentOriginal == false)
        #expect(harness.viewModel.brushDisplayTexture(for: activeLayerID) == nil)
    }

    @Test
    @MainActor
    func curveAdjustmentSelectionPreviewUsesCommittedSelectionWithoutPainting() async throws {
        let harness = try BrushEditingBoundaryHarness()
        let activeLayerID = harness.viewModel.workspace.document.activeLayerID
        let insideSelectionX = 92
        let insideSelectionY = 92
        let outsideSelectionX = 156
        let outsideSelectionY = 156

        try fillOpaqueRect(
            in: harness,
            layerID: activeLayerID,
            originX: 48,
            originY: 48,
            width: 140,
            height: 140,
            color: .init(red: 0.48, green: 0.48, blue: 0.48, alpha: 1)
        )
        makeRectangleSelection(
            in: harness.viewModel,
            minX: 72,
            minY: 72,
            maxX: 124,
            maxY: 124
        )

        let insideBasePixel = try harness.color(atX: insideSelectionX, y: insideSelectionY, layerID: activeLayerID)
        let outsideBasePixel = try harness.color(atX: outsideSelectionX, y: outsideSelectionY, layerID: activeLayerID)

        let baselineRevision = harness.viewModel.colorAdjustmentRedrawRevision
        harness.viewModel.updateCurveAdjustmentChannelPoints(
            [
                .init(x: 0, y: 0),
                .init(x: 0.5, y: 0.25),
                .init(x: 1, y: 1)
            ],
            channel: .rgb
        )
        try await waitForColorAdjustmentRedrawRevision(in: harness, after: baselineRevision)

        let insidePreviewPixel = try harness.colorAdjustmentPreviewColor(atX: insideSelectionX, y: insideSelectionY)
        let outsidePreviewPixel = try harness.colorAdjustmentPreviewColor(atX: outsideSelectionX, y: outsideSelectionY)
        #expect(insidePreviewPixel.red < insideBasePixel.red - 0.04)
        #expect(insidePreviewPixel.green < insideBasePixel.green - 0.04)
        #expect(insidePreviewPixel.blue < insideBasePixel.blue - 0.04)
        #expect(abs(outsidePreviewPixel.red - outsideBasePixel.red) < 0.02)
        #expect(abs(outsidePreviewPixel.green - outsideBasePixel.green) < 0.02)
        #expect(abs(outsidePreviewPixel.blue - outsideBasePixel.blue) < 0.02)
        #expect(harness.viewModel.curveAdjustmentOverlayState.sourceKind == .selection)
        #expect(harness.viewModel.selectionOverlayProxy.isHiddenForTransientAdjustment)

        guard let session = harness.viewModel.curveAdjustmentSession else {
            Issue.record("Expected selection curve adjustment session")
            return
        }

        switch session.source {
        case .selection:
            break
        case .painted, .wholeLayer:
            Issue.record("Expected committed selection curve source")
        }
    }

    @Test
    @MainActor
    func curveAdjustmentSelectionSessionRebuildsWhenCommittedSelectionChanges() async throws {
        let harness = try BrushEditingBoundaryHarness()
        let activeLayerID = harness.viewModel.workspace.document.activeLayerID
        let firstSelectionX = 92
        let firstSelectionY = 92
        let secondSelectionX = 152
        let secondSelectionY = 152

        try fillOpaqueRect(
            in: harness,
            layerID: activeLayerID,
            originX: 48,
            originY: 48,
            width: 140,
            height: 140,
            color: .init(red: 0.48, green: 0.48, blue: 0.48, alpha: 1)
        )
        makeRectangleSelection(
            in: harness.viewModel,
            minX: 72,
            minY: 72,
            maxX: 116,
            maxY: 116
        )

        let firstBasePixel = try harness.color(atX: firstSelectionX, y: firstSelectionY, layerID: activeLayerID)
        let secondBasePixel = try harness.color(atX: secondSelectionX, y: secondSelectionY, layerID: activeLayerID)

        let initialPreviewRevision = harness.viewModel.colorAdjustmentRedrawRevision
        harness.viewModel.updateCurveAdjustmentChannelPoints(
            [
                .init(x: 0, y: 0),
                .init(x: 0.5, y: 0.25),
                .init(x: 1, y: 1)
            ],
            channel: .rgb
        )
        try await waitForColorAdjustmentRedrawRevision(
            in: harness,
            after: initialPreviewRevision
        )

        let baselineRevision = harness.viewModel.colorAdjustmentRedrawRevision
        makeRectangleSelection(
            in: harness.viewModel,
            minX: 136,
            minY: 136,
            maxX: 172,
            maxY: 172
        )
        try await waitForColorAdjustmentRedrawRevision(
            in: harness,
            after: baselineRevision
        )

        let firstPreviewPixel = try harness.colorAdjustmentPreviewColor(atX: firstSelectionX, y: firstSelectionY)
        let secondPreviewPixel = try harness.colorAdjustmentPreviewColor(atX: secondSelectionX, y: secondSelectionY)
        #expect(abs(firstPreviewPixel.red - firstBasePixel.red) < 0.02)
        #expect(abs(firstPreviewPixel.green - firstBasePixel.green) < 0.02)
        #expect(abs(firstPreviewPixel.blue - firstBasePixel.blue) < 0.02)
        #expect(secondPreviewPixel.red < secondBasePixel.red - 0.04)
        #expect(secondPreviewPixel.green < secondBasePixel.green - 0.04)
        #expect(secondPreviewPixel.blue < secondBasePixel.blue - 0.04)

        guard let session = harness.viewModel.curveAdjustmentSession else {
            Issue.record("Expected rebuilt selection curve adjustment session")
            return
        }
        switch session.source {
        case .selection(let selectionState):
            #expect(selectionState.capturedSelectionRevision == harness.viewModel.selectionRevision)
            #expect(selectionState.capturedSelectionShape.bounds.origin.x > 130)
        case .painted, .wholeLayer:
            Issue.record("Expected rebuilt selection curve source")
        }
    }

    @Test
    @MainActor
    func curveAdjustmentToolFirstStrokeCreatesBlueMaskPreview() async throws {
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
        harness.viewModel.setBrightnessAdjustmentEditorMode(.curves)
        harness.viewModel.beginStrokeIfNeeded()
        harness.viewModel.applyStroke(samples: [
            .init(location: .init(x: 96, y: 96), pressure: 1),
            .init(location: .init(x: 112, y: 112), pressure: 1)
        ])
        harness.viewModel.endStroke()

        try await waitForCurveAdjustmentPreview(in: harness)

        #expect(harness.viewModel.curveAdjustmentOverlayState.isActive)
        #expect(harness.viewModel.curveAdjustmentOverlayState.sourceKind == .paintedMask)

        let previewPixel = try harness.colorAdjustmentPreviewColor(atX: 104, y: 104)
        #expect(previewPixel.blue > previewPixel.red)
        #expect(previewPixel.blue > previewPixel.green)
    }

    @Test
    @MainActor
    func curveAdjustmentToolBEKeysSwitchMaskMode() throws {
        let harness = try BrushEditingBoundaryHarness()

        harness.viewModel.selectTool(.brightnessAdjust)
        harness.viewModel.setBrightnessAdjustmentEditorMode(.curves)

        let eraseHandled = harness.viewModel.handleKeyDown(
            makeCanvasKeyEvent(type: .keyDown, characters: "e", charactersIgnoringModifiers: "e", modifiers: [], keyCode: 14)
        )
        #expect(eraseHandled == true)
        #expect(harness.viewModel.curveAdjustmentBrushMode == .erase)

        let paintHandled = harness.viewModel.handleKeyDown(
            makeCanvasKeyEvent(type: .keyDown, characters: "b", charactersIgnoringModifiers: "b", modifiers: [], keyCode: 11)
        )
        #expect(paintHandled == true)
        #expect(harness.viewModel.curveAdjustmentBrushMode == .paint)
    }

    @Test
    @MainActor
    func curveAdjustmentConfirmReleasesBEKeysBackToToolShortcuts() throws {
        let harness = try BrushEditingBoundaryHarness()
        let activeLayerID = harness.viewModel.workspace.document.activeLayerID

        try fillOpaqueRect(
            in: harness,
            layerID: activeLayerID,
            originX: 48,
            originY: 48,
            width: 120,
            height: 120,
            color: .init(red: 0.48, green: 0.48, blue: 0.48, alpha: 1)
        )

        harness.viewModel.selectTool(.brightnessAdjust)
        harness.viewModel.setBrightnessAdjustmentEditorMode(.curves)
        harness.viewModel.beginStrokeIfNeeded()
        harness.viewModel.applyStroke(samples: [.init(location: .init(x: 96, y: 96), pressure: 1)])
        harness.viewModel.endStroke()
        harness.viewModel.updateCurveAdjustmentChannelPoints(
            [
                .init(x: 0, y: 0),
                .init(x: 0.5, y: 0.25),
                .init(x: 1, y: 1)
            ],
            channel: .rgb
        )
        #expect(harness.viewModel.confirmCurveAdjustmentIfNeeded(showFeedback: false))

        #expect(harness.viewModel.curveAdjustmentSession == nil)
        #expect(harness.viewModel.workspace.toolSession.activeTool == .brightnessAdjust)

        let handled = harness.viewModel.handleKeyDown(
            makeCanvasKeyEvent(type: .keyDown, characters: "b", charactersIgnoringModifiers: "b", modifiers: [], keyCode: 11)
        )

        #expect(handled == true)
        #expect(harness.viewModel.workspace.toolSession.activeTool == .brush)
    }

    @Test
    @MainActor
    func colorAdjustmentConfirmReleasesBEKeysBackToToolShortcuts() throws {
        let harness = try BrushEditingBoundaryHarness()
        let activeLayerID = harness.viewModel.workspace.document.activeLayerID

        try fillOpaqueRect(
            in: harness,
            layerID: activeLayerID,
            originX: 48,
            originY: 48,
            width: 120,
            height: 120,
            color: .init(red: 0.24, green: 0.24, blue: 0.24, alpha: 1)
        )

        harness.viewModel.selectTool(.brightnessAdjust)
        harness.viewModel.beginStrokeIfNeeded()
        harness.viewModel.applyStroke(samples: [.init(location: .init(x: 96, y: 96), pressure: 1)])
        harness.viewModel.endStroke()
        harness.viewModel.setColorAdjustmentBrightness(0.6)
        harness.viewModel.confirmColorAdjustmentPaintedSession()

        #expect(harness.viewModel.colorAdjustmentSession == nil)
        #expect(harness.viewModel.workspace.toolSession.activeTool == .brightnessAdjust)

        let handled = harness.viewModel.handleKeyDown(
            makeCanvasKeyEvent(type: .keyDown, characters: "b", charactersIgnoringModifiers: "b", modifiers: [], keyCode: 11)
        )

        #expect(handled == true)
        #expect(harness.viewModel.workspace.toolSession.activeTool == .brush)
    }

    @Test
    @MainActor
    func colorAdjustmentToolSwitchPromptCancelKeepsCurrentSessionActive() throws {
        let harness = try BrushEditingBoundaryHarness()
        let activeLayerID = harness.viewModel.workspace.document.activeLayerID

        try fillOpaqueRect(
            in: harness,
            layerID: activeLayerID,
            originX: 48,
            originY: 48,
            width: 120,
            height: 120,
            color: .init(red: 0.3, green: 0.3, blue: 0.3, alpha: 1)
        )

        harness.viewModel.selectTool(.brightnessAdjust)
        harness.viewModel.beginStrokeIfNeeded()
        harness.viewModel.applyStroke(samples: [.init(location: .init(x: 96, y: 96), pressure: 1)])
        harness.viewModel.endStroke()
        harness.viewModel.setColorAdjustmentBrightness(0.5)
        harness.viewModel.debugColorAdjustmentResolutionDecisionOverride = .cancel

        harness.viewModel.selectTool(.brush)

        #expect(harness.viewModel.workspace.toolSession.activeTool == .brightnessAdjust)
        #expect(harness.viewModel.colorAdjustmentSession != nil)
        #expect(harness.viewModel.colorAdjustmentOverlayState.isActive)
    }

    @Test
    @MainActor
    func colorAdjustmentLayerSwitchPromptDiscardDropsSessionAndContinues() throws {
        let harness = try BrushEditingBoundaryHarness()
        let backgroundLayerID = try #require(harness.viewModel.workspace.document.layers.first?.id)
        let activeLayerID = harness.viewModel.workspace.document.activeLayerID
        let sampleX = 96
        let sampleY = 96

        try fillOpaqueRect(
            in: harness,
            layerID: activeLayerID,
            originX: 48,
            originY: 48,
            width: 120,
            height: 120,
            color: .init(red: 0.32, green: 0.28, blue: 0.24, alpha: 1)
        )
        let basePixel = try harness.color(atX: sampleX, y: sampleY, layerID: activeLayerID)

        harness.viewModel.selectTool(.brightnessAdjust)
        harness.viewModel.beginStrokeIfNeeded()
        harness.viewModel.applyStroke(samples: [.init(location: .init(x: Double(sampleX), y: Double(sampleY)), pressure: 1)])
        harness.viewModel.endStroke()
        harness.viewModel.setColorAdjustmentBrightness(0.5)
        harness.viewModel.debugColorAdjustmentResolutionDecisionOverride = .discard

        harness.viewModel.selectLayer(backgroundLayerID)

        #expect(harness.viewModel.workspace.document.activeLayerID == backgroundLayerID)
        #expect(harness.viewModel.colorAdjustmentSession == nil)
        #expect(harness.viewModel.status?.message == "已放弃当前色彩调整")
        let retainedPixel = try harness.color(atX: sampleX, y: sampleY, layerID: activeLayerID)
        #expect(abs(retainedPixel.red - basePixel.red) < 0.02)
        #expect(abs(retainedPixel.green - basePixel.green) < 0.02)
        #expect(abs(retainedPixel.blue - basePixel.blue) < 0.02)
    }

    @Test
    @MainActor
    func colorAdjustmentNewCanvasPromptDiscardContinuesCreation() throws {
        let harness = try BrushEditingBoundaryHarness()
        let activeLayerID = harness.viewModel.workspace.document.activeLayerID

        try fillOpaqueRect(
            in: harness,
            layerID: activeLayerID,
            originX: 48,
            originY: 48,
            width: 120,
            height: 120,
            color: .init(red: 0.24, green: 0.26, blue: 0.28, alpha: 1)
        )

        harness.viewModel.selectTool(.brightnessAdjust)
        harness.viewModel.beginStrokeIfNeeded()
        harness.viewModel.applyStroke(samples: [.init(location: .init(x: 96, y: 96), pressure: 1)])
        harness.viewModel.endStroke()
        harness.viewModel.setColorAdjustmentBrightness(0.45)
        harness.viewModel.debugColorAdjustmentResolutionDecisionOverride = .discard

        harness.viewModel.createNewCanvasDiscardingUnsavedChanges(
            name: "Color Adjustment Prompt",
            canvasSize: .init(width: 40, height: 40),
            resolutionDPI: 72
        )

        #expect(harness.viewModel.colorAdjustmentSession == nil)
        #expect(harness.viewModel.workspace.document.canvasSize == .init(width: 40, height: 40))
        #expect(harness.viewModel.workspace.document.layers.count == 2)
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
    func droppedCanvasImageImportsAsCenteredUndoableNewLayer() throws {
        let harness = try BrushEditingBoundaryHarness(canvasSize: .init(width: 64, height: 64))
        let sourceAsset = makeReferenceImageAsset(
            fileName: "drop.png",
            color: .init(red: 0.9, green: 0.2, blue: 0.1, alpha: 1)
        )
        let droppedImage = NSImage(
            cgImage: sourceAsset.cgImage,
            size: NSSize(width: sourceAsset.width, height: sourceAsset.height)
        )
        let initialLayerIDs = harness.viewModel.workspace.document.layers.map(\.id)

        #expect(harness.viewModel.importDroppedCanvasImage(
            from: droppedImage,
            centeredAt: .init(x: 20, y: 22),
            layerName: "drop"
        ))

        let importedLayerID = harness.viewModel.workspace.document.activeLayerID
        #expect(harness.viewModel.workspace.document.layers.count == initialLayerIDs.count + 1)
        #expect(harness.viewModel.workspace.document.layers.last?.id == importedLayerID)
        #expect(harness.viewModel.workspace.document.layers.last?.name == "drop")
        #expect(try harness.alpha(atX: 19, y: 21, layerID: importedLayerID) > 0.95)
        #expect(try harness.alpha(atX: 18, y: 21, layerID: importedLayerID) < 0.01)
        #expect(harness.viewModel.status?.message == "已将图片导入为新图层")

        harness.viewModel.undo()
        #expect(harness.viewModel.workspace.document.layers.map(\.id) == initialLayerIDs)

        harness.viewModel.redo()
        #expect(harness.viewModel.workspace.document.layers.count == initialLayerIDs.count + 1)
        let restoredLayerID = harness.viewModel.workspace.document.activeLayerID
        #expect(try harness.alpha(atX: 19, y: 21, layerID: restoredLayerID) > 0.95)
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
    func stampVisibleLayersShortcutCreatesUndoableTopCompositeWithoutRemovingSources() throws {
        let harness = try BrushEditingBoundaryHarness(canvasSize: .init(width: 32, height: 32))
        let redLayerID = harness.viewModel.workspace.document.activeLayerID
        try fillOpaqueRect(
            in: harness,
            layerID: redLayerID,
            originX: 6,
            originY: 6,
            width: 12,
            height: 12,
            color: .init(red: 1, green: 0, blue: 0, alpha: 1)
        )

        harness.viewModel.addLayer()
        let blueLayerID = harness.viewModel.workspace.document.activeLayerID
        try fillOpaqueRect(
            in: harness,
            layerID: blueLayerID,
            originX: 6,
            originY: 6,
            width: 12,
            height: 12,
            color: .init(red: 0, green: 0, blue: 1, alpha: 1)
        )
        harness.viewModel.setActiveLayerOpacity(0.5)

        harness.viewModel.addLayer()
        let hiddenGreenLayerID = harness.viewModel.workspace.document.activeLayerID
        try fillOpaqueRect(
            in: harness,
            layerID: hiddenGreenLayerID,
            originX: 6,
            originY: 6,
            width: 12,
            height: 12,
            color: .init(red: 0, green: 1, blue: 0, alpha: 1)
        )
        harness.viewModel.setLayerVisibility(hiddenGreenLayerID, isVisible: false)

        let sourceLayerIDs = harness.viewModel.workspace.document.layers.map(\.id)
        let handled = harness.viewModel.handleKeyDown(
            makeCanvasKeyEvent(
                type: .keyDown,
                characters: "E",
                charactersIgnoringModifiers: "e",
                modifiers: [.command, .option, .shift],
                keyCode: 14
            )
        )

        #expect(handled)
        let stampedDocument = harness.viewModel.workspace.document
        #expect(stampedDocument.layers.count == sourceLayerIDs.count + 1)
        #expect(Array(stampedDocument.layers.dropLast().map(\.id)) == sourceLayerIDs)
        let stampedLayer = try #require(stampedDocument.layers.last)
        #expect(stampedLayer.id == stampedDocument.activeLayerID)
        #expect(stampedLayer.name == "盖印图层")
        #expect(stampedLayer.isVisible)
        #expect(stampedLayer.opacity == 1)

        let stampedColor = try harness.color(atX: 10, y: 10, layerID: stampedLayer.id)
        #expect(stampedColor.red > 0.45)
        #expect(stampedColor.blue > 0.45)
        #expect(stampedColor.green < 0.05)
        #expect(stampedColor.alpha > 0.99)
        #expect(stampedDocument.layers.first(where: { $0.id == hiddenGreenLayerID })?.isVisible == false)

        harness.viewModel.undo()
        #expect(harness.viewModel.workspace.document.layers.map(\.id) == sourceLayerIDs)
        #expect(try harness.color(atX: 10, y: 10, layerID: redLayerID).red > 0.95)
        #expect(try harness.color(atX: 10, y: 10, layerID: blueLayerID).blue > 0.95)
    }

    @Test
    @MainActor
    func mergedCopyShortcutPastesVisibleSelectionInPlaceAsNewLayer() throws {
        let harness = try BrushEditingBoundaryHarness(canvasSize: .init(width: 32, height: 32))
        let backgroundLayerID = try #require(harness.viewModel.workspace.document.layers.first?.id)
        let redLayerID = harness.viewModel.workspace.document.activeLayerID
        try fillOpaqueRect(
            in: harness,
            layerID: redLayerID,
            originX: 6,
            originY: 6,
            width: 12,
            height: 12,
            color: .init(red: 1, green: 0, blue: 0, alpha: 1)
        )

        harness.viewModel.addLayer()
        let blueLayerID = harness.viewModel.workspace.document.activeLayerID
        try fillOpaqueRect(
            in: harness,
            layerID: blueLayerID,
            originX: 6,
            originY: 6,
            width: 12,
            height: 12,
            color: .init(red: 0, green: 0, blue: 1, alpha: 1)
        )
        harness.viewModel.setActiveLayerOpacity(0.5)

        harness.viewModel.addLayer()
        let hiddenGreenLayerID = harness.viewModel.workspace.document.activeLayerID
        try fillOpaqueRect(
            in: harness,
            layerID: hiddenGreenLayerID,
            originX: 6,
            originY: 6,
            width: 12,
            height: 12,
            color: .init(red: 0, green: 1, blue: 0, alpha: 1)
        )
        harness.viewModel.setLayerVisibility(hiddenGreenLayerID, isVisible: false)
        makeRectangleSelection(
            in: harness.viewModel,
            minX: 8,
            minY: 8,
            maxX: 16,
            maxY: 16
        )

        let sourceLayerIDs = harness.viewModel.workspace.document.layers.map(\.id)
        let copied = harness.viewModel.handleKeyDown(
            makeCanvasKeyEvent(
                type: .keyDown,
                characters: "C",
                charactersIgnoringModifiers: "c",
                modifiers: [.command, .shift],
                keyCode: 8
            )
        )
        #expect(copied)
        #expect(harness.viewModel.workspace.document.layers.map(\.id) == sourceLayerIDs)
        #expect(harness.viewModel.status?.message == "已合并拷贝选区内的可见图层")

        harness.viewModel.selectLayer(backgroundLayerID)
        let pasted = harness.viewModel.handleKeyDown(
            makeCanvasKeyEvent(
                type: .keyDown,
                characters: "v",
                charactersIgnoringModifiers: "v",
                modifiers: [.command],
                keyCode: 9
            )
        )
        #expect(pasted)

        let pastedDocument = harness.viewModel.workspace.document
        #expect(pastedDocument.layers.count == sourceLayerIDs.count + 1)
        let pastedLayerID = pastedDocument.activeLayerID
        #expect(sourceLayerIDs.contains(pastedLayerID) == false)
        let pastedColor = try harness.color(atX: 10, y: 10, layerID: pastedLayerID)
        #expect(pastedColor.red > 0.45)
        #expect(pastedColor.blue > 0.45)
        #expect(pastedColor.green < 0.05)
        #expect(pastedColor.alpha > 0.99)
        #expect(try harness.alpha(atX: 4, y: 4, layerID: pastedLayerID) < 0.01)
        #expect(try harness.alpha(atX: 10, y: 10, layerID: redLayerID) > 0.99)
        #expect(try harness.alpha(atX: 10, y: 10, layerID: blueLayerID) > 0.99)
        #expect(harness.viewModel.status?.message == "已粘贴为新图层")
    }

    @Test
    @MainActor
    func perspectiveToolAddsMovesUndoesAndLocksGuidesWithoutPixelHistory() throws {
        let harness = try BrushEditingBoundaryHarness(canvasSize: .init(width: 32, height: 32))
        harness.viewModel.selectTool(.perspective)

        #expect(harness.viewModel.workspace.toolSession.activeTool == .perspective)
        #expect(harness.viewModel.perspectiveGuide?.mode == .threePoint)
        let sceneBeforeGuideEditing = harness.viewModel.sceneSnapshot

        harness.viewModel.beginPerspectiveGuideInteraction(
            at: .init(x: 16, y: 22),
            hitRadius: 1
        )
        harness.viewModel.endPerspectiveGuideInteraction()
        let anchor = try #require(harness.viewModel.perspectiveGuide?.anchors.first)
        #expect(anchor.position == CanvasPoint(x: 16, y: 22))

        harness.viewModel.beginPerspectiveGuideInteraction(at: anchor.position, hitRadius: 2)
        harness.viewModel.updatePerspectiveGuideInteraction(to: .init(x: 20, y: 25))
        harness.viewModel.endPerspectiveGuideInteraction()
        #expect(harness.viewModel.perspectiveGuide?.anchors.first?.position == CanvasPoint(x: 20, y: 25))
        #expect(harness.viewModel.sceneSnapshot == sceneBeforeGuideEditing)

#if DEBUG
        #expect(harness.bootstrap.historyController.debugUndoEntryApproxByteCounts.last == 0)
#endif

        harness.viewModel.undo()
        #expect(harness.viewModel.perspectiveGuide?.anchors.first?.position == CanvasPoint(x: 16, y: 22))
        harness.viewModel.redo()
        #expect(harness.viewModel.perspectiveGuide?.anchors.first?.position == CanvasPoint(x: 20, y: 25))

        harness.viewModel.selectTool(.brush)
        #expect(harness.viewModel.perspectiveGuide?.isVisible == true)
        #expect(harness.viewModel.perspectiveGuide?.isLocked == true)
    }

    @Test
    @MainActor
    func clearingPerspectiveGuideRemovesEveryControlAndSupportsUndoRedoAndRecreation() throws {
        let harness = try BrushEditingBoundaryHarness(canvasSize: .init(width: 32, height: 32))
        harness.viewModel.selectTool(.perspective)
        harness.viewModel.beginPerspectiveGuideInteraction(
            at: .init(x: 16, y: 22),
            hitRadius: 1
        )
        harness.viewModel.endPerspectiveGuideInteraction()
        let guideBeforeClear = try #require(harness.viewModel.perspectiveGuide)
        #expect(guideBeforeClear.anchors.count == 1)

        harness.viewModel.clearPerspectiveGuide()
        #expect(harness.viewModel.perspectiveGuide == nil)
        #expect(harness.viewModel.selectedPerspectiveAnchorID == nil)

        harness.viewModel.undo()
        #expect(harness.viewModel.perspectiveGuide == guideBeforeClear)
        harness.viewModel.redo()
        #expect(harness.viewModel.perspectiveGuide == nil)

        harness.viewModel.createPerspectiveGuide()
        #expect(harness.viewModel.perspectiveGuide?.mode == .threePoint)
        #expect(harness.viewModel.perspectiveGuide?.anchors.isEmpty == true)
    }

    @Test
    @MainActor
    func blockReferenceCreatesExtrudedObjectFreezesAndRestoresThroughHistory() throws {
        let harness = try BrushEditingBoundaryHarness(canvasSize: .init(width: 600, height: 480))
        harness.viewModel.selectTool(.blockReference)
        #expect(harness.viewModel.blockReferenceScene != nil)
        #expect(harness.viewModel.workspace.toolSession.activeTool == .blockReference)

        harness.viewModel.setBlockReferenceEditorMode(.box)
        harness.viewModel.beginBlockReferenceInteraction(
            at: .init(x: 250, y: 250),
            screenScale: 1
        )
        harness.viewModel.updateBlockReferenceInteraction(
            to: .init(x: 350, y: 330),
            screenScale: 1
        )
        harness.viewModel.endBlockReferenceInteraction()
        #expect(harness.viewModel.blockReferenceEditorState.phase == .awaitingExtrusion)

        harness.viewModel.beginBlockReferenceInteraction(
            at: .init(x: 350, y: 330),
            screenScale: 1
        )
        harness.viewModel.updateBlockReferenceInteraction(
            to: .init(x: 350, y: 230),
            screenScale: 1
        )
        harness.viewModel.endBlockReferenceInteraction()

        let object = try #require(harness.viewModel.blockReferenceScene?.objects.first)
        #expect(object.kind == .box)
        #expect(object.dimensions.width > 1)
        #expect(object.dimensions.depth > 1)
        #expect(object.dimensions.height > 1)

        harness.viewModel.undo()
        #expect(harness.viewModel.blockReferenceScene?.objects.isEmpty == true)
        harness.viewModel.redo()
        #expect(harness.viewModel.blockReferenceScene?.objects.count == 1)

        harness.viewModel.selectTool(.brush)
        #expect(harness.viewModel.blockReferenceScene?.display.isFrozen == true)
        #expect(harness.viewModel.blockReferenceScene?.display.isVisible == true)
    }

    @Test
    @MainActor
    func blockReferenceNumericTransformPreviewsThenCommitsOneUndoableChange() throws {
        let harness = try BrushEditingBoundaryHarness(canvasSize: .init(width: 600, height: 480))
        harness.viewModel.selectTool(.blockReference)
        let object = BlockReferenceObject(
            name: "方块 1",
            kind: .box,
            position: .init(x: 10, y: 20, z: 0),
            dimensions: .init(width: 80, depth: 60, height: 100)
        )
        _ = harness.viewModel.updateBlockReferenceDocument { scene in
            scene?.objects.append(object)
        }
        harness.viewModel.blockReferenceEditorState.selectedObjectID = object.id

        harness.viewModel.beginBlockReferenceNumericTransform(.move)
        harness.viewModel.setBlockReferenceNumericTransformAxis(.x)
        harness.viewModel.setBlockReferenceNumericTransformInput("-35")

        #expect(harness.viewModel.selectedBlockReferenceObject?.position.x == 10)
        #expect(harness.viewModel.displayedSelectedBlockReferenceObject?.position.x == -25)

        harness.viewModel.commitBlockReferenceNumericTransform()
        #expect(harness.viewModel.selectedBlockReferenceObject?.position.x == -25)
        #expect(harness.viewModel.blockReferenceEditorState.numericTransform == nil)

        harness.viewModel.undo()
        #expect(harness.viewModel.selectedBlockReferenceObject?.position.x == 10)

        let keySequence: [(String, UInt16)] = [
            ("g", 5), ("x", 7), ("-", 27), ("3", 20), ("5", 23), ("\r", 36)
        ]
        for (characters, keyCode) in keySequence {
            let event = makeCanvasKeyEvent(
                type: .keyDown,
                characters: characters,
                charactersIgnoringModifiers: characters,
                modifiers: [],
                keyCode: keyCode
            )
            #expect(harness.viewModel.handleBlockReferenceKeyDown(event))
        }
        #expect(harness.viewModel.selectedBlockReferenceObject?.position.x == -25)
    }

    @Test
    @MainActor
    func blockReferenceControlShortcutsUsePhysicalKeyCodesForGroupAndUngroup() throws {
        let harness = try BrushEditingBoundaryHarness(canvasSize: .init(width: 600, height: 480))
        harness.viewModel.selectTool(.blockReference)
        let objects = [
            BlockReferenceObject(
                name: "A", kind: .box, position: .init(x: -20, y: 0, z: 0),
                dimensions: .init(width: 20, depth: 20, height: 20)
            ),
            BlockReferenceObject(
                name: "B", kind: .box, position: .init(x: 20, y: 0, z: 0),
                dimensions: .init(width: 20, depth: 20, height: 20)
            )
        ]
        _ = harness.viewModel.updateBlockReferenceDocument { $0?.objects = objects }
        harness.viewModel.selectAllBlockReferenceObjects()
        let group = makeCanvasKeyEvent(
            type: .keyDown,
            characters: "\u{7}",
            charactersIgnoringModifiers: "\u{7}",
            modifiers: [.control],
            keyCode: 5
        )
        #expect(harness.viewModel.handleBlockReferenceKeyDown(group))
        #expect(harness.viewModel.blockReferenceScene?.groups.count == 1)

        let ungroup = makeCanvasKeyEvent(
            type: .keyDown,
            characters: "\u{7}",
            charactersIgnoringModifiers: "\u{7}",
            modifiers: [.control, .shift],
            keyCode: 5
        )
        #expect(harness.viewModel.handleBlockReferenceKeyDown(ungroup))
        #expect(harness.viewModel.blockReferenceScene?.groups.isEmpty == true)
    }

    @Test
    @MainActor
    func blockReferenceGroupExpandsASelectedMemberAndTransformsAsOneUnit() throws {
        let harness = try BrushEditingBoundaryHarness(canvasSize: .init(width: 600, height: 480))
        harness.viewModel.selectTool(.blockReference)
        let first = BlockReferenceObject(
            name: "A", kind: .box, position: .init(x: -20, y: 0, z: 0),
            dimensions: .init(width: 20, depth: 20, height: 20)
        )
        let second = BlockReferenceObject(
            name: "B", kind: .box, position: .init(x: 20, y: 0, z: 0),
            dimensions: .init(width: 20, depth: 20, height: 20)
        )
        _ = harness.viewModel.updateBlockReferenceDocument { $0?.objects = [first, second] }
        harness.viewModel.selectAllBlockReferenceObjects()
        harness.viewModel.groupSelectedBlockReferenceObjects()

        // Reproduce a canvas click that stores only the clicked member as the raw selection.
        harness.viewModel.blockReferenceEditorState.selectedObjectID = first.id
        harness.viewModel.blockReferenceEditorState.selectedObjectIDs = [first.id]
        #expect(harness.viewModel.selectedBlockReferenceObjectIDs == [first.id, second.id])

        harness.viewModel.beginBlockReferenceNumericTransform(.rotate)
        harness.viewModel.setBlockReferenceNumericTransformAxis(.z)
        harness.viewModel.setBlockReferenceNumericTransformInput("90")
        harness.viewModel.commitBlockReferenceNumericTransform()
        let rotated = try #require(harness.viewModel.blockReferenceScene?.objects)
        #expect(rotated[0].position.distance(to: .init(x: 0, y: -20, z: 0)) < 0.000_001)
        #expect(rotated[1].position.distance(to: .init(x: 0, y: 20, z: 0)) < 0.000_001)

        harness.viewModel.setSelectedBlockReferencePosition(.init(x: 10, y: -20, z: 0))
        let moved = try #require(harness.viewModel.blockReferenceScene?.objects)
        #expect(moved[0].position.distance(to: .init(x: 10, y: -20, z: 0)) < 0.000_001)
        #expect(moved[1].position.distance(to: .init(x: 10, y: 20, z: 0)) < 0.000_001)

        harness.viewModel.ungroupSelectedBlockReferenceObjects()
        #expect(harness.viewModel.blockReferenceScene?.groups.isEmpty == true)
        #expect(harness.viewModel.blockReferenceScene?.objects.allSatisfy { $0.groupID == nil } == true)
    }

    @Test
    @MainActor
    func blockReferenceShortcutAxisUsesWorldThenLocalOnRepeatedAxisKey() throws {
        let harness = try BrushEditingBoundaryHarness(canvasSize: .init(width: 600, height: 480))
        harness.viewModel.selectTool(.blockReference)
        let object = BlockReferenceObject(
            name: "旋转方块",
            kind: .box,
            position: .zero,
            rotation: .init(xDegrees: 0, yDegrees: 0, zDegrees: 90),
            dimensions: .stageOneDefault
        )
        _ = harness.viewModel.updateBlockReferenceDocument { $0?.objects = [object] }
        harness.viewModel.selectBlockReferenceObject(object.id, extending: false)
        harness.viewModel.setBlockReferenceGizmoCoordinateSpace(.local)

        let event: (String, UInt16) -> NSEvent = { characters, keyCode in
            makeCanvasKeyEvent(
                type: .keyDown,
                characters: characters,
                charactersIgnoringModifiers: characters,
                modifiers: [],
                keyCode: keyCode
            )
        }
        for input in [("g", 5), ("x", 7), ("1", 18), ("0", 29), ("\r", 36)] {
            #expect(harness.viewModel.handleBlockReferenceKeyDown(event(input.0, UInt16(input.1))))
        }
        #expect(harness.viewModel.selectedBlockReferenceObject?.position.distance(to: .init(x: 10, y: 0, z: 0)) ?? 1 < 0.000_001)

        harness.viewModel.undo()
        for input in [("g", 5), ("x", 7), ("x", 7), ("1", 18), ("0", 29), ("\r", 36)] {
            #expect(harness.viewModel.handleBlockReferenceKeyDown(event(input.0, UInt16(input.1))))
        }
        #expect(harness.viewModel.selectedBlockReferenceObject?.position.distance(to: .init(x: 0, y: 10, z: 0)) ?? 1 < 0.000_001)
    }

    @Test
    @MainActor
    func blockReferenceRestoresGroundPlaneAndCameraGuideCreatesSceneAnchors() throws {
        let harness = try BrushEditingBoundaryHarness(canvasSize: .init(width: 600, height: 480))
        harness.viewModel.selectTool(.blockReference)
        let object = BlockReferenceObject(
            name: "方块", kind: .box, position: .zero, dimensions: .stageOneDefault
        )
        _ = harness.viewModel.updateBlockReferenceDocument { scene in
            scene?.objects = [object]
            scene?.workingPlane = .init(
                origin: .init(x: 10, y: 20, z: 30),
                axisU: .unitY,
                axisV: .unitZ,
                normal: .unitX,
                sourceObjectID: object.id,
                sourceFaceIndex: 0
            )
        }
        harness.viewModel.blockReferenceEditorState.mode = .pickWorkPlane
        harness.viewModel.resetBlockReferenceWorkingPlane()
        #expect(harness.viewModel.blockReferenceScene?.workingPlane == .ground)
        #expect(harness.viewModel.blockReferenceEditorState.mode == .select)

        harness.viewModel.createPerspectiveGuideFromBlockReferenceCamera()
        let guide = try #require(harness.viewModel.perspectiveGuide)
        #expect(guide.mode == .threePoint)
        #expect(!guide.anchors.isEmpty)
        #expect(!guide.isLocked)
    }

    @Test
    @MainActor
    func blockReferenceNumericScaleUsesTheSelectionPivotAndIsOneUndoableChange() throws {
        let harness = try BrushEditingBoundaryHarness(canvasSize: .init(width: 600, height: 480))
        harness.viewModel.selectTool(.blockReference)
        let first = BlockReferenceObject(
            name: "方块 1",
            kind: .box,
            position: .init(x: -40, y: 0, z: 20),
            dimensions: .init(width: 40, depth: 60, height: 80)
        )
        let second = BlockReferenceObject(
            name: "方块 2",
            kind: .box,
            position: .init(x: 40, y: 0, z: 20),
            dimensions: .init(width: 40, depth: 60, height: 80)
        )
        _ = harness.viewModel.updateBlockReferenceDocument { scene in
            scene?.objects.append(contentsOf: [first, second])
        }
        harness.viewModel.selectBlockReferenceObject(first.id, extending: false)
        harness.viewModel.selectBlockReferenceObject(second.id, extending: true)

        harness.viewModel.beginBlockReferenceNumericTransform(.scale)
        harness.viewModel.setBlockReferenceNumericTransformInput("1.5")
        #expect(harness.viewModel.blockReferenceScene?.objects == [first, second])
        let transform = try #require(harness.viewModel.blockReferenceEditorState.numericTransform)
        let preview = [transform.applying(to: first), transform.applying(to: second)]
        #expect(preview[0].position.x == -60)
        #expect(preview[1].position.x == 60)
        #expect(preview[0].dimensions == BlockDimensions(width: 60, depth: 90, height: 120))

        harness.viewModel.commitBlockReferenceNumericTransform()
        let scaled = try #require(harness.viewModel.blockReferenceScene?.objects)
        #expect(scaled[0].position.x == -60)
        #expect(scaled[1].position.x == 60)
        #expect(scaled[1].dimensions == BlockDimensions(width: 60, depth: 90, height: 120))

        harness.viewModel.undo()
        #expect(harness.viewModel.blockReferenceScene?.objects == [first, second])
    }

    @Test
    @MainActor
    func blockReferenceAdvancedSceneOperationsStayBoundedAndUndoable() throws {
        let harness = try BrushEditingBoundaryHarness(canvasSize: .init(width: 600, height: 480))
        harness.viewModel.selectTool(.blockReference)
        let first = BlockReferenceObject(
            name: "方块 1",
            kind: .box,
            position: .init(x: -30, y: 0, z: 20),
            dimensions: .stageOneDefault
        )
        let second = BlockReferenceObject(
            name: "方块 2",
            kind: .box,
            position: .init(x: 30, y: 0, z: 20),
            dimensions: .stageOneDefault
        )
        _ = harness.viewModel.updateBlockReferenceDocument { scene in
            scene?.objects.append(contentsOf: [first, second])
        }
        harness.viewModel.selectAllBlockReferenceObjects()
        #expect(harness.viewModel.blockReferenceEditorState.instruction == "已选择全部 2 个可编辑体块。")
        harness.viewModel.groupSelectedBlockReferenceObjects()
        #expect(harness.viewModel.blockReferenceScene?.groups.count == 1)
        #expect(harness.viewModel.blockReferenceEditorState.instruction == "已将 2 个体块编组。")

        harness.viewModel.mirrorSelectedBlockReferenceObjects(axis: .x)
        #expect(harness.viewModel.blockReferenceScene?.objects.count == 4)
        #expect(harness.viewModel.blockReferenceEditorState.instruction == "已沿 X 轴生成镜像副本。")
        harness.viewModel.undo()
        #expect(harness.viewModel.blockReferenceScene?.objects.count == 2)

        harness.viewModel.storeBlockReferenceCameraSlot(1)
        harness.viewModel.addBlockReferenceConstructionAxis(.x)
        harness.viewModel.saveCurrentBlockReferenceWorkingPlane()
        harness.viewModel.setBlockReferenceSectionEnabled(true)
        harness.viewModel.saveBlockReferenceSceneSnapshot()
        let scene = try #require(harness.viewModel.blockReferenceScene)
        #expect(scene.cameraSlots.first?.name == "视角 1")
        #expect(scene.constructionLines.count == 1)
        #expect(scene.savedWorkingPlanes.count == 1)
        #expect(scene.section.isEnabled)
        #expect(scene.snapshots.count == 1)
        #expect(scene.snapshots[0].objects.count == 2)
    }

    @Test
    @MainActor
    func blockReferenceArraysAndHistoryNavigationReportCompletedState() throws {
        let harness = try BrushEditingBoundaryHarness(canvasSize: .init(width: 600, height: 480))
        harness.viewModel.selectTool(.blockReference)
        let object = BlockReferenceObject(
            name: "方块 1",
            kind: .box,
            position: .init(x: 40, y: 0, z: 20),
            dimensions: .stageOneDefault
        )
        _ = harness.viewModel.updateBlockReferenceDocument { scene in
            scene?.objects = [object]
        }
        harness.viewModel.selectBlockReferenceObject(object.id, extending: false)

        harness.viewModel.createBlockReferenceLinearArray(count: 4, spacing: 30, axis: .y)
        #expect(harness.viewModel.blockReferenceScene?.objects.count == 4)
        #expect(harness.viewModel.blockReferenceEditorState.instruction == "已沿 Y 轴生成 3 个线性阵列副本。")

        harness.viewModel.undo()
        #expect(harness.viewModel.blockReferenceScene?.objects == [object])
        #expect(harness.viewModel.blockReferenceEditorState.instruction == "已撤销上一项操作。")

        harness.viewModel.redo()
        #expect(harness.viewModel.blockReferenceScene?.objects.count == 4)
        #expect(harness.viewModel.blockReferenceEditorState.instruction == "已重做上一项操作。")

        harness.viewModel.undo()
        harness.viewModel.selectBlockReferenceObject(object.id, extending: false)
        harness.viewModel.setBlockReferencePivotMode(.workingPlaneOrigin)
        harness.viewModel.createBlockReferenceRadialArray(count: 4, totalDegrees: 360, axis: .z)
        #expect(harness.viewModel.blockReferenceScene?.objects.count == 4)
        #expect(harness.viewModel.blockReferenceEditorState.instruction == "已绕 Z 轴生成 3 个环形阵列副本。")
    }

    @Test
    @MainActor
    func blockReferenceGizmoDragMovesAlongOneAxisAndKeepsOneEditableUndoStep() throws {
        let canvasSize = CanvasSize(width: 600, height: 480)
        let harness = try BrushEditingBoundaryHarness(canvasSize: canvasSize)
        harness.viewModel.selectTool(.blockReference)
        let object = BlockReferenceObject(
            name: "方块 1",
            kind: .box,
            position: BlockVector3(x: 0, y: 0, z: 70),
            dimensions: BlockDimensions(width: 80, depth: 60, height: 100)
        )
        _ = harness.viewModel.updateBlockReferenceDocument { scene in
            scene?.objects.append(object)
        }
        harness.viewModel.blockReferenceEditorState.selectedObjectID = object.id
        let scene = try #require(harness.viewModel.blockReferenceScene)
        let layout = try #require(blockReferenceGizmoLayout(
            object: object,
            camera: scene.camera,
            canvasSize: canvasSize,
            screenScale: 1
        ))
        let move = try #require(layout.moveHandles.first(where: { $0.axis == .x }))
        let dragEnd = CanvasPoint(
            x: move.end.x + move.canvasDirection.x * 36,
            y: move.end.y + move.canvasDirection.y * 36
        )

        #expect(harness.viewModel.updateBlockReferenceGizmoHover(at: move.end, screenScale: 1))
        #expect(
            harness.viewModel.blockReferenceEditorState.hoveredGizmoHandle
                == BlockReferenceGizmoHandle(kind: .move, axis: .x)
        )
        harness.viewModel.beginBlockReferenceInteraction(at: move.end, screenScale: 1)
        #expect(harness.viewModel.blockReferenceEditorState.phase == .transformingGizmo)
        harness.viewModel.updateBlockReferenceInteraction(to: dragEnd, screenScale: 1)
        harness.viewModel.endBlockReferenceInteraction()

        #expect(harness.viewModel.selectedBlockReferenceObject?.position.x != 0)
        let adjustment = try #require(harness.viewModel.blockReferenceEditorState.gizmoAdjustment)
        #expect(adjustment.handle == BlockReferenceGizmoHandle(kind: .move, axis: .x))
        harness.viewModel.setBlockReferenceGizmoAdjustmentInput("-25")
        #expect(harness.viewModel.selectedBlockReferenceObject?.position == BlockVector3(x: -25, y: 0, z: 70))
        harness.viewModel.finishBlockReferenceGizmoAdjustment()

        harness.viewModel.undo()
        #expect(harness.viewModel.selectedBlockReferenceObject?.position == object.position)
    }

    @Test
    @MainActor
    func blockReferenceLocalGizmoMouseDragUsesTheDisplayedObjectAxes() throws {
        let canvasSize = CanvasSize(width: 600, height: 480)
        let harness = try BrushEditingBoundaryHarness(canvasSize: canvasSize)
        harness.viewModel.selectTool(.blockReference)
        let object = BlockReferenceObject(
            name: "局部轴方块",
            kind: .box,
            position: BlockVector3(x: 0, y: 0, z: 70),
            rotation: BlockEulerRotation(xDegrees: 18, yDegrees: -12, zDegrees: 90),
            dimensions: BlockDimensions(width: 80, depth: 60, height: 100)
        )
        _ = harness.viewModel.updateBlockReferenceDocument { scene in
            scene?.objects.append(object)
        }
        harness.viewModel.blockReferenceEditorState.selectedObjectID = object.id
        harness.viewModel.blockReferenceEditorState.selectedObjectIDs = [object.id]
        for (characters, keyCode) in [("g", UInt16(5)), ("x", UInt16(7)), ("x", UInt16(7))] {
            #expect(harness.viewModel.handleBlockReferenceKeyDown(makeCanvasKeyEvent(
                type: .keyDown,
                characters: characters,
                charactersIgnoringModifiers: characters,
                modifiers: [],
                keyCode: keyCode
            )))
        }
        #expect(harness.viewModel.blockReferenceEditorState.numericTransform?.coordinateSpace == .local)
        #expect(harness.viewModel.blockReferenceEditorState.gizmoCoordinateSpace == .local)
        let scene = try #require(harness.viewModel.blockReferenceScene)
        let directions = harness.viewModel.blockReferenceGizmoAxisDirections
        let layout = try #require(blockReferenceGizmoLayout(
            center: object.position,
            axisDirections: directions,
            camera: scene.camera,
            canvasSize: canvasSize,
            screenScale: 1
        ))
        let move = try #require(layout.moveHandles.first(where: { $0.axis == .x }))
        let dragEnd = CanvasPoint(
            x: move.end.x + move.canvasDirection.x * 38,
            y: move.end.y + move.canvasDirection.y * 38
        )

        #expect(harness.viewModel.updateBlockReferenceGizmoHover(at: move.end, screenScale: 1))
        harness.viewModel.beginBlockReferenceInteraction(at: move.end, screenScale: 1)
        #expect(harness.viewModel.blockReferenceEditorState.numericTransform == nil)
        #expect(harness.viewModel.blockReferenceEditorState.phase == .transformingGizmo)
        harness.viewModel.updateBlockReferenceInteraction(to: dragEnd, screenScale: 1)
        harness.viewModel.endBlockReferenceInteraction()

        let moved = try #require(harness.viewModel.selectedBlockReferenceObject)
        let delta = moved.position - object.position
        let localX = try #require(directions[.x])
        #expect(delta.length > 1)
        #expect(abs(delta.normalized().dot(localX)) > 0.999)
    }

    @Test
    @MainActor
    func blockReferenceLocalRotationRingStartsAndRotatesWithMouse() throws {
        let canvasSize = CanvasSize(width: 600, height: 480)
        let harness = try BrushEditingBoundaryHarness(canvasSize: canvasSize)
        harness.viewModel.selectTool(.blockReference)
        let object = BlockReferenceObject(
            name: "局部旋转方块",
            kind: .box,
            position: BlockVector3(x: 0, y: 0, z: 70),
            rotation: BlockEulerRotation(xDegrees: 22, yDegrees: 31, zDegrees: -17),
            dimensions: .stageOneDefault
        )
        _ = harness.viewModel.updateBlockReferenceDocument { scene in
            scene?.objects.append(object)
        }
        harness.viewModel.blockReferenceEditorState.selectedObjectID = object.id
        harness.viewModel.blockReferenceEditorState.selectedObjectIDs = [object.id]
        harness.viewModel.setBlockReferenceGizmoCoordinateSpace(.local)
        let scene = try #require(harness.viewModel.blockReferenceScene)
        let localDirections = harness.viewModel.blockReferenceGizmoAxisDirections
        let layout = try #require(blockReferenceGizmoLayout(
            center: object.position,
            axisDirections: localDirections,
            camera: scene.camera,
            canvasSize: canvasSize,
            screenScale: 1
        ))
        let ring = try #require(layout.rotationRings.first(where: { $0.axis == .y }))
        let startIndex = try #require(ring.points.indices.first(where: { index in
            index + 4 < ring.points.count
                && blockReferenceGizmoHitTest(
                    point: ring.points[index],
                    layout: layout,
                    screenScale: 1
                ) == BlockReferenceGizmoHandle(kind: .rotate, axis: .y)
        }))

        harness.viewModel.beginBlockReferenceInteraction(at: ring.points[startIndex], screenScale: 1)
        #expect(harness.viewModel.blockReferenceEditorState.phase == .transformingGizmo)
        harness.viewModel.updateBlockReferenceInteraction(to: ring.points[startIndex + 4], screenScale: 1)
        harness.viewModel.endBlockReferenceInteraction()

        #expect(harness.viewModel.selectedBlockReferenceObject?.rotation != object.rotation)
        #expect(harness.viewModel.blockReferenceEditorState.gizmoAdjustment?.axisDirections
            == localDirections)
    }

    @Test
    @MainActor
    func blockReferenceGroupGizmoMovesEverySelectedObjectWithOneUndoStep() throws {
        let canvasSize = CanvasSize(width: 600, height: 480)
        let harness = try BrushEditingBoundaryHarness(canvasSize: canvasSize)
        harness.viewModel.selectTool(.blockReference)
        let first = BlockReferenceObject(
            name: "方块 1",
            kind: .box,
            position: BlockVector3(x: -30, y: 0, z: 70),
            dimensions: .stageOneDefault
        )
        let second = BlockReferenceObject(
            name: "方块 2",
            kind: .box,
            position: BlockVector3(x: 30, y: 0, z: 70),
            dimensions: .stageOneDefault
        )
        _ = harness.viewModel.updateBlockReferenceDocument { scene in
            scene?.objects.append(contentsOf: [first, second])
        }
        harness.viewModel.selectBlockReferenceObject(first.id, extending: false)
        harness.viewModel.selectBlockReferenceObject(second.id, extending: true)
        let scene = try #require(harness.viewModel.blockReferenceScene)
        let center = try #require(harness.viewModel.blockReferenceSelectionCenter)
        let layout = try #require(blockReferenceGizmoLayout(
            center: center,
            axisDirections: harness.viewModel.blockReferenceGizmoAxisDirections,
            camera: scene.camera,
            canvasSize: canvasSize,
            screenScale: 1
        ))
        let move = try #require(layout.moveHandles.first(where: { $0.axis == .x }))
        let dragEnd = CanvasPoint(
            x: move.end.x + move.canvasDirection.x * 30,
            y: move.end.y + move.canvasDirection.y * 30
        )

        harness.viewModel.beginBlockReferenceInteraction(at: move.end, screenScale: 1)
        harness.viewModel.updateBlockReferenceInteraction(to: dragEnd, screenScale: 1)
        harness.viewModel.endBlockReferenceInteraction()
        harness.viewModel.setBlockReferenceGizmoAdjustmentInput("40")

        let moved = try #require(harness.viewModel.blockReferenceScene?.objects)
        #expect(moved[0].position == BlockVector3(x: 10, y: 0, z: 70))
        #expect(moved[1].position == BlockVector3(x: 70, y: 0, z: 70))

        harness.viewModel.finishBlockReferenceGizmoAdjustment()
        harness.viewModel.undo()
        let restored = try #require(harness.viewModel.blockReferenceScene?.objects)
        #expect(restored[0].position == first.position)
        #expect(restored[1].position == second.position)
    }

    @Test
    @MainActor
    func blockReferenceRotationRingDragsAroundItsWorldAxis() throws {
        let canvasSize = CanvasSize(width: 600, height: 480)
        let harness = try BrushEditingBoundaryHarness(canvasSize: canvasSize)
        harness.viewModel.selectTool(.blockReference)
        let object = BlockReferenceObject(
            name: "方块 1",
            kind: .box,
            position: BlockVector3(x: 0, y: 0, z: 70),
            rotation: BlockEulerRotation(xDegrees: 15, yDegrees: -20, zDegrees: 25),
            dimensions: BlockDimensions(width: 80, depth: 60, height: 100)
        )
        _ = harness.viewModel.updateBlockReferenceDocument { scene in
            scene?.objects.append(object)
        }
        harness.viewModel.blockReferenceEditorState.selectedObjectID = object.id
        let scene = try #require(harness.viewModel.blockReferenceScene)
        let layout = try #require(blockReferenceGizmoLayout(
            object: object,
            camera: scene.camera,
            canvasSize: canvasSize,
            screenScale: 1
        ))
        let ring = try #require(layout.rotationRings.first(where: { $0.axis == .z }))
        let startIndex = try #require(ring.points.indices.first(where: { index in
            blockReferenceGizmoHitTest(
                point: ring.points[index],
                layout: layout,
                screenScale: 1
            ) == BlockReferenceGizmoHandle(kind: .rotate, axis: .z)
            && index + 4 < ring.points.count
        }))

        harness.viewModel.beginBlockReferenceInteraction(at: ring.points[startIndex], screenScale: 1)
        harness.viewModel.updateBlockReferenceInteraction(to: ring.points[startIndex + 4], screenScale: 1)
        harness.viewModel.endBlockReferenceInteraction()

        let adjustment = try #require(harness.viewModel.blockReferenceEditorState.gizmoAdjustment)
        #expect(adjustment.handle == BlockReferenceGizmoHandle(kind: .rotate, axis: .z))
        let rotated = try #require(harness.viewModel.selectedBlockReferenceObject)
        #expect(rotated.rotation != object.rotation)
        harness.viewModel.undo()
        #expect(harness.viewModel.selectedBlockReferenceObject?.rotation == object.rotation)
    }

    @Test
    @MainActor
    func blockReferenceCameraNavigationChangesOnlyTheSceneCameraAndSupportsUndo() throws {
        let harness = try BrushEditingBoundaryHarness(canvasSize: .init(width: 600, height: 480))
        harness.viewModel.selectTool(.blockReference)
        let originalCamera = try #require(harness.viewModel.blockReferenceScene?.camera)
        let originalViewport = harness.viewModel.workspace.viewport

        harness.viewModel.beginBlockReferenceCameraNavigation(.orbit)
        harness.viewModel.updateBlockReferenceCameraNavigation(
            mode: .orbit,
            deltaX: 90,
            deltaY: -30,
            screenScale: 1
        )
        harness.viewModel.endBlockReferenceCameraNavigation()

        let changedCamera = try #require(harness.viewModel.blockReferenceScene?.camera)
        #expect(changedCamera.yawDegrees != originalCamera.yawDegrees)
        #expect(changedCamera.pitchDegrees < originalCamera.pitchDegrees)
        #expect(harness.viewModel.workspace.viewport == originalViewport)

        harness.viewModel.undo()
        #expect(harness.viewModel.blockReferenceScene?.camera == originalCamera)
    }

    @Test
    @MainActor
    func blockReferenceMultiSelectionMovesTogetherOnLocalAxisAndSupportsUndo() throws {
        let harness = try BrushEditingBoundaryHarness(canvasSize: .init(width: 600, height: 480))
        harness.viewModel.selectTool(.blockReference)
        let first = BlockReferenceObject(
            name: "方块 1",
            kind: .box,
            position: BlockVector3(x: -30, y: 0, z: 0),
            dimensions: .stageOneDefault
        )
        let second = BlockReferenceObject(
            name: "方块 2",
            kind: .box,
            position: BlockVector3(x: 30, y: 0, z: 0),
            rotation: BlockEulerRotation(xDegrees: 0, yDegrees: 0, zDegrees: 90),
            dimensions: .stageOneDefault
        )
        _ = harness.viewModel.updateBlockReferenceDocument { scene in
            scene?.objects.append(contentsOf: [first, second])
        }
        harness.viewModel.selectBlockReferenceObject(first.id, extending: false)
        harness.viewModel.selectBlockReferenceObject(second.id, extending: true)
        #expect(harness.viewModel.selectedBlockReferenceObjectIDs == [first.id, second.id])
        #expect(harness.viewModel.blockReferenceEditorState.selectedObjectID == second.id)

        harness.viewModel.setBlockReferenceGizmoCoordinateSpace(.local)
        harness.viewModel.beginBlockReferenceNumericTransform(.move)
        harness.viewModel.setBlockReferenceNumericTransformAxis(.x)
        harness.viewModel.setBlockReferenceNumericTransformInput("25")
        harness.viewModel.commitBlockReferenceNumericTransform()

        let moved = try #require(harness.viewModel.blockReferenceScene?.objects)
        #expect(moved[0].position.distance(to: BlockVector3(x: -30, y: 25, z: 0)) < 0.000_001)
        #expect(moved[1].position.distance(to: BlockVector3(x: 30, y: 25, z: 0)) < 0.000_001)

        harness.viewModel.undo()
        let restored = try #require(harness.viewModel.blockReferenceScene?.objects)
        #expect(restored[0].position == first.position)
        #expect(restored[1].position == second.position)
    }

    @Test
    @MainActor
    func blockReferenceVisibilityAndLockRemoveObjectsFromEditableSelection() throws {
        let harness = try BrushEditingBoundaryHarness(canvasSize: .init(width: 600, height: 480))
        harness.viewModel.selectTool(.blockReference)
        let object = BlockReferenceObject(
            name: "方块 1",
            kind: .box,
            position: .zero,
            dimensions: .stageOneDefault
        )
        _ = harness.viewModel.updateBlockReferenceDocument { scene in
            scene?.objects.append(object)
        }
        harness.viewModel.selectBlockReferenceObject(object.id, extending: false)

        harness.viewModel.setBlockReferenceObjectLocked(object.id, isLocked: true)
        #expect(harness.viewModel.blockReferenceScene?.objects.first?.isLocked == true)
        #expect(harness.viewModel.selectedBlockReferenceObjectIDs.isEmpty)
        #expect(harness.viewModel.editableSelectedBlockReferenceObjects.isEmpty)

        harness.viewModel.setBlockReferenceObjectLocked(object.id, isLocked: false)
        harness.viewModel.selectBlockReferenceObject(object.id, extending: false)
        harness.viewModel.setBlockReferenceObjectVisibility(object.id, isVisible: false)
        #expect(harness.viewModel.blockReferenceScene?.objects.first?.isVisible == false)
        #expect(harness.viewModel.selectedBlockReferenceObjectIDs.isEmpty)
        #expect(harness.viewModel.editableSelectedBlockReferenceObjects.isEmpty)
    }

    @Test
    @MainActor
    func blockReferenceBooleanUsesTheActiveObjectAndIsOneUndoableReplacement() throws {
        let harness = try BrushEditingBoundaryHarness(canvasSize: .init(width: 600, height: 480))
        harness.viewModel.selectTool(.blockReference)
        let first = BlockReferenceObject(
            name: "左主体",
            kind: .box,
            position: .zero,
            dimensions: .init(width: 100, depth: 100, height: 100)
        )
        let second = BlockReferenceObject(
            name: "右工具体",
            kind: .box,
            position: .init(x: 50, y: 0, z: 0),
            dimensions: .init(width: 100, depth: 100, height: 100)
        )
        _ = harness.viewModel.updateBlockReferenceDocument { scene in
            scene?.objects.append(contentsOf: [first, second])
        }
        harness.viewModel.selectBlockReferenceObject(second.id, extending: false)
        harness.viewModel.selectBlockReferenceObject(first.id, extending: true)
        #expect(harness.viewModel.selectedBlockReferenceObject?.id == first.id)
        #expect(harness.viewModel.canApplyBlockReferenceBoolean)

        harness.viewModel.applyBlockReferenceBoolean(.subtract)

        let result = try #require(harness.viewModel.blockReferenceScene?.objects.first)
        #expect(harness.viewModel.blockReferenceScene?.objects.count == 1)
        #expect(result.customMesh != nil)
        #expect(abs(result.dimensions.width - 50) < 0.001)
        #expect(result.position.x < 0)
        #expect(harness.viewModel.selectedBlockReferenceObject?.id == result.id)
        #expect(harness.viewModel.blockReferenceEditorState.instruction.contains("左主体 − 右工具体"))

        harness.viewModel.undo()
        #expect(harness.viewModel.blockReferenceScene?.objects == [first, second])
        harness.viewModel.redo()
        #expect(harness.viewModel.blockReferenceScene?.objects.count == 1)
        #expect(harness.viewModel.blockReferenceScene?.objects.first?.customMesh != nil)
    }

    @Test
    @MainActor
    func lassoFillModeSwitchKeepsOneSidebarSurfaceAndRemembersTextureMode() throws {
        let harness = try BrushEditingBoundaryHarness(canvasSize: .init(width: 32, height: 32))
        let group = try #require(
            ToolSidebarGroup.orderedGroups.first { $0.id == "lasso-fill" }
        )

        harness.viewModel.selectTool(.lassoFill)
        #expect(harness.viewModel.lassoFillMode == .color)
        #expect(harness.viewModel.sidebarDisplayedTool(for: group) == .lassoFill)

        harness.viewModel.setLassoFillMode(.texture)
        #expect(harness.viewModel.workspace.toolSession.activeTool == .textureFill)
        #expect(harness.viewModel.lassoFillMode == .texture)
        #expect(harness.viewModel.isSelected(group: group))
        #expect(harness.viewModel.sidebarDisplayedTool(for: group) == .lassoFill)

        harness.viewModel.selectTool(.brush)
        harness.viewModel.activateSidebarGroup(group)
        #expect(harness.viewModel.workspace.toolSession.activeTool == .textureFill)

        harness.viewModel.setLassoFillMode(.color)
        #expect(harness.viewModel.workspace.toolSession.activeTool == .lassoFill)
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
    func compoundPressureMixEditingPreservesMonotonicOrderAndAppliesPresetsAtomically() throws {
        let harness = try BrushEditingBoundaryHarness()

        harness.viewModel.setCompoundPressureMix(.default)
        harness.viewModel.setCompoundPrimaryMixAtLowPressure(0.8)
        var mix = harness.viewModel.workspace.toolSession.brush.compoundBrush.pressureMix
        #expect(mix.primaryAtLowPressure == 0.8)
        #expect(mix.primaryAtMidPressure == 0.8)
        #expect(mix.primaryAtHighPressure == 1)

        harness.viewModel.setCompoundPrimaryMixAtMidPressure(0.4)
        mix = harness.viewModel.workspace.toolSession.brush.compoundBrush.pressureMix
        #expect(mix.primaryAtMidPressure == 0.8)

        harness.viewModel.setCompoundPrimaryMixAtHighPressure(0.2)
        mix = harness.viewModel.workspace.toolSession.brush.compoundBrush.pressureMix
        #expect(mix.primaryAtHighPressure == 0.8)

        harness.viewModel.setCompoundPressureMix(.balanced)
        #expect(harness.viewModel.workspace.toolSession.brush.compoundBrush.pressureMix == .balanced)
    }

    @Test
    @MainActor
    func compoundBrushEditorSnapshotRestoreRestoresTheWholeBrush() throws {
        let harness = try BrushEditingBoundaryHarness()
        let baseline = harness.viewModel.workspace.toolSession.brush

        harness.viewModel.setCompoundBrushEnabled(true)
        harness.viewModel.setCompoundBrushMode(.subtract)
        harness.viewModel.setCompoundSecondaryRelativeSizeRatio(3.2)
        harness.viewModel.setCompoundPressureMix(.primaryOnly)
        #expect(harness.viewModel.workspace.toolSession.brush != baseline)

        harness.viewModel.restoreCompoundBrushEditingSnapshot(baseline)

        #expect(harness.viewModel.workspace.toolSession.brush == baseline)
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
    func ellipseSelectionStartedOutsideCanvasCommitsAsCanvasClippedMask() async throws {
        let harness = try BrushEditingBoundaryHarness(canvasSize: .init(width: 96, height: 72))
        let viewModel = harness.viewModel
        viewModel.selectTool(.ellipseSelection)

        let action = viewModel.handleSelectionMouseDown(
            at: .init(x: -30, y: -18),
            modifiers: []
        )
        guard case .beginDrawing = action else {
            Issue.record("Expected an outside-canvas press to begin drawing a selection.")
            return
        }

        viewModel.updateSelection(to: .init(x: 62, y: 54))
        viewModel.commitSelection(at: .init(x: 62, y: 54))

        for _ in 0..<200 where viewModel.workspace.selection.committedShape?.kind != .mask {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }

        let committed = try #require(viewModel.workspace.selection.committedShape)
        #expect(committed.kind == .mask)
        #expect(committed.bounds.origin.x >= 0)
        #expect(committed.bounds.origin.y >= 0)
        #expect(committed.bounds.maxX <= 96)
        #expect(committed.bounds.maxY <= 72)
        let displayComponent = try #require(committed.components.first)
        #expect(committed.components.count == 1)
        #expect(displayComponent.operation == .add)
        #expect(displayComponent.shape.kind == .ellipse)
        #expect(displayComponent.shape.bounds.origin.x == -30)
        #expect(displayComponent.shape.bounds.origin.y == -18)
        #expect(displayComponent.shape.bounds.maxX == 62)
        #expect(displayComponent.shape.bounds.maxY == 54)
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
    func navigatorAutoRefreshPolicyIsPromptRateLimitedAndVisibilityAware() throws {
        let harness = try BrushEditingBoundaryHarness()
        let viewModel = harness.viewModel
        let minimumInterval = WorkspaceViewModel.navigatorPreviewMinimumRefreshIntervalNanoseconds
        #expect(minimumInterval == 250_000_000)
        #expect(WorkspaceViewModel.navigatorPreviewCoalescingDelayNanoseconds == 100_000_000)
        #expect(
            WorkspaceViewModel.navigatorPreviewRefreshDelayNanoseconds(
                now: 1_000,
                lastRefresh: nil
            ) == 100_000_000
        )
        #expect(
            WorkspaceViewModel.navigatorPreviewRefreshDelayNanoseconds(
                now: 100_000_000,
                lastRefresh: 0
            ) == 150_000_000
        )
        #expect(
            WorkspaceViewModel.navigatorPreviewRefreshDelayNanoseconds(
                now: minimumInterval,
                lastRefresh: 0
            ) == 100_000_000
        )

        viewModel.setNavigatorPreviewVisible(true)
        viewModel.refreshNavigatorPreviewNow()
        let initialRevision = viewModel.navigatorPreviewProxy.redrawRevision

        for _ in 0..<4 {
            viewModel.endStroke()
        }
        #expect(viewModel.navigatorPreviewProxy.redrawRevision == initialRevision)

        viewModel.setNavigatorPreviewVisible(false)
        viewModel.endStroke()
        #expect(viewModel.navigatorPreviewProxy.redrawRevision == initialRevision)

        viewModel.refreshNavigatorPreviewNow()
        #expect(viewModel.navigatorPreviewProxy.redrawRevision == initialRevision + 1)
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
    func referenceImageDropUsesFirstAvailableSlotsAndSkipsReservedSlots() {
        var slots = (0..<5).map { ReferenceImageSlotState(id: $0) }
        slots[1].asset = makeReferenceImageAsset(fileName: "two.png")

        let destinationIDs = referenceImageDropDestinationSlotIDs(
            slots: slots,
            reservedSlotIDs: [2],
            maximumCount: 5
        )

        #expect(destinationIDs == [0, 3, 4])
        #expect(referenceImageDropDestinationSlotIDs(
            slots: slots,
            reservedSlotIDs: [0, 2, 3, 4],
            maximumCount: 1
        ).isEmpty)
        #expect(referenceImageDropDestinationSlotIDs(
            slots: slots,
            reservedSlotIDs: [],
            maximumCount: 0
        ).isEmpty)
    }

    @Test
    @MainActor
    func droppedReferenceImageObjectLoadsIntoTheFirstEmptySlot() async throws {
        let harness = try BrushEditingBoundaryHarness()
        let sourceAsset = makeReferenceImageAsset(fileName: "source.png")
        let droppedImage = NSImage(
            cgImage: sourceAsset.cgImage,
            size: NSSize(width: sourceAsset.width, height: sourceAsset.height)
        )

        #expect(harness.viewModel.importDroppedReferenceImage(
            from: droppedImage,
            fileName: "dropped.png"
        ))
        #expect(harness.viewModel.referenceImageLoadingSlotIDs == [0])

        for _ in 0..<200 {
            if harness.viewModel.referenceImageSlots[0].asset != nil {
                break
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(harness.viewModel.referenceImageSlots[0].asset?.fileName == "dropped.png")
        #expect(harness.viewModel.referenceImageLoadingSlotIDs.isEmpty)
        #expect(harness.viewModel.selectedReferenceImageSlotID == 0)
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
    func canvasColorPickSamplesCurrentBrushDisplayTextureBeforeBrushCommit() throws {
        let harness = try BrushEditingBoundaryHarness()
        let activeLayerID = harness.viewModel.workspace.document.activeLayerID
        let sampleX = 96
        let sampleY = 96

        harness.viewModel.setSelectedColor(.init(red: 0.88, green: 0.12, blue: 0.04, alpha: 1))
        try enqueueRecentBrushAdjustmentStroke(
            in: harness,
            point: .init(location: .init(x: Double(sampleX), y: Double(sampleY)), pressure: 1)
        )

        #expect(harness.bootstrap.strokeEngine.hasPendingBrushCommitJobs)
        #expect(harness.viewModel.brushDisplayTexture(for: activeLayerID) != nil)
        #expect(try harness.color(atX: sampleX, y: sampleY, layerID: activeLayerID).alpha < 0.01)

        harness.viewModel.setSelectedColor(.init(red: 0.05, green: 0.85, blue: 0.2, alpha: 1))
        harness.viewModel.sampleColor(at: .init(x: Double(sampleX), y: Double(sampleY)))

        let sampledColor = harness.viewModel.workspace.toolSession.selectedColor
        #expect(sampledColor.red > 0.6)
        #expect(sampledColor.green < 0.35)
        #expect(sampledColor.blue < 0.25)
        #expect(sampledColor.alpha > 0.99)
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

    init(canvasSize: CanvasSize? = nil) throws {
        guard let metalContext = MetalDeviceContext() else {
            throw BoundaryHarnessError.metalUnavailable
        }
        let workspaceStore = WorkspaceStore()
        if let canvasSize {
            workspaceStore.updateDocument { document in
                document.canvasSize = canvasSize
            }
        }
        let bootstrap = try AppBootstrap(
            workspaceStore: workspaceStore,
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
private func enqueueRecentBrushAdjustmentStroke(
    in harness: BrushEditingBoundaryHarness,
    point: CanvasStrokeSample
) throws {
    harness.viewModel.beginStrokeIfNeeded()
    harness.viewModel.applyStroke(samples: [point])
    harness.viewModel.endStroke()

    guard let commandBuffer = harness.bootstrap.metalContext.commandQueue.makeCommandBuffer() else {
        throw BoundaryHarnessError.commandBufferUnavailable
    }

    _ = harness.viewModel.flushPendingBrushWork(into: commandBuffer)
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
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
    harness.bootstrap.layerSurfaceStore.markContentUnknown(for: layerID)
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
private func makeLassoSelection(
    in viewModel: WorkspaceViewModel,
    points: [CanvasPoint]
) {
    guard let first = points.first, points.count > 1 else { return }
    viewModel.selectTool(.lassoSelection)
    viewModel.beginSelection(kind: .lasso, at: first)
    for point in points.dropFirst().dropLast() {
        viewModel.updateSelection(to: point)
    }
    viewModel.commitSelection(at: points.last ?? first)
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

@MainActor
private func waitForCurveAdjustmentPreview(
    in harness: BrushEditingBoundaryHarness,
    timeoutIterations: Int = 200
) async throws {
    let activeLayerID = harness.viewModel.workspace.document.activeLayerID
    for _ in 0..<timeoutIterations {
        if harness.viewModel.brushDisplayTexture(for: activeLayerID) != nil,
           harness.viewModel.curveAdjustmentOverlayState.isActive {
            return
        }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(10))
    }
    throw BoundaryHarnessError.textureUnavailable
}

@MainActor
private func waitForColorAdjustmentRedrawRevision(
    in harness: BrushEditingBoundaryHarness,
    after baselineRevision: UInt64,
    timeoutIterations: Int = 200
) async throws {
    for _ in 0..<timeoutIterations {
        if harness.viewModel.colorAdjustmentRedrawRevision > baselineRevision {
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

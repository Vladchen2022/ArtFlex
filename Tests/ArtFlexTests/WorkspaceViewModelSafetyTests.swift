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
}

private enum BoundaryHarnessError: Error {
    case metalUnavailable
    case commandBufferUnavailable
    case textureUnavailable
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

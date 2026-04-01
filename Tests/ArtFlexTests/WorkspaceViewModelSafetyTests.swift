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

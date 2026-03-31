import Foundation
import Metal
import Testing
@testable import ArtFlex

struct IdeationSessionTests {
    @Test
    @MainActor
    func synchronizedIdeationCanSelectAllMainCanvasTools() async throws {
        let harness = try IdeationHarness()
        harness.viewModel.startIdeationSession()

        let session = try #require(harness.viewModel.ideationSession)
        let sourceBranch = session.branches[0].viewModel

        for tool in IdeationHarness.allMainCanvasTools {
            sourceBranch.selectTool(tool)
            await Task.yield()

            for branch in session.branches {
                #expect(branch.viewModel.workspace.toolSession.activeTool == tool)
            }
        }
    }

    @Test
    @MainActor
    func synchronizedLassoFillMirrorsPixelMutationAcrossBranches() throws {
        let harness = try IdeationHarness()
        harness.viewModel.startIdeationSession()

        let session = try #require(harness.viewModel.ideationSession)
        let sourceBranch = session.branches[0].viewModel

        harness.makeLassoFill(
            on: sourceBranch,
            color: .init(red: 1, green: 0, blue: 0, alpha: 1),
            points: [
                .init(x: 8, y: 8),
                .init(x: 24, y: 8),
                .init(x: 24, y: 24),
                .init(x: 8, y: 24),
                .init(x: 8, y: 8)
            ]
        )

        for branch in session.branches {
            let pixel = try harness.sampleVisiblePixel(in: branch.viewModel, x: 16, y: 16)
            #expect(pixel.alpha > 0.99)
            #expect(pixel.red > 0.95)
            #expect(pixel.green < 0.05)
            #expect(pixel.blue < 0.05)
            #expect(branch.viewModel.workspace.selection.committedShape == nil)
        }
    }

    @Test
    @MainActor
    func applyingIdeationVariantToMainCanvasAppendsOnlyVisibleDeltaPixels() throws {
        let harness = try IdeationHarness()
        let baseLayerID = harness.viewModel.workspace.document.activeLayerID

        harness.viewModel.setSelectedColor(.black)
        harness.viewModel.fillAtPoint(.init(x: 2, y: 2))

        harness.viewModel.startIdeationSession()
        let session = try #require(harness.viewModel.ideationSession)
        let sourceBranch = session.branches[0].viewModel

        harness.makeLassoFill(
            on: sourceBranch,
            color: .init(red: 1, green: 0, blue: 0, alpha: 1),
            points: [
                .init(x: 8, y: 8),
                .init(x: 24, y: 8),
                .init(x: 24, y: 24),
                .init(x: 8, y: 24),
                .init(x: 8, y: 8)
            ]
        )

        harness.viewModel.applySelectedIdeationVariantToMainCanvas()

        #expect(harness.viewModel.ideationSession == nil)
        #expect(harness.viewModel.workspace.document.layers.count == 2)

        let appendedLayerID = harness.viewModel.workspace.document.activeLayerID
        #expect(appendedLayerID != baseLayerID)

        let deltaInside = try harness.samplePixel(in: harness.viewModel, x: 16, y: 16, layerID: appendedLayerID)
        #expect(deltaInside.alpha > 0.99)
        #expect(deltaInside.red > 0.95)
        #expect(deltaInside.green < 0.05)
        #expect(deltaInside.blue < 0.05)

        let deltaOutside = try harness.samplePixel(in: harness.viewModel, x: 48, y: 48, layerID: appendedLayerID)
        #expect(deltaOutside.alpha < 0.01)

        let baseOutside = try harness.samplePixel(in: harness.viewModel, x: 48, y: 48, layerID: baseLayerID)
        #expect(baseOutside.alpha > 0.99)
        #expect(baseOutside.red < 0.05)
        #expect(baseOutside.green < 0.05)
        #expect(baseOutside.blue < 0.05)
    }

    @Test
    @MainActor
    func applyingIdeationVariantFlushesPendingBrushWorkBeforeSnapshotting() throws {
        let harness = try IdeationHarness()

        harness.viewModel.startIdeationSession()
        let session = try #require(harness.viewModel.ideationSession)
        let sourceBranch = session.branches[0].viewModel

        sourceBranch.setSelectedColor(.init(red: 1, green: 0, blue: 0, alpha: 1))
        sourceBranch.selectTool(.brush)
        sourceBranch.beginStrokeIfNeeded()
        sourceBranch.applyStroke(
            samples: [
                .init(location: .init(x: 12, y: 12), pressure: 1),
                .init(location: .init(x: 22, y: 22), pressure: 1)
            ]
        )
        sourceBranch.endStroke()

        #expect(sourceBranch.hasPendingBrushWork)

        harness.viewModel.applySelectedIdeationVariantToMainCanvas()

        #expect(harness.viewModel.ideationSession == nil)
        #expect(harness.viewModel.workspace.document.layers.count == 2)

        let appendedLayerID = harness.viewModel.workspace.document.activeLayerID
        let pixel = try harness.samplePixel(in: harness.viewModel, x: 16, y: 16, layerID: appendedLayerID)
        #expect(pixel.alpha > 0.01)
        #expect(pixel.red > 0.2)
        #expect(pixel.green < pixel.red)
        #expect(pixel.blue < pixel.red)
    }

    @Test
    @MainActor
    func ideationPausesActiveTimelapseAndBlocksRestartUntilExit() throws {
        let harness = try IdeationHarness()
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            harness.viewModel.timelapseRecorder.stopRecording()
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        harness.viewModel.timelapseRecorder.outputDirectory = tempDirectory
        harness.viewModel.toggleTimelapseRecording()
        #expect(harness.viewModel.timelapseRecorder.isRecording)

        harness.viewModel.startIdeationSession()
        #expect(harness.viewModel.timelapseRecorder.isRecording == false)

        harness.viewModel.toggleTimelapseRecording()
        #expect(harness.viewModel.timelapseRecorder.isRecording == false)

        harness.viewModel.cancelIdeationSession()
        #expect(harness.viewModel.timelapseRecorder.isRecording)
    }

    @Test
    @MainActor
    func ideationGridResetsBranchViewportsAndLocksCanvasInteraction() throws {
        let harness = try IdeationHarness()
        harness.viewModel.updateCanvasViewportSize(.init(width: 1200, height: 900))
        harness.viewModel.updateCanvasToolHover(to: .init(x: 40, y: 40))
        harness.viewModel.zoomIn()
        harness.viewModel.setViewportOffset(x: 180, y: -140)
        harness.viewModel.setViewportRotation(24)

        harness.viewModel.startIdeationSession()
        let session = try #require(harness.viewModel.ideationSession)

        for branch in session.branches {
            #expect(branch.viewModel.workspace.viewport == .stageOneDefault)
            #expect(branch.viewModel.isCanvasViewportLocked)
        }
    }

    @Test
    @MainActor
    func returningToIdeationGridReLocksAndRecentersBranches() throws {
        let harness = try IdeationHarness()
        harness.viewModel.startIdeationSession()
        let session = try #require(harness.viewModel.ideationSession)
        let activeBranch = session.activeBranchViewModel

        session.focusSelectedBranchCanvas()
        #expect(activeBranch.isCanvasViewportLocked == false)

        activeBranch.updateCanvasViewportSize(.init(width: 1200, height: 900))
        activeBranch.updateCanvasToolHover(to: .init(x: 48, y: 48))
        activeBranch.zoomIn()
        activeBranch.setViewportOffset(x: 90, y: -60)
        activeBranch.setViewportRotation(18)
        #expect(activeBranch.workspace.viewport != .stageOneDefault)

        session.returnToGridCanvasLayout()

        for branch in session.branches {
            #expect(branch.viewModel.workspace.viewport == .stageOneDefault)
            #expect(branch.viewModel.isCanvasViewportLocked)
        }
    }
}

@MainActor
private struct IdeationHarness {
    static let allMainCanvasTools: [ToolKind] = [
        .brush,
        .eraser,
        .smudge,
        .eyedropper,
        .bucket,
        .polygonSelection,
        .lassoFill,
        .straightLine,
        .linearGradient,
        .sectorGradient,
        .rectangleSelection,
        .ellipseSelection,
        .lassoSelection,
        .canvasRotate,
        .freeTransform
    ]

    let bootstrap: AppBootstrap
    let viewModel: WorkspaceViewModel

    init(canvasSize: CanvasSize = .init(width: 64, height: 64)) throws {
        guard let metalContext = MetalDeviceContext() else {
            throw IdeationHarnessError.metalUnavailable
        }
        let workspaceStore = WorkspaceStore(state: .stageOneDefault)
        workspaceStore.updateDocument { document in
            document.canvasSize = canvasSize
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

    func makeLassoFill(
        on viewModel: WorkspaceViewModel,
        color: RGBAColor,
        points: [CanvasPoint]
    ) {
        guard let first = points.first, points.count > 1 else { return }

        viewModel.setSelectedColor(color)
        viewModel.selectTool(.lassoFill)
        viewModel.beginSelection(kind: .lasso, at: first)
        for point in points.dropFirst().dropLast() {
            viewModel.updateSelection(to: point)
        }
        viewModel.commitSelection(at: points.last ?? first)
    }

    func samplePixel(
        in viewModel: WorkspaceViewModel,
        x: Int,
        y: Int,
        layerID: LayerID? = nil
    ) throws -> RGBAColor {
        let targetLayerID = layerID ?? viewModel.workspace.document.activeLayerID
        guard
            let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: targetLayerID),
            let texture = bootstrap.layerSurfaceStore.texture(for: surfaceID)
        else {
            throw IdeationHarnessError.textureUnavailable
        }
        return try bootstrap.textureSerializer.samplePixel(texture: texture, x: x, y: y)
    }

    func sampleVisiblePixel(
        in viewModel: WorkspaceViewModel,
        x: Int,
        y: Int
    ) throws -> RGBAColor {
        let snapshot = try viewModel.makeVisibleCompositeSnapshot()
        return snapshot.pixelData.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            let index = (y * snapshot.bytesPerRow) + (x * 4)
            return RGBAColor(
                red: Float(bytes[index + 2]) / 255,
                green: Float(bytes[index + 1]) / 255,
                blue: Float(bytes[index]) / 255,
                alpha: Float(bytes[index + 3]) / 255
            )
        }
    }
}

private enum IdeationHarnessError: Error {
    case metalUnavailable
    case textureUnavailable
}

import AppKit
import Foundation
import ImageIO
import Metal
import Testing
import UniformTypeIdentifiers
@testable import ArtFlex

struct PatternPlacementTests {
    @Test
    @MainActor
    func decodedPatternTextureCacheHasExplicitMemoryLimits() throws {
        let harness = try PatternPlacementHarness()
        defer { harness.cleanup() }

        let limits = harness.viewModel.debugPatternPlacementTextureCacheLimits
        #expect(limits.count == 8)
        #expect(limits.cost == 256 * 1024 * 1024)
    }

    @Test
    func patternPlacementScissorRectClampsToRenderTargetBoundsAtCanvasEdge() throws {
        let scissorRect = try #require(
            patternPlacementScissorRect(
                destinationRect: CGRect(
                    x: 1638.2688937568455,
                    y: 1037.93537787513,
                    width: 189.9,
                    height: 206.9
                ),
                canvasSize: .init(width: 1826, height: 2048),
                renderTargetWidth: 1826,
                renderTargetHeight: 2048
            )
        )

        #expect(scissorRect.x + scissorRect.width <= 1826)
        #expect(scissorRect.y + scissorRect.height <= 2048)
        #expect(scissorRect.width > 0)
        #expect(scissorRect.height > 0)
    }

    @Test
    func patternPlacementTextureCoordinatesFlipHorizontallyWhenDraggingLeftward() {
        let draft = PatternPlacementDraft(
            itemID: UUID(),
            startCanvasPoint: .init(x: 48, y: 20),
            currentCanvasPoint: .init(x: 12, y: 44),
            destinationRect: PatternPlacementDraft.destinationRect(
                startCanvasPoint: .init(x: 48, y: 20),
                currentCanvasPoint: .init(x: 12, y: 44)
            )
        )

        #expect(draft.flipsHorizontally)

        let coords = patternPlacementTextureCoordinates(flipHorizontally: draft.flipsHorizontally)
        #expect(coords.topLeft == SIMD2<Float>(1, 0))
        #expect(coords.topRight == SIMD2<Float>(0, 0))
        #expect(coords.bottomLeft == SIMD2<Float>(1, 1))
        #expect(coords.bottomRight == SIMD2<Float>(0, 1))
    }

    @Test
    func patternPlacementDraftLocksModeAtDragStart() {
        let draft = PatternPlacementDraft(
            itemID: UUID(),
            startCanvasPoint: .init(x: 10, y: 10),
            currentCanvasPoint: .init(x: 22, y: 26),
            destinationRect: PatternPlacementDraft.destinationRect(
                startCanvasPoint: .init(x: 10, y: 10),
                currentCanvasPoint: .init(x: 22, y: 26)
            ),
            placementModeAtDragStart: .newLayer
        )

        #expect(draft.placementModeAtDragStart == .newLayer)
    }

    @Test
    @MainActor
    func selectingPatternLibraryItemArmsPlacement() throws {
        let harness = try PatternPlacementHarness()
        defer { harness.cleanup() }

        let itemID = try #require(harness.viewModel.workspace.patternLibrary.items.first?.id)

        harness.viewModel.selectPatternLibraryItem(itemID)

        #expect(harness.viewModel.workspace.patternLibrary.selectedItemID == itemID)
        #expect(harness.viewModel.patternPlacementPhase == .armed(itemID: itemID))
        #expect(harness.viewModel.patternPlacementTexture(for: itemID) != nil)
    }

    @Test
    @MainActor
    func patternPlacementEscCancelsArmedState() throws {
        let harness = try PatternPlacementHarness()
        defer { harness.cleanup() }

        let itemID = try #require(harness.viewModel.workspace.patternLibrary.items.first?.id)
        harness.viewModel.selectPatternLibraryItem(itemID)

        let handled = harness.viewModel.handleKeyDown(
            makePatternPlacementKeyEvent(
                type: .keyDown,
                characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}",
                modifiers: [],
                keyCode: 53
            )
        )

        #expect(handled)
        #expect(harness.viewModel.patternPlacementPhase == .idle)
        #expect(harness.viewModel.workspace.patternLibrary.selectedItemID == itemID)
    }

    @Test
    @MainActor
    func selectingAnotherToolCancelsPatternPlacementButKeepsSelection() throws {
        let harness = try PatternPlacementHarness()
        defer { harness.cleanup() }

        let itemID = try #require(harness.viewModel.workspace.patternLibrary.items.first?.id)
        harness.viewModel.selectPatternLibraryItem(itemID)

        harness.viewModel.selectTool(.eraser)

        #expect(harness.viewModel.workspace.toolSession.activeTool == .eraser)
        #expect(harness.viewModel.patternPlacementPhase == .idle)
        #expect(harness.viewModel.workspace.patternLibrary.selectedItemID == itemID)
    }

    @Test
    @MainActor
    func selectingCurrentBrushToolCancelsPatternPlacementButKeepsSelection() throws {
        let harness = try PatternPlacementHarness()
        defer { harness.cleanup() }

        let itemID = try #require(harness.viewModel.workspace.patternLibrary.items.first?.id)
        #expect(harness.viewModel.workspace.toolSession.activeTool == .brush)
        harness.viewModel.selectPatternLibraryItem(itemID)

        harness.viewModel.selectTool(.brush)

        #expect(harness.viewModel.workspace.toolSession.activeTool == .brush)
        #expect(harness.viewModel.patternPlacementPhase == .idle)
        #expect(harness.viewModel.workspace.patternLibrary.selectedItemID == itemID)
    }

    @Test
    @MainActor
    func patternPlacementCommitIntoCurrentLayerSupportsUndoRedoAndRearmsSelection() async throws {
        let harness = try PatternPlacementHarness()
        defer { harness.cleanup() }

        let itemID = try #require(harness.viewModel.workspace.patternLibrary.items.first?.id)
        let originalLayerCount = harness.viewModel.workspace.document.layers.count
        let originalLayerID = harness.viewModel.workspace.document.activeLayerID
        harness.viewModel.selectPatternLibraryItem(itemID)

        harness.viewModel.beginPatternPlacementDrag(at: .init(x: 12, y: 14))
        harness.viewModel.updatePatternPlacementDrag(to: .init(x: 28, y: 30))
        harness.viewModel.endPatternPlacementDrag(at: .init(x: 28, y: 30))
        #expect(harness.viewModel.patternPlacementPhase.isAdjusting)
        harness.viewModel.commitActivePatternPlacement()
        try await harness.waitForPatternPlacementCommitToFinish()

        #expect(harness.viewModel.patternPlacementPhase == .armed(itemID: itemID))
        #expect(harness.viewModel.workspace.document.layers.count == originalLayerCount)
        #expect(harness.viewModel.workspace.document.activeLayerID == originalLayerID)
        #expect(try harness.alpha(atX: 20, y: 22, layerID: originalLayerID) > 0.7)

        harness.viewModel.undo()
        #expect(harness.viewModel.workspace.document.layers.count == originalLayerCount)
        #expect(try harness.alpha(atX: 20, y: 22, layerID: originalLayerID) < 0.05)

        harness.viewModel.redo()
        #expect(harness.viewModel.workspace.document.layers.count == originalLayerCount)
        #expect(try harness.alpha(atX: 20, y: 22, layerID: originalLayerID) > 0.7)
    }

    @Test
    @MainActor
    func shiftPatternPlacementCommitCreatesNewLayerSupportsUndoRedoAndRearmsSelection() async throws {
        let harness = try PatternPlacementHarness()
        defer { harness.cleanup() }

        let itemID = try #require(harness.viewModel.workspace.patternLibrary.items.first?.id)
        let originalLayerCount = harness.viewModel.workspace.document.layers.count
        let originalLayerID = harness.viewModel.workspace.document.activeLayerID
        harness.viewModel.selectPatternLibraryItem(itemID)

        harness.viewModel.beginPatternPlacementDrag(at: .init(x: 12, y: 14), placeIntoNewLayer: true)
        harness.viewModel.updatePatternPlacementDrag(to: .init(x: 28, y: 30))
        harness.viewModel.endPatternPlacementDrag(at: .init(x: 28, y: 30))
        #expect(harness.viewModel.patternPlacementPhase.isAdjusting)
        harness.viewModel.commitActivePatternPlacement()
        try await harness.waitForPatternPlacementCommitToFinish()

        let placedLayerID = harness.viewModel.workspace.document.activeLayerID

        #expect(harness.viewModel.patternPlacementPhase == .armed(itemID: itemID))
        #expect(harness.viewModel.workspace.document.layers.count == originalLayerCount + 1)
        #expect(placedLayerID != originalLayerID)
        #expect(try harness.alpha(atX: 20, y: 22, layerID: placedLayerID) > 0.7)
        #expect(try harness.alpha(atX: 20, y: 22, layerID: originalLayerID) < 0.05)

        harness.viewModel.undo()
        #expect(harness.viewModel.workspace.document.layers.count == originalLayerCount)
        #expect(harness.viewModel.workspace.document.layers.contains(where: { $0.id == placedLayerID }) == false)
        #expect(try harness.alpha(atX: 20, y: 22, layerID: originalLayerID) < 0.05)

        harness.viewModel.redo()
        #expect(harness.viewModel.workspace.document.layers.count == originalLayerCount + 1)
        #expect(harness.viewModel.workspace.document.layers.contains(where: { $0.id == placedLayerID }))
        #expect(try harness.alpha(atX: 20, y: 22, layerID: placedLayerID) > 0.7)
    }

    @Test
    @MainActor
    func tinyPatternPlacementReturnsToArmedStateWithoutCreatingHistory() throws {
        let harness = try PatternPlacementHarness()
        defer { harness.cleanup() }

        let itemID = try #require(harness.viewModel.workspace.patternLibrary.items.first?.id)
        let layerID = harness.viewModel.workspace.document.activeLayerID
        let originalLayerCount = harness.viewModel.workspace.document.layers.count
        harness.viewModel.selectPatternLibraryItem(itemID)

        harness.viewModel.beginPatternPlacementDrag(at: .init(x: 12, y: 12))
        harness.viewModel.endPatternPlacementDrag(at: .init(x: 14, y: 14))

        #expect(harness.viewModel.patternPlacementPhase == .armed(itemID: itemID))
        #expect(harness.viewModel.canUndo == false)
        #expect(harness.viewModel.workspace.document.layers.count == originalLayerCount)
        #expect(try harness.alpha(atX: 13, y: 13, layerID: layerID) < 0.05)
    }

    @Test
    func patternPlacementDestinationRectPreservesSourceAspectRatio() {
        let rect = PatternPlacementDraft.destinationRect(
            startCanvasPoint: .init(x: 10, y: 10),
            currentCanvasPoint: .init(x: 50, y: 25),
            preservingAspectRatio: 2
        )

        #expect(abs((rect.width / rect.height) - 2) < 0.000_001)
        #expect(rect.minX == 10)
        #expect(rect.minY == 10)
    }
}

private struct PatternPlacementHarness {
    let tempRootURL: URL
    let bootstrap: AppBootstrap
    let viewModel: WorkspaceViewModel

    @MainActor
    init(canvasSize: CanvasSize = .init(width: 64, height: 64)) throws {
        guard let metalContext = MetalDeviceContext() else {
            throw PatternPlacementHarnessError.metalUnavailable
        }

        let tempRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtFlexPatternPlacementTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRootURL, withIntermediateDirectories: true)

        let controller = PatternLibraryPersistenceController(rootDirectoryURL: tempRootURL)
        let sourceURL = tempRootURL.appendingPathComponent("pattern-source.png")
        try writePatternPlacementPNG(
            to: sourceURL,
            width: 8,
            height: 8,
            rgbaBytes: [UInt8](repeating: 0, count: 8 * 8 * 4).enumerated().map { index, _ in
                let channel = index % 4
                return channel == 3 ? 255 : 0
            }
        )
        _ = try controller.importFiles(
            [sourceURL],
            recipe: .init(mode: .originalColor, contrast: 0, autoCropToContent: false),
            into: .init()
        )

        let workspaceStore = WorkspaceStore(state: .stageOneDefault)
        workspaceStore.updateDocument { document in
            document.canvasSize = canvasSize
        }
        let bootstrap = try AppBootstrap(
            workspaceStore: workspaceStore,
            metalContext: metalContext,
            layerSurfaceStore: StageOneLayerSurfaceStore(),
            patternLibraryPersistenceController: controller
        )
        let viewModel = WorkspaceViewModel(
            bootstrap: bootstrap,
            installsZoomKeyboardMonitor: false
        )

        self.tempRootURL = tempRootURL
        self.bootstrap = bootstrap
        self.viewModel = viewModel
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: tempRootURL)
    }

    func alpha(atX x: Int, y: Int, layerID: LayerID) throws -> Float {
        try color(atX: x, y: y, layerID: layerID).alpha
    }

    func color(atX x: Int, y: Int, layerID: LayerID) throws -> RGBAColor {
        guard
            let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: layerID),
            let texture = bootstrap.layerSurfaceStore.texture(for: surfaceID)
        else {
            throw PatternPlacementHarnessError.textureUnavailable
        }
        return try bootstrap.textureSerializer.samplePixel(texture: texture, x: x, y: y)
    }

    @MainActor
    func waitForPatternPlacementCommitToFinish(timeoutIterations: Int = 80) async throws {
        for _ in 0..<timeoutIterations {
            if !viewModel.isApplyingPatternPlacementCommit {
                return
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }

        throw PatternPlacementHarnessError.commitTimeout
    }
}

private enum PatternPlacementHarnessError: Error {
    case metalUnavailable
    case textureUnavailable
    case commitTimeout
}

private func makePatternPlacementKeyEvent(
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

private func writePatternPlacementPNG(
    to url: URL,
    width: Int,
    height: Int,
    rgbaBytes: [UInt8]
) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    guard
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
        let provider = CGDataProvider(data: Data(rgbaBytes) as CFData),
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ),
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        )
    else {
        throw CocoaError(.fileWriteUnknown)
    }

    CGImageDestinationAddImage(destination, image, nil)
    if !CGImageDestinationFinalize(destination) {
        throw CocoaError(.fileWriteUnknown)
    }
}

import Foundation
import Metal
import AppKit
import Testing
@testable import ArtFlex

struct SmartSelectionTests {
    @Test
    func magicWandKeepsTheSelectionGroupButUsesClickOnlyCanvasInput() throws {
        let group = try #require(ToolSidebarGroup.orderedGroups.first { $0.id == "selection-l" })
        #expect(group.tools == [.lassoSelection, .smartSelection, .polygonSelection])
        #expect(ToolKind.smartSelection.displayName == "魔棒选区")
        #expect(ToolKind.smartSelection.shortcutKey == "L")
        #expect(!ToolKind.smartSelection.supportsOutsideCanvasSelectionStart)
    }

    @Test
    func settingsClampAndMigrateTheLegacyPercentageTolerance() throws {
        #expect(SmartSelectionSettings(tolerance: -2).tolerance == 0)
        #expect(SmartSelectionSettings(tolerance: 999).tolerance == 255)
        let defaults = try JSONDecoder().decode(SmartSelectionSettings.self, from: Data("{}".utf8))
        #expect(defaults == .stageOneDefault)
        #expect(defaults.sampleSource == .allVisibleLayers)
        let migrated = try JSONDecoder().decode(
            SmartSelectionSettings.self,
            from: Data(#"{"tolerance":0.5}"#.utf8)
        )
        #expect(migrated.tolerance == 128)
    }

    @MainActor
    @Test
    func defaultSamplingSelectsTheVisibleColorWhenTheActiveLayerIsBlank() async throws {
        let harness = try SmartSelectionWorkspaceHarness(canvasSize: .init(width: 32, height: 20))
        try harness.paintBlocks()
        let viewModel = harness.viewModel
        viewModel.addLayer()
        #expect(viewModel.smartSelectionSettings.sampleSource == .allVisibleLayers)
        viewModel.selectTool(.smartSelection)
        viewModel.setSmartSelectionTolerance(0)

        viewModel.handleCanvasToolClick(at: .init(x: 8, y: 10))
        await waitForSelectionRefinement(viewModel)

        let selection = try #require(viewModel.workspace.selection.committedShape)
        #expect(selection.contains(.init(x: 8, y: 10)))
        #expect(!selection.contains(.init(x: 1, y: 1)))
        #expect(!selection.contains(.init(x: 24, y: 10)))
    }

    @Test
    func contiguousModeSelectsOnlyTheSeedConnectedColor() throws {
        let raster = separatedRedBlocksRaster()
        let result = try #require(SmartSelectionSegmenter.segment(
            raster: raster,
            seedPoint: .init(x: 3, y: 3),
            settings: .init(tolerance: 0, isAntiAliased: false, isContiguous: true)
        ))

        #expect(result.alphaBytes[(3 * raster.width) + 3] == 255)
        #expect(result.alphaBytes[(3 * raster.width) + 11] == 0)
        #expect(result.selectedPixelCount == 16)
    }

    @Test
    func noncontiguousModeSelectsSeparatedMatchingColors() throws {
        let raster = separatedRedBlocksRaster()
        let result = try #require(SmartSelectionSegmenter.segment(
            raster: raster,
            seedPoint: .init(x: 3, y: 3),
            settings: .init(tolerance: 0, isAntiAliased: false, isContiguous: false)
        ))

        #expect(result.alphaBytes[(3 * raster.width) + 3] == 255)
        #expect(result.alphaBytes[(3 * raster.width) + 11] == 255)
        #expect(result.alphaBytes[(0 * raster.width) + 0] == 0)
        #expect(result.selectedPixelCount == 32)
    }

    @Test
    func toleranceControlsHowFarTheConnectedSelectionExpands() throws {
        let width = 9
        let height = 3
        var bytes = solidBGRA(width: width, height: height, color: (0, 0, 0, 255))
        for x in 0..<width {
            setPixel(x: x, y: 1, canvasWidth: width, bytes: &bytes, color: (0, 0, UInt8(x * 12), 255))
        }
        let raster = SmartSelectionRaster(
            originX: 0,
            originY: 0,
            width: width,
            height: height,
            bytesPerRow: width * 4,
            premultipliedBGRABytes: Data(bytes)
        )
        let tight = try #require(SmartSelectionSegmenter.segment(
            raster: raster,
            seedPoint: .init(x: 0, y: 1),
            settings: .init(tolerance: 0, isAntiAliased: false, isContiguous: true)
        ))
        let broad = try #require(SmartSelectionSegmenter.segment(
            raster: raster,
            seedPoint: .init(x: 0, y: 1),
            settings: .init(tolerance: 80, isAntiAliased: false, isContiguous: true)
        ))

        #expect(tight.alphaBytes[(1 * width) + 0] == 255)
        #expect(tight.alphaBytes[(1 * width) + 1] == 0)
        #expect(broad.selectedPixelCount > tight.selectedPixelCount)
        #expect(broad.alphaBytes[(1 * width) + 5] == 255)
    }

    @Test
    func antiAliasProducesPartialBoundaryCoverageInsteadOfASecondFeather() throws {
        let width = 2
        let height = 1
        var bytes = solidBGRA(width: width, height: height, color: (255, 255, 255, 255))
        setPixel(x: 1, y: 0, canvasWidth: width, bytes: &bytes, color: (254, 254, 254, 254))
        let result = try #require(SmartSelectionSegmenter.segment(
            raster: .init(
                originX: 0,
                originY: 0,
                width: width,
                height: height,
                bytesPerRow: width * 4,
                premultipliedBGRABytes: Data(bytes)
            ),
            seedPoint: .init(x: 0, y: 0),
            settings: .init(tolerance: 0, isAntiAliased: true, isContiguous: true)
        ))
        #expect(result.alphaBytes[0] == 255)
        #expect(result.alphaBytes[1] > 0)
        #expect(result.alphaBytes[1] < 255)
    }

    @MainActor
    @Test
    func canvasClicksReplaceAddSubtractAndIntersectWithoutDrawingALasso() async throws {
        let harness = try SmartSelectionWorkspaceHarness(canvasSize: .init(width: 32, height: 20))
        try harness.paintBlocks()
        let viewModel = harness.viewModel
        viewModel.selectTool(.smartSelection)
        viewModel.setSmartSelectionTolerance(0)

        viewModel.handleCanvasToolClick(at: .init(x: 8, y: 10))
        await waitForSelectionRefinement(viewModel)
        var selection = try #require(viewModel.workspace.selection.committedShape)
        #expect(selection.contains(.init(x: 8, y: 10)))
        #expect(!selection.contains(.init(x: 24, y: 10)))
        #expect(viewModel.workspace.selection.inProgressShape == nil)

        viewModel.handleCanvasToolClick(at: .init(x: 24, y: 10), modifiers: [.shift])
        await waitForSelectionRefinement(viewModel)
        selection = try #require(viewModel.workspace.selection.committedShape)
        #expect(selection.contains(.init(x: 8, y: 10)))
        #expect(selection.contains(.init(x: 24, y: 10)))

        viewModel.handleCanvasToolClick(at: .init(x: 8, y: 10), modifiers: [.option])
        await waitForSelectionRefinement(viewModel)
        selection = try #require(viewModel.workspace.selection.committedShape)
        #expect(!selection.contains(.init(x: 8, y: 10)))
        #expect(selection.contains(.init(x: 24, y: 10)))

        viewModel.handleCanvasToolClick(
            at: .init(x: 8, y: 10),
            modifiers: [.shift, .option]
        )
        await waitForSelectionRefinement(viewModel)
        #expect(viewModel.workspace.selection.committedShape == nil)
    }

    @MainActor
    @Test
    func magicWandSelectionCanBeAddedSubtractedAndIntersectedByLasso() async throws {
        let harness = try SmartSelectionWorkspaceHarness(canvasSize: .init(width: 32, height: 20))
        try harness.paintBlocks()
        let viewModel = harness.viewModel
        viewModel.selectTool(.smartSelection)
        viewModel.setSmartSelectionTolerance(0)
        viewModel.handleCanvasToolClick(at: .init(x: 8, y: 10))
        await waitForSelectionRefinement(viewModel)

        let left = [
            CanvasPoint(x: 3, y: 3), CanvasPoint(x: 14, y: 3),
            CanvasPoint(x: 14, y: 17), CanvasPoint(x: 3, y: 17),
            CanvasPoint(x: 3, y: 3),
        ]
        let right = [
            CanvasPoint(x: 19, y: 3), CanvasPoint(x: 30, y: 3),
            CanvasPoint(x: 30, y: 17), CanvasPoint(x: 19, y: 17),
            CanvasPoint(x: 19, y: 3),
        ]

        viewModel.selectTool(.lassoSelection)
        let committedRevision = viewModel.selectionOverlayProxy.committedShapeRevision
        beginLasso(right, modifiers: [.shift], viewModel: viewModel)
        #expect(viewModel.selectionOverlayProxy.activeCombineMode == .add)
        #expect(viewModel.selectionOverlayProxy.committedShapeRevision == committedRevision)
        await finishLasso(right, modifiers: [.shift], viewModel: viewModel)
        var selection = try #require(viewModel.workspace.selection.committedShape)
        #expect(selection.components.isEmpty)
        #expect(selection.contains(.init(x: 8, y: 10)))
        #expect(selection.contains(.init(x: 24, y: 10)))

        beginLasso(left, modifiers: [.shift, .option], viewModel: viewModel)
        #expect(viewModel.selectionOverlayProxy.activeCombineMode == .intersect)
        await finishLasso(left, modifiers: [.shift, .option], viewModel: viewModel)
        selection = try #require(viewModel.workspace.selection.committedShape)
        #expect(selection.contains(.init(x: 8, y: 10)))
        #expect(!selection.contains(.init(x: 24, y: 10)))

        beginLasso(right, modifiers: [.shift], viewModel: viewModel)
        await finishLasso(right, modifiers: [.shift], viewModel: viewModel)
        selection = try #require(viewModel.workspace.selection.committedShape)
        #expect(selection.contains(.init(x: 8, y: 10)))
        #expect(selection.contains(.init(x: 24, y: 10)))

        beginLasso(left, modifiers: [.option], viewModel: viewModel)
        #expect(viewModel.selectionOverlayProxy.activeCombineMode == .subtract)
        await finishLasso(left, modifiers: [.option], viewModel: viewModel)
        selection = try #require(viewModel.workspace.selection.committedShape)
        #expect(!selection.contains(.init(x: 8, y: 10)))
        #expect(selection.contains(.init(x: 24, y: 10)))
    }

    @Test
    func sharedMaskCombinerPreservesFractionalCoverageForAllFourModes() {
        let base: [UInt8] = [0, 64, 128, 255]
        let incoming: [UInt8] = [255, 128, 64, 0]

        #expect(SelectionMaskCombiner.combine(base: base, incoming: incoming, mode: .replace) == incoming)
        #expect(SelectionMaskCombiner.combine(base: base, incoming: incoming, mode: .add) == [255, 128, 128, 255])
        #expect(SelectionMaskCombiner.combine(base: base, incoming: incoming, mode: .subtract) == [0, 32, 96, 255])
        #expect(SelectionMaskCombiner.combine(base: base, incoming: incoming, mode: .intersect) == [0, 32, 32, 0])
    }

    @Test
    func boundedMaskCombinerUpdatesOnlyTheIncomingRegion() throws {
        let width = 6
        let height = 4
        var base = Data(count: width * height)
        base.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for y in 1...2 {
                for x in 1...3 {
                    bytes[(y * width) + x] = 255
                }
            }
        }
        let patch = SelectionMaskCombiner.Patch(
            originX: 3,
            originY: 0,
            width: 2,
            height: 3,
            alphaBytes: Data(repeating: 255, count: 6)
        )
        let baseBounds = CanvasRect(
            origin: .init(x: 1, y: 1),
            size: .init(x: 3, y: 2)
        )

        let added = SelectionMaskCombiner.combineCanvas(
            base: base,
            baseBounds: baseBounds,
            incoming: patch,
            canvasWidth: width,
            canvasHeight: height,
            mode: .add
        )
        #expect(added.alphaBytes[(0 * width) + 3] == 255)
        #expect(added.alphaBytes[(2 * width) + 4] == 255)
        #expect(added.alphaBytes[(3 * width) + 4] == 0)
        #expect(added.bounds == .init(origin: .init(x: 1, y: 0), size: .init(x: 4, y: 3)))

        let subtracted = SelectionMaskCombiner.combineCanvas(
            base: base,
            baseBounds: baseBounds,
            incoming: patch,
            canvasWidth: width,
            canvasHeight: height,
            mode: .subtract
        )
        #expect(subtracted.alphaBytes[(1 * width) + 2] == 255)
        #expect(subtracted.alphaBytes[(1 * width) + 3] == 0)
        #expect(subtracted.bounds == .init(origin: .init(x: 1, y: 1), size: .init(x: 2, y: 2)))

        let intersected = SelectionMaskCombiner.combineCanvas(
            base: base,
            baseBounds: baseBounds,
            incoming: patch,
            canvasWidth: width,
            canvasHeight: height,
            mode: .intersect
        )
        #expect(intersected.alphaBytes[(1 * width) + 3] == 255)
        #expect(intersected.alphaBytes[(1 * width) + 2] == 0)
        #expect(intersected.bounds == .init(origin: .init(x: 3, y: 1), size: .init(x: 1, y: 2)))
    }

    @MainActor
    @Test
    func numberKeysMapPercentagesOntoTheZeroTo255Tolerance() throws {
        let harness = try SmartSelectionWorkspaceHarness(canvasSize: .init(width: 32, height: 20))
        let viewModel = harness.viewModel
        viewModel.selectTool(.smartSelection)

        for digit in 1...9 {
            #expect(viewModel.handleKeyDown(numberKeyEvent(character: String(digit), keyCode: UInt16(digit))))
            let expected = Int((Double(digit * 10) * 2.55).rounded())
            #expect(viewModel.smartSelectionSettings.tolerance == expected)
        }
        #expect(viewModel.handleKeyDown(numberKeyEvent(character: "0", keyCode: 29)))
        #expect(viewModel.smartSelectionSettings.tolerance == 255)
    }

    @MainActor
    @Test
    func enterStillTogglesTheRequestedTintPreviewAndMarchingAnts() async throws {
        let harness = try SmartSelectionWorkspaceHarness(canvasSize: .init(width: 32, height: 20))
        try harness.paintBlocks()
        let viewModel = harness.viewModel
        viewModel.selectTool(.smartSelection)
        viewModel.handleCanvasToolClick(at: .init(x: 8, y: 10))
        await waitForSelectionRefinement(viewModel)

        #expect(viewModel.smartSelectionDisplayMode == .tint)
        #expect(viewModel.handleKeyDown(returnKeyEvent()))
        #expect(viewModel.smartSelectionDisplayMode == .marchingAnts)
        #expect(viewModel.handleKeyDown(returnKeyEvent()))
        #expect(viewModel.smartSelectionDisplayMode == .tint)
    }

    @MainActor
    private func waitForSelectionRefinement(_ viewModel: WorkspaceViewModel) async {
        for _ in 0..<300 where viewModel.isRefiningSelection {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    private func beginLasso(
        _ points: [CanvasPoint],
        modifiers: NSEvent.ModifierFlags,
        viewModel: WorkspaceViewModel
    ) {
        guard let first = points.first else { return }
        let action = viewModel.handleSelectionMouseDown(at: first, modifiers: modifiers)
        guard case .beginDrawing = action else {
            Issue.record("Expected the modified lasso press to begin drawing")
            return
        }
        for point in points.dropFirst().dropLast() {
            viewModel.updateSelection(to: point, modifiers: modifiers)
        }
    }

    @MainActor
    private func finishLasso(
        _ points: [CanvasPoint],
        modifiers: NSEvent.ModifierFlags,
        viewModel: WorkspaceViewModel
    ) async {
        guard let last = points.last else { return }
        viewModel.commitSelection(at: last, modifiers: modifiers)
        for _ in 0..<300 {
            if viewModel.selectionOverlayProxy.inProgressShape == nil,
               viewModel.selectionOverlayProxy.activeCombineMode == .replace {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func separatedRedBlocksRaster() -> SmartSelectionRaster {
        let width = 16
        let height = 8
        var bytes = solidBGRA(width: width, height: height, color: (255, 255, 255, 255))
        fillRect(x: 2, y: 2, width: 4, height: 4, canvasWidth: width, bytes: &bytes, color: (0, 0, 255, 255))
        fillRect(x: 10, y: 2, width: 4, height: 4, canvasWidth: width, bytes: &bytes, color: (0, 0, 255, 255))
        return SmartSelectionRaster(
            originX: 0,
            originY: 0,
            width: width,
            height: height,
            bytesPerRow: width * 4,
            premultipliedBGRABytes: Data(bytes)
        )
    }

    private func solidBGRA(
        width: Int,
        height: Int,
        color: (UInt8, UInt8, UInt8, UInt8)
    ) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        fillRect(x: 0, y: 0, width: width, height: height, canvasWidth: width, bytes: &bytes, color: color)
        return bytes
    }

    private func fillRect(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        canvasWidth: Int,
        bytes: inout [UInt8],
        color: (UInt8, UInt8, UInt8, UInt8)
    ) {
        for row in y..<(y + height) {
            for column in x..<(x + width) {
                setPixel(x: column, y: row, canvasWidth: canvasWidth, bytes: &bytes, color: color)
            }
        }
    }

    private func setPixel(
        x: Int,
        y: Int,
        canvasWidth: Int,
        bytes: inout [UInt8],
        color: (UInt8, UInt8, UInt8, UInt8)
    ) {
        let offset = ((y * canvasWidth) + x) * 4
        bytes[offset] = color.0
        bytes[offset + 1] = color.1
        bytes[offset + 2] = color.2
        bytes[offset + 3] = color.3
    }
}

@MainActor
private func numberKeyEvent(character: String, keyCode: UInt16) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0,
        context: nil,
        characters: character,
        charactersIgnoringModifiers: character,
        isARepeat: false,
        keyCode: keyCode
    )!
}

@MainActor
private func returnKeyEvent() -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0,
        context: nil,
        characters: "\r",
        charactersIgnoringModifiers: "\r",
        isARepeat: false,
        keyCode: 36
    )!
}

@MainActor
private struct SmartSelectionWorkspaceHarness {
    let bootstrap: AppBootstrap
    let viewModel: WorkspaceViewModel

    init(canvasSize: CanvasSize) throws {
        guard let metalContext = MetalDeviceContext() else {
            throw CocoaError(.featureUnsupported)
        }
        let store = WorkspaceStore(state: .stageOneDefault)
        store.updateDocument { document in document.canvasSize = canvasSize }
        bootstrap = try AppBootstrap(
            workspaceStore: store,
            metalContext: metalContext,
            layerSurfaceStore: StageOneLayerSurfaceStore()
        )
        viewModel = WorkspaceViewModel(bootstrap: bootstrap, installsZoomKeyboardMonitor: false)
    }

    func paintBlocks() throws {
        let layerID = viewModel.workspace.document.activeLayerID
        let surfaceID = try #require(bootstrap.layerSurfaceStore.surfaceID(for: layerID))
        let texture = try #require(bootstrap.layerSurfaceStore.texture(for: surfaceID))
        let width = texture.width
        let height = texture.height
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        fillRect(x: 4, y: 4, width: 9, height: 12, canvasWidth: width, bytes: &bytes, color: (35, 55, 220, 255))
        fillRect(x: 20, y: 4, width: 9, height: 12, canvasWidth: width, bytes: &bytes, color: (40, 190, 60, 255))
        try bootstrap.textureSerializer.restore(
            snapshot: LayerTextureSnapshot(
                width: width,
                height: height,
                bytesPerRow: width * 4,
                pixelData: Data(bytes)
            ),
            into: texture
        )
        bootstrap.layerSurfaceStore.markContentUnknown(for: [layerID])
    }

    private func fillRect(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        canvasWidth: Int,
        bytes: inout [UInt8],
        color: (UInt8, UInt8, UInt8, UInt8)
    ) {
        for row in y..<(y + height) {
            for column in x..<(x + width) {
                let offset = ((row * canvasWidth) + column) * 4
                bytes[offset] = color.0
                bytes[offset + 1] = color.1
                bytes[offset + 2] = color.2
                bytes[offset + 3] = color.3
            }
        }
    }
}

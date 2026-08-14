import Foundation
import Metal
import AppKit
import Testing
@testable import ArtFlex

struct SmartSelectionTests {
    @Test
    func toolLivesInLassoGroupAndUsesLassoShortcut() throws {
        let group = try #require(ToolSidebarGroup.orderedGroups.first { $0.id == "selection-l" })
        #expect(group.tools == [.lassoSelection, .smartSelection, .polygonSelection])
        #expect(ToolKind.smartSelection.shortcutKey == "L")
        #expect(ToolKind.smartSelection.supportsOutsideCanvasSelectionStart)
    }

    @Test
    func settingsClampAndDecodeOlderData() throws {
        #expect(SmartSelectionSettings(tolerance: -2).tolerance == 0)
        #expect(SmartSelectionSettings(tolerance: 2).tolerance == 1)
        let decoded = try JSONDecoder().decode(
            SmartSelectionSettings.self,
            from: Data("{}".utf8)
        )
        #expect(decoded == .stageOneDefault)
    }

    @Test
    func roughLassoSelectsContrastingConnectedColorBlock() throws {
        let width = 20
        let height = 16
        var bytes = makeSolidBGRA(width: width, height: height, color: (blue: 210, green: 74, red: 50, alpha: 255))
        fillRect(
            x: 6,
            y: 4,
            width: 8,
            height: 8,
            canvasWidth: width,
            bytes: &bytes,
            color: (blue: 40, green: 60, red: 220, alpha: 255)
        )

        let result = try #require(SmartSelectionSegmenter.segment(
            raster: .init(
                originX: 0,
                originY: 0,
                width: width,
                height: height,
                bytesPerRow: width * 4,
                premultipliedBGRABytes: Data(bytes)
            ),
            lassoPoints: rectangleLasso(minX: 2, minY: 1, maxX: 18, maxY: 15),
            settings: .init(tolerance: 0.12)
        ))

        #expect(result.alphaBytes[(8 * width) + 9] > 0)
        #expect(result.alphaBytes[(2 * width) + 3] == 0)
        #expect(result.selectedPixelCount >= 60)
        #expect(result.selectedPixelCount <= 70)
        #expect(result.selectedBounds == CanvasRect(
            origin: .init(x: 6, y: 4),
            size: .init(x: 8, y: 8)
        ))
    }

    @Test
    func largerToleranceIncludesNearbyToneButStillRespectsLasso() throws {
        let width = 24
        let height = 14
        var bytes = makeSolidBGRA(width: width, height: height, color: (blue: 205, green: 70, red: 48, alpha: 255))
        fillRect(
            x: 5,
            y: 3,
            width: 5,
            height: 8,
            canvasWidth: width,
            bytes: &bytes,
            color: (blue: 38, green: 58, red: 220, alpha: 255)
        )
        fillRect(
            x: 10,
            y: 3,
            width: 5,
            height: 8,
            canvasWidth: width,
            bytes: &bytes,
            color: (blue: 42, green: 105, red: 202, alpha: 255)
        )
        fillRect(
            x: 19,
            y: 3,
            width: 4,
            height: 8,
            canvasWidth: width,
            bytes: &bytes,
            color: (blue: 38, green: 58, red: 220, alpha: 255)
        )
        let raster = SmartSelectionRaster(
            originX: 0,
            originY: 0,
            width: width,
            height: height,
            bytesPerRow: width * 4,
            premultipliedBGRABytes: Data(bytes)
        )
        let lasso = rectangleLasso(minX: 1, minY: 1, maxX: 18, maxY: 13)
        let tight = try #require(SmartSelectionSegmenter.segment(
            raster: raster,
            lassoPoints: lasso,
            settings: .init(tolerance: 0.04)
        ))
        let broad = try #require(SmartSelectionSegmenter.segment(
            raster: raster,
            lassoPoints: lasso,
            settings: .init(tolerance: 0.5)
        ))

        let tightFirstTone = tight.alphaBytes[(7 * width) + 7] > 0
        let tightSecondTone = tight.alphaBytes[(7 * width) + 12] > 0
        #expect(tightFirstTone != tightSecondTone)
        #expect(broad.alphaBytes[(7 * width) + 7] > 0)
        #expect(broad.alphaBytes[(7 * width) + 12] > 0)
        #expect(broad.selectedPixelCount > tight.selectedPixelCount)
        #expect(broad.alphaBytes[(7 * width) + 20] == 0)
    }

    @MainActor
    @Test
    func workspaceGestureCommitsSmartSelectionAndShiftAddsAnotherBlock() async throws {
        let harness = try SmartSelectionWorkspaceHarness(canvasSize: .init(width: 32, height: 20))
        try harness.paintBlocks()
        let viewModel = harness.viewModel
        viewModel.selectTool(.smartSelection)
        viewModel.setSmartSelectionTolerance(0.12)

        let firstAction = viewModel.handleSelectionMouseDown(
            at: .init(x: 2, y: 2),
            modifiers: []
        )
        #expect(firstAction == .beginDrawing)
        viewModel.updateSelection(to: [
            .init(x: 16, y: 2),
            .init(x: 16, y: 17),
            .init(x: 2, y: 17),
            .init(x: 2, y: 2)
        ])
        viewModel.commitSelection(at: .init(x: 2, y: 2))
        await waitForSelectionRefinement(viewModel)

        let firstSelection = try #require(viewModel.workspace.selection.committedShape)
        #expect(firstSelection.contains(.init(x: 8, y: 10)))
        #expect(!firstSelection.contains(.init(x: 24, y: 10)))

        let addAction = viewModel.handleSelectionMouseDown(
            at: .init(x: 17, y: 2),
            modifiers: [.shift]
        )
        #expect(addAction == .beginDrawing)
        viewModel.updateSelection(
            to: [
                .init(x: 30, y: 2),
                .init(x: 30, y: 17),
                .init(x: 17, y: 17),
                .init(x: 17, y: 2)
            ],
            modifiers: [.shift]
        )
        viewModel.commitSelection(at: .init(x: 17, y: 2), modifiers: [.shift])
        await waitForSelectionRefinement(viewModel)

        let combined = try #require(viewModel.workspace.selection.committedShape)
        #expect(combined.contains(.init(x: 8, y: 10)))
        #expect(combined.contains(.init(x: 24, y: 10)))

        let subtractAction = viewModel.handleSelectionMouseDown(
            at: .init(x: 17, y: 2),
            modifiers: [.option]
        )
        #expect(subtractAction == .beginDrawing)
        viewModel.updateSelection(
            to: [
                .init(x: 30, y: 2),
                .init(x: 30, y: 17),
                .init(x: 17, y: 17),
                .init(x: 17, y: 2)
            ],
            modifiers: [.option]
        )
        viewModel.commitSelection(at: .init(x: 17, y: 2), modifiers: [.option])
        await waitForSelectionRefinement(viewModel)

        let subtracted = try #require(viewModel.workspace.selection.committedShape)
        #expect(subtracted.contains(.init(x: 8, y: 10)))
        #expect(!subtracted.contains(.init(x: 24, y: 10)))
    }

    @MainActor
    @Test
    func shiftRecognitionTreatsTheNewRoughRegionAsAnIndependentColorTarget() async throws {
        let harness = try SmartSelectionWorkspaceHarness(canvasSize: .init(width: 32, height: 20))
        try harness.paintBlocks()
        let viewModel = harness.viewModel
        viewModel.selectTool(.smartSelection)
        viewModel.setSmartSelectionTolerance(0.05)

        _ = viewModel.handleSelectionMouseDown(at: .init(x: 2, y: 2), modifiers: [])
        viewModel.updateSelection(to: rectangleLasso(minX: 2, minY: 2, maxX: 16, maxY: 18))
        viewModel.commitSelection(at: .init(x: 2, y: 2))
        await waitForSelectionRefinement(viewModel)
        #expect(viewModel.workspace.selection.committedShape?.contains(.init(x: 8, y: 10)) == true)

        // Deliberately circle both the old red block and the new green block.
        // Shift must exclude the existing selection from this round's seed search,
        // otherwise the salient old color can be selected a second time.
        _ = viewModel.handleSelectionMouseDown(at: .init(x: 2, y: 2), modifiers: [.shift])
        viewModel.updateSelection(
            to: rectangleLasso(minX: 2, minY: 2, maxX: 30, maxY: 18),
            modifiers: [.shift]
        )
        viewModel.commitSelection(at: .init(x: 2, y: 2), modifiers: [.shift])
        await waitForSelectionRefinement(viewModel)

        let combined = try #require(viewModel.workspace.selection.committedShape)
        #expect(combined.contains(.init(x: 8, y: 10)))
        #expect(combined.contains(.init(x: 24, y: 10)))
    }

    @MainActor
    @Test
    func numberKeysSetThresholdOnlyWhileSmartSelectionIsActive() throws {
        let harness = try SmartSelectionWorkspaceHarness(canvasSize: .init(width: 32, height: 20))
        let viewModel = harness.viewModel
        viewModel.selectTool(.smartSelection)

        for digit in 1...9 {
            let handled = viewModel.handleKeyDown(numberKeyEvent(
                character: String(digit),
                keyCode: UInt16(digit)
            ))
            #expect(handled)
            #expect(abs(viewModel.smartSelectionSettings.tolerance - (Float(digit) / 10)) < 0.0001)
        }

        let zeroHandled = viewModel.handleKeyDown(numberKeyEvent(character: "0", keyCode: 29))
        #expect(zeroHandled)
        #expect(viewModel.smartSelectionSettings.tolerance == 1)

        viewModel.selectTool(.brush)
        viewModel.setSmartSelectionTolerance(0.3)
        _ = viewModel.handleKeyDown(numberKeyEvent(character: "8", keyCode: 28))
        #expect(abs(viewModel.smartSelectionSettings.tolerance - 0.3) < 0.0001)
    }

    @MainActor
    @Test
    func enterTogglesRecognizedMaskBetweenTintAndMarchingAnts() async throws {
        let harness = try SmartSelectionWorkspaceHarness(canvasSize: .init(width: 32, height: 20))
        try harness.paintBlocks()
        let viewModel = harness.viewModel
        viewModel.selectTool(.smartSelection)

        #expect(!viewModel.handleKeyDown(returnKeyEvent()))
        _ = viewModel.handleSelectionMouseDown(at: .init(x: 2, y: 2), modifiers: [])
        viewModel.updateSelection(to: rectangleLasso(minX: 2, minY: 2, maxX: 16, maxY: 18))
        viewModel.commitSelection(at: .init(x: 2, y: 2))
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

    private func rectangleLasso(minX: Double, minY: Double, maxX: Double, maxY: Double) -> [CanvasPoint] {
        [
            .init(x: minX, y: minY),
            .init(x: maxX, y: minY),
            .init(x: maxX, y: maxY),
            .init(x: minX, y: maxY),
            .init(x: minX, y: minY)
        ]
    }

    private func makeSolidBGRA(
        width: Int,
        height: Int,
        color: (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8)
    ) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        fillRect(
            x: 0,
            y: 0,
            width: width,
            height: height,
            canvasWidth: width,
            bytes: &bytes,
            color: color
        )
        return bytes
    }

    private func fillRect(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        canvasWidth: Int,
        bytes: inout [UInt8],
        color: (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8)
    ) {
        for row in y..<(y + height) {
            for column in x..<(x + width) {
                let offset = ((row * canvasWidth) + column) * 4
                bytes[offset] = color.blue
                bytes[offset + 1] = color.green
                bytes[offset + 2] = color.red
                bytes[offset + 3] = color.alpha
            }
        }
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
        store.updateDocument { document in
            document.canvasSize = canvasSize
        }
        bootstrap = try AppBootstrap(
            workspaceStore: store,
            metalContext: metalContext,
            layerSurfaceStore: StageOneLayerSurfaceStore()
        )
        viewModel = WorkspaceViewModel(
            bootstrap: bootstrap,
            installsZoomKeyboardMonitor: false
        )
    }

    func paintBlocks() throws {
        let layerID = viewModel.workspace.document.activeLayerID
        let surfaceID = try #require(bootstrap.layerSurfaceStore.surfaceID(for: layerID))
        let texture = try #require(bootstrap.layerSurfaceStore.texture(for: surfaceID))
        let width = texture.width
        let height = texture.height
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        fillRect(
            x: 4,
            y: 4,
            width: 9,
            height: 12,
            canvasWidth: width,
            bytes: &bytes,
            color: (blue: 35, green: 55, red: 220, alpha: 255)
        )
        fillRect(
            x: 20,
            y: 4,
            width: 9,
            height: 12,
            canvasWidth: width,
            bytes: &bytes,
            color: (blue: 40, green: 190, red: 60, alpha: 255)
        )
        let snapshot = LayerTextureSnapshot(
            width: width,
            height: height,
            bytesPerRow: width * 4,
            pixelData: Data(bytes)
        )
        try bootstrap.textureSerializer.restore(snapshot: snapshot, into: texture)
        bootstrap.layerSurfaceStore.markContentUnknown(for: [layerID])
    }

    private func fillRect(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        canvasWidth: Int,
        bytes: inout [UInt8],
        color: (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8)
    ) {
        for row in y..<(y + height) {
            for column in x..<(x + width) {
                let offset = ((row * canvasWidth) + column) * 4
                bytes[offset] = color.blue
                bytes[offset + 1] = color.green
                bytes[offset + 2] = color.red
                bytes[offset + 3] = color.alpha
            }
        }
    }
}

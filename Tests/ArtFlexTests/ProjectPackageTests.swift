import Foundation
import Testing
@testable import ArtFlex

struct ProjectPackageTests {
    @Test
    func layerHistorySnapshotDecodesLegacyMissingOriginAsZero() throws {
        let json = """
        {
          "layerID": {
            "rawValue": "00000000-0000-0000-0000-000000000222"
          },
          "texture": {
            "width": 1,
            "height": 1,
            "bytesPerRow": 4,
            "pixelData": "AQIDBA=="
          }
        }
        """

        let snapshot = try JSONDecoder().decode(
            LayerHistorySnapshot.self,
            from: Data(json.utf8)
        )

        #expect(snapshot.originX == 0)
        #expect(snapshot.originY == 0)
        #expect(snapshot.texture.pixelData == Data([1, 2, 3, 4]))
    }

    @Test
    func packagePreservesWorkspaceStateAndLayerSnapshots() {
        var workspace = WorkspaceState.stageOneDefault
        let primaryMask = Data([11, 22, 140, 250])
        let primarySourceInfo = ImportedTipSourceInfo(
            sourceLabel: "Project Primary",
            pixelWidth: 192,
            pixelHeight: 128
        )

        var presetBrush = BrushSettings.stageOneDefault
        presetBrush.size = 18
        presetBrush.opacity = 0.6
        presetBrush.buildMode = .opacityCap
        presetBrush.tipShape = .customRound
        presetBrush.customTipSourceSemantic = .importedImage
        presetBrush.customTipImportedSourceInfo = primarySourceInfo
        presetBrush.customTipMaskData = primaryMask
        presetBrush.customTipSoftness = 0.82
        presetBrush.customTipRoundness = 0.58
        presetBrush.customTipAngleDegrees = 33
        presetBrush.jitterAmount = 0.32
        presetBrush.colorJitterAmount = 0.46
        presetBrush.pressureSensitivity = 1.6
        presetBrush.sizeLowerBound = 0.24
        presetBrush.pressureSizeAmount = 0.35
        presetBrush.pressureOpacityAmount = 0.7
        presetBrush.buildUpOpacityCompensationAmount = 0.44
        presetBrush.sizeCurveLow = 0.12
        presetBrush.sizeCurveMid = 0.58
        presetBrush.sizeCurveHigh = 0.91
        presetBrush.opacityCurveLow = 0.03
        presetBrush.opacityCurveMid = 0.48
        presetBrush.opacityCurveHigh = 0.86
        presetBrush.compoundBrush.enabled = true
        presetBrush.compoundBrush.globalPressureSizeAmount = 0.42
        presetBrush.compoundBrush.globalPressureOpacityAmount = 0.68
        presetBrush.compoundBrush.globalPaintJitterAmount = 0.57
        presetBrush.compoundBrush.globalPaintContrastAmount = 0.26
        workspace.toolSession.brush = presetBrush

        workspace.brushLibrary = BrushLibraryState(
            presets: [
                BrushPreset(
                    id: "custom-test",
                    name: "Custom Test",
                    brush: presetBrush,
                    isBuiltIn: false
                )
            ],
            selectedPresetID: "custom-test"
        )
        let patternID = UUID(uuidString: "00000000-0000-0000-0000-000000000111")!
        workspace.patternLibrary = PatternLibraryState(
            items: [
                PatternLibraryItem(
                    id: patternID,
                    displayName: "Pattern Test",
                    slotIndex: 5,
                    importRecipe: PatternImportRecipe(mode: .transparentMonochrome, contrast: 0.31),
                    originalFilename: "pattern.png",
                    sourcePixelWidth: 180,
                    sourcePixelHeight: 96,
                    renderAssetLocation: .managedCopy(relativePath: "Patterns/render/pattern.png"),
                    thumbnailLocation: .managedCopy(relativePath: "Patterns/thumb/pattern.png")
                )
            ],
            selectedItemID: patternID
        )
        workspace.tipImageLibrary = TipImageLibraryState(
            items: [
                TipImageLibraryItem(
                    id: BrushTipImageAssetID(maskData: primaryMask),
                    sourceInfo: primarySourceInfo,
                    maskData: primaryMask
                )
            ]
        )
        workspace.generator = GeneratorSettings(
            kind: .automaticLines,
            density: 0.72,
            drift: 0.41,
            branch: 0.63,
            opacity: 0.45
        )
        workspace.creativeShapeGenerator = CreativeShapeGeneratorState(
            selectedSource: .externalImage,
            formTendency: 0.67,
            complexity: 0.62,
            openness: 0.41,
            edgeCharacter: 0.44,
            surprise: 0.19,
            importedImage: CreativeShapeGeneratorImageSource(
                fileName: "reference.jpg",
                width: 128,
                height: 128,
                rgbaPixels: Data(repeating: 127, count: 128 * 128 * 4)
            )
        )
        let snapshot = LayerTextureSnapshot(
            width: 8,
            height: 8,
            bytesPerRow: 32,
            pixelData: Data([1, 2, 3, 4])
        )
        let layerSnapshots = [
            LayerHistorySnapshot(
                layerID: workspace.document.activeLayerID,
                texture: snapshot
            )
        ]

        let package = ProjectPackage.fromWorkspace(
            workspace,
            layerSnapshots: layerSnapshots
        )

        #expect(package.tipImageAssets.count == 1)
        #expect(package.toolSession.brush.customTipMaskData == nil)
        #expect(package.toolSession.brush.customTipAssetID != nil)
        #expect(package.brushLibrary.presets.first?.brush.customTipMaskData == nil)
        #expect(package.brushLibrary.presets.first?.brush.customTipAssetID != nil)
        #expect(package.tipImageLibrary.items.count == 1)
        #expect(package.tipImageLibrary.items.allSatisfy { $0.maskData == nil })
        #expect(package.patternLibrary == workspace.patternLibrary)
        #expect(package.workspaceState.brushLibrary.selectedPresetID == workspace.brushLibrary.selectedPresetID)
        #expect(package.workspaceState.brushLibrary.presets.count == workspace.brushLibrary.presets.count)
        #expect(package.workspaceState.patternLibrary == workspace.patternLibrary)
        #expect(package.workspaceState.brushLibrary.presets.first?.brush.customTipMaskData == primaryMask)
        #expect(package.workspaceState.brushLibrary.presets.first?.brush.customTipImportedSourceInfo == primarySourceInfo)
        #expect(package.workspaceState.brushLibrary.presets.first?.brush.buildUpOpacityCompensationAmount == 0.44)
        #expect(package.workspaceState.brushLibrary.presets.first?.brush.compoundBrush.globalPressureSizeAmount == 0.42)
        #expect(package.workspaceState.brushLibrary.presets.first?.brush.compoundBrush.globalPressureOpacityAmount == 0.68)
        #expect(package.workspaceState.brushLibrary.presets.first?.brush.compoundBrush.globalPaintJitterAmount == 0.57)
        #expect(package.workspaceState.brushLibrary.presets.first?.brush.compoundBrush.globalPaintContrastAmount == 0.26)
        #expect(package.workspaceState.toolSession.brush.buildUpOpacityCompensationAmount == 0.44)
        #expect(package.workspaceState.toolSession.brush.compoundBrush.globalPressureSizeAmount == 0.42)
        #expect(package.workspaceState.toolSession.brush.compoundBrush.globalPressureOpacityAmount == 0.68)
        #expect(package.workspaceState.toolSession.brush.compoundBrush.globalPaintJitterAmount == 0.57)
        #expect(package.workspaceState.toolSession.brush.compoundBrush.globalPaintContrastAmount == 0.26)
        #expect(package.workspaceState.tipImageLibrary == workspace.tipImageLibrary)
        #expect(package.creativeShapeGenerator == workspace.creativeShapeGenerator)
        #expect(package.workspaceState.creativeShapeGenerator == workspace.creativeShapeGenerator)
        #expect(package.layerSnapshots == layerSnapshots)
    }

    @Test
    func packagePreservesDormantImportedTipAssetsAcrossWorkspaceRoundTrip() {
        var workspace = WorkspaceState.stageOneDefault
        let primaryMask = Data([255, 96, 48, 0, 12])
        let primarySourceInfo = ImportedTipSourceInfo(
            sourceLabel: "Dormant Workspace Primary",
            pixelWidth: 320,
            pixelHeight: 200
        )

        workspace.toolSession.brush.tipShape = .softRound
        workspace.toolSession.brush.customTipSourceSemantic = .importedImage
        workspace.toolSession.brush.customTipImportedSourceInfo = primarySourceInfo
        workspace.toolSession.brush.customTipMaskData = primaryMask
        workspace.tipImageLibrary = TipImageLibraryState(
            items: [
                TipImageLibraryItem(
                    id: BrushTipImageAssetID(maskData: primaryMask),
                    sourceInfo: primarySourceInfo,
                    maskData: primaryMask
                )
            ]
        )

        let layerSnapshots = [
            LayerHistorySnapshot(
                layerID: workspace.document.activeLayerID,
                texture: LayerTextureSnapshot(
                    width: 4,
                    height: 4,
                    bytesPerRow: 16,
                    pixelData: Data([1, 2, 3, 4])
                )
            )
        ]

        let package = ProjectPackage.fromWorkspace(
            workspace,
            layerSnapshots: layerSnapshots
        )

        #expect(package.tipImageAssets.count == 1)
        #expect(package.toolSession.brush.customTipMaskData == nil)
        #expect(package.toolSession.brush.customTipAssetID != nil)
        #expect(package.toolSession.brush.tipShape == .softRound)
        #expect(package.tipImageLibrary.items.count == 1)
        #expect(package.tipImageLibrary.items.allSatisfy { $0.maskData == nil })
        #expect(package.workspaceState.toolSession.brush.customTipMaskData == workspace.toolSession.brush.customTipMaskData)
        #expect(package.workspaceState.toolSession.brush.customTipImportedSourceInfo == workspace.toolSession.brush.customTipImportedSourceInfo)
        #expect(package.workspaceState.tipImageLibrary == workspace.tipImageLibrary)
        #expect(package.layerSnapshots == layerSnapshots)
    }

    @Test
    func packagePreservesUnreferencedTipImageLibraryItems() {
        var workspace = WorkspaceState.stageOneDefault
        let orphanMask = Data([14, 28, 196, 255, 32, 8])
        let orphanSourceInfo = ImportedTipSourceInfo(
            sourceLabel: "Unused Library Tip",
            pixelWidth: 210,
            pixelHeight: 132
        )

        workspace.tipImageLibrary = TipImageLibraryState(
            items: [
                TipImageLibraryItem(
                    id: BrushTipImageAssetID(maskData: orphanMask),
                    sourceInfo: orphanSourceInfo,
                    maskData: orphanMask
                )
            ]
        )

        let package = ProjectPackage.fromWorkspace(
            workspace,
            layerSnapshots: []
        )

        #expect(package.tipImageAssets.count == 1)
        #expect(package.tipImageLibrary.items.count == 1)
        #expect(package.tipImageLibrary.items[0].maskData == nil)
        #expect(package.workspaceState.tipImageLibrary == workspace.tipImageLibrary)
    }
}

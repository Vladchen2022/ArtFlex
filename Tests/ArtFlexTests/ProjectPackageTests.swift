import Foundation
import Testing
@testable import ArtFlex

struct ProjectPackageTests {
    @Test
    func packagePreservesWorkspaceStateAndLayerSnapshots() {
        var workspace = WorkspaceState.stageOneDefault
        let primaryMask = Data([11, 22, 140, 250])
        let secondaryMask = Data([5, 10, 180, 240])
        let primarySourceInfo = ImportedTipSourceInfo(
            sourceLabel: "Project Primary",
            pixelWidth: 192,
            pixelHeight: 128
        )
        let secondarySourceInfo = ImportedTipSourceInfo(
            sourceLabel: "Project Secondary",
            pixelWidth: 96,
            pixelHeight: 144
        )
        workspace.brushLibrary = BrushLibraryState(
            presets: [
                BrushPreset(
                    id: "custom-test",
                    name: "Custom Test",
                    brush: BrushSettings(
                        size: 18,
                        opacity: 0.6,
                        buildMode: .opacityCap,
                        tipShape: .customRound,
                        dualTipEnabled: true,
                        secondaryTipDescriptor: SecondaryTipDescriptor(
                            tipShape: .customRound,
                            sourceSemantic: .importedImage,
                            importedSourceInfo: secondarySourceInfo,
                            customTipMaskData: secondaryMask,
                            customTipSoftness: 0.37,
                            customTipRoundness: 0.69,
                            customTipAngleDegrees: 52
                        ),
                        dualTipCombineMode: .intersect,
                        dualTipStrength: 0.68,
                        secondarySizeRatio: 1.45,
                        secondaryAngleOffsetDegrees: 27,
                        secondaryScatter: 0.9,
                        secondaryInvert: true,
                        spacingPercent: 15,
                        scatterAmount: 0,
                        jitterAmount: 0.32,
                        colorJitterAmount: 0.46,
                        stampRotationDegrees: 0,
                        followsStrokeDirection: false,
                        customTipSourceSemantic: .importedImage,
                        customTipImportedSourceInfo: primarySourceInfo,
                        customTipMaskData: primaryMask,
                        customTipSoftness: 0.82,
                        customTipRoundness: 0.58,
                        customTipAngleDegrees: 33,
                        pressureSensitivity: 1.6,
                        sizeLowerBound: 0.24,
                        pressureSizeAmount: 0.35,
                        pressureOpacityAmount: 0.7,
                        sizeCurveLow: 0.12,
                        sizeCurveMid: 0.58,
                        sizeCurveHigh: 0.91,
                        opacityCurveLow: 0.03,
                        opacityCurveMid: 0.48,
                        opacityCurveHigh: 0.86
                    ),
                    isBuiltIn: false
                )
            ],
            selectedPresetID: "custom-test"
        )
        workspace.tipImageLibrary = TipImageLibraryState(
            items: [
                TipImageLibraryItem(
                    id: BrushTipImageAssetID(maskData: primaryMask),
                    sourceInfo: primarySourceInfo,
                    maskData: primaryMask
                ),
                TipImageLibraryItem(
                    id: BrushTipImageAssetID(maskData: secondaryMask),
                    sourceInfo: secondarySourceInfo,
                    maskData: secondaryMask
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

        #expect(package.tipImageAssets.count == 2)
        #expect(package.toolSession.brush.customTipMaskData == nil)
        #expect(package.toolSession.brush.customTipAssetID == nil)
        #expect(package.toolSession.brush.secondaryTipDescriptor.customTipMaskData == nil)
        #expect(package.toolSession.brush.secondaryTipDescriptor.tipAssetID == nil)
        #expect(package.brushLibrary.presets.first?.brush.customTipMaskData == nil)
        #expect(package.brushLibrary.presets.first?.brush.customTipAssetID != nil)
        #expect(package.brushLibrary.presets.first?.brush.secondaryTipDescriptor.customTipMaskData == nil)
        #expect(package.brushLibrary.presets.first?.brush.secondaryTipDescriptor.tipAssetID != nil)
        #expect(package.tipImageLibrary.items.count == 2)
        #expect(package.tipImageLibrary.items.allSatisfy { $0.maskData == nil })
        #expect(package.workspaceState.toolSession.brush == workspace.toolSession.brush)
        #expect(package.workspaceState.brushLibrary.presets.first?.brush.customTipMaskData == workspace.brushLibrary.presets.first?.brush.customTipMaskData)
        #expect(package.workspaceState.brushLibrary.presets.first?.brush.secondaryTipDescriptor.customTipMaskData == workspace.brushLibrary.presets.first?.brush.secondaryTipDescriptor.customTipMaskData)
        #expect(package.workspaceState.brushLibrary.presets.first?.brush.customTipSourceSemantic == workspace.brushLibrary.presets.first?.brush.customTipSourceSemantic)
        #expect(package.workspaceState.brushLibrary.presets.first?.brush.customTipImportedSourceInfo == workspace.brushLibrary.presets.first?.brush.customTipImportedSourceInfo)
        #expect(package.workspaceState.brushLibrary.presets.first?.brush.secondaryTipDescriptor.sourceSemantic == workspace.brushLibrary.presets.first?.brush.secondaryTipDescriptor.sourceSemantic)
        #expect(package.workspaceState.brushLibrary.presets.first?.brush.secondaryTipDescriptor.importedSourceInfo == workspace.brushLibrary.presets.first?.brush.secondaryTipDescriptor.importedSourceInfo)
        #expect(package.workspaceState.tipImageLibrary == workspace.tipImageLibrary)
        #expect(package.workspaceState.brushLibrary.selectedPresetID == workspace.brushLibrary.selectedPresetID)
        #expect(package.layerSnapshots == layerSnapshots)
    }

    @Test
    func packagePreservesDormantImportedTipAssetsAcrossWorkspaceRoundTrip() {
        var workspace = WorkspaceState.stageOneDefault
        let primaryMask = Data([255, 96, 48, 0, 12])
        let secondaryMask = Data([0, 32, 128, 255, 40])
        let primarySourceInfo = ImportedTipSourceInfo(
            sourceLabel: "Dormant Workspace Primary",
            pixelWidth: 320,
            pixelHeight: 200
        )
        let secondarySourceInfo = ImportedTipSourceInfo(
            sourceLabel: "Dormant Workspace Secondary",
            pixelWidth: 180,
            pixelHeight: 180
        )
        workspace.toolSession.brush.tipShape = .softRound
        workspace.toolSession.brush.customTipSourceSemantic = .importedImage
        workspace.toolSession.brush.customTipImportedSourceInfo = primarySourceInfo
        workspace.toolSession.brush.customTipMaskData = primaryMask
        workspace.toolSession.brush.secondaryTipDescriptor = SecondaryTipDescriptor(
            tipShape: .square,
            sourceSemantic: .importedImage,
            importedSourceInfo: secondarySourceInfo,
            customTipMaskData: secondaryMask,
            customTipSoftness: 0.37,
            customTipRoundness: 0.69,
            customTipAngleDegrees: 52
        )
        workspace.tipImageLibrary = TipImageLibraryState(
            items: [
                TipImageLibraryItem(
                    id: BrushTipImageAssetID(maskData: primaryMask),
                    sourceInfo: primarySourceInfo,
                    maskData: primaryMask
                ),
                TipImageLibraryItem(
                    id: BrushTipImageAssetID(maskData: secondaryMask),
                    sourceInfo: secondarySourceInfo,
                    maskData: secondaryMask
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

        #expect(package.tipImageAssets.count == 2)
        #expect(package.toolSession.brush.customTipMaskData == nil)
        #expect(package.toolSession.brush.customTipAssetID != nil)
        #expect(package.toolSession.brush.secondaryTipDescriptor.customTipMaskData == nil)
        #expect(package.toolSession.brush.secondaryTipDescriptor.tipAssetID != nil)
        #expect(package.toolSession.brush.tipShape == .softRound)
        #expect(package.toolSession.brush.secondaryTipDescriptor.tipShape == .square)
        #expect(package.tipImageLibrary.items.count == 2)
        #expect(package.tipImageLibrary.items.allSatisfy { $0.maskData == nil })
        #expect(package.workspaceState.toolSession.brush.customTipMaskData == workspace.toolSession.brush.customTipMaskData)
        #expect(package.workspaceState.toolSession.brush.secondaryTipDescriptor.customTipMaskData == workspace.toolSession.brush.secondaryTipDescriptor.customTipMaskData)
        #expect(package.workspaceState.toolSession.brush.customTipImportedSourceInfo == workspace.toolSession.brush.customTipImportedSourceInfo)
        #expect(package.workspaceState.toolSession.brush.secondaryTipDescriptor.importedSourceInfo == workspace.toolSession.brush.secondaryTipDescriptor.importedSourceInfo)
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

import Testing
@testable import ArtFlex

struct TextureFillPhase0Tests {
    @Test
    func inspectorColumnsStayEqualAtTheFixedSidebarWidth() {
        #expect(rightInspectorColumnWidth(totalWidth: 560) == 262)
        #expect(topInspectorPanelContentWidth(panelWidth: 262) == 238)
        #expect(rightInspectorContentHeight(totalHeight: 1_000) == 976)
        #expect(rightInspectorColumnWidth(totalWidth: 20) == 0)
        #expect(topInspectorPanelContentWidth(panelWidth: 20) == 0)
        #expect(rightInspectorContentHeight(totalHeight: 20) == 0)
    }

    @Test
    func textureFillIsAnInternalModeOfTheLassoFillSidebarTool() {
        let group = ToolSidebarGroup.orderedGroups.first { $0.id == "lasso-fill" }

        #expect(group != nil)
        #expect(group?.tools == [.lassoFill, .textureFill])
        #expect(group?.isGrouped == false)
        #expect(group?.shortcutKey == "K")
        #expect(ToolKind.textureFill.shortcutKey == "K")
        #expect(ToolKind.textureFill.displayName == "纹理填充")
        #expect(ToolSidebarGroup.orderedGroups.contains { $0.id == "texture-fill" } == false)
    }

    @Test
    func lassoFillToolGroupDrivesTheTextureLibraryWhileOtherToolsUseTheBrushLibrary() {
        #expect(rightInspectorUsesTextureLibrary(activeTool: .lassoFill))
        #expect(rightInspectorUsesTextureLibrary(activeTool: .textureFill))
        #expect(rightInspectorUsesTextureLibrary(activeTool: .colorVitalization))
        #expect(!rightInspectorUsesTextureLibrary(activeTool: .brush))
        #expect(!rightInspectorUsesTextureLibrary(activeTool: .eraser))
        #expect(!rightInspectorUsesTextureLibrary(activeTool: .blockReference))
    }

    @Test
    func shortToolParametersYieldSpaceToTheLayerPanel() {
        #expect(rightInspectorUsesCompactParameterLayout(
            activeTool: .lassoFill,
            isBrushTab: true,
            usesTextureFillControls: false
        ))
        #expect(rightInspectorUsesCompactParameterLayout(
            activeTool: .linearGradient,
            isBrushTab: true,
            usesTextureFillControls: false
        ))
        #expect(!rightInspectorUsesCompactParameterLayout(
            activeTool: .lassoFill,
            isBrushTab: true,
            usesTextureFillControls: true
        ))
        #expect(!rightInspectorUsesCompactParameterLayout(
            activeTool: .brush,
            isBrushTab: true,
            usesTextureFillControls: false
        ))
        #expect(rightInspectorUsesCompactParameterLayout(
            activeTool: .linearGradient,
            isBrushTab: false,
            usesTextureFillControls: false
        ))
    }
}

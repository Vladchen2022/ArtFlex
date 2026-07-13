import Testing
@testable import ArtFlex

struct TextureFillPhase0Tests {
    @Test
    func textureFillToolIsRegisteredAsStandaloneSidebarGroup() {
        let group = ToolSidebarGroup.orderedGroups.first { $0.id == "texture-fill" }

        #expect(group != nil)
        #expect(group?.tools == [.textureFill])
        #expect(group?.shortcutKey == "F")
        #expect(ToolKind.textureFill.shortcutKey == "F")
        #expect(ToolKind.textureFill.displayName == "纹理填充")
    }
}

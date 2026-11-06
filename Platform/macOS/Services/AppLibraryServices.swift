import Foundation

/// Shared by every document and ideation branch in one application instance.
final class AppLibraryServices {
    let store: SharedLibraryStore
    let writes = PersistenceSaveQueue(label: "ArtFlex.ApplicationLibraries")
    let brushes: BrushLibraryPersistenceController
    let patterns: PatternLibraryPersistenceController
    let textures: TextureFillLibraryPersistenceController
    let blocks: BlockReferenceModuleLibraryPersistenceController

    init(state: WorkspaceState, brushes: BrushLibraryPersistenceController,
         patterns: PatternLibraryPersistenceController, textures: TextureFillLibraryPersistenceController,
         blocks: BlockReferenceModuleLibraryPersistenceController) {
        store = SharedLibraryStore(state: state)
        self.brushes = brushes; self.patterns = patterns; self.textures = textures; self.blocks = blocks
    }
}

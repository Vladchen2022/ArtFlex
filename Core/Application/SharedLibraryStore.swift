import Foundation

/// Application-owned resource data. Document snapshots retain compatibility fields for
/// archives, but replacing/undoing a document never replaces these live shared libraries.
struct WorkspaceLibraries: Equatable {
    var brushes: BrushLibraryState
    var patterns: PatternLibraryState
    var textures: TextureFillLibraryState
    var blocks: BlockReferenceModuleLibraryState
    var tips: TipImageLibraryState

    init(_ state: WorkspaceState) {
        brushes = state.brushLibrary; patterns = state.patternLibrary
        textures = state.textureFillLibrary; blocks = state.blockReferenceModuleLibrary
        tips = state.tipImageLibrary
    }

    func apply(to state: inout WorkspaceState, preservingSelection: Bool = true) {
        let brush = state.brushLibrary.selectedPresetID
        let pattern = state.patternLibrary.selectedItemID
        let texture = state.textureFillLibrary.selectedItemID
        let category = state.blockReferenceModuleLibrary.selectedCategoryID
        state.brushLibrary = brushes; state.patternLibrary = patterns
        state.textureFillLibrary = textures; state.blockReferenceModuleLibrary = blocks
        state.tipImageLibrary = tips
        if preservingSelection {
            if blocks.categories.contains(where: { $0.id == category }) { state.blockReferenceModuleLibrary.selectedCategoryID = category }
            state.brushLibrary.selectedPresetID = brush.flatMap { id in brushes.presets.contains { $0.id == id } ? id : nil }
            state.patternLibrary.selectedItemID = pattern.flatMap { id in patterns.items.contains { $0.id == id } ? id : nil }
            state.textureFillLibrary.selectedItemID = texture.flatMap { id in textures.items.contains { $0.id == id } ? id : nil }
        }
    }
}

final class SharedLibraryStore {
    private final class Observer {
        weak var store: WorkspaceStore?
        init(_ store: WorkspaceStore) { self.store = store }
    }
    private(set) var resources: WorkspaceLibraries
    private var observers: [Observer] = []
    var hasLoadedPersistence = false
    init(state: WorkspaceState) { resources = WorkspaceLibraries(state) }

    func attach(_ store: WorkspaceStore) {
        observers.removeAll { $0.store == nil || $0.store === store }
        observers.append(Observer(store))
        store.sharedLibraries = self
    }

    func update(_ transform: (inout WorkspaceLibraries) -> Void) {
        var updated = resources
        transform(&updated)
        guard updated != resources else { return }
        resources = updated
        observers.removeAll { $0.store == nil }
        for observer in observers { observer.store?.onLibrariesChanged?() }
    }
}

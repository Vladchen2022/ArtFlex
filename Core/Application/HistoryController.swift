import Foundation

struct LayerHistorySnapshot: Codable, Sendable, Equatable {
    var layerID: LayerID
    var texture: LayerTextureSnapshot
}

struct WorkspaceHistoryEntry: Sendable, Equatable {
    var workspace: WorkspaceState
    var layerSnapshots: [LayerHistorySnapshot]
}

final class HistoryController {
    private let workspaceStore: WorkspaceStore
    private let layerSurfaceStore: StageOneLayerSurfaceStore
    private let serializer: LayerTextureSerializer
    private let metalContext: MetalDeviceContext
    private let maxEntries: Int?

    private var undoStack: [WorkspaceHistoryEntry] = []
    private var redoStack: [WorkspaceHistoryEntry] = []

    init(
        workspaceStore: WorkspaceStore,
        layerSurfaceStore: StageOneLayerSurfaceStore,
        serializer: LayerTextureSerializer,
        metalContext: MetalDeviceContext,
        maxEntries: Int? = nil
    ) {
        self.workspaceStore = workspaceStore
        self.layerSurfaceStore = layerSurfaceStore
        self.serializer = serializer
        self.metalContext = metalContext
        self.maxEntries = maxEntries
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func captureCheckpoint(workspaceOverride: WorkspaceState? = nil) throws {
        let entry = try makeEntry(workspaceOverride: workspaceOverride)
        undoStack.append(entry)

        if let maxEntries, undoStack.count > maxEntries {
            undoStack.removeFirst(undoStack.count - maxEntries)
        }

        redoStack.removeAll()
    }

    func resetHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    func undo() throws -> Bool {
        guard let previous = undoStack.popLast() else {
            return false
        }

        let current = try makeEntry()
        redoStack.append(current)
        try restore(entry: previous)
        return true
    }

    func redo() throws -> Bool {
        guard let next = redoStack.popLast() else {
            return false
        }

        let current = try makeEntry()
        undoStack.append(current)
        try restore(entry: next)
        return true
    }

    static func mergedWorkspaceForHistoryNavigation(
        restored: WorkspaceState,
        current: WorkspaceState
    ) -> WorkspaceState {
        WorkspaceState(
            document: restored.document,
            toolSession: current.toolSession,
            colorPanel: current.colorPanel,
            brushLibrary: current.brushLibrary,
            generator: current.generator,
            viewport: current.viewport,
            selection: restored.selection
        )
    }

    private func makeEntry(workspaceOverride: WorkspaceState? = nil) throws -> WorkspaceHistoryEntry {
        let workspace = workspaceOverride ?? workspaceStore.state
        layerSurfaceStore.prepareTextures(for: workspace.document, metal: metalContext)

        var layerSnapshots: [LayerHistorySnapshot] = []
        for layer in workspace.document.layers {
            guard
                let surfaceID = layerSurfaceStore.surfaceID(for: layer.id),
                let texture = layerSurfaceStore.texture(for: surfaceID)
            else {
                continue
            }

            layerSnapshots.append(
                LayerHistorySnapshot(
                    layerID: layer.id,
                    texture: try serializer.snapshot(texture: texture)
                )
            )
        }

        return WorkspaceHistoryEntry(
            workspace: workspace,
            layerSnapshots: layerSnapshots
        )
    }

    private func restore(entry: WorkspaceHistoryEntry) throws {
        let currentWorkspace = workspaceStore.state
        let mergedWorkspace = Self.mergedWorkspaceForHistoryNavigation(
            restored: entry.workspace,
            current: currentWorkspace
        )
        workspaceStore.replaceState(mergedWorkspace)
        layerSurfaceStore.reset()
        layerSurfaceStore.prepareTextures(
            for: mergedWorkspace.document,
            metal: metalContext
        )

        for layerSnapshot in entry.layerSnapshots {
            guard
                let surfaceID = layerSurfaceStore.surfaceID(for: layerSnapshot.layerID),
                let texture = layerSurfaceStore.texture(for: surfaceID)
            else {
                continue
            }

            try serializer.restore(snapshot: layerSnapshot.texture, into: texture)
        }
    }
}

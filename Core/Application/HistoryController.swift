import Foundation

struct LayerHistorySnapshot: Codable, Sendable, Equatable {
    var layerID: LayerID
    var texture: LayerTextureSnapshot

    var approxByteCount: Int {
        texture.pixelData.count
    }
}

struct WorkspaceHistoryEntry: Sendable, Equatable {
    var workspace: WorkspaceState
    var layerSnapshots: [LayerHistorySnapshot]
    var approxByteCount: Int
}

final class HistoryController {
    private let workspaceStore: WorkspaceStore
    private let layerSurfaceStore: StageOneLayerSurfaceStore
    private let serializer: LayerTextureSerializer
    private let metalContext: MetalDeviceContext
    private let maxEntries: Int
    private let maxResidentBytes: Int

    private var undoStack: [WorkspaceHistoryEntry] = []
    private var redoStack: [WorkspaceHistoryEntry] = []
    private var undoResidentBytes = 0
    private var redoResidentBytes = 0

    init(
        workspaceStore: WorkspaceStore,
        layerSurfaceStore: StageOneLayerSurfaceStore,
        serializer: LayerTextureSerializer,
        metalContext: MetalDeviceContext,
        maxEntries: Int = 8,
        maxResidentBytes: Int = 512 * 1024 * 1024
    ) {
        self.workspaceStore = workspaceStore
        self.layerSurfaceStore = layerSurfaceStore
        self.serializer = serializer
        self.metalContext = metalContext
        self.maxEntries = maxEntries
        self.maxResidentBytes = maxResidentBytes
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func captureCheckpoint(
        workspaceOverride: WorkspaceState? = nil
    ) throws {
        let startNs = DispatchTime.now().uptimeNanoseconds
        defer {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000
            PerformanceAuditStore.shared.recordDuration("HistoryController.captureCheckpoint", ms: ms)
        }
        let entry = try makeEntry(workspaceOverride: workspaceOverride)
        append(entry, to: &undoStack, residentBytes: &undoResidentBytes)
        clear(&redoStack, residentBytes: &redoResidentBytes)
    }

    func resetHistory() {
        clear(&undoStack, residentBytes: &undoResidentBytes)
        clear(&redoStack, residentBytes: &redoResidentBytes)
    }

    func captureCurrentEntry() throws -> WorkspaceHistoryEntry {
        try makeEntry()
    }

    func undo() throws -> Bool {
        guard let previous = popLast(from: &undoStack, residentBytes: &undoResidentBytes) else {
            return false
        }

        let current = try makeEntry()
        append(current, to: &redoStack, residentBytes: &redoResidentBytes)
        try restore(entry: previous)
        return true
    }

    func redo() throws -> Bool {
        guard let next = popLast(from: &redoStack, residentBytes: &redoResidentBytes) else {
            return false
        }

        let current = try makeEntry()
        append(current, to: &undoStack, residentBytes: &undoResidentBytes)
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

    private func makeEntry(
        workspaceOverride: WorkspaceState? = nil
    ) throws -> WorkspaceHistoryEntry {
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

        let approxByteCount = layerSnapshots.reduce(into: 0) { partialResult, snapshot in
            partialResult += snapshot.approxByteCount
        }

        return WorkspaceHistoryEntry(
            workspace: workspace,
            layerSnapshots: layerSnapshots,
            approxByteCount: approxByteCount
        )
    }

    private func restore(entry: WorkspaceHistoryEntry) throws {
        let currentWorkspace = workspaceStore.state
        let mergedWorkspace = Self.mergedWorkspaceForHistoryNavigation(
            restored: entry.workspace,
            current: currentWorkspace
        )
        try restoreWithFullReset(entry: entry, workspace: mergedWorkspace)
    }

    func restoreExact(entry: WorkspaceHistoryEntry) throws {
        try restoreWithFullReset(entry: entry, workspace: entry.workspace)
        resetHistory()
    }

    private func restoreWithFullReset(
        entry: WorkspaceHistoryEntry,
        workspace: WorkspaceState
    ) throws {
        workspaceStore.replaceState(workspace)
        layerSurfaceStore.reset()
        layerSurfaceStore.prepareTextures(
            for: workspace.document,
            metal: metalContext
        )
        try restoreSnapshots(entry.layerSnapshots)
    }

    private func restoreSnapshots(_ layerSnapshots: [LayerHistorySnapshot]) throws {
        for layerSnapshot in layerSnapshots {
            guard
                let surfaceID = layerSurfaceStore.surfaceID(for: layerSnapshot.layerID),
                let texture = layerSurfaceStore.texture(for: surfaceID)
            else {
                continue
            }

            try serializer.restore(snapshot: layerSnapshot.texture, into: texture)
        }
    }

    private func append(
        _ entry: WorkspaceHistoryEntry,
        to stack: inout [WorkspaceHistoryEntry],
        residentBytes: inout Int
    ) {
        stack.append(entry)
        residentBytes += entry.approxByteCount
        trim(&stack, residentBytes: &residentBytes)
    }

    private func popLast(
        from stack: inout [WorkspaceHistoryEntry],
        residentBytes: inout Int
    ) -> WorkspaceHistoryEntry? {
        guard let entry = stack.popLast() else {
            return nil
        }
        residentBytes = max(0, residentBytes - entry.approxByteCount)
        return entry
    }

    private func clear(
        _ stack: inout [WorkspaceHistoryEntry],
        residentBytes: inout Int
    ) {
        stack.removeAll()
        residentBytes = 0
    }

    private func trim(
        _ stack: inout [WorkspaceHistoryEntry],
        residentBytes: inout Int
    ) {
        while stack.count > maxEntries {
            let removed = stack.removeFirst()
            residentBytes = max(0, residentBytes - removed.approxByteCount)
        }

        while residentBytes > maxResidentBytes, stack.count > 1 {
            let removed = stack.removeFirst()
            residentBytes = max(0, residentBytes - removed.approxByteCount)
        }
    }
}

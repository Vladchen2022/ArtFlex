import Foundation

struct LayerHistorySnapshot: Codable, Sendable, Equatable {
    var layerID: LayerID
    var texture: LayerTextureSnapshot

    var approxByteCount: Int {
        texture.pixelData.count
    }
}

struct WorkspaceHistoryEntry: Sendable, Equatable {
    enum Mode: Sendable, Equatable {
        case full
        case inPlaceChangedLayers(topologySignature: TopologySignature, changedLayerIDs: [LayerID])
    }

    struct TopologySignature: Sendable, Equatable {
        var canvasSize: CanvasSize
        var orderedLayerIDs: [LayerID]
        var layerCount: Int
    }

    var workspace: WorkspaceState
    var layerSnapshots: [LayerHistorySnapshot]
    var approxByteCount: Int
    var mode: Mode
}

enum HistoryCaptureMode {
    case full
    case inPlaceChangedLayers([LayerID])
}

private enum HistoryControllerError: LocalizedError {
    case dirtyRestoreTopologyMismatch
    case fullResetRequestedForDirtyEntry

    var errorDescription: String? {
        switch self {
        case .dirtyRestoreTopologyMismatch:
            return "Dirty history restore topology mismatch."
        case .fullResetRequestedForDirtyEntry:
            return "Full reset restore cannot be used with a dirty history entry."
        }
    }
}

struct HistoryEligibilityAuditContext: Sendable {
    var operationKind: String
    var candidateChangedLayerIDs: [LayerID]
    var candidateChangedLayerIDsKnown: Bool
    var comparisonWorkspace: WorkspaceState?
    var topologyOperation: Bool = false
    var additionalOperationKinds: [String] = []
}

final class HistoryController {
    static let defaultMaxEntries = 24
    static let defaultMaxResidentBytes = 768 * 1024 * 1024

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
#if DEBUG
    private(set) var debugAttemptedFullResetWithDirtyEntry = false
#endif

    init(
        workspaceStore: WorkspaceStore,
        layerSurfaceStore: StageOneLayerSurfaceStore,
        serializer: LayerTextureSerializer,
        metalContext: MetalDeviceContext,
        maxEntries: Int = HistoryController.defaultMaxEntries,
        maxResidentBytes: Int = HistoryController.defaultMaxResidentBytes
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

    var latestUndoWorkspaceForAudit: WorkspaceState? {
        undoStack.last?.workspace
    }

    func captureCheckpoint(
        workspaceOverride: WorkspaceState? = nil,
        captureMode: HistoryCaptureMode = .full,
        auditContext: HistoryEligibilityAuditContext? = nil
    ) throws {
        let entry = try makeEntryWithAudit(
            workspaceOverride: workspaceOverride,
            captureMode: captureMode,
            auditContext: auditContext,
            durationMetricKey: "HistoryController.captureCheckpoint"
        )
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
        guard let previous = undoStack.last else {
            return false
        }

        let current = try makeEntryWithAudit(
            captureMode: currentEntryCaptureMode(for: previous),
            auditContext: HistoryEligibilityAuditContext(
                operationKind: "undo.currentEntryCapture",
                candidateChangedLayerIDs: [],
                candidateChangedLayerIDsKnown: false,
                comparisonWorkspace: previous.workspace
            )
        )
        try restore(entry: previous)
        _ = popLast(from: &undoStack, residentBytes: &undoResidentBytes)
        append(current, to: &redoStack, residentBytes: &redoResidentBytes)
        return true
    }

    func redo() throws -> Bool {
        guard let next = redoStack.last else {
            return false
        }

        let current = try makeEntryWithAudit(
            captureMode: currentEntryCaptureMode(for: next),
            auditContext: HistoryEligibilityAuditContext(
                operationKind: "redo.currentEntryCapture",
                candidateChangedLayerIDs: [],
                candidateChangedLayerIDsKnown: false,
                comparisonWorkspace: next.workspace
            )
        )
        try restore(entry: next)
        _ = popLast(from: &redoStack, residentBytes: &redoResidentBytes)
        append(current, to: &undoStack, residentBytes: &undoResidentBytes)
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
        workspaceOverride: WorkspaceState? = nil,
        captureMode: HistoryCaptureMode = .full
    ) throws -> WorkspaceHistoryEntry {
        let workspace = workspaceOverride ?? workspaceStore.state
        layerSurfaceStore.prepareTextures(for: workspace.document, metal: metalContext)

        let resolvedCapture = resolveCaptureMode(captureMode, workspace: workspace)
        let snapshotLayerIDs: Set<LayerID>
        let mode: WorkspaceHistoryEntry.Mode

        switch resolvedCapture {
        case .full:
            snapshotLayerIDs = Set(workspace.document.layers.map(\.id))
            mode = .full
        case .inPlaceChangedLayers(let changedLayerIDs):
            snapshotLayerIDs = Set(changedLayerIDs)
            mode = .inPlaceChangedLayers(
                topologySignature: topologySignature(for: workspace),
                changedLayerIDs: changedLayerIDs
            )
        }

        var layerSnapshots: [LayerHistorySnapshot] = []
        for layer in workspace.document.layers where snapshotLayerIDs.contains(layer.id) {
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
            approxByteCount: approxByteCount,
            mode: mode
        )
    }

    private func makeEntryWithAudit(
        workspaceOverride: WorkspaceState? = nil,
        captureMode: HistoryCaptureMode = .full,
        auditContext: HistoryEligibilityAuditContext? = nil,
        durationMetricKey: String? = nil
    ) throws -> WorkspaceHistoryEntry {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let entry = try makeEntry(
            workspaceOverride: workspaceOverride,
            captureMode: captureMode
        )
        let ms = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000

        if let durationMetricKey {
            PerformanceAuditStore.shared.recordDuration(durationMetricKey, ms: ms)
        }

#if DEBUG
        if let auditContext {
            recordEligibilityAudit(
                for: entry,
                workspace: workspaceOverride ?? workspaceStore.state,
                auditContext: auditContext,
                fullCheckpointMs: ms
            )
        }
#endif
        return entry
    }

    private func restore(entry: WorkspaceHistoryEntry) throws {
        let currentWorkspace = workspaceStore.state
        let mergedWorkspace = Self.mergedWorkspaceForHistoryNavigation(
            restored: entry.workspace,
            current: currentWorkspace
        )
        switch entry.mode {
        case .full:
            try restoreWithFullReset(entry: entry, workspace: mergedWorkspace)
        case .inPlaceChangedLayers(let topologySignature, let changedLayerIDs):
            try restoreInPlaceChangedLayers(
                entry: entry,
                workspace: mergedWorkspace,
                expectedTopologySignature: topologySignature,
                changedLayerIDs: changedLayerIDs
            )
        }
    }

    func restoreExact(entry: WorkspaceHistoryEntry) throws {
        switch entry.mode {
        case .full:
            try restoreWithFullReset(entry: entry, workspace: entry.workspace)
        case .inPlaceChangedLayers(let topologySignature, let changedLayerIDs):
            try restoreInPlaceChangedLayers(
                entry: entry,
                workspace: entry.workspace,
                expectedTopologySignature: topologySignature,
                changedLayerIDs: changedLayerIDs
            )
        }
        resetHistory()
    }

    private func restoreWithFullReset(
        entry: WorkspaceHistoryEntry,
        workspace: WorkspaceState
    ) throws {
#if DEBUG
        if case .inPlaceChangedLayers = entry.mode {
            debugAttemptedFullResetWithDirtyEntry = true
        }
#endif
        guard case .full = entry.mode else {
            throw HistoryControllerError.fullResetRequestedForDirtyEntry
        }
        workspaceStore.replaceState(workspace)
        layerSurfaceStore.reset()
        layerSurfaceStore.prepareTextures(
            for: workspace.document,
            metal: metalContext
        )
        try restoreSnapshots(entry.layerSnapshots)
    }

    private func restoreInPlaceChangedLayers(
        entry: WorkspaceHistoryEntry,
        workspace: WorkspaceState,
        expectedTopologySignature: WorkspaceHistoryEntry.TopologySignature,
        changedLayerIDs: [LayerID]
    ) throws {
        guard topologySignature(for: workspaceStore.state) == expectedTopologySignature else {
            throw HistoryControllerError.dirtyRestoreTopologyMismatch
        }

        let snapshotLayerIDs = Set(entry.layerSnapshots.map(\.layerID))
        guard snapshotLayerIDs == Set(changedLayerIDs) else {
            throw HistoryControllerError.dirtyRestoreTopologyMismatch
        }

        workspaceStore.replaceState(workspace)
        layerSurfaceStore.prepareTextures(
            for: workspace.document,
            metal: metalContext
        )
        try restoreSnapshots(entry.layerSnapshots)
    }

    private func currentEntryCaptureMode(for targetEntry: WorkspaceHistoryEntry) -> HistoryCaptureMode {
        switch targetEntry.mode {
        case .full:
            return .full
        case .inPlaceChangedLayers(let expectedTopologySignature, let changedLayerIDs):
            guard topologySignature(for: workspaceStore.state) == expectedTopologySignature else {
                return .full
            }
            return .inPlaceChangedLayers(changedLayerIDs)
        }
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

#if DEBUG
    private struct HistoryEligibilityAuditAssessment {
        var eligible: Bool
        var ineligibleReason: HistoryEligibilityIneligibleReason?
        var topologyStable: Bool
        var phase: HistoryEligibilityPhase
    }

    private func recordEligibilityAudit(
        for entry: WorkspaceHistoryEntry,
        workspace: WorkspaceState,
        auditContext: HistoryEligibilityAuditContext,
        fullCheckpointMs: Double
    ) {
        let fullSnapshotLayerCount = workspace.document.layers.count
        let candidateLayerIDs = auditContext.candidateChangedLayerIDs
        let assessment = assessEligibility(for: workspace, auditContext: auditContext)
        let bytesPerLayer = max(0, workspace.document.canvasSize.width * workspace.document.canvasSize.height * 4)
        let projectedFullEntryBytes = fullSnapshotLayerCount * bytesPerLayer

        let dirtyCandidateLayerCount: Int
        let projectedDirtyEntryBytes: Int
        if auditContext.candidateChangedLayerIDsKnown {
            dirtyCandidateLayerCount = Set(candidateLayerIDs).count
            projectedDirtyEntryBytes = dirtyCandidateLayerCount * bytesPerLayer
        } else {
            dirtyCandidateLayerCount = fullSnapshotLayerCount
            projectedDirtyEntryBytes = projectedFullEntryBytes
        }

        let operationKinds = [auditContext.operationKind] + auditContext.additionalOperationKinds
        let canvasSizeBucket = canvasSizeBucket(for: workspace.document.canvasSize)
        let layerCountBucket = layerCountBucket(for: workspace.document.layers.count)

        for operationKind in operationKinds {
            PerformanceAuditStore.shared.recordHistoryEligibility(
                HistoryEligibilityAuditRecord(
                    operationKind: operationKind,
                    eligible: assessment.eligible,
                    ineligibleReason: assessment.ineligibleReason,
                    canvasSizeBucket: canvasSizeBucket,
                    layerCountBucket: layerCountBucket,
                    warmupOrSteadyState: assessment.phase,
                    topologyStable: assessment.topologyStable,
                    candidateChangedLayerIDs: candidateLayerIDs,
                    fullSnapshotLayerCount: fullSnapshotLayerCount,
                    dirtyCandidateLayerCount: dirtyCandidateLayerCount,
                    fullEntryBytes: projectedFullEntryBytes,
                    projectedDirtyEntryBytes: projectedDirtyEntryBytes,
                    projectedByteSavings: max(0, projectedFullEntryBytes - projectedDirtyEntryBytes),
                    projectedLayerSavings: max(0, fullSnapshotLayerCount - dirtyCandidateLayerCount),
                    fullCheckpointMs: fullCheckpointMs,
                    overBudget: entry.approxByteCount > maxResidentBytes
                )
            )
        }
    }

    private func assessEligibility(
        for workspace: WorkspaceState,
        auditContext: HistoryEligibilityAuditContext
    ) -> HistoryEligibilityAuditAssessment {
        let phase: HistoryEligibilityPhase = auditContext.comparisonWorkspace == nil ? .warmup : .steadyState

        guard let comparisonWorkspace = auditContext.comparisonWorkspace else {
            return HistoryEligibilityAuditAssessment(
                eligible: false,
                ineligibleReason: .noComparisonWorkspace,
                topologyStable: false,
                phase: phase
            )
        }

        if comparisonWorkspace.document.canvasSize != workspace.document.canvasSize {
            return HistoryEligibilityAuditAssessment(
                eligible: false,
                ineligibleReason: .canvasSizeChanged,
                topologyStable: false,
                phase: phase
            )
        }

        if comparisonWorkspace.document.layers.count != workspace.document.layers.count {
            return HistoryEligibilityAuditAssessment(
                eligible: false,
                ineligibleReason: .layerCountChanged,
                topologyStable: false,
                phase: phase
            )
        }

        if comparisonWorkspace.document.layers.map(\.id) != workspace.document.layers.map(\.id) {
            return HistoryEligibilityAuditAssessment(
                eligible: false,
                ineligibleReason: .orderedLayerIDsChanged,
                topologyStable: false,
                phase: phase
            )
        }

        if auditContext.topologyOperation {
            return HistoryEligibilityAuditAssessment(
                eligible: false,
                ineligibleReason: .topologyOperation,
                topologyStable: true,
                phase: phase
            )
        }

        if !auditContext.candidateChangedLayerIDsKnown {
            return HistoryEligibilityAuditAssessment(
                eligible: false,
                ineligibleReason: .candidateChangedLayersUnknown,
                topologyStable: true,
                phase: phase
            )
        }

        if Set(auditContext.candidateChangedLayerIDs).count > 1 {
            return HistoryEligibilityAuditAssessment(
                eligible: false,
                ineligibleReason: .multiLayerWrite,
                topologyStable: true,
                phase: phase
            )
        }

        return HistoryEligibilityAuditAssessment(
            eligible: !auditContext.candidateChangedLayerIDs.isEmpty,
            ineligibleReason: auditContext.candidateChangedLayerIDs.isEmpty ? .candidateChangedLayersUnknown : nil,
            topologyStable: true,
            phase: phase
        )
    }

    private func canvasSizeBucket(for canvasSize: CanvasSize) -> String {
        "\(canvasSize.width)x\(canvasSize.height)"
    }

    private func layerCountBucket(for layerCount: Int) -> String {
        "\(layerCount)"
    }

    var debugUndoEntryModes: [WorkspaceHistoryEntry.Mode] {
        undoStack.map(\.mode)
    }

    var debugUndoEntryApproxByteCounts: [Int] {
        undoStack.map(\.approxByteCount)
    }

    var debugUndoCount: Int {
        undoStack.count
    }

    var debugRedoCount: Int {
        redoStack.count
    }

    var debugRedoEntryModes: [WorkspaceHistoryEntry.Mode] {
        redoStack.map(\.mode)
    }
#endif

    private func resolveCaptureMode(
        _ captureMode: HistoryCaptureMode,
        workspace: WorkspaceState
    ) -> HistoryCaptureMode {
        switch captureMode {
        case .full:
            return .full
        case .inPlaceChangedLayers(let changedLayerIDs):
            let uniqueLayerIDs = Array(Set(changedLayerIDs))
            guard uniqueLayerIDs.count == 1, workspace.document.layers.count > 1 else {
                return .full
            }
            let validLayerIDs = Set(workspace.document.layers.map(\.id))
            guard uniqueLayerIDs.allSatisfy({ validLayerIDs.contains($0) }) else {
                return .full
            }
            return .inPlaceChangedLayers(uniqueLayerIDs)
        }
    }

    private func topologySignature(for workspace: WorkspaceState) -> WorkspaceHistoryEntry.TopologySignature {
        WorkspaceHistoryEntry.TopologySignature(
            canvasSize: workspace.document.canvasSize,
            orderedLayerIDs: workspace.document.layers.map(\.id),
            layerCount: workspace.document.layers.count
        )
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

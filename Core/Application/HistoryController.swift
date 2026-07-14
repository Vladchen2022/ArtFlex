import Foundation
import Metal

struct LayerHistorySnapshot: Codable, Sendable, Equatable {
    var layerID: LayerID
    var texture: LayerTextureSnapshot
    var originX: Int
    var originY: Int

    enum CodingKeys: String, CodingKey {
        case layerID
        case texture
        case originX
        case originY
    }

    init(
        layerID: LayerID,
        texture: LayerTextureSnapshot,
        originX: Int = 0,
        originY: Int = 0
    ) {
        self.layerID = layerID
        self.texture = texture
        self.originX = originX
        self.originY = originY
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layerID = try container.decode(LayerID.self, forKey: .layerID)
        texture = try container.decode(LayerTextureSnapshot.self, forKey: .texture)
        originX = try container.decodeIfPresent(Int.self, forKey: .originX) ?? 0
        originY = try container.decodeIfPresent(Int.self, forKey: .originY) ?? 0
    }

    var approxByteCount: Int {
        texture.pixelData.count
    }

    func coversFullCanvas(_ canvasSize: CanvasSize) -> Bool {
        originX == 0 &&
            originY == 0 &&
            texture.width == canvasSize.width &&
            texture.height == canvasSize.height
    }
}

struct WorkspaceHistoryEntry: Sendable, Equatable {
    enum Mode: Sendable, Equatable {
        case full
        case inPlaceChangedLayers(topologySignature: TopologySignature, changedLayerIDs: [LayerID])
        case workspaceOnly(topologySignature: TopologySignature)
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
    case workspaceOnly
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

    var nextUndoRestoresWorkspaceOnly: Bool {
        guard let entry = undoStack.last else { return false }
        if case .workspaceOnly = entry.mode { return true }
        return false
    }

    var nextRedoRestoresWorkspaceOnly: Bool {
        guard let entry = redoStack.last else { return false }
        if case .workspaceOnly = entry.mode { return true }
        return false
    }

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

    func captureCheckpoint(
        workspaceOverride: WorkspaceState? = nil,
        captureMode: HistoryCaptureMode = .full,
        providedLayerSnapshots: [LayerHistorySnapshot],
        auditContext: HistoryEligibilityAuditContext? = nil
    ) throws {
        let entry = try makeEntryWithAudit(
            workspaceOverride: workspaceOverride,
            captureMode: captureMode,
            providedLayerSnapshots: providedLayerSnapshots,
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
            patternLibrary: current.patternLibrary,
            tipImageLibrary: current.tipImageLibrary,
            generator: current.generator,
            viewport: current.viewport,
            selection: restored.selection
        )
    }

    private func makeEntry(
        workspaceOverride: WorkspaceState? = nil,
        captureMode: HistoryCaptureMode = .full,
        providedLayerSnapshots: [LayerHistorySnapshot]? = nil
    ) throws -> WorkspaceHistoryEntry {
        let workspace = workspaceOverride ?? workspaceStore.state
        let resolvedCapture = resolveCaptureMode(captureMode, workspace: workspace)
        if case .workspaceOnly = resolvedCapture {
            // 文档级 UI 状态（例如透视辅助线）不需要触碰 Metal 图层。
        } else {
            layerSurfaceStore.prepareTextures(for: workspace.document, metal: metalContext)
        }
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
        case .workspaceOnly:
            snapshotLayerIDs = []
            mode = .workspaceOnly(topologySignature: topologySignature(for: workspace))
        }
        let requiresFullCanvasSnapshots: Bool
        switch resolvedCapture {
        case .full:
            requiresFullCanvasSnapshots = true
        case .inPlaceChangedLayers, .workspaceOnly:
            requiresFullCanvasSnapshots = false
        }

        let layerSnapshots: [LayerHistorySnapshot]
        if let providedLayerSnapshots,
           let validatedSnapshots = validatedProvidedLayerSnapshots(
                providedLayerSnapshots,
                workspace: workspace,
                snapshotLayerIDs: snapshotLayerIDs,
                requiresFullCanvasSnapshots: requiresFullCanvasSnapshots
           ) {
            layerSnapshots = validatedSnapshots
        } else {
            var snapshotLayers: [(layer: LayerRecord, texture: MTLTexture)] = []
            for layer in workspace.document.layers where snapshotLayerIDs.contains(layer.id) {
                guard
                    let surfaceID = layerSurfaceStore.surfaceID(for: layer.id),
                    let texture = layerSurfaceStore.texture(for: surfaceID)
                else {
                    continue
                }
                snapshotLayers.append((layer: layer, texture: texture))
            }

            let textureSnapshots = try serializer.snapshotBatch(
                textures: snapshotLayers.map { $0.texture }
            )

            layerSnapshots = zip(snapshotLayers, textureSnapshots).map { item, textureSnapshot in
                LayerHistorySnapshot(
                    layerID: item.layer.id,
                    texture: textureSnapshot
                )
            }
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
        providedLayerSnapshots: [LayerHistorySnapshot]? = nil,
        auditContext: HistoryEligibilityAuditContext? = nil,
        durationMetricKey: String? = nil
    ) throws -> WorkspaceHistoryEntry {
        let auditEnabled = PerformanceAuditStore.shared.isRecordingEnabled &&
            (durationMetricKey != nil || auditContext != nil)
        let startedAt = auditEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        let entry = try makeEntry(
            workspaceOverride: workspaceOverride,
            captureMode: captureMode,
            providedLayerSnapshots: providedLayerSnapshots
        )
        let ms = auditEnabled
            ? Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
            : 0

        if auditEnabled, let durationMetricKey {
            PerformanceAuditStore.shared.recordDuration(durationMetricKey, ms: ms)
        }

#if DEBUG
        if auditEnabled, let auditContext {
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

    private func validatedProvidedLayerSnapshots(
        _ snapshots: [LayerHistorySnapshot],
        workspace: WorkspaceState,
        snapshotLayerIDs: Set<LayerID>,
        requiresFullCanvasSnapshots: Bool
    ) -> [LayerHistorySnapshot]? {
        guard snapshots.count == snapshotLayerIDs.count else { return nil }

        var snapshotsByLayerID: [LayerID: LayerHistorySnapshot] = [:]
        snapshotsByLayerID.reserveCapacity(snapshots.count)

        for snapshot in snapshots {
            guard snapshotLayerIDs.contains(snapshot.layerID) else { return nil }
            guard snapshotsByLayerID[snapshot.layerID] == nil else { return nil }
            guard snapshot.texture.width > 0,
                  snapshot.texture.height > 0,
                  snapshot.texture.bytesPerRow >= snapshot.texture.width * 4,
                  snapshot.originX >= 0,
                  snapshot.originY >= 0,
                  snapshot.originX + snapshot.texture.width <= workspace.document.canvasSize.width,
                  snapshot.originY + snapshot.texture.height <= workspace.document.canvasSize.height else {
                return nil
            }
            if requiresFullCanvasSnapshots,
               snapshot.coversFullCanvas(workspace.document.canvasSize) == false {
                return nil
            }
            snapshotsByLayerID[snapshot.layerID] = snapshot
        }

        var orderedSnapshots: [LayerHistorySnapshot] = []
        orderedSnapshots.reserveCapacity(snapshotLayerIDs.count)
        for layer in workspace.document.layers where snapshotLayerIDs.contains(layer.id) {
            guard let provided = snapshotsByLayerID[layer.id] else {
                return nil
            }
            orderedSnapshots.append(provided)
        }
        guard orderedSnapshots.count == snapshotLayerIDs.count else { return nil }
        return orderedSnapshots
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
        case .workspaceOnly(let topologySignature):
            try restoreWorkspaceOnly(
                workspace: mergedWorkspace,
                expectedTopologySignature: topologySignature
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
        case .workspaceOnly(let topologySignature):
            try restoreWorkspaceOnly(
                workspace: entry.workspace,
                expectedTopologySignature: topologySignature
            )
        }
        resetHistory()
    }

    private func restoreWorkspaceOnly(
        workspace: WorkspaceState,
        expectedTopologySignature: WorkspaceHistoryEntry.TopologySignature
    ) throws {
        guard topologySignature(for: workspaceStore.state) == expectedTopologySignature,
              topologySignature(for: workspace) == expectedTopologySignature else {
            throw HistoryControllerError.dirtyRestoreTopologyMismatch
        }
        workspaceStore.replaceState(workspace)
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
        case .workspaceOnly(let expectedTopologySignature):
            guard topologySignature(for: workspaceStore.state) == expectedTopologySignature else {
                return .full
            }
            return .workspaceOnly
        }
    }

    private func restoreSnapshots(_ layerSnapshots: [LayerHistorySnapshot]) throws {
        var batchItems: [(snapshot: LayerTextureSnapshot, texture: MTLTexture, destinationX: Int, destinationY: Int)] = []
        batchItems.reserveCapacity(layerSnapshots.count)

        for layerSnapshot in layerSnapshots {
            guard
                let surfaceID = layerSurfaceStore.surfaceID(for: layerSnapshot.layerID),
                let texture = layerSurfaceStore.texture(for: surfaceID)
            else {
                continue
            }
            batchItems.append((
                snapshot: layerSnapshot.texture,
                texture: texture,
                destinationX: layerSnapshot.originX,
                destinationY: layerSnapshot.originY
            ))
        }

        try serializer.restoreBatch(batchItems)
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
        case .workspaceOnly:
            return .workspaceOnly
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

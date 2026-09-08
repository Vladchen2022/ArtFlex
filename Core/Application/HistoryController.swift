import Foundation
import Metal

enum LayerHistoryResourceKind: String, Codable, Sendable, Equatable {
    case content
    case mask
}

struct LayerHistorySnapshot: Codable, Sendable, Equatable {
    var layerID: LayerID
    var resourceKind: LayerHistoryResourceKind
    var texture: LayerTextureSnapshot
    var originX: Int
    var originY: Int

    enum CodingKeys: String, CodingKey {
        case layerID
        case resourceKind
        case texture
        case originX
        case originY
    }

    init(
        layerID: LayerID,
        resourceKind: LayerHistoryResourceKind = .content,
        texture: LayerTextureSnapshot,
        originX: Int = 0,
        originY: Int = 0
    ) {
        self.layerID = layerID
        self.resourceKind = resourceKind
        self.texture = texture
        self.originX = originX
        self.originY = originY
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layerID = try container.decode(LayerID.self, forKey: .layerID)
        resourceKind = try container.decodeIfPresent(LayerHistoryResourceKind.self, forKey: .resourceKind) ?? .content
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
        case metadataOnly(identitySignature: IdentitySignature)
    }

    struct TopologySignature: Sendable, Equatable {
        var canvasSize: CanvasSize
        var orderedLayerIDs: [LayerID]
        var layerCount: Int
    }

    struct IdentitySignature: Sendable, Equatable {
        var canvasSize: CanvasSize
        var layerIDs: Set<LayerID>
    }

    var workspace: WorkspaceState
    var layerSnapshots: [LayerHistorySnapshot]
    var approxByteCount: Int
    var mode: Mode
    var preservesCommonLayerTexturesAcrossTopologyChange: Bool
    var visibleMetadata: VisibleHistoryEntryMetadata
}

enum HistoryCaptureMode {
    case full
    case inPlaceChangedLayers([LayerID])
    /// Canvas dimensions stay fixed, but layer or mask topology may change. Only resources that
    /// disappear or are mutated need snapshots; common layer textures remain resident.
    case topologyDelta(changedLayerIDs: [LayerID])
    case workspaceOnly
    case metadataOnly
}

private enum HistoryControllerError: LocalizedError {
    case dirtyRestoreTopologyMismatch
    case fullResetRequestedForDirtyEntry
    case missingCaptureResource(layerID: LayerID, resourceKind: LayerHistoryResourceKind)
    case missingRestoreResource(layerID: LayerID, resourceKind: LayerHistoryResourceKind)
    case unableToAllocateRestoreResource(layerID: LayerID, resourceKind: LayerHistoryResourceKind)

    var errorDescription: String? {
        switch self {
        case .dirtyRestoreTopologyMismatch:
            return "Dirty history restore topology mismatch."
        case .fullResetRequestedForDirtyEntry:
            return "Full reset restore cannot be used with a dirty history entry."
        case let .missingCaptureResource(layerID, resourceKind):
            return "History capture is missing \(resourceKind.rawValue) pixels for layer \(layerID.rawValue.uuidString)."
        case let .missingRestoreResource(layerID, resourceKind):
            return "History restore target is missing \(resourceKind.rawValue) pixels for layer \(layerID.rawValue.uuidString)."
        case let .unableToAllocateRestoreResource(layerID, resourceKind):
            return "History restore could not allocate \(resourceKind.rawValue) pixels for layer \(layerID.rawValue.uuidString)."
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
    static let defaultMaxEntries = 128
    static let defaultMaxResidentBytes = 768 * 1024 * 1024

    static func adaptiveMaxResidentBytes(recommendedMaxWorkingSetSize: UInt64?) -> Int {
        guard let recommendedMaxWorkingSetSize, recommendedMaxWorkingSetSize > 0 else {
            return defaultMaxResidentBytes
        }
        let minimum = UInt64(128 * 1024 * 1024)
        return Int(min(
            UInt64(defaultMaxResidentBytes),
            max(minimum, recommendedMaxWorkingSetSize / 16)
        ))
    }

    private let workspaceStore: WorkspaceStore
    private let layerSurfaceStore: StageOneLayerSurfaceStore
    private let serializer: LayerTextureSerializer
    private let metalContext: MetalDeviceContext
    private let maxEntries: Int
    private let maxResidentBytes: Int
    private let diskCache: HistoryDiskCache?
    private let hotEntryCount: Int

    private struct StoredEntry {
        var metadata: WorkspaceHistoryEntry
        var pixels: HistoryPixelPayload
        var workspace: WorkspaceState { metadata.workspace }
        var mode: WorkspaceHistoryEntry.Mode { metadata.mode }
        var visibleMetadata: VisibleHistoryEntryMetadata { metadata.visibleMetadata }
        var approxByteCount: Int { metadata.approxByteCount }
        func materialized() throws -> WorkspaceHistoryEntry {
            var entry = metadata
            entry.layerSnapshots = try pixels.read()
            return entry
        }
    }

    private var undoStack: [StoredEntry] = []
    private var redoStack: [StoredEntry] = []
#if DEBUG
    private(set) var debugAttemptedFullResetWithDirtyEntry = false
    var debugPreventsCheckpointCapture = false
    var debugDiskCache: HistoryDiskCache? { diskCache }
#endif

    init(
        workspaceStore: WorkspaceStore,
        layerSurfaceStore: StageOneLayerSurfaceStore,
        serializer: LayerTextureSerializer,
        metalContext: MetalDeviceContext,
        maxEntries: Int = HistoryController.defaultMaxEntries,
        maxResidentBytes: Int = HistoryController.defaultMaxResidentBytes,
        diskCache: HistoryDiskCache? = nil,
        hotEntryCount: Int = 8
    ) {
        self.workspaceStore = workspaceStore
        self.layerSurfaceStore = layerSurfaceStore
        self.serializer = serializer
        self.metalContext = metalContext
        self.maxEntries = maxEntries
        self.maxResidentBytes = maxResidentBytes
        self.diskCache = diskCache
        self.hotEntryCount = max(1, hotEntryCount)
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var residentByteCount: Int { (undoStack + redoStack).reduce(0) { $0 + $1.pixels.residentBytes } }
    var diskByteCount: Int { (undoStack + redoStack).reduce(0) { $0 + $1.pixels.diskBytes } }
    var diskEntryCount: Int { (undoStack + redoStack).filter { $0.pixels.diskBytes > 0 }.count }
    var pendingDiskEntryCount: Int { (undoStack + redoStack).filter { $0.pixels.isPending }.count }
    var storageWarning: String? { diskCache?.lastFailure }

    /// Releases oldest history first while keeping the newest restore point. This is used only
    /// after an OS memory-pressure notification; document pixels are never discarded.
    func relieveMemoryPressure(critical: Bool) {
        if diskCache != nil {
            maintainStorage(hotCount: 1, byteTarget: critical ? maxResidentBytes / 8 : maxResidentBytes / 3)
            return
        }
        let entryTarget = critical ? 2 : 6
        let byteTarget = critical ? maxResidentBytes / 8 : maxResidentBytes / 3
        trimForPressure(
            &undoStack,
            entryTarget: entryTarget,
            byteTarget: byteTarget
        )
        trimForPressure(
            &redoStack,
            entryTarget: critical ? 1 : 3,
            byteTarget: critical ? maxResidentBytes / 16 : maxResidentBytes / 6
        )
    }

    var nextUndoRestoresWorkspaceOnly: Bool {
        guard let entry = undoStack.last else { return false }
        if case .workspaceOnly = entry.mode { return true }
        if case .metadataOnly = entry.mode { return true }
        return false
    }

    var nextRedoRestoresWorkspaceOnly: Bool {
        guard let entry = redoStack.last else { return false }
        if case .workspaceOnly = entry.mode { return true }
        if case .metadataOnly = entry.mode { return true }
        return false
    }

    var latestUndoWorkspaceForAudit: WorkspaceState? {
        undoStack.last?.workspace
    }

    /// User-facing history in the exact order supported by the real undo/redo stacks.
    /// Redo is reversed because the last element is the next state restored by `redo()`.
    var visibleTimeline: VisibleHistoryTimeline {
        VisibleHistoryTimeline(
            appliedEntries: undoStack.map(\.visibleMetadata),
            redoEntries: redoStack.reversed().map(\.visibleMetadata)
        )
    }

    func captureCheckpoint(
        workspaceOverride: WorkspaceState? = nil,
        captureMode: HistoryCaptureMode = .full,
        auditContext: HistoryEligibilityAuditContext? = nil
    ) throws {
#if DEBUG
        if debugPreventsCheckpointCapture { throw CocoaError(.fileWriteUnknown) }
#endif
        let entry = try makeEntryWithAudit(
            workspaceOverride: workspaceOverride,
            captureMode: captureMode,
            auditContext: auditContext,
            durationMetricKey: "HistoryController.captureCheckpoint"
        )
        clear(&redoStack)
        append(entry, to: &undoStack)
        maintainStorage()
    }

    func captureCheckpoint(
        workspaceOverride: WorkspaceState? = nil,
        captureMode: HistoryCaptureMode = .full,
        providedLayerSnapshots: [LayerHistorySnapshot],
        auditContext: HistoryEligibilityAuditContext? = nil
    ) throws {
#if DEBUG
        if debugPreventsCheckpointCapture { throw CocoaError(.fileWriteUnknown) }
#endif
        let entry = try makeEntryWithAudit(
            workspaceOverride: workspaceOverride,
            captureMode: captureMode,
            providedLayerSnapshots: providedLayerSnapshots,
            auditContext: auditContext,
            durationMetricKey: "HistoryController.captureCheckpoint"
        )
        clear(&redoStack)
        append(entry, to: &undoStack)
        maintainStorage()
    }

    func resetHistory() {
        clear(&undoStack)
        clear(&redoStack)
    }

    func captureCurrentEntry() throws -> WorkspaceHistoryEntry {
        try makeEntry()
    }

    /// Check every cold entry before a multi-step UI preview starts. This does not inflate the
    /// entire history into RAM and prevents a known broken cache halfway through a jump.
    func validateNavigation(_ plan: VisibleHistoryNavigationPlan) throws {
        let entries = plan.direction == .undo ? undoStack.suffix(plan.undoStepCount) : redoStack.suffix(plan.redoStepCount)
        guard entries.count == plan.totalStepCount else { throw HistoryDiskError.unavailable }
        for entry in entries { try entry.pixels.validateReadable() }
    }

    func undo() throws -> Bool {
        guard let stored = undoStack.last else {
            return false
        }
        // Disk validation must finish before capturing or changing any live document state.
        let previous = try stored.materialized()

        var current = try makeEntryWithAudit(
            captureMode: currentEntryCaptureMode(for: previous),
            providedLayerSnapshots: try currentLayerSnapshots(matchingRegionsIn: previous),
            auditContext: HistoryEligibilityAuditContext(
                operationKind: "undo.currentEntryCapture",
                candidateChangedLayerIDs: [],
                candidateChangedLayerIDsKnown: false,
                comparisonWorkspace: previous.workspace
            )
        )
        current.visibleMetadata = previous.visibleMetadata
        try restore(entry: previous)
        undoStack.removeLast().pixels.discard()
        append(current, to: &redoStack)
        maintainStorage()
        return true
    }

    func redo() throws -> Bool {
        guard let stored = redoStack.last else {
            return false
        }
        let next = try stored.materialized()

        var current = try makeEntryWithAudit(
            captureMode: currentEntryCaptureMode(for: next),
            providedLayerSnapshots: try currentLayerSnapshots(matchingRegionsIn: next),
            auditContext: HistoryEligibilityAuditContext(
                operationKind: "redo.currentEntryCapture",
                candidateChangedLayerIDs: [],
                candidateChangedLayerIDsKnown: false,
                comparisonWorkspace: next.workspace
            )
        )
        current.visibleMetadata = next.visibleMetadata
        try restore(entry: next)
        redoStack.removeLast().pixels.discard()
        append(current, to: &undoStack)
        maintainStorage()
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
            textureFillLibrary: current.textureFillLibrary,
            blockReferenceModuleLibrary: current.blockReferenceModuleLibrary,
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
        } else if case .metadataOnly = resolvedCapture {
            // 图层名称、顺序、可见性等元数据不需要复制任何画布纹理。
        } else {
            layerSurfaceStore.prepareTextures(for: workspace.document, metal: metalContext)
        }
        let snapshotLayerIDs: Set<LayerID>
        let mode: WorkspaceHistoryEntry.Mode
        let preservesCommonLayerTexturesAcrossTopologyChange: Bool

        switch resolvedCapture {
        case .full:
            snapshotLayerIDs = Set(workspace.document.paintLayers.map(\.id))
            mode = .full
            preservesCommonLayerTexturesAcrossTopologyChange = false
        case .inPlaceChangedLayers(let changedLayerIDs):
            snapshotLayerIDs = Set(changedLayerIDs)
            mode = .inPlaceChangedLayers(
                topologySignature: topologySignature(for: workspace),
                changedLayerIDs: changedLayerIDs
            )
            preservesCommonLayerTexturesAcrossTopologyChange = false
        case .topologyDelta(let changedLayerIDs):
            snapshotLayerIDs = Set(changedLayerIDs)
            mode = .full
            preservesCommonLayerTexturesAcrossTopologyChange = true
        case .workspaceOnly:
            snapshotLayerIDs = []
            mode = .workspaceOnly(topologySignature: topologySignature(for: workspace))
            preservesCommonLayerTexturesAcrossTopologyChange = false
        case .metadataOnly:
            snapshotLayerIDs = []
            mode = .metadataOnly(identitySignature: identitySignature(for: workspace))
            preservesCommonLayerTexturesAcrossTopologyChange = false
        }
        let requiresFullCanvasSnapshots: Bool
        switch resolvedCapture {
        case .full, .topologyDelta:
            requiresFullCanvasSnapshots = true
        case .inPlaceChangedLayers, .workspaceOnly, .metadataOnly:
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
            var snapshotLayers: [(layer: LayerRecord, resourceKind: LayerHistoryResourceKind, texture: MTLTexture)] = []
            for layer in workspace.document.paintLayers where snapshotLayerIDs.contains(layer.id) {
                guard let surfaceID = layerSurfaceStore.surfaceID(for: layer.id),
                      let texture = layerSurfaceStore.texture(for: surfaceID) else {
                    throw HistoryControllerError.missingCaptureResource(
                        layerID: layer.id,
                        resourceKind: .content
                    )
                }
                snapshotLayers.append((layer: layer, resourceKind: .content, texture: texture))
                if layer.mask != nil {
                    guard let maskTexture = layerSurfaceStore.maskTexture(for: layer.id) else {
                        throw HistoryControllerError.missingCaptureResource(
                            layerID: layer.id,
                            resourceKind: .mask
                        )
                    }
                    snapshotLayers.append((layer: layer, resourceKind: .mask, texture: maskTexture))
                }
            }

            let textureSnapshots = try serializer.snapshotBatch(
                textures: snapshotLayers.map { $0.texture }
            )

            layerSnapshots = zip(snapshotLayers, textureSnapshots).map { item, textureSnapshot in
                LayerHistorySnapshot(
                    layerID: item.layer.id,
                    resourceKind: item.resourceKind,
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
            mode: mode,
            preservesCommonLayerTexturesAcrossTopologyChange: preservesCommonLayerTexturesAcrossTopologyChange,
            visibleMetadata: VisibleHistoryEntryMetadata(
                actionKey: "generic.checkpoint",
                affectedLayerIDs: Array(snapshotLayerIDs)
            )
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
        var entry = try makeEntry(
            workspaceOverride: workspaceOverride,
            captureMode: captureMode,
            providedLayerSnapshots: providedLayerSnapshots
        )
        if let auditContext {
            entry.visibleMetadata = VisibleHistoryEntryMetadata(
                actionKey: auditContext.operationKind,
                affectedLayerIDs: auditContext.candidateChangedLayerIDs
            )
        }
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
        let requiredKeys: Set<String> = Set(workspace.document.paintLayers.flatMap { layer -> [String] in
            guard snapshotLayerIDs.contains(layer.id) else { return [] }
            var keys = ["\(layer.id.rawValue.uuidString):content"]
            if layer.mask != nil {
                keys.append("\(layer.id.rawValue.uuidString):mask")
            }
            return keys
        })
        guard snapshots.count == requiredKeys.count else { return nil }

        var snapshotsByKey: [String: LayerHistorySnapshot] = [:]
        snapshotsByKey.reserveCapacity(snapshots.count)

        for snapshot in snapshots {
            guard snapshotLayerIDs.contains(snapshot.layerID) else { return nil }
            let key = "\(snapshot.layerID.rawValue.uuidString):\(snapshot.resourceKind.rawValue)"
            guard requiredKeys.contains(key), snapshotsByKey[key] == nil else { return nil }
            let minimumBytesPerRow = snapshot.texture.width * (snapshot.resourceKind == .mask ? 1 : 4)
            guard snapshot.texture.width > 0,
                  snapshot.texture.height > 0,
                  snapshot.texture.bytesPerRow >= minimumBytesPerRow,
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
            snapshotsByKey[key] = snapshot
        }

        var orderedSnapshots: [LayerHistorySnapshot] = []
        orderedSnapshots.reserveCapacity(snapshotLayerIDs.count)
        for layer in workspace.document.layers where snapshotLayerIDs.contains(layer.id) {
            let contentKey = "\(layer.id.rawValue.uuidString):content"
            guard let provided = snapshotsByKey[contentKey] else {
                return nil
            }
            orderedSnapshots.append(provided)
            if layer.mask != nil {
                let maskKey = "\(layer.id.rawValue.uuidString):mask"
                guard let mask = snapshotsByKey[maskKey] else { return nil }
                orderedSnapshots.append(mask)
            }
        }
        guard orderedSnapshots.count == requiredKeys.count else { return nil }
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
            if entry.preservesCommonLayerTexturesAcrossTopologyChange {
                try restoreTopologyDelta(entry: entry, workspace: mergedWorkspace)
            } else {
                try restoreWithFullReset(entry: entry, workspace: mergedWorkspace)
            }
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
        case .metadataOnly(let identitySignature):
            try restoreMetadataOnly(workspace: mergedWorkspace, expectedIdentitySignature: identitySignature)
        }
    }

    func restoreExact(entry: WorkspaceHistoryEntry) throws {
        switch entry.mode {
        case .full:
            if entry.preservesCommonLayerTexturesAcrossTopologyChange {
                try restoreTopologyDelta(entry: entry, workspace: entry.workspace)
            } else {
                try restoreWithFullReset(entry: entry, workspace: entry.workspace)
            }
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
        case .metadataOnly(let identitySignature):
            try restoreMetadataOnly(workspace: entry.workspace, expectedIdentitySignature: identitySignature)
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

    private func restoreMetadataOnly(
        workspace: WorkspaceState,
        expectedIdentitySignature: WorkspaceHistoryEntry.IdentitySignature
    ) throws {
        guard identitySignature(for: workspaceStore.state) == expectedIdentitySignature,
              identitySignature(for: workspace) == expectedIdentitySignature else {
            throw HistoryControllerError.dirtyRestoreTopologyMismatch
        }
        workspaceStore.replaceState(workspace)
        layerSurfaceStore.prepareTextures(for: workspace.document, metal: metalContext)
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
        let stagedTextures = try stageFullCanvasSnapshots(
            entry.layerSnapshots,
            workspace: workspace
        )
        workspaceStore.replaceState(workspace)
        layerSurfaceStore.reset()
        installStagedTextures(stagedTextures, workspace: workspace)
    }

    private func restoreTopologyDelta(
        entry: WorkspaceHistoryEntry,
        workspace: WorkspaceState
    ) throws {
        guard workspaceStore.state.document.canvasSize == workspace.document.canvasSize else {
            throw HistoryControllerError.dirtyRestoreTopologyMismatch
        }
        let stagedTextures = try stageFullCanvasSnapshots(
            entry.layerSnapshots,
            workspace: workspace,
            requireCompleteDocument: false
        )
        workspaceStore.replaceState(workspace)
        // Common layer textures remain resident. Deleted or mutated resources were restored into
        // independent textures before the document topology changed, so allocation/readback
        // failure cannot leave the workspace half-restored.
        installStagedTextures(stagedTextures, workspace: workspace)
        layerSurfaceStore.prepareTextures(for: workspace.document, metal: metalContext)
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

        try restoreSnapshots(entry.layerSnapshots)
        workspaceStore.replaceState(workspace)
    }

    private func currentEntryCaptureMode(for targetEntry: WorkspaceHistoryEntry) -> HistoryCaptureMode {
        if targetEntry.preservesCommonLayerTexturesAcrossTopologyChange {
            let currentPaintLayerIDs = Set(workspaceStore.state.document.paintLayers.map(\.id))
            let targetPaintLayerIDs = Set(targetEntry.workspace.document.paintLayers.map(\.id))
            let currentOnlyLayerIDs = currentPaintLayerIDs.subtracting(targetPaintLayerIDs)
            let targetChangedLayerIDs = Set(targetEntry.layerSnapshots.map(\.layerID))
                .intersection(currentPaintLayerIDs)
            return .topologyDelta(
                changedLayerIDs: Array(currentOnlyLayerIDs.union(targetChangedLayerIDs))
            )
        }
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
        case .metadataOnly(let expectedIdentitySignature):
            guard identitySignature(for: workspaceStore.state) == expectedIdentitySignature else {
                return .full
            }
            return .metadataOnly
        }
    }

    /// Undo replaces only these regions, so its inverse needs only the same current pixels.
    /// Do not expand a small brush checkpoint into a full-layer redo (and then back again).
    private func currentLayerSnapshots(
        matchingRegionsIn target: WorkspaceHistoryEntry
    ) throws -> [LayerHistorySnapshot]? {
        guard case .inPlaceChangedLayers(let changedIDs) = currentEntryCaptureMode(for: target),
              target.layerSnapshots.contains(where: { !$0.coversFullCanvas(workspaceStore.state.document.canvasSize) }),
              let regions = validatedProvidedLayerSnapshots(
                target.layerSnapshots, workspace: workspaceStore.state,
                snapshotLayerIDs: Set(changedIDs), requiresFullCanvasSnapshots: false
              ) else { return nil }

        let requests = try regions.map { region -> LayerTextureRegionSnapshotRequest in
            let texture: MTLTexture?
            switch region.resourceKind {
            case .content:
                texture = layerSurfaceStore.surfaceID(for: region.layerID).flatMap(layerSurfaceStore.texture(for:))
            case .mask:
                texture = layerSurfaceStore.maskTexture(for: region.layerID)
            }
            guard let texture else {
                throw HistoryControllerError.missingCaptureResource(layerID: region.layerID, resourceKind: region.resourceKind)
            }
            return LayerTextureRegionSnapshotRequest(texture: texture,
                originX: region.originX, originY: region.originY,
                width: region.texture.width, height: region.texture.height)
        }
        return try zip(regions, serializer.snapshotRegions(requests)).map { region, pixels in
            LayerHistorySnapshot(layerID: region.layerID, resourceKind: region.resourceKind,
                texture: pixels, originX: region.originX, originY: region.originY)
        }
    }

    private func restoreSnapshots(_ layerSnapshots: [LayerHistorySnapshot]) throws {
        var targets: [(layerSnapshot: LayerHistorySnapshot, texture: MTLTexture)] = []
        targets.reserveCapacity(layerSnapshots.count)

        for layerSnapshot in layerSnapshots {
            let texture: MTLTexture?
            switch layerSnapshot.resourceKind {
            case .content:
                texture = layerSurfaceStore.surfaceID(for: layerSnapshot.layerID)
                    .flatMap(layerSurfaceStore.texture(for:))
            case .mask:
                texture = layerSurfaceStore.maskTexture(for: layerSnapshot.layerID)
            }
            guard let texture else {
                throw HistoryControllerError.missingRestoreResource(
                    layerID: layerSnapshot.layerID,
                    resourceKind: layerSnapshot.resourceKind
                )
            }
            targets.append((layerSnapshot, texture))
        }

        // Restore into full-size clones first. This also makes the tiled transfer path atomic:
        // a later staging failure cannot leave earlier tiles written into the live layer.
        let replacementTextures = try serializer.cloneBatchForDeferredSnapshot(
            textures: targets.map(\.texture)
        )
        let batchItems = zip(targets, replacementTextures).map { target, replacement in
            (
                snapshot: target.layerSnapshot.texture,
                texture: replacement,
                destinationX: target.layerSnapshot.originX,
                destinationY: target.layerSnapshot.originY
            )
        }
        try serializer.restoreBatch(batchItems)
        for (target, replacement) in zip(targets, replacementTextures) {
            switch target.layerSnapshot.resourceKind {
            case .content:
                guard let surfaceID = layerSurfaceStore.surfaceID(for: target.layerSnapshot.layerID) else {
                    throw HistoryControllerError.missingRestoreResource(
                        layerID: target.layerSnapshot.layerID,
                        resourceKind: .content
                    )
                }
                layerSurfaceStore.swapTexture(for: surfaceID, with: replacement)
            case .mask:
                layerSurfaceStore.setMaskTexture(replacement, for: target.layerSnapshot.layerID)
            }
        }
    }

    private struct StagedHistoryResource {
        var layerID: LayerID
        var resourceKind: LayerHistoryResourceKind
        var texture: MTLTexture
    }

    /// Builds and fills all replacement textures before mutating the live workspace. History
    /// restoration is therefore all-or-nothing even if Metal cannot allocate another surface.
    private func stageFullCanvasSnapshots(
        _ snapshots: [LayerHistorySnapshot],
        workspace: WorkspaceState,
        requireCompleteDocument: Bool = true
    ) throws -> [StagedHistoryResource] {
        let expectedKeys: Set<String> = Set(workspace.document.paintLayers.flatMap { layer -> [String] in
            var keys = [historyResourceKey(layerID: layer.id, resourceKind: .content)]
            if layer.mask != nil {
                keys.append(historyResourceKey(layerID: layer.id, resourceKind: .mask))
            }
            return keys
        })
        var actualKeys = Set<String>()
        var staged: [StagedHistoryResource] = []
        var restoreItems: [(snapshot: LayerTextureSnapshot, texture: MTLTexture, destinationX: Int, destinationY: Int)] = []
        staged.reserveCapacity(snapshots.count)
        restoreItems.reserveCapacity(snapshots.count)

        for snapshot in snapshots {
            let key = historyResourceKey(layerID: snapshot.layerID, resourceKind: snapshot.resourceKind)
            guard expectedKeys.contains(key), actualKeys.insert(key).inserted,
                  snapshot.coversFullCanvas(workspace.document.canvasSize) else {
                throw HistoryControllerError.dirtyRestoreTopologyMismatch
            }
            let pixelFormat: MTLPixelFormat = snapshot.resourceKind == .mask
                ? .r8Unorm
                : .bgra8Unorm_srgb
            guard let texture = layerSurfaceStore.makeTexture(
                width: workspace.document.canvasSize.width,
                height: workspace.document.canvasSize.height,
                pixelFormat: pixelFormat,
                metal: metalContext
            ) else {
                throw HistoryControllerError.unableToAllocateRestoreResource(
                    layerID: snapshot.layerID,
                    resourceKind: snapshot.resourceKind
                )
            }
            staged.append(.init(
                layerID: snapshot.layerID,
                resourceKind: snapshot.resourceKind,
                texture: texture
            ))
            restoreItems.append((
                snapshot: snapshot.texture,
                texture: texture,
                destinationX: 0,
                destinationY: 0
            ))
        }

        if requireCompleteDocument, actualKeys != expectedKeys {
            throw HistoryControllerError.dirtyRestoreTopologyMismatch
        }
        try serializer.restoreBatch(restoreItems)
        return staged
    }

    private func installStagedTextures(
        _ resources: [StagedHistoryResource],
        workspace: WorkspaceState
    ) {
        _ = layerSurfaceStore.surfaceRecords(for: workspace.document)
        for resource in resources {
            switch resource.resourceKind {
            case .content:
                if let surfaceID = layerSurfaceStore.surfaceID(for: resource.layerID) {
                    layerSurfaceStore.swapTexture(for: surfaceID, with: resource.texture)
                }
            case .mask:
                layerSurfaceStore.setMaskTexture(resource.texture, for: resource.layerID)
            }
        }
    }

    private func historyResourceKey(
        layerID: LayerID,
        resourceKind: LayerHistoryResourceKind
    ) -> String {
        "\(layerID.rawValue.uuidString):\(resourceKind.rawValue)"
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
            guard !uniqueLayerIDs.isEmpty else {
                return .full
            }
            let validLayerIDs = Set(workspace.document.layers.map(\.id))
            guard uniqueLayerIDs.allSatisfy({ validLayerIDs.contains($0) }) else {
                return .full
            }
            return .inPlaceChangedLayers(uniqueLayerIDs)
        case .topologyDelta(let changedLayerIDs):
            let validPaintLayerIDs = Set(workspace.document.paintLayers.map(\.id))
            let uniqueLayerIDs = Array(Set(changedLayerIDs).intersection(validPaintLayerIDs))
            return .topologyDelta(changedLayerIDs: uniqueLayerIDs)
        case .workspaceOnly:
            return .workspaceOnly
        case .metadataOnly:
            return .metadataOnly
        }
    }

    private func topologySignature(for workspace: WorkspaceState) -> WorkspaceHistoryEntry.TopologySignature {
        WorkspaceHistoryEntry.TopologySignature(
            canvasSize: workspace.document.canvasSize,
            orderedLayerIDs: workspace.document.layers.map(\.id),
            layerCount: workspace.document.layers.count
        )
    }

    private func identitySignature(for workspace: WorkspaceState) -> WorkspaceHistoryEntry.IdentitySignature {
        WorkspaceHistoryEntry.IdentitySignature(
            canvasSize: workspace.document.canvasSize,
            layerIDs: Set(workspace.document.layers.map(\.id))
        )
    }

    private func append(
        _ entry: WorkspaceHistoryEntry,
        to stack: inout [StoredEntry]
    ) {
        var metadata = entry
        metadata.layerSnapshots = []
        stack.append(StoredEntry(metadata: metadata, pixels: HistoryPixelPayload(entry.layerSnapshots, cache: diskCache)))
        while stack.count > max(1, maxEntries) { stack.removeFirst().pixels.discard() }
    }

    private func clear(_ stack: inout [StoredEntry]) {
        for entry in stack { entry.pixels.discard() }
        stack.removeAll()
    }

    private func maintainStorage(hotCount: Int? = nil, byteTarget: Int? = nil) {
        let hot = hotCount ?? hotEntryCount
        let target = max(0, byteTarget ?? maxResidentBytes)
        if diskCache != nil {
            // The stacks remain a contiguous sequence. Never evict a middle delta.
            for stack in [undoStack, redoStack] {
                for entry in stack.dropLast(hot) { entry.pixels.spill() }
            }
            var projected = (undoStack + redoStack).reduce(0) { $0 + $1.pixels.projectedResidentBytes }
            for stack in [undoStack, redoStack] {
                for entry in stack.dropLast() where projected > target {
                    let bytes = entry.pixels.projectedResidentBytes
                    if entry.pixels.spill() { projected -= bytes }
                }
            }
        }
        // Failed/unavailable disk writes retain RAM first. If it exceeds budget, fall back to
        // the existing oldest-first pruning policy, always preserving a newest restore point.
        func projectedBytes() -> Int {
            (undoStack + redoStack).reduce(0) { $0 + $1.pixels.projectedResidentBytes }
        }
        while projectedBytes() > target, undoStack.count > 1 || redoStack.count > 1 {
            if undoStack.count > 1 {
                undoStack.removeFirst().pixels.discard()
            } else {
                redoStack.removeFirst().pixels.discard()
            }
            // Evicting an archived oldest entry frees disk budget. Retry cold RAM entries
            // before pruning again, otherwise a full disk budget could erase the entire tail.
            if diskCache != nil {
                for stack in [undoStack, redoStack] {
                    for entry in stack.dropLast() where projectedBytes() > target { entry.pixels.spill() }
                }
            }
        }
        // Background writes are not free memory yet. Bound the pending backlog too, so fast
        // drawing or a slow/full disk cannot retain an unbounded queue of pixel snapshots.
        let hardTarget = min(Int.max / 2, max(target, maxResidentBytes)) * 2
        while residentByteCount > hardTarget, undoStack.count > 1 || redoStack.count > 1 {
            if undoStack.count > 1 { undoStack.removeFirst().pixels.discard() }
            else { redoStack.removeFirst().pixels.discard() }
        }
    }

    private func trimForPressure(
        _ stack: inout [StoredEntry],
        entryTarget: Int,
        byteTarget: Int
    ) {
        while stack.count > max(1, entryTarget) {
            stack.removeFirst().pixels.discard()
        }
        while stack.reduce(0, { $0 + $1.pixels.residentBytes }) > max(0, byteTarget), stack.count > 1 {
            stack.removeFirst().pixels.discard()
        }
    }
}

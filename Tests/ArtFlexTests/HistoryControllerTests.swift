import Metal
import Testing
@testable import ArtFlex

struct HistoryControllerTests {
    @Test @MainActor
    func localUndoRedoRetainsOnlyTheOriginalRegionAndPreservesOutsidePixels() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 256, height: 256))
        let layerID = harness.workspaceStore.state.document.activeLayerID
        func texture() throws -> MTLTexture {
            let surfaceID = try #require(harness.layerSurfaceStore.surfaceID(for: layerID))
            return try #require(harness.layerSurfaceStore.texture(for: surfaceID))
        }
        // Sentinel outside the changed area must survive both directions.
        try harness.writeOpaquePixel(layerID: layerID, x: 200, y: 200, value: 137)
        let before = try harness.serializer.snapshot(texture: texture())
        let region = try harness.serializer.snapshot(texture: texture(), originX: 22, originY: 33, width: 12, height: 13)
        try harness.history.captureCheckpoint(captureMode: .inPlaceChangedLayers([layerID]),
            providedLayerSnapshots: [.init(layerID: layerID, texture: region, originX: 22, originY: 33)])
        let patch = LayerTextureSnapshot(width: 12, height: 13, bytesPerRow: 48, pixelData: Data(repeating: 255, count: 624))
        try harness.serializer.restore(snapshot: patch, into: texture(), destinationX: 22, destinationY: 33)
        let after = try harness.serializer.snapshot(texture: texture())
        #expect(harness.history.residentByteCount == 624)
        for _ in 0..<4 {
            #expect(try harness.history.undo())
            #expect(harness.history.residentByteCount == 624)
            #expect(try harness.serializer.snapshot(texture: texture()) == before)
            #expect(try harness.history.redo())
            #expect(harness.history.residentByteCount == 624)
            #expect(try harness.serializer.snapshot(texture: texture()) == after)
        }
    }

    @Test @MainActor
    func localContentAndMaskHistoryKeepTheirDifferentBoundsInBothDirections() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 256, height: 256))
        let layerID = harness.workspaceStore.state.document.activeLayerID
        harness.workspaceStore.updateDocument { document in
            if let index = document.layers.firstIndex(where: { $0.id == layerID }) {
                document.layers[index].mask = LayerMaskDescriptor()
            }
        }
        harness.layerSurfaceStore.prepareTextures(for: harness.workspaceStore.state.document, metal: harness.metalContext)
        func textures() throws -> [MTLTexture] {
            let surfaceID = try #require(harness.layerSurfaceStore.surfaceID(for: layerID))
            let content = try #require(harness.layerSurfaceStore.texture(for: surfaceID))
            let mask = try #require(harness.layerSurfaceStore.maskTexture(for: layerID))
            return [content, mask]
        }
        let initialTextures = try textures()
        let before = try harness.serializer.snapshotBatch(textures: initialTextures)
        let contentRegion = try harness.serializer.snapshot(texture: initialTextures[0], originX: 10, originY: 10, width: 8, height: 9)
        let maskRegion = try harness.serializer.snapshot(texture: initialTextures[1], originX: 18, originY: 20, width: 7, height: 11)
        try harness.history.captureCheckpoint(captureMode: .inPlaceChangedLayers([layerID]), providedLayerSnapshots: [
            .init(layerID: layerID, texture: contentRegion, originX: 10, originY: 10),
            .init(layerID: layerID, resourceKind: .mask, texture: maskRegion, originX: 18, originY: 20)
        ])
        try harness.serializer.restore(snapshot: .init(width: 8, height: 9, bytesPerRow: 32, pixelData: Data(repeating: 255, count: 288)),
            into: initialTextures[0], destinationX: 10, destinationY: 10)
        try harness.serializer.restore(snapshot: .init(width: 7, height: 11, bytesPerRow: 7, pixelData: Data(repeating: 0, count: 77)),
            into: initialTextures[1], destinationX: 18, destinationY: 20)
        let after = try harness.serializer.snapshotBatch(textures: textures())
        for _ in 0..<3 {
            #expect(try harness.history.undo())
            #expect(harness.history.residentByteCount == 365)
            #expect(try harness.serializer.snapshotBatch(textures: textures()) == before)
            #expect(try harness.history.redo())
            #expect(harness.history.residentByteCount == 365)
            #expect(try harness.serializer.snapshotBatch(textures: textures()) == after)
        }
    }

    @Test @MainActor
    func smallDiskRegionHistoryDoesNotLoseDepthAfterUndoAndRedo() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 128, height: 128))
        let cache = HistoryDiskCache(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("ArtFlexHistoryTests"), maximumBytes: 2_000)
        let history = HistoryController(workspaceStore: harness.workspaceStore,
            layerSurfaceStore: harness.layerSurfaceStore, serializer: harness.serializer,
            metalContext: harness.metalContext, maxResidentBytes: 400, diskCache: cache, hotEntryCount: 1)
        let layerID = harness.workspaceStore.state.document.activeLayerID
        func texture() throws -> MTLTexture {
            let surfaceID = try #require(harness.layerSurfaceStore.surfaceID(for: layerID))
            return try #require(harness.layerSurfaceStore.texture(for: surfaceID))
        }
        var expected = [try harness.serializer.snapshot(texture: texture())]
        for i in 0..<20 {
            let x = 2 + (i % 10) * 12, y = 20 + (i / 10) * 20
            let region = try harness.serializer.snapshot(texture: texture(), originX: x, originY: y, width: 5, height: 5)
            try history.captureCheckpoint(captureMode: .inPlaceChangedLayers([layerID]),
                providedLayerSnapshots: [.init(layerID: layerID, texture: region, originX: x, originY: y)])
            try harness.serializer.restore(snapshot: .init(width: 5, height: 5, bytesPerRow: 20, pixelData: Data(repeating: UInt8(255 - i), count: 100)),
                into: texture(), destinationX: x, destinationY: y)
            cache.waitForPendingWrites()
            expected.append(try harness.serializer.snapshot(texture: texture()))
        }
        #expect(history.debugUndoCount == 20 && history.diskEntryCount == 19)
        for state in expected.dropLast().reversed() {
            #expect(try history.undo())
            cache.waitForPendingWrites()
            #expect(try harness.serializer.snapshot(texture: texture()) == state)
            #expect(history.residentByteCount <= 200)
            #expect(history.debugUndoCount + history.debugRedoCount == 20)
        }
        for state in expected.dropFirst() {
            #expect(try history.redo())
            cache.waitForPendingWrites()
            #expect(try harness.serializer.snapshot(texture: texture()) == state)
            #expect(history.residentByteCount <= 200)
            #expect(history.debugUndoCount + history.debugRedoCount == 20)
        }
    }

    @Test @MainActor
    func fullDiskBudgetEvictsOnlyOldestContiguousHistory() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 16, height: 16))
        // Two layers = 2 KiB per checkpoint: two disk slots plus one resident slot.
        let cache = HistoryDiskCache(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("ArtFlexHistoryTests"), maximumBytes: 4_096)
        let history = HistoryController(workspaceStore: harness.workspaceStore,
            layerSurfaceStore: harness.layerSurfaceStore, serializer: harness.serializer,
            metalContext: harness.metalContext, maxResidentBytes: 2_048, diskCache: cache, hotEntryCount: 1)
        for i in 0..<6 {
            harness.workspaceStore.updateDocument { $0.metadata.name = "state-\(i)" }
            try history.captureCheckpoint()
            cache.waitForPendingWrites()
        }
        #expect(history.debugUndoCount == 3)
        #expect(history.diskEntryCount == 2)
        #expect(history.residentByteCount == 2_048)
        #expect(cache.reservedByteCount <= 4_096)
        #expect(try history.undo())
        #expect(harness.workspaceStore.state.document.metadata.name == "state-5")
    }

    @Test @MainActor
    func diskHistoryRetainsAndRestoresPixelsBeyondResidentBudget() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let cache = HistoryDiskCache(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("ArtFlexHistoryTests"))
        let history = HistoryController(workspaceStore: harness.workspaceStore,
            layerSurfaceStore: harness.layerSurfaceStore, serializer: harness.serializer,
            metalContext: harness.metalContext, maxEntries: 40, maxResidentBytes: 80_000,
            diskCache: cache, hotEntryCount: 1)
        let layerID = harness.workspaceStore.state.document.activeLayerID
        var expected: [LayerTextureSnapshot] = []
        func pixels() throws -> LayerTextureSnapshot {
            let surface = try #require(harness.layerSurfaceStore.surfaceID(for: layerID))
            return try harness.serializer.snapshot(texture: #require(harness.layerSurfaceStore.texture(for: surface)))
        }
        expected.append(try pixels())
        for i in 0..<30 {
            try harness.drawBrushStroke(history: history, layerID: layerID, points: [
                .init(x: Double(5 + i), y: 12, pressure: 1),
                .init(x: Double(6 + i), y: 45, pressure: 1)
            ])
            cache.waitForPendingWrites()
            expected.append(try pixels())
        }
        #expect(history.debugUndoCount == 30)
        #expect(history.diskEntryCount == 29)
        #expect(history.residentByteCount <= 80_000)
        for state in expected.dropLast().reversed() {
            #expect(try history.undo())
            cache.waitForPendingWrites()
            #expect(try pixels() == state)
        }
        #expect(!history.canUndo)
        for state in expected.dropFirst() {
            #expect(try history.redo())
            cache.waitForPendingWrites()
            #expect(try pixels() == state)
        }
        #expect(!history.canRedo)
        history.resetHistory()
        cache.waitForPendingWrites()
        #expect(history.residentByteCount == 0 && history.diskByteCount == 0)
        #expect(cache.reservedByteCount == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.directoryURL.path).isEmpty)
    }

    @Test @MainActor
    func unreadableDiskHistoryDoesNotChangeWorkspacePixelsOrStacks() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let cache = HistoryDiskCache(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("ArtFlexHistoryTests"))
        let history = HistoryController(workspaceStore: harness.workspaceStore,
            layerSurfaceStore: harness.layerSurfaceStore, serializer: harness.serializer,
            metalContext: harness.metalContext, diskCache: cache, hotEntryCount: 1)
        let layerID = harness.workspaceStore.state.document.activeLayerID
        for x in [8, 28] {
            try harness.drawBrushStroke(history: history, layerID: layerID, points: [
                .init(x: Double(x), y: 10, pressure: 1), .init(x: Double(x + 8), y: 30, pressure: 1)
            ])
        }
        cache.waitForPendingWrites()
        let url = try #require(FileManager.default.contentsOfDirectory(at: cache.directoryURL,
            includingPropertiesForKeys: nil).first)
        let saved = try Data(contentsOf: url)
        try Data([0]).write(to: url)
        #expect(try history.undo()) // newest in-memory checkpoint is still usable
        let workspace = harness.workspaceStore.state
        let surface = try #require(harness.layerSurfaceStore.surfaceID(for: layerID))
        let pixels = try harness.serializer.snapshot(texture: #require(harness.layerSurfaceStore.texture(for: surface)))
        #expect(throws: HistoryDiskError.self) { try history.undo() }
        #expect(history.debugUndoCount == 1 && history.debugRedoCount == 1)
        #expect(harness.workspaceStore.state == workspace)
        #expect(try harness.serializer.snapshot(texture: #require(harness.layerSurfaceStore.texture(for: surface))) == pixels)
        // Fixing the temporary read failure allows retry: the history handle was not popped.
        try saved.write(to: url)
        #expect(try history.undo())
    }

    @Test @MainActor
    func diskBackedRedoBranchIsDeletedAfterNewCheckpoint() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 16, height: 16))
        let cache = HistoryDiskCache(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("ArtFlexHistoryTests"))
        let history = HistoryController(workspaceStore: harness.workspaceStore,
            layerSurfaceStore: harness.layerSurfaceStore, serializer: harness.serializer,
            metalContext: harness.metalContext, diskCache: cache, hotEntryCount: 1)
        for _ in 0..<5 { try history.captureCheckpoint(); cache.waitForPendingWrites() }
        for _ in 0..<4 { #expect(try history.undo()); cache.waitForPendingWrites() }
        #expect(history.diskEntryCount > 0)
        try history.captureCheckpoint()
        cache.waitForPendingWrites()
        #expect(!history.canRedo)
        #expect(history.debugUndoCount == 2)
        #expect(history.diskEntryCount == 1)
        history.resetHistory()
        cache.waitForPendingWrites()
        #expect(cache.reservedByteCount == 0)
    }

    @Test
    func historyNavigationPreservesTransientToolSettings() {
        var restored = WorkspaceState.stageOneDefault
        var current = WorkspaceState.stageOneDefault

        restored.selection = .empty
        current.toolSession.brush.buildMode = .opacityCap
        current.toolSession.brush.pressureOpacityAmount = 0.42
        current.viewport.zoomScale = 2.5

        let merged = HistoryController.mergedWorkspaceForHistoryNavigation(
            restored: restored,
            current: current
        )

        #expect(merged.document == restored.document)
        #expect(merged.selection == restored.selection)
        #expect(merged.toolSession == current.toolSession)
        #expect(merged.viewport == current.viewport)
    }

    @Test
    func historyNavigationPreservesTipImageLibraryState() {
        var restored = WorkspaceState.stageOneDefault
        var current = WorkspaceState.stageOneDefault

        restored.tipImageLibrary = .empty
        current.tipImageLibrary = TipImageLibraryState(
            items: [
                TipImageLibraryItem(
                    id: BrushTipImageAssetID(rawValue: "tip-a"),
                    sourceInfo: ImportedTipSourceInfo(
                        sourceLabel: "A",
                        pixelWidth: 64,
                        pixelHeight: 64
                    ),
                    maskData: Data([255, 0, 0, 255])
                ),
                TipImageLibraryItem(
                    id: BrushTipImageAssetID(rawValue: "tip-b"),
                    sourceInfo: ImportedTipSourceInfo(
                        sourceLabel: "B",
                        pixelWidth: 96,
                        pixelHeight: 96
                    ),
                    maskData: Data([0, 255, 0, 255])
                )
            ]
        )

        let merged = HistoryController.mergedWorkspaceForHistoryNavigation(
            restored: restored,
            current: current
        )

        #expect(merged.tipImageLibrary == current.tipImageLibrary)
        #expect(merged.tipImageLibrary.items.count == 2)
    }

    @Test
    @MainActor
    func workspaceOnlyHistoryRestoresDocumentStateWithoutTextureSnapshots() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 16, height: 16))

        try harness.history.captureCheckpoint(captureMode: .workspaceOnly)
        harness.workspaceStore.updateDocument { document in
            document.perspectiveGuide = .initial(canvasSize: document.canvasSize)
        }

        #expect(harness.history.debugUndoEntryApproxByteCounts.last == 0)
        let undoMode = try #require(harness.history.debugUndoEntryModes.last)
        if case .workspaceOnly = undoMode {
            // Expected: this entry contains document state but no layer texture snapshots.
        } else {
            Issue.record("Expected workspace-only history entry")
        }

        #expect(try harness.history.undo())
        #expect(harness.workspaceStore.state.document.perspectiveGuide == nil)
        #expect(try harness.history.redo())
        #expect(harness.workspaceStore.state.document.perspectiveGuide?.mode == .threePoint)
    }

    @Test
    @MainActor
    func topologyDeltaAddLayerUsesNoFullDocumentSnapshotAndRedoRestoresNewPixels() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 16, height: 16))
        let existingLayerID = harness.workspaceStore.state.document.activeLayerID
        try harness.writeOpaquePixel(layerID: existingLayerID, x: 2, y: 2, value: 80)

        try harness.history.captureCheckpoint(
            captureMode: .topologyDelta(changedLayerIDs: [])
        )
        #expect(harness.history.debugUndoEntryApproxByteCounts.last == 0)

        let addedLayerID = harness.addLayer()
        try harness.writeOpaquePixel(layerID: addedLayerID, x: 7, y: 7, value: 210)

        #expect(try harness.history.undo())
        #expect(harness.workspaceStore.state.document.layer(addedLayerID) == nil)
        #expect(try harness.alpha(atX: 2, y: 2, layerID: existingLayerID) > 0.99)

        #expect(try harness.history.redo())
        #expect(harness.workspaceStore.state.document.layer(addedLayerID) != nil)
        #expect(try harness.alpha(atX: 7, y: 7, layerID: addedLayerID) > 0.99)
        #expect(try harness.alpha(atX: 2, y: 2, layerID: existingLayerID) > 0.99)
    }

    @Test
    @MainActor
    func topologyDeltaDeleteSnapshotsOnlyRemovedLayerAndPreservesCommonPixels() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 16, height: 16))
        let commonLayerID = harness.workspaceStore.state.document.activeLayerID
        let removedLayerID = harness.addLayer()
        try harness.writeOpaquePixel(layerID: commonLayerID, x: 3, y: 3, value: 90)
        try harness.writeOpaquePixel(layerID: removedLayerID, x: 8, y: 8, value: 220)

        try harness.history.captureCheckpoint(
            captureMode: .topologyDelta(changedLayerIDs: [removedLayerID])
        )
        #expect(harness.history.debugUndoEntryApproxByteCounts.last == 16 * 16 * 4)

        harness.workspaceStore.updateDocument { document in
            document.removeActiveLayer()
        }
        harness.layerSurfaceStore.prepareTextures(
            for: harness.workspaceStore.state.document,
            metal: harness.metalContext
        )

        #expect(try harness.history.undo())
        #expect(try harness.alpha(atX: 8, y: 8, layerID: removedLayerID) > 0.99)
        #expect(try harness.alpha(atX: 3, y: 3, layerID: commonLayerID) > 0.99)

        #expect(try harness.history.redo())
        #expect(harness.workspaceStore.state.document.layer(removedLayerID) == nil)
        #expect(try harness.alpha(atX: 3, y: 3, layerID: commonLayerID) > 0.99)
    }

    @Test
    @MainActor
    func undoDoesNotDropTipImageLibraryState() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 16, height: 16))
        let tipImageLibrary = TipImageLibraryState(
            items: [
                TipImageLibraryItem(
                    id: BrushTipImageAssetID(rawValue: "tip-a"),
                    sourceInfo: ImportedTipSourceInfo(
                        sourceLabel: "A",
                        pixelWidth: 64,
                        pixelHeight: 64
                    ),
                    maskData: Data([255, 0, 0, 255])
                ),
                TipImageLibraryItem(
                    id: BrushTipImageAssetID(rawValue: "tip-b"),
                    sourceInfo: ImportedTipSourceInfo(
                        sourceLabel: "B",
                        pixelWidth: 96,
                        pixelHeight: 96
                    ),
                    maskData: Data([0, 255, 0, 255])
                )
            ]
        )

        harness.workspaceStore.updateTipImageLibrary { library in
            library = tipImageLibrary
        }

        try harness.history.captureCheckpoint()
        #expect(try harness.history.undo())
        #expect(harness.workspaceStore.state.tipImageLibrary == tipImageLibrary)
    }

    @Test
    @MainActor
    func historyLimitsTrimByEntryCount() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 16, height: 16))
        let history = HistoryController(
            workspaceStore: harness.workspaceStore,
            layerSurfaceStore: harness.layerSurfaceStore,
            serializer: harness.serializer,
            metalContext: harness.metalContext,
            maxEntries: 2,
            maxResidentBytes: .max
        )

        try history.captureCheckpoint()
        try history.captureCheckpoint()
        try history.captureCheckpoint()

        var undoCount = 0
        while try history.undo() {
            undoCount += 1
        }

        #expect(undoCount == 2)
    }

    @Test
    @MainActor
    func historyLimitsTrimByResidentBytes() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 16, height: 16))
        let history = HistoryController(
            workspaceStore: harness.workspaceStore,
            layerSurfaceStore: harness.layerSurfaceStore,
            serializer: harness.serializer,
            metalContext: harness.metalContext,
            maxEntries: 10,
            maxResidentBytes: 1_500
        )

        try history.captureCheckpoint()
        try history.captureCheckpoint()

        var undoCount = 0
        while try history.undo() {
            undoCount += 1
        }

        #expect(undoCount == 1)
    }

    @Test
    func defaultHistoryPolicySupportsAtLeastTwenty3000pxDirtyEntries() {
        let dirtyEntryBytes = 3_000 * 3_000 * 4
        let retainedByBudget = HistoryController.defaultMaxResidentBytes / dirtyEntryBytes
        let retainedByPolicy = min(HistoryController.defaultMaxEntries, retainedByBudget)

        #expect(HistoryController.defaultMaxEntries == 128)
        #expect(HistoryController.defaultMaxResidentBytes == 768 * 1024 * 1024)
        #expect(retainedByPolicy >= 20)
    }

    @Test
    @MainActor
    func oversizedSingleEntryStillKeepsLatestUndoState() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let history = HistoryController(
            workspaceStore: harness.workspaceStore,
            layerSurfaceStore: harness.layerSurfaceStore,
            serializer: harness.serializer,
            metalContext: harness.metalContext,
            maxEntries: 10,
            maxResidentBytes: 1_024
        )
        let layerID = harness.workspaceStore.state.document.activeLayerID

        try harness.drawBrushStroke(
            history: history,
            layerID: layerID,
            points: [
                .init(x: 10, y: 10, pressure: 1),
                .init(x: 18, y: 18, pressure: 1)
            ]
        )

        #expect(history.canUndo)
        #expect(try history.undo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) < 0.01)
    }

    @Test
    @MainActor
    func consecutiveOversizedEntriesTrimOlderEntriesButKeepNewest() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let history = HistoryController(
            workspaceStore: harness.workspaceStore,
            layerSurfaceStore: harness.layerSurfaceStore,
            serializer: harness.serializer,
            metalContext: harness.metalContext,
            maxEntries: 10,
            maxResidentBytes: 1_024
        )
        let layerID = harness.workspaceStore.state.document.activeLayerID

        try harness.drawBrushStroke(
            history: history,
            layerID: layerID,
            points: [
                .init(x: 8, y: 8, pressure: 1),
                .init(x: 16, y: 16, pressure: 1)
            ]
        )
        try harness.drawBrushStroke(
            history: history,
            layerID: layerID,
            points: [
                .init(x: 28, y: 28, pressure: 1),
                .init(x: 36, y: 36, pressure: 1)
            ]
        )
        try harness.drawBrushStroke(
            history: history,
            layerID: layerID,
            points: [
                .init(x: 44, y: 12, pressure: 1),
                .init(x: 52, y: 20, pressure: 1)
            ]
        )

        #expect(try history.undo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) > 0.01)
        #expect(try harness.alpha(atX: 32, y: 32, layerID: layerID) > 0.01)
        #expect(try harness.alpha(atX: 48, y: 16, layerID: layerID) < 0.01)
        #expect(!(try history.undo()))
    }

    @Test
    @MainActor
    func oversizedEntriesStillSupportUndoRedoForNewestEntry() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let history = HistoryController(
            workspaceStore: harness.workspaceStore,
            layerSurfaceStore: harness.layerSurfaceStore,
            serializer: harness.serializer,
            metalContext: harness.metalContext,
            maxEntries: 10,
            maxResidentBytes: 1_024
        )
        let layerID = harness.workspaceStore.state.document.activeLayerID

        try harness.drawBrushStroke(
            history: history,
            layerID: layerID,
            points: [
                .init(x: 10, y: 10, pressure: 1),
                .init(x: 18, y: 18, pressure: 1)
            ]
        )
        try harness.drawBrushStroke(
            history: history,
            layerID: layerID,
            points: [
                .init(x: 40, y: 40, pressure: 1),
                .init(x: 48, y: 48, pressure: 1)
            ]
        )

        #expect(try history.undo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) > 0.01)
        #expect(try harness.alpha(atX: 44, y: 44, layerID: layerID) < 0.01)

        #expect(try history.redo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) > 0.01)
        #expect(try harness.alpha(atX: 44, y: 44, layerID: layerID) > 0.01)
    }

    @Test
    @MainActor
    func historySupportsUndoRedoForTwoStrokesOnSameLayer() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let layerID = harness.workspaceStore.state.document.activeLayerID

        try harness.drawBrushStroke(
            useDirtyBrushHistory: true,
            layerID: layerID,
            points: [
                .init(x: 10, y: 10, pressure: 1),
                .init(x: 18, y: 18, pressure: 1)
            ]
        )
        try harness.drawBrushStroke(
            useDirtyBrushHistory: true,
            layerID: layerID,
            points: [
                .init(x: 42, y: 42, pressure: 1),
                .init(x: 52, y: 52, pressure: 1)
            ]
        )

        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) > 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: layerID) > 0.01)

        #expect(try harness.history.undo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) > 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: layerID) < 0.01)

        #expect(try harness.history.undo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) < 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: layerID) < 0.01)

        #expect(try harness.history.redo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) > 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: layerID) < 0.01)

        #expect(try harness.history.redo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) > 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: layerID) > 0.01)
        #expect(!harness.history.debugAttemptedFullResetWithDirtyEntry)
    }

    @Test
    @MainActor
    func historySupportsUndoRedoAcrossDifferentLayersWithoutClearingUntouchedLayers() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let firstLayerID = harness.workspaceStore.state.document.layers[0].id
        let secondLayerID = harness.addLayer()

        try harness.drawBrushStroke(
            useDirtyBrushHistory: true,
            layerID: firstLayerID,
            points: [
                .init(x: 10, y: 10, pressure: 1),
                .init(x: 18, y: 18, pressure: 1)
            ]
        )
        try harness.drawBrushStroke(
            useDirtyBrushHistory: true,
            layerID: secondLayerID,
            points: [
                .init(x: 42, y: 42, pressure: 1),
                .init(x: 52, y: 52, pressure: 1)
            ]
        )

        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) > 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)

        #expect(try harness.history.undo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) > 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) < 0.01)

        #expect(try harness.history.undo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) < 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) < 0.01)

        #expect(try harness.history.redo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) > 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) < 0.01)

        #expect(try harness.history.redo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) > 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)
        #expect(!harness.history.debugAttemptedFullResetWithDirtyEntry)
    }

    @Test
    @MainActor
    func hiddenLockedOpacityLayersRemainIntactAcrossDirtyBrushRestore() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let baseLayerID = harness.workspaceStore.state.document.layers[0].id
        let decoratedLayerID = harness.addLayer()

        try harness.drawBrushStroke(
            useDirtyBrushHistory: true,
            layerID: decoratedLayerID,
            points: [
                .init(x: 42, y: 42, pressure: 1),
                .init(x: 52, y: 52, pressure: 1)
            ]
        )

        harness.workspaceStore.updateDocument { document in
            document.setLayerVisibility(decoratedLayerID, isVisible: false)
            document.toggleLayerLock(decoratedLayerID)
            document.setLayerOpacity(decoratedLayerID, opacity: 0.35)
        }

        try harness.drawBrushStroke(
            useDirtyBrushHistory: true,
            layerID: baseLayerID,
            points: [
                .init(x: 10, y: 10, pressure: 1),
                .init(x: 18, y: 18, pressure: 1)
            ]
        )

        #expect(try harness.history.undo())
        #expect(try harness.alpha(atX: 46, y: 46, layerID: decoratedLayerID) > 0.01)
        #expect(try harness.alpha(atX: 12, y: 12, layerID: baseLayerID) < 0.01)
        let decoratedLayer = try #require(harness.workspaceStore.state.document.layers.first(where: { $0.id == decoratedLayerID }))
        #expect(decoratedLayer.isVisible == false)
        #expect(decoratedLayer.isLocked == true)
        #expect(abs(decoratedLayer.opacity - 0.35) < 0.001)
        #expect(!harness.history.debugAttemptedFullResetWithDirtyEntry)
    }

    @Test
    @MainActor
    func topologyChangesDoNotLoseOtherLayerContentsDuringUndoRedo() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let firstLayerID = harness.workspaceStore.state.document.layers[0].id
        let secondLayerID = harness.addLayer()

        try harness.drawBrushStroke(
            useDirtyBrushHistory: true,
            layerID: firstLayerID,
            points: [
                .init(x: 10, y: 10, pressure: 1),
                .init(x: 18, y: 18, pressure: 1)
            ]
        )
        try harness.drawBrushStroke(
            useDirtyBrushHistory: true,
            layerID: secondLayerID,
            points: [
                .init(x: 42, y: 42, pressure: 1),
                .init(x: 52, y: 52, pressure: 1)
            ]
        )
        try harness.drawBrushStroke(
            useDirtyBrushHistory: true,
            layerID: firstLayerID,
            points: [
                .init(x: 36, y: 20, pressure: 1),
                .init(x: 46, y: 30, pressure: 1)
            ]
        )
        try harness.history.captureCheckpoint()
        let thirdLayerID = harness.addLayer()
        #expect(harness.workspaceStore.state.document.layers.count == 4)

        #expect(try harness.history.undo())
        #expect(harness.workspaceStore.state.document.layers.count == 3)
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) > 0.01)
        #expect(try harness.alpha(atX: 40, y: 24, layerID: firstLayerID) > 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)

        #expect(try harness.history.undo())
        #expect(harness.workspaceStore.state.document.layers.count == 3)
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) > 0.01)
        #expect(try harness.alpha(atX: 40, y: 24, layerID: firstLayerID) < 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)

        #expect(try harness.history.redo())
        #expect(harness.workspaceStore.state.document.layers.count == 3)
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) > 0.01)
        #expect(try harness.alpha(atX: 40, y: 24, layerID: firstLayerID) > 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)

        #expect(try harness.history.redo())
        #expect(harness.workspaceStore.state.document.layers.count == 4)
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) > 0.01)
        #expect(try harness.alpha(atX: 40, y: 24, layerID: firstLayerID) > 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)
        #expect(try harness.alpha(atX: 12, y: 12, layerID: thirdLayerID) < 0.01)
        #expect(!harness.history.debugAttemptedFullResetWithDirtyEntry)
    }

    @Test
    @MainActor
    func singleLayerBrushHistoryUsesDirtyEntry() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 64, height: 64), startsWithSingleLayer: true)
        let layerID = harness.workspaceStore.state.document.activeLayerID

        try harness.drawBrushStroke(
            useDirtyBrushHistory: true,
            layerID: layerID,
            points: [
                .init(x: 12, y: 12, pressure: 1),
                .init(x: 24, y: 24, pressure: 1)
            ]
        )

        let latestMode = try #require(harness.history.debugUndoEntryModes.last)
        switch latestMode {
        case .inPlaceChangedLayers:
            break
        case .full:
            Issue.record("Single-layer brush history should retain its rendered-region delta")
        case .workspaceOnly, .metadataOnly:
            Issue.record("Brush stroke should not produce workspace-only history entries")
        }

        #expect(try harness.history.undo())
        #expect(try harness.alpha(atX: 16, y: 16, layerID: layerID) < 0.01)
        #expect(try harness.history.redo())
        #expect(try harness.alpha(atX: 16, y: 16, layerID: layerID) > 0.01)
    }

    @Test
    @MainActor
    func dirtyBrushHistoryNeverFallsBackToFullResetWithPartialSnapshots() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let firstLayerID = harness.workspaceStore.state.document.layers[0].id
        let secondLayerID = harness.addLayer()

        try harness.drawBrushStroke(
            useDirtyBrushHistory: true,
            layerID: firstLayerID,
            points: [
                .init(x: 8, y: 8, pressure: 1),
                .init(x: 16, y: 16, pressure: 1)
            ]
        )
        try harness.drawBrushStroke(
            useDirtyBrushHistory: true,
            layerID: secondLayerID,
            points: [
                .init(x: 36, y: 36, pressure: 1),
                .init(x: 44, y: 44, pressure: 1)
            ]
        )

        #expect(try harness.history.undo())
        #expect(try harness.history.undo())
        #expect(try harness.history.redo())
        #expect(try harness.history.redo())
        #expect(!harness.history.debugAttemptedFullResetWithDirtyEntry)
    }

    @Test
    @MainActor
    func dirtyUndoCapturePushesSymmetricDirtyEntryOntoRedoStack() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let firstLayerID = harness.workspaceStore.state.document.layers[0].id
        let secondLayerID = harness.addLayer()

        try harness.drawBrushStroke(
            useDirtyBrushHistory: true,
            layerID: firstLayerID,
            points: [
                .init(x: 10, y: 10, pressure: 1),
                .init(x: 18, y: 18, pressure: 1)
            ]
        )
        try harness.drawBrushStroke(
            useDirtyBrushHistory: true,
            layerID: secondLayerID,
            points: [
                .init(x: 40, y: 40, pressure: 1),
                .init(x: 48, y: 48, pressure: 1)
            ]
        )

        #expect(try harness.history.undo())
        let redoMode = try #require(harness.history.debugRedoEntryModes.last)
        switch redoMode {
        case .full:
            Issue.record("Expected symmetric dirty current-entry capture in redo stack")
        case .inPlaceChangedLayers(_, let changedLayerIDs):
            #expect(Set(changedLayerIDs) == [secondLayerID])
        case .workspaceOnly, .metadataOnly:
            Issue.record("Brush stroke should not produce workspace-only history entries")
        }
    }

    @Test
    @MainActor
    func eraserHistorySupportsUndoRedoForTwoStrokesOnSameLayer() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let layerID = harness.workspaceStore.state.document.activeLayerID

        try harness.drawStroke(
            tool: .brush,
            layerID: layerID,
            points: [
                .init(x: 10, y: 10, pressure: 1),
                .init(x: 18, y: 18, pressure: 1)
            ]
        )
        try harness.drawStroke(
            tool: .brush,
            layerID: layerID,
            points: [
                .init(x: 42, y: 42, pressure: 1),
                .init(x: 52, y: 52, pressure: 1)
            ]
        )

        try harness.drawStroke(
            tool: .eraser,
            useDirtyHistory: true,
            layerID: layerID,
            points: [
                .init(x: 10, y: 10, pressure: 1),
                .init(x: 18, y: 18, pressure: 1)
            ]
        )
        try harness.drawStroke(
            tool: .eraser,
            useDirtyHistory: true,
            layerID: layerID,
            points: [
                .init(x: 42, y: 42, pressure: 1),
                .init(x: 52, y: 52, pressure: 1)
            ]
        )

        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) < 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: layerID) < 0.01)

        #expect(try harness.history.undo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) < 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: layerID) > 0.01)

        #expect(try harness.history.undo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) > 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: layerID) > 0.01)

        #expect(try harness.history.redo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) < 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: layerID) > 0.01)

        #expect(try harness.history.redo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: layerID) < 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: layerID) < 0.01)
        #expect(!harness.history.debugAttemptedFullResetWithDirtyEntry)
    }

    @Test
    @MainActor
    func eraserHistorySupportsUndoRedoAcrossDifferentLayersWithoutClearingUntouchedLayers() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let firstLayerID = harness.workspaceStore.state.document.layers[0].id
        let secondLayerID = harness.addLayer()

        try harness.drawStroke(
            tool: .brush,
            layerID: firstLayerID,
            points: [
                .init(x: 10, y: 10, pressure: 1),
                .init(x: 18, y: 18, pressure: 1)
            ]
        )
        try harness.drawStroke(
            tool: .brush,
            layerID: secondLayerID,
            points: [
                .init(x: 42, y: 42, pressure: 1),
                .init(x: 52, y: 52, pressure: 1)
            ]
        )

        try harness.drawStroke(
            tool: .eraser,
            useDirtyHistory: true,
            layerID: firstLayerID,
            points: [
                .init(x: 10, y: 10, pressure: 1),
                .init(x: 18, y: 18, pressure: 1)
            ]
        )
        try harness.drawStroke(
            tool: .eraser,
            useDirtyHistory: true,
            layerID: secondLayerID,
            points: [
                .init(x: 42, y: 42, pressure: 1),
                .init(x: 52, y: 52, pressure: 1)
            ]
        )

        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) < 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) < 0.01)

        #expect(try harness.history.undo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) < 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)

        #expect(try harness.history.undo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) > 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)

        #expect(try harness.history.redo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) < 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)

        #expect(try harness.history.redo())
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) < 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) < 0.01)
        #expect(!harness.history.debugAttemptedFullResetWithDirtyEntry)
    }

    @Test
    @MainActor
    func hiddenLockedOpacityLayersRemainIntactAcrossDirtyEraserRestore() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let baseLayerID = harness.workspaceStore.state.document.layers[0].id
        let decoratedLayerID = harness.addLayer()

        try harness.drawStroke(
            tool: .brush,
            layerID: decoratedLayerID,
            points: [
                .init(x: 42, y: 42, pressure: 1),
                .init(x: 52, y: 52, pressure: 1)
            ]
        )

        harness.workspaceStore.updateDocument { document in
            document.setLayerVisibility(decoratedLayerID, isVisible: false)
            document.toggleLayerLock(decoratedLayerID)
            document.setLayerOpacity(decoratedLayerID, opacity: 0.35)
        }

        try harness.drawStroke(
            tool: .brush,
            layerID: baseLayerID,
            points: [
                .init(x: 10, y: 10, pressure: 1),
                .init(x: 18, y: 18, pressure: 1)
            ]
        )
        try harness.drawStroke(
            tool: .eraser,
            useDirtyHistory: true,
            layerID: baseLayerID,
            points: [
                .init(x: 10, y: 10, pressure: 1),
                .init(x: 18, y: 18, pressure: 1)
            ]
        )

        #expect(try harness.history.undo())
        #expect(try harness.alpha(atX: 46, y: 46, layerID: decoratedLayerID) > 0.01)
        #expect(try harness.alpha(atX: 12, y: 12, layerID: baseLayerID) > 0.01)
        let decoratedLayer = try #require(harness.workspaceStore.state.document.layers.first(where: { $0.id == decoratedLayerID }))
        #expect(decoratedLayer.isVisible == false)
        #expect(decoratedLayer.isLocked == true)
        #expect(abs(decoratedLayer.opacity - 0.35) < 0.001)
        #expect(!harness.history.debugAttemptedFullResetWithDirtyEntry)
    }

    @Test
    @MainActor
    func eraserTopologyFenceKeepsUndoRedoChainCorrect() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let firstLayerID = harness.workspaceStore.state.document.layers[0].id
        let secondLayerID = harness.addLayer()

        try harness.drawStroke(
            tool: .brush,
            layerID: firstLayerID,
            points: [
                .init(x: 10, y: 10, pressure: 1),
                .init(x: 18, y: 18, pressure: 1)
            ]
        )
        try harness.drawStroke(
            tool: .brush,
            layerID: secondLayerID,
            points: [
                .init(x: 42, y: 42, pressure: 1),
                .init(x: 52, y: 52, pressure: 1)
            ]
        )
        try harness.drawStroke(
            tool: .eraser,
            useDirtyHistory: true,
            layerID: firstLayerID,
            points: [
                .init(x: 10, y: 10, pressure: 1),
                .init(x: 18, y: 18, pressure: 1)
            ]
        )
        try harness.history.captureCheckpoint()
        let thirdLayerID = harness.addLayer()

        #expect(try harness.history.undo())
        #expect(harness.workspaceStore.state.document.layers.count == 3)
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) < 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)

        #expect(try harness.history.undo())
        #expect(harness.workspaceStore.state.document.layers.count == 3)
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) > 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)

        #expect(try harness.history.redo())
        #expect(harness.workspaceStore.state.document.layers.count == 3)
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) < 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)

        #expect(try harness.history.redo())
        #expect(harness.workspaceStore.state.document.layers.count == 4)
        #expect(try harness.alpha(atX: 12, y: 12, layerID: firstLayerID) < 0.01)
        #expect(try harness.alpha(atX: 46, y: 46, layerID: secondLayerID) > 0.01)
        #expect(try harness.alpha(atX: 12, y: 12, layerID: thirdLayerID) < 0.01)
        #expect(!harness.history.debugAttemptedFullResetWithDirtyEntry)
    }

    @Test
    @MainActor
    func dirtyRestoreTopologyMismatchLeavesWorkspaceAndStacksUnchanged() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 64, height: 64))
        let secondLayerID = harness.addLayer()

        try harness.drawBrushStroke(
            useDirtyBrushHistory: true,
            layerID: secondLayerID,
            points: [
                .init(x: 36, y: 36, pressure: 1),
                .init(x: 44, y: 44, pressure: 1)
            ]
        )

        let undoCountBefore = harness.history.debugUndoCount
        let redoCountBefore = harness.history.debugRedoCount

        harness.workspaceStore.updateDocument { document in
            _ = document.addLayer()
        }
        harness.layerSurfaceStore.prepareTextures(for: harness.workspaceStore.state.document, metal: harness.metalContext)
        let workspaceAfterTopologyChange = harness.workspaceStore.state

        do {
            _ = try harness.history.undo()
            Issue.record("Expected dirty restore topology mismatch to throw")
        } catch {
        }

        #expect(harness.history.debugUndoCount == undoCountBefore)
        #expect(harness.history.debugRedoCount == redoCountBefore)
        #expect(harness.workspaceStore.state == workspaceAfterTopologyChange)
        #expect(try harness.alpha(atX: 40, y: 40, layerID: secondLayerID) > 0.01)
    }

    @Test
    @MainActor
    func dirtyEraserUndoCapturePushesSymmetricDirtyEntryOntoRedoStack() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 64, height: 64))
        _ = harness.workspaceStore.state.document.activeLayerID
        let layerID = harness.addLayer()

        try harness.drawStroke(
            tool: .brush,
            layerID: layerID,
            points: [
                .init(x: 12, y: 12, pressure: 1),
                .init(x: 20, y: 20, pressure: 1)
            ]
        )
        try harness.drawStroke(
            tool: .eraser,
            useDirtyHistory: true,
            layerID: layerID,
            points: [
                .init(x: 12, y: 12, pressure: 1),
                .init(x: 20, y: 20, pressure: 1)
            ]
        )

        #expect(try harness.history.undo())
        let redoMode = try #require(harness.history.debugRedoEntryModes.last)
        switch redoMode {
        case .full:
            Issue.record("Expected symmetric dirty current-entry capture for eraser in redo stack")
        case .inPlaceChangedLayers(_, let changedLayerIDs):
            #expect(Set(changedLayerIDs) == [layerID])
        case .workspaceOnly, .metadataOnly:
            Issue.record("Eraser stroke should not produce workspace-only history entries")
        }
    }

    @Test
    @MainActor
    func memoryPressureKeepsNewestRedoRestorePoint() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 16, height: 16))
        let layerID = harness.workspaceStore.state.document.activeLayerID
        try harness.history.captureCheckpoint(
            captureMode: .inPlaceChangedLayers([layerID])
        )
        try harness.writeOpaquePixel(layerID: layerID, x: 4, y: 4, value: 210)

        #expect(try harness.history.undo())
        #expect(harness.history.canRedo)
        harness.history.relieveMemoryPressure(critical: true)
        #expect(harness.history.canRedo)
        #expect(try harness.history.redo())
        #expect(try harness.alpha(atX: 4, y: 4, layerID: layerID) > 0.99)
    }

    @Test
    @MainActor
    func checkpointFailsInsteadOfRecordingMissingLayerPixels() throws {
        let harness = try BrushHistoryHarness(canvasSize: .init(width: 16, height: 16))
        let undoCount = harness.history.debugUndoCount
        let layerID = harness.workspaceStore.state.document.activeLayerID
        harness.layerSurfaceStore.debugRemoveContentTexture(for: layerID)
        harness.layerSurfaceStore.debugPreventsTextureAllocation = true

        #expect(throws: Error.self) {
            try harness.history.captureCheckpoint()
        }
        harness.layerSurfaceStore.debugPreventsTextureAllocation = false
        #expect(harness.history.debugUndoCount == undoCount)
    }
}

private enum BrushHistoryHarnessError: Error {
    case metalUnavailable
    case commandBufferUnavailable
    case textureUnavailable
}

@MainActor
private struct BrushHistoryHarness {
    let workspaceStore: WorkspaceStore
    let metalContext: MetalDeviceContext
    let layerSurfaceStore: StageOneLayerSurfaceStore
    let serializer: LayerTextureSerializer
    let history: HistoryController
    let engine: MetalStrokeEngine

    init(canvasSize: CanvasSize, startsWithSingleLayer: Bool = false) throws {
        guard let metalContext = MetalDeviceContext() else {
            throw BrushHistoryHarnessError.metalUnavailable
        }

        var workspaceState = WorkspaceState.stageOneDefault
        if startsWithSingleLayer {
            let backgroundLayer = LayerRecord.stageOneDefault()
            workspaceState.document = ArtDocument(
                metadata: workspaceState.document.metadata,
                canvasSize: workspaceState.document.canvasSize,
                colorStandard: workspaceState.document.colorStandard,
                layers: [backgroundLayer],
                activeLayerID: backgroundLayer.id
            )
        }
        workspaceState.document.canvasSize = canvasSize
        workspaceState.document.metadata.updatedAt = Date()

        let workspaceStore = WorkspaceStore(state: workspaceState)
        let layerSurfaceStore = StageOneLayerSurfaceStore()
        layerSurfaceStore.prepareTextures(for: workspaceState.document, metal: metalContext)

        let serializer = LayerTextureSerializer(metalContext: metalContext)
        let history = HistoryController(
            workspaceStore: workspaceStore,
            layerSurfaceStore: layerSurfaceStore,
            serializer: serializer,
            metalContext: metalContext
        )
        let engine = try MetalStrokeEngine(
            metalContext: metalContext,
            layerSurfaceStore: layerSurfaceStore
        )

        self.workspaceStore = workspaceStore
        self.metalContext = metalContext
        self.layerSurfaceStore = layerSurfaceStore
        self.serializer = serializer
        self.history = history
        self.engine = engine
    }

    func addLayer() -> LayerID {
        workspaceStore.updateDocument { document in
            _ = document.addLayer()
        }
        layerSurfaceStore.prepareTextures(for: workspaceStore.state.document, metal: metalContext)
        return workspaceStore.state.document.activeLayerID
    }

    func drawBrushStroke(
        history: HistoryController? = nil,
        useDirtyBrushHistory: Bool = false,
        layerID: LayerID,
        points: [StrokePoint]
    ) throws {
        try drawStroke(
            history: history,
            tool: .brush,
            useDirtyHistory: useDirtyBrushHistory,
            layerID: layerID,
            points: points
        )
    }

    func drawStroke(
        history: HistoryController? = nil,
        tool: ToolKind,
        useDirtyHistory: Bool = false,
        layerID: LayerID,
        points: [StrokePoint]
    ) throws {
        engine.beginStrokeIfNeeded(
            toolSession: .stageOneDefault,
            layerID: layerID
        )
        _ = engine.applyStroke(
            StrokeDescriptor(
                tool: tool,
                color: .black,
                brush: .stageOneDefault,
                points: points,
                selectionShape: nil,
                skipLeadingStamp: false
            ),
            to: layerID
        )
        engine.endStroke()

        guard let commandBuffer = metalContext.commandQueue.makeCommandBuffer() else {
            throw BrushHistoryHarnessError.commandBufferUnavailable
        }
        _ = engine.flushPendingStrokePackets(into: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let historyController = history ?? self.history
        try engine.drainPendingBrushCommitJobs { job in
            let captureMode: HistoryCaptureMode
            if useDirtyHistory, job.packets.last?.tool == .brush || job.packets.last?.tool == .eraser {
                captureMode = .inPlaceChangedLayers([job.layerID])
            } else {
                captureMode = .full
            }
            try historyController.captureCheckpoint(captureMode: captureMode)
        }
    }

    func alpha(
        atX x: Int,
        y: Int,
        layerID: LayerID
    ) throws -> Float {
        guard
            let surfaceID = layerSurfaceStore.surfaceID(for: layerID),
            let texture = layerSurfaceStore.texture(for: surfaceID)
        else {
            throw BrushHistoryHarnessError.textureUnavailable
        }
        return try serializer.samplePixel(texture: texture, x: x, y: y).alpha
    }

    func writeOpaquePixel(layerID: LayerID, x: Int, y: Int, value: UInt8) throws {
        guard
            let surfaceID = layerSurfaceStore.surfaceID(for: layerID),
            let texture = layerSurfaceStore.texture(for: surfaceID)
        else {
            throw BrushHistoryHarnessError.textureUnavailable
        }
        let width = workspaceStore.state.document.canvasSize.width
        let height = workspaceStore.state.document.canvasSize.height
        var pixels = Data(repeating: 0, count: width * height * 4)
        let offset = (y * width + x) * 4
        pixels[offset] = value
        pixels[offset + 1] = value
        pixels[offset + 2] = value
        pixels[offset + 3] = 255
        try serializer.restore(
            snapshot: LayerTextureSnapshot(
                width: width,
                height: height,
                bytesPerRow: width * 4,
                pixelData: pixels
            ),
            into: texture
        )
    }
}

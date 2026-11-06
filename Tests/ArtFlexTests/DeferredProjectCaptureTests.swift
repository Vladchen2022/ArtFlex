import Foundation
@preconcurrency import Metal
import Testing
@testable import ArtFlex

@MainActor
struct DeferredProjectCaptureTests {
    @Test func cpuReservationFollowsThePayloadUntilItsConsumerReleasesIt() throws {
        var state = WorkspaceState.stageOneDefault
        state.document.canvasSize = .init(width: 16, height: 16)
        let bootstrap = try AppBootstrap(workspaceStore: .init(state: state))
        _ = WorkspaceViewModel(bootstrap: bootstrap, installsZoomKeyboardMonitor: false)
        let budget = bootstrap.metalContext.workingResourceBudget
        #expect(budget.reservedBytes == 0)
        var payload: ProjectArchivePayload? = try bootstrap.persistenceController.captureProjectPayload()
        #expect(payload?.package.layerSnapshots.isEmpty == false)
        #expect(budget.reservedBytes > 0)
        payload = nil
        #expect(budget.reservedBytes == 0)
    }

    @Test func projectFreezeSharesSparseResourcesAndLaterWritesDetach() throws {
        let metal = try #require(MetalDeviceContext())
        guard SparseLayerTexture.isSupported(by: metal.device) else { return }
        var state = WorkspaceState.stageOneDefault; state.document.canvasSize = .init(width: 4096, height: 4096)
        let workspace = WorkspaceStore(state: state), surfaces = StageOneLayerSurfaceStore(usesSparseStorage: true)
        try surfaces.requireTextures(for: state.document, metal: metal)
        let serializer = LayerTextureSerializer(metalContext: metal)
        let controller = PersistenceController(workspaceStore: workspace, layerSurfaceStore: surfaces, serializer: serializer)
        let id = state.document.activeLayerID, surface = try #require(surfaces.surfaceID(for: id))
        let first = try #require(surfaces.writableTexture(for: surface, region: .init(originX: 0, originY: 0, width: 2, height: 2)))
        let patch = LayerTextureSnapshot(width: 2, height: 2, bytesPerRow: 8, pixelData: Data(repeating: 255, count: 16))
        try serializer.restore(snapshot: patch, into: first)
        let frozen = try controller.enqueueProjectCapture().waitUntilReady()
        let saved = try #require(frozen.layerResources.first { $0.layer.id == id }?.texture)
        #expect(saved === first)
        #expect(frozen.pinnedResources.reduce(0) { $0 + $1.allocatedBytes } < 4096 * 4096 * 4 / 10)
        let next = try #require(surfaces.writableTexture(for: surface, region: .init(originX: 0, originY: 0, width: 2, height: 2)))
        #expect(next !== saved)
        try serializer.restore(snapshot: .init(width: 2, height: 2, bytesPerRow: 8, pixelData: Data(repeating: 0, count: 16)), into: next)
        #expect(try serializer.snapshot(texture: saved, originX: 0, originY: 0, width: 2, height: 2) == patch)
        #expect(surfaces.allocatedPixelBytes < 4096 * 4096 * 4 / 10)
    }

    @Test func streamingCompressionRoundTripsEmptyAndMultipleLargeChunks() throws {
        for count in [0, 1, 131_077, 3_000_001] {
            let data = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ ($0 / 251)) })
            let compressed = try ZlibCodec.compressStreaming { consume in
                for offset in stride(from: 0, to: data.count, by: 17_003) {
                    try consume(data.subdata(in: offset..<min(data.count, offset + 17_003)))
                }
            }
            #expect(try ZlibCodec.decompress(compressed, expectedSize: count) == data)
        }
    }

    @Test func stripEncodedArchiveKeepsEveryPixelAndItsExistingFormat() throws {
        for standard in [ArtColorStandard.stageOneDefault, .highPrecision] {
            var state = WorkspaceState.stageOneDefault
            state.document.canvasSize = .init(width: 1234, height: 613); state.document.colorStandard = standard
            let workspace = WorkspaceStore(state: state), metal = try #require(MetalDeviceContext())
            let surfaces = StageOneLayerSurfaceStore(), serializer = LayerTextureSerializer(metalContext: metal)
            try surfaces.requireTextures(for: state.document, metal: metal)
            let id = state.document.activeLayerID, surface = try #require(surfaces.surfaceID(for: id))
            #expect(surfaces.fillContentTexture(for: id, value: 0.5, metal: metal))
            let original = try serializer.snapshot(texture: #require(surfaces.readTexture(for: surface)))
            let controller = PersistenceController(workspaceStore: workspace, layerSurfaceStore: surfaces, serializer: serializer)
            let frozen = try controller.enqueueProjectCapture().waitUntilReady()
            let payload = try controller.materializeProjectPayload(from: frozen, reuseEncodedLayers: true)
            let encoded = try #require(payload.encodedLayerResources.first { $0.key.layerID == id })
            #expect(try encoded.materialized().texture == original)
            #expect(encoded.uncompressedByteCount == original.pixelData.count)
            #expect(payload.package.layerSnapshots.allSatisfy { $0.texture.pixelData.isEmpty })
        }
    }

    @Test func privateCaptureReturnsBeforeGPUCompletionAndPreservesQueueOrder() throws {
        let metal = try #require(MetalDeviceContext())
        let serializer = LayerTextureSerializer(metalContext: metal)
        let store = StageOneLayerSurfaceStore()
        for format in [MTLPixelFormat.bgra8Unorm_srgb, .rgba16Float, .r8Unorm] {
            let texture = try #require(store.makeTexture(width: 16, height: 16, pixelFormat: format, metal: metal))
            try clear(texture, red: 0.25, metal: metal).waitUntilCompleted()
            let before = try serializer.snapshot(texture: texture)
            let event = try #require(metal.device.makeSharedEvent())
            let gate = try #require(metal.commandQueue.makeCommandBuffer())
            gate.encodeWaitForEvent(event, value: 1)
            gate.commit()
            // Prevent a regression from leaving the test GPU queue blocked indefinitely.
            let release = DispatchWorkItem { event.signaledValue = 1 }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: release)
            defer { event.signaledValue = 1; release.cancel() }
            let pending = try serializer.enqueueCloneBatchForDeferredSnapshot(textures: [texture])
            #expect(event.signaledValue == 0, "Submitting a private copy must not wait for GPU completion")
            let laterWrite = try clear(texture, red: 0.75, metal: metal)
            event.signaledValue = 1
            let frozen = try #require(pending.waitUntilReady().first)
            laterWrite.waitUntilCompleted()
            #expect(try serializer.snapshot(texture: frozen) == before)
            #expect(try serializer.snapshot(texture: texture) != before)
        }
    }

    @Test func sharedSourceIsFrozenBeforeCPUCanOverwriteIt() throws {
        let metal = try #require(MetalDeviceContext())
        let store = StageOneLayerSurfaceStore()
        let serializer = LayerTextureSerializer(metalContext: metal)
        let texture = try #require(store.makeTexture(width: 4, height: 4, storageMode: .shared, metal: metal))
        var before = [UInt8](repeating: 63, count: 64)
        before.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 16) }
        let pending = try serializer.enqueueCloneBatchForDeferredSnapshot(textures: [texture])
        before = [UInt8](repeating: 127, count: 64)
        before.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 16) }
        let frozen = try #require(pending.waitUntilReady().first)
        #expect(try serializer.snapshot(texture: frozen).pixelData == Data(repeating: 63, count: 64))
    }

    @Test func queuedCaptureRetainsSparseSourcesWhenLiveStoreIsReplaced() throws {
        let metal = try #require(MetalDeviceContext())
        guard SparseLayerTexture.isSupported(by: metal.device) else { return }
        for standard in [ArtColorStandard.stageOneDefault, .highPrecision] {
            let workspace = WorkspaceStore()
            workspace.updateDocument { $0.canvasSize = .init(width: 1024, height: 1024); $0.colorStandard = standard }
            let surfaces = StageOneLayerSurfaceStore(usesSparseStorage: true)
            surfaces.prepareTextures(for: workspace.state.document, metal: metal)
            let serializer = LayerTextureSerializer(metalContext: metal)
            let controller = PersistenceController(workspaceStore: workspace, layerSurfaceStore: surfaces, serializer: serializer,
                recoveryRootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
            let surfaceID = try #require(surfaces.surfaceID(for: workspace.state.document.activeLayerID))
            let writable = try #require(surfaces.writableTexture(for: surfaceID,
                region: .init(originX: 0, originY: 0, width: 2, height: 2)))
            try serializer.restore(snapshot: .init(width: 2, height: 2, bytesPerRow: 8,
                pixelData: Data([0, 0, 127, 255, 0, 0, 127, 255, 0, 0, 127, 255, 0, 0, 127, 255])), into: writable)
            let expected = try controller.captureProjectPayload().package.layerSnapshots
            let event = try #require(metal.device.makeSharedEvent())
            let gate = try #require(metal.commandQueue.makeCommandBuffer())
            gate.encodeWaitForEvent(event, value: 1); gate.commit()
            let release = DispatchWorkItem { event.signaledValue = 1 }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: release)
            defer { event.signaledValue = 1; release.cancel() }
            let pending = try controller.enqueueProjectCapture()
            #expect(event.signaledValue == 0)
            surfaces.reset()
            event.signaledValue = 1
            let payload = try controller.materializeProjectPayload(from: pending.waitUntilReady())
            #expect(payload.package.layerSnapshots.count == workspace.state.document.paintLayers.count)
            #expect(payload.package.layerSnapshots == expected)
            for snapshot in payload.package.layerSnapshots {
                #expect(snapshot.texture.encoding == standard.pixelFormat.encoding)
            }
        }
    }

    private func clear(_ texture: MTLTexture, red: Double, metal: MetalDeviceContext) throws -> MTLCommandBuffer {
        let command = try #require(metal.commandQueue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = .init(red: red, green: 0, blue: 0, alpha: 1)
        let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass))
        encoder.endEncoding(); command.commit()
        return command
    }
}

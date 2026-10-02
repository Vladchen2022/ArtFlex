import Foundation
@preconcurrency import Metal
import Testing
@testable import ArtFlex

@MainActor
struct DeferredProjectCaptureTests {
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

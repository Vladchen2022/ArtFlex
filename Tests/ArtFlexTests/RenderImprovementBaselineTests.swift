import Foundation
@preconcurrency import Metal
import Testing
@testable import ArtFlex

/// Run serially with ARTFLEX_RUN_RENDER_BASELINE=1. Records actual current paths;
/// these are CPU/GPU work durations, not input-to-display latency.
@MainActor
struct RenderImprovementBaselineTests {
    @Test func currentTransformCompositionAndBlockRendering() async throws {
        guard ProcessInfo.processInfo.environment["ARTFLEX_RUN_RENDER_BASELINE"] == "1" else { return }
        let metal = try #require(MetalDeviceContext())
        let serializer = LayerTextureSerializer(metalContext: metal)
        let store = StageOneLayerSurfaceStore()
        func finish(_ command: MTLCommandBuffer) {
            command.commit()
            command.waitUntilCompleted()
            #expect(command.status == .completed)
        }
        func solid(_ side: Int, _ bgra: [UInt8]) throws -> MTLTexture {
            let texture = try #require(store.makeTexture(width: side, height: side, metal: metal))
            try serializer.restore(snapshot: .init(width: side, height: side, bytesPerRow: side * 4,
                pixelData: Data(Array(repeating: bgra, count: side * side).flatMap { $0 })), into: texture)
            return texture
        }
        let source = try solid(8, [0, 0, 255, 255])
        let mask = try #require(store.makeTexture(width: 2, height: 2, pixelFormat: .r8Unorm,
            storageMode: .shared, metal: metal))
        let maskBytes: [UInt8] = [64, 128, 192, 255]
        mask.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0, withBytes: maskBytes, bytesPerRow: 2)
        let compositor = try TransformGPUCompositor(device: metal.device)
        var pair: (MTLTexture?, MTLTexture?) = (nil, nil)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            compositor.buildSelectionTextures(sourceTexture: source, canvasSize: .init(width: 8, height: 8),
                sourceBounds: .init(origin: .init(x: 2, y: 2), size: .init(x: 2, y: 2)),
                maskTexture: mask, metal: metal) { base, extracted in
                pair = (base, extracted)
                continuation.resume()
            }
        }
        let base = try #require(pair.0)
        let extracted = try #require(pair.1)
        let baseAlpha = try serializer.samplePixel(texture: base, x: 2, y: 2).alpha
        let extractedAlpha = try serializer.samplePixel(texture: extracted, x: 0, y: 0).alpha
        print("RENDER_BASELINE soft-mask-64 base-alpha=\(baseAlpha) extracted-alpha=\(extractedAlpha)")

        let side = 512
        let target = try solid(side, [0, 0, 0, 0])
        let presenter = try StageOneCanvasPresenter(device: metal.device)
        let disablesCaches = ProcessInfo.processInfo.environment["ARTFLEX_DISABLE_RENDER_CACHES"] == "1"
        let prefixVersion = LayerChangeJournal().cursor
        let layers = try (0..<20).map { index in
            CanvasLayerCompositeInput(texture: try solid(side, [UInt8(index * 7), 30, 60, 128]),
                opacity: 0.8, blendMode: index == 4 ? .multiply : .normal)
        }
        var compositionCPU: [Double] = []
        var compositionGPU: [Double] = []
        for _ in 0..<8 {
            let command = try #require(metal.commandQueue.makeCommandBuffer())
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            let start = DispatchTime.now().uptimeNanoseconds
            #expect(presenter.encode(layerInputs: layers,
                cacheHint: disablesCaches ? nil : .init(count: 18, revisionTokens: [prefixVersion]),
                into: pass, commandBuffer: command))
            compositionCPU.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            finish(command)
            compositionGPU.append((command.gpuEndTime - command.gpuStartTime) * 1_000)
        }
        print("RENDER_BASELINE 20-layers-512 CPU-ms=\(compositionCPU) GPU-ms=\(compositionGPU)")
        print("RENDER_CACHE prefix-builds=\(presenter.debugPrefixCacheBuilds) hits=\(presenter.debugPrefixCacheHits)")

        let renderer = try BlockReferenceMetalSolidRenderer(context: metal)
        renderer.debugDisablesRenderCaches = disablesCaches
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
            width: side, height: side, mipmapped: false)
        depthDescriptor.storageMode = .private
        depthDescriptor.usage = .renderTarget
        let depth = try #require(metal.device.makeTexture(descriptor: depthDescriptor))
        var scene = BlockReferenceScene.empty
        scene.objects = (0..<100).map { index in
            var object = BlockReferenceObject(name: "Baseline \(index)", kind: index % 5 == 0 ? .cylinder : .box,
                position: .init(x: Double(index % 10) * 140, y: Double(index / 10) * 140, z: 0),
                dimensions: .stageOneDefault)
            object.radialSegments = 24
            return object
        }
        let transform = CanvasViewportTransform(canvasSize: .init(width: side, height: side),
            viewport: .stageOneDefault, availableWidth: Double(side), availableHeight: Double(side), padding: 0)
        var unchangedCPU: [Double] = []
        var editedCPU: [Double] = []
        var orbitCPU: [Double] = []
        for frame in 0..<24 {
            if (8..<16).contains(frame) { scene.objects[0].position.x += 1 }
            if frame >= 16 { scene.camera.yawDegrees += 1 }
            let command = try #require(metal.commandQueue.makeCommandBuffer())
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.depthAttachment.texture = depth
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.storeAction = .dontCare
            pass.depthAttachment.clearDepth = 1
            let start = DispatchTime.now().uptimeNanoseconds
            #expect(renderer.encode(scene: scene, editorState: .init(), selectedObjectIDs: [], transform: transform,
                viewportSize: CGSize(width: side, height: side), into: pass, commandBuffer: command))
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            if frame < 8 { unchangedCPU.append(elapsed) }
            else if frame < 16 { editedCPU.append(elapsed) }
            else { orbitCPU.append(elapsed) }
            finish(command)
        }
        print("RENDER_BASELINE 100-blocks unchanged-CPU-ms=\(unchangedCPU) one-edited-CPU-ms=\(editedCPU) orbit-CPU-ms=\(orbitCPU)")
        print("RENDER_CACHE blocks=\(renderer.cacheStatistics)")
    }
}

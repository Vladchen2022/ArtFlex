import Darwin
import Foundation
import Metal
import Testing
@testable import ArtFlex

/// Opt-in, bounded measurements. Run this suite alone; ru_maxrss is a process lifetime peak.
@MainActor
struct SaveCapturePerformanceTests {
    @Test func boundedFreezeSamples() throws {
        guard ProcessInfo.processInfo.environment["ARTFLEX_RUN_SAVE_CAPTURE_BENCHMARK"] == "1" else { return }
        let metal = try #require(MetalDeviceContext())
        print("SAVE_BENCH device=\(metal.device.name) os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        for side in [2048, 4096] {
            for format in [MTLPixelFormat.bgra8Unorm_srgb, .rgba16Float] {
                try autoreleasepool {
                    let audit = PerformanceAuditStore()
                    let serializer = LayerTextureSerializer(metalContext: metal, auditStore: audit)
                    let store = StageOneLayerSurfaceStore()
                    let sources = try ([format, format, format, format, .r8Unorm]).map { format in
                        let texture = try #require(store.makeTexture(width: side, height: side, pixelFormat: format, metal: metal))
                        let command = try #require(metal.commandQueue.makeCommandBuffer())
                        let pass = MTLRenderPassDescriptor()
                        pass.colorAttachments[0].texture = texture
                        pass.colorAttachments[0].loadAction = .clear
                        pass.colorAttachments[0].storeAction = .store
                        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1)
                        let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass))
                        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
                        #expect(command.status == .completed)
                        return texture
                    }
                    for sample in 0..<6 {
                        for mode in (sample % 2 == 0 ? ["sync", "deferred"] : ["deferred", "sync"]) {
                        try autoreleasepool {
                            audit.reset()
                            let start = DispatchTime.now().uptimeNanoseconds
                            let frozen: [MTLTexture]
                            let entryMs: Double
                            if mode == "deferred" {
                                let pending = try serializer.enqueueCloneBatchForDeferredSnapshot(textures: sources)
                                entryMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                                frozen = try pending.waitUntilReady()
                            } else {
                                frozen = try serializer.cloneBatchForDeferredSnapshot(textures: sources)
                                entryMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                            }
                            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                            let measured = audit.snapshot()
                            var usage = rusage()
                            getrusage(RUSAGE_SELF, &usage)
                            print("SAVE_BENCH side=\(side) format=\(format.rawValue) sample=\(sample) mode=\(mode) entry_ms=\(entryMs) total_ms=\(elapsed) prepare_ms=\(measured.latestDuration("SaveCapture.prepare") ?? -1) wait_ms=\(measured.latestDuration("SaveCapture.wait") ?? -1) gpu_bytes=\(metal.device.currentAllocatedSize) rss_peak_bytes=\(usage.ru_maxrss)")
                            for (source, clone) in zip(sources, frozen) {
                                #expect(try serializer.snapshot(texture: source, originX: 0, originY: 0, width: 1, height: 1)
                                    == serializer.snapshot(texture: clone, originX: 0, originY: 0, width: 1, height: 1))
                            }
                        }
                        }
                    }
                }
            }
        }
    }
}

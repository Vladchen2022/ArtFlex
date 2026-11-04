import Foundation
import Metal
import Testing
@testable import ArtFlex

struct RegionalCompositePerformanceTests {
    @Test func measuredComplexLayerWorkload() throws {
        guard ProcessInfo.processInfo.environment["ARTFLEX_REGIONAL_BENCHMARK"] == "1" else { return }
        let metal = try #require(MetalDeviceContext())
        let serializer = LayerTextureSerializer(metalContext: metal)
        let store = StageOneLayerSurfaceStore()
        for side in [2048, 4096] {
            let source = try #require(store.makeTexture(width: side, height: side, metal: metal))
            try serializer.restore(snapshot: .init(width: side, height: side, bytesPerRow: side * 4,
                pixelData: Data(repeating: 90, count: side * side * 4)), into: source)
            let output = try #require(store.makeTexture(width: side, height: side, metal: metal))
            let expected = try #require(store.makeTexture(width: side, height: side, metal: metal))
            let inputs: [CanvasLayerCompositeInput] = (0..<12).map { index in
                .init(texture: source, opacity: 0.75, blendMode: index.isMultiple(of: 3) ? .multiply : .screen,
                      clipMaskTexture: index.isMultiple(of: 4) ? source : nil,
                      curveAdjustmentLUTs: index == 7 ? .identity : nil)
            }
            let renderer = try StageOneCanvasPresenter(device: metal.device)
            let regionalRenderer = try StageOneCanvasPresenter(device: metal.device)
            let cache = CanvasRegionalComposite()
            let revision = LayerChangeJournal().cursor
            var fullTimes: [Double] = [], regionTimes: [Double] = []
            for iteration in 0..<24 {
                for regional in [false, true] {
                    let command = try #require(metal.commandQueue.makeCommandBuffer())
                    let pass = MTLRenderPassDescriptor()
                    pass.colorAttachments[0].texture = regional ? output : expected
                    pass.colorAttachments[0].loadAction = .clear
                    pass.colorAttachments[0].storeAction = .store
                    pass.colorAttachments[0].clearColor = MTLClearColorMake(1, 1, 1, 1)
                    if regional {
                        #expect(cache.encode(inputs: inputs, revisions: [revision],
                            changedRegion: .init(originX: 400 + iteration * 8, originY: 800, width: 64, height: 64),
                            canvasSize: .init(width: side, height: side), presenter: regionalRenderer,
                            sampling: .linear, into: pass, command: command) == true)
                    } else {
                        #expect(renderer.encode(layerInputs: inputs, into: pass, commandBuffer: command))
                    }
                    command.commit(); command.waitUntilCompleted()
                    #expect(command.status == .completed)
                    if iteration >= 4 {
                        let time = (command.gpuEndTime - command.gpuStartTime) * 1_000
                        if regional { regionTimes.append(time) } else { fullTimes.append(time) }
                    }
                }
            }
            let full = try #require(PerformanceDistribution(fullTimes))
            let partial = try #require(PerformanceDistribution(regionTimes))
            let snapshot = try serializer.snapshot(texture: output)
            #expect(try snapshot == serializer.snapshot(texture: expected))
            print("REGIONAL_BENCH side=\(side) full_median_ms=\(full.median) regional_median_ms=\(partial.median) full_p95_ms=\(full.p95) regional_p95_ms=\(partial.p95) samples=\(partial.count)")
            #expect(cache.partialFrameCount == 23)
        }
    }
}

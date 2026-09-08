import Foundation
import Testing
@testable import ArtFlex

struct SparseStrokeIntegrationTests {
    @Test @MainActor func fourKCanvasMeasuresStorageAndStrokeCommitCost() throws {
        let metal = try #require(MetalDeviceContext())
        guard SparseLayerTexture.isSupported(by: metal.device) else { return }
        var state = WorkspaceState.stageOneDefault
        state.document.canvasSize = .init(width: 4096, height: 4096)
        state.document.layers = [try #require(state.document.layers.last)]
        var results: [(sparse: Bool, ms: Double, bytes: Int, pixel: RGBAColor)] = []
        for sparse in [false, true] {
            let bootstrap = try AppBootstrap(workspaceStore: WorkspaceStore(state: state), metalContext: metal,
                layerSurfaceStore: .init(usesSparseStorage: sparse))
            let vm = WorkspaceViewModel(bootstrap: bootstrap, installsZoomKeyboardMonitor: false)
            vm.setBrushSize(48)
            let start = DispatchTime.now().uptimeNanoseconds
            for n in 0..<8 {
                vm.beginStrokeIfNeeded()
                vm.applyStroke(samples: [.init(location: .init(x: 100, y: Double(200 + n * 60)), pressure: 1),
                    .init(location: .init(x: 600, y: Double(230 + n * 60)), pressure: 0.8)])
                vm.endStroke()
                #expect(vm.flushBrushEditingBoundary(reason: "4k-storage-measurement"))
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            let id = try #require(bootstrap.layerSurfaceStore.surfaceID(for: state.document.activeLayerID))
            let texture = try #require(bootstrap.layerSurfaceStore.readTexture(for: id))
            let pixel = try bootstrap.textureSerializer.samplePixel(texture: texture, x: 200, y: 206)
            results.append((sparse, elapsed, bootstrap.layerSurfaceStore.allocatedPixelBytes, pixel))
        }
        #expect(results[1].bytes < results[0].bytes / 4)
        #expect(results[0].pixel == results[1].pixel)
        for result in results {
            print("ArtFlex4K sparse=\(result.sparse) eightStrokesMs=\(result.ms) committedLayerBytes=\(result.bytes)")
        }
    }

    @Test @MainActor func productionStrokeAndEraseMatchDensePixelsAfterUndoRedo() throws {
        let metal = try #require(MetalDeviceContext())
        guard SparseLayerTexture.isSupported(by: metal.device) else { return }
        var state = WorkspaceState.stageOneDefault
        state.document.canvasSize = .init(width: 1200, height: 1100)
        let sparseBootstrap = try AppBootstrap(workspaceStore: WorkspaceStore(state: state), metalContext: metal,
                                               layerSurfaceStore: StageOneLayerSurfaceStore(usesSparseStorage: true))
        let denseBootstrap = try AppBootstrap(workspaceStore: WorkspaceStore(state: state), metalContext: metal,
                                              layerSurfaceStore: StageOneLayerSurfaceStore())
        let sparse = WorkspaceViewModel(bootstrap: sparseBootstrap, installsZoomKeyboardMonitor: false)
        let dense = WorkspaceViewModel(bootstrap: denseBootstrap, installsZoomKeyboardMonitor: false)
        for vm in [sparse, dense] {
            vm.setBrushSize(32)
            vm.setSelectedColor(.init(red: 0.7, green: 0.2, blue: 0.1, alpha: 1))
            for tool in [ToolKind.brush, .eraser] {
                vm.selectTool(tool)
                vm.beginStrokeIfNeeded()
                vm.applyStroke(samples: [.init(location: .init(x: 100, y: 200), pressure: 1),
                                         .init(location: .init(x: 350, y: 240), pressure: 0.5)])
                vm.endStroke()
                _ = vm.flushBrushEditingBoundary(reason: "sparse-integration")
            }
        }
        func pixels(_ vm: WorkspaceViewModel, _ bootstrap: AppBootstrap) throws -> Data {
            let id = try #require(vm.layerSurfaceStore.surfaceID(for: state.document.activeLayerID))
            let texture = try #require(vm.layerSurfaceStore.readTexture(for: id))
            return try bootstrap.textureSerializer.snapshot(texture: texture).pixelData
        }
        #expect(try pixels(sparse, sparseBootstrap) == pixels(dense, denseBootstrap))
        let id = try #require(sparse.layerSurfaceStore.surfaceID(for: state.document.activeLayerID))
        #expect(sparse.layerSurfaceStore.readTexture(for: id)?.heap?.type == .sparse)
        sparse.undo(); dense.undo()
        #expect(try pixels(sparse, sparseBootstrap) == pixels(dense, denseBootstrap))
        sparse.redo(); dense.redo()
        #expect(try pixels(sparse, sparseBootstrap) == pixels(dense, denseBootstrap))
    }
}

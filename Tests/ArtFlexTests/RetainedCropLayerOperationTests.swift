import Foundation
import Testing
@testable import ArtFlex

struct RetainedCropLayerOperationTests {
    @Test @MainActor func croppedLayerMergeMatchesUncroppedMergeAndUndoInBothPrecisions() throws {
        for format in [ArtPixelFormat.rgba8, .rgba16Float] {
            for visible in [false, true] {
                let a = try makeWorkspace(format: format)
                let b = try makeWorkspace(format: format)
                let vm = a.1
                crop(vm)
                let retained = vm.workspace.document.cropRetention
                if visible { vm.mergeVisibleLayers(); b.1.mergeVisibleLayers() }
                else { vm.mergeActiveLayerDown(); b.1.mergeActiveLayerDown() }
                #expect(vm.workspace.document.paintLayers.count == 1)
                let merged = vm.workspace.document.cropRetention
                vm.undo()
                #expect(vm.workspace.document.cropRetention == retained)
                vm.redo()
                #expect(vm.workspace.document.cropRetention == merged)
                vm.expandRetainedCanvas()
                #expect(try pixels(a.0, vm.workspace.document.activeLayerID) == pixels(b.0, b.1.workspace.document.activeLayerID))
            }
        }
    }

    @Test @MainActor func duplicateDeleteAndMasksRetainOutsidePixels() throws {
        let (bootstrap, vm) = try makeWorkspace(format: .rgba16Float)
        let originalID = vm.workspace.document.activeLayerID
        let original = try pixels(bootstrap, originalID)
        crop(vm)
        vm.duplicateActiveLayer()
        let copied = vm.workspace.document.activeLayerID
        #expect(copied != originalID)
        #expect(vm.workspace.document.cropRetention?.tiles.contains { $0.key.layerID == copied } == true)
        vm.expandRetainedCanvas()
        #expect(try pixels(bootstrap, copied) == original)
        vm.undo()
        vm.removeActiveLayer()
        #expect(vm.workspace.document.cropRetention?.tiles.contains { $0.key.layerID == copied } == false)
        vm.selectLayer(originalID)
        vm.deleteActiveLayerMask()
        #expect(vm.workspace.document.cropRetention?.tiles.contains { $0.key == .init(layerID: originalID, kind: .mask) } == false)
        vm.addMaskToActiveLayer(revealsAll: false)
        vm.selectTool(.canvasCrop)
        vm.expandRetainedCanvas()
        let mask = try #require(bootstrap.layerSurfaceStore.readMaskTexture(for: originalID))
        #expect(try bootstrap.textureSerializer.snapshot(texture: mask).pixelData.allSatisfy { $0 == 0 })
        vm.undo()
        vm.invertActiveLayerMask()
        vm.selectTool(.canvasCrop)
        vm.expandRetainedCanvas()
        let white = try #require(bootstrap.layerSurfaceStore.readMaskTexture(for: originalID))
        #expect(try bootstrap.textureSerializer.snapshot(texture: white).pixelData.allSatisfy { $0 == 255 })
    }

    @MainActor private func makeWorkspace(format: ArtPixelFormat) throws -> (AppBootstrap, WorkspaceViewModel) {
        var state = WorkspaceState.stageOneDefault
        state.document.canvasSize = .init(width: 32, height: 32)
        state.document.colorStandard = format == .rgba16Float ? .highPrecision : .stageOneDefault
        state.document.layers[1].mask = .init()
        state.document.layers[1].opacity = 0.57
        state.document.layers[1].blendMode = .multiply
        let bootstrap = try AppBootstrap(workspaceStore: WorkspaceStore(state: state))
        let vm = WorkspaceViewModel(bootstrap: bootstrap, installsZoomKeyboardMonitor: false)
        let encoding = format.encoding
        for (index, layer) in state.document.paintLayers.enumerated() {
            let id = try #require(bootstrap.layerSurfaceStore.surfaceID(for: layer.id))
            let texture = try #require(bootstrap.layerSurfaceStore.texture(for: id))
            var data = Data(count: 32 * 32 * encoding.bytesPerPixel)
            data.withUnsafeMutableBytes { output in
                for i in 0..<1024 {
                    CanvasPixelCodec.write(.init(red: index == 0 ? 0.1531 : 0.3537,
                        green: Float(i % 32) / 100, blue: 0.1223, alpha: index == 0 ? 1 : 0.7),
                        into: output, offset: i * encoding.bytesPerPixel, encoding: encoding)
                }
            }
            try bootstrap.textureSerializer.restore(snapshot: .init(width: 32, height: 32,
                bytesPerRow: 32 * encoding.bytesPerPixel, pixelData: data, encoding: encoding), into: texture)
        }
        bootstrap.layerSurfaceStore.fillMaskTexture(for: state.document.activeLayerID, value: 0.7, metal: bootstrap.metalContext)
        return (bootstrap, vm)
    }

    @MainActor private func crop(_ vm: WorkspaceViewModel) {
        vm.selectTool(.canvasCrop)
        vm.beginCanvasCrop(at: .init(x: 8, y: 8), handleRadius: 1)
        vm.endCanvasCrop(at: .init(x: 24, y: 24))
        vm.applyCanvasCrop()
        #expect(vm.workspace.document.canvasSize == .init(width: 16, height: 16))
    }

    private func pixels(_ bootstrap: AppBootstrap, _ layerID: LayerID) throws -> LayerTextureSnapshot {
        let id = try #require(bootstrap.layerSurfaceStore.surfaceID(for: layerID))
        return try bootstrap.textureSerializer.snapshot(texture: #require(bootstrap.layerSurfaceStore.readTexture(for: id)))
    }
}

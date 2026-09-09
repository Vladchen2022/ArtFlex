import Foundation
import Metal
import Testing
@testable import ArtFlex

@MainActor
struct BlockReferencePaintingPlacementTests {
    @Test func legacyDocumentsKeepReferenceInFront() throws {
        var display = BlockReferenceDisplaySettings.stageOneDefault
        display.isFrozen = true
        display.paintingPlacement = .behindPainting
        let data = try JSONEncoder().encode(display)
        #expect(try JSONDecoder().decode(BlockReferenceDisplaySettings.self, from: data) == display)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "paintingPlacement")
        let restored = try JSONDecoder().decode(BlockReferenceDisplaySettings.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        #expect(restored.paintingPlacement == .inFront)
        #expect(!restored.drawsBehindPainting(activeTool: .brush))
        #expect(display.drawsBehindPainting(activeTool: .brush))
        #expect(display.drawsBehindPainting(activeTool: .eraser))
        #expect(!display.drawsBehindPainting(activeTool: .blockReference))
        display.isVisible = false
        #expect(!display.drawsBehindPainting(activeTool: .brush))
    }

    @Test func lockedReferencePlacementIsUndoableAndPersistsWithoutMovingObjects() throws {
        let vm = WorkspaceViewModel(bootstrap: try AppBootstrap(), installsZoomKeyboardMonitor: false,
                                    preparesInitialTextures: false)
        vm.createEmptyBlockReferenceScene()
        _ = vm.updateBlockReferenceDocument {
            $0?.objects = [.init(name: "方块", kind: .box, position: .zero, dimensions: .stageOneDefault)]
        }
        vm.freezeBlockReferenceAndSelectBrush()
        let original = try #require(vm.blockReferenceScene)
        vm.setBlockReferencePaintingPlacement(.behindPainting)
        let changed = try #require(vm.blockReferenceScene)
        #expect(changed.display.isFrozen)
        #expect(changed.objects == original.objects)
        #expect(changed.camera == original.camera)
        #expect(changed.display.paintingPlacement == .behindPainting)
        #expect(vm.hasUnsavedChanges)
        let restored = try JSONDecoder().decode(ArtDocument.self, from: JSONEncoder().encode(vm.workspace.document))
        #expect(restored.blockReferenceScene == changed)
        vm.undo()
        #expect(vm.blockReferenceScene?.display.paintingPlacement == .inFront)
        vm.redo()
        #expect(vm.blockReferenceScene?.display.paintingPlacement == .behindPainting)
        vm.saveBlockReferenceSceneSnapshot()
        let snapshot = try #require(vm.blockReferenceScene?.snapshots.first)
        vm.setBlockReferencePaintingPlacement(.inFront)
        vm.restoreBlockReferenceSceneSnapshot(snapshot.id)
        #expect(vm.blockReferenceScene?.display.paintingPlacement == .behindPainting)
    }

    @Test func referenceSitsAbovePaperButBelowOrdinaryPaintAndImages() {
        var document = ArtDocument.stageOneDefault()
        let ids = document.drawablePaintLayers.map(\.id)
        #expect(BlockReferencePaintingPlan.insertionIndex(document: document, visibleLayerIDs: ids) == 1)
        #expect(BlockReferencePaintingPlan.insertionIndex(document: document, visibleLayerIDs: [ids[1]]) == 0)
        #expect(BlockReferencePaintingPlan.insertionIndex(document: document, visibleLayerIDs: ids.reversed()) == 0)
        document.layers[0].name = "导入的图片"
        #expect(BlockReferencePaintingPlan.insertionIndex(document: document, visibleLayerIDs: ids) == 0)
        #expect(BlockReferencePaintingPlan.insertionIndex(document: document, visibleLayerIDs: []) == 0)
    }

    @Test func metalUnderlayPreservesOpaqueAndTranslucentPaintAndStaysOutOfDocumentPixels() throws {
        let metal = try #require(MetalDeviceContext())
        let renderer = try BlockReferenceCanvasUnderlay(context: metal)
        let presenter = try StageOneCanvasPresenter(device: metal.device)
        let serializer = LayerTextureSerializer(metalContext: metal)
        let store = StageOneLayerSurfaceStore()
        let size = CanvasSize(width: 128, height: 128)
        var scene = BlockReferenceScene.empty
        scene.objects = [.init(name: "测试体块", kind: .box, position: .zero,
                              dimensions: .stageOneDefault)]
        scene.display.isFrozen = true
        scene.display.paintingPlacement = .behindPainting
        scene.display.paintingOpacity = 0.7
        let command = try #require(metal.commandQueue.makeCommandBuffer())
        let reference = try #require(renderer.texture(scene: scene, canvasSize: size, width: 128, height: 128,
            viewportSize: CGSize(width: 128, height: 128), commandBuffer: command))
        command.commit(); command.waitUntilCompleted()
        #expect(command.status == .completed)
        let referencePixels = try serializer.snapshot(texture: reference)
        let pixelIndex = try #require((0..<(128 * 128)).max {
            referencePixels.pixelData[$0 * 4 + 3] < referencePixels.pixelData[$1 * 4 + 3]
        })
        #expect(referencePixels.pixelData[pixelIndex * 4 + 3] > 0)

        func solid(_ bgra: [UInt8]) throws -> MTLTexture {
            let texture = try #require(store.makeTexture(width: 128, height: 128, metal: metal))
            try serializer.restore(snapshot: .init(width: 128, height: 128, bytesPerRow: 512,
                pixelData: Data(Array(repeating: bgra, count: 128 * 128).flatMap { $0 })), into: texture)
            return texture
        }
        let paper = try solid([255, 255, 255, 255])
        let paint = try solid([0, 0, 255, 255])
        let originalPaint = try serializer.snapshot(texture: paint)
        let output = try solid([0, 0, 0, 0])
        func render(_ inputs: [CanvasLayerCompositeInput]) throws -> LinearPremultipliedColor {
            let command = try #require(metal.commandQueue.makeCommandBuffer())
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = output
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            #expect(presenter.encode(layerInputs: inputs, into: pass, commandBuffer: command))
            command.commit(); command.waitUntilCompleted()
            #expect(command.status == .completed)
            let pixels = try serializer.snapshot(texture: output)
            return pixels.pixelData.withUnsafeBytes {
                CanvasPixelCodec.read($0, offset: pixelIndex * 4, encoding: pixels.encoding)
            }
        }
        let underlay: [CanvasLayerCompositeInput] = [
            .init(texture: paper, opacity: 1), .init(texture: reference, opacity: scene.display.paintingOpacity)]
        let backdrop = try render(underlay)
        let opaque = try render(underlay + [.init(texture: paint, opacity: 1)])
        #expect(opaque.red > 0.99 && opaque.green < 0.01 && opaque.blue < 0.01)
        let translucent = try render(underlay + [.init(texture: paint, opacity: 0.5)])
        #expect(abs(translucent.red - (0.5 + 0.5 * backdrop.red)) < 0.012)
        #expect(abs(translucent.green - 0.5 * backdrop.green) < 0.012)
        let front = try render([.init(texture: paper, opacity: 1), .init(texture: paint, opacity: 1),
                                .init(texture: reference, opacity: scene.display.paintingOpacity)])
        #expect(front != opaque)
        #expect(try serializer.snapshot(texture: paint) == originalPaint)
        let documentOnly = try render([.init(texture: paper, opacity: 1), .init(texture: paint, opacity: 1)])
        #expect(documentOnly == opaque)

        let cachedCommand = try #require(metal.commandQueue.makeCommandBuffer())
        let cached = try #require(renderer.texture(scene: scene, canvasSize: size, width: 128, height: 128,
            viewportSize: CGSize(width: 128, height: 128), commandBuffer: cachedCommand))
        #expect(cached === reference)
        cachedCommand.commit(); cachedCommand.waitUntilCompleted()
        scene.display.showsFaces = false
        let changedCommand = try #require(metal.commandQueue.makeCommandBuffer())
        let changed = try #require(renderer.texture(scene: scene, canvasSize: size, width: 128, height: 128,
            viewportSize: CGSize(width: 128, height: 128), commandBuffer: changedCommand))
        changedCommand.commit(); changedCommand.waitUntilCompleted()
        #expect(try serializer.snapshot(texture: changed) != referencePixels)
    }
}

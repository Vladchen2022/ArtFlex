import Foundation
import Testing
@testable import ArtFlex

struct NonDestructiveCropPersistenceTests {
    @Test @MainActor func retainedPixelsAndMasksSurviveFormalSaveAndIncrementalRecovery() throws {
        let metal = try #require(MetalDeviceContext())
        let serializer = LayerTextureSerializer(metalContext: metal)
        var workspace = WorkspaceState.stageOneDefault
        workspace.document.canvasSize = .init(width: 32, height: 32)
        workspace.document.layers[1].mask = .init()
        let original = StageOneLayerSurfaceStore()
        original.prepareTextures(for: workspace.document, metal: metal)
        let layer = workspace.document.activeLayerID
        let id = try #require(original.surfaceID(for: layer))
        let texture = try #require(original.texture(for: id))
        let data = Data(repeating: 63, count: 32 * 32 * 4)
        try serializer.restore(snapshot: .init(width: 32, height: 32, bytesPerRow: 128, pixelData: data), into: texture)
        original.fillMaskTexture(for: layer, value: 0, metal: metal)
        let cropped = try NonDestructiveCanvasCrop.prepare(document: workspace.document, source: original,
            region: .init(originX: 8, originY: 8, width: 16, height: 16), metal: metal, serializer: serializer)
        workspace.document.canvasSize = .init(width: 16, height: 16)
        workspace.document.cropRetention = cropped.retention
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArtFlex-CropPersistence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = PersistenceController(workspaceStore: WorkspaceStore(state: workspace),
            layerSurfaceStore: cropped.surfaces, serializer: serializer, recoveryRootURL: root.appendingPathComponent("Recovery"))
        let file = root.appendingPathComponent("crop.artflex")
        try controller.saveProject(to: file)
        let opened = try controller.openProject(from: file)
        #expect(opened.workspace.document.cropRetention == cropped.retention)
        let capture = try controller.freezeIncrementalRecovery()
        let stage = try controller.makeRecoveryStagingURL()
        try controller.writeIncrementalRecovery(capture, to: stage)
        try controller.installRecoveryProject(from: stage)
        let recovered = try controller.openProject(from: controller.recoveryProjectURL)
        #expect(recovered.workspace.document.cropRetention == cropped.retention)
        let expanded = try NonDestructiveCanvasCrop.prepare(document: recovered.workspace.document,
            source: cropped.surfaces, region: .init(originX: -8, originY: -8, width: 32, height: 32),
            metal: metal, serializer: serializer)
        let expandedID = try #require(expanded.surfaces.surfaceID(for: layer))
        let expandedTexture = try #require(expanded.surfaces.readTexture(for: expandedID))
        #expect(try serializer.snapshot(texture: expandedTexture).pixelData == data)
        let mask = try #require(expanded.surfaces.readMaskTexture(for: layer))
        #expect(try serializer.snapshot(texture: mask).pixelData.allSatisfy { $0 == 0 })
    }
}

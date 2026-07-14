import Foundation
@preconcurrency import Metal
import Testing
@testable import ArtFlex

struct LayerTextureSerializerQueueSafetyTests {
    @Test
    func sharedSerializerConcurrentAccessKeepsStagingPoolConsistent() throws {
        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal unavailable")
            return
        }

        let serializer = LayerTextureSerializer(
            metalContext: metalContext,
            stagingPoolMaxResidentBytes: 16 * 1024 * 1024
        )
        let layerSurfaceStore = StageOneLayerSurfaceStore()
        let textures = try (0..<4).map { index -> MTLTexture in
            guard let texture = layerSurfaceStore.makeTexture(width: 64, height: 64, metal: metalContext) else {
                throw QueueSafetyHarnessError.textureUnavailable
            }
            try serializer.restore(
                snapshot: opaqueRedSnapshot(
                    width: 64,
                    height: 64,
                    red: UInt8(100 + (index * 20))
                ),
                into: texture
            )
            return texture
        }

        final class SerializerBox: @unchecked Sendable {
            let value: LayerTextureSerializer
            init(_ value: LayerTextureSerializer) { self.value = value }
        }
        final class TextureArrayBox: @unchecked Sendable {
            let value: [MTLTexture]
            init(_ value: [MTLTexture]) { self.value = value }
        }
        let serializerBox = SerializerBox(serializer)
        let texturesBox = TextureArrayBox(textures)

        DispatchQueue.concurrentPerform(iterations: 24) { iteration in
            let texture = texturesBox.value[iteration % texturesBox.value.count]
            _ = try? serializerBox.value.snapshot(texture: texture)
            _ = try? serializerBox.value.samplePixel(texture: texture, x: 0, y: 0)
        }

        let snapshot = serializer.stagingPoolDebugSnapshot()
        #expect(snapshot.cachedTextureCount >= 0)
        #expect(snapshot.residentBytes >= 0)
        #expect(snapshot.residentBytes <= 16 * 1024 * 1024)

        let sampled = try serializer.samplePixel(texture: textures[0], x: 0, y: 0)
        #expect(sampled.red > 0.3)
        #expect(sampled.alpha > 0.99)
    }

    @Test
    func copyTextureAsyncUsageIsScopedToMetalStrokeEngine() throws {
        let rootURL = workspaceRootURL(from: #filePath)
        let sourceDirectories = [
            rootURL.appendingPathComponent("Core"),
            rootURL.appendingPathComponent("Infrastructure"),
            rootURL.appendingPathComponent("Platform"),
            rootURL.appendingPathComponent("Rendering")
        ]

        let matches = try sourceDirectories.flatMap { directory in
            try swiftFiles(in: directory).filter { fileURL in
                guard fileURL.lastPathComponent != "StageOneLayerSurfaceStore.swift" else {
                    return false
                }
                let contents = try String(contentsOf: fileURL)
                return contents.contains("copyTextureAsync(")
            }
        }

        #expect(matches.map(\.lastPathComponent) == ["MetalStrokeEngine.swift"])
    }

    @Test
    func snapshotBatchSupportsMixedSharedAndPrivateTextures() throws {
        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal unavailable")
            return
        }

        let layerSurfaceStore = StageOneLayerSurfaceStore()
        let serializer = LayerTextureSerializer(metalContext: metalContext)
        guard
            let sharedTexture = layerSurfaceStore.makeTexture(
                width: 4,
                height: 4,
                storageMode: .shared,
                metal: metalContext
            ),
            let privateTexture = layerSurfaceStore.makeTexture(
                width: 4,
                height: 4,
                storageMode: .private,
                metal: metalContext
            )
        else {
            throw QueueSafetyHarnessError.textureUnavailable
        }

        try serializer.restore(snapshot: opaqueRedSnapshot(width: 4, height: 4, red: 120), into: sharedTexture)
        try serializer.restore(snapshot: opaqueRedSnapshot(width: 4, height: 4, red: 240), into: privateTexture)

        let snapshots = try serializer.snapshotBatch(textures: [sharedTexture, privateTexture])
        #expect(snapshots.count == 2)
        #expect(snapshots[0].pixelData[2] == 120)
        #expect(snapshots[0].pixelData[3] == 255)
        #expect(snapshots[1].pixelData[2] == 240)
        #expect(snapshots[1].pixelData[3] == 255)
    }

    @Test
    func copyTextureSynchronouslyMakesCopiedPixelsImmediatelyVisibleToSerializer() throws {
        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal unavailable")
            return
        }

        let layerSurfaceStore = StageOneLayerSurfaceStore()
        let serializer = LayerTextureSerializer(metalContext: metalContext)
        guard
            let sourceTexture = layerSurfaceStore.makeTexture(width: 4, height: 4, metal: metalContext),
            let destinationTexture = layerSurfaceStore.makeTexture(width: 4, height: 4, metal: metalContext)
        else {
            Issue.record("Texture allocation failed")
            return
        }

        try serializer.restore(snapshot: opaqueRedSnapshot(width: 4, height: 4), into: sourceTexture)
        layerSurfaceStore.copyTexture(from: sourceTexture, to: destinationTexture, metal: metalContext)

        let sampled = try serializer.samplePixel(texture: destinationTexture, x: 0, y: 0)
        #expect(sampled.red > 0.99)
        #expect(sampled.alpha > 0.99)
    }

    @Test
    func batchCopyTexturesPreservesEverySourcePixel() throws {
        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal unavailable")
            return
        }

        let layerSurfaceStore = StageOneLayerSurfaceStore()
        let serializer = LayerTextureSerializer(metalContext: metalContext)
        guard
            let sourceA = layerSurfaceStore.makeTexture(width: 8, height: 8, metal: metalContext),
            let sourceB = layerSurfaceStore.makeTexture(width: 8, height: 8, metal: metalContext),
            let destinationA = layerSurfaceStore.makeTexture(width: 8, height: 8, metal: metalContext),
            let destinationB = layerSurfaceStore.makeTexture(width: 8, height: 8, metal: metalContext)
        else {
            throw QueueSafetyHarnessError.textureUnavailable
        }

        try serializer.restore(snapshot: opaqueRedSnapshot(width: 8, height: 8, red: 91), into: sourceA)
        try serializer.restore(snapshot: opaqueRedSnapshot(width: 8, height: 8, red: 217), into: sourceB)

        let copied = layerSurfaceStore.copyTextures(
            [
                (source: sourceA, destination: destinationA),
                (source: sourceB, destination: destinationB)
            ],
            metal: metalContext
        )

        #expect(copied)
        #expect(try serializer.snapshot(texture: destinationA).pixelData == serializer.snapshot(texture: sourceA).pixelData)
        #expect(try serializer.snapshot(texture: destinationB).pixelData == serializer.snapshot(texture: sourceB).pixelData)
    }

    @Test
    func prepareTexturesClearRemainsSynchronouslyVisibleToSerializer() throws {
        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal unavailable")
            return
        }

        let document = makeAuditDocument(canvasSize: .init(width: 8, height: 8))
        let layerSurfaceStore = StageOneLayerSurfaceStore()
        let serializer = LayerTextureSerializer(metalContext: metalContext)
        layerSurfaceStore.prepareTextures(for: document, metal: metalContext)

        guard
            let surfaceID = layerSurfaceStore.surfaceID(for: document.activeLayerID),
            let texture = layerSurfaceStore.texture(for: surfaceID)
        else {
            Issue.record("Prepared texture missing")
            return
        }

        let sampled = try serializer.samplePixel(texture: texture, x: 0, y: 0)
        #expect(sampled.alpha == 0)
    }

    @Test
    func persistenceSaveProjectSeesRestoredPixelsImmediatelyOnSharedSerializerQueue() throws {
        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal unavailable")
            return
        }

        let workspaceStore = WorkspaceStore(state: makeAuditWorkspaceState(canvasSize: .init(width: 8, height: 8)))
        let layerSurfaceStore = StageOneLayerSurfaceStore()
        layerSurfaceStore.prepareTextures(for: workspaceStore.state.document, metal: metalContext)
        let serializer = LayerTextureSerializer(metalContext: metalContext)
        let persistenceController = PersistenceController(
            workspaceStore: workspaceStore,
            layerSurfaceStore: layerSurfaceStore,
            serializer: serializer
        )

        guard
            let surfaceID = layerSurfaceStore.surfaceID(for: workspaceStore.state.document.activeLayerID),
            let texture = layerSurfaceStore.texture(for: surfaceID)
        else {
            Issue.record("Active texture missing")
            return
        }

        try serializer.restore(snapshot: opaqueRedSnapshot(width: 8, height: 8), into: texture)

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("artflex")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try persistenceController.saveProject(to: fileURL)
        let result = try persistenceController.openProject(from: fileURL)
        guard let layerSnapshot = result.layerSnapshots.first else {
            Issue.record("Missing layer snapshot in saved project")
            return
        }

        let pixelBytes = [UInt8](layerSnapshot.texture.pixelData)
        #expect(pixelBytes[2] == 255)
        #expect(pixelBytes[3] == 255)
    }

    @Test
    func eyedropperSamplerReadsImmediatelyRestoredPixelsOnSharedSerializerQueue() throws {
        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal unavailable")
            return
        }

        let document = makeAuditDocument(canvasSize: .init(width: 8, height: 8))
        let layerSurfaceStore = StageOneLayerSurfaceStore()
        layerSurfaceStore.prepareTextures(for: document, metal: metalContext)
        let serializer = LayerTextureSerializer(metalContext: metalContext)
        let eyedropper = EyedropperSampler(serializer: serializer)

        guard
            let surfaceID = layerSurfaceStore.surfaceID(for: document.activeLayerID),
            let texture = layerSurfaceStore.texture(for: surfaceID)
        else {
            Issue.record("Active texture missing")
            return
        }

        try serializer.restore(snapshot: opaqueRedSnapshot(width: 8, height: 8), into: texture)

        let color = try eyedropper.sampleVisibleColor(
            at: .init(x: 0, y: 0),
            document: document,
            layerSurfaceStore: layerSurfaceStore
        )
        #expect(color.red > 0.99)
        #expect(color.green < 0.01)
        #expect(color.blue < 0.01)
        #expect(color.alpha > 0.99)
    }

    @Test
    func eyedropperSamplerPrefersDisplayedLayerTextureOverCommittedLayerTexture() throws {
        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal unavailable")
            return
        }

        let document = makeAuditDocument(canvasSize: .init(width: 8, height: 8))
        let layerSurfaceStore = StageOneLayerSurfaceStore()
        layerSurfaceStore.prepareTextures(for: document, metal: metalContext)
        let serializer = LayerTextureSerializer(metalContext: metalContext)
        let eyedropper = EyedropperSampler(serializer: serializer)

        guard
            let surfaceID = layerSurfaceStore.surfaceID(for: document.activeLayerID),
            let committedTexture = layerSurfaceStore.texture(for: surfaceID),
            let displayedTexture = layerSurfaceStore.makeTexture(
                width: 8,
                height: 8,
                pixelFormat: committedTexture.pixelFormat,
                metal: metalContext
            )
        else {
            Issue.record("Textures missing")
            return
        }

        try serializer.restore(snapshot: opaqueSnapshot(width: 8, height: 8, red: 255), into: committedTexture)
        try serializer.restore(snapshot: opaqueSnapshot(width: 8, height: 8, green: 255), into: displayedTexture)

        let settings = EyedropperSettings(
            sampleSize: .point,
            statistic: .average,
            source: .displayedColor,
            preservesTransparency: false,
            returnsToPreviousTool: false
        )

        let color = try eyedropper.sampleVisibleColor(
            at: .init(x: 0, y: 0),
            document: document,
            layerSurfaceStore: layerSurfaceStore,
            settings: settings,
            displayTextureForLayer: { layerID in
                layerID == document.activeLayerID ? displayedTexture : nil
            }
        )

        #expect(color.red < 0.01)
        #expect(color.green > 0.99)
        #expect(color.blue < 0.01)
        #expect(color.alpha > 0.99)
    }

    @Test
    func trimAndPurgePreserveSerializerCorrectness() throws {
        guard let metalContext = MetalDeviceContext() else {
            Issue.record("Metal unavailable")
            return
        }

        let serializer = LayerTextureSerializer(
            metalContext: metalContext,
            stagingPoolMaxResidentBytes: 4 * 1024 * 1024
        )
        let layerSurfaceStore = StageOneLayerSurfaceStore()
        guard
            let largeTexture = layerSurfaceStore.makeTexture(width: 512, height: 512, metal: metalContext),
            let smallTexture = layerSurfaceStore.makeTexture(width: 64, height: 64, metal: metalContext)
        else {
            Issue.record("Texture allocation failed")
            return
        }

        try serializer.restore(snapshot: opaqueRedSnapshot(width: 512, height: 512), into: largeTexture)
        _ = try serializer.snapshot(texture: largeTexture)
        _ = try serializer.snapshot(texture: smallTexture)

        let beforeTrim = serializer.stagingPoolDebugSnapshot()
        serializer.trimStagingPool(toMaxResidentBytes: 512 * 1024)
        let afterTrim = serializer.stagingPoolDebugSnapshot()
        #expect(afterTrim.residentBytes <= 512 * 1024)
        #expect(afterTrim.residentBytes <= beforeTrim.residentBytes)

        _ = try serializer.snapshot(texture: largeTexture)
        serializer.purgeStagingTextures(exceeding: .init(width: 128, height: 128))
        let afterPurge = serializer.stagingPoolDebugSnapshot()
        #expect(afterPurge.residentBytes <= afterTrim.residentBytes || afterPurge.residentBytes <= 512 * 1024)

        try serializer.restore(snapshot: opaqueRedSnapshot(width: 64, height: 64), into: smallTexture)
        let sampled = try serializer.samplePixel(texture: smallTexture, x: 0, y: 0)
        #expect(sampled.red > 0.99)
        #expect(sampled.alpha > 0.99)
    }
}

private func workspaceRootURL(from filePath: StaticString) -> URL {
    let fileURL = URL(fileURLWithPath: "\(filePath)")
    return fileURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func swiftFiles(in directory: URL) throws -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }

    var files: [URL] = []
    for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
        files.append(fileURL)
    }
    return files
}

private func makeAuditWorkspaceState(canvasSize: CanvasSize) -> WorkspaceState {
    var state = WorkspaceState.stageOneDefault
    state.document = makeAuditDocument(canvasSize: canvasSize)
    return state
}

private func makeAuditDocument(canvasSize: CanvasSize) -> ArtDocument {
    let layer = LayerRecord.stageOneDefault()
    let now = Date()
    return ArtDocument(
        metadata: DocumentMetadata(
            name: "Queue Safety",
            createdAt: now,
            updatedAt: now
        ),
        canvasSize: canvasSize,
        layers: [layer],
        activeLayerID: layer.id
    )
}

private func opaqueRedSnapshot(width: Int, height: Int, red: UInt8 = 255) -> LayerTextureSnapshot {
    opaqueSnapshot(width: width, height: height, red: red)
}

private func opaqueSnapshot(
    width: Int,
    height: Int,
    red: UInt8 = 0,
    green: UInt8 = 0,
    blue: UInt8 = 0
) -> LayerTextureSnapshot {
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
    for offset in stride(from: 0, to: pixels.count, by: 4) {
        pixels[offset] = blue
        pixels[offset + 1] = green
        pixels[offset + 2] = red
        pixels[offset + 3] = 255
    }
    return LayerTextureSnapshot(
        width: width,
        height: height,
        bytesPerRow: bytesPerRow,
        pixelData: Data(pixels)
    )
}

private enum QueueSafetyHarnessError: Error {
    case textureUnavailable
}

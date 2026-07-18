import Foundation
import Metal

struct OpenProjectResult {
    var workspace: WorkspaceState
    var layerSnapshots: [LayerHistorySnapshot]
}

enum PersistenceError: LocalizedError {
    case missingLayerTexture(LayerID)

    var errorDescription: String? {
        switch self {
        case let .missingLayerTexture(layerID):
            return "Missing texture for layer \(layerID.rawValue.uuidString)."
        }
    }
}

final class PersistenceController {
    private let workspaceStore: WorkspaceStore
    private let layerSurfaceStore: StageOneLayerSurfaceStore
    private let serializer: LayerTextureSerializer

    init(
        workspaceStore: WorkspaceStore,
        layerSurfaceStore: StageOneLayerSurfaceStore,
        serializer: LayerTextureSerializer
    ) {
        self.workspaceStore = workspaceStore
        self.layerSurfaceStore = layerSurfaceStore
        self.serializer = serializer
    }

    func saveProject(to fileURL: URL) throws {
        let state = workspaceStore.state
        var snapshotLayers: [(layer: LayerRecord, texture: MTLTexture)] = []
        snapshotLayers.reserveCapacity(state.document.paintLayers.count)

        for layer in state.document.paintLayers {
            guard
                let surfaceID = layerSurfaceStore.surfaceID(for: layer.id),
                let texture = layerSurfaceStore.texture(for: surfaceID)
            else {
                throw PersistenceError.missingLayerTexture(layer.id)
            }

            snapshotLayers.append((layer: layer, texture: texture))
        }

        let textureSnapshots = try serializer.snapshotBatch(
            textures: snapshotLayers.map(\.texture)
        )
        let layerSnapshots = zip(snapshotLayers, textureSnapshots).map { item, textureSnapshot in
            return LayerHistorySnapshot(
                layerID: item.layer.id,
                texture: textureSnapshot
            )
        }

        let package = ProjectPackage.fromWorkspace(
            state,
            layerSnapshots: layerSnapshots
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(package)
        try data.write(to: fileURL, options: .atomic)
    }

    func openProject(from fileURL: URL) throws -> OpenProjectResult {
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let package = try decoder.decode(ProjectPackage.self, from: data)
        var workspace = package.workspaceState
        workspace.document.normalizeLayerHierarchy()

        return OpenProjectResult(
            workspace: workspace,
            layerSnapshots: package.layerSnapshots
        )
    }
}

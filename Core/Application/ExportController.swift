import Foundation
import Metal

struct ExportRequest: Sendable, Equatable {
    var fileURL: URL
}

enum ExportError: LocalizedError {
    case missingActiveLayer

    var errorDescription: String? {
        switch self {
        case .missingActiveLayer:
            return "No active layer is available for export."
        }
    }
}

final class ExportController {
    private let workspaceStore: WorkspaceStore
    private let layerSurfaceStore: StageOneLayerSurfaceStore
    private let pngExporter: PNGExporter

    init(
        workspaceStore: WorkspaceStore,
        layerSurfaceStore: StageOneLayerSurfaceStore,
        pngExporter: PNGExporter
    ) {
        self.workspaceStore = workspaceStore
        self.layerSurfaceStore = layerSurfaceStore
        self.pngExporter = pngExporter
    }

    func exportPNG(request: ExportRequest) throws {
        let document = workspaceStore.state.document

        guard
            let surfaceID = layerSurfaceStore.surfaceID(for: document.activeLayerID),
            let texture = layerSurfaceStore.readTexture(for: surfaceID)
        else {
            throw ExportError.missingActiveLayer
        }

        try pngExporter.export(texture: texture, to: request.fileURL)
    }

    func exportPNG(texture: MTLTexture, request: ExportRequest) throws {
        try pngExporter.export(texture: texture, to: request.fileURL)
    }
}

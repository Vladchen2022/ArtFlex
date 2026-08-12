import Foundation

enum PersistentCanvasSnapshotKind: String, Codable, Sendable, Equatable {
    /// A full-resolution flattened canvas. Applying it does not restore editable layer topology.
    case flattenedCanvas
}

/// Manifest metadata only. Pixel bytes and derived preview images are stored by a resource backend.
struct PersistentCanvasSnapshotDescriptor: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var displayName: String
    var createdAt: Date
    var kind: PersistentCanvasSnapshotKind
    var canvasSize: CanvasSize
    var pixelResourceID: CanvasPixelResourceID
    var thumbnailResourceID: CanvasPixelResourceID?

    init(
        id: UUID = UUID(),
        displayName: String,
        createdAt: Date = Date(),
        kind: PersistentCanvasSnapshotKind = .flattenedCanvas,
        canvasSize: CanvasSize,
        pixelResourceID: CanvasPixelResourceID,
        thumbnailResourceID: CanvasPixelResourceID? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
        self.kind = kind
        self.canvasSize = canvasSize
        self.pixelResourceID = pixelResourceID
        self.thumbnailResourceID = thumbnailResourceID
    }
}

/// A persistence boundary object. Full-resolution pixels remain outside project.json and are
/// stored as a checked, compressed archive resource by ProjectArchiveV2.
struct PersistentCanvasSnapshotPayload: Sendable, Equatable {
    var descriptor: PersistentCanvasSnapshotDescriptor
    var pixels: LayerTextureSnapshot

    init(
        descriptor: PersistentCanvasSnapshotDescriptor,
        pixels: LayerTextureSnapshot
    ) {
        self.descriptor = descriptor
        self.pixels = pixels
    }
}

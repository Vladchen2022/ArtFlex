import Foundation

struct LayerResourceKey: Codable, Hashable, Sendable {
    var layerID: LayerID
    var kind: LayerHistoryResourceKind
}

/// A consumer keeps its own cursor. Capturing recovery cannot consume another consumer's changes.
struct LayerChangeCursor: Codable, Sendable, Equatable {
    var epoch: UUID
    var revision: UInt64
}

struct LayerChangeJournal: Sendable {
    private(set) var epoch = UUID()
    private(set) var revision: UInt64 = 1
    private var fullRevision: UInt64 = 1
    private var tileRevisions: [TileCoordinate: UInt64] = [:]

    var cursor: LayerChangeCursor { .init(epoch: epoch, revision: revision) }

    mutating func markAll() {
        advance()
        fullRevision = revision
        tileRevisions.removeAll(keepingCapacity: true)
    }

    mutating func mark(_ region: PixelRegion, canvasSize: CanvasSize) {
        guard let grid = TileGrid(canvasSize: canvasSize) else { return }
        let tiles = grid.coordinates(intersecting: region)
        guard !tiles.isEmpty else { return }
        advance()
        for tile in tiles { tileRevisions[tile] = revision }
    }

    func changedRegions(since cursor: LayerChangeCursor?, canvasSize: CanvasSize) -> [PixelRegion] {
        guard let grid = TileGrid(canvasSize: canvasSize) else { return [] }
        guard let cursor, cursor.epoch == epoch, cursor.revision >= fullRevision,
              cursor.revision <= revision else {
            return grid.intersections(with: grid.canvasBounds).map(\.canvasRegion)
        }
        return tileRevisions.filter { $0.value > cursor.revision }
            .keys.sorted { ($0.y, $0.x) < ($1.y, $1.x) }.compactMap(grid.bounds(for:))
    }

    private mutating func advance() {
        if revision == .max {
            epoch = UUID()
            revision = 1
            fullRevision = 1
            tileRevisions.removeAll()
        } else {
            revision += 1
        }
    }
}

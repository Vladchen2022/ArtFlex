import Foundation
import Metal

/// Bridges the platform-neutral fuzzy selector to Metal textures. Contiguous
/// current-layer selections load 512-pixel tiles lazily, matching the existing
/// bucket-fill strategy instead of reading the entire canvas up front.
final class MagicWandSelectionEngine: @unchecked Sendable {
    private struct TileKey: Hashable {
        var x: Int
        var y: Int
    }

    private struct Tile {
        var originX: Int
        var originY: Int
        var width: Int
        var height: Int
        var bytesPerRow: Int
        var bytes: [UInt8]
    }

    private let serializer: LayerTextureSerializer
    private let tileLength = 512

    init(serializer: LayerTextureSerializer) {
        self.serializer = serializer
    }

    func select(
        texture: MTLTexture,
        at point: CanvasPoint,
        settings: SmartSelectionSettings
    ) throws -> SmartSelectionSegmentationResult? {
        if !settings.isContiguous {
            let snapshot = try serializer.snapshot(
                texture: texture,
                originX: 0,
                originY: 0,
                width: texture.width,
                height: texture.height
            )
            return select(snapshot: snapshot, originX: 0, originY: 0, at: point, settings: settings)
        }

        var tiles: [TileKey: Tile] = [:]
        func loadTile(_ key: TileKey) throws -> Tile {
            if let existing = tiles[key] { return existing }
            let originX = key.x * tileLength
            let originY = key.y * tileLength
            let width = min(tileLength, texture.width - originX)
            let height = min(tileLength, texture.height - originY)
            let snapshot = try serializer.snapshot(
                texture: texture,
                originX: originX,
                originY: originY,
                width: width,
                height: height
            )
            let tile = Tile(
                originX: originX,
                originY: originY,
                width: width,
                height: height,
                bytesPerRow: snapshot.bytesPerRow,
                bytes: [UInt8](snapshot.pixelData)
            )
            tiles[key] = tile
            return tile
        }

        return try SmartSelectionSegmenter.segment(
            originX: 0,
            originY: 0,
            width: texture.width,
            height: texture.height,
            seedPoint: point,
            settings: settings
        ) { x, y in
            let key = TileKey(x: x / tileLength, y: y / tileLength)
            let tile = try loadTile(key)
            let localX = x - tile.originX
            let localY = y - tile.originY
            let offset = (localY * tile.bytesPerRow) + (localX * 4)
            return PremultipliedSRGBAPixel(
                bgraBlue: tile.bytes[offset],
                green: tile.bytes[offset + 1],
                red: tile.bytes[offset + 2],
                alpha: tile.bytes[offset + 3]
            )
        }
    }

    func select(
        snapshot: LayerTextureSnapshot,
        originX: Int,
        originY: Int,
        at point: CanvasPoint,
        settings: SmartSelectionSettings
    ) -> SmartSelectionSegmentationResult? {
        SmartSelectionSegmenter.segment(
            raster: SmartSelectionRaster(
                originX: originX,
                originY: originY,
                width: snapshot.width,
                height: snapshot.height,
                bytesPerRow: snapshot.bytesPerRow,
                premultipliedBGRABytes: snapshot.pixelData
            ),
            seedPoint: point,
            settings: settings
        )
    }
}

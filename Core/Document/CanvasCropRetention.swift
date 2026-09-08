import Foundation

/// Hidden pixels belong to the document, not to the temporary crop tool or the undo stack.
/// Coordinates are relative to the currently visible canvas; negative origins are intentional.
struct RetainedCropTile: Codable, Sendable, Equatable {
    var key: LayerResourceKey
    var region: PixelRegion
    var compressedPixels: Data
    var sha256: String
    var pixelEncoding: CanvasPixelEncoding? = nil
    var encoding: CanvasPixelEncoding { pixelEncoding ?? (key.kind == .mask ? .grayscale8 : .premultipliedBGRA8SRGB) }
}

struct CanvasCropRetention: Codable, Sendable, Equatable {
    var fullBounds: PixelRegion
    var tiles: [RetainedCropTile]

    var compressedByteCount: Int { tiles.reduce(0) { $0 + $1.compressedPixels.count } }

    func validated(for document: ArtDocument) throws -> CanvasCropRetention {
        let edge = CanvasCapacityPolicy.standard.maximumEdge
        guard fullBounds.width > 0, fullBounds.height > 0,
              fullBounds.width <= edge, fullBounds.height <= edge,
              fullBounds.originX >= -edge, fullBounds.originY >= -edge,
              fullBounds.originX <= 0, fullBounds.originY <= 0,
              fullBounds.maxX >= document.canvasSize.width, fullBounds.maxY >= document.canvasSize.height,
              tiles.count <= 1_048_576 else { throw PersistenceError.invalidProject("保留裁剪范围无效") }
        let visible = PixelRegion(originX: 0, originY: 0, width: document.canvasSize.width, height: document.canvasSize.height)
        var validKeys = Set(document.paintLayers.map { LayerResourceKey(layerID: $0.id, kind: .content) })
        for layer in document.paintLayers where layer.mask != nil { validKeys.insert(.init(layerID: layer.id, kind: .mask)) }
        for tile in tiles {
            guard tile.region.width > 0, tile.region.height > 0,
                  tile.region.width <= 512, tile.region.height <= 512,
                  tile.region.originX >= -edge, tile.region.originX <= edge,
                  tile.region.originY >= -edge, tile.region.originY <= edge,
                  validKeys.contains(tile.key),
                  tile.region.intersection(with: fullBounds) == tile.region,
                  tile.region.intersection(with: visible) == nil,
                  tile.compressedPixels.count <= 2 * 1024 * 1024,
                  tile.encoding == (tile.key.kind == .mask ? .grayscale8 : document.colorStandard.pixelFormat.encoding),
                  tile.sha256.count == 64,
                  tile.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw PersistenceError.invalidProject("保留裁剪像素无效")
            }
        }
        return self
    }
}

extension PixelRegion {
    func subtracting(_ other: PixelRegion) -> [PixelRegion] {
        guard let cut = intersection(with: other) else { return isEmpty ? [] : [self] }
        return [
            PixelRegion(originX: originX, originY: originY, width: width, height: cut.originY - originY),
            PixelRegion(originX: originX, originY: cut.maxY, width: width, height: maxY - cut.maxY),
            PixelRegion(originX: originX, originY: cut.originY, width: cut.originX - originX, height: cut.height),
            PixelRegion(originX: cut.maxX, originY: cut.originY, width: maxX - cut.maxX, height: cut.height)
        ].filter { !$0.isEmpty }
    }
}

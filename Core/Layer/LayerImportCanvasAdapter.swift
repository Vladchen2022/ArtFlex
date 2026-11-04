import Foundation

/// Aligns document origins without scaling. Pixels outside the destination remain in the
/// existing crop-retention format, so copying into a smaller canvas is not destructive.
enum LayerImportCanvasAdapter {
    static func adapt(_ source: ProjectArchivePayload, included: Set<LayerID>, to size: CanvasSize) throws -> ProjectArchivePayload {
        guard source.package.document.canvasSize != size else { return source }
        var result = source
        let target = PixelRegion(originX: 0, originY: 0, width: size.width, height: size.height)
        let oldSize = source.package.document.canvasSize
        let oldVisible = PixelRegion(originX: 0, originY: 0, width: oldSize.width, height: oldSize.height)
        let fullBounds = (source.package.document.cropRetention?.fullBounds ?? oldVisible).union(target)
        guard CanvasCapacityPolicy.standard.assess(.init(width: fullBounds.width, height: fullBounds.height)).isSupported else {
            throw CanvasResourceError(message: "跨文档图层的完整范围超出画布支持上限")
        }
        var retained: [RetainedCropTile] = []
        var snapshots: [LayerHistorySnapshot] = []
        for resource in source.package.layerSnapshots where included.contains(resource.layerID) {
            let encoding = resource.texture.encoding, bpp = encoding.bytesPerPixel
            let key = LayerResourceKey(layerID: resource.layerID, kind: resource.resourceKind)
            var pixels = Data(repeating: resource.resourceKind == .mask ? 255 : 0, count: size.width * size.height * bpp)
            func place(_ data: Data, region: PixelRegion) throws {
                if let overlap = region.intersection(with: target) {
                    pixels.withUnsafeMutableBytes { output in
                        data.withUnsafeBytes { input in
                            for y in overlap.originY..<overlap.maxY {
                                memcpy(output.baseAddress!.advanced(by: (y * size.width + overlap.originX) * bpp),
                                    input.baseAddress!.advanced(by: ((y - region.originY) * region.width + overlap.originX - region.originX) * bpp), overlap.width * bpp)
                            }
                        }
                    }
                }
                for excluded in region.subtracting(target) {
                    for y in stride(from: excluded.originY, to: excluded.maxY, by: 512) {
                        for x in stride(from: excluded.originX, to: excluded.maxX, by: 512) {
                            let tile = PixelRegion(originX: x, originY: y, width: min(512, excluded.maxX - x), height: min(512, excluded.maxY - y))
                            let patch = NonDestructiveCanvasCrop.slice(data, sourceRegion: region, targetRegion: tile, encoding: encoding)
                            retained.append(try NonDestructiveCanvasCrop.encode(patch.pixelData, key: key, region: tile, encoding: encoding))
                        }
                    }
                }
            }
            let visible = PixelRegion(originX: resource.originX, originY: resource.originY, width: resource.texture.width, height: resource.texture.height)
            try place(resource.texture.pixelData, region: visible)
            for tile in source.package.document.cropRetention?.tiles ?? [] where tile.key == key {
                try place(NonDestructiveCanvasCrop.decode(tile), region: tile.region)
            }
            snapshots.append(.init(layerID: resource.layerID, resourceKind: resource.resourceKind,
                texture: .init(width: size.width, height: size.height, bytesPerRow: size.width * bpp, pixelData: pixels, encoding: encoding)))
        }
        result.package.document.canvasSize = size
        result.package.document.cropRetention = .init(fullBounds: fullBounds, tiles: retained)
        result.package.layerSnapshots = snapshots
        return result
    }
}

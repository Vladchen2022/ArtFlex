import Foundation
import Metal

enum NonDestructiveCanvasCrop {
    struct Result {
        var surfaces: StageOneLayerSurfaceStore
        var retention: CanvasCropRetention
    }

    static func prepare(document: ArtDocument, source: StageOneLayerSurfaceStore,
                        region: PixelRegion, metal: MetalDeviceContext,
                        serializer: LayerTextureSerializer) throws -> Result {
        let size = CanvasSize(width: region.width, height: region.height)
        let visible = PixelRegion(originX: 0, originY: 0, width: document.canvasSize.width, height: document.canvasSize.height)
        let previous = try document.cropRetention?.validated(for: document)
        let oldExtent = previous?.fullBounds ?? visible
        let fullBounds = PixelRegion(originX: min(oldExtent.originX, region.originX),
            originY: min(oldExtent.originY, region.originY),
            width: max(oldExtent.maxX, region.maxX) - min(oldExtent.originX, region.originX),
            height: max(oldExtent.maxY, region.maxY) - min(oldExtent.originY, region.originY))
        guard CanvasCapacityPolicy.standard.assess(.init(width: fullBounds.width, height: fullBounds.height)).isSupported else {
            throw CanvasResourceError(message: "包含保留像素的总范围超出画布支持上限，原画稿未修改")
        }
        let surfaces = try LayerSurfaceTransfer.prepare(document: document, source: source, metal: metal,
            targetSize: size, originX: region.originX, originY: region.originY)
        var retained: [RetainedCropTile] = []
        func isPresent(_ key: LayerResourceKey) -> Bool {
            guard let layer = document.layer(key.layerID), layer.isPaintLayer else { return false }
            return key.kind == .content || layer.mask != nil
        }
        for tile in previous?.tiles ?? [] where isPresent(tile.key) {
            guard let overlap = tile.region.intersection(with: region) else {
                var shifted = tile
                shifted.region = tile.region.translatedBy(x: -region.originX, y: -region.originY)
                retained.append(shifted)
                continue
            }
            let pixels = try decode(tile)
            let target = tile.key.kind == .mask ? surfaces.maskTexture(for: tile.key.layerID)
                : surfaces.surfaceID(for: tile.key.layerID).flatMap(surfaces.texture(for:))
            guard let target else { throw CanvasResourceError(message: "无法恢复框外图层像素") }
            let patch = slice(pixels, sourceRegion: tile.region, targetRegion: overlap, encoding: tile.encoding)
            try serializer.restore(snapshot: patch, into: target,
                destinationX: overlap.originX - region.originX, destinationY: overlap.originY - region.originY)
            for remainder in tile.region.subtracting(region) {
                let patch = slice(pixels, sourceRegion: tile.region, targetRegion: remainder, encoding: tile.encoding)
                retained.append(try encode(patch.pixelData, key: tile.key,
                    region: remainder.translatedBy(x: -region.originX, y: -region.originY), encoding: tile.encoding))
            }
        }
        guard let grid = TileGrid(canvasSize: document.canvasSize) else { throw CocoaError(.fileWriteUnknown) }
        let excluded = visible.subtracting(region).flatMap { grid.intersections(with: $0).map(\.canvasRegion) }
        for layer in document.paintLayers {
            for kind in (layer.mask == nil ? [LayerHistoryResourceKind.content] : [.content, .mask]) {
                let key = LayerResourceKey(layerID: layer.id, kind: kind)
                let texture = kind == .mask ? source.readMaskTexture(for: layer.id)
                    : source.surfaceID(for: layer.id).flatMap(source.readTexture(for:))
                guard let texture else { throw PersistenceError.missingLayerTexture(layer.id) }
                for area in excluded {
                    let patch = try serializer.snapshot(texture: texture, originX: area.originX,
                        originY: area.originY, width: area.width, height: area.height)
                    let blank: UInt8 = kind == .mask ? 255 : 0
                    if patch.pixelData.allSatisfy({ $0 == blank }) { continue }
                    retained.append(try encode(patch.pixelData, key: key,
                        region: area.translatedBy(x: -region.originX, y: -region.originY), encoding: patch.encoding))
                }
            }
        }
        let retention = CanvasCropRetention(fullBounds: fullBounds.translatedBy(x: -region.originX, y: -region.originY), tiles: retained)
        var targetDocument = document
        targetDocument.canvasSize = size
        _ = try retention.validated(for: targetDocument)
        return Result(surfaces: surfaces, retention: retention)
    }

    static func decode(_ tile: RetainedCropTile) throws -> Data {
        let bpp = tile.encoding.bytesPerPixel
        let count = tile.region.width * tile.region.height * bpp
        let pixels = try ZlibCodec.decompress(tile.compressedPixels, expectedSize: count)
        guard ProjectReferenceImageHash.sha256Hex(pixels) == tile.sha256 else { throw CocoaError(.fileReadCorruptFile) }
        return pixels
    }

    static func encode(_ pixels: Data, key: LayerResourceKey, region: PixelRegion, encoding: CanvasPixelEncoding) throws -> RetainedCropTile {
        .init(key: key, region: region, compressedPixels: try ZlibCodec.compress(pixels),
              sha256: ProjectReferenceImageHash.sha256Hex(pixels), pixelEncoding: encoding)
    }

    static func slice(_ pixels: Data, sourceRegion: PixelRegion, targetRegion: PixelRegion, encoding: CanvasPixelEncoding) -> LayerTextureSnapshot {
        let bpp = encoding.bytesPerPixel
        let rowBytes = targetRegion.width * bpp
        var result = Data(count: rowBytes * targetRegion.height)
        result.withUnsafeMutableBytes { output in
            pixels.withUnsafeBytes { input in
                for row in 0..<targetRegion.height {
                    let offset = ((targetRegion.originY - sourceRegion.originY + row) * sourceRegion.width + targetRegion.originX - sourceRegion.originX) * bpp
                    memcpy(output.baseAddress!.advanced(by: row * rowBytes), input.baseAddress!.advanced(by: offset), rowBytes)
                }
            }
        }
        return .init(width: targetRegion.width, height: targetRegion.height, bytesPerRow: rowBytes, pixelData: result, encoding: encoding)
    }
}

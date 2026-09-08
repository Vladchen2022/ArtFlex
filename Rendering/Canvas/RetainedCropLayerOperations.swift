import Foundation
import Metal

/// Reuses the canvas compositor for hidden pixels; never expands every layer to a full canvas.
enum RetainedCropLayerOperations {
    static func merged(document: ArtDocument, layers: [LayerRecord], target: LayerID,
                       metal: MetalDeviceContext, serializer: LayerTextureSerializer,
                       merger: LayerMergeController) throws -> CanvasCropRetention? {
        guard var result = document.cropRetention else { return nil }
        let ids = Set(layers.map(\.id))
        let source = result.tiles.filter { ids.contains($0.key.layerID) }
        result.tiles.removeAll { ids.contains($0.key.layerID) }
        guard !source.isEmpty else { return result }
        let byKey = Dictionary(grouping: source, by: \.key)
        let visible = PixelRegion(originX: 0, originY: 0, width: document.canvasSize.width, height: document.canvasSize.height)
        let extent = result.fullBounds
        guard let grid = TileGrid(canvasSize: .init(width: extent.width, height: extent.height)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let coordinates = Set(source.flatMap {
            grid.coordinates(intersecting: $0.region.translatedBy(x: -extent.originX, y: -extent.originY))
        }).sorted { ($0.y, $0.x) < ($1.y, $1.x) }
        let store = StageOneLayerSurfaceStore()
        let encoding = document.colorStandard.pixelFormat.encoding
        for coordinate in coordinates {
            guard let local = grid.bounds(for: coordinate) else { continue }
            for area in local.translatedBy(x: extent.originX, y: extent.originY).subtracting(visible) {
                var textures: [LayerID: MTLTexture] = [:]
                var masks: [LayerID: MTLTexture] = [:]
                for layer in layers {
                    let key = LayerResourceKey(layerID: layer.id, kind: .content)
                    let pixels = try snapshot(tiles: byKey[key] ?? [], area: area, encoding: encoding, blank: 0)
                    guard let texture = store.makeTexture(width: area.width, height: area.height,
                        pixelFormat: encoding.metalPixelFormat, metal: metal) else { throw CocoaError(.fileWriteUnknown) }
                    try serializer.restore(snapshot: pixels, into: texture)
                    textures[layer.id] = texture
                    if layer.mask?.isEnabled == true {
                        let maskKey = LayerResourceKey(layerID: layer.id, kind: .mask)
                        let pixels = try snapshot(tiles: byKey[maskKey] ?? [], area: area, encoding: .grayscale8, blank: 255)
                        guard let mask = store.makeTexture(width: area.width, height: area.height,
                            pixelFormat: .r8Unorm, metal: metal) else { throw CocoaError(.fileWriteUnknown) }
                        try serializer.restore(snapshot: pixels, into: mask)
                        masks[layer.id] = mask
                    }
                }
                let inputs = layers.compactMap { layer -> CanvasLayerCompositeInput? in
                    guard let texture = textures[layer.id] else { return nil }
                    return .init(texture: texture,
                        opacity: layer.isVisible ? document.effectiveLayerOpacity(layer.id) : 0,
                        blendMode: layer.blendMode,
                        clipMaskTexture: layer.clipTargetLayerID.flatMap { textures[$0] },
                        clipLayerMaskTexture: layer.clipTargetLayerID.flatMap { masks[$0] },
                        layerMaskTexture: masks[layer.id], curveAdjustmentLUTs: layer.adjustment?.curveLUTs)
                }
                guard let output = textures[target] else { throw CocoaError(.fileWriteUnknown) }
                try merger.mergeVisible(layers: inputs, into: output)
                let pixels = try serializer.snapshot(texture: output)
                if pixels.pixelData.contains(where: { $0 != 0 }) {
                    result.tiles.append(try NonDestructiveCanvasCrop.encode(pixels.pixelData,
                        key: .init(layerID: target, kind: .content), region: area, encoding: encoding))
                }
            }
        }
        return result
    }

    /// A missing retained mask tile means white, so inversion must also visit implicit white tiles.
    static func mask(document: ArtDocument, layerID: LayerID, fill: UInt8? = nil) throws -> CanvasCropRetention? {
        guard var result = document.cropRetention else { return nil }
        let key = LayerResourceKey(layerID: layerID, kind: .mask)
        let old = result.tiles.filter { $0.key == key }
        result.tiles.removeAll { $0.key == key }
        guard fill != 255 else { return result }
        let visible = PixelRegion(originX: 0, originY: 0, width: document.canvasSize.width, height: document.canvasSize.height)
        let extent = result.fullBounds
        guard let grid = TileGrid(canvasSize: .init(width: extent.width, height: extent.height)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        for excluded in extent.subtracting(visible) {
            for tile in grid.intersections(with: excluded.translatedBy(x: -extent.originX, y: -extent.originY)) {
                let area = tile.canvasRegion.translatedBy(x: extent.originX, y: extent.originY)
                let pixels: Data
                if let fill { pixels = Data(repeating: fill, count: area.width * area.height) }
                else { pixels = try Data(snapshot(tiles: old, area: area, encoding: .grayscale8, blank: 255).pixelData.map { 255 &- $0 }) }
                if pixels.contains(where: { $0 != 255 }) {
                    result.tiles.append(try NonDestructiveCanvasCrop.encode(pixels, key: key, region: area, encoding: .grayscale8))
                }
            }
        }
        return result
    }

    private static func snapshot(tiles: [RetainedCropTile], area: PixelRegion,
                                 encoding: CanvasPixelEncoding, blank: UInt8) throws -> LayerTextureSnapshot {
        let bpp = encoding.bytesPerPixel
        let rowBytes = area.width * bpp
        var data = Data(repeating: blank, count: rowBytes * area.height)
        for tile in tiles {
            guard let overlap = tile.region.intersection(with: area) else { continue }
            let pixels = try NonDestructiveCanvasCrop.decode(tile)
            let patch = NonDestructiveCanvasCrop.slice(pixels, sourceRegion: tile.region, targetRegion: overlap, encoding: encoding)
            data.withUnsafeMutableBytes { output in
                patch.pixelData.withUnsafeBytes { input in
                    for row in 0..<overlap.height {
                        let offset = (overlap.originY - area.originY + row) * rowBytes + (overlap.originX - area.originX) * bpp
                        memcpy(output.baseAddress!.advanced(by: offset), input.baseAddress!.advanced(by: row * patch.bytesPerRow), patch.bytesPerRow)
                    }
                }
            }
        }
        return .init(width: area.width, height: area.height, bytesPerRow: rowBytes, pixelData: data, encoding: encoding)
    }
}

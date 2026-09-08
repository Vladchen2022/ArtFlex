import Foundation
import Metal

/// Owns a texture and its private sparse heap. Only initialized tiles are exposed to readers.
/// All mapping and copies use the canvas queue, before callers encode writes to the returned texture.
final class SparseLayerTexture {
    let metal: MetalDeviceContext
    let size: CanvasSize
    let format: MTLPixelFormat
    let tileSize: MTLSize
    private(set) var texture: MTLTexture
    private var heap: MTLHeap
    private(set) var mappedTiles: Set<TileCoordinate> = []
    private(set) var capacity: Int

    var allocatedBytes: Int { heap.size }
    var residentTileBytes: Int { mappedTiles.count * metal.device.sparseTileSizeInBytes }

    static func isSupported(by device: MTLDevice) -> Bool {
        device.supportsFamily(.apple6)
    }

    init?(size: CanvasSize, format: MTLPixelFormat = .bgra8Unorm_srgb,
          metal: MetalDeviceContext, initialCapacity: Int = 1) {
        guard Self.isSupported(by: metal.device), size.width > 0, size.height > 0 else { return nil }
        let tileSize = metal.device.sparseTileSize(with: .type2D, pixelFormat: format, sampleCount: 1)
        guard tileSize.width > 0, tileSize.height > 0 else { return nil }
        let capacity = max(1, initialCapacity)
        guard let pair = Self.allocate(size: size, format: format, capacity: capacity, metal: metal) else { return nil }
        self.metal = metal
        self.size = size
        self.format = format
        self.tileSize = tileSize
        self.capacity = capacity
        self.heap = pair.heap
        self.texture = pair.texture
    }

    func regions(for tiles: Set<TileCoordinate>) -> [PixelRegion] {
        tiles.sorted { ($0.y, $0.x) < ($1.y, $1.x) }.map { tile in
            let x = tile.x * tileSize.width, y = tile.y * tileSize.height
            return PixelRegion(originX: x, originY: y,
                               width: min(tileSize.width, size.width - x),
                               height: min(tileSize.height, size.height - y))
        }
    }

    func tiles(intersecting region: PixelRegion) -> Set<TileCoordinate> {
        guard let bounds = PixelRegion.canvasBounds(for: size)?.intersection(with: region) else { return [] }
        var result: Set<TileCoordinate> = []
        for y in (bounds.originY / tileSize.height)...((bounds.maxY - 1) / tileSize.height) {
            for x in (bounds.originX / tileSize.width)...((bounds.maxX - 1) / tileSize.width) {
                result.insert(TileCoordinate(x: x, y: y))
            }
        }
        return result
    }

    /// Allocates and clears missing tiles. Existing pixels survive heap growth atomically.
    func prepareForWrite(in region: PixelRegion) throws {
        let required = mappedTiles.union(tiles(intersecting: region))
        guard required != mappedTiles else { return }
        // Mapping failure must never leave the currently exposed heap partially initialized.
        // Prepare replacement ownership first, including when the current heap has spare capacity.
        do {
            let newCapacity = max(required.count, capacity)
            guard let pair = Self.allocate(size: size, format: format, capacity: newCapacity, metal: metal) else {
                throw CanvasResourceError(message: "无法扩展稀疏图层；原像素未修改")
            }
            try initialize(required, on: pair.texture, copying: texture, copyTiles: mappedTiles)
            texture = pair.texture
            heap = pair.heap
            capacity = newCapacity
        }
        mappedTiles = required
    }

    static func copying(_ source: MTLTexture, tiles: Set<TileCoordinate>, metal: MetalDeviceContext) throws -> SparseLayerTexture {
        guard let result = SparseLayerTexture(size: .init(width: source.width, height: source.height),
                                             format: source.pixelFormat, metal: metal,
                                             initialCapacity: max(tiles.count, 1)) else {
            throw CanvasResourceError(message: "无法分配稀疏图层")
        }
        if !tiles.isEmpty {
            try result.initialize(tiles, on: result.texture, copying: source, copyTiles: tiles)
            result.mappedTiles = tiles
        }
        return result
    }

    func cloned() throws -> SparseLayerTexture {
        guard let result = SparseLayerTexture(size: size, format: format, metal: metal,
                                             initialCapacity: max(mappedTiles.count, 1)) else {
            throw CanvasResourceError(message: "无法复制稀疏图层；原像素未修改")
        }
        if !mappedTiles.isEmpty {
            try result.initialize(mappedTiles, on: result.texture, copying: texture, copyTiles: mappedTiles)
            result.mappedTiles = mappedTiles
        }
        return result
    }

    private static func allocate(size: CanvasSize, format: MTLPixelFormat, capacity: Int,
                                 metal: MetalDeviceContext) -> (heap: MTLHeap, texture: MTLTexture)? {
        let (bytes, overflow) = capacity.multipliedReportingOverflow(by: metal.device.sparseTileSizeInBytes)
        guard !overflow, bytes > 0 else { return nil }
        let descriptor = MTLHeapDescriptor()
        descriptor.type = .sparse
        descriptor.storageMode = .private
        descriptor.size = bytes
        guard let heap = metal.device.makeHeap(descriptor: descriptor) else { return nil }
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: size.width, height: size.height, mipmapped: false)
        textureDescriptor.storageMode = .private
        textureDescriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let texture = heap.makeTexture(descriptor: textureDescriptor) else { return nil }
        return (heap, texture)
    }

    private func initialize(_ tiles: Set<TileCoordinate>, on target: MTLTexture,
                            copying source: MTLTexture?, copyTiles: Set<TileCoordinate>) throws {
        guard let command = metal.commandQueue.makeCommandBuffer(),
              let mapping = command.makeResourceStateCommandEncoder(),
              let updateMapping = mapping.updateTextureMapping(_:mode:region:mipLevel:slice:) else {
            throw CanvasResourceError(message: "无法准备稀疏图层映射")
        }
        command.label = "ArtFlex sparse layer mapping"
        for tile in tiles {
            updateMapping(target, .map, MTLRegionMake2D(tile.x, tile.y, 1, 1), 0, 0)
        }
        mapping.endEncoding()
        // A single zero tile initializes newly mapped memory; never read uninitialized heap bytes.
        let bytesPerPixel = format == .rgba16Float ? 8 : 4
        let rowBytes = tileSize.width * bytesPerPixel
        guard let zero = metal.device.makeBuffer(length: rowBytes * tileSize.height, options: .storageModeShared),
              let blit = command.makeBlitCommandEncoder() else {
            throw CanvasResourceError(message: "无法初始化稀疏图层")
        }
        memset(zero.contents(), 0, zero.length)
        for region in regions(for: tiles) {
            let coordinate = TileCoordinate(x: region.originX / tileSize.width, y: region.originY / tileSize.height)
            let origin = MTLOrigin(x: region.originX, y: region.originY, z: 0)
            let copySize = MTLSize(width: region.width, height: region.height, depth: 1)
            if let source, copyTiles.contains(coordinate) {
                blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: origin,
                          sourceSize: copySize, to: target, destinationSlice: 0, destinationLevel: 0,
                          destinationOrigin: origin)
            } else {
                blit.copy(from: zero, sourceOffset: 0, sourceBytesPerRow: rowBytes,
                          sourceBytesPerImage: zero.length, sourceSize: copySize, to: target,
                          destinationSlice: 0, destinationLevel: 0, destinationOrigin: origin)
            }
        }
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw CanvasResourceError(message: command.error?.localizedDescription ?? "稀疏图层映射失败")
        }
    }
}

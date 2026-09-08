import Metal

/// One threadgroup per native tile; only a small occupancy table is read back to the CPU.
final class SparseTileScanner {
    private let metal: MetalDeviceContext
    private let pipeline: MTLComputePipelineState

    init(metal: MetalDeviceContext) throws {
        self.metal = metal
        let library = try metal.device.makeLibrary(source: """
        #include <metal_stdlib>
        using namespace metal;
        kernel void occupiedTiles(texture2d<float, access::read> source [[texture(0)]],
            device uint *flags [[buffer(0)]], constant uint2 &tileSize [[buffer(1)]],
            const device uint2 *candidates [[buffer(2)]],
            uint index [[threadgroup_position_in_grid]], uint tid [[thread_index_in_threadgroup]]) {
            threadgroup atomic_uint occupied;
            if (tid == 0) atomic_store_explicit(&occupied, 0, memory_order_relaxed);
            threadgroup_barrier(mem_flags::mem_threadgroup);
            uint2 origin = candidates[index] * tileSize;
            for (uint i = tid; i < tileSize.x * tileSize.y; i += 256) {
                uint2 p = origin + uint2(i % tileSize.x, i / tileSize.x);
                if (p.x < source.get_width() && p.y < source.get_height() && any(source.read(p) != 0.0f)) {
                    atomic_store_explicit(&occupied, 1, memory_order_relaxed);
                    break;
                }
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            if (tid == 0) {
                flags[index] = atomic_load_explicit(&occupied, memory_order_relaxed);
            }
        }
        """, options: nil)
        guard let function = library.makeFunction(name: "occupiedTiles") else {
            throw CanvasResourceError(message: "无法创建图层占用检测程序")
        }
        pipeline = try metal.device.makeComputePipelineState(function: function)
    }

    func occupiedTiles(in texture: MTLTexture, tileSize: MTLSize,
                       candidates: Set<TileCoordinate>? = nil) throws -> Set<TileCoordinate> {
        let columns = (texture.width + tileSize.width - 1) / tileSize.width
        let rows = (texture.height + tileSize.height - 1) / tileSize.height
        let coordinates = (candidates ?? Set((0..<(columns * rows)).map {
            TileCoordinate(x: $0 % columns, y: $0 / columns)
        })).filter { $0.x >= 0 && $0.y >= 0 && $0.x < columns && $0.y < rows }
            .sorted { ($0.y, $0.x) < ($1.y, $1.x) }
        guard !coordinates.isEmpty else { return [] }
        let values = coordinates.map { SIMD2<UInt32>(UInt32($0.x), UInt32($0.y)) }
        let candidateBuffer = values.withUnsafeBytes { bytes in
            metal.device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
        }
        guard let candidateBuffer,
              let result = metal.device.makeBuffer(length: coordinates.count * 4, options: .storageModeShared),
              let command = metal.commandQueue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else {
            throw CanvasResourceError(message: "无法检查图层占用")
        }
        var size = SIMD2<UInt32>(UInt32(tileSize.width), UInt32(tileSize.height))
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(result, offset: 0, index: 0)
        encoder.setBytes(&size, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 1)
        encoder.setBuffer(candidateBuffer, offset: 0, index: 2)
        encoder.dispatchThreadgroups(.init(width: coordinates.count, height: 1, depth: 1),
                                     threadsPerThreadgroup: .init(width: 256, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw CanvasResourceError(message: command.error?.localizedDescription ?? "图层占用检测失败")
        }
        let flags = result.contents().bindMemory(to: UInt32.self, capacity: coordinates.count)
        return Set(coordinates.indices.compactMap { flags[$0] == 0 ? nil : coordinates[$0] })
    }
}

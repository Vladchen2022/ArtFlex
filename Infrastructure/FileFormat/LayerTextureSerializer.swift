import Foundation
import Metal
import MetalPerformanceShaders

struct LayerTextureSnapshot: Codable, Sendable, Equatable {
    var width: Int
    var height: Int
    var bytesPerRow: Int
    var pixelData: Data
}

struct LayerTextureRegionSnapshotRequest {
    var texture: MTLTexture
    var originX: Int
    var originY: Int
    var width: Int
    var height: Int
}

private struct LayerSerializerStagingKey: Hashable {
    var width: Int
    var height: Int
    var pixelFormatRawValue: UInt

    init(width: Int, height: Int, pixelFormat: MTLPixelFormat) {
        self.width = width
        self.height = height
        self.pixelFormatRawValue = pixelFormat.rawValue
    }
}

struct LayerSerializerStagingPoolSnapshot: Sendable, Equatable {
    var cachedTextureCount: Int
    var residentBytes: Int
}

private final class LayerSerializerStagingPool {
    private let device: MTLDevice
    private let lock = NSLock()
    private var availableTextures: [LayerSerializerStagingKey: [MTLTexture]] = [:]
    private var residentBytes = 0
    private var maxRetainedBytes: Int

    init(device: MTLDevice, maxRetainedBytes: Int) {
        self.device = device
        self.maxRetainedBytes = max(0, maxRetainedBytes)
    }

    func checkout(
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat
    ) -> MTLTexture? {
        let key = LayerSerializerStagingKey(
            width: width,
            height: height,
            pixelFormat: pixelFormat
        )

        lock.lock()
        if var cachedTextures = availableTextures[key], let texture = cachedTextures.popLast() {
            residentBytes -= estimatedRetainedBytes(for: texture)
            if cachedTextures.isEmpty {
                availableTextures.removeValue(forKey: key)
            } else {
                availableTextures[key] = cachedTextures
            }
            lock.unlock()
            return texture
        }
        lock.unlock()

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        return device.makeTexture(descriptor: descriptor)
    }

    func checkin(_ texture: MTLTexture) {
        let key = LayerSerializerStagingKey(
            width: texture.width,
            height: texture.height,
            pixelFormat: texture.pixelFormat
        )

        lock.lock()
        availableTextures[key, default: []].append(texture)
        residentBytes += estimatedRetainedBytes(for: texture)
        trimLocked(toMaxResidentBytes: maxRetainedBytes)
        lock.unlock()
    }

    func trim(toMaxResidentBytes maxBytes: Int) {
        lock.lock()
        maxRetainedBytes = max(0, maxBytes)
        trimLocked(toMaxResidentBytes: maxRetainedBytes)
        lock.unlock()
    }

    func purgeTextures(exceeding canvasSize: CanvasSize) {
        lock.lock()
        let keysToRemove = availableTextures.keys.filter { key in
            key.width > canvasSize.width || key.height > canvasSize.height
        }
        for key in keysToRemove {
            removeTextures(for: key)
        }
        trimLocked(toMaxResidentBytes: maxRetainedBytes)
        lock.unlock()
    }

    func purgeAll() {
        lock.lock()
        availableTextures.removeAll()
        residentBytes = 0
        lock.unlock()
    }

    func debugSnapshot() -> LayerSerializerStagingPoolSnapshot {
        lock.lock()
        let snapshot = LayerSerializerStagingPoolSnapshot(
            cachedTextureCount: availableTextures.values.reduce(0) { $0 + $1.count },
            residentBytes: residentBytes
        )
        lock.unlock()
        return snapshot
    }

    private func trimLocked(toMaxResidentBytes maxBytes: Int) {
        guard residentBytes > maxBytes else { return }

        let oversizedKeys = availableTextures.keys
            .sorted { lhs, rhs in
                estimatedRetainedBytes(for: lhs) > estimatedRetainedBytes(for: rhs)
            }

        for key in oversizedKeys {
            guard residentBytes > maxBytes else { break }
            removeTextures(for: key)
        }
    }

    private func removeTextures(for key: LayerSerializerStagingKey) {
        guard let removedTextures = availableTextures.removeValue(forKey: key) else {
            return
        }
        for texture in removedTextures {
            residentBytes -= estimatedRetainedBytes(for: texture)
        }
        residentBytes = max(0, residentBytes)
    }

    private func estimatedRetainedBytes(for key: LayerSerializerStagingKey) -> Int {
        estimatedRetainedBytes(
            width: key.width,
            height: key.height,
            pixelFormat: MTLPixelFormat(rawValue: key.pixelFormatRawValue) ?? .bgra8Unorm_srgb
        )
    }

    private func estimatedRetainedBytes(for texture: MTLTexture) -> Int {
        estimatedRetainedBytes(
            width: texture.width,
            height: texture.height,
            pixelFormat: texture.pixelFormat
        )
    }

    private func estimatedRetainedBytes(
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat
    ) -> Int {
        let bytesPerPixel: Int
        switch pixelFormat {
        case .r8Unorm:
            bytesPerPixel = 1
        case .bgra8Unorm, .bgra8Unorm_srgb:
            bytesPerPixel = 4
        default:
            bytesPerPixel = 4
        }
        return width * height * bytesPerPixel
    }
}

final class LayerTextureSerializer {
    private static let tiledTransferThresholdBytes = 64 * 1024 * 1024
    private static let transferTileLength = 1_024
    private let metalContext: MetalDeviceContext
    private let stagingPool: LayerSerializerStagingPool
    private let auditStore: PerformanceAuditStore

    init(
        metalContext: MetalDeviceContext,
        stagingPoolMaxResidentBytes: Int = 64 * 1024 * 1024,
        auditStore: PerformanceAuditStore = .shared
    ) {
        self.metalContext = metalContext
        self.auditStore = auditStore
        self.stagingPool = LayerSerializerStagingPool(
            device: metalContext.device,
            maxRetainedBytes: stagingPoolMaxResidentBytes
        )
    }

    private func readPixelData(
        from texture: MTLTexture,
        originX: Int,
        originY: Int,
        width: Int,
        height: Int
    ) -> Data {
        let bytesPerPixel = Self.bytesPerPixel(for: texture.pixelFormat)
        let bytesPerRow = width * bytesPerPixel
        var pixelData = Data(count: bytesPerRow * height)
        pixelData.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            texture.getBytes(
                baseAddress,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(originX, originY, width, height),
                mipmapLevel: 0
            )
        }
        return pixelData
    }

    private func makeSnapshot(
        from texture: MTLTexture,
        originX: Int,
        originY: Int,
        width: Int,
        height: Int
    ) -> LayerTextureSnapshot {
        let bytesPerPixel = Self.bytesPerPixel(for: texture.pixelFormat)
        let bytesPerRow = width * bytesPerPixel
        return LayerTextureSnapshot(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            pixelData: readPixelData(
                from: texture,
                originX: originX,
                originY: originY,
                width: width,
                height: height
            )
        )
    }

    private static func bytesPerPixel(for pixelFormat: MTLPixelFormat) -> Int {
        switch pixelFormat {
        case .r8Unorm:
            return 1
        case .bgra8Unorm, .bgra8Unorm_srgb:
            return 4
        default:
            return 4
        }
    }

    func snapshot(texture: MTLTexture) throws -> LayerTextureSnapshot {
        try snapshot(
            texture: texture,
            originX: 0,
            originY: 0,
            width: texture.width,
            height: texture.height
        )
    }

    /// Downsample on the GPU before readback. A half-size recording transfers one
    /// quarter of the pixels instead of copying the full canvas through CPU arrays.
    func downsampledSnapshot(texture: MTLTexture, divisor: Int) throws -> LayerTextureSnapshot {
        guard divisor > 1 else { return try snapshot(texture: texture) }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: max(1, texture.width / divisor), height: max(1, texture.height / divisor),
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let target = metalContext.device.makeTexture(descriptor: descriptor),
              let commandBuffer = metalContext.commandQueue.makeCommandBuffer() else {
            throw CocoaError(.fileReadUnknown)
        }
        let scaler = MPSImageBilinearScale(device: metalContext.device)
        scaler.encode(commandBuffer: commandBuffer, sourceTexture: texture, destinationTexture: target)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            throw commandBuffer.error ?? CocoaError(.fileReadUnknown)
        }
        return try snapshot(texture: target)
    }

    /// Freezes live GPU resources with one private-to-private blit. The returned textures can be
    /// read on a utility task while painting continues on the original layer textures.
    func cloneBatchForDeferredSnapshot(textures: [MTLTexture]) throws -> [MTLTexture] {
        guard !textures.isEmpty else { return [] }
        var clones: [MTLTexture] = []
        clones.reserveCapacity(textures.count)
        for source in textures {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: source.pixelFormat,
                width: source.width,
                height: source.height,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            descriptor.storageMode = .private
            guard let clone = metalContext.device.makeTexture(descriptor: descriptor) else {
                throw CocoaError(.fileWriteUnknown)
            }
            clones.append(clone)
        }

        guard let commandBuffer = metalContext.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeBlitCommandEncoder() else {
            throw CocoaError(.fileWriteUnknown)
        }
        for (source, clone) in zip(textures, clones) {
            encoder.copy(
                from: source,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: .init(x: 0, y: 0, z: 0),
                sourceSize: .init(width: source.width, height: source.height, depth: 1),
                to: clone,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: .init(x: 0, y: 0, z: 0)
            )
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            throw commandBuffer.error ?? CocoaError(.fileWriteUnknown)
        }
        return clones
    }

    func snapshotBatch(textures: [MTLTexture]) throws -> [LayerTextureSnapshot] {
        guard !textures.isEmpty else { return [] }
        if textures.contains(where: { Self.requiresTiledTransfer($0) }) {
            // Avoid retaining one full-size shared staging texture per layer.
            // Large canvases are intentionally serialized one tiled resource at a time.
            return try textures.map { try snapshot(texture: $0) }
        }
        let auditEnabled = auditStore.isRecordingEnabled
        let startedAt = auditEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if auditEnabled {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
                auditStore.recordDuration("LayerTextureSerializer.snapshotBatch(\(textures.count))", ms: ms)
            }
        }

        struct StagedBatchTexture {
            let index: Int
            let sourceTexture: MTLTexture
            let stagingTexture: MTLTexture
        }

        var snapshots = Array<LayerTextureSnapshot?>(repeating: nil, count: textures.count)
        var stagedTextures: [StagedBatchTexture] = []
        stagedTextures.reserveCapacity(textures.count)
        var commandBuffer: MTLCommandBuffer?
        var blitEncoder: MTLBlitCommandEncoder?

        do {
            for (index, texture) in textures.enumerated() {
                if texture.storageMode == .shared {
                    snapshots[index] = makeSnapshot(
                        from: texture,
                        originX: 0,
                        originY: 0,
                        width: texture.width,
                        height: texture.height
                    )
                    continue
                }

                if blitEncoder == nil {
                    guard
                        let createdCommandBuffer = metalContext.commandQueue.makeCommandBuffer(),
                        let createdBlitEncoder = createdCommandBuffer.makeBlitCommandEncoder()
                    else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    commandBuffer = createdCommandBuffer
                    blitEncoder = createdBlitEncoder
                }

                guard let stagingTexture = stagingPool.checkout(
                    width: texture.width,
                    height: texture.height,
                    pixelFormat: texture.pixelFormat
                ) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                stagedTextures.append(.init(index: index, sourceTexture: texture, stagingTexture: stagingTexture))

                let region = MTLRegionMake2D(0, 0, texture.width, texture.height)
                blitEncoder?.copy(
                    from: texture,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: region.origin,
                    sourceSize: region.size,
                    to: stagingTexture,
                    destinationSlice: 0,
                    destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )
            }

            if let blitEncoder, let commandBuffer {
                blitEncoder.endEncoding()
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()
            }
        } catch {
            for stagedTexture in stagedTextures {
                stagingPool.checkin(stagedTexture.stagingTexture)
            }
            throw error
        }

        for stagedTexture in stagedTextures {
            snapshots[stagedTexture.index] = makeSnapshot(
                from: stagedTexture.stagingTexture,
                originX: 0,
                originY: 0,
                width: stagedTexture.sourceTexture.width,
                height: stagedTexture.sourceTexture.height
            )
            stagingPool.checkin(stagedTexture.stagingTexture)
        }

        return try snapshots.enumerated().map { _, snapshot in
            guard let snapshot else { throw CocoaError(.fileWriteUnknown) }
            return snapshot
        }
    }

    func snapshot(
        texture: MTLTexture,
        originX: Int,
        originY: Int,
        width: Int,
        height: Int
    ) throws -> LayerTextureSnapshot {
        let auditEnabled = auditStore.isRecordingEnabled
        let startedAt = auditEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if auditEnabled {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
                auditStore.recordDuration("LayerTextureSerializer.snapshot", ms: ms)
            }
        }

        guard
            originX >= 0, originY >= 0,
            width > 0, height > 0,
            originX + width <= texture.width,
            originY + height <= texture.height
        else {
            throw CocoaError(.fileReadCorruptFile)
        }

        if texture.storageMode == .shared {
            return makeSnapshot(
                from: texture,
                originX: originX,
                originY: originY,
                width: width,
                height: height
            )
        }


        if Self.requiresTiledTransfer(
            width: width,
            height: height,
            pixelFormat: texture.pixelFormat
        ) {
            return try tiledSnapshot(
                texture: texture,
                originX: originX,
                originY: originY,
                width: width,
                height: height
            )
        }

        let region = MTLRegionMake2D(originX, originY, width, height)

        guard
            let stagingTexture = stagingPool.checkout(
                width: width,
                height: height,
                pixelFormat: texture.pixelFormat
            )
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer {
            stagingPool.checkin(stagingTexture)
        }

        guard
            let commandBuffer = metalContext.commandQueue.makeCommandBuffer(),
            let blitEncoder = commandBuffer.makeBlitCommandEncoder()
        else {
            throw CocoaError(.fileWriteUnknown)
        }

        blitEncoder.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: region.origin,
            sourceSize: region.size,
            to: stagingTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return makeSnapshot(
            from: stagingTexture,
            originX: 0,
            originY: 0,
            width: width,
            height: height
        )
    }

    func snapshotRegions(
        _ requests: [LayerTextureRegionSnapshotRequest]
    ) throws -> [LayerTextureSnapshot] {
        guard !requests.isEmpty else { return [] }
        for request in requests {
            guard
                request.originX >= 0,
                request.originY >= 0,
                request.width > 0,
                request.height > 0,
                request.originX + request.width <= request.texture.width,
                request.originY + request.height <= request.texture.height
            else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }

        // Keep large partial-history readbacks on the same bounded staging path as full
        // snapshots. A region request is not necessarily small on a large canvas.
        if requests.contains(where: {
            Self.requiresTiledTransfer(width: $0.width, height: $0.height, pixelFormat: $0.texture.pixelFormat)
        }) {
            return try requests.map {
                try snapshot(texture: $0.texture, originX: $0.originX, originY: $0.originY,
                    width: $0.width, height: $0.height)
            }
        }

        let auditEnabled = auditStore.isRecordingEnabled
        let startedAt = auditEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if auditEnabled {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
                auditStore.recordDuration(
                    "LayerTextureSerializer.snapshotRegions(\(requests.count))",
                    ms: ms
                )
            }
        }

        struct StagedRegion {
            var index: Int
            var texture: MTLTexture
        }

        var snapshots = Array<LayerTextureSnapshot?>(repeating: nil, count: requests.count)
        var stagedRegions: [StagedRegion] = []
        stagedRegions.reserveCapacity(requests.count)
        defer {
            for stagedRegion in stagedRegions {
                stagingPool.checkin(stagedRegion.texture)
            }
        }

        var commandBuffer: MTLCommandBuffer?
        var blitEncoder: MTLBlitCommandEncoder?
        for (index, request) in requests.enumerated() {
            if request.texture.storageMode == .shared {
                snapshots[index] = makeSnapshot(
                    from: request.texture,
                    originX: request.originX,
                    originY: request.originY,
                    width: request.width,
                    height: request.height
                )
                continue
            }

            if blitEncoder == nil {
                guard
                    let createdCommandBuffer = metalContext.commandQueue.makeCommandBuffer(),
                    let createdBlitEncoder = createdCommandBuffer.makeBlitCommandEncoder()
                else {
                    throw CocoaError(.fileReadUnknown)
                }
                commandBuffer = createdCommandBuffer
                blitEncoder = createdBlitEncoder
            }

            guard let stagingTexture = stagingPool.checkout(
                width: request.width,
                height: request.height,
                pixelFormat: request.texture.pixelFormat
            ) else {
                throw CocoaError(.fileReadUnknown)
            }
            stagedRegions.append(.init(index: index, texture: stagingTexture))
            blitEncoder?.copy(
                from: request.texture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: request.originX, y: request.originY, z: 0),
                sourceSize: MTLSize(width: request.width, height: request.height, depth: 1),
                to: stagingTexture,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
        }

        if let blitEncoder, let commandBuffer {
            blitEncoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }

        for stagedRegion in stagedRegions {
            let request = requests[stagedRegion.index]
            snapshots[stagedRegion.index] = makeSnapshot(
                from: stagedRegion.texture,
                originX: 0,
                originY: 0,
                width: request.width,
                height: request.height
            )
        }

        return try snapshots.map { snapshot in
            guard let snapshot else { throw CocoaError(.fileReadUnknown) }
            return snapshot
        }
    }

    func restore(
        snapshot: LayerTextureSnapshot,
        into texture: MTLTexture
    ) throws {
        try restore(
            snapshot: snapshot,
            into: texture,
            destinationX: 0,
            destinationY: 0
        )
    }

    func restore(
        snapshot: LayerTextureSnapshot,
        into texture: MTLTexture,
        destinationX: Int,
        destinationY: Int
    ) throws {
        let auditEnabled = auditStore.isRecordingEnabled
        let startedAt = auditEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if auditEnabled {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
                auditStore.recordDuration("LayerTextureSerializer.restore", ms: ms)
            }
        }

        guard
            destinationX >= 0, destinationY >= 0,
            destinationX + snapshot.width <= texture.width,
            destinationY + snapshot.height <= texture.height
        else {
            throw CocoaError(.fileReadCorruptFile)
        }


        if Self.requiresTiledTransfer(
            width: snapshot.width,
            height: snapshot.height,
            pixelFormat: texture.pixelFormat
        ) {
            try tiledRestore(
                snapshot: snapshot,
                into: texture,
                destinationX: destinationX,
                destinationY: destinationY
            )
            return
        }

        let region = MTLRegionMake2D(0, 0, snapshot.width, snapshot.height)
        guard
            let stagingTexture = stagingPool.checkout(
                width: snapshot.width,
                height: snapshot.height,
                pixelFormat: texture.pixelFormat
            )
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        defer {
            stagingPool.checkin(stagingTexture)
        }

        guard
            let commandBuffer = metalContext.commandQueue.makeCommandBuffer(),
            let blitEncoder = commandBuffer.makeBlitCommandEncoder()
        else {
            throw CocoaError(.fileReadCorruptFile)
        }

        snapshot.pixelData.withUnsafeBytes { rawBuffer in
            if let baseAddress = rawBuffer.baseAddress {
                stagingTexture.replace(
                    region: region,
                    mipmapLevel: 0,
                    withBytes: baseAddress,
                    bytesPerRow: snapshot.bytesPerRow
                )
            }
        }

        blitEncoder.copy(
            from: stagingTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: region.origin,
            sourceSize: region.size,
            to: texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: destinationX, y: destinationY, z: 0)
        )
        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    func restoreBatch(
        _ items: [(snapshot: LayerTextureSnapshot, texture: MTLTexture, destinationX: Int, destinationY: Int)]
    ) throws {
        guard !items.isEmpty else { return }
        if items.contains(where: {
            Self.requiresTiledTransfer(
                width: $0.snapshot.width,
                height: $0.snapshot.height,
                pixelFormat: $0.texture.pixelFormat
            )
        }) {
            for item in items {
                try restore(
                    snapshot: item.snapshot,
                    into: item.texture,
                    destinationX: item.destinationX,
                    destinationY: item.destinationY
                )
            }
            return
        }
        let auditEnabled = auditStore.isRecordingEnabled
        let startedAt = auditEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if auditEnabled {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
                auditStore.recordDuration("LayerTextureSerializer.restoreBatch(\(items.count))", ms: ms)
            }
        }

        guard let commandBuffer = metalContext.commandQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder()
        else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var checkedOutTextures: [MTLTexture] = []
        checkedOutTextures.reserveCapacity(items.count)

        do {
            for item in items {
                guard
                    item.destinationX >= 0,
                    item.destinationY >= 0,
                    item.destinationX + item.snapshot.width <= item.texture.width,
                    item.destinationY + item.snapshot.height <= item.texture.height
                else {
                    throw CocoaError(.fileReadCorruptFile)
                }

                guard let stagingTexture = stagingPool.checkout(
                    width: item.snapshot.width,
                    height: item.snapshot.height,
                    pixelFormat: item.texture.pixelFormat
                ) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                checkedOutTextures.append(stagingTexture)

                let region = MTLRegionMake2D(0, 0, item.snapshot.width, item.snapshot.height)
                item.snapshot.pixelData.withUnsafeBytes { rawBuffer in
                    if let baseAddress = rawBuffer.baseAddress {
                        stagingTexture.replace(
                            region: region,
                            mipmapLevel: 0,
                            withBytes: baseAddress,
                            bytesPerRow: item.snapshot.bytesPerRow
                        )
                    }
                }

                blitEncoder.copy(
                    from: stagingTexture,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: region.origin,
                    sourceSize: region.size,
                    to: item.texture,
                    destinationSlice: 0,
                    destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: item.destinationX, y: item.destinationY, z: 0)
                )
            }

            blitEncoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        } catch {
            for stagingTexture in checkedOutTextures {
                stagingPool.checkin(stagingTexture)
            }
            throw error
        }

        for stagingTexture in checkedOutTextures {
            stagingPool.checkin(stagingTexture)
        }
    }

    func samplePixel(texture: MTLTexture, x: Int, y: Int) throws -> RGBAColor {
        let auditEnabled = auditStore.isRecordingEnabled
        let startedAt = auditEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if auditEnabled {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
                auditStore.recordDuration("LayerTextureSerializer.samplePixel", ms: ms)
            }
        }

        guard
            x >= 0, y >= 0,
            x < texture.width, y < texture.height
        else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let region = MTLRegionMake2D(x, y, 1, 1)

        if texture.storageMode == .shared {
            var bytes = [UInt8](repeating: 0, count: 4)
            texture.getBytes(
                &bytes,
                bytesPerRow: 4,
                from: region,
                mipmapLevel: 0
            )

            return RGBAColor(
                red: Float(bytes[2]) / 255,
                green: Float(bytes[1]) / 255,
                blue: Float(bytes[0]) / 255,
                alpha: Float(bytes[3]) / 255
            )
        }

        guard
            let stagingTexture = stagingPool.checkout(
                width: 1,
                height: 1,
                pixelFormat: texture.pixelFormat
            )
        else {
            throw CocoaError(.fileReadUnknown)
        }
        defer {
            stagingPool.checkin(stagingTexture)
        }

        guard
            let commandBuffer = metalContext.commandQueue.makeCommandBuffer(),
            let blitEncoder = commandBuffer.makeBlitCommandEncoder()
        else {
            throw CocoaError(.fileReadUnknown)
        }

        blitEncoder.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: region.origin,
            sourceSize: region.size,
            to: stagingTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: 4)
        stagingTexture.getBytes(
            &bytes,
            bytesPerRow: 4,
            from: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0
        )

        return RGBAColor(
            red: Float(bytes[2]) / 255,
            green: Float(bytes[1]) / 255,
            blue: Float(bytes[0]) / 255,
            alpha: Float(bytes[3]) / 255
        )
    }

    func trimStagingPool(toMaxResidentBytes maxBytes: Int) {
        stagingPool.trim(toMaxResidentBytes: maxBytes)
    }

    func purgeStagingTextures(exceeding canvasSize: CanvasSize) {
        stagingPool.purgeTextures(exceeding: canvasSize)
    }

    func purgeAllStagingTextures() {
        stagingPool.purgeAll()
    }

    func stagingPoolDebugSnapshot() -> LayerSerializerStagingPoolSnapshot {
        stagingPool.debugSnapshot()
    }

    private static func requiresTiledTransfer(_ texture: MTLTexture) -> Bool {
        requiresTiledTransfer(
            width: texture.width,
            height: texture.height,
            pixelFormat: texture.pixelFormat
        )
    }

    private static func requiresTiledTransfer(
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat
    ) -> Bool {
        let bytesPerPixel = bytesPerPixel(for: pixelFormat)
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: bytesPerPixel)
        return pixelOverflow || byteOverflow || byteCount > tiledTransferThresholdBytes
    }

    private func tiledSnapshot(
        texture: MTLTexture,
        originX: Int,
        originY: Int,
        width: Int,
        height: Int
    ) throws -> LayerTextureSnapshot {
        let bytesPerPixel = Self.bytesPerPixel(for: texture.pixelFormat)
        let bytesPerRow = width * bytesPerPixel
        var pixelData = Data(count: bytesPerRow * height)
        guard let grid = TileGrid(
            canvasSize: CanvasSize(width: width, height: height),
            tileLength: Self.transferTileLength
        ) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        for intersection in grid.intersections(with: grid.canvasBounds) {
            let tile = intersection.canvasRegion
            guard let stagingTexture = stagingPool.checkout(
                width: tile.width,
                height: tile.height,
                pixelFormat: texture.pixelFormat
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
            defer { stagingPool.checkin(stagingTexture) }

            guard let commandBuffer = metalContext.commandQueue.makeCommandBuffer(),
                  let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
                throw CocoaError(.fileWriteUnknown)
            }
            blitEncoder.copy(
                from: texture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(
                    x: originX + tile.originX,
                    y: originY + tile.originY,
                    z: 0
                ),
                sourceSize: MTLSize(width: tile.width, height: tile.height, depth: 1),
                to: stagingTexture,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blitEncoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            guard commandBuffer.status == .completed else {
                throw commandBuffer.error ?? CocoaError(.fileReadUnknown)
            }

            pixelData.withUnsafeMutableBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                let destination = baseAddress.advanced(
                    by: (tile.originY * bytesPerRow) + (tile.originX * bytesPerPixel)
                )
                stagingTexture.getBytes(
                    destination,
                    bytesPerRow: bytesPerRow,
                    from: MTLRegionMake2D(0, 0, tile.width, tile.height),
                    mipmapLevel: 0
                )
            }
        }

        return LayerTextureSnapshot(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            pixelData: pixelData
        )
    }

    private func tiledRestore(
        snapshot: LayerTextureSnapshot,
        into texture: MTLTexture,
        destinationX: Int,
        destinationY: Int
    ) throws {
        let bytesPerPixel = Self.bytesPerPixel(for: texture.pixelFormat)
        guard snapshot.bytesPerRow >= snapshot.width * bytesPerPixel,
              snapshot.pixelData.count >= snapshot.bytesPerRow * snapshot.height,
              let grid = TileGrid(
                canvasSize: CanvasSize(width: snapshot.width, height: snapshot.height),
                tileLength: Self.transferTileLength
              ) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        for intersection in grid.intersections(with: grid.canvasBounds) {
            let tile = intersection.canvasRegion
            guard let stagingTexture = stagingPool.checkout(
                width: tile.width,
                height: tile.height,
                pixelFormat: texture.pixelFormat
            ) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            defer { stagingPool.checkin(stagingTexture) }

            snapshot.pixelData.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                let source = baseAddress.advanced(
                    by: (tile.originY * snapshot.bytesPerRow) + (tile.originX * bytesPerPixel)
                )
                stagingTexture.replace(
                    region: MTLRegionMake2D(0, 0, tile.width, tile.height),
                    mipmapLevel: 0,
                    withBytes: source,
                    bytesPerRow: snapshot.bytesPerRow
                )
            }

            guard let commandBuffer = metalContext.commandQueue.makeCommandBuffer(),
                  let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
                throw CocoaError(.fileReadCorruptFile)
            }
            blitEncoder.copy(
                from: stagingTexture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: tile.width, height: tile.height, depth: 1),
                to: texture,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(
                    x: destinationX + tile.originX,
                    y: destinationY + tile.originY,
                    z: 0
                )
            )
            blitEncoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            guard commandBuffer.status == .completed else {
                throw commandBuffer.error ?? CocoaError(.fileReadCorruptFile)
            }
        }
    }
}

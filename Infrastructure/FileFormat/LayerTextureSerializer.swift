import Foundation
import Metal

struct LayerTextureSnapshot: Codable, Sendable, Equatable {
    var width: Int
    var height: Int
    var bytesPerRow: Int
    var pixelData: Data
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
    private let metalContext: MetalDeviceContext
    private let stagingPool: LayerSerializerStagingPool
    private let bytesPerPixel = 4

    init(
        metalContext: MetalDeviceContext,
        stagingPoolMaxResidentBytes: Int = 64 * 1024 * 1024
    ) {
        self.metalContext = metalContext
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

    func snapshot(texture: MTLTexture) throws -> LayerTextureSnapshot {
        try snapshot(
            texture: texture,
            originX: 0,
            originY: 0,
            width: texture.width,
            height: texture.height
        )
    }

    func snapshotBatch(textures: [MTLTexture]) throws -> [LayerTextureSnapshot] {
        guard !textures.isEmpty else { return [] }
        let auditEnabled = PerformanceAuditStore.shared.isRecordingEnabled
        let startedAt = auditEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if auditEnabled {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
                PerformanceAuditStore.shared.recordDuration("LayerTextureSerializer.snapshotBatch(\(textures.count))", ms: ms)
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
        let auditEnabled = PerformanceAuditStore.shared.isRecordingEnabled
        let startedAt = auditEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if auditEnabled {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
                PerformanceAuditStore.shared.recordDuration("LayerTextureSerializer.snapshot", ms: ms)
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
        let auditEnabled = PerformanceAuditStore.shared.isRecordingEnabled
        let startedAt = auditEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if auditEnabled {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
                PerformanceAuditStore.shared.recordDuration("LayerTextureSerializer.restore", ms: ms)
            }
        }

        guard
            destinationX >= 0, destinationY >= 0,
            destinationX + snapshot.width <= texture.width,
            destinationY + snapshot.height <= texture.height
        else {
            throw CocoaError(.fileReadCorruptFile)
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
        _ items: [(snapshot: LayerTextureSnapshot, texture: MTLTexture)]
    ) throws {
        guard !items.isEmpty else { return }
        let auditEnabled = PerformanceAuditStore.shared.isRecordingEnabled
        let startedAt = auditEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if auditEnabled {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
                PerformanceAuditStore.shared.recordDuration("LayerTextureSerializer.restoreBatch(\(items.count))", ms: ms)
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
                    item.snapshot.width <= item.texture.width,
                    item.snapshot.height <= item.texture.height
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
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
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
        let auditEnabled = PerformanceAuditStore.shared.isRecordingEnabled
        let startedAt = auditEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if auditEnabled {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
                PerformanceAuditStore.shared.recordDuration("LayerTextureSerializer.samplePixel", ms: ms)
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
}

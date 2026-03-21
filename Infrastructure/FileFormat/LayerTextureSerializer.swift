import Foundation
import Foundation
import Foundation
import Foundation
import Foundation
import Foundation
import Foundation
import Metal

struct LayerTextureSnapshot: Codable, Sendable, Equatable {
    var width: Int
    var height: Int
    var bytesPerRow: Int
    var pixelData: Data
}

final class LayerTextureSerializer {
    func snapshot(texture: MTLTexture) throws -> LayerTextureSnapshot {
        try snapshot(
            texture: texture,
            originX: 0,
            originY: 0,
            width: texture.width,
            height: texture.height
        )
    }

    func snapshot(
        texture: MTLTexture,
        originX: Int,
        originY: Int,
        width: Int,
        height: Int
    ) throws -> LayerTextureSnapshot {
        guard
            originX >= 0, originY >= 0,
            width > 0, height > 0,
            originX + width <= texture.width,
            originY + height <= texture.height
        else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let region = MTLRegionMake2D(originX, originY, width, height)

        guard
            let stagingTexture = makeStagingTexture(
                width: width,
                height: height,
                device: texture.device,
                pixelFormat: texture.pixelFormat
            ),
            let commandQueue = texture.device.makeCommandQueue(),
            let commandBuffer = commandQueue.makeCommandBuffer(),
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

        var sourceBytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        stagingTexture.getBytes(
            &sourceBytes,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )

        return LayerTextureSnapshot(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            pixelData: Data(sourceBytes)
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
        guard
            destinationX >= 0, destinationY >= 0,
            destinationX + snapshot.width <= texture.width,
            destinationY + snapshot.height <= texture.height
        else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let region = MTLRegionMake2D(0, 0, snapshot.width, snapshot.height)
        guard
            let stagingTexture = makeStagingTexture(
                width: snapshot.width,
                height: snapshot.height,
                device: texture.device,
                pixelFormat: texture.pixelFormat
            ),
            let commandQueue = texture.device.makeCommandQueue(),
            let commandBuffer = commandQueue.makeCommandBuffer(),
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

    func samplePixel(texture: MTLTexture, x: Int, y: Int) throws -> RGBAColor {
        guard
            x >= 0, y >= 0,
            x < texture.width, y < texture.height
        else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let region = MTLRegionMake2D(x, y, 1, 1)
        guard
            let stagingTexture = makeStagingTexture(
                width: 1,
                height: 1,
                device: texture.device,
                pixelFormat: texture.pixelFormat
            ),
            let commandQueue = texture.device.makeCommandQueue(),
            let commandBuffer = commandQueue.makeCommandBuffer(),
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

    private func makeStagingTexture(
        width: Int,
        height: Int,
        device: MTLDevice,
        pixelFormat: MTLPixelFormat
    ) -> MTLTexture? {
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
}

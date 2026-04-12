import Foundation
import Metal
final class StageOneLayerSurfaceStore {
    private var surfacesByLayerID: [LayerID: LayerSurfaceRecord] = [:]
    private var texturesBySurfaceID: [LayerSurfaceID: MTLTexture] = [:]

    func surfaceRecords(for document: ArtDocument) -> [LayerSurfaceRecord] {
        document.layers.map { layer in
            if let existing = surfacesByLayerID[layer.id] {
                if existing.layerName == layer.name,
                   existing.isVisible == layer.isVisible,
                   existing.opacity == layer.opacity {
                    return existing
                }
                let updated = LayerSurfaceRecord(
                    surfaceID: existing.surfaceID,
                    layerID: existing.layerID,
                    layerName: layer.name,
                    isVisible: layer.isVisible,
                    opacity: layer.opacity,
                    descriptor: existing.descriptor
                )
                surfacesByLayerID[layer.id] = updated
                return updated
            }

            let created = LayerSurfaceRecord(
                surfaceID: LayerSurfaceID(),
                layerID: layer.id,
                layerName: layer.name,
                isVisible: layer.isVisible,
                opacity: layer.opacity,
                descriptor: .stageOneCanvas(
                    width: document.canvasSize.width,
                    height: document.canvasSize.height
                )
            )

            surfacesByLayerID[layer.id] = created
            return created
        }
    }

    func prepareTextures(
        for document: ArtDocument,
        metal: MetalDeviceContext
    ) {
        let records = surfaceRecords(for: document)

        for record in records where texturesBySurfaceID[record.surfaceID] == nil {
            guard let texture = makeTexture(for: record, metal: metal) else {
                continue
            }

            clearTexture(texture, metal: metal)
            texturesBySurfaceID[record.surfaceID] = texture
        }

        let validLayerIDs = Set(document.layers.map(\.id))
        let removedLayerIDs = surfacesByLayerID.keys.filter { !validLayerIDs.contains($0) }

        for layerID in removedLayerIDs {
            if let surfaceID = surfacesByLayerID[layerID]?.surfaceID {
                texturesBySurfaceID.removeValue(forKey: surfaceID)
            }
            surfacesByLayerID.removeValue(forKey: layerID)
        }

    }

    func texture(for surfaceID: LayerSurfaceID) -> MTLTexture? {
        texturesBySurfaceID[surfaceID]
    }

    func swapTexture(
        for surfaceID: LayerSurfaceID,
        with texture: MTLTexture
    ) {
        texturesBySurfaceID[surfaceID] = texture
    }

    func surfaceID(for layerID: LayerID) -> LayerSurfaceID? {
        surfacesByLayerID[layerID]?.surfaceID
    }

    func copyTexture(from sourceLayerID: LayerID, to destinationLayerID: LayerID, metal: MetalDeviceContext) {
        guard
            let sourceSurfaceID = surfaceID(for: sourceLayerID),
            let destinationSurfaceID = surfaceID(for: destinationLayerID),
            let sourceTexture = texture(for: sourceSurfaceID),
            let destinationTexture = texture(for: destinationSurfaceID)
        else {
            return
        }

        copyTexture(
            from: sourceTexture,
            to: destinationTexture,
            metal: metal,
            waitUntilCompleted: true
        )
    }

    func copyTexture(
        from sourceTexture: MTLTexture,
        to destinationTexture: MTLTexture,
        metal: MetalDeviceContext
    ) {
        copyTexture(
            from: sourceTexture,
            to: destinationTexture,
            metal: metal,
            waitUntilCompleted: true
        )
    }

    func copyTextureAsync(
        from sourceTexture: MTLTexture,
        to destinationTexture: MTLTexture,
        metal: MetalDeviceContext
    ) {
        copyTexture(
            from: sourceTexture,
            to: destinationTexture,
            metal: metal,
            waitUntilCompleted: false
        )
    }

    private func copyTexture(
        from sourceTexture: MTLTexture,
        to destinationTexture: MTLTexture,
        metal: MetalDeviceContext,
        waitUntilCompleted: Bool
    ) {
        guard
            let commandBuffer = metal.commandQueue.makeCommandBuffer(),
            let blitEncoder = commandBuffer.makeBlitCommandEncoder()
        else {
            return
        }

        let size = MTLSize(width: sourceTexture.width, height: sourceTexture.height, depth: 1)
        blitEncoder.copy(
            from: sourceTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: size,
            to: destinationTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()
        commandBuffer.commit()
        if waitUntilCompleted {
            commandBuffer.waitUntilCompleted()
        }
    }

    func reset() {
        surfacesByLayerID.removeAll()
        texturesBySurfaceID.removeAll()
    }

    func makeTexture(
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat = .bgra8Unorm_srgb,
        usage: MTLTextureUsage = [.shaderRead, .shaderWrite, .renderTarget],
        storageMode: MTLStorageMode = .private,
        metal: MetalDeviceContext
    ) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = usage
        descriptor.storageMode = storageMode
        return metal.device.makeTexture(descriptor: descriptor)
    }

    private func makeTexture(
        for record: LayerSurfaceRecord,
        metal: MetalDeviceContext
    ) -> MTLTexture? {
        makeTexture(
            width: record.descriptor.width,
            height: record.descriptor.height,
            metal: metal
        )
    }

    private func clearTexture(
        _ texture: MTLTexture,
        metal: MetalDeviceContext
    ) {
        guard
            let commandBuffer = metal.commandQueue.makeCommandBuffer()
        else {
            return
        }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 0,
            green: 0,
            blue: 0,
            alpha: 0
        )

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        encoder.endEncoding()
        commandBuffer.commit()
    }
}

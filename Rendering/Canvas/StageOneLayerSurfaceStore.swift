import Foundation
import Metal

private enum LayerSurfaceContentState {
    case knownTransparent
    case unknown
}

final class StageOneLayerSurfaceStore {
    private var surfacesByLayerID: [LayerID: LayerSurfaceRecord] = [:]
    private var texturesBySurfaceID: [LayerSurfaceID: MTLTexture] = [:]
    private var contentStateByLayerID: [LayerID: LayerSurfaceContentState] = [:]
    private var maskTexturesByLayerID: [LayerID: MTLTexture] = [:]
#if DEBUG
    var debugPreventsTextureAllocation = false

    func debugRemoveContentTexture(for layerID: LayerID) {
        guard let surfaceID = surfacesByLayerID[layerID]?.surfaceID else { return }
        texturesBySurfaceID.removeValue(forKey: surfaceID)
    }
#endif

    func surfaceRecords(for document: ArtDocument) -> [LayerSurfaceRecord] {
        document.layers.compactMap { layer in
            guard layer.isPaintLayer else { return nil }
            let effectiveVisibility = document.isLayerEffectivelyVisible(layer.id)
            let effectiveOpacity = document.effectiveLayerOpacity(layer.id)
            if let existing = surfacesByLayerID[layer.id] {
                if existing.layerName == layer.name,
                   existing.isVisible == effectiveVisibility,
                   existing.opacity == effectiveOpacity,
                   existing.blendMode == layer.blendMode,
                   existing.clipTargetLayerID == layer.clipTargetLayerID {
                    return existing
                }
                let updated = LayerSurfaceRecord(
                    surfaceID: existing.surfaceID,
                    layerID: existing.layerID,
                    layerName: layer.name,
                    isVisible: effectiveVisibility,
                    opacity: effectiveOpacity,
                    blendMode: layer.blendMode,
                    clipTargetLayerID: layer.clipTargetLayerID,
                    descriptor: existing.descriptor
                )
                surfacesByLayerID[layer.id] = updated
                return updated
            }

            let created = LayerSurfaceRecord(
                surfaceID: LayerSurfaceID(),
                layerID: layer.id,
                layerName: layer.name,
                isVisible: effectiveVisibility,
                opacity: effectiveOpacity,
                blendMode: layer.blendMode,
                clipTargetLayerID: layer.clipTargetLayerID,
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
#if DEBUG
            if debugPreventsTextureAllocation { continue }
#endif
            guard let texture = makeTexture(for: record, metal: metal) else {
                continue
            }

            clearTexture(texture, metal: metal)
            texturesBySurfaceID[record.surfaceID] = texture
            contentStateByLayerID[record.layerID] = .knownTransparent
        }

        for layer in document.paintLayers where layer.mask != nil && maskTexturesByLayerID[layer.id] == nil {
            guard let texture = makeTexture(
                width: document.canvasSize.width,
                height: document.canvasSize.height,
                pixelFormat: .r8Unorm,
                usage: [.shaderRead, .shaderWrite, .renderTarget],
                storageMode: .private,
                metal: metal
            ) else {
                continue
            }
            clearTexture(texture, value: 1, metal: metal)
            maskTexturesByLayerID[layer.id] = texture
        }

        let validLayerIDs = Set(document.layers.filter(\.isPaintLayer).map(\.id))
        let removedLayerIDs = surfacesByLayerID.keys.filter { !validLayerIDs.contains($0) }

        for layerID in removedLayerIDs {
            if let surfaceID = surfacesByLayerID[layerID]?.surfaceID {
                texturesBySurfaceID.removeValue(forKey: surfaceID)
            }
            surfacesByLayerID.removeValue(forKey: layerID)
            contentStateByLayerID.removeValue(forKey: layerID)
            maskTexturesByLayerID.removeValue(forKey: layerID)
        }

        let unmaskedLayerIDs = maskTexturesByLayerID.keys.filter { layerID in
            document.layers.first(where: { $0.id == layerID })?.mask == nil
        }
        for layerID in unmaskedLayerIDs {
            maskTexturesByLayerID.removeValue(forKey: layerID)
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
        if let layerID = surfacesByLayerID.first(where: { $0.value.surfaceID == surfaceID })?.key {
            markContentUnknown(for: layerID)
        }
    }

    func surfaceID(for layerID: LayerID) -> LayerSurfaceID? {
        surfacesByLayerID[layerID]?.surfaceID
    }

    func maskTexture(for layerID: LayerID) -> MTLTexture? {
        maskTexturesByLayerID[layerID]
    }

    func setMaskTexture(_ texture: MTLTexture?, for layerID: LayerID) {
        maskTexturesByLayerID[layerID] = texture
    }

    func removeMaskTexture(for layerID: LayerID) {
        maskTexturesByLayerID.removeValue(forKey: layerID)
    }

    func fillMaskTexture(for layerID: LayerID, value: Float, metal: MetalDeviceContext) {
        guard let texture = maskTexturesByLayerID[layerID] else { return }
        clearTexture(texture, value: Double(min(max(value, 0), 1)), metal: metal)
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
        contentStateByLayerID[destinationLayerID] = contentStateByLayerID[sourceLayerID] ?? .unknown
    }

    func copyMaskTexture(from sourceLayerID: LayerID, to destinationLayerID: LayerID, metal: MetalDeviceContext) {
        guard let sourceTexture = maskTexturesByLayerID[sourceLayerID],
              let destinationTexture = maskTexturesByLayerID[destinationLayerID] else {
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

    @discardableResult
    func copyTextures(
        _ copies: [(source: MTLTexture, destination: MTLTexture)],
        metal: MetalDeviceContext
    ) -> Bool {
        guard !copies.isEmpty else { return true }
        guard copies.allSatisfy({ copy in
            copy.source.width == copy.destination.width
                && copy.source.height == copy.destination.height
                && copy.source.pixelFormat == copy.destination.pixelFormat
        }) else {
            return false
        }
        guard
            let commandBuffer = metal.commandQueue.makeCommandBuffer(),
            let blitEncoder = commandBuffer.makeBlitCommandEncoder()
        else {
            return false
        }

        for copy in copies {
            blitEncoder.copy(
                from: copy.source,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: copy.source.width, height: copy.source.height, depth: 1),
                to: copy.destination,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
        }

        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed
    }

    func copyTextureRegion(
        from sourceTexture: MTLTexture,
        to destinationTexture: MTLTexture,
        sourceOriginX: Int,
        sourceOriginY: Int,
        width: Int,
        height: Int,
        destinationOriginX: Int,
        destinationOriginY: Int,
        metal: MetalDeviceContext,
        waitUntilCompleted: Bool = true
    ) {
        guard width > 0, height > 0 else {
            return
        }

        guard
            sourceOriginX >= 0,
            sourceOriginY >= 0,
            destinationOriginX >= 0,
            destinationOriginY >= 0,
            sourceOriginX + width <= sourceTexture.width,
            sourceOriginY + height <= sourceTexture.height,
            destinationOriginX + width <= destinationTexture.width,
            destinationOriginY + height <= destinationTexture.height
        else {
            return
        }

        guard
            let commandBuffer = metal.commandQueue.makeCommandBuffer(),
            let blitEncoder = commandBuffer.makeBlitCommandEncoder()
        else {
            return
        }

        blitEncoder.copy(
            from: sourceTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: sourceOriginX, y: sourceOriginY, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: destinationTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: destinationOriginX, y: destinationOriginY, z: 0)
        )
        blitEncoder.endEncoding()
        commandBuffer.commit()
        if waitUntilCompleted {
            commandBuffer.waitUntilCompleted()
        }
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
        contentStateByLayerID.removeAll()
        maskTexturesByLayerID.removeAll()
    }

    func isKnownTransparent(layerID: LayerID) -> Bool {
        contentStateByLayerID[layerID] == .knownTransparent
    }

    func markKnownTransparent(for layerID: LayerID) {
        contentStateByLayerID[layerID] = .knownTransparent
    }

    func markContentUnknown(for layerID: LayerID) {
        contentStateByLayerID[layerID] = .unknown
    }

    func markContentUnknown<S: Sequence>(for layerIDs: S) where S.Element == LayerID {
        for layerID in layerIDs {
            markContentUnknown(for: layerID)
        }
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
        clearTexture(texture, value: 0, metal: metal)
    }

    private func clearTexture(
        _ texture: MTLTexture,
        value: Double,
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
            red: value,
            green: value,
            blue: value,
            alpha: value
        )

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        encoder.endEncoding()
        commandBuffer.commit()
    }
}

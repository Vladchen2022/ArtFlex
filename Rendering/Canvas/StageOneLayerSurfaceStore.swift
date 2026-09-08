import Foundation
import Metal

private enum LayerSurfaceContentState {
    case knownTransparent
    case unknown
}

private final class LayerTextureResource {
    let dense: MTLTexture?
    let sparse: SparseLayerTexture?
    var texture: MTLTexture { sparse?.texture ?? dense! }
    init(_ texture: MTLTexture) { dense = texture; sparse = nil }
    init(_ sparse: SparseLayerTexture) { self.sparse = sparse; dense = nil }
}

final class StageOneLayerSurfaceStore {
    private var surfacesByLayerID: [LayerID: LayerSurfaceRecord] = [:]
    private var texturesBySurfaceID: [LayerSurfaceID: LayerTextureResource] = [:]
    private var contentStateByLayerID: [LayerID: LayerSurfaceContentState] = [:]
    private var maskTexturesByLayerID: [LayerID: LayerTextureResource] = [:]
    private var metalContext: MetalDeviceContext?
    private var changes: [LayerResourceKey: LayerChangeJournal] = [:]
    private var usesSparseStorage: Bool
    private var sparseScanner: SparseTileScanner?
    private var sparseScanCandidates: [LayerSurfaceID: Set<TileCoordinate>] = [:]
    private(set) var contentPixelFormat: MTLPixelFormat = .bgra8Unorm_srgb
    private(set) var lastResourceError: String?

    init(usesSparseStorage: Bool = false) { self.usesSparseStorage = usesSparseStorage }

    var allocatedPixelBytes: Int {
        texturesBySurfaceID.values.reduce(0) { total, resource in
            total + (resource.sparse?.allocatedBytes ?? resource.texture.allocatedSize)
        } + maskTexturesByLayerID.values.reduce(0) { $0 + $1.texture.allocatedSize }
    }

    func sharedCopy() -> StageOneLayerSurfaceStore {
        let result = StageOneLayerSurfaceStore(usesSparseStorage: usesSparseStorage)
        result.adoptContents(of: self)
        return result
    }

    func changeJournal(for key: LayerResourceKey) -> LayerChangeJournal {
        if let journal = changes[key] { return journal }
        let journal = LayerChangeJournal()
        changes[key] = journal
        return journal
    }

    private func recordChange(for key: LayerResourceKey, region: PixelRegion? = nil) {
        var journal = changeJournal(for: key)
        if let region, let record = surfacesByLayerID[key.layerID] {
            journal.mark(region, canvasSize: .init(width: record.descriptor.width, height: record.descriptor.height))
        } else { journal.markAll() }
        changes[key] = journal
    }
#if DEBUG
    var debugPreventsTextureAllocation = false

    func debugRemoveContentTexture(for layerID: LayerID) {
        guard let surfaceID = surfacesByLayerID[layerID]?.surfaceID else { return }
        texturesBySurfaceID.removeValue(forKey: surfaceID)
    }
#endif

    func surfaceRecords(for document: ArtDocument) -> [LayerSurfaceRecord] {
        contentPixelFormat = document.colorStandard.pixelFormat.encoding.metalPixelFormat
        return document.layers.compactMap { layer in
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
                    height: document.canvasSize.height,
                    format: document.colorStandard.pixelFormat
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
        metalContext = metal
        let records = surfaceRecords(for: document)

        for record in records where texturesBySurfaceID[record.surfaceID] == nil {
#if DEBUG
            if debugPreventsTextureAllocation { continue }
#endif
            if usesSparseStorage, record.descriptor.width * record.descriptor.height >= 1024 * 1024,
               let sparse = SparseLayerTexture(
                size: .init(width: record.descriptor.width, height: record.descriptor.height),
                format: contentPixelFormat, metal: metal
            ) {
                texturesBySurfaceID[record.surfaceID] = LayerTextureResource(sparse)
                contentStateByLayerID[record.layerID] = .knownTransparent
                continue
            }
            guard let texture = makeTexture(for: record, metal: metal) else {
                continue
            }

            clearTexture(texture, metal: metal)
            texturesBySurfaceID[record.surfaceID] = LayerTextureResource(texture)
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
            maskTexturesByLayerID[layer.id] = LayerTextureResource(texture)
        }

        let validLayerIDs = Set(document.layers.filter(\.isPaintLayer).map(\.id))
        let removedLayerIDs = surfacesByLayerID.keys.filter { !validLayerIDs.contains($0) }

        for layerID in removedLayerIDs {
            if let surfaceID = surfacesByLayerID[layerID]?.surfaceID {
                texturesBySurfaceID.removeValue(forKey: surfaceID)
                sparseScanCandidates.removeValue(forKey: surfaceID)
            }
            surfacesByLayerID.removeValue(forKey: layerID)
            contentStateByLayerID.removeValue(forKey: layerID)
            maskTexturesByLayerID.removeValue(forKey: layerID)
            changes.removeValue(forKey: .init(layerID: layerID, kind: .content))
            changes.removeValue(forKey: .init(layerID: layerID, kind: .mask))
        }

        let unmaskedLayerIDs = maskTexturesByLayerID.keys.filter { layerID in
            document.layers.first(where: { $0.id == layerID })?.mask == nil
        }
        for layerID in unmaskedLayerIDs {
            maskTexturesByLayerID.removeValue(forKey: layerID)
        }

    }

    func texture(for surfaceID: LayerSurfaceID) -> MTLTexture? {
        writableTexture(for: surfaceID, region: nil)
    }

    /// Sampling, serialization and GPU-copy sources must use this accessor.
    func readTexture(for surfaceID: LayerSurfaceID) -> MTLTexture? {
        texturesBySurfaceID[surfaceID]?.texture
    }

    /// An old surface may become reusable scratch only when no branch owns it.
    func canRecycleTexture(for surfaceID: LayerSurfaceID) -> Bool {
        guard texturesBySurfaceID[surfaceID]?.sparse == nil else { return false }
        return isKnownUniquelyReferenced(&texturesBySurfaceID[surfaceID])
    }

    /// Converts a completed result, never a still-writable scratch texture. Failure keeps the
    /// exact dense result; an optimization must not reject a successfully rendered stroke.
    func compactTexture(for surfaceID: LayerSurfaceID) {
        guard usesSparseStorage, let metal = metalContext,
              SparseLayerTexture.isSupported(by: metal.device),
              let resource = texturesBySurfaceID[surfaceID],
              resource.texture.width * resource.texture.height >= 1024 * 1024 else { return }
        let texture = resource.texture
        guard texture.pixelFormat == .bgra8Unorm_srgb || texture.pixelFormat == .rgba16Float else { return }
        do {
            if sparseScanner == nil { sparseScanner = try SparseTileScanner(metal: metal) }
            let tile = metal.device.sparseTileSize(with: .type2D, pixelFormat: texture.pixelFormat, sampleCount: 1)
            let occupied = try sparseScanner!.occupiedTiles(in: texture, tileSize: tile,
                candidates: sparseScanCandidates.removeValue(forKey: surfaceID))
            let denseBytes = texture.width * texture.height * (texture.pixelFormat == .rgba16Float ? 8 : 4)
            guard max(occupied.count, 1) * metal.device.sparseTileSizeInBytes < denseBytes * 3 / 4 else { return }
            if let sparse = resource.sparse, sparse.mappedTiles == occupied { return }
            let sparse = try SparseLayerTexture.copying(texture, tiles: occupied, metal: metal)
            texturesBySurfaceID[surfaceID] = LayerTextureResource(sparse)
        } catch { lastResourceError = error.localizedDescription }
    }

    func readMaskTexture(for layerID: LayerID) -> MTLTexture? {
        maskTexturesByLayerID[layerID]?.texture
    }

    func writableTexture(for surfaceID: LayerSurfaceID, region: PixelRegion?) -> MTLTexture? {
        guard texturesBySurfaceID[surfaceID] != nil else { return nil }
        sparseScanCandidates.removeValue(forKey: surfaceID)
        do {
            if !isKnownUniquelyReferenced(&texturesBySurfaceID[surfaceID]) {
                texturesBySurfaceID[surfaceID] = try cloneResource(texturesBySurfaceID[surfaceID]!)
            }
            let resource = texturesBySurfaceID[surfaceID]!
            let bounds = region ?? PixelRegion(originX: 0, originY: 0,
                                                width: resource.texture.width, height: resource.texture.height)
            try resource.sparse?.prepareForWrite(in: bounds)
            if let layerID = surfacesByLayerID.first(where: { $0.value.surfaceID == surfaceID })?.key {
                recordChange(for: .init(layerID: layerID, kind: .content), region: region)
            }
            return resource.texture
        } catch {
            lastResourceError = error.localizedDescription
            return nil
        }
    }

    private func cloneResource(_ resource: LayerTextureResource) throws -> LayerTextureResource {
        if let sparse = resource.sparse { return LayerTextureResource(try sparse.cloned()) }
        guard let metal = metalContext,
              let clone = makeTexture(width: resource.texture.width, height: resource.texture.height,
                                      pixelFormat: resource.texture.pixelFormat, metal: metal),
              copyTextures([(resource.texture, clone)], metal: metal) else {
            throw CanvasResourceError(message: "无法分离共享图层；其他方案及原像素未修改")
        }
        return LayerTextureResource(clone)
    }

    func swapTexture(
        for surfaceID: LayerSurfaceID,
        with texture: MTLTexture,
        changedRegion: PixelRegion? = nil
    ) {
        sparseScanCandidates.removeValue(forKey: surfaceID)
        if let old = texturesBySurfaceID[surfaceID]?.sparse,
           let changedRegion, let metal = metalContext,
           old.texture.pixelFormat == texture.pixelFormat,
           old.texture.width == texture.width, old.texture.height == texture.height {
            let tile = metal.device.sparseTileSize(with: .type2D, pixelFormat: texture.pixelFormat, sampleCount: 1)
            let bounds = PixelRegion(originX: 0, originY: 0, width: texture.width, height: texture.height)
            var candidates = old.mappedTiles
            if let area = changedRegion.intersection(with: bounds) {
                for y in (area.originY / tile.height)...((area.maxY - 1) / tile.height) {
                    for x in (area.originX / tile.width)...((area.maxX - 1) / tile.width) {
                        candidates.insert(.init(x: x, y: y))
                    }
                }
            }
            sparseScanCandidates[surfaceID] = candidates
        }
        texturesBySurfaceID[surfaceID] = LayerTextureResource(texture)
        if let layerID = surfacesByLayerID.first(where: { $0.value.surfaceID == surfaceID })?.key {
            contentStateByLayerID[layerID] = .unknown
            recordChange(for: .init(layerID: layerID, kind: .content), region: changedRegion)
        }
    }

    func surfaceID(for layerID: LayerID) -> LayerSurfaceID? {
        surfacesByLayerID[layerID]?.surfaceID
    }

    func maskTexture(for layerID: LayerID) -> MTLTexture? {
        guard maskTexturesByLayerID[layerID] != nil else { return nil }
        do {
            if !isKnownUniquelyReferenced(&maskTexturesByLayerID[layerID]) {
                maskTexturesByLayerID[layerID] = try cloneResource(maskTexturesByLayerID[layerID]!)
            }
            recordChange(for: .init(layerID: layerID, kind: .mask))
            return maskTexturesByLayerID[layerID]?.texture
        } catch {
            lastResourceError = error.localizedDescription
            return nil
        }
    }

    func setMaskTexture(_ texture: MTLTexture?, for layerID: LayerID) {
        maskTexturesByLayerID[layerID] = texture.map(LayerTextureResource.init)
        recordChange(for: .init(layerID: layerID, kind: .mask))
    }

    func removeMaskTexture(for layerID: LayerID) {
        maskTexturesByLayerID.removeValue(forKey: layerID)
    }

    func fillMaskTexture(for layerID: LayerID, value: Float, metal: MetalDeviceContext) {
        guard let texture = maskTexture(for: layerID) else { return }
        clearTexture(texture, value: Double(min(max(value, 0), 1)), metal: metal)
    }

    func copyTexture(from sourceLayerID: LayerID, to destinationLayerID: LayerID, metal: MetalDeviceContext) {
        guard
            let sourceSurfaceID = surfaceID(for: sourceLayerID),
            let destinationSurfaceID = surfaceID(for: destinationLayerID),
            let sourceTexture = readTexture(for: sourceSurfaceID),
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
        guard let sourceTexture = readMaskTexture(for: sourceLayerID),
              let destinationTexture = maskTexture(for: destinationLayerID) else {
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
        changes.removeAll()
        sparseScanCandidates.removeAll()
    }

    /// Adopts already validated resources without allocating a second set of surfaces.
    func adoptContents(of prepared: StageOneLayerSurfaceStore) {
        sparseScanCandidates.removeAll()
        surfacesByLayerID = prepared.surfacesByLayerID
        texturesBySurfaceID = prepared.texturesBySurfaceID
        contentStateByLayerID = prepared.contentStateByLayerID
        maskTexturesByLayerID = prepared.maskTexturesByLayerID
        metalContext = prepared.metalContext
        contentPixelFormat = prepared.contentPixelFormat
        changes = prepared.changes
        usesSparseStorage = usesSparseStorage || prepared.usesSparseStorage
    }

    func isKnownTransparent(layerID: LayerID) -> Bool {
        contentStateByLayerID[layerID] == .knownTransparent
    }

    func markKnownTransparent(for layerID: LayerID) {
        contentStateByLayerID[layerID] = .knownTransparent
    }

    func markContentUnknown(for layerID: LayerID, recordsChange: Bool = true) {
        contentStateByLayerID[layerID] = .unknown
        if recordsChange { recordChange(for: .init(layerID: layerID, kind: .content)) }
    }

    func markContentUnknown<S: Sequence>(for layerIDs: S, recordsChange: Bool = true) where S.Element == LayerID {
        for layerID in layerIDs {
            markContentUnknown(for: layerID, recordsChange: recordsChange)
        }
    }

    func makeTexture(
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat? = nil,
        usage: MTLTextureUsage = [.shaderRead, .shaderWrite, .renderTarget],
        storageMode: MTLStorageMode = .private,
        metal: MetalDeviceContext
    ) -> MTLTexture? {
        metalContext = metal
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat ?? contentPixelFormat,
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

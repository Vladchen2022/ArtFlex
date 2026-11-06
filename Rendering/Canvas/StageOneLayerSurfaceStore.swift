import Foundation
import Metal

private enum LayerSurfaceContentState {
    case knownTransparent
    case unknown
}

fileprivate final class LayerTextureResource {
    let dense: MTLTexture?
    let sparse: SparseLayerTexture?
    var texture: MTLTexture { sparse?.texture ?? dense! }
    init(_ texture: MTLTexture) { dense = texture; sparse = nil }
    init(_ sparse: SparseLayerTexture) { self.sparse = sparse; dense = nil }
}

final class StageOneLayerSurfaceStore {
    /// Retains the resource owner, including its sparse heap. Subsequent mutable access
    /// sees a second owner and detaches; readers can safely cross the worker boundary.
    final class FrozenRead: @unchecked Sendable {
        fileprivate let resource: LayerTextureResource
        var texture: MTLTexture { resource.texture }
        var allocatedBytes: Int { resource.sparse?.allocatedBytes ?? texture.allocatedSize }
        var mappedRegions: [PixelRegion]? { resource.sparse.map { $0.regions(for: $0.mappedTiles) } }
        fileprivate init(_ resource: LayerTextureResource) { self.resource = resource }
    }

    func freezeRead(for key: LayerResourceKey) throws -> FrozenRead {
        let resource = key.kind == .mask ? maskTexturesByLayerID[key.layerID]
            : surfacesByLayerID[key.layerID].flatMap { texturesBySurfaceID[$0.surfaceID] }
        guard let resource else { throw CanvasResourceError(message: "无法冻结缺失的图层资源") }
        return FrozenRead(resource)
    }

    /// Full history restores preserve sparse residency instead of allocating a dense layer
    /// for mostly transparent checkpoints. Scanning uses native row comparisons, not pixels.
    func prepareSnapshotResource(_ snapshot: LayerTextureSnapshot, metal: MetalDeviceContext) throws -> FrozenRead {
#if DEBUG
        if debugPreventsTextureAllocation || debugRejectsTextureCommands { throw CanvasResourceError(message: "无法准备恢复资源") }
#endif
        let format = snapshot.encoding.metalPixelFormat
        let bpp = snapshot.encoding.bytesPerPixel
        if usesSparseStorage, snapshot.width * snapshot.height >= 1024 * 1024,
           format == .bgra8Unorm_srgb || format == .rgba16Float,
           snapshot.bytesPerRow == snapshot.width * bpp,
           snapshot.pixelData.count == snapshot.bytesPerRow * snapshot.height,
           SparseLayerTexture.isSupported(by: metal.device) {
            let tile = metal.device.sparseTileSize(with: .type2D, pixelFormat: format, sampleCount: 1)
            var occupied = Set<TileCoordinate>()
            let zeros = Data(count: tile.width * bpp)
            snapshot.pixelData.withUnsafeBytes { pixels in
                zeros.withUnsafeBytes { blank in
                    for y in stride(from: 0, to: snapshot.height, by: tile.height) {
                        for x in stride(from: 0, to: snapshot.width, by: tile.width) {
                            let count = min(tile.width, snapshot.width - x) * bpp
                            for row in y..<min(y + tile.height, snapshot.height) {
                                if memcmp(pixels.baseAddress! + row * snapshot.bytesPerRow + x * bpp, blank.baseAddress!, count) != 0 {
                                    occupied.insert(.init(x: x / tile.width, y: y / tile.height)); break
                                }
                            }
                        }
                    }
                }
            }
            if max(1, occupied.count) * metal.device.sparseTileSizeInBytes < snapshot.pixelData.count * 3 / 4 {
                return FrozenRead(LayerTextureResource(try SparseLayerTexture.initialized(
                    size: .init(width: snapshot.width, height: snapshot.height), format: format, tiles: occupied, metal: metal)))
            }
        }
        guard let texture = makeTexture(width: snapshot.width, height: snapshot.height, pixelFormat: format, metal: metal) else {
            throw CanvasResourceError(message: "无法准备恢复纹理")
        }
        return FrozenRead(LayerTextureResource(texture))
    }

    func installFrozenResource(_ read: FrozenRead, for key: LayerResourceKey) {
        if key.kind == .mask { maskTexturesByLayerID[key.layerID] = read.resource }
        else if let id = surfacesByLayerID[key.layerID]?.surfaceID {
            texturesBySurfaceID[id] = read.resource
            sparseScanCandidates.removeValue(forKey: id)
            contentStateByLayerID[key.layerID] = .unknown
        }
        recordChange(for: key)
    }

    /// Owns unpublished pixels and their sparse heap until a validated edit commits.
    final class StagedPixelEdit {
        fileprivate let source: LayerTextureResource
        fileprivate let sourceTexture: MTLTexture
        fileprivate let result: LayerTextureResource
        fileprivate let surfaceID: LayerSurfaceID
        fileprivate let region: PixelRegion
        fileprivate let sourceRevision: LayerChangeCursor?
        var texture: MTLTexture { result.texture }
        var allocatedBytes: Int { result.sparse?.allocatedBytes ?? texture.allocatedSize }
        fileprivate init(source: LayerTextureResource, result: LayerTextureResource,
                         surfaceID: LayerSurfaceID, region: PixelRegion, sourceRevision: LayerChangeCursor?) {
            self.source = source; self.sourceTexture = source.texture; self.result = result
            self.surfaceID = surfaceID; self.region = region
            self.sourceRevision = sourceRevision
        }
    }

    func preparePixelEdit(for surfaceID: LayerSurfaceID, region: PixelRegion,
                          allowsSparse: Bool = true) throws -> StagedPixelEdit {
        guard let source = texturesBySurfaceID[surfaceID], let metal = metalContext else {
            throw CanvasResourceError(message: "无法访问像素编辑源图层")
        }
#if DEBUG
        if debugPreventsTextureAllocation { throw CanvasResourceError(message: "无法分配像素编辑资源") }
#endif
        let texture = source.texture
        let canvas = CanvasSize(width: texture.width, height: texture.height)
        guard let bounds = PixelRegion.canvasBounds(for: canvas), bounds.intersection(with: region) == region else {
            throw CanvasResourceError(message: "像素编辑区域超出画布")
        }
        var result: LayerTextureResource?
        // Large/global edits retain the existing dense path. Local edits copy only occupied
        // native tiles plus the write area, without changing canvas coordinates or shaders.
        if allowsSparse, usesSparseStorage, texture.width * texture.height >= 1024 * 1024,
           region.width * region.height < texture.width * texture.height / 4,
           SparseLayerTexture.isSupported(by: metal.device) {
            let tile = metal.device.sparseTileSize(with: .type2D, pixelFormat: texture.pixelFormat, sampleCount: 1)
            var required: Set<TileCoordinate>
            if let sparse = source.sparse { required = sparse.mappedTiles }
            else {
                if sparseScanner == nil { sparseScanner = try SparseTileScanner(metal: metal) }
                required = try sparseScanner!.occupiedTiles(in: texture, tileSize: tile)
            }
            for y in (region.originY / tile.height)...((region.maxY - 1) / tile.height) {
                for x in (region.originX / tile.width)...((region.maxX - 1) / tile.width) {
                    required.insert(.init(x: x, y: y))
                }
            }
            let denseBytes = texture.width * texture.height * (texture.pixelFormat == .rgba16Float ? 8 : 4)
            if required.count * metal.device.sparseTileSizeInBytes < denseBytes * 3 / 4 {
                result = LayerTextureResource(try SparseLayerTexture.copying(texture, tiles: required, metal: metal))
            }
        }
        if result == nil {
            guard let copy = makeTexture(width: texture.width, height: texture.height,
                pixelFormat: texture.pixelFormat, metal: metal), copyTextures([(texture, copy)], metal: metal) else {
                throw CanvasResourceError(message: "无法准备像素编辑；原像素未修改")
            }
            result = LayerTextureResource(copy)
        }
        return StagedPixelEdit(source: source, result: result!, surfaceID: surfaceID, region: region,
            sourceRevision: revision(for: surfaceID))
    }

    func canPublish(_ edit: StagedPixelEdit) -> Bool {
        texturesBySurfaceID[edit.surfaceID] === edit.source && edit.source.texture === edit.sourceTexture
            && revision(for: edit.surfaceID) == edit.sourceRevision
    }

    @discardableResult
    func publish(_ edit: StagedPixelEdit) -> Bool {
        guard canPublish(edit) else { return false }
        if let sparse = edit.result.sparse {
            texturesBySurfaceID[edit.surfaceID] = edit.result
            sparseScanCandidates[edit.surfaceID] = sparse.mappedTiles
            if let id = surfacesByLayerID.first(where: { $0.value.surfaceID == edit.surfaceID })?.key {
                contentStateByLayerID[id] = .unknown
                recordChange(for: .init(layerID: id, kind: .content), region: edit.region)
            }
        } else { swapTexture(for: edit.surfaceID, with: edit.texture, changedRegion: edit.region) }
        return true
    }

    /// An unpublished live target. Sparse residency follows actual rasterized bounds.
    /// It never aliases the document's writable pixels.
    final class WorkingPixelEdit {
        fileprivate var resource: LayerTextureResource
        fileprivate let metal: MetalDeviceContext
        var texture: MTLTexture { resource.texture }
        var allocatedBytes: Int { resource.sparse?.allocatedBytes ?? texture.allocatedSize }
        fileprivate init(resource: LayerTextureResource, metal: MetalDeviceContext) {
            self.resource = resource
            self.metal = metal
        }

        func prepareWrite(in region: PixelRegion, commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
            if let sparse = resource.sparse {
                let required = sparse.mappedTiles.union(sparse.tiles(intersecting: region))
                let denseBytes = texture.width * texture.height * (texture.pixelFormat == .rgba16Float ? 8 : 4)
                if required.count * metal.device.sparseTileSizeInBytes >= denseBytes * 3 / 4 {
                    try materializeDense(commandBuffer: commandBuffer)
                } else {
                    try sparse.prepareForWrite(in: region, commandBuffer: commandBuffer)
                }
            }
            return texture
        }

        func materializeDense(commandBuffer: MTLCommandBuffer) throws {
            guard resource.sparse != nil else { return }
            let copy = try StageOneLayerSurfaceStore.makeDenseCopy(of: texture, metal: metal,
                                                                  commandBuffer: commandBuffer)
            resource = LayerTextureResource(copy)
        }
    }

    func makeWorkingPixelEdit(for surfaceID: LayerSurfaceID,
                              commandBuffer: MTLCommandBuffer) throws -> WorkingPixelEdit {
        guard let source = texturesBySurfaceID[surfaceID], let metal = metalContext else {
            throw CanvasResourceError(message: "无法访问笔触源图层")
        }
#if DEBUG
        if debugPreventsTextureAllocation { throw CanvasResourceError(message: "无法分配笔触资源") }
#endif
        let result: LayerTextureResource
        let texture = source.texture
        let denseBytes = texture.width * texture.height * (texture.pixelFormat == .rgba16Float ? 8 : 4)
        if usesSparseStorage, let sparse = source.sparse,
           max(sparse.mappedTiles.count, 1) * metal.device.sparseTileSizeInBytes < denseBytes * 3 / 4 {
            result = LayerTextureResource(try SparseLayerTexture.copying(texture, tiles: sparse.mappedTiles,
                metal: metal, commandBuffer: commandBuffer))
        } else {
            result = LayerTextureResource(try Self.makeDenseCopy(of: texture, metal: metal,
                                                                 commandBuffer: commandBuffer))
        }
        return WorkingPixelEdit(resource: result, metal: metal)
    }

    /// Async preparation uses known residency only: no synchronous occupancy scan or GPU wait.
    /// Unknown/dense sources and broad edits deliberately retain the dense path.
    func preparePixelEdit(for surfaceID: LayerSurfaceID, region: PixelRegion,
                          commandBuffer: MTLCommandBuffer,
                          reusingDenseTexture: MTLTexture? = nil) throws -> StagedPixelEdit {
        guard let source = texturesBySurfaceID[surfaceID], let metal = metalContext else {
            throw CanvasResourceError(message: "无法访问笔触编辑源图层")
        }
#if DEBUG
        if debugPreventsTextureAllocation { throw CanvasResourceError(message: "无法分配像素编辑资源") }
#endif
        let texture = source.texture
        let canvas = CanvasSize(width: texture.width, height: texture.height)
        guard let bounds = PixelRegion.canvasBounds(for: canvas), bounds.intersection(with: region) == region else {
            throw CanvasResourceError(message: "笔触编辑区域超出画布")
        }
        var result: LayerTextureResource?
        if usesSparseStorage, let sparse = source.sparse,
           region.width * region.height < texture.width * texture.height / 4 {
            let required = sparse.mappedTiles.union(sparse.tiles(intersecting: region))
            let denseBytes = texture.width * texture.height * (texture.pixelFormat == .rgba16Float ? 8 : 4)
            if max(required.count, 1) * metal.device.sparseTileSizeInBytes < denseBytes * 3 / 4 {
                result = LayerTextureResource(try SparseLayerTexture.copying(texture, tiles: required,
                    metal: metal, commandBuffer: commandBuffer))
            }
        }
        if result == nil {
            result = LayerTextureResource(try Self.makeDenseCopy(of: texture, metal: metal,
                commandBuffer: commandBuffer, reusing: reusingDenseTexture))
        }
        return StagedPixelEdit(source: source, result: result!, surfaceID: surfaceID, region: region,
            sourceRevision: revision(for: surfaceID))
    }

    private static func makeDenseCopy(of source: MTLTexture, metal: MetalDeviceContext,
                                      commandBuffer: MTLCommandBuffer,
                                      reusing candidate: MTLTexture? = nil) throws -> MTLTexture {
        let result: MTLTexture
        if let candidate, candidate !== source,
           candidate.width == source.width, candidate.height == source.height,
           candidate.pixelFormat == source.pixelFormat, candidate.heap?.type != .sparse {
            result = candidate
        } else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: source.pixelFormat,
                width: source.width, height: source.height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            guard let created = metal.device.makeTexture(descriptor: descriptor) else {
                throw CanvasResourceError(message: "无法分配笔触暂存；原图层和输入仍保留")
            }
            result = created
        }
        let lifetime = MetalCloneSourceLifetime([source, result])
        commandBuffer.addCompletedHandler { _ in withExtendedLifetime(lifetime) {} }
        guard let copy = commandBuffer.makeBlitCommandEncoder() else {
            throw CanvasResourceError(message: "无法复制笔触源图层")
        }
        copy.copy(from: source, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
                  to: result, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        copy.endEncoding()
        return result
    }

    private func revision(for surfaceID: LayerSurfaceID) -> LayerChangeCursor? {
        guard let layerID = surfacesByLayerID.first(where: { $0.value.surfaceID == surfaceID })?.key else { return nil }
        return changeJournal(for: .init(layerID: layerID, kind: .content)).cursor
    }


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
        result.sparseScanCandidates = sparseScanCandidates
#if DEBUG
        result.debugPreventsTextureAllocation = debugPreventsTextureAllocation
        result.debugRejectsTextureCommands = debugRejectsTextureCommands
#endif
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
    var debugRejectsTextureCommands = false

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

    /// Publish a complete surface set only after every allocation and GPU clear succeeds.
    @discardableResult
    func prepareTextures(for document: ArtDocument, metal: MetalDeviceContext) -> Bool {
        do { try requireTextures(for: document, metal: metal); return true }
        catch { lastResourceError = error.localizedDescription; return false }
    }

    func requireTextures(for document: ArtDocument, metal: MetalDeviceContext) throws {
        let prepared = sharedCopy()
        try prepared.prepareTexturesInPlace(for: document, metal: metal)
        adoptContents(of: prepared)
        sparseScanCandidates = prepared.sparseScanCandidates
        lastResourceError = nil
    }

    /// Duplicate ownership, not bytes. The first write detaches through the existing COW path.
    func shareLayerResources(from sourceID: LayerID, to destinationID: LayerID, document: ArtDocument) throws {
        _ = surfaceRecords(for: document)
        guard let source = surfacesByLayerID[sourceID], let target = surfacesByLayerID[destinationID],
              let pixels = texturesBySurfaceID[source.surfaceID] else {
            throw CanvasResourceError(message: "复制源图层资源不完整")
        }
        if document.layer(destinationID)?.mask != nil, maskTexturesByLayerID[sourceID] == nil {
            throw CanvasResourceError(message: "复制源蒙版资源不完整")
        }
        texturesBySurfaceID[target.surfaceID] = pixels
        maskTexturesByLayerID[destinationID] = maskTexturesByLayerID[sourceID]
        contentStateByLayerID[destinationID] = contentStateByLayerID[sourceID]
    }

    private func prepareTexturesInPlace(
        for document: ArtDocument,
        metal: MetalDeviceContext
    ) throws {
        metalContext = metal
        let records = surfaceRecords(for: document)

        for record in records where texturesBySurfaceID[record.surfaceID] == nil {
#if DEBUG
            if debugPreventsTextureAllocation { throw CanvasResourceError(message: "无法分配图层资源") }
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
            guard let texture = makeTexture(for: record, metal: metal), clearTexture(texture, metal: metal) else {
                throw CanvasResourceError(message: "图层资源分配或初始化失败")
            }
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
            ), clearTexture(texture, value: 1, metal: metal) else {
                throw CanvasResourceError(message: "蒙版资源分配或初始化失败")
            }
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

    @discardableResult
    func fillContentTexture(for layerID: LayerID, value: Double, metal: MetalDeviceContext) -> Bool {
        guard let id = surfaceID(for: layerID), let texture = texture(for: id) else { return false }
        return clearTexture(texture, value: value, metal: metal)
    }

    @discardableResult
    func fillMaskTexture(for layerID: LayerID, value: Float, metal: MetalDeviceContext) -> Bool {
        guard let texture = maskTexture(for: layerID) else { return false }
        return clearTexture(texture, value: Double(min(max(value, 0), 1)), metal: metal)
    }

    @discardableResult
    func copyTexture(from sourceLayerID: LayerID, to destinationLayerID: LayerID, metal: MetalDeviceContext) -> Bool {
        guard let sourceID = surfaceID(for: sourceLayerID), let destinationID = surfaceID(for: destinationLayerID),
              let source = readTexture(for: sourceID), let destination = texture(for: destinationID),
              copyTextures([(source, destination)], metal: metal) else { return false }
        contentStateByLayerID[destinationLayerID] = contentStateByLayerID[sourceLayerID] ?? .unknown
        return true
    }

    @discardableResult
    func copyMaskTexture(from sourceLayerID: LayerID, to destinationLayerID: LayerID, metal: MetalDeviceContext) -> Bool {
        guard let source = readMaskTexture(for: sourceLayerID) else { return readMaskTexture(for: destinationLayerID) == nil }
        guard let destination = maskTexture(for: destinationLayerID) else { return false }
        return copyTextures([(source, destination)], metal: metal)
    }

    @discardableResult
    func copyTexture(from sourceTexture: MTLTexture, to destinationTexture: MTLTexture, metal: MetalDeviceContext) -> Bool {
        copyTextures([(sourceTexture, destinationTexture)], metal: metal)
    }

    @discardableResult
    func copyTextures(
        _ copies: [(source: MTLTexture, destination: MTLTexture)],
        metal: MetalDeviceContext
    ) -> Bool {
#if DEBUG
        if debugRejectsTextureCommands { return false }
#endif
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
#if DEBUG
        if debugPreventsTextureAllocation { return nil }
#endif
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
    ) -> Bool {
        clearTexture(texture, value: 0, metal: metal)
    }

    private func clearTexture(
        _ texture: MTLTexture,
        value: Double,
        metal: MetalDeviceContext
    ) -> Bool {
#if DEBUG
        if debugRejectsTextureCommands { return false }
#endif
        guard
            let commandBuffer = metal.commandQueue.makeCommandBuffer()
        else {
            return false
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
            return false
        }

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed
    }
}

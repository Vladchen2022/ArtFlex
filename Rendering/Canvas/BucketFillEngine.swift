import Foundation
import Metal

struct BucketFillPlan: Sendable {
    var layerID: LayerID
    var historySnapshot: LayerHistorySnapshot?
    var restoreSnapshot: LayerTextureSnapshot
    var destinationX: Int
    var destinationY: Int
}

final class BucketFillEngine: @unchecked Sendable {
    private let serializer: LayerTextureSerializer
    private let tileLength = 512

    init(serializer: LayerTextureSerializer) {
        self.serializer = serializer
    }

    func fill(
        layerID: LayerID,
        at point: CanvasPoint,
        color: RGBAColor,
        alphaLockEnabled: Bool,
        selectionShape: SelectionShape?,
        layerSurfaceStore: StageOneLayerSurfaceStore
    ) throws {
        guard let plan = try makeFillPlan(
            layerID: layerID,
            at: point,
            color: color,
            alphaLockEnabled: alphaLockEnabled,
            selectionShape: selectionShape,
            layerSurfaceStore: layerSurfaceStore
        ) else {
            return
        }
        try apply(plan, layerSurfaceStore: layerSurfaceStore)
    }

    func makeFillPlan(
        layerID: LayerID,
        at point: CanvasPoint,
        color: RGBAColor,
        alphaLockEnabled: Bool,
        selectionShape: SelectionShape?,
        layerSurfaceStore: StageOneLayerSurfaceStore
    ) throws -> BucketFillPlan? {
        guard
            let surfaceID = layerSurfaceStore.surfaceID(for: layerID),
            let texture = layerSurfaceStore.texture(for: surfaceID)
        else {
            return nil
        }

        return try makeFillPlan(
            layerID: layerID,
            texture: texture,
            at: point,
            color: color,
            alphaLockEnabled: alphaLockEnabled,
            selectionShape: selectionShape,
            isKnownTransparent: layerSurfaceStore.isKnownTransparent(layerID: layerID)
        )
    }

    func makeFillPlan(
        layerID: LayerID,
        texture: MTLTexture,
        at point: CanvasPoint,
        color: RGBAColor,
        alphaLockEnabled: Bool,
        selectionShape: SelectionShape?,
        isKnownTransparent: Bool
    ) throws -> BucketFillPlan? {

        let width = texture.width
        let height = texture.height
        let bytesPerPixel = 4
        let canvasBounds = CanvasSize(width: width, height: height)
        let boundedSelection = selectionShape?.clamped(to: canvasBounds)

        let startX = max(0, min(width - 1, Int(point.x.rounded(.down))))
        let startY = max(0, min(height - 1, Int(point.y.rounded(.down))))
        if let boundedSelection,
           !boundedSelection.contains(CanvasPoint(x: Double(startX), y: Double(startY))) {
            return nil
        }

        let processingOriginX: Int
        let processingOriginY: Int
        let processingWidth: Int
        let processingHeight: Int
        if let boundedSelection {
            processingOriginX = max(Int(boundedSelection.bounds.minX.rounded(.down)), 0)
            processingOriginY = max(Int(boundedSelection.bounds.minY.rounded(.down)), 0)
            let maxSelectionX = min(Int(boundedSelection.bounds.maxX.rounded(.up)), width)
            let maxSelectionY = min(Int(boundedSelection.bounds.maxY.rounded(.up)), height)
            processingWidth = max(0, maxSelectionX - processingOriginX)
            processingHeight = max(0, maxSelectionY - processingOriginY)
        } else {
            processingOriginX = 0
            processingOriginY = 0
            processingWidth = width
            processingHeight = height
        }

        guard processingWidth > 0, processingHeight > 0 else {
            return nil
        }

        if boundedSelection == nil, isKnownTransparent {
            return makeKnownTransparentFillPlan(
                layerID: layerID,
                width: width,
                height: height,
                color: color,
                alphaLockEnabled: alphaLockEnabled
            )
        }

        if boundedSelection == nil,
           processingWidth * processingHeight > tileLength * tileLength {
            return try makeTiledFillPlan(
                layerID: layerID,
                texture: texture,
                startX: startX,
                startY: startY,
                color: color,
                alphaLockEnabled: alphaLockEnabled
            )
        }

        let snapshot = try serializer.snapshot(
            texture: texture,
            originX: processingOriginX,
            originY: processingOriginY,
            width: processingWidth,
            height: processingHeight
        )
        let localStartX = startX - processingOriginX
        let localStartY = startY - processingOriginY
        let startIndex = (localStartY * snapshot.bytesPerRow) + (localStartX * bytesPerPixel)

        let target = snapshot.pixelData.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return PixelBGRA(
                blue: bytes[startIndex],
                green: bytes[startIndex + 1],
                red: bytes[startIndex + 2],
                alpha: bytes[startIndex + 3]
            )
        }
        let replacement = alphaLockEnabled
            ? makePremultipliedBGRA(color: color, preservingAlpha: target.alpha)
            : makePremultipliedBGRA(color: color)

        guard target != replacement else { return nil }
        if alphaLockEnabled && target.alpha == 0 {
            return nil
        }

        let selectionMaskBytes = makeSelectionMaskBytes(
            for: boundedSelection,
            canvasSize: canvasBounds,
            originX: processingOriginX,
            originY: processingOriginY,
            width: processingWidth,
            height: processingHeight
        )
        if let selectionMaskBytes,
           selectionMaskBytes[(localStartY * processingWidth) + localStartX] == 0 {
            return nil
        }

        if selectionMaskBytes == nil,
           snapshotIsUniform(snapshot, matching: target) {
            return BucketFillPlan(
                layerID: layerID,
                historySnapshot: LayerHistorySnapshot(
                    layerID: layerID,
                    texture: snapshot,
                    originX: processingOriginX,
                    originY: processingOriginY
                ),
                restoreSnapshot: filledSnapshot(
                    width: processingWidth,
                    height: processingHeight,
                    pixel: replacement
                ),
                destinationX: processingOriginX,
                destinationY: processingOriginY
            )
        }

        var bytes = [UInt8](snapshot.pixelData)
        var queue: [(x: Int, y: Int)] = [(localStartX, localStartY)]
        queue.reserveCapacity(min(processingWidth * processingHeight, 4096))
        var dirtyMinX = processingWidth
        var dirtyMinY = processingHeight
        var dirtyMaxX = -1
        var dirtyMaxY = -1

        func canFill(localX: Int, localY: Int) -> Bool {
            guard localX >= 0, localX < processingWidth, localY >= 0, localY < processingHeight else {
                return false
            }
            let pixelID = (localY * processingWidth) + localX
            if let selectionMaskBytes,
               selectionMaskBytes[pixelID] == 0 {
                return false
            }

            let index = (localY * snapshot.bytesPerRow) + (localX * bytesPerPixel)
            return bytes[index] == target.blue &&
                bytes[index + 1] == target.green &&
                bytes[index + 2] == target.red &&
                bytes[index + 3] == target.alpha
        }

        func enqueueNeighborSegments(localY: Int, from minX: Int, through maxX: Int) {
            guard localY >= 0, localY < processingHeight else { return }
            var x = minX
            while x <= maxX {
                while x <= maxX, !canFill(localX: x, localY: localY) {
                    x += 1
                }
                guard x <= maxX else { break }
                queue.append((x, localY))
                while x <= maxX, canFill(localX: x, localY: localY) {
                    x += 1
                }
            }
        }

        while let seed = queue.popLast() {
            guard canFill(localX: seed.x, localY: seed.y) else { continue }

            var leftX = seed.x
            while leftX > 0, canFill(localX: leftX - 1, localY: seed.y) {
                leftX -= 1
            }
            var rightX = seed.x
            while rightX < processingWidth - 1, canFill(localX: rightX + 1, localY: seed.y) {
                rightX += 1
            }

            for localX in leftX...rightX {
                let index = (seed.y * snapshot.bytesPerRow) + (localX * bytesPerPixel)
                bytes[index] = replacement.blue
                bytes[index + 1] = replacement.green
                bytes[index + 2] = replacement.red
                bytes[index + 3] = replacement.alpha
            }

            dirtyMinX = min(dirtyMinX, leftX)
            dirtyMinY = min(dirtyMinY, seed.y)
            dirtyMaxX = max(dirtyMaxX, rightX)
            dirtyMaxY = max(dirtyMaxY, seed.y)

            enqueueNeighborSegments(localY: seed.y - 1, from: leftX, through: rightX)
            enqueueNeighborSegments(localY: seed.y + 1, from: leftX, through: rightX)
        }

        guard dirtyMaxX >= dirtyMinX, dirtyMaxY >= dirtyMinY else {
            return nil
        }

        let dirtyWidth = dirtyMaxX - dirtyMinX + 1
        let dirtyHeight = dirtyMaxY - dirtyMinY + 1
        let dirtyBytesPerRow = dirtyWidth * bytesPerPixel
        var dirtyBytes = [UInt8](repeating: 0, count: dirtyBytesPerRow * dirtyHeight)
        dirtyBytes.withUnsafeMutableBytes { destinationBuffer in
            bytes.withUnsafeBytes { sourceBuffer in
                for localRow in 0..<dirtyHeight {
                    let sourceOffset = ((dirtyMinY + localRow) * snapshot.bytesPerRow) + (dirtyMinX * bytesPerPixel)
                    let destinationOffset = localRow * dirtyBytesPerRow
                    guard
                        let destinationBase = destinationBuffer.baseAddress,
                        let sourceBase = sourceBuffer.baseAddress
                    else {
                        return
                    }
                    destinationBase.advanced(by: destinationOffset).copyMemory(
                        from: sourceBase.advanced(by: sourceOffset),
                        byteCount: dirtyBytesPerRow
                    )
                }
            }
        }

        let dirtySnapshot = LayerTextureSnapshot(
            width: dirtyWidth,
            height: dirtyHeight,
            bytesPerRow: dirtyBytesPerRow,
            pixelData: Data(dirtyBytes)
        )
        let oldDirtySnapshot = croppedSnapshot(
            from: snapshot,
            originX: dirtyMinX,
            originY: dirtyMinY,
            width: dirtyWidth,
            height: dirtyHeight
        )
        return BucketFillPlan(
            layerID: layerID,
            historySnapshot: LayerHistorySnapshot(
                layerID: layerID,
                texture: oldDirtySnapshot,
                originX: processingOriginX + dirtyMinX,
                originY: processingOriginY + dirtyMinY
            ),
            restoreSnapshot: dirtySnapshot,
            destinationX: processingOriginX + dirtyMinX,
            destinationY: processingOriginY + dirtyMinY
        )
    }

    func apply(
        _ plan: BucketFillPlan,
        layerSurfaceStore: StageOneLayerSurfaceStore
    ) throws {
        guard
            let surfaceID = layerSurfaceStore.surfaceID(for: plan.layerID),
            let texture = layerSurfaceStore.texture(for: surfaceID)
        else {
            return
        }

        try serializer.restore(
            snapshot: plan.restoreSnapshot,
            into: texture,
            destinationX: plan.destinationX,
            destinationY: plan.destinationY
        )
    }

    private func makeKnownTransparentFillPlan(
        layerID: LayerID,
        width: Int,
        height: Int,
        color: RGBAColor,
        alphaLockEnabled: Bool
    ) -> BucketFillPlan? {
        let target = PixelBGRA(blue: 0, green: 0, red: 0, alpha: 0)
        let replacement = alphaLockEnabled
            ? makePremultipliedBGRA(color: color, preservingAlpha: target.alpha)
            : makePremultipliedBGRA(color: color)

        guard target != replacement else { return nil }
        if alphaLockEnabled && target.alpha == 0 {
            return nil
        }

        return BucketFillPlan(
            layerID: layerID,
            historySnapshot: LayerHistorySnapshot(
                layerID: layerID,
                texture: filledSnapshot(width: width, height: height, pixel: target),
                originX: 0,
                originY: 0
            ),
            restoreSnapshot: filledSnapshot(width: width, height: height, pixel: replacement),
            destinationX: 0,
            destinationY: 0
        )
    }

    private func makeTiledFillPlan(
        layerID: LayerID,
        texture: MTLTexture,
        startX: Int,
        startY: Int,
        color: RGBAColor,
        alphaLockEnabled: Bool
    ) throws -> BucketFillPlan? {
        let width = texture.width
        let height = texture.height
        let bytesPerPixel = 4
        var tiles: [BucketFillTileKey: BucketFillTile] = [:]

        func keyForTileContaining(canvasX: Int, canvasY: Int) -> BucketFillTileKey {
            BucketFillTileKey(x: canvasX / tileLength, y: canvasY / tileLength)
        }

        func loadTile(_ key: BucketFillTileKey) throws -> BucketFillTile {
            if let tile = tiles[key] {
                return tile
            }

            let originX = key.x * tileLength
            let originY = key.y * tileLength
            let tileWidth = min(tileLength, width - originX)
            let tileHeight = min(tileLength, height - originY)
            let snapshot = try serializer.snapshot(
                texture: texture,
                originX: originX,
                originY: originY,
                width: tileWidth,
                height: tileHeight
            )
            let originalBytes = [UInt8](snapshot.pixelData)
            let tile = BucketFillTile(
                originX: originX,
                originY: originY,
                width: tileWidth,
                height: tileHeight,
                bytesPerRow: snapshot.bytesPerRow,
                originalBytes: originalBytes,
                bytes: originalBytes
            )
            tiles[key] = tile
            return tile
        }

        func tileAndLocalPoint(canvasX: Int, canvasY: Int) throws -> (BucketFillTile, Int, Int) {
            let tile = try loadTile(keyForTileContaining(canvasX: canvasX, canvasY: canvasY))
            return (tile, canvasX - tile.originX, canvasY - tile.originY)
        }

        func pixelAt(canvasX: Int, canvasY: Int) throws -> PixelBGRA {
            let (tile, localX, localY) = try tileAndLocalPoint(canvasX: canvasX, canvasY: canvasY)
            let index = (localY * tile.bytesPerRow) + (localX * bytesPerPixel)
            return PixelBGRA(
                blue: tile.bytes[index],
                green: tile.bytes[index + 1],
                red: tile.bytes[index + 2],
                alpha: tile.bytes[index + 3]
            )
        }

        let target = try pixelAt(canvasX: startX, canvasY: startY)
        let replacement = alphaLockEnabled
            ? makePremultipliedBGRA(color: color, preservingAlpha: target.alpha)
            : makePremultipliedBGRA(color: color)

        guard target != replacement else { return nil }
        if alphaLockEnabled && target.alpha == 0 {
            return nil
        }

        func canFill(canvasX: Int, canvasY: Int) throws -> Bool {
            guard canvasX >= 0, canvasX < width, canvasY >= 0, canvasY < height else {
                return false
            }
            let (tile, localX, localY) = try tileAndLocalPoint(canvasX: canvasX, canvasY: canvasY)
            let index = (localY * tile.bytesPerRow) + (localX * bytesPerPixel)
            return tile.bytes[index] == target.blue &&
                tile.bytes[index + 1] == target.green &&
                tile.bytes[index + 2] == target.red &&
                tile.bytes[index + 3] == target.alpha
        }

        var queue: [(x: Int, y: Int)] = [(startX, startY)]
        queue.reserveCapacity(4096)
        var dirtyMinX = width
        var dirtyMinY = height
        var dirtyMaxX = -1
        var dirtyMaxY = -1

        func enqueueNeighborSegments(canvasY: Int, from minX: Int, through maxX: Int) throws {
            guard canvasY >= 0, canvasY < height else { return }
            var x = minX
            while x <= maxX {
                while x <= maxX, try !canFill(canvasX: x, canvasY: canvasY) {
                    x += 1
                }
                guard x <= maxX else { break }
                queue.append((x, canvasY))
                while x <= maxX, try canFill(canvasX: x, canvasY: canvasY) {
                    x += 1
                }
            }
        }

        func fillHorizontalSegment(canvasY: Int, from leftX: Int, through rightX: Int) throws {
            var x = leftX
            while x <= rightX {
                let tile = try loadTile(keyForTileContaining(canvasX: x, canvasY: canvasY))
                let segmentEndX = min(rightX, tile.originX + tile.width - 1)
                let localY = canvasY - tile.originY
                for canvasX in x...segmentEndX {
                    let localX = canvasX - tile.originX
                    let index = (localY * tile.bytesPerRow) + (localX * bytesPerPixel)
                    tile.bytes[index] = replacement.blue
                    tile.bytes[index + 1] = replacement.green
                    tile.bytes[index + 2] = replacement.red
                    tile.bytes[index + 3] = replacement.alpha
                }
                x = segmentEndX + 1
            }
        }

        while let seed = queue.popLast() {
            guard try canFill(canvasX: seed.x, canvasY: seed.y) else { continue }

            var leftX = seed.x
            while leftX > 0, try canFill(canvasX: leftX - 1, canvasY: seed.y) {
                leftX -= 1
            }

            var rightX = seed.x
            while rightX < width - 1, try canFill(canvasX: rightX + 1, canvasY: seed.y) {
                rightX += 1
            }

            try fillHorizontalSegment(canvasY: seed.y, from: leftX, through: rightX)

            dirtyMinX = min(dirtyMinX, leftX)
            dirtyMinY = min(dirtyMinY, seed.y)
            dirtyMaxX = max(dirtyMaxX, rightX)
            dirtyMaxY = max(dirtyMaxY, seed.y)

            try enqueueNeighborSegments(canvasY: seed.y - 1, from: leftX, through: rightX)
            try enqueueNeighborSegments(canvasY: seed.y + 1, from: leftX, through: rightX)
        }

        guard dirtyMaxX >= dirtyMinX, dirtyMaxY >= dirtyMinY else {
            return nil
        }

        let dirtyWidth = dirtyMaxX - dirtyMinX + 1
        let dirtyHeight = dirtyMaxY - dirtyMinY + 1

        func preloadTilesCoveringDirtyBounds() throws {
            let minTileX = dirtyMinX / tileLength
            let maxTileX = dirtyMaxX / tileLength
            let minTileY = dirtyMinY / tileLength
            let maxTileY = dirtyMaxY / tileLength
            for tileY in minTileY...maxTileY {
                for tileX in minTileX...maxTileX {
                    _ = try loadTile(BucketFillTileKey(x: tileX, y: tileY))
                }
            }
        }

        func dirtySnapshot(useOriginalBytes: Bool) throws -> LayerTextureSnapshot {
            try preloadTilesCoveringDirtyBounds()
            let bytesPerRow = dirtyWidth * bytesPerPixel
            var pixelData = Data(count: bytesPerRow * dirtyHeight)
            pixelData.withUnsafeMutableBytes { destinationBuffer in
                guard let destinationBase = destinationBuffer.baseAddress else { return }
                for row in 0..<dirtyHeight {
                    let canvasY = dirtyMinY + row
                    var localDirtyX = 0
                    while localDirtyX < dirtyWidth {
                        let canvasX = dirtyMinX + localDirtyX
                        let key = keyForTileContaining(canvasX: canvasX, canvasY: canvasY)
                        guard let tile = tiles[key] else { return }
                        let segmentWidth = min(
                            dirtyWidth - localDirtyX,
                            tile.originX + tile.width - canvasX
                        )
                        let sourceX = canvasX - tile.originX
                        let sourceY = canvasY - tile.originY
                        let sourceOffset = (sourceY * tile.bytesPerRow) + (sourceX * bytesPerPixel)
                        let destinationOffset = (row * bytesPerRow) + (localDirtyX * bytesPerPixel)
                        let sourceBytes = useOriginalBytes ? tile.originalBytes : tile.bytes
                        sourceBytes.withUnsafeBytes { sourceBuffer in
                            guard let sourceBase = sourceBuffer.baseAddress else { return }
                            destinationBase.advanced(by: destinationOffset).copyMemory(
                                from: sourceBase.advanced(by: sourceOffset),
                                byteCount: segmentWidth * bytesPerPixel
                            )
                        }
                        localDirtyX += segmentWidth
                    }
                }
            }

            return LayerTextureSnapshot(
                width: dirtyWidth,
                height: dirtyHeight,
                bytesPerRow: bytesPerRow,
                pixelData: pixelData
            )
        }

        return BucketFillPlan(
            layerID: layerID,
            historySnapshot: LayerHistorySnapshot(
                layerID: layerID,
                texture: try dirtySnapshot(useOriginalBytes: true),
                originX: dirtyMinX,
                originY: dirtyMinY
            ),
            restoreSnapshot: try dirtySnapshot(useOriginalBytes: false),
            destinationX: dirtyMinX,
            destinationY: dirtyMinY
        )
    }

    private func makeSelectionMaskBytes(
        for selectionShape: SelectionShape?,
        canvasSize: CanvasSize,
        originX: Int,
        originY: Int,
        width: Int,
        height: Int
    ) -> [UInt8]? {
        guard let selectionShape else { return nil }
        guard width > 0, height > 0 else { return nil }

        if let maskData = selectionShape.maskData,
           maskData.canvasWidth == canvasSize.width,
           maskData.canvasHeight == canvasSize.height {
            return extractMaskRegionBytes(
                from: maskData.alphaBytes,
                canvasWidth: canvasSize.width,
                originX: originX,
                originY: originY,
                width: width,
                height: height
            )
        }

        var generated = [UInt8](repeating: 0, count: width * height)
        for localY in 0..<height {
            let canvasY = originY + localY
            let rowOffset = localY * width
            for localX in 0..<width {
                let canvasX = originX + localX
                if selectionShape.contains(CanvasPoint(x: Double(canvasX) + 0.5, y: Double(canvasY) + 0.5)) {
                    generated[rowOffset + localX] = 255
                }
            }
        }
        return generated
    }

    private func extractMaskRegionBytes(
        from alphaBytes: Data,
        canvasWidth: Int,
        originX: Int,
        originY: Int,
        width: Int,
        height: Int
    ) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: width * height)
        guard !result.isEmpty else { return result }

        result.withUnsafeMutableBufferPointer { destinationBuffer in
            alphaBytes.withUnsafeBytes { sourceRawBuffer in
                guard
                    let destinationBase = destinationBuffer.baseAddress,
                    let sourceBase = sourceRawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else {
                    return
                }

                for row in 0..<height {
                    let sourceOffset = ((originY + row) * canvasWidth) + originX
                    let destinationOffset = row * width
                    UnsafeMutableRawPointer(destinationBase.advanced(by: destinationOffset))
                        .copyMemory(
                            from: UnsafeRawPointer(sourceBase.advanced(by: sourceOffset)),
                            byteCount: width
                        )
                }
            }
        }

        return result
    }

    private func makePremultipliedBGRA(color: RGBAColor) -> PixelBGRA {
        let premultiplied = color.premultiplied
        return PixelBGRA(
            blue: UInt8(clamping: Int((premultiplied.blue * 255).rounded())),
            green: UInt8(clamping: Int((premultiplied.green * 255).rounded())),
            red: UInt8(clamping: Int((premultiplied.red * 255).rounded())),
            alpha: UInt8(clamping: Int((premultiplied.alpha * 255).rounded()))
        )
    }

    private func makePremultipliedBGRA(color: RGBAColor, preservingAlpha alpha: UInt8) -> PixelBGRA {
        let alphaScale = Float(alpha) / 255
        return PixelBGRA(
            blue: UInt8(clamping: Int((color.blue * alphaScale * 255).rounded())),
            green: UInt8(clamping: Int((color.green * alphaScale * 255).rounded())),
            red: UInt8(clamping: Int((color.red * alphaScale * 255).rounded())),
            alpha: alpha
        )
    }

    private func croppedSnapshot(
        from snapshot: LayerTextureSnapshot,
        originX: Int,
        originY: Int,
        width: Int,
        height: Int
    ) -> LayerTextureSnapshot {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixelData = Data(count: bytesPerRow * height)
        pixelData.withUnsafeMutableBytes { destinationBuffer in
            snapshot.pixelData.withUnsafeBytes { sourceBuffer in
                guard
                    let destinationBase = destinationBuffer.baseAddress,
                    let sourceBase = sourceBuffer.baseAddress
                else {
                    return
                }

                for row in 0..<height {
                    let sourceOffset = ((originY + row) * snapshot.bytesPerRow) + (originX * bytesPerPixel)
                    let destinationOffset = row * bytesPerRow
                    destinationBase.advanced(by: destinationOffset).copyMemory(
                        from: sourceBase.advanced(by: sourceOffset),
                        byteCount: bytesPerRow
                    )
                }
            }
        }

        return LayerTextureSnapshot(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            pixelData: pixelData
        )
    }

    private func snapshotIsUniform(
        _ snapshot: LayerTextureSnapshot,
        matching target: PixelBGRA
    ) -> Bool {
        snapshot.pixelData.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for y in 0..<snapshot.height {
                let rowOffset = y * snapshot.bytesPerRow
                for x in 0..<snapshot.width {
                    let offset = rowOffset + (x * 4)
                    if bytes[offset] != target.blue ||
                        bytes[offset + 1] != target.green ||
                        bytes[offset + 2] != target.red ||
                        bytes[offset + 3] != target.alpha {
                        return false
                    }
                }
            }
            return true
        }
    }

    private func filledSnapshot(
        width: Int,
        height: Int,
        pixel: PixelBGRA
    ) -> LayerTextureSnapshot {
        let bytesPerRow = width * 4
        var rowBytes = [UInt8](repeating: 0, count: bytesPerRow)
        for x in 0..<width {
            let offset = x * 4
            rowBytes[offset] = pixel.blue
            rowBytes[offset + 1] = pixel.green
            rowBytes[offset + 2] = pixel.red
            rowBytes[offset + 3] = pixel.alpha
        }

        var pixelData = Data(count: bytesPerRow * height)
        pixelData.withUnsafeMutableBytes { rawBuffer in
            rowBytes.withUnsafeBytes { rowBuffer in
                guard
                    let destinationBase = rawBuffer.baseAddress,
                    let sourceBase = rowBuffer.baseAddress
                else {
                    return
                }

                for y in 0..<height {
                    destinationBase.advanced(by: y * bytesPerRow).copyMemory(
                        from: sourceBase,
                        byteCount: bytesPerRow
                    )
                }
            }
        }
        return LayerTextureSnapshot(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            pixelData: pixelData
        )
    }
}

private struct BucketFillTileKey: Hashable {
    var x: Int
    var y: Int
}

private final class BucketFillTile {
    let originX: Int
    let originY: Int
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let originalBytes: [UInt8]
    var bytes: [UInt8]

    init(
        originX: Int,
        originY: Int,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        originalBytes: [UInt8],
        bytes: [UInt8]
    ) {
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.originalBytes = originalBytes
        self.bytes = bytes
    }
}

private struct PixelBGRA: Equatable {
    var blue: UInt8
    var green: UInt8
    var red: UInt8
    var alpha: UInt8
}

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
        layerSurfaceStore: StageOneLayerSurfaceStore,
        settings: FillSettings = .stageOneDefault
    ) throws {
        guard let plan = try makeFillPlan(
            layerID: layerID,
            at: point,
            color: color,
            alphaLockEnabled: alphaLockEnabled,
            selectionShape: selectionShape,
            layerSurfaceStore: layerSurfaceStore,
            settings: settings
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
        layerSurfaceStore: StageOneLayerSurfaceStore,
        settings: FillSettings = .stageOneDefault
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
            isKnownTransparent: layerSurfaceStore.isKnownTransparent(layerID: layerID),
            settings: settings
        )
    }

    func makeFillPlan(
        layerID: LayerID,
        texture: MTLTexture,
        at point: CanvasPoint,
        color: RGBAColor,
        alphaLockEnabled: Bool,
        selectionShape: SelectionShape?,
        isKnownTransparent: Bool,
        settings: FillSettings = .stageOneDefault,
        cancellation: WorkCancellation? = nil
    ) throws -> BucketFillPlan? {
        try cancellation?.check()

        if settings.closeGapPixels > 0 || settings.expandPixels > 0 {
            return try makeRefinedFillPlan(
                layerID: layerID, destination: texture, reference: texture,
                point: point, color: color, alphaLock: alphaLockEnabled,
                selection: selectionShape, settings: settings, cancellation: cancellation
            )
        }

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

        if settings.isContiguous,
           boundedSelection == nil,
           processingWidth * processingHeight > tileLength * tileLength {
            return try makeTiledFillPlan(
                layerID: layerID,
                texture: texture,
                startX: startX,
                startY: startY,
                color: color,
                alphaLockEnabled: alphaLockEnabled,
                tolerance: settings.normalizedTolerance, cancellation: cancellation
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

        if !settings.isContiguous {
            return makeGlobalFillPlan(
                layerID: layerID,
                snapshot: snapshot,
                processingOriginX: processingOriginX,
                processingOriginY: processingOriginY,
                target: target,
                replacement: replacement,
                color: color,
                alphaLockEnabled: alphaLockEnabled,
                tolerance: settings.normalizedTolerance,
                selectionMaskBytes: selectionMaskBytes
            )
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
        var visited = [UInt8](repeating: 0, count: processingWidth * processingHeight)
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
            if visited[pixelID] != 0 {
                return false
            }
            if let selectionMaskBytes,
               selectionMaskBytes[pixelID] == 0 {
                return false
            }

            let index = (localY * snapshot.bytesPerRow) + (localX * bytesPerPixel)
            return pixelsMatch(
                PixelBGRA(
                    blue: bytes[index],
                    green: bytes[index + 1],
                    red: bytes[index + 2],
                    alpha: bytes[index + 3]
                ),
                target,
                tolerance: settings.normalizedTolerance
            )
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
            try cancellation?.check()
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
                let pixelID = (seed.y * processingWidth) + localX
                visited[pixelID] = 1
                let coverage = selectionMaskBytes?[pixelID] ?? 255
                let previous = PixelBGRA(
                    blue: bytes[index],
                    green: bytes[index + 1],
                    red: bytes[index + 2],
                    alpha: bytes[index + 3]
                )
                let pixelReplacement = alphaLockEnabled
                    ? makePremultipliedBGRA(color: color, preservingAlpha: previous.alpha)
                    : replacement
                let coveredReplacement = coverage == 255
                    ? pixelReplacement
                    : blendedPixel(from: previous, to: pixelReplacement, coverage: coverage)
                bytes[index] = coveredReplacement.blue
                bytes[index + 1] = coveredReplacement.green
                bytes[index + 2] = coveredReplacement.red
                bytes[index + 3] = coveredReplacement.alpha
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

    private func makeGlobalFillPlan(
        layerID: LayerID,
        snapshot: LayerTextureSnapshot,
        processingOriginX: Int,
        processingOriginY: Int,
        target: PixelBGRA,
        replacement: PixelBGRA,
        color: RGBAColor,
        alphaLockEnabled: Bool,
        tolerance: Float,
        selectionMaskBytes: [UInt8]?
    ) -> BucketFillPlan? {
        let width = snapshot.width
        let height = snapshot.height
        var bytes = [UInt8](snapshot.pixelData)
        var dirtyMinX = width
        var dirtyMinY = height
        var dirtyMaxX = -1
        var dirtyMaxY = -1

        for y in 0..<height {
            for x in 0..<width {
                let pixelID = (y * width) + x
                let coverage = selectionMaskBytes?[pixelID] ?? 255
                guard coverage > 0 else { continue }
                let offset = (y * snapshot.bytesPerRow) + (x * 4)
                let previous = PixelBGRA(
                    blue: bytes[offset],
                    green: bytes[offset + 1],
                    red: bytes[offset + 2],
                    alpha: bytes[offset + 3]
                )
                guard pixelsMatch(previous, target, tolerance: tolerance) else { continue }
                if alphaLockEnabled, previous.alpha == 0 { continue }
                let pixelReplacement = alphaLockEnabled
                    ? makePremultipliedBGRA(color: color, preservingAlpha: previous.alpha)
                    : replacement
                let resolved = coverage == 255
                    ? pixelReplacement
                    : blendedPixel(from: previous, to: pixelReplacement, coverage: coverage)
                guard resolved != previous else { continue }
                bytes[offset] = resolved.blue
                bytes[offset + 1] = resolved.green
                bytes[offset + 2] = resolved.red
                bytes[offset + 3] = resolved.alpha
                dirtyMinX = min(dirtyMinX, x)
                dirtyMinY = min(dirtyMinY, y)
                dirtyMaxX = max(dirtyMaxX, x)
                dirtyMaxY = max(dirtyMaxY, y)
            }
        }

        guard dirtyMaxX >= dirtyMinX, dirtyMaxY >= dirtyMinY else { return nil }
        let dirtyWidth = dirtyMaxX - dirtyMinX + 1
        let dirtyHeight = dirtyMaxY - dirtyMinY + 1
        let changedSnapshot = LayerTextureSnapshot(
            width: width,
            height: height,
            bytesPerRow: snapshot.bytesPerRow,
            pixelData: Data(bytes)
        )
        return BucketFillPlan(
            layerID: layerID,
            historySnapshot: LayerHistorySnapshot(
                layerID: layerID,
                texture: croppedSnapshot(
                    from: snapshot,
                    originX: dirtyMinX,
                    originY: dirtyMinY,
                    width: dirtyWidth,
                    height: dirtyHeight
                ),
                originX: processingOriginX + dirtyMinX,
                originY: processingOriginY + dirtyMinY
            ),
            restoreSnapshot: croppedSnapshot(
                from: changedSnapshot,
                originX: dirtyMinX,
                originY: dirtyMinY,
                width: dirtyWidth,
                height: dirtyHeight
            ),
            destinationX: processingOriginX + dirtyMinX,
            destinationY: processingOriginY + dirtyMinY
        )
    }

    func makeReferencedFillPlan(
        layerID: LayerID,
        destinationTexture: MTLTexture,
        referenceTexture: MTLTexture,
        at point: CanvasPoint,
        color: RGBAColor,
        alphaLockEnabled: Bool,
        selectionShape: SelectionShape?,
        settings: FillSettings = .stageOneDefault,
        cancellation: WorkCancellation? = nil
    ) throws -> BucketFillPlan? {
        try cancellation?.check()
        guard destinationTexture.width == referenceTexture.width,
              destinationTexture.height == referenceTexture.height else { return nil }

        if settings.closeGapPixels > 0 || settings.expandPixels > 0 {
            return try makeRefinedFillPlan(
                layerID: layerID, destination: destinationTexture, reference: referenceTexture,
                point: point, color: color, alphaLock: alphaLockEnabled,
                selection: selectionShape, settings: settings, cancellation: cancellation
            )
        }

        let markerColors = [
            RGBAColor(red: 1, green: 0, blue: 1, alpha: 1),
            RGBAColor(red: 0, green: 1, blue: 1, alpha: 1)
        ]
        var referencePlan: BucketFillPlan?
        for markerColor in markerColors where referencePlan == nil {
            referencePlan = try makeFillPlan(
                layerID: layerID,
                texture: referenceTexture,
                at: point,
                color: markerColor,
                alphaLockEnabled: false,
                selectionShape: selectionShape,
                isKnownTransparent: false,
                settings: settings, cancellation: cancellation
            )
        }
        guard let referencePlan, let referenceBefore = referencePlan.historySnapshot else { return nil }

        let destinationBefore = try serializer.snapshot(
            texture: destinationTexture,
            originX: referencePlan.destinationX,
            originY: referencePlan.destinationY,
            width: referencePlan.restoreSnapshot.width,
            height: referencePlan.restoreSnapshot.height
        )
        var destinationBytes = [UInt8](destinationBefore.pixelData)
        let referenceBeforeBytes = [UInt8](referenceBefore.texture.pixelData)
        let referenceAfterBytes = [UInt8](referencePlan.restoreSnapshot.pixelData)
        let replacement = makePremultipliedBGRA(color: color)
        var changedPixelCount = 0

        for y in 0..<destinationBefore.height {
            try cancellation?.check()
            for x in 0..<destinationBefore.width {
                let destinationOffset = y * destinationBefore.bytesPerRow + x * 4
                let referenceBeforeOffset = y * referenceBefore.texture.bytesPerRow + x * 4
                let referenceAfterOffset = y * referencePlan.restoreSnapshot.bytesPerRow + x * 4
                let referenceChanged = (0..<4).contains { channel in
                    referenceBeforeBytes[referenceBeforeOffset + channel] != referenceAfterBytes[referenceAfterOffset + channel]
                }
                guard referenceChanged else { continue }

                let destinationAlpha = destinationBytes[destinationOffset + 3]
                if alphaLockEnabled, destinationAlpha == 0 { continue }
                let resolvedReplacement = alphaLockEnabled
                    ? makePremultipliedBGRA(color: color, preservingAlpha: destinationAlpha)
                    : replacement
                let previous = PixelBGRA(
                    blue: destinationBytes[destinationOffset],
                    green: destinationBytes[destinationOffset + 1],
                    red: destinationBytes[destinationOffset + 2],
                    alpha: destinationAlpha
                )
                guard previous != resolvedReplacement else { continue }
                destinationBytes[destinationOffset] = resolvedReplacement.blue
                destinationBytes[destinationOffset + 1] = resolvedReplacement.green
                destinationBytes[destinationOffset + 2] = resolvedReplacement.red
                destinationBytes[destinationOffset + 3] = resolvedReplacement.alpha
                changedPixelCount += 1
            }
        }
        guard changedPixelCount > 0 else { return nil }

        return BucketFillPlan(
            layerID: layerID,
            historySnapshot: LayerHistorySnapshot(
                layerID: layerID,
                texture: destinationBefore,
                originX: referencePlan.destinationX,
                originY: referencePlan.destinationY
            ),
            restoreSnapshot: LayerTextureSnapshot(
                width: destinationBefore.width,
                height: destinationBefore.height,
                bytesPerRow: destinationBefore.bytesPerRow,
                pixelData: Data(destinationBytes)
            ),
            destinationX: referencePlan.destinationX,
            destinationY: referencePlan.destinationY
        )
    }

    /// Optional line-art path. Closing changes only the temporary topology, never
    /// the reference layer. The default zero/zero path retains the tiled flood fill.
    private func makeRefinedFillPlan(
        layerID: LayerID, destination: MTLTexture, reference: MTLTexture,
        point: CanvasPoint, color: RGBAColor, alphaLock: Bool,
        selection: SelectionShape?, settings: FillSettings, cancellation: WorkCancellation?
    ) throws -> BucketFillPlan? {
        let width = reference.width
        let height = reference.height
        let size = CanvasSize(width: width, height: height)
        let sx = Int(point.x.rounded(.down)), sy = Int(point.y.rounded(.down))
        guard sx >= 0, sy >= 0, sx < width, sy < height else { return nil }
        let selectionBytes = makeSelectionMaskBytes(
            for: selection, canvasSize: size, originX: 0, originY: 0, width: width, height: height
        )
        if let selectionBytes, selectionBytes[sy * width + sx] == 0 { return nil }
        let snapshot = try serializer.snapshot(texture: reference)
        var walls = try snapshot.pixelData.withUnsafeBytes { raw -> [UInt8] in
            let bytes = raw.bindMemory(to: UInt8.self)
            func pixel(_ x: Int, _ y: Int) -> PremultipliedSRGBAPixel {
                let i = y * snapshot.bytesPerRow + x * 4
                return .init(bgraBlue: bytes[i], green: bytes[i + 1], red: bytes[i + 2], alpha: bytes[i + 3])
            }
            let seed = pixel(sx, sy)
            var result = [UInt8](repeating: 0, count: width * height)
            for y in 0..<height {
                try cancellation?.check()
                for x in 0..<width {
                    if !FillColorDistance.matches(pixel(x, y), seed, tolerance: settings.normalizedTolerance) {
                        result[y * width + x] = 255
                    }
                }
            }
            return result
        }
        if settings.isContiguous, settings.closeGapPixels > 0 {
            try cancellation?.check()
            let wallShape = SelectionShape.mask(canvasWidth: width, canvasHeight: height, alphaBytes: walls)
            if !wallShape.isEmpty,
               let expanded = SelectionRefinement.expanded(wallShape, canvasSize: size, radiusPixels: settings.closeGapPixels),
               let closed = SelectionRefinement.contracted(expanded, canvasSize: size, radiusPixels: settings.closeGapPixels),
               let closedMask = closed.maskData {
                let closedBytes = [UInt8](closedMask.alphaBytes)
                // Preserve original boundaries at canvas edges (erosion has zero padding).
                for i in walls.indices { walls[i] = max(walls[i], closedBytes[i]) }
            }
        }
        if let selectionBytes {
            for i in walls.indices where selectionBytes[i] == 0 { walls[i] = 255 }
        }
        guard walls[sy * width + sx] == 0 else {
            throw CanvasResourceError(message: "落点附近空间不足，请减小闭合缺口数值后重试")
        }
        guard let region = try SmartSelectionSegmenter.segment(
            originX: 0, originY: 0, width: width, height: height, seedPoint: point,
            settings: .init(tolerance: 0, isAntiAliased: false, isContiguous: settings.isContiguous),
            cancellation: cancellation,
            pixelAt: { x, y in
                let value = walls[y * width + x]
                return .init(red: value, green: value, blue: value, alpha: 255)
            }
        ) else { return nil }
        var fillShape = SelectionShape.mask(canvasWidth: width, canvasHeight: height, alphaBytes: region.alphaBytes)
        try cancellation?.check()
        if settings.expandPixels > 0,
           let expanded = SelectionRefinement.expanded(fillShape, canvasSize: size, radiusPixels: settings.expandPixels) {
            fillShape = expanded
        }
        guard let mask = fillShape.maskData else { return nil }
        let coverage = [UInt8](mask.alphaBytes)
        let x0 = max(0, Int(fillShape.bounds.minX)), y0 = max(0, Int(fillShape.bounds.minY))
        let w = min(width, Int(fillShape.bounds.maxX.rounded(.up))) - x0
        let h = min(height, Int(fillShape.bounds.maxY.rounded(.up))) - y0
        guard w > 0, h > 0 else { return nil }
        let before = try serializer.snapshot(texture: destination, originX: x0, originY: y0, width: w, height: h)
        var output = [UInt8](before.pixelData)
        var changed = false
        for y in 0..<h {
            try cancellation?.check()
            for x in 0..<w {
                let maskIndex = (y + y0) * width + x + x0
                let amount = UInt8((Int(coverage[maskIndex]) * Int(selectionBytes?[maskIndex] ?? 255) + 127) / 255)
                guard amount > 0 else { continue }
                let i = y * before.bytesPerRow + x * 4
                let old = PixelBGRA(blue: output[i], green: output[i + 1], red: output[i + 2], alpha: output[i + 3])
                if alphaLock && old.alpha == 0 { continue }
                let replacement = alphaLock ? makePremultipliedBGRA(color: color, preservingAlpha: old.alpha) : makePremultipliedBGRA(color: color)
                let next = blendedPixel(from: old, to: replacement, coverage: amount)
                guard old != next else { continue }
                output[i] = next.blue; output[i + 1] = next.green
                output[i + 2] = next.red; output[i + 3] = next.alpha
                changed = true
            }
        }
        guard changed else { return nil }
        return BucketFillPlan(
            layerID: layerID,
            historySnapshot: .init(layerID: layerID, texture: before, originX: x0, originY: y0),
            restoreSnapshot: .init(width: w, height: h, bytesPerRow: before.bytesPerRow, pixelData: Data(output)),
            destinationX: x0, destinationY: y0
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
        alphaLockEnabled: Bool,
        tolerance: Float,
        cancellation: WorkCancellation?
    ) throws -> BucketFillPlan? {
        let width = texture.width
        let height = texture.height
        let bytesPerPixel = 4
        var tiles: [BucketFillTileKey: BucketFillTile] = [:]
        var visited = [UInt8](repeating: 0, count: width * height)

        func keyForTileContaining(canvasX: Int, canvasY: Int) -> BucketFillTileKey {
            BucketFillTileKey(x: canvasX / tileLength, y: canvasY / tileLength)
        }

        func loadTile(_ key: BucketFillTileKey) throws -> BucketFillTile {
            try cancellation?.check()
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
            let visitedIndex = (canvasY * width) + canvasX
            guard visited[visitedIndex] == 0 else { return false }
            let (tile, localX, localY) = try tileAndLocalPoint(canvasX: canvasX, canvasY: canvasY)
            let index = (localY * tile.bytesPerRow) + (localX * bytesPerPixel)
            return pixelsMatch(
                PixelBGRA(
                    blue: tile.bytes[index],
                    green: tile.bytes[index + 1],
                    red: tile.bytes[index + 2],
                    alpha: tile.bytes[index + 3]
                ),
                target,
                tolerance: tolerance
            )
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
                    visited[(canvasY * width) + canvasX] = 1
                    let pixelReplacement = alphaLockEnabled
                        ? makePremultipliedBGRA(
                            color: color,
                            preservingAlpha: tile.bytes[index + 3]
                        )
                        : replacement
                    tile.bytes[index] = pixelReplacement.blue
                    tile.bytes[index + 1] = pixelReplacement.green
                    tile.bytes[index + 2] = pixelReplacement.red
                    tile.bytes[index + 3] = pixelReplacement.alpha
                }
                x = segmentEndX + 1
            }
        }

        while let seed = queue.popLast() {
            try cancellation?.check()
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

    private func pixelsMatch(
        _ lhs: PixelBGRA,
        _ rhs: PixelBGRA,
        tolerance: Float
    ) -> Bool {
        FillColorDistance.matches(
            PremultipliedSRGBAPixel(
                bgraBlue: lhs.blue,
                green: lhs.green,
                red: lhs.red,
                alpha: lhs.alpha
            ),
            PremultipliedSRGBAPixel(
                bgraBlue: rhs.blue,
                green: rhs.green,
                red: rhs.red,
                alpha: rhs.alpha
            ),
            tolerance: tolerance
        )
    }

    private func blendedPixel(
        from source: PixelBGRA,
        to destination: PixelBGRA,
        coverage: UInt8
    ) -> PixelBGRA {
        let amount = Int(coverage)
        let inverse = 255 - amount
        func blend(_ sourceValue: UInt8, _ destinationValue: UInt8) -> UInt8 {
            UInt8(
                clamping: (
                    (Int(sourceValue) * inverse) +
                    (Int(destinationValue) * amount) +
                    127
                ) / 255
            )
        }

        return PixelBGRA(
            blue: blend(source.blue, destination.blue),
            green: blend(source.green, destination.green),
            red: blend(source.red, destination.red),
            alpha: blend(source.alpha, destination.alpha)
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

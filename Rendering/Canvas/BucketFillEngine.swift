import Foundation
import Metal

final class BucketFillEngine {
    private let serializer: LayerTextureSerializer

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
        guard
            let surfaceID = layerSurfaceStore.surfaceID(for: layerID),
            let texture = layerSurfaceStore.texture(for: surfaceID)
        else {
            return
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
            return
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
            return
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

        var bytes = [UInt8](snapshot.pixelData)
        let target = PixelBGRA(
            blue: bytes[startIndex],
            green: bytes[startIndex + 1],
            red: bytes[startIndex + 2],
            alpha: bytes[startIndex + 3]
        )
        let replacement = alphaLockEnabled
            ? makePremultipliedBGRA(color: color, preservingAlpha: target.alpha)
            : makePremultipliedBGRA(color: color)

        guard target != replacement else { return }
        if alphaLockEnabled && target.alpha == 0 {
            return
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
            return
        }

        var queue: [Int] = [(localStartY * processingWidth) + localStartX]
        var visited = [UInt8](repeating: 0, count: processingWidth * processingHeight)
        var dirtyMinX = processingWidth
        var dirtyMinY = processingHeight
        var dirtyMaxX = -1
        var dirtyMaxY = -1

        while let pixelID = queue.popLast() {
            guard visited[pixelID] == 0 else { continue }
            visited[pixelID] = 1

            if let selectionMaskBytes,
               selectionMaskBytes[pixelID] == 0 {
                continue
            }

            let localY = pixelID / processingWidth
            let localX = pixelID - (localY * processingWidth)
            let index = (localY * snapshot.bytesPerRow) + (localX * bytesPerPixel)

            let currentPixel = PixelBGRA(
                blue: bytes[index],
                green: bytes[index + 1],
                red: bytes[index + 2],
                alpha: bytes[index + 3]
            )

            guard currentPixel == target else { continue }
            if alphaLockEnabled && currentPixel.alpha == 0 {
                continue
            }

            let resolvedReplacement = alphaLockEnabled
                ? makePremultipliedBGRA(color: color, preservingAlpha: currentPixel.alpha)
                : replacement
            bytes[index] = resolvedReplacement.blue
            bytes[index + 1] = resolvedReplacement.green
            bytes[index + 2] = resolvedReplacement.red
            bytes[index + 3] = resolvedReplacement.alpha

            dirtyMinX = min(dirtyMinX, localX)
            dirtyMinY = min(dirtyMinY, localY)
            dirtyMaxX = max(dirtyMaxX, localX)
            dirtyMaxY = max(dirtyMaxY, localY)

            if localX > 0 { queue.append(pixelID - 1) }
            if localX < processingWidth - 1 { queue.append(pixelID + 1) }
            if localY > 0 { queue.append(pixelID - processingWidth) }
            if localY < processingHeight - 1 { queue.append(pixelID + processingWidth) }
        }

        guard dirtyMaxX >= dirtyMinX, dirtyMaxY >= dirtyMinY else {
            return
        }

        let dirtyWidth = dirtyMaxX - dirtyMinX + 1
        let dirtyHeight = dirtyMaxY - dirtyMinY + 1
        let dirtyBytesPerRow = dirtyWidth * bytesPerPixel
        var dirtyBytes = [UInt8](repeating: 0, count: dirtyBytesPerRow * dirtyHeight)
        for localRow in 0..<dirtyHeight {
            let sourceOffset = ((dirtyMinY + localRow) * snapshot.bytesPerRow) + (dirtyMinX * bytesPerPixel)
            let destinationOffset = localRow * dirtyBytesPerRow
            dirtyBytes.withUnsafeMutableBytes { destinationBuffer in
                bytes.withUnsafeBytes { sourceBuffer in
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
        try serializer.restore(
            snapshot: dirtySnapshot,
            into: texture,
            destinationX: processingOriginX + dirtyMinX,
            destinationY: processingOriginY + dirtyMinY
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
}

private struct PixelBGRA: Equatable {
    var blue: UInt8
    var green: UInt8
    var red: UInt8
    var alpha: UInt8
}

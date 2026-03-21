import Foundation
import Metal

struct TransformPreviewSession {
    let activeLayerSurfaceID: LayerSurfaceID
    let workingTexture: MTLTexture?
    let previewTexture: MTLTexture
    let selectionShape: SelectionShape
    let previewBounds: CanvasRect
    var offset: CanvasPoint
}

final class TransformPreviewSessionBuilder {
    private let serializer: LayerTextureSerializer

    init(serializer: LayerTextureSerializer = LayerTextureSerializer()) {
        self.serializer = serializer
    }

    func makeSession(
        sceneSnapshot: CanvasSceneSnapshot,
        layerSurfaceStore: StageOneLayerSurfaceStore,
        metal: MetalDeviceContext,
        selectionShape: SelectionShape
    ) throws -> TransformPreviewSession? {
        guard
            let activeLayerSurfaceID = sceneSnapshot.activeLayerSurfaceID,
            let activeTexture = layerSurfaceStore.texture(for: activeLayerSurfaceID)
        else {
            return nil
        }

        let clampedSelection = selectionShape.clamped(
            to: CanvasSize(width: activeTexture.width, height: activeTexture.height)
        )
        guard !clampedSelection.isEmpty else {
            return nil
        }

        let minX = max(Int(clampedSelection.bounds.minX.rounded(.down)), 0)
        let minY = max(Int(clampedSelection.bounds.minY.rounded(.down)), 0)
        let maxX = min(Int(clampedSelection.bounds.maxX.rounded(.up)), activeTexture.width)
        let maxY = min(Int(clampedSelection.bounds.maxY.rounded(.up)), activeTexture.height)
        guard minX < maxX, minY < maxY else {
            return nil
        }

        let isWholeLayerMove =
            clampedSelection.kind == .rectangle &&
            minX == 0 &&
            minY == 0 &&
            maxX == activeTexture.width &&
            maxY == activeTexture.height

        if isWholeLayerMove {
            return TransformPreviewSession(
                activeLayerSurfaceID: activeLayerSurfaceID,
                workingTexture: nil,
                previewTexture: activeTexture,
                selectionShape: clampedSelection,
                previewBounds: CanvasRect(
                    origin: .init(x: 0, y: 0),
                    size: .init(x: Double(activeTexture.width), y: Double(activeTexture.height))
                ),
                offset: .init(x: 0, y: 0)
            )
        }

        let bytesPerPixel = 4
        let canvasWidth = activeTexture.width
        let canvasHeight = activeTexture.height
        let previewWidth = maxX - minX
        let previewHeight = maxY - minY
        let previewBytesPerRow = previewWidth * bytesPerPixel
        let selectionSnapshot = try serializer.snapshot(
            texture: activeTexture,
            originX: minX,
            originY: minY,
            width: previewWidth,
            height: previewHeight
        )
        let sourceBytes = [UInt8](selectionSnapshot.pixelData)
        var workingRegionBytes = sourceBytes
        var previewBytes = [UInt8](repeating: 0, count: previewBytesPerRow * previewHeight)

        if clampedSelection.kind == .rectangle {
            previewBytes = sourceBytes
            for index in stride(from: 0, to: workingRegionBytes.count, by: bytesPerPixel) {
                workingRegionBytes[index] = 0
                workingRegionBytes[index + 1] = 0
                workingRegionBytes[index + 2] = 0
                workingRegionBytes[index + 3] = 0
            }
        } else if clampedSelection.kind == .mask, let maskData = clampedSelection.maskData {
            let maskBytes = [UInt8](maskData.alphaBytes)
            for localY in 0..<previewHeight {
                for localX in 0..<previewWidth {
                    let x = minX + localX
                    let y = minY + localY
                    let maskIndex = (y * maskData.canvasWidth) + x
                    guard maskBytes.indices.contains(maskIndex), maskBytes[maskIndex] > 0 else { continue }

                    let sourceIndex = (localY * selectionSnapshot.bytesPerRow) + (localX * bytesPerPixel)
                    let previewIndex = (localY * previewBytesPerRow) + (localX * bytesPerPixel)

                    previewBytes[previewIndex] = sourceBytes[sourceIndex]
                    previewBytes[previewIndex + 1] = sourceBytes[sourceIndex + 1]
                    previewBytes[previewIndex + 2] = sourceBytes[sourceIndex + 2]
                    previewBytes[previewIndex + 3] = sourceBytes[sourceIndex + 3]

                    workingRegionBytes[sourceIndex] = 0
                    workingRegionBytes[sourceIndex + 1] = 0
                    workingRegionBytes[sourceIndex + 2] = 0
                    workingRegionBytes[sourceIndex + 3] = 0
                }
            }
        } else {
            for localY in 0..<previewHeight {
                for localX in 0..<previewWidth {
                    let x = minX + localX
                    let y = minY + localY
                    let point = CanvasPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                    guard clampedSelection.contains(point) else { continue }

                    let sourceIndex = (localY * selectionSnapshot.bytesPerRow) + (localX * bytesPerPixel)
                    let previewIndex = (localY * previewBytesPerRow) + (localX * bytesPerPixel)

                    previewBytes[previewIndex] = sourceBytes[sourceIndex]
                    previewBytes[previewIndex + 1] = sourceBytes[sourceIndex + 1]
                    previewBytes[previewIndex + 2] = sourceBytes[sourceIndex + 2]
                    previewBytes[previewIndex + 3] = sourceBytes[sourceIndex + 3]

                    workingRegionBytes[sourceIndex] = 0
                    workingRegionBytes[sourceIndex + 1] = 0
                    workingRegionBytes[sourceIndex + 2] = 0
                    workingRegionBytes[sourceIndex + 3] = 0
                }
            }
        }

        guard
            let workingTexture = makeTexture(
                width: canvasWidth,
                height: canvasHeight,
                metal: metal
            ),
            let previewTexture = makeTexture(
                width: previewWidth,
                height: previewHeight,
                metal: metal
            )
        else {
            return nil
        }

        layerSurfaceStore.copyTexture(
            from: activeTexture,
            to: workingTexture,
            metal: metal
        )
        try serializer.restore(
            snapshot: LayerTextureSnapshot(
                width: previewWidth,
                height: previewHeight,
                bytesPerRow: selectionSnapshot.bytesPerRow,
                pixelData: Data(workingRegionBytes)
            ),
            into: workingTexture,
            destinationX: minX,
            destinationY: minY
        )
        try serializer.restore(
            snapshot: LayerTextureSnapshot(
                width: previewWidth,
                height: previewHeight,
                bytesPerRow: previewBytesPerRow,
                pixelData: Data(previewBytes)
            ),
            into: previewTexture
        )

        return TransformPreviewSession(
            activeLayerSurfaceID: activeLayerSurfaceID,
            workingTexture: workingTexture,
            previewTexture: previewTexture,
            selectionShape: clampedSelection,
            previewBounds: CanvasRect(
                origin: CanvasPoint(x: Double(minX), y: Double(minY)),
                size: CanvasPoint(x: Double(previewWidth), y: Double(previewHeight))
            ),
            offset: .init(x: 0, y: 0)
        )
    }

    private func makeTexture(
        width: Int,
        height: Int,
        metal: MetalDeviceContext
    ) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .private
        return metal.device.makeTexture(descriptor: descriptor)
    }
}

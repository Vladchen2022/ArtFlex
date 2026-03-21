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
        selectionShape: SelectionShape?,
        layerSurfaceStore: StageOneLayerSurfaceStore
    ) throws {
        guard
            let surfaceID = layerSurfaceStore.surfaceID(for: layerID),
            let texture = layerSurfaceStore.texture(for: surfaceID)
        else {
            return
        }

        var snapshot = try serializer.snapshot(texture: texture)
        let width = snapshot.width
        let height = snapshot.height
        let bytesPerPixel = 4
        let canvasBounds = CanvasSize(width: width, height: height)
        let boundedSelection = selectionShape?.clamped(to: canvasBounds)

        let startX = max(0, min(width - 1, Int(point.x.rounded(.down))))
        let startY = max(0, min(height - 1, Int(point.y.rounded(.down))))
        if let boundedSelection,
           !boundedSelection.contains(CanvasPoint(x: Double(startX), y: Double(startY))) {
            return
        }
        let startIndex = (startY * snapshot.bytesPerRow) + (startX * bytesPerPixel)

        var bytes = [UInt8](snapshot.pixelData)
        let target = PixelBGRA(
            blue: bytes[startIndex],
            green: bytes[startIndex + 1],
            red: bytes[startIndex + 2],
            alpha: bytes[startIndex + 3]
        )
        let replacement = makePremultipliedBGRA(color: color)

        guard target != replacement else { return }

        var queue: [(x: Int, y: Int)] = [(startX, startY)]
        var visited = Set<Int>()

        while let current = queue.popLast() {
            let index = (current.y * snapshot.bytesPerRow) + (current.x * bytesPerPixel)
            let pixelID = (current.y * width) + current.x

            guard !visited.contains(pixelID) else { continue }
            visited.insert(pixelID)

            if let boundedSelection,
               !boundedSelection.contains(CanvasPoint(x: Double(current.x), y: Double(current.y))) {
                continue
            }

            let currentPixel = PixelBGRA(
                blue: bytes[index],
                green: bytes[index + 1],
                red: bytes[index + 2],
                alpha: bytes[index + 3]
            )

            guard currentPixel == target else { continue }

            bytes[index] = replacement.blue
            bytes[index + 1] = replacement.green
            bytes[index + 2] = replacement.red
            bytes[index + 3] = replacement.alpha

            if current.x > 0 { queue.append((current.x - 1, current.y)) }
            if current.x < width - 1 { queue.append((current.x + 1, current.y)) }
            if current.y > 0 { queue.append((current.x, current.y - 1)) }
            if current.y < height - 1 { queue.append((current.x, current.y + 1)) }
        }

        snapshot.pixelData = Data(bytes)
        try serializer.restore(snapshot: snapshot, into: texture)
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
}

private struct PixelBGRA: Equatable {
    var blue: UInt8
    var green: UInt8
    var red: UInt8
    var alpha: UInt8
}

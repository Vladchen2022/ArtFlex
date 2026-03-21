import Foundation
import Metal

final class SmudgeEngine {
    private let serializer: LayerTextureSerializer

    init(serializer: LayerTextureSerializer) {
        self.serializer = serializer
    }

    func applySmudge(
        _ stroke: StrokeDescriptor,
        to layerID: LayerID,
        layerSurfaceStore: StageOneLayerSurfaceStore
    ) throws {
        guard
            let surfaceID = layerSurfaceStore.surfaceID(for: layerID),
            let texture = layerSurfaceStore.texture(for: surfaceID)
        else {
            return
        }

        let points = interpolatedPoints(for: stroke)
        guard !points.isEmpty else { return }

        let radius = max(Double(stroke.brush.size) / 2, 0.5)
        let canvasSize = CanvasSize(width: texture.width, height: texture.height)
        let selectionShape = stroke.selectionShape?.clamped(to: canvasSize)
        let bounds = smudgeBounds(for: points, radius: radius, canvasSize: canvasSize)
        guard bounds.width > 0, bounds.height > 0 else { return }

        var snapshot = try serializer.snapshot(
            texture: texture,
            originX: bounds.originX,
            originY: bounds.originY,
            width: bounds.width,
            height: bounds.height
        )
        var bytes = [UInt8](snapshot.pixelData)
        let localPoints = points.map {
            StrokePoint(
                x: $0.x - Double(bounds.originX),
                y: $0.y - Double(bounds.originY),
                pressure: $0.pressure
            )
        }
        let localSelectionShape = selectionShape?.translatedBy(
            x: -Double(bounds.originX),
            y: -Double(bounds.originY)
        )

        var carriedColor = averageColor(
            around: localPoints[0],
            radius: radius,
            bytes: bytes,
            bytesPerRow: snapshot.bytesPerRow,
            width: snapshot.width,
            height: snapshot.height,
            selectionShape: localSelectionShape
        )

        for point in localPoints {
            stamp(
                carriedColor: carriedColor,
                at: point,
                radius: radius,
                opacity: min(max(Double(stroke.brush.opacity), 0), 1),
                bytes: &bytes,
                bytesPerRow: snapshot.bytesPerRow,
                width: snapshot.width,
                height: snapshot.height,
                selectionShape: localSelectionShape
            )

            let sampled = averageColor(
                around: point,
                radius: radius,
                bytes: bytes,
                bytesPerRow: snapshot.bytesPerRow,
                width: snapshot.width,
                height: snapshot.height,
                selectionShape: localSelectionShape
            )
            carriedColor = LinearPremultipliedColor(
                red: (carriedColor.red * 0.35) + (sampled.red * 0.65),
                green: (carriedColor.green * 0.35) + (sampled.green * 0.65),
                blue: (carriedColor.blue * 0.35) + (sampled.blue * 0.65),
                alpha: (carriedColor.alpha * 0.35) + (sampled.alpha * 0.65)
            )
        }

        snapshot.pixelData = Data(bytes)
        try serializer.restore(
            snapshot: snapshot,
            into: texture,
            destinationX: bounds.originX,
            destinationY: bounds.originY
        )
    }

    private func smudgeBounds(
        for points: [StrokePoint],
        radius: Double,
        canvasSize: CanvasSize
    ) -> (originX: Int, originY: Int, width: Int, height: Int) {
        guard let first = points.first else {
            return (0, 0, 0, 0)
        }

        var minX = first.x - radius
        var minY = first.y - radius
        var maxX = first.x + radius
        var maxY = first.y + radius

        for point in points.dropFirst() {
            minX = min(minX, point.x - radius)
            minY = min(minY, point.y - radius)
            maxX = max(maxX, point.x + radius)
            maxY = max(maxY, point.y + radius)
        }

        let originX = max(Int(minX.rounded(.down)), 0)
        let originY = max(Int(minY.rounded(.down)), 0)
        let endX = min(Int(maxX.rounded(.up)), canvasSize.width)
        let endY = min(Int(maxY.rounded(.up)), canvasSize.height)

        return (
            originX: originX,
            originY: originY,
            width: max(endX - originX, 0),
            height: max(endY - originY, 0)
        )
    }

    private func stamp(
        carriedColor: LinearPremultipliedColor,
        at point: StrokePoint,
        radius: Double,
        opacity: Double,
        bytes: inout [UInt8],
        bytesPerRow: Int,
        width: Int,
        height: Int,
        selectionShape: SelectionShape?
    ) {
        let minX = max(Int((point.x - radius).rounded(.down)), 0)
        let maxX = min(Int((point.x + radius).rounded(.up)), width - 1)
        let minY = max(Int((point.y - radius).rounded(.down)), 0)
        let maxY = min(Int((point.y + radius).rounded(.up)), height - 1)

        for y in minY...maxY {
            for x in minX...maxX {
                let pixelPoint = CanvasPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                if let selectionShape, !selectionShape.contains(pixelPoint) {
                    continue
                }

                let dx = pixelPoint.x - point.x
                let dy = pixelPoint.y - point.y
                let distance = sqrt((dx * dx) + (dy * dy))
                guard distance <= radius else { continue }

                let normalized = min(max(distance / radius, 0), 1)
                let falloff = (1 - normalized) * (1 - normalized)
                let alpha = opacity * falloff * Double(carriedColor.alpha)
                guard alpha > 0 else { continue }

                let index = (y * bytesPerRow) + (x * 4)
                let destination = LinearPremultipliedColor(
                    bgraBlue: bytes[index],
                    green: bytes[index + 1],
                    red: bytes[index + 2],
                    alpha: bytes[index + 3]
                )

                let source = LinearPremultipliedColor(
                    red: carriedColor.red * Float(alpha),
                    green: carriedColor.green * Float(alpha),
                    blue: carriedColor.blue * Float(alpha),
                    alpha: Float(alpha)
                )

                let composited = source.composited(over: destination)
                let output = composited.bgra8PremultipliedBytes
                bytes[index] = output.blue
                bytes[index + 1] = output.green
                bytes[index + 2] = output.red
                bytes[index + 3] = output.alpha
            }
        }
    }

    private func averageColor(
        around point: StrokePoint,
        radius: Double,
        bytes: [UInt8],
        bytesPerRow: Int,
        width: Int,
        height: Int,
        selectionShape: SelectionShape?
    ) -> LinearPremultipliedColor {
        let minX = max(Int((point.x - radius).rounded(.down)), 0)
        let maxX = min(Int((point.x + radius).rounded(.up)), width - 1)
        let minY = max(Int((point.y - radius).rounded(.down)), 0)
        let maxY = min(Int((point.y + radius).rounded(.up)), height - 1)

        var accumulated = LinearPremultipliedColor.clear
        var sampleCount: Float = 0

        for y in minY...maxY {
            for x in minX...maxX {
                let pixelPoint = CanvasPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                if let selectionShape, !selectionShape.contains(pixelPoint) {
                    continue
                }

                let dx = pixelPoint.x - point.x
                let dy = pixelPoint.y - point.y
                let distance = sqrt((dx * dx) + (dy * dy))
                guard distance <= radius else { continue }

                let index = (y * bytesPerRow) + (x * 4)
                let pixel = LinearPremultipliedColor(
                    bgraBlue: bytes[index],
                    green: bytes[index + 1],
                    red: bytes[index + 2],
                    alpha: bytes[index + 3]
                )

                accumulated.red += pixel.red
                accumulated.green += pixel.green
                accumulated.blue += pixel.blue
                accumulated.alpha += pixel.alpha
                sampleCount += 1
            }
        }

        guard sampleCount > 0 else {
            return .clear
        }

        return LinearPremultipliedColor(
            red: accumulated.red / sampleCount,
            green: accumulated.green / sampleCount,
            blue: accumulated.blue / sampleCount,
            alpha: accumulated.alpha / sampleCount
        )
    }

    private func interpolatedPoints(for stroke: StrokeDescriptor) -> [StrokePoint] {
        guard let first = stroke.points.first else {
            return []
        }

        if stroke.points.count == 1 {
            return [first]
        }

        let spacing = max(Double(stroke.brush.size) * 0.08, 0.75)
        var result: [StrokePoint] = [first]

        for index in 1..<stroke.points.count {
            let previous = stroke.points[index - 1]
            let current = stroke.points[index]
            let dx = current.x - previous.x
            let dy = current.y - previous.y
            let distance = sqrt((dx * dx) + (dy * dy))

            if distance <= spacing {
                result.append(current)
                continue
            }

            let steps = Int(distance / spacing)
            for step in 1...steps {
                let t = Double(step) / Double(steps + 1)
                result.append(
                    StrokePoint(
                        x: previous.x + (dx * t),
                        y: previous.y + (dy * t),
                        pressure: 1
                    )
                )
            }

            result.append(current)
        }

        return result
    }
}

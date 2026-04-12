import Foundation
import Metal

final class LayerMergeController {
    private let serializer: LayerTextureSerializer

    init(serializer: LayerTextureSerializer) {
        self.serializer = serializer
    }

    func merge(
        sourceTexture: MTLTexture,
        sourceOpacity: Float,
        sourceVisible: Bool,
        into destinationTexture: MTLTexture,
        destinationOpacity: Float,
        destinationVisible: Bool
    ) throws {
        try composite(
            layers: [
                (texture: destinationTexture, opacity: destinationOpacity, isVisible: destinationVisible),
                (texture: sourceTexture, opacity: sourceOpacity, isVisible: sourceVisible)
            ],
            into: destinationTexture
        )
    }

    func mergeVisible(
        layers: [(texture: MTLTexture, opacity: Float, isVisible: Bool)],
        into targetTexture: MTLTexture
    ) throws {
        try composite(layers: layers, into: targetTexture)
    }

    private func composite(
        layers: [(texture: MTLTexture, opacity: Float, isVisible: Bool)],
        into targetTexture: MTLTexture
    ) throws {
        guard let first = layers.first else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let snapshots = try layers.map { layer in
            try serializer.snapshot(texture: layer.texture)
        }

        guard snapshots.allSatisfy({
            $0.width == first.texture.width &&
            $0.height == first.texture.height &&
            $0.bytesPerRow == snapshots[0].bytesPerRow
        }) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var mergedBytes = [UInt8](repeating: 0, count: snapshots[0].pixelData.count)
        let bytesPerPixel = 4

        for layerIndex in snapshots.indices {
            let snapshot = snapshots[layerIndex]
            let layer = layers[layerIndex]
            let effectiveOpacity: Float = layer.isVisible ? layer.opacity : 0

            guard effectiveOpacity > 0 else { continue }

            snapshot.pixelData.withUnsafeBytes { rawBuffer in
                let bytes = rawBuffer.bindMemory(to: UInt8.self)
                for offset in stride(from: 0, to: bytes.count, by: bytesPerPixel) {
                    let destination = LinearPremultipliedColor(
                        bgraBlue: mergedBytes[offset],
                        green: mergedBytes[offset + 1],
                        red: mergedBytes[offset + 2],
                        alpha: mergedBytes[offset + 3]
                    )

                    let source = LinearPremultipliedColor(
                        bgraBlue: bytes[offset],
                        green: bytes[offset + 1],
                        red: bytes[offset + 2],
                        alpha: bytes[offset + 3]
                    ).applyingOpacity(effectiveOpacity)

                    let merged = source.composited(over: destination)
                    let output = merged.bgra8PremultipliedBytes
                    mergedBytes[offset] = output.blue
                    mergedBytes[offset + 1] = output.green
                    mergedBytes[offset + 2] = output.red
                    mergedBytes[offset + 3] = output.alpha
                }
            }
        }

        try serializer.restore(
            snapshot: LayerTextureSnapshot(
                width: snapshots[0].width,
                height: snapshots[0].height,
                bytesPerRow: snapshots[0].bytesPerRow,
                pixelData: Data(mergedBytes)
            ),
            into: targetTexture
        )
    }
}

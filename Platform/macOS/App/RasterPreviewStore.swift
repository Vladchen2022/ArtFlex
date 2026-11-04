import CoreGraphics
import Foundation
import ImageIO
import Metal

/// One immutable, reduced source per export presentation. No full-canvas CPU readback
/// and no simultaneous encodes when settings change rapidly.
actor RasterPreviewStore {
    private var source: LayerTextureSnapshot?
    private var sourceTexture: MTLTexture?

    func image(texture: WorkspaceUncheckedBox<MTLTexture>, serializer: WorkspaceUncheckedBox<LayerTextureSerializer>,
               exporter: RasterExporter, options: RasterExportOptions,
               cancellation: WorkCancellation) -> CGImage? {
        do {
            try cancellation.check()
            let id = ObjectIdentifier(texture.value)
            if sourceTexture.map(ObjectIdentifier.init) != id {
                source = nil
                // Ceiling division guarantees an upper bound of 1200 pixels.
                let divisor = max(1, (max(texture.value.width, texture.value.height) + 1199) / 1200)
                let reduced = try serializer.value.downsampledSnapshot(texture: texture.value, divisor: divisor)
                try cancellation.check()
                source = reduced
                sourceTexture = texture.value
            }
            guard let source else { return nil }
            let bounds = try exporter.resolvedSourceBounds(snapshot: source, scope: options.scope)
            try cancellation.check()
            // Resize mode changes aspect ratio only for exact dimensions. The thumbnail
            // approximates resampling/JPEG artifacts; final export retains full resolution.
            let size = try options.outputDimensions(sourceWidth: bounds.width, sourceHeight: bounds.height)
            let divisor = max(1, Double(max(size.width, size.height)) / 600)
            var preview = options
            preview.resize = .exact(width: max(1, Int(Double(size.width) / divisor)),
                                    height: max(1, Int(Double(size.height) / divisor)))
            preview.bitDepth = .eight
            let result = try exporter.encode(snapshot: source, options: preview, sourceBounds: bounds)
            try cancellation.check()
            guard let imageSource = CGImageSourceCreateWithData(result.encodedData as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        } catch { return nil }
    }

    func clear() { source = nil; sourceTexture = nil }
}

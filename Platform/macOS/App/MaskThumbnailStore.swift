import CoreGraphics
import Foundation
import Metal

struct MaskThumbnailKey: Hashable, Sendable {
    var layerID: LayerID
    var epoch: UUID
    var revision: UInt64
    var textureID: ObjectIdentifier
}

/// Serial generation, bounded cache, and per-resource keys prevent unrelated paint edits
/// from re-reading every mask. The store owns cache lifetime, not the workspace model.
actor MaskThumbnailStore {
    private var images: [MaskThumbnailKey: CGImage] = [:]
    private var order: [MaskThumbnailKey] = []

    func image(key: MaskThumbnailKey, cancellation: WorkCancellation,
               makeImage: @Sendable () -> CGImage?) -> CGImage? {
        guard !cancellation.isCancelled else { return nil }
        if let cached = images[key] { return cached }
        guard let image = makeImage(), !cancellation.isCancelled else { return nil }
        // Superseded versions of this layer are evicted immediately.
        order.removeAll { old in
            if old.layerID == key.layerID { images.removeValue(forKey: old); return true }
            return false
        }
        images[key] = image
        order.append(key)
        while order.count > 96 { images.removeValue(forKey: order.removeFirst()) }
        return image
    }
}

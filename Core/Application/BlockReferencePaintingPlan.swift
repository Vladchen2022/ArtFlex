import Foundation

/// Preserve the paper layer, then place the reference below all painting layers.
/// An ordinary opaque image or paint layer still occludes a reference behind it.
enum BlockReferencePaintingPlan {
    static func insertionIndex(document: ArtDocument, visibleLayerIDs: [LayerID]) -> Int {
        guard let paper = document.drawablePaintLayers.first,
              paper.name == LayerRecord.defaultBackgroundLayerName,
              visibleLayerIDs.first == paper.id else { return 0 }
        return 1
    }
}

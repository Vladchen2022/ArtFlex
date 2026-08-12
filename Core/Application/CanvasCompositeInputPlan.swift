import Foundation
import Metal

/// Canonical runtime description shared by on-screen and off-screen canvas composition.
/// It deliberately resolves document hierarchy before platform renderers see the inputs.
struct CanvasCompositeInputPlan {
    struct Entry {
        let layerID: LayerID
        let input: CanvasLayerCompositeInput
    }

    let entries: [Entry]

    var inputs: [CanvasLayerCompositeInput] {
        entries.map(\.input)
    }

    static func make(
        document: ArtDocument,
        orderedLayers: [LayerRecord]? = nil,
        allowsMissingTextures: Bool = false,
        textureForLayer: (LayerID) -> MTLTexture?,
        enabledMaskTextureForLayer: (LayerID) -> MTLTexture?
    ) throws -> CanvasCompositeInputPlan {
        let visiblePaintLayers = document.layers.filter {
            $0.isPaintLayer && document.isLayerEffectivelyVisible($0.id)
        }
        var visibleTextures: [LayerID: MTLTexture] = [:]
        var enabledMasks: [LayerID: MTLTexture] = [:]
        for layer in visiblePaintLayers {
            if let texture = textureForLayer(layer.id) {
                visibleTextures[layer.id] = texture
            }
            if layer.mask?.isEnabled == true,
               let mask = enabledMaskTextureForLayer(layer.id) {
                enabledMasks[layer.id] = mask
            }
        }

        let requestedLayers = orderedLayers ?? visiblePaintLayers
        let renderableLayers = requestedLayers.filter {
            $0.isPaintLayer && document.isLayerEffectivelyVisible($0.id)
        }
        let entries = try renderableLayers.compactMap { layer -> Entry? in
            guard let texture = visibleTextures[layer.id] else {
                if allowsMissingTextures {
                    return nil
                }
                throw CocoaError(.fileReadCorruptFile)
            }
            if let clipTargetLayerID = layer.clipTargetLayerID,
               visibleTextures[clipTargetLayerID] == nil {
                return nil
            }
            return Entry(
                layerID: layer.id,
                input: CanvasLayerCompositeInput(
                    texture: texture,
                    opacity: document.effectiveLayerOpacity(layer.id),
                    blendMode: layer.blendMode,
                    clipMaskTexture: layer.clipTargetLayerID.flatMap { visibleTextures[$0] },
                    clipLayerMaskTexture: layer.clipTargetLayerID.flatMap { enabledMasks[$0] },
                    layerMaskTexture: enabledMasks[layer.id],
                    curveAdjustmentLUTs: layer.adjustment?.curveLUTs
                )
            )
        }
        return CanvasCompositeInputPlan(entries: entries)
    }
}

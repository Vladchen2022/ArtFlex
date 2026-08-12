import Foundation

struct CanvasStrokeSample: Sendable, Equatable {
    var location: CanvasPoint
    var pressure: Float = 1
}

final class CanvasInteractionController {
    private let workspaceStore: WorkspaceStore

    init(workspaceStore: WorkspaceStore) {
        self.workspaceStore = workspaceStore
    }

    func makeStrokeDescriptor(
        samples: [CanvasStrokeSample],
        skipLeadingStamp: Bool = false,
        paintVariationSeed: UInt32 = 0
    ) -> (layerID: LayerID, stroke: StrokeDescriptor)? {
        let document = workspaceStore.state.document
        guard
            !samples.isEmpty,
            let activeLayer = document.layers.first(where: {
                $0.id == document.activeLayerID && $0.isPaintLayer
            }),
            !activeLayer.isAdjustmentLayer,
            document.isLayerEffectivelyVisible(activeLayer.id),
            !document.isLayerEffectivelyLocked(activeLayer.id)
        else {
            return nil
        }

        let session = workspaceStore.state.toolSession
        guard session.activeTool == .brush || session.activeTool == .eraser || session.activeTool == .smudge else {
            return nil
        }

        let stroke = StrokeDescriptor(
            tool: session.activeTool,
            color: session.selectedColor,
            brush: session.brush,
            points: samples.map {
                StrokePoint(x: $0.location.x, y: $0.location.y, pressure: $0.pressure)
            },
            selectionShape: workspaceStore.state.selection.committedShape,
            alphaLockEnabled: activeLayer.locksTransparentPixels,
            skipLeadingStamp: skipLeadingStamp,
            paintVariationSeed: paintVariationSeed,
            pigmentPalette: session.activeOilPaintPalette
        )

        return (layerID: activeLayer.id, stroke: stroke)
    }

    func activeEditableLayerID() -> LayerID? {
        let document = workspaceStore.state.document
        guard let activeLayer = document.layers.first(where: {
            $0.id == document.activeLayerID && $0.isPaintLayer
        }), !activeLayer.isAdjustmentLayer,
            !document.isLayerEffectivelyLocked(activeLayer.id) else {
            return nil
        }

        return activeLayer.id
    }
}

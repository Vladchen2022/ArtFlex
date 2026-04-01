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
        skipLeadingStamp: Bool = false
    ) -> (layerID: LayerID, stroke: StrokeDescriptor)? {
        guard
            !samples.isEmpty,
            let activeLayer = workspaceStore.state.document.layers.first(where: {
                $0.id == workspaceStore.state.document.activeLayerID
            }),
            !activeLayer.isLocked
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
            skipLeadingStamp: skipLeadingStamp
        )

        return (layerID: activeLayer.id, stroke: stroke)
    }

    func activeEditableLayerID() -> LayerID? {
        guard let activeLayer = workspaceStore.state.document.layers.first(where: {
            $0.id == workspaceStore.state.document.activeLayerID
        }), !activeLayer.isLocked else {
            return nil
        }

        return activeLayer.id
    }
}

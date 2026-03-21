import Foundation
import Metal

final class MetalStrokeEngine: StrokeEngine {
    private struct OpacityCapStrokeSession {
        let layerID: LayerID
        let resources: OpacityCapSessionResources
    }

    private let metalContext: MetalDeviceContext
    private let layerSurfaceStore: StageOneLayerSurfaceStore
    private let brushRenderer: StageOneBrushRenderer
    private var opacityCapSession: OpacityCapStrokeSession?

    init(
        metalContext: MetalDeviceContext,
        layerSurfaceStore: StageOneLayerSurfaceStore
    ) {
        self.metalContext = metalContext
        self.layerSurfaceStore = layerSurfaceStore
        self.brushRenderer = StageOneBrushRenderer(device: metalContext.device)
    }

    func beginStrokeIfNeeded(
        toolSession: ToolSessionState,
        layerID: LayerID
    ) {
        guard
            (toolSession.activeTool == .brush || toolSession.activeTool == .eraser),
            toolSession.brush.buildMode == .opacityCap,
            let surfaceID = layerSurfaceStore.surfaceID(for: layerID),
            let texture = layerSurfaceStore.texture(for: surfaceID)
        else {
            opacityCapSession = nil
            return
        }

        if opacityCapSession?.layerID == layerID {
            return
        }

        guard
            let resources = brushRenderer.makeOpacityCapSession(
                for: texture,
                commandQueue: metalContext.commandQueue
            )
        else {
            opacityCapSession = nil
            return
        }

        opacityCapSession = OpacityCapStrokeSession(
            layerID: layerID,
            resources: resources
        )
    }

    func endStroke() {
        opacityCapSession = nil
    }

    func applyStroke(_ stroke: StrokeDescriptor, to layerID: LayerID) {
        guard
            let surfaceID = layerSurfaceStore.surfaceID(for: layerID),
            let texture = layerSurfaceStore.texture(for: surfaceID)
        else {
            return
        }

        if (stroke.tool == .brush || stroke.tool == .eraser), stroke.brush.buildMode == .opacityCap {
            if opacityCapSession?.layerID != layerID {
                beginStrokeIfNeeded(
                    toolSession: ToolSessionState(
                        activeTool: stroke.tool,
                        brush: stroke.brush,
                        selectedColor: stroke.color
                    ),
                    layerID: layerID
                )
            }

            guard let opacityCapSession else {
                brushRenderer.render(
                    stroke: stroke,
                    into: texture,
                    commandQueue: metalContext.commandQueue
                )
                return
            }

            brushRenderer.renderOpacityCap(
                stroke: stroke,
                session: opacityCapSession.resources,
                into: texture,
                commandQueue: metalContext.commandQueue
            )
            return
        }

        brushRenderer.render(
            stroke: stroke,
            into: texture,
            commandQueue: metalContext.commandQueue
        )
    }
}

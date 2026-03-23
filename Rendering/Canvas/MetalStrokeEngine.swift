import Foundation
import Metal
import os

final class MetalStrokeEngine: StrokeEngine {
    private struct OpacityCapStrokeSession {
        let layerID: LayerID
        let resources: OpacityCapSessionResources
    }

    private struct PendingStrokeContext {
        let layerID: LayerID
        let tool: ToolKind
        let color: RGBAColor
        let brush: BrushSettings
        let selectionShape: SelectionShape?
    }

    private let metalContext: MetalDeviceContext
    private let layerSurfaceStore: StageOneLayerSurfaceStore
    private let brushRenderer: StageOneBrushRenderer
    private let logger = Logger(subsystem: "ArtFlex", category: "BrushStroke")
    private var opacityCapSession: OpacityCapStrokeSession?
    private var brushSamplingState: BrushStrokeSamplingState?
    private var pendingStrokeContext: PendingStrokeContext?

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
        brushSamplingState = nil
        pendingStrokeContext = nil
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
        var flushEmitted = 0
        if let currentSamplingState = brushSamplingState,
           !currentSamplingState.pendingInputPoints.isEmpty,
           let context = pendingStrokeContext,
           let surfaceID = layerSurfaceStore.surfaceID(for: context.layerID),
           let texture = layerSurfaceStore.texture(for: surfaceID) {
            var samplingState: BrushStrokeSamplingState? = currentSamplingState
            samplingState?.isFlushing = true
            let flushStroke = StrokeDescriptor(
                tool: context.tool,
                color: context.color,
                brush: context.brush,
                points: [],
                selectionShape: context.selectionShape,
                skipLeadingStamp: true
            )

            if (flushStroke.tool == .brush || flushStroke.tool == .eraser),
               flushStroke.brush.buildMode == .opacityCap,
               let opacityCapSession,
               opacityCapSession.layerID == context.layerID {
                flushEmitted = brushRenderer.renderOpacityCap(
                    stroke: flushStroke,
                    session: opacityCapSession.resources,
                    into: texture,
                    commandQueue: metalContext.commandQueue,
                    samplingState: &samplingState
                )
            } else {
                flushEmitted = brushRenderer.render(
                    stroke: flushStroke,
                    into: texture,
                    commandQueue: metalContext.commandQueue,
                    samplingState: &samplingState
                )
            }

            brushSamplingState = samplingState
        }
        logger.debug("[flush] didFlush=\(flushEmitted > 0, privacy: .public) emittedStamps=\(flushEmitted, privacy: .public)")
        opacityCapSession = nil
        brushSamplingState = nil
        pendingStrokeContext = nil
    }

    @discardableResult
    func applyStroke(_ stroke: StrokeDescriptor, to layerID: LayerID) -> Int {
        guard
            let surfaceID = layerSurfaceStore.surfaceID(for: layerID),
            let texture = layerSurfaceStore.texture(for: surfaceID)
        else {
            return 0
        }

        pendingStrokeContext = PendingStrokeContext(
            layerID: layerID,
            tool: stroke.tool,
            color: stroke.color,
            brush: stroke.brush,
            selectionShape: stroke.selectionShape
        )

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
                return brushRenderer.render(
                    stroke: stroke,
                    into: texture,
                    commandQueue: metalContext.commandQueue,
                    samplingState: &brushSamplingState
                )
            }

            return brushRenderer.renderOpacityCap(
                stroke: stroke,
                session: opacityCapSession.resources,
                into: texture,
                commandQueue: metalContext.commandQueue,
                samplingState: &brushSamplingState
            )
        }

        return brushRenderer.render(
            stroke: stroke,
            into: texture,
            commandQueue: metalContext.commandQueue,
            samplingState: &brushSamplingState
        )
    }
}

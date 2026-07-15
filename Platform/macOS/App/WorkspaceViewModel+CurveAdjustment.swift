import AppKit
import Foundation
@preconcurrency import Metal

private struct CurveAdjustmentRenderPlan {
    let maskTexture: MTLTexture?
    let maskReadMode: CurveAdjustmentRegionReadMode
    let effectRegion: MTLRegion?
}

@MainActor
extension WorkspaceViewModel {
    var curveAdjustmentParameters: CurveAdjustmentParameters {
        curveAdjustmentSession?.parameters ?? .neutral
    }

    var canStartOrEditCurveAdjustmentFromPanel: Bool {
        curveAdjustmentAvailabilityIssueMessage == nil
    }

    var canConfirmCurveAdjustmentSession: Bool {
        guard
            canStartOrEditCurveAdjustmentFromPanel,
            let activeLayerID = activeEditableLayerIDForCurveAdjustment(),
            let session = curveAdjustmentSession,
            session.layerID == activeLayerID
        else {
            return false
        }

        return session.hasPendingCommittedEffect
    }

    var canPreviewCurveAdjustmentOriginal: Bool {
        guard let session = curveAdjustmentSession else { return false }
        return session.hasVisiblePreview
    }

    var curveAdjustmentStatusMessage: String {
        if let issue = curveAdjustmentAvailabilityIssueMessage {
            return issue
        }
        if let session = curveAdjustmentSession {
            switch session.source {
            case .wholeLayer:
                return "当前影响区域：当前图层全部已有像素。此模式下不需要绘制蒙版。"
            case .selection:
                return "当前影响区域：选区内像素。此模式下不需要绘制蒙版。"
            case .painted(let state):
                return state.paintedBounds == nil
                    ? "当前影响区域：等待绘制蒙版。先用画笔或橡皮定义影响区域，再拖动曲线。"
                    : "当前影响区域：已绘制蒙版。调参时仍可继续补画或擦除蒙版。"
            }
        }
        if workspace.toolSession.activeTool == .brightnessAdjust {
            if preferredCurveAdjustmentSelectionShape() != nil {
                return "当前影响区域：还未开始调整。直接拖动曲线可作用于选区；在画布上绘制可切换到蒙版模式。"
            }
            return "当前影响区域：还未开始调整。直接拖动曲线可作用于当前图层已有像素；在画布上绘制可切换到蒙版模式。"
        }
        if preferredCurveAdjustmentSelectionShape() != nil {
            return "当前影响区域：选区内像素。此模式下不需要绘制蒙版。"
        }
        return "当前影响区域：当前图层全部已有像素。点击曲线图开始调整。"
    }

    func beginCurveAdjustmentFromCurrentContextIfNeeded(showFeedback: Bool = true) -> Bool {
        if let issue = curveAdjustmentAvailabilityIssueMessage {
            if showFeedback {
                presentWorkspaceStatus(kind: .info, message: issue)
            }
            return false
        }
        guard let preparedContext = preparedEditableAdjustmentLayerContext(reason: "curveAdjustment.beginFromCurrentContext") else {
            if showFeedback {
                presentWorkspaceStatus(kind: .error, message: "无法访问当前图层")
            }
            return false
        }
        let layerID = preparedContext.layerID
        let sourceTexture = preparedContext.sourceTexture

        if let session = curveAdjustmentSession, session.layerID == layerID {
            syncCurveAdjustmentSessionToCurrentContextIfNeeded()
            return curveAdjustmentSession?.layerID == layerID
        }

        let parameters = curveAdjustmentSession?.parameters ?? .neutral
        let nextSession: CurveAdjustmentSession?
        if let selectionShape = preferredCurveAdjustmentSelectionShape() {
            nextSession = makeSelectionCurveAdjustmentSession(
                layerID: layerID,
                sourceTexture: sourceTexture,
                selectionShape: selectionShape,
                parameters: parameters
            )
        } else {
            nextSession = makeWholeLayerCurveAdjustmentSession(
                layerID: layerID,
                sourceTexture: sourceTexture,
                parameters: parameters
            )
        }

        curveAdjustmentSession = nextSession
        if nextSession?.hasVisiblePreview == true {
            scheduleCurveAdjustmentPreviewUpdate(force: true)
        }
        syncCurveAdjustmentOverlayState()
        return nextSession != nil
    }

    func beginCurveAdjustmentFromWholeLayerIfNeeded(showFeedback: Bool = true) -> Bool {
        if let issue = curveAdjustmentAvailabilityIssueMessage {
            if showFeedback {
                presentWorkspaceStatus(kind: .info, message: issue)
            }
            return false
        }
        guard let preparedContext = preparedEditableAdjustmentLayerContext(reason: "curveAdjustment.beginWholeLayer") else {
            if showFeedback {
                presentWorkspaceStatus(kind: .error, message: "无法访问当前图层")
            }
            return false
        }
        let layerID = preparedContext.layerID
        let sourceTexture = preparedContext.sourceTexture

        if let session = curveAdjustmentSession,
           session.layerID == layerID,
           case .wholeLayer(let state) = session.source,
           state.capturedCanvasRevision == canvasContentRevision {
            return true
        }

        let carriedParameters = curveAdjustmentSession?.parameters ?? .neutral
        curveAdjustmentSession = makeWholeLayerCurveAdjustmentSession(
            layerID: layerID,
            sourceTexture: sourceTexture,
            parameters: carriedParameters
        )
        if curveAdjustmentSession?.hasVisiblePreview == true {
            scheduleCurveAdjustmentPreviewUpdate(force: true)
        }
        syncCurveAdjustmentOverlayState()
        return curveAdjustmentSession != nil
    }

    func setCurveAdjustmentSelectedChannel(_ channel: CurveChannel) {
        guard var session = preparedCurveAdjustmentSessionForParameterEditing(showFeedback: false) else { return }
        guard session.parameters.selectedChannel != channel else { return }
        var parameters = session.parameters
        parameters.selectedChannel = channel
        session.setParameters(parameters)
        curveAdjustmentSession = session
        syncCurveAdjustmentOverlayState()
    }

    func updateCurveAdjustmentChannelPoints(_ points: [CurveControlPoint], channel: CurveChannel? = nil) {
        guard var session = preparedCurveAdjustmentSessionForParameterEditing(showFeedback: false) else { return }
        let targetChannel = channel ?? session.parameters.selectedChannel
        let nextState = CurveChannelState(points: points)
        guard session.parameters.state(for: targetChannel) != nextState else { return }

        var parameters = session.parameters
        parameters.setState(nextState, for: targetChannel)
        session.setParameters(parameters)
        curveAdjustmentSession = session
        scheduleCurveAdjustmentPreviewUpdate()
        syncCurveAdjustmentOverlayState()
    }

    func resetCurveAdjustmentValues() {
        guard var session = preparedCurveAdjustmentSessionForParameterEditing(showFeedback: false) else { return }
        guard !session.parameters.isNeutral else { return }

        var parameters = session.parameters
        parameters.resetAll()
        session.setParameters(parameters)
        curveAdjustmentSession = session
        scheduleCurveAdjustmentPreviewUpdate()
        syncCurveAdjustmentOverlayState()
    }

    func setCurveAdjustmentShowingOriginalPreview(_ showsOriginal: Bool) {
        guard var session = curveAdjustmentSession else { return }
        guard session.showsOriginalPreview != showsOriginal else { return }
        session.showsOriginalPreview = showsOriginal
        curveAdjustmentSession = session
        colorAdjustmentRedrawRevision &+= 1
        syncCurveAdjustmentOverlayState()
    }

    @discardableResult
    func confirmCurveAdjustmentIfNeeded(showFeedback: Bool = true) -> Bool {
        guard let preparedContext = preparedEditableAdjustmentLayerContext(reason: "curveAdjustment.confirm"),
              let surfaceID = layerSurfaceStore.surfaceID(for: preparedContext.layerID),
              let session = curveAdjustmentSession,
              session.layerID == preparedContext.layerID else {
            if showFeedback {
                presentWorkspaceStatus(kind: .error, message: "无法访问当前图层")
            }
            return false
        }
        let layerID = preparedContext.layerID
        let sourceTexture = preparedContext.sourceTexture
        guard session.hasPendingCommittedEffect else {
            if showFeedback {
                presentWorkspaceStatus(kind: .info, message: "当前还没有可应用的曲线调整")
            }
            return false
        }
        guard let renderPlan = curveRenderPlan(for: session) else {
            if showFeedback {
                presentWorkspaceStatus(kind: .error, message: "无法准备曲线调整范围")
            }
            return false
        }
        guard let targetTexture = layerSurfaceStore.makeTexture(
            width: sourceTexture.width,
            height: sourceTexture.height,
            pixelFormat: sourceTexture.pixelFormat,
            metal: metalContext
        ) else {
            if showFeedback {
                presentWorkspaceStatus(kind: .error, message: "无法创建曲线结果纹理")
            }
            return false
        }
        guard let commandBuffer = metalContext.commandQueue.makeCommandBuffer() else {
            if showFeedback {
                presentWorkspaceStatus(kind: .error, message: "无法创建曲线提交命令")
            }
            return false
        }

        let shouldClearCommittedSelectionAfterApply: Bool = {
            guard case .selection = session.source else { return false }
            return workspace.selection.committedShape != nil
        }()
        let historyWorkspaceOverride = shouldClearCommittedSelectionAfterApply
            ? workspaceSnapshotClearingSelection()
            : nil

        checkpointSingleLayerHistoryIfPossible(
            layerID: layerID,
            operationKind: "curveAdjustment.commit",
            workspaceOverride: historyWorkspaceOverride
        )

        curveAdjustmentRenderer.encodePreview(
            sourceTexture: sourceTexture,
            previewTexture: targetTexture,
            maskTexture: renderPlan.maskTexture,
            maskReadMode: renderPlan.maskReadMode,
            luts: session.luts,
            overlayOnly: false,
            effectRegion: renderPlan.effectRegion,
            commandBuffer: commandBuffer
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        guard commandBuffer.status == .completed else {
            if showFeedback {
                let message = commandBuffer.error?.localizedDescription ?? "曲线调整提交失败"
                presentWorkspaceStatus(kind: .error, message: message)
            }
            return false
        }

        layerSurfaceStore.swapTexture(for: surfaceID, with: targetTexture)
        if shouldClearCommittedSelectionAfterApply {
            clearCommittedSelectionAfterCurveAdjustmentApply()
        }
        discardCurveAdjustmentSession()
        finalizeCommittedSingleLayerMutation(layerID)
        if showFeedback {
            presentWorkspaceStatus(
                kind: .success,
                message: shouldClearCommittedSelectionAfterApply ? "已应用曲线调整，并取消选区" : "已应用曲线调整"
            )
        }
        return true
    }

    @discardableResult
    func cancelCurveAdjustmentIfNeeded(showFeedback: Bool = true) -> Bool {
        guard curveAdjustmentSession != nil else { return true }
        discardCurveAdjustmentSession()
        if showFeedback {
            presentWorkspaceStatus(kind: .info, message: "已放弃当前曲线调整")
        }
        return true
    }

    func beginCurveAdjustmentStrokeIfNeeded() {
        guard let activeContext = activeEditableAdjustmentLayerContext() else { return }
        let layerID = activeContext.layerID
        let sourceTexture = activeContext.sourceTexture

        let carriedParameters = curveAdjustmentSession?.parameters ?? .neutral
        let requiresPaintedMaskSession: Bool = {
            guard let session = curveAdjustmentSession, session.layerID == layerID else {
                return true
            }
            if case .painted = session.source {
                return false
            }
            return true
        }()

        if requiresPaintedMaskSession {
            curveAdjustmentPreviewToken &+= 1
            curveAdjustmentPreviewRenderInFlight = false
            curveAdjustmentPreviewRenderNeedsResubmit = false
            curveAdjustmentSession = makePaintedCurveAdjustmentSession(
                layerID: layerID,
                sourceTexture: sourceTexture,
                parameters: carriedParameters
            )
        }

        curveAdjustmentStrokePacketCount = 0
        curveAdjustmentPreviewRenderNeedsResubmit = false
        syncCurveAdjustmentOverlayState()
    }

    func applyCurveAdjustmentStroke(samples: [CanvasStrokeSample]) {
        guard !samples.isEmpty else { return }
        guard let activeContext = activeEditableAdjustmentLayerContext() else { return }
        let layerID = activeContext.layerID
        let sourceTexture = activeContext.sourceTexture
        guard var session = curveAdjustmentSession, session.layerID == layerID else { return }
        guard case .painted(var paintedState) = session.source else { return }

        let skipLeadingStamp = curveAdjustmentStrokePacketCount > 0
        let stroke = makeCurveAdjustmentMaskStrokeDescriptor(
            samples: samples,
            skipLeadingStamp: skipLeadingStamp
        )

        if stroke.brush.requiresStrokeMaskSession {
            if paintedState.opacityCapSession == nil {
                paintedState.opacityCapSession = colorAdjustmentStrokeEngine.makeOpacityCapSessionForImmediateStroke(
                    texture: paintedState.maskTexture
                )
            }
            if let opacityCapSession = paintedState.opacityCapSession {
                _ = colorAdjustmentStrokeEngine.renderImmediateOpacityCapStroke(
                    stroke,
                    session: opacityCapSession,
                    to: paintedState.maskTexture,
                    alphaLockTexture: sourceTexture,
                    preservesAlphaWhenAlphaLocked: false,
                    samplingState: &paintedState.brushSamplingState
                )
            }
        } else {
            _ = colorAdjustmentStrokeEngine.renderImmediateStroke(
                stroke,
                to: paintedState.maskTexture,
                alphaLockTexture: sourceTexture,
                preservesAlphaWhenAlphaLocked: false,
                samplingState: &paintedState.brushSamplingState
            )
        }

        paintedState.paintedBounds = unionCurveAdjustmentPaintedBounds(
            paintedState.paintedBounds,
            with: samples,
            brushSize: stroke.brush.size
        )

        session.source = .painted(paintedState)
        session.brushMode = curveAdjustmentBrushMode
        curveAdjustmentSession = session
        curveAdjustmentStrokePacketCount += 1
        let shouldRenderPreviewNow =
            curveAdjustmentStrokePacketCount == 1
            || curveAdjustmentStrokePacketCount.isMultiple(of: 3)
        if shouldRenderPreviewNow {
            scheduleCurveAdjustmentPreviewUpdate(force: true)
        }
        syncCurveAdjustmentOverlayState()
    }

    func endCurveAdjustmentStroke() {
        guard var session = curveAdjustmentSession else { return }
        guard case .painted(var paintedState) = session.source else { return }
        guard let activeContext = activeEditableAdjustmentLayerContext() else { return }
        let sourceTexture = activeContext.sourceTexture

        defer {
            session.source = .painted(paintedState)
            curveAdjustmentSession = session
            curveAdjustmentStrokePacketCount = 0
            scheduleCurveAdjustmentPreviewUpdate(force: true)
            syncCurveAdjustmentOverlayState()
        }

        guard paintedState.brushSamplingState != nil else { return }

        var flushSamplingState = paintedState.brushSamplingState
        flushSamplingState?.isFlushing = true
        let flushStroke = StrokeDescriptor(
            tool: .brush,
            color: curveAdjustmentBrushMode == .paint
                ? .init(red: 1, green: 1, blue: 1, alpha: 1)
                : .init(red: 0, green: 0, blue: 0, alpha: 1),
            brush: workspace.toolSession.brush,
            points: [],
            selectionShape: workspace.selection.committedShape,
            alphaLockEnabled: true,
            skipLeadingStamp: true
        )

        if flushStroke.brush.requiresStrokeMaskSession,
           let opacityCapSession = paintedState.opacityCapSession {
            _ = colorAdjustmentStrokeEngine.renderImmediateOpacityCapStroke(
                flushStroke,
                session: opacityCapSession,
                to: paintedState.maskTexture,
                alphaLockTexture: sourceTexture,
                preservesAlphaWhenAlphaLocked: false,
                samplingState: &flushSamplingState
            )
            paintedState.opacityCapSession = nil
        } else {
            _ = colorAdjustmentStrokeEngine.renderImmediateStroke(
                flushStroke,
                to: paintedState.maskTexture,
                alphaLockTexture: sourceTexture,
                preservesAlphaWhenAlphaLocked: false,
                samplingState: &flushSamplingState
            )
        }
        flushSamplingState?.isFlushing = false
        paintedState.brushSamplingState = nil
    }

    @discardableResult
    func resolveCurveAdjustmentSessionIfNeeded(
        reason: CurveAdjustmentResolutionReason
    ) -> Bool {
        guard let session = curveAdjustmentSession else { return true }
        guard session.hasPendingCommittedEffect else {
            discardCurveAdjustmentSession()
            return true
        }

        switch confirmCurveAdjustmentResolution(reason: reason) {
        case .apply:
            guard confirmCurveAdjustmentIfNeeded(showFeedback: true) else { return false }
        case .discard:
            discardCurveAdjustmentSession()
            presentWorkspaceStatus(kind: .info, message: "已放弃当前曲线调整")
        case .cancel:
            return false
        }

        return reason.continuesTriggeringActionAfterResolution
    }

    func handleCurveAdjustmentKeyDown(
        _ event: NSEvent,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard modifiers.isEmpty else { return false }
        let isCurveMaskToolContext =
            workspace.toolSession.activeTool == .brightnessAdjust
            && brightnessAdjustmentEditorMode == .curves
        guard curveAdjustmentSession != nil || curveAdjustmentAllowsIdleModeHotkeys else { return false }

        if event.keyCode == 53 {
            guard curveAdjustmentSession != nil else { return false }
            cancelCurveAdjustmentIfNeeded(showFeedback: true)
            return true
        }

        if event.keyCode == 36 || event.keyCode == 76 {
            guard curveAdjustmentSession != nil else { return false }
            confirmCurveAdjustmentIfNeeded(showFeedback: true)
            return true
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "e" where isCurveMaskToolContext:
            curveAdjustmentBrushMode = .erase
            updateCurveAdjustmentBrushModeIfNeeded()
            return true
        case "b" where isCurveMaskToolContext:
            curveAdjustmentBrushMode = .paint
            updateCurveAdjustmentBrushModeIfNeeded()
            return true
        default:
            return false
        }
    }

    func activeCurveAdjustmentPreviewTexture(for layerID: LayerID) -> MTLTexture? {
        guard let session = curveAdjustmentSession, session.layerID == layerID else { return nil }
        guard !session.showsOriginalPreview, session.hasVisiblePreview else { return nil }
        return session.previewTexture
    }

    private var curveAdjustmentAvailabilityIssueMessage: String? {
        guard activeEditableLayerIDForCurveAdjustment() != nil else {
            return "当前图层不可编辑，请先切到可编辑图层。"
        }
        if colorAdjustmentSession != nil {
            return "请先确认或取消当前色彩调整。"
        }
        return nil
    }

    private func preparedCurveAdjustmentSessionForParameterEditing(showFeedback: Bool) -> CurveAdjustmentSession? {
        guard let preparedContext = preparedEditableAdjustmentLayerContext(reason: "curveAdjustment.prepareParameters") else {
            return nil
        }
        let layerID = preparedContext.layerID
        if let session = curveAdjustmentSession, session.layerID == layerID {
            syncCurveAdjustmentSessionToCurrentContextIfNeeded()
            return curveAdjustmentSession
        }
        guard beginCurveAdjustmentFromCurrentContextIfNeeded(showFeedback: showFeedback) else {
            return nil
        }
        return curveAdjustmentSession
    }

    func syncCurveAdjustmentSessionToCurrentContextIfNeeded() {
        guard let session = curveAdjustmentSession else { return }
        guard let activeContext = activeEditableAdjustmentLayerContext(),
              session.layerID == activeContext.layerID else {
            return
        }
        let activeLayerID = activeContext.layerID
        let sourceTexture = activeContext.sourceTexture

        let replacementSession: CurveAdjustmentSession?
        switch session.source {
        case .painted:
            replacementSession = nil
        case .selection(let selectionState):
            guard let selectionShape = preferredCurveAdjustmentSelectionShape() else {
                replacementSession = rebuiltDirectCurveAdjustmentSession(
                    layerID: activeLayerID,
                    sourceTexture: sourceTexture,
                    preserving: session,
                    preferredSelectionShape: nil
                )
                break
            }
            guard selectionShape != selectionState.capturedSelectionShape else {
                replacementSession = nil
                break
            }
            replacementSession = rebuiltDirectCurveAdjustmentSession(
                layerID: activeLayerID,
                sourceTexture: sourceTexture,
                preserving: session,
                preferredSelectionShape: selectionShape
            )
        case .wholeLayer(let wholeLayerState):
            if let selectionShape = preferredCurveAdjustmentSelectionShape() {
                replacementSession = rebuiltDirectCurveAdjustmentSession(
                    layerID: activeLayerID,
                    sourceTexture: sourceTexture,
                    preserving: session,
                    preferredSelectionShape: selectionShape
                )
            } else if wholeLayerState.capturedCanvasRevision != canvasContentRevision {
                replacementSession = rebuiltDirectCurveAdjustmentSession(
                    layerID: activeLayerID,
                    sourceTexture: sourceTexture,
                    preserving: session,
                    preferredSelectionShape: nil
                )
            } else {
                replacementSession = nil
            }
        }

        guard let replacementSession else { return }
        curveAdjustmentSession = replacementSession
        if replacementSession.hasVisiblePreview {
            scheduleCurveAdjustmentPreviewUpdate(force: true)
        }
        syncCurveAdjustmentOverlayState()
    }

    private func makeWholeLayerCurveAdjustmentSession(
        layerID: LayerID,
        sourceTexture: MTLTexture,
        parameters: CurveAdjustmentParameters
    ) -> CurveAdjustmentSession? {
        guard let previewTexture = makeCurveAdjustmentPreviewTexture(from: sourceTexture) else {
            return nil
        }

        return CurveAdjustmentSession(
            layerID: layerID,
            source: .wholeLayer(
                CurveWholeLayerState(
                    effectBounds: activeEditableLayerEffectBoundsForCurveAdjustment(),
                    capturedCanvasRevision: canvasContentRevision
                )
            ),
            previewTexture: previewTexture,
            parameters: parameters,
            brushMode: curveAdjustmentBrushMode
        )
    }

    private func makePaintedCurveAdjustmentSession(
        layerID: LayerID,
        sourceTexture: MTLTexture,
        parameters: CurveAdjustmentParameters = .neutral
    ) -> CurveAdjustmentSession? {
        guard
            let previewTexture = makeCurveAdjustmentPreviewTexture(from: sourceTexture),
            let maskTexture = layerSurfaceStore.makeTexture(
                width: sourceTexture.width,
                height: sourceTexture.height,
                pixelFormat: .bgra8Unorm_srgb,
                metal: metalContext
            )
        else {
            return nil
        }

        clearCurveAdjustmentMaskTexture(maskTexture)
        return CurveAdjustmentSession(
            layerID: layerID,
            source: .painted(
                CurvePaintedMaskState(
                    maskTexture: maskTexture,
                    paintedBounds: nil,
                    brushSamplingState: nil,
                    opacityCapSession: nil
                )
            ),
            previewTexture: previewTexture,
            parameters: parameters,
            brushMode: curveAdjustmentBrushMode
        )
    }

    private func makeSelectionCurveAdjustmentSession(
        layerID: LayerID,
        sourceTexture: MTLTexture,
        selectionShape: SelectionShape,
        parameters: CurveAdjustmentParameters
    ) -> CurveAdjustmentSession? {
        let canvasSize = CanvasSize(width: sourceTexture.width, height: sourceTexture.height)
        let clampedSelection = selectionShape.clamped(to: canvasSize)
        guard let boundsRegion = curveEffectRegion(from: clampedSelection.bounds) else {
            return nil
        }
        guard let previewTexture = makeCurveAdjustmentPreviewTexture(from: sourceTexture),
              let maskTexture = makeCurveSelectionMaskTexture(
                for: clampedSelection,
                canvasSize: canvasSize
              ) else {
            return nil
        }

        return CurveAdjustmentSession(
            layerID: layerID,
            source: .selection(
                CurveSelectionMaskState(
                    maskTexture: maskTexture,
                    bounds: CanvasRect(
                        origin: .init(
                            x: Double(boundsRegion.origin.x),
                            y: Double(boundsRegion.origin.y)
                        ),
                        size: .init(
                            x: Double(boundsRegion.size.width),
                            y: Double(boundsRegion.size.height)
                        )
                    ),
                    capturedSelectionShape: clampedSelection,
                    capturedSelectionRevision: selectionRevision
                )
            ),
            previewTexture: previewTexture,
            parameters: parameters,
            brushMode: curveAdjustmentBrushMode
        )
    }

    private func sourceTextureForCurveAdjustment(layerID: LayerID) -> MTLTexture? {
        if let activeContext = activeEditableAdjustmentLayerContext(),
           activeContext.layerID == layerID {
            return activeContext.sourceTexture
        }
        guard
            let surfaceID = layerSurfaceStore.surfaceID(for: layerID),
            let texture = layerSurfaceStore.texture(for: surfaceID)
        else {
            return nil
        }
        return texture
    }

    private func scheduleCurveAdjustmentPreviewUpdate(force: Bool = false) {
        guard let session = curveAdjustmentSession else { return }
        guard let sourceTexture = sourceTextureForCurveAdjustment(layerID: session.layerID) else { return }
        guard let renderPlan = curveRenderPlan(for: session) else { return }
        let isPaintedMaskSession: Bool = {
            if case .painted = session.source {
                return true
            }
            return false
        }()

        if curveAdjustmentPreviewRenderInFlight {
            curveAdjustmentPreviewRenderNeedsResubmit = true
            return
        }

        if isPaintedMaskSession,
           !force,
           curveAdjustmentStrokePacketCount > 1,
           !curveAdjustmentStrokePacketCount.isMultiple(of: 3) {
            return
        }

        curveAdjustmentPreviewRenderInFlight = true
        let previewToken = curveAdjustmentPreviewToken

        curveAdjustmentRenderer.renderPreview(
            sourceTexture: sourceTexture,
            previewTexture: session.previewTexture,
            maskTexture: renderPlan.maskTexture,
            maskReadMode: renderPlan.maskReadMode,
            luts: session.luts,
            overlayOnly: session.parameters.isNeutral,
            effectRegion: renderPlan.effectRegion,
            commandQueue: metalContext.commandQueue
        ) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard self.curveAdjustmentPreviewToken == previewToken else { return }
                self.curveAdjustmentPreviewRenderInFlight = false
                self.colorAdjustmentRedrawRevision &+= 1
                if self.curveAdjustmentPreviewRenderNeedsResubmit {
                    self.curveAdjustmentPreviewRenderNeedsResubmit = false
                    self.scheduleCurveAdjustmentPreviewUpdate(force: true)
                }
            }
        }
    }

    private func rebuiltDirectCurveAdjustmentSession(
        layerID: LayerID,
        sourceTexture: MTLTexture,
        preserving session: CurveAdjustmentSession,
        preferredSelectionShape: SelectionShape?
    ) -> CurveAdjustmentSession? {
        let rebuiltSession: CurveAdjustmentSession?
        if let preferredSelectionShape {
            rebuiltSession = makeSelectionCurveAdjustmentSession(
                layerID: layerID,
                sourceTexture: sourceTexture,
                selectionShape: preferredSelectionShape,
                parameters: session.parameters
            )
        } else {
            rebuiltSession = makeWholeLayerCurveAdjustmentSession(
                layerID: layerID,
                sourceTexture: sourceTexture,
                parameters: session.parameters
            )
        }

        guard var rebuiltSession else { return nil }
        rebuiltSession.brushMode = session.brushMode
        rebuiltSession.showsOriginalPreview = session.showsOriginalPreview
        return rebuiltSession
    }

    private func preferredCurveAdjustmentSelectionShape() -> SelectionShape? {
        let canvasSize = workspace.document.canvasSize
        guard let selectionShape = workspace.selection.committedShape?.clamped(to: canvasSize) else {
            return nil
        }
        guard curveEffectRegion(from: selectionShape.bounds) != nil else {
            return nil
        }
        return selectionShape
    }

    private func confirmCurveAdjustmentResolution(
        reason: CurveAdjustmentResolutionReason
    ) -> CurveAdjustmentResolutionDecision {
#if DEBUG
        if let override = debugCurveAdjustmentResolutionDecisionOverride {
            return override
        }
#endif

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "当前曲线调整还未确认"
        alert.informativeText = curveAdjustmentResolutionInformativeText(for: reason)
        alert.addButton(withTitle: "确认效果")
        alert.addButton(withTitle: "放弃")
        alert.addButton(withTitle: "取消")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .apply
        case .alertSecondButtonReturn:
            return .discard
        default:
            return .cancel
        }
    }

    private func curveAdjustmentResolutionInformativeText(
        for reason: CurveAdjustmentResolutionReason
    ) -> String {
        switch reason {
        case .toolChange:
            return "切换工具前，要先确认当前曲线调整效果，还是放弃这次调整？"
        case .panelChange:
            return "切换到另一种调整面板前，要先确认当前曲线调整效果，还是放弃这次调整？"
        case .layerChange:
            return "切换图层前，要先确认当前曲线调整效果，还是放弃这次调整？"
        case .historyNavigation:
            return "继续撤销或重做前，要先确认当前曲线调整效果，还是放弃这次调整？"
        case .documentOpen:
            return "继续打开或新建画布前，要先确认当前曲线调整效果，还是放弃这次调整？"
        case .closeOrQuit:
            return "关闭当前画布前，要先确认当前曲线调整效果，还是放弃这次调整？"
        }
    }

    private func discardCurveAdjustmentSession() {
        curveAdjustmentSession = nil
        curveAdjustmentAllowsIdleModeHotkeys = false
        curveAdjustmentBrushMode = .paint
        curveAdjustmentStrokePacketCount = 0
        curveAdjustmentPreviewToken &+= 1
        curveAdjustmentPreviewRenderInFlight = false
        curveAdjustmentPreviewRenderNeedsResubmit = false
        curveAdjustmentOverlayState = .inactive
        colorAdjustmentRedrawRevision &+= 1
    }

    private func syncCurveAdjustmentOverlayState() {
        guard let session = curveAdjustmentSession else {
            curveAdjustmentOverlayState = .inactive
            syncSelectionOverlayForAdjustmentState()
            return
        }

        curveAdjustmentOverlayState = CurveAdjustmentOverlayState(
            isActive: true,
            selectedChannel: session.parameters.selectedChannel,
            showsOriginalPreview: session.showsOriginalPreview,
            effectiveBounds: session.source.effectiveBounds,
            sourceKind: session.source.sourceKindForOverlay
        )
        syncSelectionOverlayForAdjustmentState()
    }

    private func curveRenderPlan(for session: CurveAdjustmentSession) -> CurveAdjustmentRenderPlan? {
        switch session.source {
        case .wholeLayer(let state):
            return CurveAdjustmentRenderPlan(
                maskTexture: nil,
                maskReadMode: .sourceAlpha,
                effectRegion: curveEffectRegion(from: state.effectBounds)
            )
        case .selection(let state):
            guard let effectRegion = curveEffectRegion(from: state.bounds) else { return nil }
            return CurveAdjustmentRenderPlan(
                maskTexture: state.maskTexture,
                maskReadMode: .maskRed,
                effectRegion: effectRegion
            )
        case .painted(let state):
            guard let effectRegion = curveEffectRegion(from: state.paintedBounds) else { return nil }
            return CurveAdjustmentRenderPlan(
                maskTexture: state.maskTexture,
                maskReadMode: .maskRed,
                effectRegion: effectRegion
            )
        }
    }

    private func curveEffectRegion(from bounds: CanvasRect?) -> MTLRegion? {
        guard let bounds else { return nil }

        let minX = max(0, Int(floor(bounds.origin.x)))
        let minY = max(0, Int(floor(bounds.origin.y)))
        let maxX = min(workspace.document.canvasSize.width, Int(ceil(bounds.origin.x + bounds.size.x)))
        let maxY = min(workspace.document.canvasSize.height, Int(ceil(bounds.origin.y + bounds.size.y)))
        guard maxX > minX, maxY > minY else { return nil }

        return MTLRegionMake2D(minX, minY, maxX - minX, maxY - minY)
    }

    private func makeCurveAdjustmentPreviewTexture(from sourceTexture: MTLTexture) -> MTLTexture? {
        guard let previewTexture = layerSurfaceStore.makeTexture(
            width: sourceTexture.width,
            height: sourceTexture.height,
            pixelFormat: sourceTexture.pixelFormat,
            metal: metalContext
        ) else {
            return nil
        }
        copyCurveTextureContents(from: sourceTexture, to: previewTexture)
        return previewTexture
    }

    private func copyCurveTextureContents(from sourceTexture: MTLTexture, to destinationTexture: MTLTexture) {
        guard
            let commandBuffer = metalContext.commandQueue.makeCommandBuffer(),
            let blitEncoder = commandBuffer.makeBlitCommandEncoder()
        else {
            return
        }

        blitEncoder.copy(
            from: sourceTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: .init(x: 0, y: 0, z: 0),
            sourceSize: .init(width: sourceTexture.width, height: sourceTexture.height, depth: 1),
            to: destinationTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: .init(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func clearCurveAdjustmentMaskTexture(_ texture: MTLTexture) {
        guard let commandBuffer = metalContext.commandQueue.makeCommandBuffer() else { return }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func makeCurveAdjustmentMaskStrokeDescriptor(
        samples: [CanvasStrokeSample],
        skipLeadingStamp: Bool
    ) -> StrokeDescriptor {
        StrokeDescriptor(
            tool: .brush,
            color: curveAdjustmentBrushMode == .paint
                ? .init(red: 1, green: 1, blue: 1, alpha: 1)
                : .init(red: 0, green: 0, blue: 0, alpha: 1),
            brush: workspace.toolSession.brush,
            points: samples.map { .init(x: $0.location.x, y: $0.location.y, pressure: $0.pressure) },
            selectionShape: workspace.selection.committedShape,
            alphaLockEnabled: true,
            skipLeadingStamp: skipLeadingStamp
        )
    }

    private func unionCurveAdjustmentPaintedBounds(
        _ existing: CanvasRect?,
        with samples: [CanvasStrokeSample],
        brushSize: Float
    ) -> CanvasRect? {
        guard !samples.isEmpty else { return existing }

        let radius = Double(max(brushSize * 0.5, 1))
        let minX = samples.map(\.location.x).min()! - radius
        let minY = samples.map(\.location.y).min()! - radius
        let maxX = samples.map(\.location.x).max()! + radius
        let maxY = samples.map(\.location.y).max()! + radius
        let strokeBounds = CanvasRect(
            origin: .init(x: minX, y: minY),
            size: .init(x: maxX - minX, y: maxY - minY)
        ).clamped(to: workspace.document.canvasSize)

        guard let existing else { return strokeBounds }
        let unionMinX = min(existing.origin.x, strokeBounds.origin.x)
        let unionMinY = min(existing.origin.y, strokeBounds.origin.y)
        let unionMaxX = max(existing.origin.x + existing.size.x, strokeBounds.origin.x + strokeBounds.size.x)
        let unionMaxY = max(existing.origin.y + existing.size.y, strokeBounds.origin.y + strokeBounds.size.y)
        return CanvasRect(
            origin: .init(x: unionMinX, y: unionMinY),
            size: .init(x: unionMaxX - unionMinX, y: unionMaxY - unionMinY)
        ).clamped(to: workspace.document.canvasSize)
    }

    private func updateCurveAdjustmentBrushModeIfNeeded() {
        guard var session = curveAdjustmentSession else {
            syncCurveAdjustmentOverlayState()
            return
        }
        if case .painted(var paintedState) = session.source {
            paintedState.brushSamplingState = nil
            paintedState.opacityCapSession = nil
            session.source = .painted(paintedState)
            curveAdjustmentStrokePacketCount = 0
        }
        session.brushMode = curveAdjustmentBrushMode
        curveAdjustmentSession = session
        syncCurveAdjustmentOverlayState()
    }

    private func makeCurveSelectionMaskTexture(
        for selectionShape: SelectionShape,
        canvasSize: CanvasSize
    ) -> MTLTexture? {
        let alphaBytes = selectionMaskBytesForCurveAdjustment(
            shape: selectionShape,
            canvasSize: canvasSize
        )
        guard !alphaBytes.isEmpty else { return nil }
        guard let maskTexture = layerSurfaceStore.makeTexture(
            width: canvasSize.width,
            height: canvasSize.height,
            pixelFormat: .r8Unorm,
            usage: [.shaderRead],
            storageMode: .shared,
            metal: metalContext
        ) else {
            return nil
        }

        alphaBytes.withUnsafeBufferPointer { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            maskTexture.replace(
                region: MTLRegionMake2D(0, 0, canvasSize.width, canvasSize.height),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: canvasSize.width
            )
        }
        return maskTexture
    }

    private func clearCommittedSelectionAfterCurveAdjustmentApply() {
        clearCommittedSelectionWithoutHistory()
    }
}

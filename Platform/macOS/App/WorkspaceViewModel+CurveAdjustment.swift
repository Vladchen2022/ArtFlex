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
        return "当前影响区域：当前图层全部已有像素。点击曲线图开始调整。"
    }

    func beginCurveAdjustmentFromWholeLayerIfNeeded(showFeedback: Bool = true) -> Bool {
        if let issue = curveAdjustmentAvailabilityIssueMessage {
            if showFeedback {
                presentWorkspaceStatus(kind: .info, message: issue)
            }
            return false
        }
        guard let layerID = activeEditableLayerIDForCurveAdjustment(),
              let sourceTexture = sourceTextureForCurveAdjustment(layerID: layerID) else {
            if showFeedback {
                presentWorkspaceStatus(kind: .error, message: "无法访问当前图层")
            }
            return false
        }

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
        scheduleCurveAdjustmentPreviewUpdate()
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
        guard let layerID = activeEditableLayerIDForCurveAdjustment(),
              let surfaceID = layerSurfaceStore.surfaceID(for: layerID),
              let sourceTexture = sourceTextureForCurveAdjustment(layerID: layerID),
              let session = curveAdjustmentSession,
              session.layerID == layerID else {
            if showFeedback {
                presentWorkspaceStatus(kind: .error, message: "无法访问当前图层")
            }
            return false
        }
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

        checkpointSingleLayerHistoryIfPossible(
            layerID: layerID,
            operationKind: "curveAdjustment.commit"
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
        discardCurveAdjustmentSession()
        finalizeCommittedSingleLayerMutation(layerID)
        if showFeedback {
            presentWorkspaceStatus(kind: .success, message: "已应用曲线调整")
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
        guard curveAdjustmentSession != nil else { return false }
        guard modifiers.isEmpty else { return false }

        if event.keyCode == 53 {
            cancelCurveAdjustmentIfNeeded(showFeedback: true)
            return true
        }

        if event.keyCode == 36 || event.keyCode == 76 {
            confirmCurveAdjustmentIfNeeded(showFeedback: true)
            return true
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "b", "e":
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
        if workspace.toolSession.activeTool == .brightnessAdjust {
            return "曲线的蒙版路径将在下一阶段接通；当前先支持整层直调。"
        }
        if workspace.selection.committedShape != nil {
            return "曲线的选区直调将在下一阶段接通；当前先支持整层直调。"
        }
        return nil
    }

    private func preparedCurveAdjustmentSessionForParameterEditing(showFeedback: Bool) -> CurveAdjustmentSession? {
        if let session = curveAdjustmentSession {
            return session
        }
        guard beginCurveAdjustmentFromWholeLayerIfNeeded(showFeedback: showFeedback) else {
            return nil
        }
        return curveAdjustmentSession
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
            parameters: parameters
        )
    }

    private func sourceTextureForCurveAdjustment(layerID: LayerID) -> MTLTexture? {
        guard
            let surfaceID = layerSurfaceStore.surfaceID(for: layerID),
            let texture = layerSurfaceStore.texture(for: surfaceID)
        else {
            return nil
        }
        return texture
    }

    private func scheduleCurveAdjustmentPreviewUpdate() {
        guard let session = curveAdjustmentSession else { return }
        guard let sourceTexture = sourceTextureForCurveAdjustment(layerID: session.layerID) else { return }
        guard let renderPlan = curveRenderPlan(for: session) else { return }

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
                self?.colorAdjustmentRedrawRevision &+= 1
            }
        }
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
        curveAdjustmentOverlayState = .inactive
        colorAdjustmentRedrawRevision &+= 1
    }

    private func syncCurveAdjustmentOverlayState() {
        guard let session = curveAdjustmentSession else {
            curveAdjustmentOverlayState = .inactive
            return
        }

        curveAdjustmentOverlayState = CurveAdjustmentOverlayState(
            isActive: true,
            selectedChannel: session.parameters.selectedChannel,
            showsOriginalPreview: session.showsOriginalPreview,
            effectiveBounds: session.source.effectiveBounds,
            sourceKind: session.source.sourceKindForOverlay
        )
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
}

import AppKit
import Foundation
@preconcurrency import Metal

private struct ColorAdjustmentRenderPlan {
    let maskTexture: MTLTexture?
    let maskReadMode: ColorAdjustmentMaskReadMode
    let effectRegion: MTLRegion?
}

@MainActor
extension WorkspaceViewModel {
    var colorAdjustmentParameters: ColorAdjustmentParameters {
        colorAdjustmentSession?.parameters ?? .neutral
    }

    var isColorAdjustmentToolActive: Bool {
        workspace.toolSession.activeTool == .brightnessAdjust
    }

    var canEditColorAdjustmentParameters: Bool {
        return activeEditableLayerIDForColorAdjustment() != nil
    }

    var canEditColorAdjustmentPaintedSession: Bool {
        guard
            isColorAdjustmentToolActive,
            let activeLayerID = activeEditableLayerIDForColorAdjustment(),
            let session = colorAdjustmentSession
        else {
            return false
        }

        guard session.layerID == activeLayerID else { return false }
        guard case .painted = session.source else { return false }
        return true
    }

    var canConfirmColorAdjustmentSession: Bool {
        guard
            canEditColorAdjustmentParameters,
            let activeLayerID = activeEditableLayerIDForColorAdjustment(),
            let session = colorAdjustmentSession,
            session.layerID == activeLayerID
        else {
            return false
        }
        return session.hasPendingCommittedEffect
    }

    var canConfirmColorAdjustmentPaintedSession: Bool {
        canConfirmColorAdjustmentSession
    }

    var canPreviewColorAdjustmentOriginal: Bool {
        guard let session = colorAdjustmentSession else { return false }
        return session.hasVisiblePreview
    }

    var preferredColorAdjustmentSourceKind: ColorAdjustmentOverlayState.SourceKind {
        if let session = colorAdjustmentSession {
            return session.source.sourceKindForOverlay
        }
        guard canEditColorAdjustmentParameters else { return .none }
        return workspace.selection.committedShape == nil ? .wholeLayer : .selection
    }

    func setColorAdjustmentSelectedHueDegrees(_ value: Float) {
        updateColorAdjustmentParameters { parameters in
            parameters.selectedHueDegrees = ColorBlocksEngine.wrapHue(value)
        }
    }

    func setColorAdjustmentHueStrength(_ value: Float) {
        updateColorAdjustmentParameters { parameters in
            parameters.hueStrength = clampSignedColorAdjustmentValue(value)
        }
    }

    func setColorAdjustmentBrightness(_ value: Float) {
        updateColorAdjustmentParameters { parameters in
            parameters.brightness = clampSignedColorAdjustmentValue(value)
        }
    }

    func setColorAdjustmentContrast(_ value: Float) {
        updateColorAdjustmentParameters { parameters in
            parameters.contrast = clampSignedColorAdjustmentValue(value)
        }
    }

    func setColorAdjustmentPurity(_ value: Float) {
        updateColorAdjustmentParameters { parameters in
            parameters.purity = clampSignedColorAdjustmentValue(value)
        }
    }

    func resetColorAdjustmentParameters() {
        updateColorAdjustmentParameters { parameters in
            parameters = .neutral
        }
    }

    func setColorAdjustmentShowsOriginalPreview(_ showsOriginalPreview: Bool) {
        guard var session = colorAdjustmentSession else { return }
        guard session.showsOriginalPreview != showsOriginalPreview else { return }

        session.showsOriginalPreview = showsOriginalPreview
        colorAdjustmentSession = session
        colorAdjustmentRedrawRevision &+= 1
        syncColorAdjustmentOverlayState()
    }

    @discardableResult
    func confirmColorAdjustmentSession() -> Bool {
        guard canEditColorAdjustmentParameters else {
            presentWorkspaceStatus(kind: .info, message: "请先切到可编辑图层")
            return false
        }
        guard let preparedContext = preparedEditableAdjustmentLayerContext(reason: "colorAdjustment.confirm"),
              let surfaceID = layerSurfaceStore.surfaceID(for: preparedContext.layerID),
              let session = colorAdjustmentSession,
              session.layerID == preparedContext.layerID else {
            presentWorkspaceStatus(kind: .error, message: "无法访问当前图层")
            return false
        }
        let layerID = preparedContext.layerID
        let sourceTexture = preparedContext.sourceTexture
        guard !session.parameters.isNeutral else {
            presentWorkspaceStatus(kind: .info, message: "当前还没有可应用的调整")
            return false
        }
        switch session.source {
        case .painted(let paintedState):
            guard paintedState.paintedBounds != nil else {
                presentWorkspaceStatus(kind: .info, message: "先在画布上涂出影响区域")
                return false
            }
        case .selection(let selectionState):
            guard effectRegion(from: selectionState.bounds) != nil else {
                presentWorkspaceStatus(kind: .info, message: "当前选区为空")
                return false
            }
        case .wholeLayer:
            break
        }
        guard let renderPlan = renderPlan(for: session) else {
            presentWorkspaceStatus(kind: .error, message: "无法准备色彩调整范围")
            return false
        }
        guard let targetTexture = layerSurfaceStore.makeTexture(
            width: sourceTexture.width,
            height: sourceTexture.height,
            pixelFormat: sourceTexture.pixelFormat,
            metal: metalContext
        ) else {
            presentWorkspaceStatus(kind: .error, message: "无法创建色彩调整结果纹理")
            return false
        }
        guard let commandBuffer = metalContext.commandQueue.makeCommandBuffer() else {
            presentWorkspaceStatus(kind: .error, message: "无法创建色彩调整提交命令")
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
            operationKind: "colorAdjustment.commit",
            workspaceOverride: historyWorkspaceOverride
        )

        colorAdjustmentRenderer.encodePreview(
            sourceTexture: sourceTexture,
            previewTexture: targetTexture,
            maskTexture: renderPlan.maskTexture,
            maskReadMode: renderPlan.maskReadMode,
            parameters: session.parameters,
            overlayOnly: false,
            effectRegion: renderPlan.effectRegion,
            commandBuffer: commandBuffer
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        guard commandBuffer.status == .completed else {
            let message = commandBuffer.error?.localizedDescription ?? "色彩调整提交失败"
            presentWorkspaceStatus(kind: .error, message: message)
            return false
        }

        layerSurfaceStore.swapTexture(for: surfaceID, with: targetTexture)
        if shouldClearCommittedSelectionAfterApply {
            clearCommittedSelectionAfterColorAdjustmentApply()
        }
        discardColorAdjustmentSession()
        finalizeCommittedSingleLayerMutation(layerID)
        presentWorkspaceStatus(
            kind: .success,
            message: shouldClearCommittedSelectionAfterApply ? "已应用色彩调整，并取消选区" : "已应用色彩调整"
        )
        return true
    }

    @discardableResult
    func confirmColorAdjustmentPaintedSession() -> Bool {
        confirmColorAdjustmentSession()
    }

    @discardableResult
    func resolveColorAdjustmentSessionIfNeeded(
        reason: ColorAdjustmentResolutionReason
    ) -> Bool {
        guard let session = colorAdjustmentSession else { return true }
        guard session.hasPendingCommittedEffect else {
            discardColorAdjustmentSession()
            return true
        }

        switch confirmColorAdjustmentResolution(reason: reason) {
        case .apply:
            guard confirmColorAdjustmentSession() else { return false }
        case .discard:
            discardColorAdjustmentSession()
            presentWorkspaceStatus(kind: .info, message: "已放弃当前色彩调整")
        case .cancel:
            return false
        }

        return reason.continuesTriggeringActionAfterResolution
    }

    func beginColorAdjustmentStrokeIfNeeded() {
        guard let activeContext = activeEditableAdjustmentLayerContext() else { return }
        let layerID = activeContext.layerID
        let sourceTexture = activeContext.sourceTexture

        let carriedParameters = colorAdjustmentSession?.parameters ?? .neutral
        let requiresPaintedMaskSession: Bool = {
            guard let session = colorAdjustmentSession, session.layerID == layerID else {
                return true
            }
            if case .painted = session.source {
                return false
            }
            return true
        }()

        if requiresPaintedMaskSession {
            colorAdjustmentPreviewToken &+= 1
            colorAdjustmentPreviewRenderInFlight = false
            colorAdjustmentPreviewRenderNeedsResubmit = false
            colorAdjustmentSession = makePaintedColorAdjustmentSession(
                layerID: layerID,
                sourceTexture: sourceTexture,
                parameters: carriedParameters
            )
        }

        colorAdjustmentStrokePacketCount = 0
        colorAdjustmentPreviewRenderNeedsResubmit = false
        syncColorAdjustmentOverlayState()
    }

    func applyColorAdjustmentStroke(samples: [CanvasStrokeSample]) {
        guard !samples.isEmpty else { return }
        guard let activeContext = activeEditableAdjustmentLayerContext() else { return }
        let layerID = activeContext.layerID
        let sourceTexture = activeContext.sourceTexture
        guard var session = colorAdjustmentSession, session.layerID == layerID else { return }
        guard case .painted(var paintedState) = session.source else { return }

        let skipLeadingStamp = colorAdjustmentStrokePacketCount > 0
        let stroke = makeColorAdjustmentMaskStrokeDescriptor(
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

        paintedState.paintedBounds = unionPaintedBounds(
            paintedState.paintedBounds,
            with: samples,
            brushSize: stroke.brush.size
        )

        session.source = .painted(paintedState)
        session.brushMode = colorAdjustmentBrushMode
        colorAdjustmentSession = session
        colorAdjustmentStrokePacketCount += 1
        let shouldRenderPreviewNow =
            colorAdjustmentStrokePacketCount == 1
            || colorAdjustmentStrokePacketCount.isMultiple(of: 3)
        if shouldRenderPreviewNow {
            scheduleColorAdjustmentPreviewUpdate()
        }
        syncColorAdjustmentOverlayState()
    }

    func endColorAdjustmentStroke() {
        guard var session = colorAdjustmentSession else { return }
        guard case .painted(var paintedState) = session.source else { return }
        guard let activeContext = activeEditableAdjustmentLayerContext() else { return }
        let sourceTexture = activeContext.sourceTexture

        defer {
            session.source = .painted(paintedState)
            colorAdjustmentSession = session
            colorAdjustmentStrokePacketCount = 0
            scheduleColorAdjustmentPreviewUpdate(force: true)
            syncColorAdjustmentOverlayState()
        }

        guard paintedState.brushSamplingState != nil else { return }

        var flushSamplingState = paintedState.brushSamplingState
        flushSamplingState?.isFlushing = true
        let flushStroke = StrokeDescriptor(
            tool: .brush,
            color: colorAdjustmentBrushMode == .paint
                ? .init(red: 1, green: 1, blue: 1, alpha: 1)
                : .init(red: 0, green: 0, blue: 0, alpha: 1),
            brush: workspace.toolSession.brush,
            points: [],
            selectionShape: workspace.selection.committedShape,
            alphaLockEnabled: true,
            skipLeadingStamp: true
        )

        if flushStroke.brush.requiresStrokeMaskSession, let opacityCapSession = paintedState.opacityCapSession {
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

    func handleColorAdjustmentKeyDown(
        _ event: NSEvent,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard modifiers.isEmpty else { return false }
        guard colorAdjustmentSession != nil || colorAdjustmentAllowsIdleModeHotkeys else {
            return false
        }

        if event.keyCode == 53 {
            guard colorAdjustmentSession != nil else { return false }
            discardColorAdjustmentSession()
            return true
        }

        if event.keyCode == 36 || event.keyCode == 76 {
            guard colorAdjustmentSession != nil else { return false }
            return confirmColorAdjustmentSession()
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "e":
            colorAdjustmentBrushMode = .erase
            updateColorAdjustmentBrushModeIfNeeded()
            return true
        case "b":
            colorAdjustmentBrushMode = .paint
            updateColorAdjustmentBrushModeIfNeeded()
            return true
        default:
            return false
        }
    }

    func activeColorAdjustmentPreviewTexture(for layerID: LayerID) -> MTLTexture? {
        guard let session = colorAdjustmentSession, session.layerID == layerID else { return nil }
        guard !session.showsOriginalPreview, session.hasVisiblePreview else { return nil }
        return session.previewTexture
    }

    func syncColorAdjustmentSessionToCurrentContextIfNeeded() {
        guard let session = colorAdjustmentSession else { return }
        guard let activeContext = activeEditableAdjustmentLayerContext(),
              session.layerID == activeContext.layerID else {
            return
        }
        let activeLayerID = activeContext.layerID
        let sourceTexture = activeContext.sourceTexture

        let replacementSession: ColorAdjustmentSession?
        switch session.source {
        case .painted:
            replacementSession = nil
        case .selection(let selectionState):
            guard let selectionShape = preferredColorAdjustmentSelectionShape() else {
                replacementSession = rebuiltDirectColorAdjustmentSession(
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
            replacementSession = rebuiltDirectColorAdjustmentSession(
                layerID: activeLayerID,
                sourceTexture: sourceTexture,
                preserving: session,
                preferredSelectionShape: selectionShape
            )
        case .wholeLayer(let wholeLayerState):
            if let selectionShape = preferredColorAdjustmentSelectionShape() {
                replacementSession = rebuiltDirectColorAdjustmentSession(
                    layerID: activeLayerID,
                    sourceTexture: sourceTexture,
                    preserving: session,
                    preferredSelectionShape: selectionShape
                )
            } else if wholeLayerState.capturedCanvasRevision != canvasContentRevision {
                replacementSession = rebuiltDirectColorAdjustmentSession(
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
        colorAdjustmentSession = replacementSession
        scheduleColorAdjustmentPreviewUpdate(force: true)
        syncColorAdjustmentOverlayState()
    }

    private func makePaintedColorAdjustmentSession(
        layerID: LayerID,
        sourceTexture: MTLTexture,
        parameters: ColorAdjustmentParameters = .neutral
    ) -> ColorAdjustmentSession? {
        guard
            let previewTexture = makeColorAdjustmentPreviewTexture(from: sourceTexture),
            let maskTexture = layerSurfaceStore.makeTexture(
                width: sourceTexture.width,
                height: sourceTexture.height,
                pixelFormat: .bgra8Unorm_srgb,
                metal: metalContext
            )
        else {
            return nil
        }

        clearTexture(maskTexture)
        copyTextureContents(from: sourceTexture, to: previewTexture)
        return ColorAdjustmentSession(
            layerID: layerID,
            source: .painted(
                PaintedMaskState(
                    maskTexture: maskTexture,
                    paintedBounds: nil,
                    brushSamplingState: nil,
                    opacityCapSession: nil
                )
            ),
            previewTexture: previewTexture,
            parameters: parameters,
            brushMode: colorAdjustmentBrushMode
        )
    }

    private func makeSelectionColorAdjustmentSession(
        layerID: LayerID,
        sourceTexture: MTLTexture,
        selectionShape: SelectionShape,
        parameters: ColorAdjustmentParameters
    ) -> ColorAdjustmentSession? {
        let canvasSize = CanvasSize(width: sourceTexture.width, height: sourceTexture.height)
        let clampedSelection = selectionShape.clamped(to: canvasSize)
        guard let boundsRegion = effectRegion(from: clampedSelection.bounds) else {
            return nil
        }
        guard let previewTexture = makeColorAdjustmentPreviewTexture(from: sourceTexture),
              let maskTexture = makeSelectionMaskTexture(
                for: clampedSelection,
                canvasSize: canvasSize
              ) else {
            return nil
        }

        return ColorAdjustmentSession(
            layerID: layerID,
            source: .selection(
                SelectionMaskState(
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
            brushMode: colorAdjustmentBrushMode
        )
    }

    private func makeWholeLayerColorAdjustmentSession(
        layerID: LayerID,
        sourceTexture: MTLTexture,
        parameters: ColorAdjustmentParameters
    ) -> ColorAdjustmentSession? {
        guard let previewTexture = makeColorAdjustmentPreviewTexture(from: sourceTexture) else {
            return nil
        }

        return ColorAdjustmentSession(
            layerID: layerID,
            source: .wholeLayer(
                WholeLayerMaskState(
                    effectBounds: activeEditableLayerEffectBoundsForColorAdjustment(),
                    capturedCanvasRevision: canvasContentRevision
                )
            ),
            previewTexture: previewTexture,
            parameters: parameters,
            brushMode: colorAdjustmentBrushMode
        )
    }

    private func makeColorAdjustmentMaskStrokeDescriptor(
        samples: [CanvasStrokeSample],
        skipLeadingStamp: Bool
    ) -> StrokeDescriptor {
        StrokeDescriptor(
            tool: .brush,
            color: colorAdjustmentBrushMode == .paint
                ? .init(red: 1, green: 1, blue: 1, alpha: 1)
                : .init(red: 0, green: 0, blue: 0, alpha: 1),
            brush: workspace.toolSession.brush,
            points: samples.map { .init(x: $0.location.x, y: $0.location.y, pressure: $0.pressure) },
            selectionShape: workspace.selection.committedShape,
            alphaLockEnabled: true,
            skipLeadingStamp: skipLeadingStamp
        )
    }

    private func sourceTextureForColorAdjustment(layerID: LayerID) -> MTLTexture? {
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

    private func unionPaintedBounds(
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

    private func clearTexture(_ texture: MTLTexture) {
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

    private func scheduleColorAdjustmentPreviewUpdate(force: Bool = false) {
        guard let session = colorAdjustmentSession else { return }
        guard let sourceTexture = sourceTextureForColorAdjustment(layerID: session.layerID) else { return }
        guard let renderPlan = renderPlan(for: session) else { return }
        let isPaintedMaskSession: Bool = {
            if case .painted = session.source {
                return true
            }
            return false
        }()

        if colorAdjustmentPreviewRenderInFlight {
            colorAdjustmentPreviewRenderNeedsResubmit = true
            return
        }

        if isPaintedMaskSession,
           !force,
           colorAdjustmentStrokePacketCount > 1,
           !colorAdjustmentStrokePacketCount.isMultiple(of: 3) {
            return
        }

        colorAdjustmentPreviewRenderInFlight = true
        let previewToken = colorAdjustmentPreviewToken

        colorAdjustmentRenderer.renderPreview(
            sourceTexture: sourceTexture,
            previewTexture: session.previewTexture,
            maskTexture: renderPlan.maskTexture,
            maskReadMode: renderPlan.maskReadMode,
            parameters: session.parameters,
            overlayOnly: session.parameters.isNeutral,
            effectRegion: renderPlan.effectRegion,
            commandQueue: metalContext.commandQueue
        ) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard self.colorAdjustmentPreviewToken == previewToken else { return }
                self.colorAdjustmentPreviewRenderInFlight = false
                self.colorAdjustmentRedrawRevision &+= 1
                if self.colorAdjustmentPreviewRenderNeedsResubmit {
                    self.colorAdjustmentPreviewRenderNeedsResubmit = false
                    self.scheduleColorAdjustmentPreviewUpdate(force: true)
                }
            }
        }
    }

    private func updateColorAdjustmentBrushModeIfNeeded() {
        guard var session = colorAdjustmentSession else {
            syncColorAdjustmentOverlayState()
            return
        }
        if case .painted(var paintedState) = session.source {
            paintedState.brushSamplingState = nil
            paintedState.opacityCapSession = nil
            session.source = .painted(paintedState)
            colorAdjustmentStrokePacketCount = 0
        }
        session.brushMode = colorAdjustmentBrushMode
        colorAdjustmentSession = session
        syncColorAdjustmentOverlayState()
    }

    private func confirmColorAdjustmentResolution(
        reason: ColorAdjustmentResolutionReason
    ) -> ColorAdjustmentResolutionDecision {
#if DEBUG
        if let override = debugColorAdjustmentResolutionDecisionOverride {
            return override
        }
#endif

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "当前色彩调整还未确认"
        alert.informativeText = colorAdjustmentResolutionInformativeText(for: reason)
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

    private func colorAdjustmentResolutionInformativeText(
        for reason: ColorAdjustmentResolutionReason
    ) -> String {
        switch reason {
        case .toolChange:
            return "切换工具前，要先确认当前色彩调整效果，还是放弃这次调整？"
        case .panelChange:
            return "切换到另一种调整面板前，要先确认当前色彩调整效果，还是放弃这次调整？"
        case .layerChange:
            return "切换图层前，要先确认当前色彩调整效果，还是放弃这次调整？"
        case .historyNavigation:
            return "继续撤销或重做前，要先确认当前色彩调整效果，还是放弃这次调整？"
        case .documentOpen:
            return "继续打开或新建画布前，要先确认当前色彩调整效果，还是放弃这次调整？"
        case .closeOrQuit:
            return "关闭当前画布前，要先确认当前色彩调整效果，还是放弃这次调整？"
        }
    }

    private func discardColorAdjustmentSession() {
        colorAdjustmentSession = nil
        colorAdjustmentAllowsIdleModeHotkeys = false
        colorAdjustmentBrushMode = .paint
        colorAdjustmentStrokePacketCount = 0
        colorAdjustmentPreviewToken &+= 1
        colorAdjustmentPreviewRenderInFlight = false
        colorAdjustmentPreviewRenderNeedsResubmit = false
        colorAdjustmentRedrawRevision &+= 1
        syncColorAdjustmentOverlayState()
    }

    private func clearCommittedSelectionAfterColorAdjustmentApply() {
        clearCommittedSelectionWithoutHistory()
    }

    private func syncColorAdjustmentOverlayState() {
        guard let session = colorAdjustmentSession else {
            colorAdjustmentOverlayState = .inactive
            syncSelectionOverlayForAdjustmentState()
            return
        }

        colorAdjustmentOverlayState = ColorAdjustmentOverlayState(
            isActive: true,
            brushMode: session.brushMode,
            selectedHueDegrees: session.parameters.selectedHueDegrees,
            hueStrength: session.parameters.hueStrength,
            brightness: session.parameters.brightness,
            contrast: session.parameters.contrast,
            purity: session.parameters.purity,
            showsOriginalPreview: session.showsOriginalPreview,
            effectiveBounds: session.source.effectiveBounds,
            sourceKind: session.source.sourceKindForOverlay
        )
        syncSelectionOverlayForAdjustmentState()
    }

    private func effectRegion(from bounds: CanvasRect?) -> MTLRegion? {
        guard let bounds else { return nil }

        let minX = max(0, Int(floor(bounds.origin.x)))
        let minY = max(0, Int(floor(bounds.origin.y)))
        let maxX = min(workspace.document.canvasSize.width, Int(ceil(bounds.origin.x + bounds.size.x)))
        let maxY = min(workspace.document.canvasSize.height, Int(ceil(bounds.origin.y + bounds.size.y)))
        guard maxX > minX, maxY > minY else { return nil }

        return MTLRegionMake2D(minX, minY, maxX - minX, maxY - minY)
    }

    private func copyTextureContents(from sourceTexture: MTLTexture, to destinationTexture: MTLTexture) {
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

    private func updateColorAdjustmentParameters(
        _ mutate: (inout ColorAdjustmentParameters) -> Void
    ) {
        guard canEditColorAdjustmentParameters else { return }
        guard var session = preparedColorAdjustmentSessionForParameterEditing() else { return }

        var nextParameters = session.parameters
        mutate(&nextParameters)
        nextParameters = normalizedColorAdjustmentParameters(nextParameters)
        guard nextParameters != session.parameters else { return }

        session.parameters = nextParameters
        colorAdjustmentSession = session
        scheduleColorAdjustmentPreviewUpdate(force: true)
        syncColorAdjustmentOverlayState()
    }

    private func normalizedColorAdjustmentParameters(
        _ parameters: ColorAdjustmentParameters
    ) -> ColorAdjustmentParameters {
        var normalized = parameters
        normalized.selectedHueDegrees = ColorBlocksEngine.wrapHue(normalized.selectedHueDegrees)
        normalized.hueStrength = clampSignedColorAdjustmentValue(normalized.hueStrength)
        normalized.brightness = clampSignedColorAdjustmentValue(normalized.brightness)
        normalized.contrast = clampSignedColorAdjustmentValue(normalized.contrast)
        normalized.purity = clampSignedColorAdjustmentValue(normalized.purity)
        return normalized
    }

    private func clampSignedColorAdjustmentValue(_ value: Float) -> Float {
        min(max(value, -1), 1)
    }

    private func preparedColorAdjustmentSessionForParameterEditing() -> ColorAdjustmentSession? {
        guard let preparedContext = preparedEditableAdjustmentLayerContext(reason: "colorAdjustment.prepareParameters") else {
            return nil
        }
        let layerID = preparedContext.layerID
        let sourceTexture = preparedContext.sourceTexture
        if let session = colorAdjustmentSession, session.layerID == layerID {
            syncColorAdjustmentSessionToCurrentContextIfNeeded()
            return colorAdjustmentSession
        }

        let parameters = colorAdjustmentSession?.parameters ?? .neutral
        let nextSession: ColorAdjustmentSession?
        if let selectionShape = preferredColorAdjustmentSelectionShape() {
            nextSession = makeSelectionColorAdjustmentSession(
                layerID: layerID,
                sourceTexture: sourceTexture,
                selectionShape: selectionShape,
                parameters: parameters
            )
        } else {
            nextSession = makeWholeLayerColorAdjustmentSession(
                layerID: layerID,
                sourceTexture: sourceTexture,
                parameters: parameters
            )
        }

        colorAdjustmentSession = nextSession
        return nextSession
    }

    private func rebuiltDirectColorAdjustmentSession(
        layerID: LayerID,
        sourceTexture: MTLTexture,
        preserving session: ColorAdjustmentSession,
        preferredSelectionShape: SelectionShape?
    ) -> ColorAdjustmentSession? {
        let rebuiltSession: ColorAdjustmentSession?
        if let preferredSelectionShape {
            rebuiltSession = makeSelectionColorAdjustmentSession(
                layerID: layerID,
                sourceTexture: sourceTexture,
                selectionShape: preferredSelectionShape,
                parameters: session.parameters
            )
        } else {
            rebuiltSession = makeWholeLayerColorAdjustmentSession(
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

    private func preferredColorAdjustmentSelectionShape() -> SelectionShape? {
        let canvasSize = workspace.document.canvasSize
        guard let selectionShape = workspace.selection.committedShape?.clamped(to: canvasSize) else {
            return nil
        }
        guard effectRegion(from: selectionShape.bounds) != nil else {
            return nil
        }
        return selectionShape
    }

    private func renderPlan(for session: ColorAdjustmentSession) -> ColorAdjustmentRenderPlan? {
        switch session.source {
        case .painted(let paintedState):
            guard let effectRegion = effectRegion(from: paintedState.paintedBounds) else {
                return nil
            }
            return ColorAdjustmentRenderPlan(
                maskTexture: paintedState.maskTexture,
                maskReadMode: .maskRed,
                effectRegion: effectRegion
            )
        case .selection(let selectionState):
            guard let effectRegion = effectRegion(from: selectionState.bounds) else {
                return nil
            }
            return ColorAdjustmentRenderPlan(
                maskTexture: selectionState.maskTexture,
                maskReadMode: .maskRed,
                effectRegion: effectRegion
            )
        case .wholeLayer(let wholeLayerState):
            return ColorAdjustmentRenderPlan(
                maskTexture: nil,
                maskReadMode: .sourceAlpha,
                effectRegion: effectRegion(from: wholeLayerState.effectBounds)
            )
        }
    }

    private func makeColorAdjustmentPreviewTexture(from sourceTexture: MTLTexture) -> MTLTexture? {
        guard let previewTexture = layerSurfaceStore.makeTexture(
            width: sourceTexture.width,
            height: sourceTexture.height,
            pixelFormat: sourceTexture.pixelFormat,
            metal: metalContext
        ) else {
            return nil
        }
        copyTextureContents(from: sourceTexture, to: previewTexture)
        return previewTexture
    }

    private func makeSelectionMaskTexture(
        for selectionShape: SelectionShape,
        canvasSize: CanvasSize
    ) -> MTLTexture? {
        let alphaBytes = selectionMaskBytesForColorAdjustment(
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
}

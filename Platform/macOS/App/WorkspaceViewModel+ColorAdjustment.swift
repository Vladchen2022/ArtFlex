import AppKit
import Foundation
@preconcurrency import Metal

@MainActor
extension WorkspaceViewModel {
    var colorAdjustmentParameters: ColorAdjustmentParameters {
        colorAdjustmentSession?.parameters ?? .neutral
    }

    var isColorAdjustmentToolActive: Bool {
        workspace.toolSession.activeTool == .brightnessAdjust
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

    func beginColorAdjustmentStrokeIfNeeded() {
        guard let layerID = activeEditableLayerIDForColorAdjustment() else { return }
        guard let sourceTexture = sourceTextureForColorAdjustment(layerID: layerID) else { return }

        if colorAdjustmentSession == nil || colorAdjustmentSession?.layerID != layerID {
            colorAdjustmentPreviewToken &+= 1
            colorAdjustmentPreviewRenderInFlight = false
            colorAdjustmentPreviewRenderNeedsResubmit = false
            colorAdjustmentSession = makePaintedColorAdjustmentSession(
                layerID: layerID,
                sourceTexture: sourceTexture
            )
        }

        colorAdjustmentStrokePacketCount = 0
        colorAdjustmentPreviewRenderNeedsResubmit = false
        syncColorAdjustmentOverlayState()
    }

    func applyColorAdjustmentStroke(samples: [CanvasStrokeSample]) {
        guard !samples.isEmpty else { return }
        guard let layerID = activeEditableLayerIDForColorAdjustment() else { return }
        guard let sourceTexture = sourceTextureForColorAdjustment(layerID: layerID) else { return }
        guard var session = colorAdjustmentSession, session.layerID == layerID else { return }
        guard case .painted(var paintedState) = session.source else { return }

        let skipLeadingStamp = colorAdjustmentStrokePacketCount > 0
        let stroke = makeColorAdjustmentMaskStrokeDescriptor(
            samples: samples,
            skipLeadingStamp: skipLeadingStamp
        )

        if stroke.brush.buildMode == BrushBuildMode.opacityCap {
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
                    samplingState: &paintedState.brushSamplingState
                )
            }
        } else {
            _ = colorAdjustmentStrokeEngine.renderImmediateStroke(
                stroke,
                to: paintedState.maskTexture,
                alphaLockTexture: sourceTexture,
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
        guard let layerID = activeEditableLayerIDForColorAdjustment() else { return }
        guard let sourceTexture = sourceTextureForColorAdjustment(layerID: layerID) else { return }

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

        if flushStroke.brush.buildMode == BrushBuildMode.opacityCap, let opacityCapSession = paintedState.opacityCapSession {
            _ = colorAdjustmentStrokeEngine.renderImmediateOpacityCapStroke(
                flushStroke,
                session: opacityCapSession,
                to: paintedState.maskTexture,
                alphaLockTexture: sourceTexture,
                samplingState: &flushSamplingState
            )
            paintedState.opacityCapSession = nil
        } else {
            _ = colorAdjustmentStrokeEngine.renderImmediateStroke(
                flushStroke,
                to: paintedState.maskTexture,
                alphaLockTexture: sourceTexture,
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

        if event.keyCode == 53 {
            guard colorAdjustmentSession != nil else { return false }
            discardColorAdjustmentSession()
            return true
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
        guard workspace.toolSession.activeTool == .brightnessAdjust else { return nil }
        guard let session = colorAdjustmentSession, session.layerID == layerID else { return nil }
        guard !session.showsOriginalPreview, session.hasVisiblePreview else { return nil }
        return session.previewTexture
    }

    private func makePaintedColorAdjustmentSession(
        layerID: LayerID,
        sourceTexture: MTLTexture
    ) -> ColorAdjustmentSession? {
        guard
            let previewTexture = layerSurfaceStore.makeTexture(
                width: sourceTexture.width,
                height: sourceTexture.height,
                pixelFormat: sourceTexture.pixelFormat,
                metal: metalContext
            ),
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
        guard case .painted(let paintedState) = session.source else { return }
        guard let effectRegion = effectRegion(from: paintedState.paintedBounds) else { return }

        if colorAdjustmentPreviewRenderInFlight {
            colorAdjustmentPreviewRenderNeedsResubmit = true
            return
        }

        if !force, colorAdjustmentStrokePacketCount > 1, !colorAdjustmentStrokePacketCount.isMultiple(of: 3) {
            return
        }

        colorAdjustmentPreviewRenderInFlight = true
        let previewToken = colorAdjustmentPreviewToken

        colorAdjustmentRenderer.renderPreview(
            sourceTexture: sourceTexture,
            previewTexture: session.previewTexture,
            maskTexture: paintedState.maskTexture,
            maskReadMode: .maskRed,
            parameters: session.parameters,
            overlayOnly: session.parameters.isNeutral,
            effectRegion: effectRegion,
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

    private func discardColorAdjustmentSession() {
        colorAdjustmentSession = nil
        colorAdjustmentBrushMode = .paint
        colorAdjustmentStrokePacketCount = 0
        colorAdjustmentPreviewToken &+= 1
        colorAdjustmentPreviewRenderInFlight = false
        colorAdjustmentPreviewRenderNeedsResubmit = false
        colorAdjustmentRedrawRevision &+= 1
        syncColorAdjustmentOverlayState()
    }

    private func syncColorAdjustmentOverlayState() {
        guard let session = colorAdjustmentSession else {
            colorAdjustmentOverlayState = .inactive
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
        guard canEditColorAdjustmentPaintedSession else { return }
        guard var session = colorAdjustmentSession else { return }

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
}

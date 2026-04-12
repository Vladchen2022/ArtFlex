import SwiftUI
import os

private let selectionTraceLogger = Logger(subsystem: "ArtFlex", category: "SelectionTrace")
private func emitSelectionTraceCanvas(_ message: String) {
    appendSelectionTrace(message)
}

struct CanvasContainerView: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    var onCanvasInteraction: (() -> Void)? = nil
    @State private var panStartOffset: CanvasPoint?
    private static let showsSelectionDebugOverlay = false

    var body: some View {
        GeometryReader { geometry in
            // CanvasViewportHost 只订阅 viewport（zoom/pan/rotation），
            // 缩放时 overlay 层完全不参与 SwiftUI layout diff
            CanvasViewportHost(
                viewport: viewModel.workspace.viewport,
                canvasSize: viewModel.workspace.document.canvasSize,
                availableSize: geometry.size
            ) { presentation, documentPresentation, documentCenter in
            ZStack(alignment: .topLeading) {
                Color(
                    red: 136.0 / 255.0,
                    green: 136.0 / 255.0,
                    blue: 136.0 / 255.0
                )
                    .clipped()

                ZStack(alignment: .topLeading) {
                    CanvasDocumentShadow(presentation: documentPresentation)

                    MetalCanvasHost(
                        sceneSnapshot: viewModel.sceneSnapshot,
                        externalRedrawRevision: 0,
                        transformSelectionShape: viewModel.transformPreparationSelectionShape,
                        metalContext: viewModel.metalContext,
                        layerSurfaceStore: viewModel.layerSurfaceStore,
                        activeTool: viewModel.workspace.toolSession.activeTool,
                        viewportRotationDegrees: viewModel.workspace.viewport.rotationDegrees,
                        strokeResetToken: viewModel.strokeResetToken,
                        brushSize: viewModel.workspace.toolSession.brush.size,
                        isPanModeActive: viewModel.isPanModeActive,
                        isTransformingSelection: viewModel.isTransformingSelection,
                        isFreeTransformDragging: viewModel.isFreeTransformDragging,
                        activeFreeTransformInteractionMode: viewModel.activeFreeTransformInteractionMode,
                        transformPreview: viewModel.freeTransformPreview,
                        linearGradientPreview: viewModel.linearGradientState.preview,
                        sectorGradientPreview: viewModel.sectorGradientState.preview,
                        gradientPreviewColor: viewModel.gradientPreviewColor,
                        gradientPaintJitterAmount: viewModel.workspace.toolSession.brush.paintJitterAmount,
                        gradientPaintContrastAmount: viewModel.workspace.toolSession.brush.paintContrastAmount,
                        gradientDistortionAmount: viewModel.workspace.toolSession.brush.jitterAmount,
                        onStrokeBegan: {
                            onCanvasInteraction?()
                            viewModel.beginStrokeIfNeeded()
                        },
                        onStrokeInput: { samples in
                            viewModel.applyStroke(samples: samples)
                        },
                        onStrokeEnded: {
                            onCanvasInteraction?()
                            viewModel.endStroke()
                        },
                        onFlushPendingBrushWork: { commandBuffer in
                            viewModel.flushPendingBrushWork(into: commandBuffer)
                        },
                        onDrainPendingBrushCommitsInteractively: { hadLiveBrushWorkThisFrame in
                            viewModel.opportunisticallyDrainBrushCommits(
                                hadLiveBrushWorkThisFrame: hadLiveBrushWorkThisFrame
                            )
                        },
                        resolveBrushDisplayTexture: { layerID in
                            viewModel.brushDisplayTexture(for: layerID)
                        },
                        onEyedropperSample: { point in
                            onCanvasInteraction?()
                            viewModel.sampleColor(at: point)
                        },
                        onBucketFill: { point in
                            onCanvasInteraction?()
                            viewModel.fillAtPoint(point)
                        },
                        onCanvasClick: { point, modifiers, clickCount in
                            onCanvasInteraction?()
                            viewModel.handleCanvasToolClick(at: point, modifiers: modifiers, clickCount: clickCount)
                        },
                        onCanvasHover: { point in
                            viewModel.updateCanvasToolHover(to: point)
                        },
                        onSelectionBegan: { point, modifiers in
                            onCanvasInteraction?()
                            let kind: SelectionShapeKind =
                                switch viewModel.workspace.toolSession.activeTool {
                                case .ellipseSelection:
                                    .ellipse
                                case .lassoSelection, .lassoFill:
                                    .lasso
                                default:
                                    .rectangle
                                }
                            viewModel.beginSelection(kind: kind, at: point, modifiers: modifiers)
                        },
                        onSelectionChanged: { point, modifiers in
                            onCanvasInteraction?()
                            viewModel.updateSelection(to: point, modifiers: modifiers)
                        },
                        onSelectionEnded: { point, modifiers in
                            onCanvasInteraction?()
                            viewModel.commitSelection(at: point, modifiers: modifiers)
                        },
                        onSelectionMouseDown: { point, modifiers in
                            onCanvasInteraction?()
                            return viewModel.handleSelectionMouseDown(at: point, modifiers: modifiers)
                        },
                        onMoveSelectionPreview: { deltaX, deltaY in
                            onCanvasInteraction?()
                            viewModel.moveSelectionPreview(by: deltaX, deltaY: deltaY)
                        },
                        onCommitSelectionMove: {
                            onCanvasInteraction?()
                            viewModel.commitSelectionMove()
                        },
                        onTransformBegan: { point, mode, modifiers in
                            onCanvasInteraction?()
                            viewModel.beginSelectionTransform(at: point, mode: mode, modifiers: modifiers)
                        },
                        onTransformChanged: { point, modifiers in
                            onCanvasInteraction?()
                            viewModel.updateSelectionTransform(to: point, modifiers: modifiers)
                        },
                        onTransformEnded: { point, modifiers in
                            onCanvasInteraction?()
                            viewModel.commitSelectionTransform(at: point, modifiers: modifiers)
                        },
                        onTransformOffsetChanged: { offset in
                            onCanvasInteraction?()
                            viewModel.setTransformPreviewOffset(offset)
                        },
                        onCanvasRotationChanged: { angleDegrees in
                            viewModel.setViewportRotation(angleDegrees)
                        },
                        onPanModeChanged: { isActive in
                            viewModel.setPanModeActive(isActive)
                        },
                        onToolShortcut: { key, modifiers in
                            _ = viewModel.handleToolShortcutKey(key, modifiers: modifiers)
                        },
                        onKeyDown: { event in
                            viewModel.handleKeyDown(event)
                        },
                        onKeyUp: { event in
                            viewModel.handleKeyUp(event)
                        },
                        onModifierFlagsChanged: { modifiers in
                            viewModel.handleModifierFlagsChanged(modifiers)
                        },
                        onGradientDragBegan: { point, modifiers in
                            onCanvasInteraction?()
                            viewModel.beginGradientDrag(at: point, modifiers: modifiers)
                        },
                        onGradientDragChanged: { point, modifiers in
                            onCanvasInteraction?()
                            viewModel.updateGradientDrag(to: point, modifiers: modifiers)
                        },
                        onGradientDragEnded: { point, modifiers in
                            onCanvasInteraction?()
                            viewModel.endGradientDrag(at: point, modifiers: modifiers)
                        },
                        onEnterGradientEditing: {
                            onCanvasInteraction?()
                            viewModel.enterGradientEditingViaShift()
                        },
                        onCancelCanvasTool: {
                            viewModel.cancelCanvasToolInteraction()
                        },
                        onApplyGradientSession: {
                            onCanvasInteraction?()
                            viewModel.applyActiveGradientSession()
                        },
                        onClearSelection: {
                            if viewModel.selectionOverlayProxy.displayShape != nil {
                                viewModel.clearSelection()
                            }
                        },
                        onApplyTransform: {
                            onCanvasInteraction?()
                            viewModel.applySelectionTransform()
                        },
                        onCancelTransform: {
                            onCanvasInteraction?()
                            viewModel.cancelSelectionTransform()
                        },
                        isLuminosityPreviewEnabled: viewModel.isLuminosityPreviewEnabled,
                        onAdjustBrushSize: { delta in
                            viewModel.adjustBrushSize(by: delta)
                        }
                    )
                    .frame(
                        width: presentation.documentDisplaySize.x,
                        height: presentation.documentDisplaySize.y
                    )
                    .clipped()

                // SelectionOverlayHost は selectionOverlayProxy だけを購読する
                // 選区ドラッグ中に MetalCanvasHost や他の overlay が再描画されない
                SelectionOverlayHost(
                    proxy: viewModel.selectionOverlayProxy,
                    presentation: documentPresentation,
                    canvasSize: viewModel.workspace.document.canvasSize
                )
                .allowsHitTesting(false)

                if Self.showsSelectionDebugOverlay,
                   let previewShape = viewModel.samePathPreviewDebugShape {
                    DebugLassoPathOverlay(
                        shape: previewShape,
                        presentation: documentPresentation,
                        canvasSize: viewModel.workspace.document.canvasSize,
                        strokeColor: Color.pink,
                        lineWidth: 1.5,
                        dash: [8, 4]
                    )
                    .allowsHitTesting(false)
                }

                if Self.showsSelectionDebugOverlay,
                   let committedShape = viewModel.samePathCommittedDebugShape {
                    DebugLassoPathOverlay(
                        shape: committedShape,
                        presentation: documentPresentation,
                        canvasSize: viewModel.workspace.document.canvasSize,
                        strokeColor: .green,
                        lineWidth: 3,
                        dash: []
                    )
                    .allowsHitTesting(false)
                }

                if Self.showsSelectionDebugOverlay,
                   !viewModel.lassoSamplingDebugPoints.isEmpty {
                    LassoSamplingPointsOverlay(
                        points: viewModel.lassoSamplingDebugPoints,
                        presentation: documentPresentation,
                        canvasSize: viewModel.workspace.document.canvasSize
                    )
                    .allowsHitTesting(false)
                }

                if shouldShowFreeTransformHandles(
                    activeTool: viewModel.workspace.toolSession.activeTool,
                    isApplyingTransformCommit: viewModel.isApplyingTransformCommit,
                    isTransformingSelection: viewModel.isTransformingSelection,
                    isFreeTransformDragging: viewModel.isFreeTransformDragging,
                    activeInteractionMode: viewModel.activeFreeTransformInteractionMode
                ),
                   let shape = viewModel.effectiveTransformInteractionShape {
                    FreeTransformHandlesOverlay(
                        bounds: shape.bounds,
                        preview: viewModel.freeTransformPreview,
                        presentation: documentPresentation,
                        canvasSize: viewModel.workspace.document.canvasSize
                    )
                    .allowsHitTesting(false)
                }

                if viewModel.workspace.toolSession.activeTool == .linearGradient,
                   shouldShowGradientDraftOverlay(phase: viewModel.linearGradientState.phase),
                   let preview = viewModel.linearGradientState.preview {
                    LinearGradientToolOverlay(
                        preview: preview,
                        presentation: documentPresentation,
                        canvasSize: viewModel.workspace.document.canvasSize
                    )
                    .allowsHitTesting(false)
                }

                if viewModel.workspace.toolSession.activeTool == .straightLine,
                   let preview = viewModel.straightLineState.preview {
                    StraightLineToolOverlay(
                        preview: preview,
                        presentation: documentPresentation,
                        canvasSize: viewModel.workspace.document.canvasSize
                    )
                    .allowsHitTesting(false)
                }

                if viewModel.workspace.toolSession.activeTool == .sectorGradient,
                   shouldShowGradientDraftOverlay(phase: viewModel.sectorGradientState.phase),
                   let preview = viewModel.sectorGradientState.preview {
                    SectorGradientToolOverlay(
                        preview: preview,
                        presentation: documentPresentation,
                        canvasSize: viewModel.workspace.document.canvasSize
                    )
                    .allowsHitTesting(false)
                }

                if viewModel.workspace.toolSession.activeTool == .polygonSelection,
                   let preview = viewModel.polygonSelectionState.preview {
                    PolygonSelectionToolOverlay(
                        preview: preview,
                        presentation: documentPresentation,
                        canvasSize: viewModel.workspace.document.canvasSize
                    )
                    .allowsHitTesting(false)
                }
                }
                .frame(
                    width: presentation.documentDisplaySize.x,
                    height: presentation.documentDisplaySize.y
                )
                .position(x: documentCenter.x, y: documentCenter.y)
                .scaleEffect(presentation.documentZoomScale, anchor: .center)
                .rotationEffect(.degrees(viewModel.workspace.viewport.rotationDegrees))

                if viewModel.workspace.toolSession.activeTool == .canvasRotate || abs(viewModel.workspace.viewport.rotationDegrees) > 0.05 {
                    CanvasRotationHUD(
                        angleDegrees: viewModel.workspace.viewport.rotationDegrees,
                        isLocked: viewModel.isCanvasViewportLocked,
                        onReset: {
                            viewModel.setViewportRotation(0)
                        }
                    )
                    .position(
                        x: geometry.size.width / 2,
                        y: 28
                    )
                }

                if viewModel.workspace.toolSession.activeTool == .freeTransform,
                   viewModel.isTransformingSelection || viewModel.isApplyingTransformCommit {
                    FreeTransformHUD(
                        isApplying: viewModel.isApplyingTransformCommit,
                        onApply: {
                            viewModel.applySelectionTransform()
                        },
                        onCancel: {
                            viewModel.cancelSelectionTransform()
                        }
                    )
                    .position(
                        x: geometry.size.width / 2,
                        y: 28
                    )
                }

                if viewModel.isPanModeActive && !viewModel.isCanvasViewportLocked {
                    PanGestureOverlay(
                        onPanChanged: { translation in
                            if panStartOffset == nil {
                                panStartOffset = viewModel.workspace.viewport.contentOffset
                            }

                            let startOffset = panStartOffset ?? .init(x: 0, y: 0)
                            viewModel.setViewportOffset(
                                x: startOffset.x + translation.width,
                                y: startOffset.y + translation.height
                            )
                        },
                        onEnded: {
                            panStartOffset = nil
                        }
                    )
                    .frame(
                        width: geometry.size.width,
                        height: geometry.size.height
                    )
                }

                if let quickColorPickerState = viewModel.quickColorPickerState {
                    let quickPickerBrushSlots = (0..<4).map { slotIndex in
                        viewModel.workspace.brushLibrary.preset(atSlot: slotIndex)
                    }
                    QuickColorPickerHUD(
                        state: resolvedQuickColorPickerState(
                            baseState: quickColorPickerState,
                            panel: viewModel.workspace.colorPanel
                        ),
                        presentation: presentation,
                        canvasSize: viewModel.workspace.document.canvasSize,
                        viewportRotationDegrees: viewModel.workspace.viewport.rotationDegrees,
                        viewportSize: geometry.size,
                        brushSlots: quickPickerBrushSlots,
                        selectedBrushPresetID: viewModel.workspace.brushLibrary.selectedPresetID,
                        onSetPoint: { x, y in
                            viewModel.setQuickColorPickerPoint(x: x, y: y)
                        },
                        onSetHue: { hue in
                            viewModel.setQuickColorPickerHue(hue)
                        },
                        onSelectBrushSlot: { slotIndex in
                            if let preset = viewModel.workspace.brushLibrary.preset(atSlot: slotIndex) {
                                viewModel.applyBrushPreset(preset.id)
                            }
                        }
                    )
                }

            }
            .clipped()
            .contentShape(Rectangle())
            .onAppear {
                viewModel.updateCanvasViewportSize(geometry.size)
            }
            .onChange(of: geometry.size) { _, newSize in
                viewModel.updateCanvasViewportSize(newSize)
            }
            } // CanvasViewportHost
        }
        .clipped()
    }
}

private func resolvedQuickColorPickerState(
    baseState: QuickColorPickerState,
    panel: ColorPanelState
) -> QuickColorPickerState {
    var resolved = baseState
    resolved.panel.pickerLightness = panel.pickerLightness
    resolved.panel.pickerSaturation = panel.pickerSaturation
    resolved.panel.lightingHue = panel.lightingHue
    resolved.panel.lightingStrength = panel.lightingStrength
    resolved.panel.snapThreeStops = panel.snapThreeStops
    return resolved
}

// viewport 状态隔离容器：只有 zoom/pan/rotation 变化时这个 View 才重新 layout
// 缩放时父级 CanvasContainerView 不会因此触发所有 overlay 的重绘
private struct CanvasViewportHost<Content: View>: View {
    let viewport: CanvasViewport
    let canvasSize: CanvasSize
    let availableSize: CGSize
    @ViewBuilder let content: (CanvasPresentation, CanvasPresentation, CanvasPoint) -> Content

    var body: some View {
        let presentation = CanvasPresentationBuilder.makePresentation(
            canvasSize: canvasSize,
            viewport: viewport,
            availableWidth: availableSize.width,
            availableHeight: availableSize.height
        )
        let documentPresentation = CanvasPresentation(
            viewportSize: presentation.documentDisplaySize,
            documentOrigin: CanvasPoint(x: 0, y: 0),
            documentDisplaySize: presentation.documentDisplaySize,
            documentZoomScale: presentation.documentZoomScale
        )
        let documentCenter = CanvasPoint(
            x: presentation.documentOrigin.x + (presentation.documentDisplaySize.x / 2),
            y: presentation.documentOrigin.y + (presentation.documentDisplaySize.y / 2)
        )
        content(presentation, documentPresentation, documentCenter)
    }
}

// 選区 overlay 専用 View — selectionOverlayProxy だけを購読する
// 選区ドラッグ中に MetalCanvasHost や他の overlay が再描画されない
private struct SelectionOverlayHost: View {
    @ObservedObject var proxy: WorkspaceViewModel.SelectionOverlayProxy
    let presentation: CanvasPresentation
    let canvasSize: CanvasSize

    var body: some View {
        let isTransforming = proxy.isTransformingSelection
        let isFreeTransform = proxy.activeTool == .freeTransform
        let isApplying = proxy.isApplyingTransformCommit

        if !isApplying, !(isFreeTransform && isTransforming),
           let committed = proxy.committedShape,
           let inProgress = proxy.inProgressShape,
           proxy.activeCombineMode != .replace {
            SelectionOverlay(
                selectionShape: committed,
                presentation: presentation,
                canvasSize: canvasSize,
                showsDimMask: false,
                previewOffset: .init(x: 0, y: 0),
                prefersVectorDisplay: true
            )
            SelectionOverlay(
                selectionShape: inProgress,
                presentation: presentation,
                canvasSize: canvasSize,
                showsDimMask: false,
                previewOffset: .init(x: 0, y: 0),
                prefersVectorDisplay: true
            )
        } else if !isApplying, !(isFreeTransform && isTransforming),
                  let shape = proxy.displayShape,
                  !proxy.hidesImplicitFreeTransformSelectionOverlay {
            SelectionOverlay(
                selectionShape: shape,
                presentation: presentation,
                canvasSize: canvasSize,
                showsDimMask: false,
                previewOffset: isTransforming
                    ? proxy.transformPreviewOffset
                    : proxy.selectionMovePreviewOffset,
                prefersVectorDisplay: shape.kind != .mask || !shape.components.isEmpty
            )
        }
    }
}

private struct DebugLassoPathOverlay: View {
    let shape: SelectionShape
    let presentation: CanvasPresentation
    let canvasSize: CanvasSize
    let strokeColor: Color
    let lineWidth: Double
    let dash: [CGFloat]

    var body: some View {
        let selectionRect = shape.bounds
        let scaleX = presentation.documentDisplaySize.x / Double(canvasSize.width)
        let scaleY = presentation.documentDisplaySize.y / Double(canvasSize.height)
        let rectWidth = max(selectionRect.size.x * scaleX, 1)
        let rectHeight = max(selectionRect.size.y * scaleY, 1)
        let originX = presentation.documentOrigin.x + (selectionRect.origin.x * scaleX)
        let originY = presentation.documentOrigin.y + (selectionRect.origin.y * scaleY)

        return lassoDebugPath(for: shape, displayWidth: rectWidth, displayHeight: rectHeight)
            .stroke(style: StrokeStyle(lineWidth: lineWidth, dash: dash))
            .foregroundStyle(strokeColor)
            .offset(x: originX, y: originY)
    }

    private func lassoDebugPath(for shape: SelectionShape, displayWidth: Double, displayHeight: Double) -> Path {
        let points = shape.pathPoints
        guard points.count >= 2 else { return Path() }

        let bounds = shape.bounds
        let canvasWidth = max(bounds.size.x, 0.0001)
        let canvasHeight = max(bounds.size.y, 0.0001)
        let mappedPoints = points.map {
            CGPoint(
                x: (($0.x - bounds.origin.x) / canvasWidth) * displayWidth,
                y: (($0.y - bounds.origin.y) / canvasHeight) * displayHeight
            )
        }
        return Path { path in
            guard let firstPoint = mappedPoints.first else { return }
            path.move(to: firstPoint)
            path.addLines(Array(mappedPoints.dropFirst()))
            path.closeSubpath()
        }
    }
}

private struct CanvasRotationHUD: View {
    let angleDegrees: Double
    let isLocked: Bool
    let onReset: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rotate.3d")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.82))

            Text("\(formattedAngle)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white)

            Button(action: onReset) {
                Text("回正")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.white.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
            .disabled(isLocked)
            .opacity(isLocked ? 0.4 : 1)
            .help("将画布旋转恢复到 0°")
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.55))
        )
    }

    private var formattedAngle: String {
        let rounded = Int(angleDegrees.rounded())
        if rounded == 0 { return "0°" }
        return "\(rounded)°"
    }
}

private struct FreeTransformHUD: View {
    let isApplying: Bool
    let onApply: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.82))

            Text(isApplying ? "应用中" : "变形中")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white)

            Button(action: onApply) {
                Text("应用")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.white.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
            .disabled(isApplying)
            .opacity(isApplying ? 0.5 : 1)
            .help("应用当前自由变形")

            Button(action: onCancel) {
                Text("取消")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.white.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
            .disabled(isApplying)
            .opacity(isApplying ? 0.5 : 1)
            .help("取消当前自由变形")
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.55))
        )
    }
}

private struct GradientToolHUD: View {
    let title: String
    let isApplying: Bool
    let onApply: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.82))

            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white)

            Button(action: onApply) {
                Text("应用")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.white.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
            .disabled(isApplying)
            .opacity(isApplying ? 0.5 : 1)

            Button(action: onCancel) {
                Text("取消")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.white.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
            .disabled(isApplying)
            .opacity(isApplying ? 0.5 : 1)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.55))
        )
    }
}

private struct LassoSamplingPointsOverlay: View {
    let points: [CanvasPoint]
    let presentation: CanvasPresentation
    let canvasSize: CanvasSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                let mapped = map(point)
                Circle()
                    .fill(index == 0 ? Color.yellow : (index == points.count - 1 ? Color.red : Color.cyan))
                    .frame(width: index == 0 || index == points.count - 1 ? 6 : 4, height: index == 0 || index == points.count - 1 ? 6 : 4)
                    .position(mapped)
            }
        }
    }

    private func map(_ point: CanvasPoint) -> CGPoint {
        let scaleX = presentation.documentDisplaySize.x / Double(canvasSize.width)
        let scaleY = presentation.documentDisplaySize.y / Double(canvasSize.height)
        return CGPoint(
            x: presentation.documentOrigin.x + (point.x * scaleX),
            y: presentation.documentOrigin.y + (point.y * scaleY)
        )
    }
}

private struct StraightLineToolOverlay: View {
    let preview: StraightLinePreview
    let presentation: CanvasPresentation
    let canvasSize: CanvasSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: map(preview.pointA))
                path.addLine(to: map(preview.pointB))
            }
            .stroke(style: StrokeStyle(lineWidth: 2, dash: [8, 8]))
            .foregroundStyle(Color.accentColor.opacity(0.9))

            pointMarker(preview.pointA, label: "A")
            pointMarker(preview.pointB, label: "B")
        }
    }

    private func pointMarker(_ point: CanvasPoint, label: String) -> some View {
        let mapped = map(point)
        return ZStack {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 10, height: 10)
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.white)
                .offset(x: 14, y: -12)
        }
        .position(mapped)
    }

    private func map(_ point: CanvasPoint) -> CGPoint {
        let scaleX = presentation.documentDisplaySize.x / Double(canvasSize.width)
        let scaleY = presentation.documentDisplaySize.y / Double(canvasSize.height)
        return CGPoint(
            x: presentation.documentOrigin.x + (point.x * scaleX),
            y: presentation.documentOrigin.y + (point.y * scaleY)
        )
    }
}

private struct LinearGradientToolOverlay: View {
    let preview: LinearGradientPreview
    let presentation: CanvasPresentation
    let canvasSize: CanvasSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            dashedSegment(from: preview.pointA, to: preview.pointB)
            pointMarker(preview.pointA, label: "A")
            pointMarker(preview.pointB, label: "B")
        }
    }

    private func dashedSegment(from start: CanvasPoint, to end: CanvasPoint) -> some View {
        Path { path in
            path.move(to: map(start))
            path.addLine(to: map(end))
        }
        .stroke(style: StrokeStyle(lineWidth: 2, dash: [8, 8]))
        .foregroundStyle(Color.accentColor.opacity(0.9))
    }

    private func pointMarker(_ point: CanvasPoint, label: String) -> some View {
        let mapped = map(point)
        return ZStack {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 10, height: 10)
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.white)
                .offset(x: 14, y: -12)
        }
        .position(mapped)
    }

    private func map(_ point: CanvasPoint) -> CGPoint {
        let scaleX = presentation.documentDisplaySize.x / Double(canvasSize.width)
        let scaleY = presentation.documentDisplaySize.y / Double(canvasSize.height)
        return CGPoint(
            x: presentation.documentOrigin.x + (point.x * scaleX),
            y: presentation.documentOrigin.y + (point.y * scaleY)
        )
    }
}

private struct SectorGradientToolOverlay: View {
    let preview: SectorGradientPreview
    let presentation: CanvasPresentation
    let canvasSize: CanvasSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let overlayPath {
                overlayPath
                    .stroke(style: StrokeStyle(lineWidth: 2, dash: [8, 8]))
                    .foregroundStyle(Color.accentColor.opacity(0.9))
            }
            closingGuide
                .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                .foregroundStyle(Color.accentColor.opacity(0.65))
            pointMarker(preview.center, label: "A")
        }
    }

    private var overlayPath: Path? {
        let points = displayPathPoints
        guard points.count >= 2 else { return nil }
        let mappedPoints = points.map { point in
            let mapped = map(point)
            return CanvasPoint(x: mapped.x, y: mapped.y)
        }
        if let smoothedPath = smoothedClosedLassoPath(points: mappedPoints) {
            return Path(smoothedPath)
        }
        return Path { path in
            path.move(to: map(points[0]))
            for point in points.dropFirst() {
                path.addLine(to: map(point))
            }
        }
    }

    private var closingGuide: Path {
        guard let lastPoint = displayPathPoints.last else { return Path() }
        return Path { path in
            path.move(to: map(lastPoint))
            path.addLine(to: map(preview.center))
        }
    }

    private func pointMarker(_ point: CanvasPoint, label: String) -> some View {
        let mapped = map(point)
        return ZStack {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 10, height: 10)
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.white)
                .offset(x: 14, y: -12)
        }
        .position(mapped)
    }

    private var displayPathPoints: [CanvasPoint] {
        if let geometry = resolvedSectorGradientPreviewGeometry(preview: preview) {
            return geometry.pathPoints
        }
        var points = preview.pathPoints
        if let hoverPoint = preview.hoverPoint, points.last != hoverPoint {
            points.append(hoverPoint)
        }
        return points
    }

    private func map(_ point: CanvasPoint) -> CGPoint {
        let scaleX = presentation.documentDisplaySize.x / Double(canvasSize.width)
        let scaleY = presentation.documentDisplaySize.y / Double(canvasSize.height)
        return CGPoint(
            x: presentation.documentOrigin.x + (point.x * scaleX),
            y: presentation.documentOrigin.y + (point.y * scaleY)
        )
    }
}

private struct PolygonSelectionToolOverlay: View {
    let preview: PolygonSelectionPreview
    let presentation: CanvasPresentation
    let canvasSize: CanvasSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            openPolyline
                .stroke(Color.black.opacity(0.9), lineWidth: 2.5)
            openPolyline
                .stroke(style: StrokeStyle(lineWidth: 1.4, dash: [7, 5]))
                .foregroundStyle(Color.white)

            if let closingGuide {
                closingGuide
                    .stroke(style: StrokeStyle(lineWidth: 1.2, dash: [5, 5]))
                    .foregroundStyle(Color.white.opacity(0.75))
            }

            ForEach(Array(preview.vertices.enumerated()), id: \.offset) { index, point in
                let mapped = map(point)
                Circle()
                    .fill(index == 0 && preview.closesToFirst ? Color.yellow : Color.accentColor)
                    .frame(width: index == 0 ? 8 : 6, height: index == 0 ? 8 : 6)
                    .position(mapped)
            }
        }
    }

    private var openPolyline: Path {
        let allPoints = preview.vertices + (preview.hoverPoint.map { [$0] } ?? [])
        guard allPoints.count >= 2 else { return Path() }
        return Path { path in
            path.move(to: map(allPoints[0]))
            for point in allPoints.dropFirst() {
                path.addLine(to: map(point))
            }
        }
    }

    private var closingGuide: Path? {
        guard
            let first = preview.vertices.first,
            let last = preview.hoverPoint ?? preview.vertices.last,
            preview.vertices.count >= 2
        else {
            return nil
        }

        return Path { path in
            path.move(to: map(last))
            path.addLine(to: map(first))
        }
    }

    private func map(_ point: CanvasPoint) -> CGPoint {
        let scaleX = presentation.documentDisplaySize.x / Double(canvasSize.width)
        let scaleY = presentation.documentDisplaySize.y / Double(canvasSize.height)
        return CGPoint(
            x: presentation.documentOrigin.x + (point.x * scaleX),
            y: presentation.documentOrigin.y + (point.y * scaleY)
        )
    }
}

private struct LassoShape: Shape {
    let selectionShape: SelectionShape
    let displayWidth: Double
    let displayHeight: Double

    func path(in rect: CGRect) -> Path {
        let points = selectionShape.pathPoints
        guard points.count >= 2 else { return Path() }

        let bounds = selectionShape.bounds
        let canvasWidth = max(bounds.size.x, 0.0001)
        let canvasHeight = max(bounds.size.y, 0.0001)

        return Path { path in
            let first = points[0]
            path.move(
                to: CGPoint(
                    x: ((first.x - bounds.origin.x) / canvasWidth) * displayWidth,
                    y: ((first.y - bounds.origin.y) / canvasHeight) * displayHeight
                )
            )

            for point in points.dropFirst() {
                path.addLine(
                    to: CGPoint(
                        x: ((point.x - bounds.origin.x) / canvasWidth) * displayWidth,
                        y: ((point.y - bounds.origin.y) / canvasHeight) * displayHeight
                    )
                )
            }

            path.closeSubpath()
        }
    }
}

private struct SelectionOverlay: View {
    let selectionShape: SelectionShape
    let presentation: CanvasPresentation
    let canvasSize: CanvasSize
    let showsDimMask: Bool
    let previewOffset: CanvasPoint
    let prefersVectorDisplay: Bool

    var body: some View {
        let displayOffsetX = previewOffset.x * (presentation.documentDisplaySize.x / Double(canvasSize.width))
        let displayOffsetY = previewOffset.y * (presentation.documentDisplaySize.y / Double(canvasSize.height))

        if prefersVectorDisplay, let vectorShape = vectorDisplayShape(for: selectionShape) {
            let selectionRect = vectorShape.bounds
            let scaleX = presentation.documentDisplaySize.x / Double(canvasSize.width)
            let scaleY = presentation.documentDisplaySize.y / Double(canvasSize.height)
            let rectWidth = max(selectionRect.size.x * scaleX, 1)
            let rectHeight = max(selectionRect.size.y * scaleY, 1)
            let cachedVectorLassoPath = vectorShape.kind == .lasso
                ? lassoPath(for: vectorShape, displayWidth: rectWidth, displayHeight: rectHeight)
                : nil
            return AnyView(
                vectorMaskOverlay(
                    for: vectorShape,
                    cachedLassoPath: cachedVectorLassoPath
                )
                    .offset(x: displayOffsetX, y: displayOffsetY)
            )
        }
        if selectionShape.kind == .mask {
            return AnyView(
                maskOverlay(for: selectionShape)
                    .offset(x: displayOffsetX, y: displayOffsetY)
            )
        }
        let previewShape = selectionShape.translatedBy(x: previewOffset.x, y: previewOffset.y)
        let selectionRect = previewShape.bounds
        let scaleX = presentation.documentDisplaySize.x / Double(canvasSize.width)
        let scaleY = presentation.documentDisplaySize.y / Double(canvasSize.height)
        let rectWidth = max(selectionRect.size.x * scaleX, 1)
        let rectHeight = max(selectionRect.size.y * scaleY, 1)
        let x = presentation.documentOrigin.x + (selectionRect.origin.x * scaleX)
        let y = presentation.documentOrigin.y + (selectionRect.origin.y * scaleY)
        let cachedPreviewLassoPath = previewShape.kind == .lasso
            ? lassoPath(for: previewShape, displayWidth: rectWidth, displayHeight: rectHeight)
            : nil

        return AnyView(ZStack(alignment: .topLeading) {
            if showsDimMask {
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .frame(
                        width: presentation.documentDisplaySize.x,
                        height: presentation.documentDisplaySize.y
                    )
                    .overlay {
                        Rectangle()
                            .fill(Color.black.opacity(0.18))
                            .mask {
                                Rectangle()
                                    .overlay(alignment: .topLeading) {
                                        selectionCutout(
                                            width: rectWidth,
                                            height: rectHeight,
                                            cachedLassoPath: cachedPreviewLassoPath
                                        )
                                            .blendMode(.destinationOut)
                                            .offset(x: selectionRect.origin.x * scaleX, y: selectionRect.origin.y * scaleY)
                                    }
                            }
                    }
                    .position(
                        x: presentation.documentOrigin.x + (presentation.documentDisplaySize.x / 2),
                        y: presentation.documentOrigin.y + (presentation.documentDisplaySize.y / 2)
                    )
            }

            selectionBorder(
                width: rectWidth,
                height: rectHeight,
                originX: x,
                originY: y,
                cachedLassoPath: cachedPreviewLassoPath
            )
        }
        .allowsHitTesting(false))
    }

    @ViewBuilder
    private func vectorMaskOverlay(
        for shape: SelectionShape,
        cachedLassoPath: Path?
    ) -> some View {
        let selectionRect = shape.bounds
        let scaleX = presentation.documentDisplaySize.x / Double(canvasSize.width)
        let scaleY = presentation.documentDisplaySize.y / Double(canvasSize.height)
        let rectWidth = max(selectionRect.size.x * scaleX, 1)
        let rectHeight = max(selectionRect.size.y * scaleY, 1)
        let x = presentation.documentOrigin.x + (selectionRect.origin.x * scaleX)
        let y = presentation.documentOrigin.y + (selectionRect.origin.y * scaleY)

        ZStack(alignment: .topLeading) {
            if showsDimMask {
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .frame(
                        width: presentation.documentDisplaySize.x,
                        height: presentation.documentDisplaySize.y
                    )
                    .overlay {
                        Rectangle()
                            .fill(Color.black.opacity(0.18))
                            .mask {
                                Rectangle()
                                    .overlay(alignment: .topLeading) {
                                        vectorSelectionCutout(
                                            for: shape,
                                            width: rectWidth,
                                            height: rectHeight,
                                            cachedLassoPath: cachedLassoPath
                                        )
                                            .blendMode(.destinationOut)
                                            .offset(
                                                x: selectionRect.origin.x * scaleX,
                                                y: selectionRect.origin.y * scaleY
                                            )
                                    }
                            }
                    }
                    .position(
                        x: presentation.documentOrigin.x + (presentation.documentDisplaySize.x / 2),
                        y: presentation.documentOrigin.y + (presentation.documentDisplaySize.y / 2)
                    )
            }

            vectorSelectionBorder(
                for: shape,
                width: rectWidth,
                height: rectHeight,
                originX: x,
                originY: y,
                cachedLassoPath: cachedLassoPath
            )
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func maskOverlay(for shape: SelectionShape) -> some View {
        let documentFrame = CGRect(
            x: presentation.documentOrigin.x,
            y: presentation.documentOrigin.y,
            width: presentation.documentDisplaySize.x,
            height: presentation.documentDisplaySize.y
        )

        ZStack(alignment: .topLeading) {
            if showsDimMask {
                Rectangle()
                    .fill(Color.black.opacity(0.18))
                    .frame(width: documentFrame.width, height: documentFrame.height)
                    .mask {
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: documentFrame.width, height: documentFrame.height)
                            .overlay {
                                SelectionMaskImageView(
                                    selectionShape: shape,
                                    presentation: presentation,
                                    canvasSize: canvasSize,
                                    edgeOnly: false,
                                    tint: .white
                                )
                                .blendMode(.destinationOut)
                                .offset(x: documentFrame.origin.x, y: documentFrame.origin.y)
                            }
                    }
                    .position(
                        x: documentFrame.midX,
                        y: documentFrame.midY
                    )
            }

            SelectionMaskImageView(
                selectionShape: shape,
                presentation: presentation,
                canvasSize: canvasSize,
                edgeOnly: true,
                tint: .black.opacity(0.88)
            )
            .offset(x: documentFrame.origin.x, y: documentFrame.origin.y)

            SelectionMaskImageView(
                selectionShape: shape,
                presentation: presentation,
                canvasSize: canvasSize,
                edgeOnly: true,
                tint: .white
            )
            .offset(x: documentFrame.origin.x, y: documentFrame.origin.y)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func selectionCutout(
        width: Double,
        height: Double,
        cachedLassoPath: Path?
    ) -> some View {
        let previewShape = selectionShape.translatedBy(x: previewOffset.x, y: previewOffset.y)
        switch selectionShape.kind {
        case .rectangle:
            Rectangle()
                .frame(width: width, height: height)
        case .ellipse:
            Ellipse()
                .frame(width: width, height: height)
        case .lasso:
            cachedLassoPath ?? lassoPath(for: previewShape, displayWidth: width, displayHeight: height)
        case .mask:
            EmptyView()
        case .composite:
            EmptyView()
        }
    }

    @ViewBuilder
    private func selectionBorder(
        width: Double,
        height: Double,
        originX: Double,
        originY: Double,
        cachedLassoPath: Path?
    ) -> some View {
        let previewShape = selectionShape.translatedBy(x: previewOffset.x, y: previewOffset.y)
        switch selectionShape.kind {
        case .rectangle:
            antsRectangleBorder(cornerRadius: 2)
                .frame(width: width, height: height)
                .position(x: originX + (width / 2), y: originY + (height / 2))
        case .ellipse:
            antsEllipseBorder()
                .frame(width: width, height: height)
                .position(x: originX + (width / 2), y: originY + (height / 2))
        case .lasso:
            antsPathBorder(
                cachedLassoPath ?? lassoPath(for: previewShape, displayWidth: width, displayHeight: height)
            )
                .offset(x: originX, y: originY)
        case .mask:
            EmptyView()
        case .composite:
            EmptyView()
        }
    }

    private func lassoPath(
        for shape: SelectionShape,
        displayWidth: Double,
        displayHeight: Double
    ) -> Path {
        let points = shape.pathPoints
        guard points.count >= 2 else { return Path() }

        let bounds = shape.bounds
        let canvasWidth = max(bounds.size.x, 0.0001)
        let canvasHeight = max(bounds.size.y, 0.0001)

        let mappedPoints = points.map {
            CGPoint(
                x: (($0.x - bounds.origin.x) / canvasWidth) * displayWidth,
                y: (($0.y - bounds.origin.y) / canvasHeight) * displayHeight
            )
        }
        return Path { path in
            guard let firstPoint = mappedPoints.first else { return }
            path.move(to: firstPoint)
            path.addLines(Array(mappedPoints.dropFirst()))
            path.closeSubpath()
        }
    }

    @ViewBuilder
    private func vectorSelectionCutout(
        for shape: SelectionShape,
        width: Double,
        height: Double,
        cachedLassoPath: Path?
    ) -> some View {
        switch shape.kind {
        case .rectangle:
            Rectangle()
                .frame(width: width, height: height)
        case .ellipse:
            Ellipse()
                .frame(width: width, height: height)
        case .lasso:
            cachedLassoPath ?? lassoPath(for: shape, displayWidth: width, displayHeight: height)
        case .composite:
            EmptyView()
        case .mask:
            EmptyView()
        }
    }

    @ViewBuilder
    private func vectorSelectionBorder(
        for shape: SelectionShape,
        width: Double,
        height: Double,
        originX: Double,
        originY: Double,
        cachedLassoPath: Path?
    ) -> some View {
        switch shape.kind {
        case .rectangle:
            antsRectangleBorder(cornerRadius: 2)
                .frame(width: width, height: height)
                .position(x: originX + (width / 2), y: originY + (height / 2))
        case .ellipse:
            antsEllipseBorder()
                .frame(width: width, height: height)
                .position(x: originX + (width / 2), y: originY + (height / 2))
        case .lasso:
            antsPathBorder(
                cachedLassoPath ?? lassoPath(for: shape, displayWidth: width, displayHeight: height)
            )
                .offset(x: originX, y: originY)
        case .composite:
            compositeSelectionBorder(for: shape)
        case .mask:
            EmptyView()
        }
    }

    @ViewBuilder
    private func compositeSelectionBorder(for shape: SelectionShape) -> some View {
        let scaleX = presentation.documentDisplaySize.x / Double(canvasSize.width)
        let scaleY = presentation.documentDisplaySize.y / Double(canvasSize.height)
        let components = shape.flattenedComponents()

        ZStack(alignment: .topLeading) {
            ForEach(Array(components.enumerated()), id: \.offset) { _, component in
                let componentShape = component.shape
                let selectionRect = componentShape.bounds
                let rectWidth = max(selectionRect.size.x * scaleX, 1)
                let rectHeight = max(selectionRect.size.y * scaleY, 1)
                let x = presentation.documentOrigin.x + (selectionRect.origin.x * scaleX)
                let y = presentation.documentOrigin.y + (selectionRect.origin.y * scaleY)

                switch componentShape.kind {
                case .rectangle:
                    antsRectangleBorder(cornerRadius: 2)
                        .frame(width: rectWidth, height: rectHeight)
                        .position(x: x + (rectWidth / 2), y: y + (rectHeight / 2))
                        .opacity(component.operation == .subtract ? 0.7 : 1)
                case .ellipse:
                    antsEllipseBorder()
                        .frame(width: rectWidth, height: rectHeight)
                        .position(x: x + (rectWidth / 2), y: y + (rectHeight / 2))
                        .opacity(component.operation == .subtract ? 0.7 : 1)
                case .lasso:
                    antsPathBorder(
                        lassoPath(for: componentShape, displayWidth: rectWidth, displayHeight: rectHeight)
                    )
                        .offset(x: x, y: y)
                        .opacity(component.operation == .subtract ? 0.7 : 1)
                case .mask, .composite:
                    EmptyView()
                }
            }
        }
    }

    @ViewBuilder
    private func antsRectangleBorder(cornerRadius: Double) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color.black.opacity(0.88), lineWidth: 2.5)
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(style: StrokeStyle(lineWidth: 1.25, dash: [6, 4]))
                .foregroundStyle(Color.white)
        }
    }

    @ViewBuilder
    private func antsEllipseBorder() -> some View {
        ZStack {
            Ellipse()
                .stroke(Color.black.opacity(0.88), lineWidth: 2.5)
            Ellipse()
                .stroke(style: StrokeStyle(lineWidth: 1.25, dash: [6, 4]))
                .foregroundStyle(Color.white)
        }
    }

    @ViewBuilder
    private func antsPathBorder(_ path: Path) -> some View {
        ZStack {
            path
                .stroke(Color.black.opacity(0.88), lineWidth: 2.5)
            path
                .stroke(style: StrokeStyle(lineWidth: 1.25, dash: [6, 4]))
                .foregroundStyle(Color.white)
        }
    }

    private func vectorDisplayShape(for shape: SelectionShape) -> SelectionShape? {
        guard shape.kind == .mask else { return nil }
        if shape.components.count > 1 {
            let message = "[vectorDisplayShape] source=composite componentCount=\(shape.components.count) boundsOrigin=(\(shape.bounds.origin.x),\(shape.bounds.origin.y)) boundsSize=(\(shape.bounds.size.x),\(shape.bounds.size.y))"
            selectionTraceLogger.debug("\(message, privacy: .public)")
            emitSelectionTraceCanvas(message)
            return SelectionShape.composite(shape.components)
        }
        if shape.components.count == 1,
           let component = shape.components.first,
           component.operation == .add {
            let message = "[vectorDisplayShape] source=component kind=\(component.shape.kind.rawValue) boundsOrigin=(\(component.shape.bounds.origin.x),\(component.shape.bounds.origin.y)) boundsSize=(\(component.shape.bounds.size.x),\(component.shape.bounds.size.y))"
            selectionTraceLogger.debug("\(message, privacy: .public)")
            emitSelectionTraceCanvas(message)
            return component.shape
        }
        if shape.pathPoints.count >= 3 {
            let message = "[vectorDisplayShape] source=maskPath pathCount=\(shape.pathPoints.count) boundsOrigin=(\(shape.bounds.origin.x),\(shape.bounds.origin.y)) boundsSize=(\(shape.bounds.size.x),\(shape.bounds.size.y))"
            selectionTraceLogger.debug("\(message, privacy: .public)")
            emitSelectionTraceCanvas(message)
            return SelectionShape(
                kind: .lasso,
                bounds: shape.bounds,
                pathPoints: shape.pathPoints
            )
        }
        return nil
    }
}

private struct SelectionMaskImageView: View {
    let selectionShape: SelectionShape
    let presentation: CanvasPresentation
    let canvasSize: CanvasSize
    let edgeOnly: Bool
    let tint: Color

    var body: some View {
        Group {
            if let slice = makeSelectionMaskImageSlice(
                shape: selectionShape,
                canvasSize: canvasSize,
                edgeOnly: edgeOnly
            ) {
                Image(decorative: slice.cgImage, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .colorMultiply(tint)
                    .frame(
                        width: slice.displayWidth * (presentation.documentDisplaySize.x / Double(canvasSize.width)),
                        height: slice.displayHeight * (presentation.documentDisplaySize.y / Double(canvasSize.height))
                    )
                    .offset(
                        x: slice.originX * (presentation.documentDisplaySize.x / Double(canvasSize.width)),
                        y: slice.originY * (presentation.documentDisplaySize.y / Double(canvasSize.height))
                    )
            }
        }
    }
}

private struct SelectionMaskImageSlice {
    let cgImage: CGImage
    let originX: Double
    let originY: Double
    let displayWidth: Double
    let displayHeight: Double
}

private func makeSelectionMaskImageSlice(
    shape: SelectionShape,
    canvasSize: CanvasSize,
    edgeOnly: Bool
) -> SelectionMaskImageSlice? {
    guard let maskData = shape.maskData else { return nil }
    let width = min(maskData.canvasWidth, canvasSize.width)
    let height = min(maskData.canvasHeight, canvasSize.height)
    guard width > 0, height > 0 else { return nil }

    let croppedBounds = shape.bounds.clamped(
        to: CanvasSize(width: width, height: height)
    )
    let minX = max(Int(floor(croppedBounds.minX)), 0)
    let minY = max(Int(floor(croppedBounds.minY)), 0)
    let maxX = min(Int(ceil(croppedBounds.maxX)), width)
    let maxY = min(Int(ceil(croppedBounds.maxY)), height)
    let message = "[makeSelectionMaskImageSlice] edgeOnly=\(edgeOnly) shapeKind=\(shape.kind.rawValue) shapeBoundsOrigin=(\(shape.bounds.origin.x),\(shape.bounds.origin.y)) shapeBoundsSize=(\(shape.bounds.size.x),\(shape.bounds.size.y)) cropped=(\(minX),\(minY))-(\(maxX),\(maxY))"
    selectionTraceLogger.debug("\(message, privacy: .public)")
    emitSelectionTraceCanvas(message)
    guard minX < maxX, minY < maxY else { return nil }

    let croppedWidth = maxX - minX
    let croppedHeight = maxY - minY

    var rgba = [UInt8](repeating: 0, count: croppedWidth * croppedHeight * 4)

    maskData.withAlphaBytes { source in
        for y in 0..<croppedHeight {
            for x in 0..<croppedWidth {
                let sourceX = x + minX
                let sourceY = y + minY
                let index = (sourceY * maskData.canvasWidth) + sourceX
                let alpha = source[index]
                let shouldDraw: UInt8
                if edgeOnly {
                    if alpha == 0 {
                        shouldDraw = 0
                    } else {
                        let left = sourceX > 0 ? source[index - 1] : 0
                        let right = sourceX < width - 1 ? source[index + 1] : 0
                        let up = sourceY > 0 ? source[index - maskData.canvasWidth] : 0
                        let down = sourceY < height - 1 ? source[index + maskData.canvasWidth] : 0
                        shouldDraw = (left == 0 || right == 0 || up == 0 || down == 0) ? 255 : 0
                    }
                } else {
                    shouldDraw = alpha
                }

                let rgbaIndex = ((y * croppedWidth) + x) * 4
                rgba[rgbaIndex] = 255
                rgba[rgbaIndex + 1] = 255
                rgba[rgbaIndex + 2] = 255
                rgba[rgbaIndex + 3] = shouldDraw
            }
        }
    }

    guard
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
        let provider = CGDataProvider(data: Data(rgba) as CFData)
    else {
        return nil
    }

    guard let cgImage = CGImage(
        width: croppedWidth,
        height: croppedHeight,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: croppedWidth * 4,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    ) else {
        return nil
    }

    return SelectionMaskImageSlice(
        cgImage: cgImage,
        originX: Double(minX),
        originY: Double(minY),
        displayWidth: Double(croppedWidth),
        displayHeight: Double(croppedHeight)
    )
}

private struct PanGestureOverlay: View {
    let onPanChanged: (CGSize) -> Void
    let onEnded: () -> Void

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onPanChanged(value.translation)
                    }
                    .onEnded { _ in
                        onEnded()
                    }
            )
    }
}

private struct CanvasDocumentShadow: View {
    let presentation: CanvasPresentation

    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(Color.white)
            .frame(
                width: presentation.documentDisplaySize.x,
                height: presentation.documentDisplaySize.y
            )
            .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: 8)
            .position(
                x: presentation.documentOrigin.x + (presentation.documentDisplaySize.x / 2),
                y: presentation.documentOrigin.y + (presentation.documentDisplaySize.y / 2)
            )
    }
}

private struct FreeTransformHandlesOverlay: View {
    let bounds: CanvasRect
    let preview: FreeTransformPreview
    let presentation: CanvasPresentation
    let canvasSize: CanvasSize
    private let handleSize: CGFloat = 8
    private let rotationHandleDistance: Double = 48

    var body: some View {
        let scaleX = presentation.documentDisplaySize.x / Double(canvasSize.width)
        let scaleY = presentation.documentDisplaySize.y / Double(canvasSize.height)
        let corners = freeTransformCornerPoints(bounds: bounds, preview: preview).map { point in
            CGPoint(
                x: presentation.documentOrigin.x + (point.x * scaleX),
                y: presentation.documentOrigin.y + (point.y * scaleY)
            )
        }
        let handleMap = freeTransformHandlePoints(
            bounds: bounds,
            preview: preview,
            rotationHandleDistance: rotationHandleDistance
        ).mapValues { point in
            CGPoint(
                x: presentation.documentOrigin.x + (point.x * scaleX),
                y: presentation.documentOrigin.y + (point.y * scaleY)
            )
        }

        ZStack(alignment: .topLeading) {
            if corners.count == 4 {
                Path { path in
                    path.move(to: corners[0])
                    path.addLines([corners[1], corners[2], corners[3], corners[0]])
                }
                .stroke(Color.black.opacity(0.65), lineWidth: 2)

                Path { path in
                    path.move(to: corners[0])
                    path.addLines([corners[1], corners[2], corners[3], corners[0]])
                }
                .stroke(style: StrokeStyle(lineWidth: 1.2, dash: [6, 4]))
                .foregroundStyle(Color.white)
            }

            if let top = handleMap[.top], let rotation = handleMap[.rotation] {
                Path { path in
                    path.move(to: top)
                    path.addLine(to: rotation)
                }
                .stroke(Color.black.opacity(0.5), lineWidth: 1.5)
                Circle()
                    .fill(Color.white)
                    .frame(width: handleSize, height: handleSize)
                    .overlay(Circle().stroke(Color.black.opacity(0.65), lineWidth: 1))
                    .position(rotation)
            }

            ForEach(
                FreeTransformHandle.allCases.filter { $0 != .rotation },
                id: \.rawValue
            ) { handle in
                if let point = handleMap[handle] {
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: handleSize, height: handleSize)
                        .overlay(Rectangle().stroke(Color.black.opacity(0.65), lineWidth: 1))
                        .position(point)
                }
            }
        }
    }
}

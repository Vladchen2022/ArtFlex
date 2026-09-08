import AppKit
import SwiftUI
import UniformTypeIdentifiers
import os

private let selectionTraceLogger = Logger(subsystem: "ArtFlex", category: "SelectionTrace")
private func emitSelectionTraceCanvas(_ message: String) {
    appendSelectionTrace(message)
}

struct CanvasContainerView: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    var onCanvasInteraction: (() -> Void)? = nil
    var onReady: (() -> Void)? = nil
    @State private var panStartOffset: CanvasPoint?
    @State private var selectionRefinementDialogKind: SelectionRefinementKind?
    @State private var selectionRefinementRadiusPixels = 16
    @State private var isCanvasImageDropTarget = false
    @StateObject private var outsideCanvasBrushInputRelay = OutsideCanvasBrushInputRelay()
    private static let showsSelectionDebugOverlay = false

    var body: some View {
        GeometryReader { geometry in
            // CanvasViewportHost 只订阅 viewport（zoom/pan/rotation/flip），
            // 缩放时 overlay 层完全不参与 SwiftUI layout diff
            CanvasViewportHost(
                viewport: viewModel.workspace.viewport,
                canvasSize: viewModel.workspace.document.canvasSize,
                availableSize: geometry.size,
                documentRenderGeneration: viewModel.documentRenderGeneration
            ) { presentation, documentPresentation, documentCenter in
            let viewportTransform = CanvasViewportTransform(
                canvasSize: viewModel.workspace.document.canvasSize,
                viewport: viewModel.workspace.viewport,
                availableWidth: geometry.size.width,
                availableHeight: geometry.size.height
            )
            let samplingMode: CanvasDisplaySamplingMode =
                presentation.actualDisplayScale >= 4 ? .nearest : .linear
            ZStack(alignment: .topLeading) {
                CanvasWorkspaceBackdrop()
                    .clipped()

                ZStack(alignment: .topLeading) {
                    CanvasDocumentShadow(presentation: documentPresentation)

                    MetalCanvasHost(
                        sceneSnapshot: viewModel.sceneSnapshot,
                        externalRedrawRevision: viewModel.colorAdjustmentRedrawRevision &+ viewModel.recentBrushAdjustmentRedrawRevision,
                        transformSelectionShape: viewModel.transformPreparationSelectionShape,
                        metalContext: viewModel.metalContext,
                        layerSurfaceStore: viewModel.layerSurfaceStore,
                        activeTool: viewModel.workspace.toolSession.activeTool,
                        viewportRotationDegrees: viewModel.workspace.viewport.rotationDegrees,
                        strokeResetToken: viewModel.strokeResetToken,
                        brushSize: viewModel.workspace.toolSession.brush.size,
                        viewportRenderScale: presentation.documentZoomScale,
                        displaySamplingMode: samplingMode,
                        drawsTransparencyCheckerboard: viewModel.showsTransparencyCheckerboard,
                        isPanModeActive: viewModel.isPanModeActive,
                        isTransformingSelection: viewModel.isTransformingSelection,
                        isFreeTransformDragging: viewModel.isFreeTransformDragging,
                        activeFreeTransformInteractionMode: viewModel.activeFreeTransformInteractionMode,
                        transformPreview: viewModel.freeTransformPreview,
                        freeTransformToolMode: viewModel.freeTransformToolMode,
                        meshWarpGrid: viewModel.displayedMeshWarpGrid,
                        linearGradientPreview: viewModel.linearGradientState.preview,
                        sectorGradientPreview: viewModel.sectorGradientState.preview,
                        patternPlacementPhase: viewModel.patternPlacementPhase,
                        gradientPreviewColor: viewModel.gradientPreviewColor,
                        gradientSettings: viewModel.gradientRenderSettings,
                        gradientPaintJitterAmount: viewModel.displayedPaintJitterAmount,
                        gradientPaintContrastAmount: viewModel.displayedPaintContrastAmount,
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
                        canDrainPendingBrushCommitsInteractively: { hadLiveBrushWorkThisFrame in
                            viewModel.canOpportunisticallyDrainBrushCommits(
                                hadLiveBrushWorkThisFrame: hadLiveBrushWorkThisFrame
                            )
                        },
                        onDrainPendingBrushCommitsInteractively: { hadLiveBrushWorkThisFrame in
                            viewModel.opportunisticallyDrainBrushCommits(
                                hadLiveBrushWorkThisFrame: hadLiveBrushWorkThisFrame
                            )
                        },
                        onRenderingFailure: { message in
                            viewModel.presentWorkspaceStatus(kind: .error, message: message)
                        },
                        resolveBrushDisplayTexture: { layerID in
                            viewModel.brushDisplayTexture(for: layerID)
                        },
                        resolvePatternPlacementTexture: { itemID in
                            viewModel.patternPlacementTexture(for: itemID)
                        },
                        onEyedropperSample: { point in
                            onCanvasInteraction?()
                            viewModel.sampleColor(at: point)
                        },
                        onBucketFill: { point in
                            onCanvasInteraction?()
                            viewModel.requestFillAtPoint(point)
                        },
                        onCanvasClick: { point, modifiers, clickCount in
                            onCanvasInteraction?()
                            viewModel.handleCanvasToolClick(at: point, modifiers: modifiers, clickCount: clickCount)
                        },
                        onCanvasHover: { point in
                            viewModel.updateCanvasToolHover(to: point)
                        },
                        onCanvasExited: {
                            viewModel.handleCanvasPointerExit()
                        },
                        onStraightLineDragBegan: { point in
                            onCanvasInteraction?()
                            viewModel.beginStraightLineDrag(
                                at: point,
                                thicknessAdjustmentDeadZone: straightLineThicknessDeadZoneCanvasDistance(
                                    actualDisplayScale: presentation.actualDisplayScale
                                )
                            )
                        },
                        onStraightLineDragChanged: { points in
                            onCanvasInteraction?()
                            viewModel.updateStraightLineDrag(along: points)
                        },
                        onStraightLineDragEnded: { point in
                            onCanvasInteraction?()
                            viewModel.endStraightLineDrag(at: point)
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
                        onSelectionChangedBatch: { points, modifiers in
                            onCanvasInteraction?()
                            viewModel.updateSelection(to: points, modifiers: modifiers)
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
                        onViewportPan: { deltaX, deltaY in
                            viewModel.panViewport(deltaX: deltaX, deltaY: deltaY)
                        },
                        onViewportZoom: { multiplier, anchorPoint in
                            viewModel.adjustViewportZoom(
                                byScaleMultiplier: multiplier,
                                anchoredAt: anchorPoint
                            )
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
                            viewModel.beginGradientDrag(
                                at: point,
                                modifiers: modifiers,
                                handleHitRadius: gradientHandleHitRadiusCanvasDistance(
                                    actualDisplayScale: presentation.actualDisplayScale
                                )
                            )
                        },
                        onGradientDragChanged: { point, modifiers in
                            onCanvasInteraction?()
                            viewModel.updateGradientDrag(to: point, modifiers: modifiers)
                        },
                        onGradientDragEnded: { point, modifiers in
                            onCanvasInteraction?()
                            viewModel.endGradientDrag(at: point, modifiers: modifiers)
                        },
                        onPatternPlacementBegan: { point, placeIntoNewLayer in
                            onCanvasInteraction?()
                            viewModel.beginPatternPlacementDrag(
                                at: point,
                                placeIntoNewLayer: placeIntoNewLayer
                            )
                        },
                        onPatternPlacementChanged: { point in
                            onCanvasInteraction?()
                            viewModel.updatePatternPlacementDrag(to: point)
                        },
                        onPatternPlacementEnded: { point in
                            onCanvasInteraction?()
                            viewModel.endPatternPlacementDrag(at: point)
                        },
                        onApplyPatternPlacement: {
                            onCanvasInteraction?()
                            viewModel.commitActivePatternPlacement()
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
                        onRequestSelectionRefinement: { kind in
                            switch kind {
                            case .invert:
                                viewModel.invertSelection()
                            case .expand, .contract, .feather:
                                selectionRefinementDialogKind = kind
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
                        },
                        outsideCanvasBrushInputRelay: outsideCanvasBrushInputRelay
                    )
                    .id(viewModel.documentRenderGeneration)
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

                if viewModel.freeTransformToolMode == .standard,
                   shouldShowFreeTransformHandles(
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
                } else if viewModel.workspace.toolSession.activeTool == .freeTransform,
                          viewModel.isTransformingSelection,
                          !viewModel.isApplyingTransformCommit,
                          let grid = viewModel.displayedMeshWarpGrid {
                    MeshWarpGridOverlay(
                        grid: grid,
                        activeInteractionMode: viewModel.activeFreeTransformInteractionMode,
                        selectedControlPointIndices: viewModel.selectedMeshWarpControlPointIndices,
                        presentation: documentPresentation,
                        canvasSize: viewModel.workspace.document.canvasSize
                    )
                    .allowsHitTesting(false)
                }

                if viewModel.patternPlacementPhase.isAdjusting,
                   let draft = viewModel.patternPlacementPhase.draft {
                    PatternPlacementHandlesOverlay(
                        draft: draft,
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
                        canvasSize: viewModel.workspace.document.canvasSize,
                        brush: viewModel.workspace.toolSession.brush,
                        color: viewModel.workspace.toolSession.selectedColor
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

                if viewModel.workspace.toolSession.activeTool == .canvasCrop,
                   let cropBounds = viewModel.canvasCropState.bounds {
                    CanvasCropOverlay(
                        bounds: cropBounds,
                        presentation: documentPresentation,
                        canvasSize: viewModel.workspace.document.canvasSize,
                        viewportZoomScale: presentation.documentZoomScale
                    )
                    .allowsHitTesting(false)
                }
                }
                .frame(
                    width: presentation.documentDisplaySize.x,
                    height: presentation.documentDisplaySize.y
                )
                .scaleEffect(
                    x: viewModel.workspace.viewport.isHorizontallyFlipped
                        ? -presentation.documentZoomScale
                        : presentation.documentZoomScale,
                    y: presentation.documentZoomScale,
                    anchor: .center
                )
                .rotationEffect(.degrees(viewModel.workspace.viewport.rotationDegrees))
                .position(x: documentCenter.x, y: documentCenter.y)

                if viewModel.isPixelGridEnabled,
                   presentation.actualDisplayScale >= 7.99 {
                    CanvasPixelGridOverlay(transform: viewportTransform)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .allowsHitTesting(false)
                }

                if let blockScene = viewModel.blockReferenceScene,
                   blockScene.display.isVisible,
                   !viewModel.blockReferenceEditorState.perspectiveMatch.isActive {
                    BlockReferenceOverlay(
                        scene: blockScene,
                        editorState: viewModel.blockReferenceEditorState,
                        transform: viewportTransform,
                        cameraRenderState: viewModel.blockReferenceCameraRenderState,
                        rendersContinuously: viewModel.isBlockReferenceCameraNavigating
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .allowsHitTesting(false)
                }

                if viewModel.workspace.toolSession.activeTool == .blockReference,
                   viewModel.blockReferenceEditorState.perspectiveMatch.isActive {
                    BlockReferencePerspectiveMatchOverlay(
                        state: viewModel.blockReferenceEditorState.perspectiveMatch,
                        transform: viewportTransform
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .allowsHitTesting(false)
                }

                if let guide = viewModel.perspectiveGuide,
                   guide.isVisible,
                   !viewModel.perspectiveGuideMatchState.isActive {
                    PerspectiveGuideOverlay(
                        guide: guide,
                        selectedAnchorID: viewModel.selectedPerspectiveAnchorID,
                        isEditing: viewModel.workspace.toolSession.activeTool == .perspective,
                        transform: viewportTransform
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .allowsHitTesting(false)
                }

                if viewModel.workspace.toolSession.activeTool == .perspective,
                   viewModel.perspectiveGuideMatchState.isActive {
                    PerspectiveGuideMatchOverlay(
                        state: viewModel.perspectiveGuideMatchState,
                        candidate: viewModel.perspectiveGuideMatchCandidate,
                        transform: viewportTransform
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .allowsHitTesting(false)
                }

                if viewModel.workspace.toolSession.activeTool == .perspective,
                   let guide = viewModel.perspectiveGuide,
                   guide.isVisible,
                   !viewModel.perspectiveGuideMatchState.isActive,
                   !viewModel.isPanModeActive {
                    PerspectiveGuideGestureOverlay(
                        transform: viewportTransform,
                        onBegan: { point in
                            onCanvasInteraction?()
                            viewModel.beginPerspectiveGuideInteraction(
                                at: point,
                                hitRadius: 14 / max(viewportTransform.actualDisplayScale, 0.000_001)
                            )
                        },
                        onChanged: viewModel.updatePerspectiveGuideInteraction,
                        onEnded: viewModel.endPerspectiveGuideInteraction
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }

                if viewModel.workspace.toolSession.activeTool == .perspective,
                   viewModel.perspectiveGuideMatchState.isActive,
                   !viewModel.isPanModeActive {
                    PerspectiveGuideGestureOverlay(
                        transform: viewportTransform,
                        onBegan: { point in
                            onCanvasInteraction?()
                            viewModel.beginPerspectiveGuideMatchLine(at: point)
                        },
                        onChanged: viewModel.updatePerspectiveGuideMatchLine,
                        onEnded: viewModel.endPerspectiveGuideMatchLine
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }

                if viewModel.workspace.toolSession.activeTool == .blockReference,
                   let blockScene = viewModel.blockReferenceScene,
                   blockScene.display.isVisible,
                   !viewModel.blockReferenceEditorState.perspectiveMatch.isActive,
                   !viewModel.isPanModeActive {
                    BlockReferenceGestureOverlay(
                        transform: viewportTransform,
                        onBegan: { point, modifiers in
                            onCanvasInteraction?()
                            viewModel.beginBlockReferenceInteraction(
                                at: point,
                                screenScale: viewportTransform.actualDisplayScale,
                                modifiers: modifiers
                            )
                        },
                        onChanged: { point in
                            viewModel.updateBlockReferenceInteraction(
                                to: point,
                                screenScale: viewportTransform.actualDisplayScale
                            )
                        },
                        onEnded: viewModel.endBlockReferenceInteraction,
                        onNavigationBegan: viewModel.beginBlockReferenceCameraNavigation,
                        onNavigationChanged: { mode, deltaX, deltaY in
                            viewModel.updateBlockReferenceCameraNavigation(
                                mode: mode,
                                deltaX: deltaX,
                                deltaY: deltaY,
                                screenScale: viewportTransform.actualDisplayScale
                            )
                        },
                        onNavigationEnded: viewModel.endBlockReferenceCameraNavigation,
                        onZoom: viewModel.zoomBlockReferenceCamera,
                        onHover: { point in
                            guard !blockScene.display.isFrozen else { return false }
                            return viewModel.updateBlockReferenceGizmoHover(
                                at: point,
                                screenScale: viewportTransform.actualDisplayScale
                            )
                        },
                        contextMenuItems: { point in
                            guard !blockScene.display.isFrozen else { return [] }
                            return blockReferenceContextMenuItems(at: point)
                        },
                        gizmoAdjustment: viewModel.blockReferenceEditorState.gizmoAdjustment,
                        gizmoPopupPoint: viewModel.blockReferenceEditorState.gizmoAdjustment.flatMap {
                            blockReferenceGizmoPopupViewportPoint(
                                scene: blockScene,
                                adjustment: $0,
                                transform: viewportTransform
                            )
                        },
                        onGizmoInputChanged: viewModel.setBlockReferenceGizmoAdjustmentInput,
                        onGizmoFinish: viewModel.finishBlockReferenceGizmoAdjustment,
                        primaryNavigationMode: viewModel.blockReferenceWorkflow.navigationMode,
                        onModifiersChanged: {
                            let disabled = $0.contains(.command)
                            if viewModel.blockReferenceWorkflow.temporarilyDisablesSnapping != disabled {
                                viewModel.blockReferenceWorkflow.temporarilyDisablesSnapping = disabled
                            }
                        }
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }

                if viewModel.workspace.toolSession.activeTool == .blockReference,
                   viewModel.blockReferenceEditorState.perspectiveMatch.isActive,
                   !viewModel.isPanModeActive {
                    PerspectiveGuideGestureOverlay(
                        transform: viewportTransform,
                        onBegan: { point in
                            onCanvasInteraction?()
                            viewModel.beginBlockReferencePerspectiveMatchLine(at: point)
                        },
                        onChanged: viewModel.updateBlockReferencePerspectiveMatchLine,
                        onEnded: viewModel.endBlockReferencePerspectiveMatchLine
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }

                if viewModel.workspace.toolSession.activeTool == .perspective,
                   let guide = viewModel.perspectiveGuide,
                   !viewModel.perspectiveGuideMatchState.isActive {
                    PerspectiveGuideHUD(
                        guide: guide,
                        onToggleLock: {
                            viewModel.setPerspectiveGuideLocked(!guide.isLocked)
                        },
                        onClear: viewModel.clearPerspectiveGuide
                    )
                    .position(
                        x: geometry.size.width / 2,
                        y: abs(viewModel.workspace.viewport.rotationDegrees) > 0.05 ? 68 : 28
                    )
                }

                if viewModel.workspace.toolSession.activeTool == .blockReference,
                   let blockScene = viewModel.blockReferenceScene,
                   !viewModel.blockReferenceEditorState.perspectiveMatch.isActive {
                    BlockReferenceHUD(
                        scene: blockScene,
                        editorState: viewModel.blockReferenceEditorState,
                        onCancel: viewModel.cancelBlockReferenceInteraction,
                        onFreeze: viewModel.freezeBlockReferenceAndSelectBrush
                    )
                    .position(
                        x: geometry.size.width / 2,
                        y: abs(viewModel.workspace.viewport.rotationDegrees) > 0.05 ? 68 : 28
                    )
                }

                if viewModel.workspace.toolSession.activeTool == .brush,
                   viewModel.workspace.document.blockReferenceScene?.display.isFrozen == true {
                    BlockReferencePaintingBar(viewModel: viewModel)
                        .position(x: geometry.size.width / 2, y: 30)
                }

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
                        toolMode: viewModel.freeTransformToolMode,
                        selectedMeshPointCount: viewModel.selectedMeshWarpControlPointIndices.count,
                        preciseInput: viewModel.preciseFreeTransformInput,
                        onToolModeChanged: viewModel.setFreeTransformToolMode,
                        onPreciseInputChanged: viewModel.setPreciseFreeTransformInput,
                        onFlipHorizontal: viewModel.flipFreeTransformHorizontally,
                        onFlipVertical: viewModel.flipFreeTransformVertically,
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

                if viewModel.patternPlacementPhase.isAdjusting,
                   let draft = viewModel.patternPlacementPhase.draft {
                    PatternPlacementHUD(
                        opacity: draft.opacity,
                        onRotateLeft: { viewModel.rotateActivePatternPlacement(by: -15) },
                        onRotateRight: { viewModel.rotateActivePatternPlacement(by: 15) },
                        onFlipHorizontal: viewModel.flipActivePatternPlacementHorizontally,
                        onFlipVertical: viewModel.flipActivePatternPlacementVertically,
                        onOpacityChanged: viewModel.setActivePatternPlacementOpacity,
                        onApply: viewModel.commitActivePatternPlacement,
                        onCancel: { viewModel.cancelPatternPlacement(keepSelection: true) }
                    )
                    .position(x: geometry.size.width / 2, y: 28)
                }

                if viewModel.workspace.toolSession.activeTool == .linearGradient,
                   viewModel.linearGradientState.isEditingSession || viewModel.isApplyingGradientCommit {
                    GradientToolHUD(
                        title: viewModel.isApplyingGradientCommit ? "应用中" : "直线渐变调整",
                        isApplying: viewModel.isApplyingGradientCommit,
                        onApply: viewModel.applyActiveGradientSession,
                        onCancel: viewModel.cancelLinearGradientInteraction
                    )
                    .position(x: geometry.size.width / 2, y: 28)
                }

                if viewModel.workspace.toolSession.activeTool == .canvasCrop {
                    CanvasCropHUD(
                        bounds: viewModel.canvasCropState.pixelBounds(
                            in: viewModel.workspace.document.canvasSize
                        ),
                        onApply: viewModel.applyCanvasCrop,
                        onCancel: viewModel.cancelCanvasCrop,
                        canExpand: viewModel.workspace.document.cropRetention.map {
                            $0.fullBounds != PixelRegion(originX: 0, originY: 0,
                                width: viewModel.workspace.document.canvasSize.width,
                                height: viewModel.workspace.document.canvasSize.height)
                        } ?? false,
                        onExpand: viewModel.expandRetainedCanvas
                    )
                    .position(x: geometry.size.width / 2, y: 28)
                }

                if viewModel.workspace.toolSession.activeTool == .canvasCrop,
                   !viewModel.isPanModeActive {
                    CanvasCropGestureOverlay(
                        transform: viewportTransform,
                        onBegan: { point in
                            viewModel.beginCanvasCrop(
                                at: point,
                                handleRadius: 12 / max(viewportTransform.actualDisplayScale, 0.000_001)
                            )
                        },
                        onChanged: viewModel.updateCanvasCrop,
                        onEnded: viewModel.endCanvasCrop
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }

                if viewModel.workspace.toolSession.activeTool.supportsOutsideCanvasSelectionStart,
                   !viewModel.isPanModeActive {
                    OutsideCanvasSelectionEventBridge(
                        transform: viewportTransform,
                        activeTool: viewModel.workspace.toolSession.activeTool,
                        onSelectionMouseDown: { point, modifiers in
                            onCanvasInteraction?()
                            return viewModel.handleSelectionMouseDown(at: point, modifiers: modifiers)
                        },
                        onSelectionChangedBatch: { points, modifiers in
                            onCanvasInteraction?()
                            viewModel.updateSelection(to: points, modifiers: modifiers)
                        },
                        onSelectionEnded: { point, modifiers in
                            onCanvasInteraction?()
                            viewModel.commitSelection(at: point, modifiers: modifiers)
                        },
                        onMoveSelectionPreview: { deltaX, deltaY in
                            onCanvasInteraction?()
                            viewModel.moveSelectionPreview(by: deltaX, deltaY: deltaY)
                        },
                        onCommitSelectionMove: {
                            onCanvasInteraction?()
                            viewModel.commitSelectionMove()
                        },
                        onPolygonClick: { point, modifiers, clickCount in
                            onCanvasInteraction?()
                            viewModel.handleCanvasToolClick(
                                at: point,
                                modifiers: modifiers,
                                clickCount: clickCount
                            )
                        },
                        onPolygonHover: viewModel.updateCanvasToolHover
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }

                if viewModel.workspace.toolSession.activeTool == .brush,
                   !viewModel.isPanModeActive {
                    OutsideCanvasBrushEventBridge(
                        transform: viewportTransform,
                        activeTool: viewModel.workspace.toolSession.activeTool,
                        isPanModeActive: viewModel.isPanModeActive,
                        inputRelay: outsideCanvasBrushInputRelay
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
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

                QuickColorPickerOverlayHost(
                    proxy: viewModel.quickColorPickerPresentation,
                    viewModel: viewModel,
                    presentation: presentation,
                    viewportSize: geometry.size
                )

            }
            .clipped()
            .contentShape(Rectangle())
            .task(
                id: QuickColorPickerSVImageKey(
                    size: QuickColorPickerLayout.svRasterSize,
                    panel: viewModel.workspace.colorPanel
                )
            ) {
                _ = await prepareSharedColorPickerSVImage(
                    size: QuickColorPickerLayout.svRasterSize,
                    panel: viewModel.workspace.colorPanel
                )
            }
            .overlay {
                if isCanvasImageDropTarget {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.accentColor.opacity(0.95), lineWidth: 3)
                        .padding(8)
                        .overlay {
                            Label("松开以导入为新图层", systemImage: "photo.badge.plus")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color.white.opacity(0.98))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(Capsule().fill(Color.black.opacity(0.72)))
                        }
                        .allowsHitTesting(false)
                }
            }
            .onDrop(
                of: [UTType.fileURL.identifier, UTType.image.identifier],
                isTargeted: $isCanvasImageDropTarget
            ) { providers in
                importCanvasImagesFromDrop(providers: providers)
            }
            .onAppear {
                viewModel.updateCanvasViewportSize(geometry.size)
                onReady?()
            }
            .onChange(of: geometry.size) { _, newSize in
                viewModel.updateCanvasViewportSize(newSize)
            }
            } // CanvasViewportHost
        }
        .clipped()
        .alert(selectionRefinementDialogTitle, isPresented: selectionRefinementDialogIsPresented) {
            TextField(
                "半径（像素）",
                value: $selectionRefinementRadiusPixels,
                format: .number
            )
            Button("取消", role: .cancel) {
                selectionRefinementDialogKind = nil
            }
            Button("应用") {
                let kind = selectionRefinementDialogKind
                selectionRefinementRadiusPixels = min(max(selectionRefinementRadiusPixels, 1), 512)
                selectionRefinementDialogKind = nil
                switch kind {
                case .expand:
                    viewModel.expandSelection(radiusPixels: selectionRefinementRadiusPixels)
                case .contract:
                    viewModel.contractSelection(radiusPixels: selectionRefinementRadiusPixels)
                case .feather:
                    viewModel.featherSelection(radiusPixels: selectionRefinementRadiusPixels)
                case .invert, .none:
                    break
                }
            }
        } message: {
            Text(selectionRefinementDialogMessage)
        }
    }

    private var selectionRefinementDialogIsPresented: Binding<Bool> {
        Binding(
            get: { selectionRefinementDialogKind != nil },
            set: { isPresented in
                if !isPresented {
                    selectionRefinementDialogKind = nil
                }
            }
        )
    }

    private var selectionRefinementDialogTitle: String {
        switch selectionRefinementDialogKind {
        case .expand: "扩展选区"
        case .contract: "收缩选区"
        case .feather: "羽化选区"
        case .invert, .none: "调整选区"
        }
    }

    private var selectionRefinementDialogMessage: String {
        switch selectionRefinementDialogKind {
        case .expand:
            "输入 1–512 px。确认后选区边界向外扩展。"
        case .contract:
            "输入 1–512 px。确认后选区边界向内收缩。"
        case .feather:
            "输入 1–512 px。确认后选区边缘会变得柔和。"
        case .invert, .none:
            "输入调整像素值。"
        }
    }

    private func blockReferenceContextMenuItems(
        at point: CanvasPoint
    ) -> [BlockReferenceContextMenuItem] {
        guard let objectID = viewModel.prepareBlockReferenceContextSelection(at: point) else {
            return []
        }
        var items: [BlockReferenceContextMenuItem] = [
            .action(title: "拾取模块基准点…", isEnabled: true) {
                viewModel.beginPickingBlockReferenceModuleBasePoint()
            },
            .action(title: "基准点使用所选中心", isEnabled: true) {
                viewModel.useSelectionCenterAsBlockReferencePivot()
            },
            .separator
        ]

        if let instance = viewModel.blockReferenceCustomModuleInstance(containing: objectID) {
            let asset = viewModel.blockReferenceModuleAsset(for: instance)
            items.append(contentsOf: [
                .action(title: "编辑模块部件", isEnabled: true) {
                    viewModel.beginEditingBlockReferenceModuleInstance(containing: objectID)
                },
                .action(
                    title: "保存并替换“\(asset?.name ?? "原模块")”",
                    isEnabled: asset != nil
                ) {
                    viewModel.replaceEditedBlockReferenceModule(containing: objectID)
                },
                .submenu(
                    title: "另存为新模块",
                    items: viewModel.blockReferenceModuleLibrary.categories.map { category in
                        .action(title: category.name, isEnabled: true) {
                            promptForBlockReferenceModuleName(
                                suggestedName: "\(asset?.name ?? "自定义模块") 副本"
                            ) { name in
                                viewModel.saveEditedBlockReferenceModuleAsNew(
                                    containing: objectID,
                                    named: name,
                                    categoryID: category.id
                                )
                            }
                        }
                    }
                ),
                .separator,
                .action(title: "不回存体块库（保留场景修改）", isEnabled: true) {
                    viewModel.detachBlockReferenceModuleInstance(containing: objectID)
                }
            ])
        } else {
            let suggestedName = viewModel.suggestedBlockReferenceModuleName(
                preferredObjectID: objectID
            )
            items.append(
                .submenu(
                    title: "将所选体块存入体块库",
                    items: viewModel.blockReferenceModuleLibrary.categories.map { category in
                        .action(title: category.name, isEnabled: true) {
                            promptForBlockReferenceModuleName(suggestedName: suggestedName) { name in
                                viewModel.saveSelectedBlockReferenceObjectsAsModule(
                                    named: name,
                                    categoryID: category.id,
                                    preferredObjectID: objectID
                                )
                            }
                        }
                    }
                )
            )
        }
        return items
    }

    private func promptForBlockReferenceModuleName(
        suggestedName: String,
        onSave: @escaping (String) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "保存到体块库"
        alert.informativeText = "模块会保留各个体块；载入时，模块基准点会落在活动工作面原点。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        nameField.stringValue = suggestedName
        nameField.placeholderString = "模块名称"
        alert.accessoryView = nameField

        let commit: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            onSave(nameField.stringValue)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: commit)
        } else {
            commit(alert.runModal())
        }
    }

    private func importCanvasImagesFromDrop(providers: [NSItemProvider]) -> Bool {
        let canvasSize = viewModel.workspace.document.canvasSize
        let canvasCenter = CanvasPoint(
            x: Double(canvasSize.width) / 2,
            y: Double(canvasSize.height) / 2
        )
        var acceptedProvider = false

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            acceptedProvider = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                switch item {
                case let data as Data:
                    url = URL(dataRepresentation: data, relativeTo: nil)
                case let nsData as NSData:
                    url = URL(dataRepresentation: nsData as Data, relativeTo: nil)
                case let fileURL as URL:
                    url = fileURL
                default:
                    url = nil
                }

                guard let url else { return }
                DispatchQueue.main.async {
                    _ = viewModel.importDroppedCanvasImage(from: url, centeredAt: canvasCenter)
                }
            }
        }

        for provider in providers
        where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) == false
            && provider.canLoadObject(ofClass: NSImage.self) {
            acceptedProvider = true
            provider.loadObject(ofClass: NSImage.self) { object, _ in
                guard let image = object as? NSImage else { return }
                DispatchQueue.main.async {
                    _ = viewModel.importDroppedCanvasImage(from: image, centeredAt: canvasCenter)
                }
            }
        }

        return acceptedProvider
    }
}

private struct CanvasWorkspaceBackdrop: View {
    private let baseColor = Color(
        red: 136.0 / 255.0,
        green: 136.0 / 255.0,
        blue: 136.0 / 255.0
    )
    private let majorGridSpacing: CGFloat = 100
    private let minorGridSpacing: CGFloat = 50
    private let majorGridColor = Color.white.opacity(0.16)
    private let minorGridColor = Color.white.opacity(0.08)
    private let gridLineThickness: CGFloat = 1

    var body: some View {
        Canvas(opaque: true, colorMode: .nonLinear, rendersAsynchronously: true) { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(baseColor)
            )

            var majorGridPath = Path()
            var minorGridPath = Path()

            for x in stride(from: CGFloat.zero, through: size.width, by: majorGridSpacing) {
                majorGridPath.addRect(
                    CGRect(
                        x: x,
                        y: 0,
                        width: gridLineThickness,
                        height: size.height
                    )
                )
            }

            for y in stride(from: CGFloat.zero, through: size.height, by: majorGridSpacing) {
                majorGridPath.addRect(
                    CGRect(
                        x: 0,
                        y: y,
                        width: size.width,
                        height: gridLineThickness
                    )
                )
            }

            context.fill(
                majorGridPath,
                with: .color(majorGridColor),
            )

            for x in stride(from: minorGridSpacing, through: size.width, by: majorGridSpacing) {
                minorGridPath.addRect(
                    CGRect(
                        x: x,
                        y: 0,
                        width: gridLineThickness,
                        height: size.height
                    )
                )
            }

            for y in stride(from: minorGridSpacing, through: size.height, by: majorGridSpacing) {
                minorGridPath.addRect(
                    CGRect(
                        x: 0,
                        y: y,
                        width: size.width,
                        height: gridLineThickness
                    )
                )
            }

            context.fill(
                minorGridPath,
                with: .color(minorGridColor),
            )
        }
    }
}

private struct QuickColorPickerOverlayHost: View {
    @ObservedObject var proxy: QuickColorPickerPresentationProxy
    let viewModel: WorkspaceViewModel
    let presentation: CanvasPresentation
    let viewportSize: CGSize

    var body: some View {
        let isPresented = proxy.state != nil
        let renderedState = proxy.state ?? inactiveState
        let quickPickerBrushSlots = (0..<4).map { slotIndex in
            viewModel.workspace.brushLibrary.preset(atSlot: slotIndex)
        }
        QuickColorPickerHUD(
            state: resolvedQuickColorPickerState(
                baseState: renderedState,
                panel: viewModel.workspace.colorPanel
            ),
            presentation: presentation,
            canvasSize: viewModel.workspace.document.canvasSize,
            viewportRotationDegrees: viewModel.workspace.viewport.rotationDegrees,
            isCanvasHorizontallyFlipped: viewModel.workspace.viewport.isHorizontallyFlipped,
            viewportSize: viewportSize,
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
            },
            onSetRecentBrushSelectionCount: { count in
                viewModel.setQuickColorPickerRecentBrushSelectionCount(count)
            },
            onSetRecentBrushOpacity: { opacity in
                viewModel.setQuickColorPickerRecentBrushOpacity(opacity)
            },
            onSetRecentBrushBrightness: { brightness in
                viewModel.setQuickColorPickerRecentBrushBrightness(brightness)
            },
            onSetRecentBrushSaturation: { saturation in
                viewModel.setQuickColorPickerRecentBrushSaturation(saturation)
            },
            onSetRecentBrushSelectionEditing: { isEditing in
                viewModel.setQuickColorPickerRecentBrushSelectionEditing(isEditing)
            },
            onSetRecentBrushOpacityEditing: { isEditing in
                viewModel.setQuickColorPickerRecentBrushOpacityEditing(isEditing)
            }
        )
        .opacity(isPresented ? 1 : 0)
        .allowsHitTesting(isPresented)
        .accessibilityHidden(!isPresented)
    }

    private var inactiveState: QuickColorPickerState {
        let canvasSize = viewModel.workspace.document.canvasSize
        return QuickColorPickerState(
            anchorPoint: CanvasPoint(
                x: Double(canvasSize.width) / 2,
                y: Double(canvasSize.height) / 2
            ),
            panel: viewModel.workspace.colorPanel,
            recentBrushSelectionCount: 1,
            recentBrushSelectionLimit: 1,
            recentBrushOpacity: 1,
            recentBrushBrightness: 0,
            recentBrushSaturation: 0
        )
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

// viewport 状态隔离容器：只有 zoom/pan/rotation/flip 变化时这个 View 才重新 layout
// 缩放时父级 CanvasContainerView 不会因此触发所有 overlay 的重绘
private struct CanvasViewportHost<Content: View>: View {
    let viewport: CanvasViewport
    let canvasSize: CanvasSize
    let availableSize: CGSize
    /// Makes document replacement an explicit dependency of this otherwise
    /// viewport-isolated subtree.
    let documentRenderGeneration: UInt64
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
        let usesSmartSelectionTint = proxy.activeTool == .smartSelection
            && proxy.smartSelectionDisplayMode == .tint

        if proxy.isHiddenForTransientAdjustment || proxy.activeTool == .canvasCrop {
            EmptyView()
        } else if !isApplying, !(isFreeTransform && isTransforming),
           let committed = proxy.committedShape,
           let inProgress = proxy.inProgressShape,
           proxy.activeCombineMode != .replace {
            SelectionOverlay(
                selectionShape: committed,
                presentation: presentation,
                canvasSize: canvasSize,
                showsDimMask: false,
                showsSelectionTint: usesSmartSelectionTint,
                previewOffset: .init(x: 0, y: 0),
                prefersVectorDisplay: proxy.activeTool != .smartSelection,
                smoothsLassoPath: false,
                maskCacheNamespace: proxy.maskCacheNamespace,
                maskCacheRevision: proxy.committedShapeRevision
            )
            .id(proxy.committedShapeRevision)
            SelectionOverlay(
                selectionShape: inProgress,
                presentation: presentation,
                canvasSize: canvasSize,
                showsDimMask: false,
                showsSelectionTint: false,
                previewOffset: .init(x: 0, y: 0),
                prefersVectorDisplay: true,
                smoothsLassoPath: false,
                maskCacheNamespace: nil,
                maskCacheRevision: nil
            )
            .id(proxy.redrawRevision)
        } else if !isApplying, !(isFreeTransform && isTransforming),
                  let shape = proxy.displayShape,
                  !proxy.hidesImplicitFreeTransformSelectionOverlay {
            SelectionOverlay(
                selectionShape: shape,
                presentation: presentation,
                canvasSize: canvasSize,
                showsDimMask: false,
                showsSelectionTint: usesSmartSelectionTint && shape.kind == .mask,
                previewOffset: isTransforming
                    ? proxy.transformPreviewOffset
                    : proxy.selectionMovePreviewOffset,
                prefersVectorDisplay: proxy.activeTool != .smartSelection
                    && (shape.kind != .mask || !shape.components.isEmpty),
                smoothsLassoPath: false,
                maskCacheNamespace: proxy.maskCacheNamespace,
                maskCacheRevision: shape.kind == .mask
                    ? proxy.committedShapeRevision
                    : nil
            )
            .id(proxy.redrawRevision)
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
            .buttonTooltip("重置画布旋转", help: "将画布旋转恢复到 0°")
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

private struct CanvasCropHUD: View {
    let bounds: CanvasRect?
    let onApply: () -> Void
    let onCancel: () -> Void
    let canExpand: Bool
    let onExpand: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "crop")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.82))

            Text(sizeText)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white)
                .frame(minWidth: 72)

            Text("保留框外像素")
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.8))
            if canExpand {
                Button("展开保留区域", action: onExpand)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.white)
                    .buttonTooltip("展开保留区域", help: "恢复裁剪框外的像素；保留裁剪后新画的内容")
            }

            Button(action: onApply) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.white)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.12)))
            .disabled(bounds == nil)
            .opacity(bounds == nil ? 0.4 : 1)
            .buttonTooltip("应用裁剪", help: "应用裁剪 (Enter)")

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.white)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.12)))
            .buttonTooltip("取消裁剪", help: "取消裁剪 (Esc)")
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Capsule().fill(Color.black.opacity(0.62)))
    }

    private var sizeText: String {
        guard let bounds else { return "拖出范围" }
        return "\(Int(bounds.size.x)) × \(Int(bounds.size.y))"
    }
}

private struct CanvasCropGestureOverlay: View {
    let transform: CanvasViewportTransform
    let onBegan: (CanvasPoint) -> Void
    let onChanged: (CanvasPoint) -> Void
    let onEnded: (CanvasPoint) -> Void

    @State private var isDragging = false

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            onBegan(canvasPoint(for: value.startLocation))
                        }
                        onChanged(canvasPoint(for: value.location))
                    }
                    .onEnded { value in
                        onEnded(canvasPoint(for: value.location))
                        isDragging = false
                    }
            )
            .onHover { hovering in
                if hovering {
                    NSCursor.crosshair.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
    }

    private func canvasPoint(for point: CGPoint) -> CanvasPoint {
        transform.viewportToCanvas(.init(x: point.x, y: point.y))
    }
}

private struct OutsideCanvasSelectionEventBridge: NSViewRepresentable {
    let transform: CanvasViewportTransform
    let activeTool: ToolKind
    let onSelectionMouseDown: (CanvasPoint, NSEvent.ModifierFlags) -> SelectionMouseDownAction
    let onSelectionChangedBatch: ([CanvasPoint], NSEvent.ModifierFlags) -> Void
    let onSelectionEnded: (CanvasPoint, NSEvent.ModifierFlags) -> Void
    let onMoveSelectionPreview: (Double, Double) -> Void
    let onCommitSelectionMove: () -> Void
    let onPolygonClick: (CanvasPoint, NSEvent.ModifierFlags, Int) -> Void
    let onPolygonHover: (CanvasPoint) -> Void

    func makeNSView(context: Context) -> OutsideCanvasSelectionEventView {
        let view = OutsideCanvasSelectionEventView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: OutsideCanvasSelectionEventView, context: Context) {
        update(nsView)
    }

    private func update(_ view: OutsideCanvasSelectionEventView) {
        view.transform = transform
        view.activeTool = activeTool
        view.onSelectionMouseDown = onSelectionMouseDown
        view.onSelectionChangedBatch = onSelectionChangedBatch
        view.onSelectionEnded = onSelectionEnded
        view.onMoveSelectionPreview = onMoveSelectionPreview
        view.onCommitSelectionMove = onCommitSelectionMove
        view.onPolygonClick = onPolygonClick
        view.onPolygonHover = onPolygonHover
    }
}

private struct OutsideCanvasBrushEventBridge: NSViewRepresentable {
    let transform: CanvasViewportTransform
    let activeTool: ToolKind
    let isPanModeActive: Bool
    let inputRelay: OutsideCanvasBrushInputRelay

    func makeNSView(context: Context) -> OutsideCanvasBrushEventView {
        let view = OutsideCanvasBrushEventView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: OutsideCanvasBrushEventView, context: Context) {
        update(nsView)
    }

    private func update(_ view: OutsideCanvasBrushEventView) {
        view.transform = transform
        view.activeTool = activeTool
        view.isPanModeActive = isPanModeActive
        view.inputRelay = inputRelay
    }
}

private final class OutsideCanvasBrushEventView: NSView {
    var transform = CanvasViewportTransform(
        canvasSize: .init(width: 1, height: 1),
        viewport: .stageOneDefault,
        availableWidth: 1,
        availableHeight: 1
    )
    var activeTool: ToolKind = .brush
    var isPanModeActive = false
    var inputRelay: OutsideCanvasBrushInputRelay?

    private var localEventMonitor: Any?
    private var isCapturingOutsideStart = false

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            removeLocalEventMonitor()
            cancelCaptureIfNeeded()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installLocalEventMonitorIfNeeded()
        }
    }

    private func installLocalEventMonitorIfNeeded() {
        guard localEventMonitor == nil else { return }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.handleLocalEvent(event) ?? event
        }
    }

    private func removeLocalEventMonitor() {
        guard let localEventMonitor else { return }
        NSEvent.removeMonitor(localEventMonitor)
        self.localEventMonitor = nil
    }

    private func handleLocalEvent(_ event: NSEvent) -> NSEvent? {
        guard event.window === window || isCapturingOutsideStart else { return event }

        switch event.type {
        case .leftMouseDown:
            guard !isCapturingOutsideStart else { return nil }
            let startsOutsideCanvas = outsideCanvasPoint(for: event) != nil
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard shouldBeginOutsideCanvasBrushStroke(
                activeTool: activeTool,
                isPanModeActive: isPanModeActive,
                modifiers: modifiers,
                startsOutsideCanvas: startsOutsideCanvas
            ) else {
                return event
            }
            isCapturingOutsideStart = true
            inputRelay?.begin(with: event)
            return nil

        case .leftMouseDragged:
            guard isCapturingOutsideStart else { return event }
            inputRelay?.append(events: brushEvents(from: event))
            return nil

        case .leftMouseUp:
            guard isCapturingOutsideStart else { return event }
            isCapturingOutsideStart = false
            inputRelay?.end(with: event)
            return nil

        default:
            return event
        }
    }

    private func outsideCanvasPoint(for event: NSEvent) -> CanvasPoint? {
        let localPoint = convert(event.locationInWindow, from: nil)
        guard bounds.contains(localPoint) else { return nil }
        let point = transform.viewportToCanvas(
            .init(x: localPoint.x, y: localPoint.y),
            clamped: false
        )
        return transform.containsCanvasPoint(point) ? nil : point
    }

    private func brushEvents(from event: NSEvent) -> [NSEvent] {
        var events = [event]
        while let queuedEvent = window?.nextEvent(
            matching: .leftMouseDragged,
            until: .distantPast,
            inMode: .eventTracking,
            dequeue: true
        ) {
            events.append(queuedEvent)
        }
        if events.count == 1 {
            while let queuedEvent = window?.nextEvent(
                matching: .leftMouseDragged,
                until: .distantPast,
                inMode: .default,
                dequeue: true
            ) {
                events.append(queuedEvent)
            }
        }
        return events
    }

    private func cancelCaptureIfNeeded() {
        guard isCapturingOutsideStart else { return }
        isCapturingOutsideStart = false
        inputRelay?.cancel()
    }
}

private final class OutsideCanvasSelectionEventView: NSView {
    var transform = CanvasViewportTransform(
        canvasSize: .init(width: 1, height: 1),
        viewport: .stageOneDefault,
        availableWidth: 1,
        availableHeight: 1
    )
    var activeTool: ToolKind = .rectangleSelection
    var onSelectionMouseDown: ((CanvasPoint, NSEvent.ModifierFlags) -> SelectionMouseDownAction)?
    var onSelectionChangedBatch: (([CanvasPoint], NSEvent.ModifierFlags) -> Void)?
    var onSelectionEnded: ((CanvasPoint, NSEvent.ModifierFlags) -> Void)?
    var onMoveSelectionPreview: ((Double, Double) -> Void)?
    var onCommitSelectionMove: (() -> Void)?
    var onPolygonClick: ((CanvasPoint, NSEvent.ModifierFlags, Int) -> Void)?
    var onPolygonHover: ((CanvasPoint) -> Void)?

    private var localEventMonitor: Any?
    private var isCapturingOutsideStart = false
    private var interactionMode: SelectionMouseDownAction = .idle
    private var selectionMoveLastPoint: CanvasPoint?
    private var initialClickCount = 1

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            removeLocalEventMonitor()
            resetCapture()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installLocalEventMonitorIfNeeded()
        }
    }

    private func installLocalEventMonitorIfNeeded() {
        guard localEventMonitor == nil else { return }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved]
        ) { [weak self] event in
            self?.handleLocalEvent(event) ?? event
        }
    }

    private func removeLocalEventMonitor() {
        guard let localEventMonitor else { return }
        NSEvent.removeMonitor(localEventMonitor)
        self.localEventMonitor = nil
    }

    private func handleLocalEvent(_ event: NSEvent) -> NSEvent? {
        guard activeTool.supportsOutsideCanvasSelectionStart else { return event }
        guard event.window === window || isCapturingOutsideStart else { return event }

        switch event.type {
        case .leftMouseDown:
            guard !isCapturingOutsideStart else { return nil }
            guard let point = outsideCanvasPoint(for: event) else { return event }
            let modifiers = normalizedModifiers(for: event)
            isCapturingOutsideStart = true
            initialClickCount = event.clickCount
            interactionMode = onSelectionMouseDown?(point, modifiers) ?? .beginDrawing
            selectionMoveLastPoint = interactionMode == .beginMoving ? point : nil
            return nil

        case .leftMouseDragged:
            guard isCapturingOutsideStart else { return event }
            let modifiers = normalizedModifiers(for: event)
            switch interactionMode {
            case .beginDrawing:
                guard activeTool != .polygonSelection else { return nil }
                let points = selectionCanvasPoints(from: event)
                if !points.isEmpty {
                    onSelectionChangedBatch?(points, modifiers)
                }
            case .beginMoving:
                let point = canvasPoint(for: event)
                if let lastPoint = selectionMoveLastPoint {
                    onMoveSelectionPreview?(point.x - lastPoint.x, point.y - lastPoint.y)
                }
                selectionMoveLastPoint = point
            case .idle:
                break
            }
            return nil

        case .leftMouseUp:
            guard isCapturingOutsideStart else { return event }
            let point = canvasPoint(for: event)
            let modifiers = normalizedModifiers(for: event)
            let completedMode = interactionMode
            let clickCount = max(initialClickCount, event.clickCount)
            resetCapture()

            if activeTool == .polygonSelection {
                switch completedMode {
                case .beginMoving:
                    onCommitSelectionMove?()
                case .beginDrawing, .idle:
                    onPolygonClick?(point, modifiers, clickCount)
                }
            } else {
                switch completedMode {
                case .beginDrawing:
                    onSelectionEnded?(point, modifiers)
                case .beginMoving:
                    onCommitSelectionMove?()
                case .idle:
                    break
                }
            }
            return nil

        case .mouseMoved:
            guard let point = outsideCanvasPoint(for: event) else { return event }
            NSCursor.crosshair.set()
            if activeTool == .polygonSelection {
                onPolygonHover?(point)
            }
            return event

        default:
            return event
        }
    }

    private func outsideCanvasPoint(for event: NSEvent) -> CanvasPoint? {
        let localPoint = convert(event.locationInWindow, from: nil)
        guard bounds.contains(localPoint) else { return nil }
        let point = transform.viewportToCanvas(
            .init(x: localPoint.x, y: localPoint.y),
            clamped: false
        )
        return transform.containsCanvasPoint(point) ? nil : point
    }

    private func canvasPoint(for event: NSEvent) -> CanvasPoint {
        let localPoint = convert(event.locationInWindow, from: nil)
        return transform.viewportToCanvas(
            .init(x: localPoint.x, y: localPoint.y),
            clamped: false
        )
    }

    private func selectionCanvasPoints(from event: NSEvent) -> [CanvasPoint] {
        guard activeTool == .lassoSelection || activeTool == .lassoFill || activeTool == .textureFill else {
            return [canvasPoint(for: event)]
        }

        var events = [event]
        while let queuedEvent = window?.nextEvent(
            matching: .leftMouseDragged,
            until: .distantPast,
            inMode: .eventTracking,
            dequeue: true
        ) {
            events.append(queuedEvent)
        }
        if events.count == 1 {
            while let queuedEvent = window?.nextEvent(
                matching: .leftMouseDragged,
                until: .distantPast,
                inMode: .default,
                dequeue: true
            ) {
                events.append(queuedEvent)
            }
        }
        return events.map(canvasPoint(for:))
    }

    private func normalizedModifiers(for event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    }

    private func resetCapture() {
        isCapturingOutsideStart = false
        interactionMode = .idle
        selectionMoveLastPoint = nil
        initialClickCount = 1
    }
}

private struct PerspectiveGuideGestureOverlay: View {
    let transform: CanvasViewportTransform
    let onBegan: (CanvasPoint) -> Void
    let onChanged: (CanvasPoint) -> Void
    let onEnded: () -> Void

    @State private var isDragging = false

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let point = canvasPoint(for: value.location)
                        if !isDragging {
                            isDragging = true
                            onBegan(canvasPoint(for: value.startLocation))
                        }
                        onChanged(point)
                    }
                    .onEnded { _ in
                        onEnded()
                        isDragging = false
                    }
            )
            .onHover { hovering in
                if hovering {
                    NSCursor.crosshair.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
    }

    private func canvasPoint(for point: CGPoint) -> CanvasPoint {
        transform.viewportToCanvas(CanvasPoint(x: point.x, y: point.y), clamped: false)
    }
}

private struct PerspectiveGuideOverlay: View {
    let guide: PerspectiveGuideState
    let selectedAnchorID: UUID?
    let isEditing: Bool
    let transform: CanvasViewportTransform

    var body: some View {
        Canvas { context, _ in
            let lineColor = Color(
                red: Double(guide.color.red),
                green: Double(guide.color.green),
                blue: Double(guide.color.blue),
                opacity: Double(guide.opacity)
            )
            let documentPath = Path { path in
                let corners = [
                    CanvasPoint(x: 0, y: 0),
                    CanvasPoint(x: Double(transform.canvasSize.width), y: 0),
                    CanvasPoint(
                        x: Double(transform.canvasSize.width),
                        y: Double(transform.canvasSize.height)
                    ),
                    CanvasPoint(x: 0, y: Double(transform.canvasSize.height))
                ].map(transform.canvasToViewport)
                guard let first = corners.first else { return }
                path.move(to: CGPoint(x: first.x, y: first.y))
                for corner in corners.dropFirst() {
                    path.addLine(to: CGPoint(x: corner.x, y: corner.y))
                }
                path.closeSubpath()
            }

            var clippedContext = context
            clippedContext.clip(to: documentPath)

            if guide.mode == .onePoint {
                drawPerspectiveLine(
                    from: CanvasPoint(x: 0, y: guide.leftVanishingPoint.y),
                    through: CanvasPoint(
                        x: Double(transform.canvasSize.width),
                        y: guide.leftVanishingPoint.y
                    ),
                    in: clippedContext,
                    color: lineColor.opacity(0.8),
                    lineWidth: CGFloat(guide.lineWidth) * 1.25,
                    dash: [8, 5]
                )
            } else {
                drawPerspectiveLine(
                    from: guide.leftVanishingPoint,
                    through: guide.rightVanishingPoint,
                    in: clippedContext,
                    color: lineColor.opacity(0.8),
                    lineWidth: CGFloat(guide.lineWidth) * 1.25,
                    dash: [8, 5]
                )
            }

            for anchor in guide.anchors {
                for role in guide.activeVanishingPointRoles where anchor.connects(to: role) {
                    drawPerspectiveLine(
                        from: guide.vanishingPoint(for: role),
                        through: anchor.position,
                        in: clippedContext,
                        color: lineColor,
                        lineWidth: CGFloat(guide.lineWidth),
                        dash: []
                    )
                }
            }

            guard isEditing else { return }
            for role in guide.activeVanishingPointRoles {
                drawVanishingPointHandle(role, in: context, color: lineColor)
            }
            for anchor in guide.anchors {
                drawAnchorHandle(anchor, in: context, color: lineColor)
            }
        }
    }

    private func drawPerspectiveLine(
        from first: CanvasPoint,
        through second: CanvasPoint,
        in context: GraphicsContext,
        color: Color,
        lineWidth: CGFloat,
        dash: [CGFloat]
    ) {
        let axisX = second.x - first.x
        let axisY = second.y - first.y
        let length = hypot(axisX, axisY)
        guard length > 0.000_001 else { return }
        let directionX = axisX / length
        let directionY = axisY / length
        let coordinateExtent = [
            Double(max(transform.canvasSize.width, transform.canvasSize.height)),
            abs(first.x),
            abs(first.y),
            abs(second.x),
            abs(second.y)
        ].max() ?? 1
        let extensionDistance = max(coordinateExtent * 4, 1_000)
        let start = transform.canvasToViewport(
            CanvasPoint(
                x: first.x - (directionX * extensionDistance),
                y: first.y - (directionY * extensionDistance)
            )
        )
        let end = transform.canvasToViewport(
            CanvasPoint(
                x: first.x + (directionX * extensionDistance),
                y: first.y + (directionY * extensionDistance)
            )
        )
        var path = Path()
        path.move(to: CGPoint(x: start.x, y: start.y))
        path.addLine(to: CGPoint(x: end.x, y: end.y))
        let drawingContext = context
        drawingContext.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(
                lineWidth: lineWidth,
                lineCap: .round,
                lineJoin: .round,
                dash: dash
            )
        )
    }

    private func drawVanishingPointHandle(
        _ role: PerspectiveVanishingPointRole,
        in context: GraphicsContext,
        color: Color
    ) {
        let drawingContext = context
        let point = transform.canvasToViewport(guide.vanishingPoint(for: role))
        let rect = CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18)
        drawingContext.fill(Path(ellipseIn: rect), with: .color(Color.black.opacity(0.72)))
        drawingContext.stroke(Path(ellipseIn: rect), with: .color(color.opacity(0.95)), lineWidth: 2)
        let label: String
        switch (guide.mode, role) {
        case (.onePoint, .left):
            label = "1"
        case (_, .left):
            label = "左"
        case (_, .right):
            label = "右"
        case (_, .vertical):
            label = guide.verticalDirection == .above ? "上" : "下"
        }
        drawingContext.draw(
            Text(label).font(.system(size: 8, weight: .bold)).foregroundStyle(Color.white),
            at: CGPoint(x: point.x, y: point.y)
        )
    }

    private func drawAnchorHandle(
        _ anchor: PerspectiveGuideAnchor,
        in context: GraphicsContext,
        color: Color
    ) {
        let drawingContext = context
        let point = transform.canvasToViewport(anchor.position)
        let isSelected = anchor.id == selectedAnchorID
        let radius = isSelected ? 6.0 : 4.5
        let rect = CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        drawingContext.fill(
            Path(ellipseIn: rect),
            with: .color(isSelected ? color.opacity(0.95) : Color.black.opacity(0.65))
        )
        drawingContext.stroke(
            Path(ellipseIn: rect),
            with: .color(isSelected ? Color.white : color.opacity(0.9)),
            lineWidth: isSelected ? 2 : 1.4
        )
    }
}

private struct PerspectiveGuideHUD: View {
    let guide: PerspectiveGuideState
    let onToggleLock: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "triangle")
                .font(.system(size: 11, weight: .semibold))
            Text("\(guide.mode.displayName)透视 · \(guide.anchors.count) 个锚点")
                .font(.system(size: 11, weight: .semibold))
            Button(guide.isLocked ? "解锁编辑" : "锁定") {
                onToggleLock()
            }
            .buttonStyle(.borderless)
            .font(.system(size: 10, weight: .semibold))
            Button("清除") {
                onClear()
            }
            .buttonStyle(.borderless)
            .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Capsule().fill(Color.black.opacity(0.62)))
    }
}

private struct CanvasCropOverlay: View {
    let bounds: CanvasRect
    let presentation: CanvasPresentation
    let canvasSize: CanvasSize
    let viewportZoomScale: Double

    var body: some View {
        let scaleX = presentation.documentDisplaySize.x / Double(max(canvasSize.width, 1))
        let scaleY = presentation.documentDisplaySize.y / Double(max(canvasSize.height, 1))
        let rect = CGRect(
            x: bounds.minX * scaleX,
            y: bounds.minY * scaleY,
            width: bounds.size.x * scaleX,
            height: bounds.size.y * scaleY
        )
        let inverseZoom = 1 / max(viewportZoomScale, 0.01)
        let handleSize = 8 * inverseZoom
        let lineWidth = 1.2 * inverseZoom
        let handlePoints = cropHandlePoints(in: rect)
        let guidePath = Path { path in
            path.addRect(rect)
            path.move(to: CGPoint(x: rect.minX + rect.width / 3, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + rect.width / 3, y: rect.maxY))
            path.move(to: CGPoint(x: rect.minX + rect.width * 2 / 3, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 2 / 3, y: rect.maxY))
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height / 3))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height / 3))
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 2 / 3))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 2 / 3))
        }

        ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(CGRect(
                    x: 0,
                    y: 0,
                    width: presentation.documentDisplaySize.x,
                    height: presentation.documentDisplaySize.y
                ))
                path.addRect(rect)
            }
            .fill(Color.black.opacity(0.48), style: FillStyle(eoFill: true))

            guidePath
                .stroke(Color.black.opacity(0.65), lineWidth: lineWidth * 2.4)

            guidePath
                .stroke(Color.white.opacity(0.92), lineWidth: lineWidth)

            ForEach(Array(handlePoints.enumerated()), id: \.offset) { _, point in
                Rectangle()
                    .fill(Color.white)
                    .frame(width: handleSize, height: handleSize)
                    .overlay(Rectangle().stroke(Color.black.opacity(0.7), lineWidth: lineWidth))
                    .position(point)
            }
        }
    }

    private func cropHandlePoints(in rect: CGRect) -> [CGPoint] {
        [
            .init(x: rect.minX, y: rect.minY),
            .init(x: rect.midX, y: rect.minY),
            .init(x: rect.maxX, y: rect.minY),
            .init(x: rect.maxX, y: rect.midY),
            .init(x: rect.maxX, y: rect.maxY),
            .init(x: rect.midX, y: rect.maxY),
            .init(x: rect.minX, y: rect.maxY),
            .init(x: rect.minX, y: rect.midY)
        ]
    }
}

private struct CanvasPixelGridOverlay: View {
    let transform: CanvasViewportTransform

    var body: some View {
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, size in
            let visibleCanvasBounds = visibleCanvasBounds(for: size)
            var path = Path()

            if visibleCanvasBounds.minX <= visibleCanvasBounds.maxX {
                for x in visibleCanvasBounds.minX...visibleCanvasBounds.maxX {
                    let start = transform.canvasToViewport(.init(x: Double(x), y: 0))
                    let end = transform.canvasToViewport(
                        .init(x: Double(x), y: Double(transform.canvasSize.height))
                    )
                    path.move(to: CGPoint(x: start.x, y: start.y))
                    path.addLine(to: CGPoint(x: end.x, y: end.y))
                }
            }

            if visibleCanvasBounds.minY <= visibleCanvasBounds.maxY {
                for y in visibleCanvasBounds.minY...visibleCanvasBounds.maxY {
                    let start = transform.canvasToViewport(.init(x: 0, y: Double(y)))
                    let end = transform.canvasToViewport(
                        .init(x: Double(transform.canvasSize.width), y: Double(y))
                    )
                    path.move(to: CGPoint(x: start.x, y: start.y))
                    path.addLine(to: CGPoint(x: end.x, y: end.y))
                }
            }

            context.stroke(
                path,
                with: .color(Color.black.opacity(0.24)),
                lineWidth: 1
            )
        }
    }

    private func visibleCanvasBounds(for size: CGSize) -> (
        minX: Int,
        maxX: Int,
        minY: Int,
        maxY: Int
    ) {
        let viewportCorners = [
            CanvasPoint(x: 0, y: 0),
            CanvasPoint(x: size.width, y: 0),
            CanvasPoint(x: size.width, y: size.height),
            CanvasPoint(x: 0, y: size.height)
        ]
        let canvasCorners = viewportCorners.map { transform.viewportToCanvas($0) }
        let minX = max(0, Int(floor(canvasCorners.map(\.x).min() ?? 0)) - 1)
        let maxX = min(transform.canvasSize.width, Int(ceil(canvasCorners.map(\.x).max() ?? 0)) + 1)
        let minY = max(0, Int(floor(canvasCorners.map(\.y).min() ?? 0)) - 1)
        let maxY = min(transform.canvasSize.height, Int(ceil(canvasCorners.map(\.y).max() ?? 0)) + 1)
        return (minX, maxX, minY, maxY)
    }
}

private struct FreeTransformHUD: View {
    let isApplying: Bool
    let toolMode: FreeTransformToolMode
    let selectedMeshPointCount: Int
    let preciseInput: PreciseAffineInput?
    let onToolModeChanged: (FreeTransformToolMode) -> Void
    let onPreciseInputChanged: (PreciseAffineInput) -> Void
    let onFlipHorizontal: () -> Void
    let onFlipVertical: () -> Void
    let onApply: () -> Void
    let onCancel: () -> Void

    @State private var showsPrecisePanel = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.82))

            Text(isApplying ? "应用中" : (toolMode == .mesh ? "网格变形" : "自由变形"))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white)

            HStack(spacing: 2) {
                transformModeButton(title: "自由", mode: .standard)
                transformModeButton(title: "网格", mode: .mesh)
            }
            .padding(2)
            .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 7))

            if toolMode == .mesh, !isApplying {
                Text(selectedMeshPointCount > 0 ? "已选 \(selectedMeshPointCount) 点" : "Shift 多选")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .help("按住 Shift 点击可追加或移除四角锚点；拖动格内区域可局部变形")
            }

            if toolMode == .standard, let preciseInput, !isApplying {
                Button("数值") {
                    showsPrecisePanel.toggle()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .popover(isPresented: $showsPrecisePanel, arrowEdge: .top) {
                    PreciseTransformPanel(
                        input: preciseInput,
                        onUpdate: onPreciseInputChanged
                    )
                }
                .buttonTooltip("输入中心、尺寸、旋转和翻转")

                flipButton(
                    title: "水平翻转",
                    systemImage: "arrow.left.and.right",
                    isActive: preciseInput.isHorizontallyFlipped,
                    action: onFlipHorizontal
                )
                flipButton(
                    title: "垂直翻转",
                    systemImage: "arrow.up.and.down",
                    isActive: preciseInput.isVerticallyFlipped,
                    action: onFlipVertical
                )
            }

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
            .buttonTooltip("应用自由变形")

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
            .buttonTooltip("取消自由变形")
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.55))
        )
    }

    private func transformModeButton(
        title: String,
        mode: FreeTransformToolMode
    ) -> some View {
        Button {
            onToolModeChanged(mode)
        } label: {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(toolMode == mode ? 1 : 0.62))
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(toolMode == mode ? Color.accentColor.opacity(0.72) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .disabled(isApplying)
    }

    private func flipButton(
        title: String,
        systemImage: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(isActive ? 1 : 0.78))
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? Color.accentColor.opacity(0.72) : Color.white.opacity(0.1))
                )
        }
        .buttonStyle(.plain)
        .disabled(isApplying)
        .buttonTooltip(title)
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
    let brush: BrushSettings
    let color: RGBAColor

    var body: some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: map(preview.pointA))
                path.addLine(to: map(preview.pointB))
            }
            .stroke(
                Color.accentColor.opacity(0.35),
                style: StrokeStyle(
                    lineWidth: previewLineWidth + 2,
                    lineCap: previewLineCap
                )
            )

            Path { path in
                path.move(to: map(preview.pointA))
                path.addLine(to: map(preview.pointB))
            }
            .stroke(
                previewColor,
                style: StrokeStyle(
                    lineWidth: previewLineWidth,
                    lineCap: previewLineCap
                )
            )

            pointMarker(preview.pointA, label: "A")
            pointMarker(preview.pointB, label: "B")

            if let handlePoint = preview.thicknessHandlePoint {
                Path { path in
                    path.move(to: map(preview.pointB))
                    path.addLine(to: map(handlePoint))
                }
                .stroke(
                    Color.accentColor.opacity(0.9),
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                )

                thicknessLabel(at: handlePoint)
            } else if preview.isPending {
                thicknessLabel(at: preview.pointB)
            }
        }
    }

    private func thicknessLabel(at point: CanvasPoint) -> some View {
        Text("\(Int(brush.size.rounded())) px")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.92), in: Capsule())
            .position(map(point))
            .offset(x: 18, y: 18)
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

    private var previewLineWidth: Double {
        let scaleX = presentation.documentDisplaySize.x / Double(max(canvasSize.width, 1))
        let scaleY = presentation.documentDisplaySize.y / Double(max(canvasSize.height, 1))
        return max(Double(brush.size) * min(scaleX, scaleY), 1)
    }

    private var previewLineCap: CGLineCap {
        brush.tipShape == .square ? .butt : .round
    }

    private var previewColor: Color {
        Color(
            red: Double(color.red),
            green: Double(color.green),
            blue: Double(color.blue),
            opacity: Double(color.alpha * brush.opacity)
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
            pointMarker(preview.pointA, label: "起")
            pointMarker(preview.pointB, label: "止")
            if let geometry = preview.geometry {
                midpointMarker(
                    geometry.transitionMidpointPoint,
                    percentage: geometry.transitionMidpoint
                )
            }
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

    private func midpointMarker(_ point: CanvasPoint, percentage: Double) -> some View {
        let mapped = map(point)
        return ZStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.accentColor, lineWidth: 2)
                )
                .frame(width: 11, height: 11)
                .rotationEffect(.degrees(45))
            Text("\(Int((percentage * 100).rounded()))%")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.7), in: Capsule())
                .offset(y: 20)
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
    let showsSelectionTint: Bool
    let previewOffset: CanvasPoint
    let prefersVectorDisplay: Bool
    let smoothsLassoPath: Bool
    let maskCacheNamespace: UUID?
    let maskCacheRevision: UInt64?

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
                                    cacheNamespace: maskCacheNamespace,
                                    cacheRevision: maskCacheRevision,
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

            if showsSelectionTint {
                SelectionMaskImageView(
                    selectionShape: shape,
                    presentation: presentation,
                    canvasSize: canvasSize,
                    edgeOnly: false,
                    cacheNamespace: maskCacheNamespace,
                    cacheRevision: maskCacheRevision,
                    tint: Color(red: 0.12, green: 0.55, blue: 1)
                )
                .opacity(0.3)
                .offset(x: documentFrame.origin.x, y: documentFrame.origin.y)
            } else {
                SelectionMaskImageView(
                    selectionShape: shape,
                    presentation: presentation,
                    canvasSize: canvasSize,
                    edgeOnly: true,
                    dashesEdge: false,
                    cacheNamespace: maskCacheNamespace,
                    cacheRevision: maskCacheRevision,
                    tint: .black.opacity(0.88)
                )
                .offset(x: documentFrame.origin.x, y: documentFrame.origin.y)

                SelectionMaskImageView(
                    selectionShape: shape,
                    presentation: presentation,
                    canvasSize: canvasSize,
                    edgeOnly: true,
                    dashesEdge: true,
                    cacheNamespace: maskCacheNamespace,
                    cacheRevision: maskCacheRevision,
                    tint: .white
                )
                .offset(x: documentFrame.origin.x, y: documentFrame.origin.y)
            }
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
            CanvasPoint(
                x: (($0.x - bounds.origin.x) / canvasWidth) * displayWidth,
                y: (($0.y - bounds.origin.y) / canvasHeight) * displayHeight
            )
        }
        if smoothsLassoPath,
           let smoothedPath = smoothedClosedLassoPath(points: mappedPoints) {
            return Path(smoothedPath)
        }
        return Path { path in
            guard let firstPoint = mappedPoints.first else { return }
            path.move(to: CGPoint(x: firstPoint.x, y: firstPoint.y))
            path.addLines(mappedPoints.dropFirst().map { CGPoint(x: $0.x, y: $0.y) })
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
            if RuntimeDiagnostics.selectionTraceLoggingEnabled {
                let message = "[vectorDisplayShape] source=composite componentCount=\(shape.components.count) boundsOrigin=(\(shape.bounds.origin.x),\(shape.bounds.origin.y)) boundsSize=(\(shape.bounds.size.x),\(shape.bounds.size.y))"
                selectionTraceLogger.debug("\(message, privacy: .public)")
                emitSelectionTraceCanvas(message)
            }
            return SelectionShape.composite(shape.components)
        }
        if shape.components.count == 1,
           let component = shape.components.first,
           component.operation == .add {
            if RuntimeDiagnostics.selectionTraceLoggingEnabled {
                let message = "[vectorDisplayShape] source=component kind=\(component.shape.kind.rawValue) boundsOrigin=(\(component.shape.bounds.origin.x),\(component.shape.bounds.origin.y)) boundsSize=(\(component.shape.bounds.size.x),\(component.shape.bounds.size.y))"
                selectionTraceLogger.debug("\(message, privacy: .public)")
                emitSelectionTraceCanvas(message)
            }
            return component.shape
        }
        if shape.pathPoints.count >= 3 {
            if RuntimeDiagnostics.selectionTraceLoggingEnabled {
                let message = "[vectorDisplayShape] source=maskPath pathCount=\(shape.pathPoints.count) boundsOrigin=(\(shape.bounds.origin.x),\(shape.bounds.origin.y)) boundsSize=(\(shape.bounds.size.x),\(shape.bounds.size.y))"
                selectionTraceLogger.debug("\(message, privacy: .public)")
                emitSelectionTraceCanvas(message)
            }
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
    var dashesEdge: Bool = false
    let cacheNamespace: UUID?
    let cacheRevision: UInt64?
    let tint: Color

    var body: some View {
        Group {
            if let slice = resolvedSlice {
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

    private var resolvedSlice: SelectionMaskImageSlice? {
        if let cacheNamespace, let cacheRevision {
            return SelectionMaskImageCache.shared.slice(
                shape: selectionShape,
                canvasSize: canvasSize,
                edgeOnly: edgeOnly,
                dashesEdge: dashesEdge,
                namespace: cacheNamespace,
                revision: cacheRevision
            )
        }
        return makeSelectionMaskImageSlice(
            shape: selectionShape,
            canvasSize: canvasSize,
            edgeOnly: edgeOnly,
            dashesEdge: dashesEdge
        )
    }
}

private struct SelectionMaskImageSlice {
    let cgImage: CGImage
    let originX: Double
    let originY: Double
    let displayWidth: Double
    let displayHeight: Double
}

private final class SelectionMaskImageSliceBox: NSObject {
    let slice: SelectionMaskImageSlice

    init(_ slice: SelectionMaskImageSlice) {
        self.slice = slice
    }
}

@MainActor
private final class SelectionMaskImageCache {
    static let shared = SelectionMaskImageCache()

    private let storage: NSCache<NSString, SelectionMaskImageSliceBox> = {
        let cache = NSCache<NSString, SelectionMaskImageSliceBox>()
        cache.countLimit = 18
        cache.totalCostLimit = 256 * 1_024 * 1_024
        return cache
    }()

    func slice(
        shape: SelectionShape,
        canvasSize: CanvasSize,
        edgeOnly: Bool,
        dashesEdge: Bool,
        namespace: UUID,
        revision: UInt64
    ) -> SelectionMaskImageSlice? {
        let key = NSString(
            string: "\(namespace.uuidString)-\(revision)-\(canvasSize.width)x\(canvasSize.height)-\(edgeOnly)-\(dashesEdge)"
        )
        if let cached = storage.object(forKey: key) {
            return cached.slice
        }
        guard let slice = makeSelectionMaskImageSlice(
            shape: shape,
            canvasSize: canvasSize,
            edgeOnly: edgeOnly,
            dashesEdge: dashesEdge
        ) else {
            return nil
        }
        let cost = slice.cgImage.bytesPerRow * slice.cgImage.height
        storage.setObject(SelectionMaskImageSliceBox(slice), forKey: key, cost: cost)
        return slice
    }
}

private func makeSelectionMaskImageSlice(
    shape: SelectionShape,
    canvasSize: CanvasSize,
    edgeOnly: Bool,
    dashesEdge: Bool = false
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
    if RuntimeDiagnostics.selectionTraceLoggingEnabled {
        let message = "[makeSelectionMaskImageSlice] edgeOnly=\(edgeOnly) shapeKind=\(shape.kind.rawValue) shapeBoundsOrigin=(\(shape.bounds.origin.x),\(shape.bounds.origin.y)) shapeBoundsSize=(\(shape.bounds.size.x),\(shape.bounds.size.y)) cropped=(\(minX),\(minY))-(\(maxX),\(maxY))"
        selectionTraceLogger.debug("\(message, privacy: .public)")
        emitSelectionTraceCanvas(message)
    }
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
                    let edgeThreshold: UInt8 = 128
                    if alpha < edgeThreshold {
                        shouldDraw = 0
                    } else {
                        let left = sourceX > 0 ? source[index - 1] : 0
                        let right = sourceX < width - 1 ? source[index + 1] : 0
                        let up = sourceY > 0 ? source[index - maskData.canvasWidth] : 0
                        let down = sourceY < height - 1 ? source[index + maskData.canvasWidth] : 0
                        let isEdge = left < edgeThreshold || right < edgeThreshold || up < edgeThreshold || down < edgeThreshold
                        let isVisibleDash = !dashesEdge || ((sourceX + sourceY) % 12) < 6
                        shouldDraw = isEdge && isVisibleDash ? 255 : 0
                    }
                } else {
                    shouldDraw = alpha
                }

                let rgbaIndex = ((y * croppedWidth) + x) * 4
                // CGImage 声明为 premultipliedLast，RGB 必须先乘 alpha。
                // 羽化选区包含中间 alpha；写死 255 会生成非法预乘像素，
                // AppKit/SwiftUI 可能把整个遮罩或边界渲染为空。
                rgba[rgbaIndex] = shouldDraw
                rgba[rgbaIndex + 1] = shouldDraw
                rgba[rgbaIndex + 2] = shouldDraw
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

private struct PatternPlacementHUD: View {
    let opacity: Float
    let onRotateLeft: () -> Void
    let onRotateRight: () -> Void
    let onFlipHorizontal: () -> Void
    let onFlipVertical: () -> Void
    let onOpacityChanged: (Float) -> Void
    let onApply: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Label("图案放置", systemImage: "photo.on.rectangle.angled")
                .font(.system(size: 11, weight: .bold))

            Divider().frame(height: 18)

            patternButton("向左旋转", systemImage: "rotate.left", action: onRotateLeft)
            patternButton("向右旋转", systemImage: "rotate.right", action: onRotateRight)
            patternButton("水平翻转", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right", action: onFlipHorizontal)
            patternButton("垂直翻转", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down", action: onFlipVertical)

            Text("透明")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.72))
            Slider(
                value: Binding(
                    get: { Double(opacity) },
                    set: { onOpacityChanged(Float($0)) }
                ),
                in: 0.05...1
            )
            .frame(width: 72)

            Button("应用", action: onApply)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: [])
            Button("取消", action: onCancel)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.76))
                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
        )
        .foregroundStyle(Color.white.opacity(0.94))
    }

    private func patternButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .help(title)
    }
}

private struct PatternPlacementHandlesOverlay: View {
    let draft: PatternPlacementDraft
    let presentation: CanvasPresentation
    let canvasSize: CanvasSize

    var body: some View {
        let corners = draft.rotatedCorners.map(map)
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
                .stroke(Color.white, style: StrokeStyle(lineWidth: 1.2, dash: [6, 4]))

                ForEach(corners.indices, id: \.self) { index in
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 9, height: 9)
                        .overlay(Rectangle().stroke(Color.black.opacity(0.7), lineWidth: 1))
                        .position(corners[index])
                }
            }
        }
    }

    private func map(_ point: CanvasPoint) -> CGPoint {
        let scaleX = presentation.documentDisplaySize.x / Double(max(canvasSize.width, 1))
        let scaleY = presentation.documentDisplaySize.y / Double(max(canvasSize.height, 1))
        return CGPoint(
            x: presentation.documentOrigin.x + (point.x * scaleX),
            y: presentation.documentOrigin.y + (point.y * scaleY)
        )
    }
}

private struct FreeTransformHandlesOverlay: View {
    let bounds: CanvasRect
    let preview: FreeTransformPreview
    let presentation: CanvasPresentation
    let canvasSize: CanvasSize
    private let handleSize: CGFloat = 8

    var body: some View {
        let scaleX = presentation.documentDisplaySize.x / Double(canvasSize.width)
        let scaleY = presentation.documentDisplaySize.y / Double(canvasSize.height)
        let handleMetrics = freeTransformHandleMetrics(
            canvasExtent: Double(canvasSize.width),
            displayExtent: presentation.documentDisplaySize.x
        )
        let corners = freeTransformCornerPoints(bounds: bounds, preview: preview).map { point in
            CGPoint(
                x: presentation.documentOrigin.x + (point.x * scaleX),
                y: presentation.documentOrigin.y + (point.y * scaleY)
            )
        }
        let handleMap = freeTransformHandlePoints(
            bounds: bounds,
            preview: preview,
            rotationHandleDistance: handleMetrics.rotationHandleDistance
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

private struct MeshWarpGridOverlay: View {
    let grid: MeshWarpGrid
    let activeInteractionMode: FreeTransformInteractionMode?
    let selectedControlPointIndices: Set<Int>
    let presentation: CanvasPresentation
    let canvasSize: CanvasSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                for row in 0..<grid.rows {
                    let v = Double(row) / Double(max(grid.rows - 1, 1))
                    guard let first = grid.surfacePoint(at: .init(u: 0, v: v)) else { continue }
                    path.move(to: map(first))
                    for step in 1...guideSubdivisions {
                        let u = Double(step) / Double(guideSubdivisions)
                        if let point = grid.surfacePoint(at: .init(u: u, v: v)) {
                            path.addLine(to: map(point))
                        }
                    }
                }
                for column in 0..<grid.columns {
                    let u = Double(column) / Double(max(grid.columns - 1, 1))
                    guard let first = grid.surfacePoint(at: .init(u: u, v: 0)) else { continue }
                    path.move(to: map(first))
                    for step in 1...guideSubdivisions {
                        let v = Double(step) / Double(guideSubdivisions)
                        if let point = grid.surfacePoint(at: .init(u: u, v: v)) {
                            path.addLine(to: map(point))
                        }
                    }
                }
            }
            .stroke(
                Color.accentColor.opacity(0.88),
                style: StrokeStyle(lineWidth: 1.15, dash: [5, 3])
            )

            ForEach(grid.cornerControlPointIndices, id: \.self) { index in
                if grid.controlPoints.indices.contains(index) {
                    let point = grid.controlPoints[index]
                    let isActive: Bool = {
                        guard case .meshPoint(let activeIndex) = activeInteractionMode else {
                            return false
                        }
                        return activeIndex == index
                    }()
                    let isSelected = selectedControlPointIndices.contains(index)
                    Circle()
                        .fill(isSelected ? Color.accentColor : Color.white)
                        .frame(
                            width: isActive ? 12 : (isSelected ? 10 : 9),
                            height: isActive ? 12 : (isSelected ? 10 : 9)
                        )
                        .overlay(
                            Circle()
                                .stroke(Color.black.opacity(0.72), lineWidth: 1.2)
                        )
                        .position(map(point))
                }
            }
        }
    }

    private var guideSubdivisions: Int {
        max((max(grid.columns, grid.rows) - 1) * 8, 8)
    }

    private func map(_ point: CanvasPoint) -> CGPoint {
        let scaleX = presentation.documentDisplaySize.x / Double(max(canvasSize.width, 1))
        let scaleY = presentation.documentDisplaySize.y / Double(max(canvasSize.height, 1))
        return CGPoint(
            x: presentation.documentOrigin.x + (point.x * scaleX),
            y: presentation.documentOrigin.y + (point.y * scaleY)
        )
    }
}

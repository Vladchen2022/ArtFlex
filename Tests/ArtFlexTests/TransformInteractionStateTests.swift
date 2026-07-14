import Testing
import CoreGraphics
@testable import ArtFlex

struct TransformInteractionStateTests {
    @Test
    func transformSessionAccumulatesOffsetsAcrossMultipleDrags() {
        var state = TransformInteractionState()

        state.beginSession(at: .init(x: 10, y: 10))
        let firstDelta = state.finishDrag(at: .init(x: 18.2, y: 15.8))
        #expect(firstDelta == .init(x: 8, y: 6))
        #expect(state.accumulatedOffset == .init(x: 8, y: 6))

        state.beginDrag(at: .init(x: 18, y: 16))
        let secondDelta = state.finishDrag(at: .init(x: 14.4, y: 26.2))
        #expect(secondDelta == .init(x: -4, y: 10))
        #expect(state.accumulatedOffset == .init(x: 4, y: 16))
    }

    @Test
    func clearBehaviorAppliesOnlyWhenTransformHasPendingOffset() {
        var state = TransformInteractionState()

        #expect(state.clearBehavior() == .none)

        state.beginSession(at: .init(x: 0, y: 0))
        #expect(state.clearBehavior() == .cancel)

        _ = state.finishDrag(at: .init(x: 12, y: 0))
        #expect(state.clearBehavior() == .apply)
    }

    @Test
    func clearBehaviorCancelsActiveTransformWithoutOffset() {
        var state = TransformInteractionState()

        state.beginSession(at: .init(x: 5, y: 5))

        #expect(state.hasPendingOffset == false)
        #expect(state.clearBehavior() == .cancel)
    }

    @Test
    func resetClearsSessionState() {
        var state = TransformInteractionState()

        state.beginSession(at: .init(x: 4, y: 5))
        _ = state.finishDrag(at: .init(x: 9, y: 11))
        state.reset()

        #expect(state.isActive == false)
        #expect(state.dragStartPoint == nil)
        #expect(state.accumulatedOffset == .init(x: 0, y: 0))
        #expect(state.clearBehavior() == .none)
    }

    @Test
    func toolAndLayerChangesApplyOnlyWhenTransformHasPendingOffset() {
        var state = TransformInteractionState()

        #expect(state.resolutionAction(for: .toolChange) == .none)
        #expect(state.resolutionAction(for: .layerChange) == .none)

        state.beginSession(at: .init(x: 0, y: 0))
        #expect(state.resolutionAction(for: .toolChange) == .cancelAndClearSelection)
        #expect(state.resolutionAction(for: .layerChange) == .cancelAndClearSelection)

        _ = state.finishDrag(at: .init(x: 12, y: 4))
        #expect(state.resolutionAction(for: .toolChange) == .applyAndClearSelection)
        #expect(state.resolutionAction(for: .layerChange) == .applyAndClearSelection)
    }

    @Test
    func historyNavigationCancelsTransformButPreservesSelection() {
        var state = TransformInteractionState()
        state.beginSession(at: .init(x: 5, y: 5))

        #expect(state.resolutionAction(for: .historyNavigation) == .cancelAndPreserveSelection)

        _ = state.finishDrag(at: .init(x: 11, y: 12))
        #expect(state.resolutionAction(for: .historyNavigation) == .cancelAndPreserveSelection)
    }

    @Test
    func documentOpenCancelsTransformAndClearsSelection() {
        var state = TransformInteractionState()
        state.beginSession(at: .init(x: 3, y: 9))

        #expect(state.resolutionAction(for: .documentOpen) == .cancelAndClearSelection)

        _ = state.finishDrag(at: .init(x: 9, y: 12))
        #expect(state.resolutionAction(for: .documentOpen) == .cancelAndClearSelection)
    }

    @Test
    func scaleOnlyTransformStillRequiresApply() {
        var state = TransformInteractionState()
        state.beginSession(at: .init(x: 0, y: 0))
        state.preview = FreeTransformPreview(
            translation: .init(x: 0, y: 0),
            scaleX: 1.2,
            scaleY: 1,
            rotationRadians: 0
        )

        #expect(state.clearBehavior() == .apply)
        #expect(state.resolutionAction(for: .toolChange) == .applyAndClearSelection)
    }

    @Test
    func liveMovePreviewPreservesFractionalTranslation() {
        let preview = freeTransformTranslatedPreview(
            dragStartPoint: .init(x: 10, y: 20),
            currentPoint: .init(x: 15.25, y: 31.75),
            startPreview: .identity
        )

        #expect(preview.translation.x == 5.25)
        #expect(preview.translation.y == 11.75)
    }

    @Test
    func uniformScaleKeepsAxesEqual() {
        let bounds = CanvasRect(
            origin: .init(x: 0, y: 0),
            size: .init(x: 100, y: 80)
        )

        let preview = freeTransformScaledPreview(
            bounds: bounds,
            handle: .topRight,
            dragStartPoint: .init(x: 100, y: 0),
            currentPoint: .init(x: 130, y: -10),
            startPreview: .identity,
            uniformScale: true
        )

        #expect(abs(preview.scaleX - preview.scaleY) < 0.0001)
    }

    @Test
    func customPivotBoundsAffectWholeLayerRotationCenter() {
        let fullBounds = CanvasRect(
            origin: .init(x: 0, y: 0),
            size: .init(x: 100, y: 100)
        )
        let pivotBounds = CanvasRect(
            origin: .init(x: 60, y: 60),
            size: .init(x: 20, y: 20)
        )
        let transform = freeTransformAffineTransform(
            bounds: fullBounds,
            preview: FreeTransformPreview(
                translation: .init(x: 0, y: 0),
                scaleX: 1,
                scaleY: 1,
                rotationRadians: .pi / 2
            ),
            pivotBounds: pivotBounds
        )

        let transformedCenter = CGPoint(x: 50, y: 50).applying(transform)
        #expect(abs(transformedCenter.x - 90) < 0.001)
        #expect(abs(transformedCenter.y - 50) < 0.001)
    }

    @Test
    func handlesAreHiddenOnlyDuringMoveDrag() {
        #expect(
            shouldShowFreeTransformHandles(
                activeTool: .freeTransform,
                isApplyingTransformCommit: false,
                isTransformingSelection: true,
                isFreeTransformDragging: true,
                activeInteractionMode: .move
            ) == false
        )

        #expect(
            shouldShowFreeTransformHandles(
                activeTool: .freeTransform,
                isApplyingTransformCommit: false,
                isTransformingSelection: true,
                isFreeTransformDragging: true,
                activeInteractionMode: .scale(.right)
            ) == true
        )

        #expect(
            shouldShowFreeTransformHandles(
                activeTool: .freeTransform,
                isApplyingTransformCommit: false,
                isTransformingSelection: true,
                isFreeTransformDragging: false,
                activeInteractionMode: nil
            ) == true
        )
    }

    @Test
    func wholeLayerInteractionBoundsEnableScaleAndRotateHitTesting() {
        let bounds = CanvasRect(
            origin: .init(x: 50, y: 60),
            size: .init(x: 120, y: 80)
        )
        let preview = FreeTransformPreview.identity
        let handleRadius = 12.0
        let handleMap = freeTransformHandlePoints(
            bounds: bounds,
            preview: preview,
            rotationHandleDistance: handleRadius * 3.4
        )

        let scaleMode = freeTransformInteractionMode(
            point: handleMap[.topRight]!,
            bounds: bounds,
            preview: preview,
            handleRadius: handleRadius,
            rotationHandleDistance: handleRadius * 3.4
        )
        #expect(scaleMode == .scale(.topRight))

        let rotateMode = freeTransformInteractionMode(
            point: handleMap[.rotation]!,
            bounds: bounds,
            preview: preview,
            handleRadius: handleRadius,
            rotationHandleDistance: handleRadius * 3.4
        )
        #expect(rotateMode == .rotate)
    }

    @Test
    func rotationHandleDisplayAndHitTestingStayAlignedWhenCanvasIsFitToView() {
        let metrics = freeTransformHandleMetrics(
            canvasExtent: 2_000,
            displayExtent: 500
        )
        #expect(metrics.hitRadius == 56)
        #expect(metrics.rotationHandleDistance == 192)

        let bounds = CanvasRect(
            origin: .init(x: 500, y: 600),
            size: .init(x: 800, y: 400)
        )
        let handleMap = freeTransformHandlePoints(
            bounds: bounds,
            preview: .identity,
            rotationHandleDistance: metrics.rotationHandleDistance
        )
        let rotationPoint = handleMap[.rotation]!

        let mode = freeTransformInteractionMode(
            point: rotationPoint,
            bounds: bounds,
            preview: .identity,
            handleRadius: metrics.hitRadius,
            rotationHandleDistance: metrics.rotationHandleDistance
        )

        #expect(mode == .rotate)
    }

    @Test
    func meshWarpGridCreatesFourByFourAnchorsAndDetectsMovedState() {
        let bounds = CanvasRect(
            origin: .init(x: 10, y: 20),
            size: .init(x: 120, y: 90)
        )
        let grid = MeshWarpGrid.regular(bounds: bounds)

        #expect(grid.columns == 4)
        #expect(grid.rows == 4)
        #expect(grid.controlPoints.count == 16)
        #expect(grid.point(row: 0, column: 0) == .init(x: 10, y: 20))
        #expect(grid.point(row: 3, column: 3) == .init(x: 130, y: 110))
        #expect(grid.isIdentity)

        let moved = grid.movingControlPoint(
            at: 5,
            by: .init(x: 14, y: -9)
        )
        #expect(moved.point(row: 1, column: 1) == .init(x: 64, y: 41))
        #expect(!moved.isIdentity)
    }

    @Test
    func meshWarpSelectionTogglesAndMovesEverySelectedAnchor() {
        let grid = MeshWarpGrid.regular(
            bounds: CanvasRect(
                origin: .init(x: 10, y: 20),
                size: .init(x: 90, y: 90)
            )
        )
        var selection = updatedMeshWarpControlPointSelection(
            current: [],
            clickedIndex: 0,
            togglesSelection: false
        )
        selection = updatedMeshWarpControlPointSelection(
            current: selection,
            clickedIndex: 5,
            togglesSelection: true
        )
        #expect(selection == Set([0, 5]))

        let moved = grid.movingControlPoints(
            at: selection,
            by: .init(x: 7, y: -4)
        )
        #expect(moved.controlPoints[0] == .init(x: 17, y: 16))
        #expect(moved.controlPoints[5] == .init(x: 47, y: 46))
        #expect(moved.controlPoints[1] == grid.controlPoints[1])

        selection = updatedMeshWarpControlPointSelection(
            current: selection,
            clickedIndex: 5,
            togglesSelection: true
        )
        #expect(selection == Set([0]))
        #expect(
            updatedMeshWarpControlPointSelection(
                current: Set([0, 5]),
                clickedIndex: 0,
                togglesSelection: false
            ) == Set([0, 5])
        )
    }

    @Test
    func meshWarpHitTestingPrioritizesAnchorsAndStateRequiresApply() {
        let grid = MeshWarpGrid.regular(
            bounds: CanvasRect(
                origin: .init(x: 20, y: 30),
                size: .init(x: 90, y: 90)
            )
        )
        let anchor = grid.controlPoints[6]
        #expect(
            meshWarpInteractionMode(
                point: .init(x: anchor.x + 2, y: anchor.y - 1),
                grid: grid,
                handleRadius: 8
            ) == .meshPoint(6)
        )

        var state = TransformInteractionState()
        state.isActive = true
        state.meshWarpGrid = grid.movingControlPoint(
            at: 6,
            by: .init(x: 8, y: 3)
        )
        #expect(state.hasPendingTransform)
        #expect(state.clearBehavior() == .apply)
    }

    @Test
    func meshWarpTessellationKeepsTextureCornersAndMovedAnchor() {
        var grid = MeshWarpGrid.regular(
            bounds: CanvasRect(
                origin: .init(x: 100, y: 200),
                size: .init(x: 300, y: 150)
            )
        )
        grid = grid.movingControlPoint(
            at: 0,
            by: .init(x: -25, y: 12)
        )
        let vertices = grid.tessellatedVertices(subdivisionsPerCell: 2)

        #expect(vertices.count == 216)
        #expect(vertices.contains {
            $0.canvasPosition == .init(x: 75, y: 212) &&
            $0.textureCoordinate == .init(x: 0, y: 0)
        })
        #expect(vertices.contains { $0.textureCoordinate == .init(x: 1, y: 1) })
    }

    @Test
    func missingInteractionBoundsFallsBackToMoveWithoutHandles() {
        let mode = freeTransformInteractionMode(
            point: .init(x: 10, y: 10),
            bounds: nil,
            preview: .identity,
            handleRadius: 12,
            rotationHandleDistance: 40
        )

        #expect(mode == .move)
    }
}

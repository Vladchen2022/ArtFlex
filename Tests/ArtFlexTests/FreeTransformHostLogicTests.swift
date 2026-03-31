import Testing
@testable import ArtFlex

struct FreeTransformHostLogicTests {
    @Test
    func wholeLayerTransformCanStartWithoutPreparedSession() {
        let signature = TransformPreviewPreparedSignature(
            activeLayerSurfaceID: LayerSurfaceID(),
            mode: .wholeLayer,
            canvasContentRevision: 1,
            selectionRevision: 1,
            operationBounds: CanvasRect(
                origin: .init(x: 0, y: 0),
                size: .init(x: 100, y: 100)
            )
        )

        #expect(
            freeTransformCanStartImmediately(
                signature: signature,
                hasPreparedSession: false
            )
        )
    }

    @Test
    func selectionTransformRequiresPreparedSessionToStart() {
        let signature = TransformPreviewPreparedSignature(
            activeLayerSurfaceID: LayerSurfaceID(),
            mode: .selection,
            canvasContentRevision: 1,
            selectionRevision: 1,
            operationBounds: CanvasRect(
                origin: .init(x: 10, y: 10),
                size: .init(x: 30, y: 40)
            )
        )

        #expect(
            freeTransformCanStartImmediately(
                signature: signature,
                hasPreparedSession: false
            ) == false
        )
    }

    @Test
    func activeMoveDragSkipsSessionRebuild() {
        #expect(
            freeTransformShouldSkipSessionRebuild(
                isTransformingSelection: true,
                isFreeTransformDragging: true,
                activeInteractionMode: .move
            )
        )

        #expect(
            freeTransformShouldSkipSessionRebuild(
                isTransformingSelection: true,
                isFreeTransformDragging: true,
                activeInteractionMode: .scale(.right)
            ) == false
        )
    }

    @Test
    func wholeLayerPreviewHidesOriginalActiveLayer() {
        #expect(
            freeTransformActiveLayerPreviewStrategy(
                hasActivePreview: true,
                sessionMode: nil,
                hasBaseTexture: false,
                plannedMode: .wholeLayer
            ) == .hideOriginalLayer
        )
    }

    @Test
    func selectionPreviewUsesBaseTextureWhenAvailable() {
        #expect(
            freeTransformActiveLayerPreviewStrategy(
                hasActivePreview: true,
                sessionMode: .selection,
                hasBaseTexture: true,
                plannedMode: .selection
            ) == .showBaseTexture
        )
    }
}

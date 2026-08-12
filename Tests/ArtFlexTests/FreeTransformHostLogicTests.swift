import Testing
@testable import ArtFlex

struct FreeTransformHostLogicTests {
    @Test
    func compositePlanKeepsLayerIDsPairedWhenActiveTransformLayerIsOmitted() throws {
        let metalContext = try #require(MetalDeviceContext())
        let store = StageOneLayerSurfaceStore()
        let lower = LayerRecord(
            id: LayerID(), name: "Lower", isVisible: true, isLocked: false,
            locksTransparentPixels: false, opacity: 1
        )
        let active = LayerRecord(
            id: LayerID(), name: "Active", isVisible: true, isLocked: false,
            locksTransparentPixels: false, opacity: 1
        )
        let upper = LayerRecord(
            id: LayerID(), name: "Upper", isVisible: true, isLocked: false,
            locksTransparentPixels: false, opacity: 1
        )
        let document = ArtDocument(
            metadata: .init(name: "Transform Preview", createdAt: .now, updatedAt: .now),
            canvasSize: .init(width: 8, height: 8),
            layers: [lower, active, upper],
            activeLayerID: active.id
        )
        let lowerTexture = try #require(store.makeTexture(width: 8, height: 8, metal: metalContext))
        let upperTexture = try #require(store.makeTexture(width: 8, height: 8, metal: metalContext))
        let textures = [lower.id: lowerTexture, upper.id: upperTexture]

        let entries = try CanvasCompositeInputPlan.make(
            document: document,
            allowsMissingTextures: true,
            textureForLayer: { textures[$0] },
            enabledMaskTextureForLayer: { _ in nil }
        ).entries

        #expect(entries.map { $0.layerID } == [lower.id, upper.id])
        #expect(entries[0].input.texture === lowerTexture)
        #expect(entries[1].input.texture === upperTexture)
    }

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

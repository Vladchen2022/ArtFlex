import Foundation
import Testing
@testable import ArtFlex

struct AdjustmentLayerTests {
    @Test
    func curveAdjustmentLayerIsInsertedAboveActiveLayerAndSurvivesCodableRoundTrip() throws {
        let paintLayer = LayerRecord(
            id: LayerID(),
            name: "Paint",
            isVisible: true,
            isLocked: false,
            locksTransparentPixels: false,
            opacity: 1
        )
        var document = ArtDocument(
            metadata: DocumentMetadata(name: "Adjustment Test", createdAt: Date(), updatedAt: Date()),
            canvasSize: CanvasSize(width: 32, height: 32),
            layers: [paintLayer],
            activeLayerID: paintLayer.id
        )

        let adjustment = document.addCurveAdjustmentLayer()
        #expect(document.layers.map(\.id) == [paintLayer.id, adjustment.id])
        #expect(document.activeLayerID == adjustment.id)
        #expect(adjustment.isAdjustmentLayer)
        #expect(adjustment.adjustment == .curves(.neutral))

        let encoded = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(ArtDocument.self, from: encoded)
        #expect(decoded == document)
        #expect(decoded.layer(adjustment.id)?.isAdjustmentLayer == true)
    }

    @Test
    func adjustmentLayerCannotBeUsedAsPaintTarget() {
        let paintLayer = LayerRecord(
            id: LayerID(),
            name: "Paint",
            isVisible: true,
            isLocked: false,
            locksTransparentPixels: false,
            opacity: 1
        )
        var document = ArtDocument(
            metadata: DocumentMetadata(name: "Adjustment Test", createdAt: Date(), updatedAt: Date()),
            canvasSize: CanvasSize(width: 32, height: 32),
            layers: [paintLayer],
            activeLayerID: paintLayer.id
        )
        let adjustment = document.addCurveAdjustmentLayer()
        var workspace = WorkspaceState.stageOneDefault
        workspace.document = document
        let store = WorkspaceStore(state: workspace)
        let controller = CanvasInteractionController(workspaceStore: store)

        #expect(controller.activeEditableLayerID() == nil)
        #expect(controller.makeStrokeDescriptor(samples: [
            CanvasStrokeSample(location: CanvasPoint(x: 4, y: 4))
        ]) == nil)
        #expect(store.state.document.activeLayerID == adjustment.id)
    }
}

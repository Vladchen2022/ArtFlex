import Foundation
import Testing
@testable import ArtFlex

struct TransformPreviewSessionTests {
    @Test
    func noSelectionUsesWholeLayerPlan() {
        let canvasSize = CanvasSize(width: 640, height: 480)

        let plan = TransformPreviewSessionBuilder.plan(
            canvasSize: canvasSize,
            selectionShape: nil
        )

        #expect(plan != nil)
        #expect(plan?.mode == .wholeLayer)
        #expect(plan?.needsMaskTexture == false)
        #expect(
            plan?.sourceBounds == CanvasRect(
                origin: .init(x: 0, y: 0),
                size: .init(x: 640, y: 480)
            )
        )
    }

    @Test
    func fullCanvasRectangleSelectionAlsoUsesWholeLayerPlan() {
        let canvasSize = CanvasSize(width: 320, height: 200)
        let selection = SelectionShape(
            kind: .rectangle,
            bounds: CanvasRect(
                origin: .init(x: 0, y: 0),
                size: .init(x: 320, y: 200)
            ),
            pathPoints: []
        )

        let plan = TransformPreviewSessionBuilder.plan(
            canvasSize: canvasSize,
            selectionShape: selection
        )

        #expect(plan != nil)
        #expect(plan?.mode == .wholeLayer)
        #expect(plan?.needsMaskTexture == false)
        #expect(plan?.sourceBounds == selection.bounds)
    }

    @Test
    func nonRectSelectionUsesLocalSelectionPlan() {
        let canvasSize = CanvasSize(width: 256, height: 256)
        let selection = SelectionShape(
            kind: .lasso,
            bounds: CanvasRect(
                origin: .init(x: 20, y: 40),
                size: .init(x: 80, y: 90)
            ),
            pathPoints: [
                .init(x: 20, y: 40),
                .init(x: 100, y: 45),
                .init(x: 92, y: 130),
                .init(x: 24, y: 120)
            ]
        )

        let plan = TransformPreviewSessionBuilder.plan(
            canvasSize: canvasSize,
            selectionShape: selection
        )

        #expect(plan != nil)
        #expect(plan?.mode == .selection)
        #expect(plan?.needsMaskTexture == true)
        #expect(
            plan?.sourceBounds == CanvasRect(
                origin: .init(x: 20, y: 40),
                size: .init(x: 80, y: 90)
            )
        )
    }

    @Test
    func localMaskBytesCropOnlyRequestedBounds() {
        let canvasWidth = 4
        let canvasHeight = 4
        let fullMaskBytes: [UInt8] = [
            0,  1,  2,  3,
            4,  5,  6,  7,
            8,  9, 10, 11,
            12, 13, 14, 15
        ]

        let selection = SelectionShape.mask(
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight,
            alphaBytes: fullMaskBytes
        )

        let localBytes = TransformPreviewSessionBuilder.localMaskBytes(
            for: selection,
            sourceBounds: CanvasRect(
                origin: .init(x: 1, y: 1),
                size: .init(x: 2, y: 2)
            )
        )

        #expect(localBytes == [5, 6, 9, 10])
    }
}

import Foundation
import Testing
@testable import ArtFlex

struct SelectionRefinementAndPreciseAffineTests {
    @Test
    func refinementRequestNormalizesRadiusByOperation() throws {
        #expect(SelectionRefinementRequest(kind: .invert, radiusPixels: 12).radiusPixels == 0)
        #expect(SelectionRefinementRequest(kind: .feather, radiusPixels: -4).radiusPixels == 0)
        #expect(SelectionRefinementRequest(kind: .expand, radiusPixels: 8_000).radiusPixels == 4_096)

        let decoded = try JSONDecoder().decode(
            SelectionRefinementRequest.self,
            from: Data(#"{"kind":"contract","radiusPixels":17}"#.utf8)
        )
        #expect(decoded == SelectionRefinementRequest(kind: .contract, radiusPixels: 17))
    }

    @Test
    func invertSimpleSelectionUsesCanvasComplement() throws {
        let canvasSize = CanvasSize(width: 4, height: 4)
        let rectangle = SelectionShape(
            kind: .rectangle,
            bounds: .init(origin: .init(x: 1, y: 1), size: .init(x: 2, y: 2)),
            pathPoints: []
        )
        let inverted = try #require(SelectionRefinement.inverted(rectangle, canvasSize: canvasSize))

        #expect(inverted.contains(.init(x: 0.5, y: 0.5)))
        #expect(inverted.contains(.init(x: 1.5, y: 1.5)) == false)
        #expect(inverted.contains(.init(x: 3.5, y: 3.5)))
    }

    @Test
    func invertMaskComplementsFeatheredAlphaExactly() throws {
        let selection = SelectionShape.mask(
            canvasWidth: 3,
            canvasHeight: 1,
            alphaBytes: [0, 64, 255]
        )
        let inverted = try #require(
            SelectionRefinement.inverted(selection, canvasSize: .init(width: 3, height: 1))
        )
        let mask = try #require(inverted.maskData)

        #expect([UInt8](mask.alphaBytes) == [255, 191, 0])
    }

    @Test
    func invertCompositeRestoresSubtractedHole() throws {
        let outer = SelectionShape(
            kind: .rectangle,
            bounds: .init(origin: .init(x: 1, y: 1), size: .init(x: 4, y: 4)),
            pathPoints: []
        )
        let hole = SelectionShape(
            kind: .rectangle,
            bounds: .init(origin: .init(x: 2, y: 2), size: .init(x: 2, y: 2)),
            pathPoints: []
        )
        let composite = SelectionShape.composite([
            .init(operation: .add, shape: outer),
            .init(operation: .subtract, shape: hole)
        ])
        let inverted = try #require(
            SelectionRefinement.inverted(composite, canvasSize: .init(width: 6, height: 6))
        )

        #expect(inverted.contains(.init(x: 0.5, y: 0.5)))
        #expect(inverted.contains(.init(x: 1.5, y: 1.5)) == false)
        #expect(inverted.contains(.init(x: 2.5, y: 2.5)))
    }

    @Test
    func contractingPastSelectionExtentProducesEmptyResult() {
        let rectangle = SelectionShape(
            kind: .rectangle,
            bounds: .init(origin: .init(x: 1, y: 1), size: .init(x: 2, y: 2)),
            pathPoints: []
        )

        #expect(
            SelectionRefinement.contracted(
                rectangle,
                canvasSize: .init(width: 4, height: 4),
                radiusPixels: 3
            ) == nil
        )
    }

    @Test
    func preciseAffineRoundTripsPreviewWithIndependentPivot() throws {
        let bounds = CanvasRect(
            origin: .init(x: 20, y: 30),
            size: .init(x: 80, y: 40)
        )
        let pivotBounds = CanvasRect(
            origin: .init(x: 0, y: 0),
            size: .init(x: 200, y: 200)
        )
        let preview = FreeTransformPreview(
            translation: .init(x: 13.5, y: -9.25),
            scaleX: -1.5,
            scaleY: 0.75,
            rotationRadians: .pi / 5
        )

        let input = PreciseAffineInput(
            bounds: bounds,
            preview: preview,
            pivotBounds: pivotBounds
        )
        let resolved = try #require(input.resolvedPreview(bounds: bounds, pivotBounds: pivotBounds))

        #expect(abs(resolved.translation.x - preview.translation.x) < 0.000_001)
        #expect(abs(resolved.translation.y - preview.translation.y) < 0.000_001)
        #expect(abs(resolved.scaleX - preview.scaleX) < 0.000_001)
        #expect(abs(resolved.scaleY - preview.scaleY) < 0.000_001)
        #expect(abs(resolved.rotationRadians - preview.rotationRadians) < 0.000_001)
    }

    @Test
    func preciseAffineAspectLockAndFlipsAreExplicit() throws {
        var input = PreciseAffineInput(
            centerX: 50,
            centerY: 40,
            width: 100,
            height: 50,
            rotationDegrees: 30
        )
        input.updateWidth(160, sourceAspectRatio: 2)
        input.flipHorizontally()
        input.flipVertically()

        #expect(input.height == 80)
        let preview = try #require(
            input.resolvedPreview(
                bounds: .init(origin: .init(x: 0, y: 0), size: .init(x: 100, y: 50))
            )
        )
        #expect(preview.scaleX == -1.6)
        #expect(preview.scaleY == -1.6)
        #expect(abs(preview.rotationRadians - (.pi / 6)) < 0.000_001)
    }
}

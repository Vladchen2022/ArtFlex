import Foundation
import Testing
@testable import ArtFlex

struct SelectionShapeTests {
    @Test
    func maskContainsMatchesStoredAlphaBytes() {
        let selection = SelectionShape.mask(
            canvasWidth: 4,
            canvasHeight: 3,
            alphaBytes: [
                0, 255, 0, 0,
                0,   0, 0, 0,
                0,   0, 0, 7
            ]
        )

        #expect(selection.contains(CanvasPoint(x: 1.2, y: 0.1)))
        #expect(selection.contains(CanvasPoint(x: 3.8, y: 2.2)))
        #expect(selection.contains(CanvasPoint(x: 0.2, y: 0.2)) == false)
        #expect(selection.contains(CanvasPoint(x: 4.0, y: 1.0)) == false)
    }

    @Test
    func flattenedComponentsPreserveNestedCompositeOperationOrder() {
        let nested = SelectionShape.composite([
            SelectionShapeComponent(
                operation: .add,
                shape: SelectionShape(
                    kind: .rectangle,
                    bounds: CanvasRect(
                        origin: .init(x: 2, y: 2),
                        size: .init(x: 6, y: 6)
                    ),
                    pathPoints: []
                )
            ),
            SelectionShapeComponent(
                operation: .subtract,
                shape: SelectionShape(
                    kind: .rectangle,
                    bounds: CanvasRect(
                        origin: .init(x: 4, y: 4),
                        size: .init(x: 2, y: 2)
                    ),
                    pathPoints: []
                )
            )
        ])

        let selection = SelectionShape.composite([
            SelectionShapeComponent(
                operation: .add,
                shape: SelectionShape(
                    kind: .rectangle,
                    bounds: CanvasRect(
                        origin: .init(x: 0, y: 0),
                        size: .init(x: 10, y: 10)
                    ),
                    pathPoints: []
                )
            ),
            SelectionShapeComponent(operation: .subtract, shape: nested),
            SelectionShapeComponent(
                operation: .add,
                shape: SelectionShape(
                    kind: .rectangle,
                    bounds: CanvasRect(
                        origin: .init(x: 4, y: 4),
                        size: .init(x: 2, y: 2)
                    ),
                    pathPoints: []
                )
            )
        ])

        let flattened = selection.flattenedComponents()
        #expect(flattened.map(\.operation) == [.add, .subtract, .subtract, .add])

        #expect(selection.contains(CanvasPoint(x: 1, y: 1)))
        #expect(selection.contains(CanvasPoint(x: 3, y: 3)) == false)
        #expect(selection.contains(CanvasPoint(x: 4.5, y: 4.5)))
    }
}

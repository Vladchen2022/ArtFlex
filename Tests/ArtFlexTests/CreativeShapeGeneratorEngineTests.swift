import Foundation
import Testing
@testable import ArtFlex

struct CreativeShapeGeneratorEngineTests {
    @Test
    func planIsDeterministicWhenShapeJitterIsZero() {
        let selection = SelectionShape(
            kind: .lasso,
            bounds: CanvasRect(
                origin: CanvasPoint(x: 20, y: 20),
                size: CanvasPoint(x: 120, y: 100)
            ),
            pathPoints: [
                CanvasPoint(x: 20, y: 20),
                CanvasPoint(x: 140, y: 24),
                CanvasPoint(x: 132, y: 118),
                CanvasPoint(x: 28, y: 120)
            ]
        )
        let state = CreativeShapeGeneratorState(
            selectedSource: .currentColor,
            shapeCharacteristic: 0.65,
            shapeSize: 0.54,
            shapeJitter: 0,
            colorJitter: 0.31,
            importedImage: nil
        )
        let colorContext = CreativeShapeGeneratorColorContext(
            selectedColor: RGBAColor(red: 0.8, green: 0.2, blue: 0.15, alpha: 1),
            brushOpacity: 0.72,
            brushNoise: 0.38,
            paletteColors: ColorBlocksEngine.renderPalette(for: .stageOneDefault)
        )

        let planA = CreativeShapeGeneratorEngine.makePlan(
            selectionShape: selection,
            state: state,
            colorContext: colorContext,
            runtimeSeed: 17
        )
        let planB = CreativeShapeGeneratorEngine.makePlan(
            selectionShape: selection,
            state: state,
            colorContext: colorContext,
            runtimeSeed: 999_999
        )

        #expect(planA == planB)
        #expect(planA?.shapes.isEmpty == false)
    }
}

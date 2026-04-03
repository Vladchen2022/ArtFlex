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

    @Test
    func shapeCharacteristicControlsTipMaterialPoolSize() {
        let selection = SelectionShape(
            kind: .lasso,
            bounds: CanvasRect(
                origin: CanvasPoint(x: 10, y: 10),
                size: CanvasPoint(x: 180, y: 140)
            ),
            pathPoints: [
                CanvasPoint(x: 12, y: 18),
                CanvasPoint(x: 184, y: 14),
                CanvasPoint(x: 176, y: 148),
                CanvasPoint(x: 18, y: 144)
            ]
        )
        let colorContext = CreativeShapeGeneratorColorContext(
            selectedColor: RGBAColor(red: 0.3, green: 0.7, blue: 0.2, alpha: 1),
            brushOpacity: 0.9,
            brushNoise: 0.12,
            paletteColors: ColorBlocksEngine.renderPalette(for: .stageOneDefault)
        )
        let tipLibrary = TipImageLibraryState(
            items: Array(0..<12).map { (index: Int) in
                let side = 16
                var bytes = [UInt8](repeating: 0, count: side * side)
                for pixelIndex in 0..<bytes.count {
                    bytes[pixelIndex] = UInt8((pixelIndex + (index * 17)) % 255)
                }
                let data = Data(bytes)
                return TipImageLibraryItem(
                    id: BrushTipImageAssetID(maskData: data),
                    sourceInfo: ImportedTipSourceInfo(
                        sourceLabel: "tip-\(index)",
                        pixelWidth: side,
                        pixelHeight: side
                    ),
                    maskData: data
                )
            }
        )

        let leftState = CreativeShapeGeneratorState(
            selectedSource: .currentColor,
            usesTipImageShapes: true,
            shapeCharacteristic: 0,
            shapeSize: 0.6,
            shapeJitter: 0,
            colorJitter: 0.2,
            importedImage: nil
        )
        let rightState = CreativeShapeGeneratorState(
            selectedSource: .currentColor,
            usesTipImageShapes: true,
            shapeCharacteristic: 1,
            shapeSize: 0.6,
            shapeJitter: 0,
            colorJitter: 0.2,
            importedImage: nil
        )

        let leftPlan = CreativeShapeGeneratorEngine.makePlan(
            selectionShape: selection,
            state: leftState,
            colorContext: colorContext,
            tipImageLibrary: tipLibrary,
            runtimeSeed: 42
        )
        let rightPlan = CreativeShapeGeneratorEngine.makePlan(
            selectionShape: selection,
            state: rightState,
            colorContext: colorContext,
            tipImageLibrary: tipLibrary,
            runtimeSeed: 42
        )

        #expect(leftPlan?.tipMaterials.count == 1)
        #expect(rightPlan?.tipMaterials.count == 10)
        #expect(leftPlan?.shapes.allSatisfy {
            if case .tipStamp = $0.geometry { return true }
            return false
        } == true)
        #expect(rightPlan?.shapes.allSatisfy {
            if case .tipStamp = $0.geometry { return true }
            return false
        } == true)
    }

    @Test
    func planStillGeneratesForThinIrregularLassoAcrossMultipleSeeds() {
        let selection = SelectionShape(
            kind: .lasso,
            bounds: CanvasRect(
                origin: CanvasPoint(x: 20, y: 20),
                size: CanvasPoint(x: 180, y: 120)
            ),
            pathPoints: [
                CanvasPoint(x: 24, y: 28),
                CanvasPoint(x: 172, y: 34),
                CanvasPoint(x: 194, y: 46),
                CanvasPoint(x: 76, y: 122),
                CanvasPoint(x: 52, y: 134),
                CanvasPoint(x: 22, y: 54)
            ]
        )
        let state = CreativeShapeGeneratorState(
            selectedSource: .currentColor,
            shapeCharacteristic: 0.6,
            shapeSize: 0.72,
            shapeJitter: 0.9,
            colorJitter: 0.28,
            importedImage: nil
        )
        let colorContext = CreativeShapeGeneratorColorContext(
            selectedColor: RGBAColor(red: 0.75, green: 0.32, blue: 0.18, alpha: 1),
            brushOpacity: 0.88,
            brushNoise: 0.14,
            paletteColors: ColorBlocksEngine.renderPalette(for: .stageOneDefault)
        )

        for seed in 1...64 {
            let plan = CreativeShapeGeneratorEngine.makePlan(
                selectionShape: selection,
                state: state,
                colorContext: colorContext,
                runtimeSeed: UInt64(seed)
            )
            #expect(plan?.shapes.isEmpty == false)
        }
    }
}

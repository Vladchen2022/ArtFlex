import Foundation
import Testing
@testable import ArtFlex

struct CreativeShapeGeneratorEngineTests {
    @Test
    func sameSeedProducesSamePlanAndRerollProducesAnotherCandidate() throws {
        let selection = makeSelection()
        let state = makeState(mode: .growth)
        let context = makeColorContext()

        let first = try #require(
            CreativeShapeGeneratorEngine.makePlan(
                selectionShape: selection,
                state: state,
                colorContext: context,
                runtimeSeed: 17
            )
        )
        let repeated = try #require(
            CreativeShapeGeneratorEngine.makePlan(
                selectionShape: selection,
                state: state,
                colorContext: context,
                runtimeSeed: 17
            )
        )
        let rerolled = try #require(
            CreativeShapeGeneratorEngine.makePlan(
                selectionShape: selection,
                state: state,
                colorContext: context,
                runtimeSeed: 18
            )
        )

        #expect(first == repeated)
        #expect(first != rerolled)
        #expect(first.shapes.count >= 5)
    }

    @Test
    func everyGeneratedPolygonStaysInsideTheRequestedLasso() throws {
        let selection = makeSelection()
        for mode in CreativeShapeStructureMode.allCases {
            for seed in 1...12 {
                let plan = try #require(
                    CreativeShapeGeneratorEngine.makePlan(
                        selectionShape: selection,
                        state: makeState(mode: mode),
                        colorContext: makeColorContext(),
                        runtimeSeed: UInt64(seed)
                    )
                )
                #expect(plan.bounds == selection.bounds)
                #expect(plan.shapes.allSatisfy { shape in
                    guard case .polygon(let points) = shape.geometry else { return false }
                    return points.isEmpty == false && points.allSatisfy(selection.contains(_:))
                })
            }
        }
    }

    @Test
    func structureModesProduceMateriallyDifferentCompositions() throws {
        let selection = makeSelection()
        let context = makeColorContext()
        let plans = try CreativeShapeStructureMode.allCases.map { mode in
            try #require(
                CreativeShapeGeneratorEngine.makePlan(
                    selectionShape: selection,
                    state: makeState(mode: mode),
                    colorContext: context,
                    runtimeSeed: 42
                )
            )
        }

        for leftIndex in plans.indices {
            for rightIndex in plans.indices where rightIndex > leftIndex {
                #expect(plans[leftIndex].shapes != plans[rightIndex].shapes)
            }
        }
        #expect(plans.allSatisfy { $0.tipMaterials.isEmpty })
    }

    @Test
    func complexityChangesDetailCountWithoutRemovingDominantMass() throws {
        let selection = makeSelection()
        var sparseState = makeState(mode: .cluster)
        sparseState.complexity = 0
        var denseState = sparseState
        denseState.complexity = 1

        let sparse = try #require(
            CreativeShapeGeneratorEngine.makePlan(
                selectionShape: selection,
                state: sparseState,
                colorContext: makeColorContext(),
                runtimeSeed: 9
            )
        )
        let dense = try #require(
            CreativeShapeGeneratorEngine.makePlan(
                selectionShape: selection,
                state: denseState,
                colorContext: makeColorContext(),
                runtimeSeed: 9
            )
        )

        #expect(sparse.shapes.count == 5)
        #expect(dense.shapes.count == 18)
        #expect(largestPolygonArea(in: sparse) > 0)
        #expect(largestPolygonArea(in: dense) > 0)
    }

    @Test
    func legacyGeneratorSettingsDecodeIntoNewCompositionControls() throws {
        let payload = Data(
            """
            {
              "selectedSource": "currentColor",
              "shapeCharacteristic": 0.6,
              "shapeSize": 0.3,
              "shapeJitter": 0.2,
              "featherProbability": 0.4
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(CreativeShapeGeneratorState.self, from: payload)

        #expect(decoded.selectedSource == .currentColor)
        #expect(decoded.structureMode == .growth)
        #expect(decoded.complexity == 0.3)
        #expect(decoded.coherence == 0.8)
        #expect(decoded.formElongation == CreativeShapeGeneratorState.stageOneDefault.formElongation)
        #expect(decoded.edgeTexture == 0.5)
    }

    @Test
    func formElongationAndEdgeVariationChangeTheGeneratedSilhouette() throws {
        let selection = makeSelection()
        var compact = makeState(mode: .flow)
        compact.formElongation = 0
        compact.edgeTexture = 0
        var organic = compact
        organic.formElongation = 1
        organic.edgeTexture = 1

        let compactPlan = try #require(
            CreativeShapeGeneratorEngine.makePlan(
                selectionShape: selection,
                state: compact,
                colorContext: makeColorContext(),
                runtimeSeed: 71
            )
        )
        let organicPlan = try #require(
            CreativeShapeGeneratorEngine.makePlan(
                selectionShape: selection,
                state: organic,
                colorContext: makeColorContext(),
                runtimeSeed: 71
            )
        )

        #expect(compactPlan.shapes != organicPlan.shapes)
        #expect(maximumPolygonAspect(in: organicPlan) > maximumPolygonAspect(in: compactPlan))
        #expect(maximumConcaveVertexCount(in: organicPlan) > 0)
    }

    private func makeSelection() -> SelectionShape {
        SelectionShape(
            kind: .lasso,
            bounds: CanvasRect(
                origin: CanvasPoint(x: 20, y: 20),
                size: CanvasPoint(x: 180, y: 130)
            ),
            pathPoints: [
                CanvasPoint(x: 24, y: 34),
                CanvasPoint(x: 92, y: 20),
                CanvasPoint(x: 188, y: 38),
                CanvasPoint(x: 200, y: 92),
                CanvasPoint(x: 164, y: 142),
                CanvasPoint(x: 78, y: 150),
                CanvasPoint(x: 22, y: 104)
            ]
        )
    }

    private func makeState(mode: CreativeShapeStructureMode) -> CreativeShapeGeneratorState {
        CreativeShapeGeneratorState(
            selectedSource: .currentColor,
            structureMode: mode,
            complexity: 0.56,
            coherence: 0.74,
            formElongation: 0.58,
            edgeTexture: 0.48,
            importedImage: nil
        )
    }

    private func makeColorContext() -> CreativeShapeGeneratorColorContext {
        CreativeShapeGeneratorColorContext(
            selectedColor: RGBAColor(red: 0.75, green: 0.32, blue: 0.18, alpha: 1),
            brushOpacity: 0.88,
            brushNoise: 0.14,
            paletteColors: ColorBlocksEngine.renderPalette(for: .stageOneDefault)
        )
    }

    private func largestPolygonArea(in plan: CreativeShapeGeneratorPlan) -> Double {
        plan.shapes.compactMap { shape -> Double? in
            guard case .polygon(let points) = shape.geometry else { return nil }
            var area = 0.0
            for index in points.indices {
                let current = points[index]
                let next = points[(index + 1) % points.count]
                area += (current.x * next.y) - (next.x * current.y)
            }
            return abs(area * 0.5)
        }.max() ?? 0
    }

    private func maximumPolygonAspect(in plan: CreativeShapeGeneratorPlan) -> Double {
        plan.shapes.compactMap { shape -> Double? in
            guard case .polygon(let points) = shape.geometry, points.isEmpty == false else { return nil }
            let minX = points.map(\.x).min() ?? 0
            let maxX = points.map(\.x).max() ?? 0
            let minY = points.map(\.y).min() ?? 0
            let maxY = points.map(\.y).max() ?? 0
            let width = max(maxX - minX, 0.000_1)
            let height = max(maxY - minY, 0.000_1)
            return max(width / height, height / width)
        }.max() ?? 0
    }

    private func maximumConcaveVertexCount(in plan: CreativeShapeGeneratorPlan) -> Int {
        plan.shapes.compactMap { shape -> Int? in
            guard case .polygon(let points) = shape.geometry, points.count >= 4 else { return nil }
            var signs: [Double] = []
            for index in points.indices {
                let previous = points[(index - 1 + points.count) % points.count]
                let current = points[index]
                let next = points[(index + 1) % points.count]
                signs.append(
                    ((current.x - previous.x) * (next.y - current.y)) -
                    ((current.y - previous.y) * (next.x - current.x))
                )
            }
            let positive = signs.filter { $0 > 0.000_1 }.count
            let negative = signs.filter { $0 < -0.000_1 }.count
            return min(positive, negative)
        }.max() ?? 0
    }
}

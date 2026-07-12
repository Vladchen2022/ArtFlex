import Foundation
import Testing
@testable import ArtFlex

struct CreativeShapeGeneratorEngineTests {
    @Test
    func sameGestureAndSeedProduceSameFieldWhileAnotherSeedChangesIt() throws {
        let state = makeState()
        let context = makeColorContext()
        let gesture = makeGesture()

        let first = try #require(CreativeShapeGeneratorEngine.makePlan(
            gesturePoints: gesture,
            state: state,
            colorContext: context,
            runtimeSeed: 17
        ))
        let repeated = try #require(CreativeShapeGeneratorEngine.makePlan(
            gesturePoints: gesture,
            state: state,
            colorContext: context,
            runtimeSeed: 17
        ))
        let changed = try #require(CreativeShapeGeneratorEngine.makePlan(
            gesturePoints: gesture,
            state: state,
            colorContext: context,
            runtimeSeed: 18
        ))

        #expect(first == repeated)
        #expect(first != changed)
        #expect(first.shapes.count == 1)
        #expect(first.tipMaterials.count == 1)
        #expect(first.tipMaterials[0].maskData.count == CreativeShapeGeneratorEngine.maskResolution * CreativeShapeGeneratorEngine.maskResolution)
    }

    @Test
    func openGestureGeneratesWithoutClosingASelectionBoundary() throws {
        let gesture = [
            CanvasPoint(x: 20, y: 50),
            CanvasPoint(x: 80, y: 38),
            CanvasPoint(x: 145, y: 74),
            CanvasPoint(x: 210, y: 46)
        ]
        let plan = try #require(CreativeShapeGeneratorEngine.makePlan(
            gesturePoints: gesture,
            state: makeState(),
            colorContext: makeColorContext(),
            runtimeSeed: 4
        ))

        #expect(plan.bounds.size.x > 190)
        #expect(plan.bounds.size.y > 20)
        #expect(visiblePixelCount(in: plan) > 600)
    }

    @Test
    func tendencyComplexityAndSurpriseChangeStructuralField() throws {
        var compact = makeState()
        compact.formTendency = 0
        compact.complexity = 0
        compact.surprise = 0
        var flowing = compact
        flowing.formTendency = 1
        flowing.complexity = 1
        flowing.surprise = 1

        let compactPlan = try #require(CreativeShapeGeneratorEngine.makePlan(
            gesturePoints: makeGesture(),
            state: compact,
            colorContext: makeColorContext(),
            runtimeSeed: 29
        ))
        let flowingPlan = try #require(CreativeShapeGeneratorEngine.makePlan(
            gesturePoints: makeGesture(),
            state: flowing,
            colorContext: makeColorContext(),
            runtimeSeed: 29
        ))

        #expect(compactPlan.tipMaterials[0].maskData != flowingPlan.tipMaterials[0].maskData)
        #expect(compactPlan.bounds != flowingPlan.bounds)
    }

    @Test
    func opennessCreatesEnclosedNegativeSpace() throws {
        var closed = makeState()
        closed.formTendency = 0.2
        closed.complexity = 0.8
        closed.openness = 0
        closed.edgeCharacter = 0.2
        closed.surprise = 0.4
        var open = closed
        open.openness = 1

        let closedPlan = try #require(CreativeShapeGeneratorEngine.makePlan(
            gesturePoints: makeGesture(),
            state: closed,
            colorContext: makeColorContext(),
            runtimeSeed: 91
        ))
        let openPlan = try #require(CreativeShapeGeneratorEngine.makePlan(
            gesturePoints: makeGesture(),
            state: open,
            colorContext: makeColorContext(),
            runtimeSeed: 91
        ))

        #expect(
            enclosedTransparentPixelCount(in: openPlan) >
            enclosedTransparentPixelCount(in: closedPlan) + 20
        )
    }

    @Test
    func edgeCharacterIncreasesBoundaryVariation() throws {
        var smooth = makeState()
        smooth.openness = 0
        smooth.edgeCharacter = 0
        smooth.surprise = 0
        var textured = smooth
        textured.edgeCharacter = 1

        let smoothPlan = try #require(CreativeShapeGeneratorEngine.makePlan(
            gesturePoints: makeGesture(),
            state: smooth,
            colorContext: makeColorContext(),
            runtimeSeed: 37
        ))
        let texturedPlan = try #require(CreativeShapeGeneratorEngine.makePlan(
            gesturePoints: makeGesture(),
            state: textured,
            colorContext: makeColorContext(),
            runtimeSeed: 37
        ))

        #expect(texturedPlan.tipMaterials[0].maskData != smoothPlan.tipMaterials[0].maskData)
        #expect(
            abs(boundaryTransitionCount(in: texturedPlan) - boundaryTransitionCount(in: smoothPlan)) > 10
        )
    }

    @Test
    func repeatedStraightGestureProducesDifferentTopologiesAcrossSeeds() throws {
        var state = makeState()
        state.formTendency = 0.55
        state.complexity = 0.68
        state.openness = 0.58
        state.edgeCharacter = 0.52
        state.surprise = 0.74
        let gesture = [CanvasPoint(x: 20, y: 64), CanvasPoint(x: 220, y: 64)]

        let plans = try (100...115).map { seed in
            try #require(CreativeShapeGeneratorEngine.makePlan(
                gesturePoints: gesture,
                state: state,
                colorContext: makeColorContext(),
                runtimeSeed: UInt64(seed)
            ))
        }
        let masks = Set(plans.map { $0.tipMaterials[0].maskData })
        let visibleCounts = plans.map(visiblePixelCount(in:))
        let holeCounts = plans.map(enclosedTransparentPixelCount(in:))
        let shapesWithHoles = holeCounts.filter { $0 > 20 }.count

        #expect(masks.count == plans.count)
        #expect((visibleCounts.max() ?? 0) - (visibleCounts.min() ?? 0) > 500)
        #expect(shapesWithHoles > 0)
        #expect(shapesWithHoles < plans.count)
        #expect(Set(holeCounts).count >= 4)
    }

    @Test
    func previousStructuredSettingsMigrateToGestureControls() throws {
        let payload = Data(
            """
            {
              "selectedSource": "currentColor",
              "structureMode": "fracture",
              "complexity": 0.73,
              "coherence": 0.64,
              "formElongation": 0.86,
              "edgeTexture": 0.52
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(CreativeShapeGeneratorState.self, from: payload)

        #expect(decoded.selectedSource == .currentColor)
        #expect(decoded.formTendency == 0.86)
        #expect(decoded.complexity == 0.73)
        #expect(decoded.openness == 0.68)
        #expect(abs(decoded.edgeCharacter - 0.52) < 0.0001)
        #expect(abs(decoded.surprise - 0.36) < 0.0001)
    }

    private func makeGesture() -> [CanvasPoint] {
        [
            CanvasPoint(x: 22, y: 82),
            CanvasPoint(x: 54, y: 42),
            CanvasPoint(x: 96, y: 56),
            CanvasPoint(x: 132, y: 108),
            CanvasPoint(x: 176, y: 116),
            CanvasPoint(x: 218, y: 72)
        ]
    }

    private func makeState() -> CreativeShapeGeneratorState {
        CreativeShapeGeneratorState(
            selectedSource: .currentColor,
            formTendency: 0.58,
            complexity: 0.56,
            openness: 0.34,
            edgeCharacter: 0.48,
            surprise: 0.32,
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

    private func visiblePixelCount(in plan: CreativeShapeGeneratorPlan) -> Int {
        plan.tipMaterials[0].maskData.filter { $0 >= 128 }.count
    }

    private func boundaryTransitionCount(in plan: CreativeShapeGeneratorPlan) -> Int {
        let bytes = [UInt8](plan.tipMaterials[0].maskData)
        let side = CreativeShapeGeneratorEngine.maskResolution
        var transitions = 0
        for y in 0..<side {
            for x in 1..<side {
                if (bytes[(y * side) + x] >= 128) != (bytes[(y * side) + x - 1] >= 128) {
                    transitions += 1
                }
            }
        }
        for x in 0..<side {
            for y in 1..<side {
                if (bytes[(y * side) + x] >= 128) != (bytes[((y - 1) * side) + x] >= 128) {
                    transitions += 1
                }
            }
        }
        return transitions
    }

    private func enclosedTransparentPixelCount(in plan: CreativeShapeGeneratorPlan) -> Int {
        let bytes = [UInt8](plan.tipMaterials[0].maskData)
        let side = CreativeShapeGeneratorEngine.maskResolution
        var exterior = [Bool](repeating: false, count: bytes.count)
        var queue: [Int] = []
        queue.reserveCapacity(bytes.count)

        func appendExterior(_ x: Int, _ y: Int) {
            let index = (y * side) + x
            guard bytes[index] < 32, exterior[index] == false else { return }
            exterior[index] = true
            queue.append(index)
        }
        for index in 0..<side {
            appendExterior(index, 0)
            appendExterior(index, side - 1)
            appendExterior(0, index)
            appendExterior(side - 1, index)
        }

        var cursor = 0
        while cursor < queue.count {
            let index = queue[cursor]
            cursor += 1
            let x = index % side
            let y = index / side
            if x > 0 { appendExterior(x - 1, y) }
            if x + 1 < side { appendExterior(x + 1, y) }
            if y > 0 { appendExterior(x, y - 1) }
            if y + 1 < side { appendExterior(x, y + 1) }
        }

        return bytes.indices.filter { bytes[$0] < 32 && exterior[$0] == false }.count
    }
}

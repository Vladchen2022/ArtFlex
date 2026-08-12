import Foundation
import Testing
@testable import ArtFlex

struct OilPaintBrushTests {
    @Test
    func sequentialLoadsRetainAndAccumulatePriorPigments() throws {
        let red = RGBAColor(red: 1, green: 0, blue: 0, alpha: 1)
        let yellow = RGBAColor(red: 1, green: 1, blue: 0, alpha: 1)
        let blue = RGBAColor(red: 0, green: 0, blue: 1, alpha: 1)
        var reservoir = OilPaintPigmentReservoirState(cleanColor: red)

        reservoir.load(yellow, amount: 0.35)
        reservoir.load(blue, amount: 0.35)

        #expect(abs(try weight(of: red, in: reservoir) - 0.4225) < 0.0001)
        #expect(abs(try weight(of: yellow, in: reservoir) - 0.2275) < 0.0001)
        #expect(abs(try weight(of: blue, in: reservoir) - 0.35) < 0.0001)
    }

    @Test
    func endpointLoadsReplaceOldPaintWithoutMixing() throws {
        let red = RGBAColor(red: 1, green: 0, blue: 0, alpha: 1)
        let yellow = RGBAColor(red: 1, green: 1, blue: 0, alpha: 1)
        let blue = RGBAColor(red: 0, green: 0, blue: 1, alpha: 1)
        var reservoir = OilPaintPigmentReservoirState(cleanColor: red)

        reservoir.load(yellow, amount: 0)
        #expect(reservoir.palette.components == [.init(color: yellow, weight: 1)])

        reservoir.load(blue, amount: 1)
        #expect(reservoir.palette.components == [.init(color: blue, weight: 1)])
    }

    @Test
    func reservoirStaysBoundedAndNormalized() {
        var reservoir = OilPaintPigmentReservoirState(cleanColor: .black)
        for index in 0..<12 {
            reservoir.load(
                RGBAColor(
                    red: Float(index) / 12,
                    green: Float(12 - index) / 12,
                    blue: Float(index % 4) / 4,
                    alpha: 1
                ),
                amount: 0.28
            )
        }

        #expect(reservoir.palette.components.count <= BrushPigmentPalette.maximumComponentCount)
        #expect(abs(reservoir.palette.components.reduce(Float.zero) { $0 + $1.weight } - 1) < 0.0001)
    }

    @Test
    func oilPaintSettingsRoundTripButResidualPaintDoesNot() throws {
        let red = RGBAColor(red: 1, green: 0, blue: 0, alpha: 1)
        let yellow = RGBAColor(red: 1, green: 1, blue: 0, alpha: 1)
        var session = ToolSessionState.stageOneDefault
        session.commitSelectedColor(red)
        session.brush.paintJitterAmount = 0.8
        session.brush.oilPaint = .init(isEnabled: true, newColorLoad: 0.42)
        session.commitSelectedColor(yellow)
        #expect(session.oilPaintReservoir.components.count == 1)
        let didLoad = session.loadSelectedColorIntoOilPaintReservoir()
        #expect(didLoad)
        #expect(session.oilPaintReservoir.components.count == 2)

        let decoded = try JSONDecoder().decode(
            ToolSessionState.self,
            from: JSONEncoder().encode(session)
        )

        #expect(decoded.brush.oilPaint == .init(isEnabled: true, newColorLoad: 0.42))
        #expect(decoded.oilPaintReservoir.palette.components == [.init(color: yellow, weight: 1)])
    }

    @Test
    func legacyBrushWithoutOilPaintSettingsDefaultsToDisabled() throws {
        let encoded = try JSONEncoder().encode(BrushSettings.stageOneDefault)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "oilPaint")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(BrushSettings.self, from: legacyData)

        #expect(decoded.oilPaint == .disabled)
    }

    @Test
    func strokeDescriptorFreezesActivePigmentPalette() throws {
        let red = RGBAColor(red: 1, green: 0, blue: 0, alpha: 1)
        let blue = RGBAColor(red: 0, green: 0, blue: 1, alpha: 1)
        let store = WorkspaceStore()
        store.updateToolSession { session in
            session.commitSelectedColor(red)
            session.brush.paintJitterAmount = 1
            session.brush.oilPaint = .init(isEnabled: true, newColorLoad: 0.4)
            session.commitSelectedColor(blue)
            #expect(session.oilPaintReservoir.palette.components == [.init(color: red, weight: 1)])
            let didLoad = session.loadSelectedColorIntoOilPaintReservoir()
            #expect(didLoad)
        }
        let controller = CanvasInteractionController(workspaceStore: store)

        let result = try #require(controller.makeStrokeDescriptor(samples: [
            .init(location: .init(x: 20, y: 20), pressure: 1),
            .init(location: .init(x: 80, y: 20), pressure: 1)
        ]))

        #expect(result.stroke.pigmentPalette == store.state.toolSession.activeOilPaintPalette)
        store.updateToolSession { $0.washOilPaintReservoir() }
        #expect(result.stroke.pigmentPalette.components.count == 2)
    }

    @Test
    func colorPickerChangesRemainCandidatesUntilExplicitLoad() {
        let red = RGBAColor(red: 1, green: 0, blue: 0, alpha: 1)
        let orange = RGBAColor(red: 1, green: 0.45, blue: 0, alpha: 1)
        let yellow = RGBAColor(red: 1, green: 1, blue: 0, alpha: 1)
        var session = ToolSessionState.stageOneDefault
        session.commitSelectedColor(red)
        session.brush.paintJitterAmount = 0.8
        session.brush.oilPaint = .init(isEnabled: true, newColorLoad: 0.35)

        session.commitSelectedColor(orange)
        session.commitSelectedColor(yellow)

        #expect(session.selectedColor == yellow)
        #expect(session.oilPaintReservoir.palette.components == [.init(color: red, weight: 1)])
        let didLoad = session.loadSelectedColorIntoOilPaintReservoir()
        #expect(didLoad)
        #expect(session.oilPaintReservoir.components.count == 2)
        #expect(session.oilPaintReservoir.components.contains(where: { $0.color == yellow }))
        #expect(!session.oilPaintReservoir.components.contains(where: { $0.color == orange }))
    }

    @Test
    func pigmentSlotsKeepTheirVisualOrderInsteadOfSortingByWeight() {
        let red = RGBAColor(red: 1, green: 0, blue: 0, alpha: 1)
        let yellow = RGBAColor(red: 1, green: 1, blue: 0, alpha: 1)
        let blue = RGBAColor(red: 0, green: 0, blue: 1, alpha: 1)
        var reservoir = OilPaintPigmentReservoirState(cleanColor: red)

        reservoir.load(yellow, amount: 0.2)
        reservoir.load(blue, amount: 0.4)

        #expect(reservoir.components.map(\.color) == [red, yellow, blue])
        #expect(reservoir.components[1].weight < reservoir.components[2].weight)
    }

    @Test
    func draggingPigmentBoundaryOnlyRedistributesItsAdjacentSlots() {
        let red = RGBAColor(red: 1, green: 0, blue: 0, alpha: 1)
        let yellow = RGBAColor(red: 1, green: 1, blue: 0, alpha: 1)
        var reservoir = OilPaintPigmentReservoirState(cleanColor: red)
        reservoir.load(yellow, amount: 0.5)

        reservoir.setBoundary(after: 0, cumulativeWeight: 0.72)

        #expect(abs(reservoir.components[0].weight - 0.72) < 0.0001)
        #expect(abs(reservoir.components[1].weight - 0.28) < 0.0001)
    }

    @Test
    func everyPigmentBoundaryCanBeAdjustedIndependently() {
        let red = RGBAColor(red: 1, green: 0, blue: 0, alpha: 1)
        let green = RGBAColor(red: 0, green: 1, blue: 0, alpha: 1)
        let blue = RGBAColor(red: 0, green: 0, blue: 1, alpha: 1)
        let yellow = RGBAColor(red: 1, green: 1, blue: 0, alpha: 1)
        var reservoir = OilPaintPigmentReservoirState(cleanColor: red)
        reservoir.load(green, amount: 0.25)
        reservoir.load(blue, amount: 1.0 / 3.0)
        reservoir.load(yellow, amount: 0.5)
        let initial = reservoir.components.map(\.weight)

        reservoir.setBoundary(after: 0, cumulativeWeight: 0.18)
        let afterFirst = reservoir.components.map(\.weight)
        #expect(abs(afterFirst[0] - 0.18) < 0.0001)
        #expect(abs(afterFirst[2] - initial[2]) < 0.0001)
        #expect(abs(afterFirst[3] - initial[3]) < 0.0001)

        reservoir.setBoundary(after: 1, cumulativeWeight: 0.42)
        let afterSecond = reservoir.components.map(\.weight)
        #expect(abs(afterSecond[0] - afterFirst[0]) < 0.0001)
        #expect(abs(afterSecond[0] + afterSecond[1] - 0.42) < 0.0001)
        #expect(abs(afterSecond[3] - afterFirst[3]) < 0.0001)

        reservoir.setBoundary(after: 2, cumulativeWeight: 0.78)
        let afterThird = reservoir.components.map(\.weight)
        #expect(abs(afterThird[0] - afterSecond[0]) < 0.0001)
        #expect(abs(afterThird[1] - afterSecond[1]) < 0.0001)
        #expect(abs(afterThird[0] + afterThird[1] + afterThird[2] - 0.78) < 0.0001)
        #expect(abs(afterThird[3] - 0.22) < 0.0001)
    }

    @Test
    func fifthPigmentEvictsTheWeakestOldSlotButKeepsNewest() {
        let red = RGBAColor(red: 1, green: 0, blue: 0, alpha: 1)
        let green = RGBAColor(red: 0, green: 1, blue: 0, alpha: 1)
        let blue = RGBAColor(red: 0, green: 0, blue: 1, alpha: 1)
        let yellow = RGBAColor(red: 1, green: 1, blue: 0, alpha: 1)
        let magenta = RGBAColor(red: 1, green: 0, blue: 1, alpha: 1)
        var reservoir = OilPaintPigmentReservoirState(cleanColor: red)
        reservoir.load(green, amount: 0.25)
        reservoir.load(blue, amount: 0.25)
        reservoir.load(yellow, amount: 0.25)

        reservoir.load(magenta, amount: 0.2)

        #expect(reservoir.components.count == BrushPigmentPalette.maximumComponentCount)
        #expect(reservoir.components.map(\.color) == [red, blue, yellow, magenta])
    }

    @Test
    func lightnessFollowMovesOldPigmentsTowardTheLatestLoadedColor() throws {
        let darkRed = RGBAColor(red: 0.35, green: 0.01, blue: 0.01, alpha: 1)
        let brightYellow = RGBAColor(red: 1, green: 0.9, blue: 0.2, alpha: 1)
        var reservoir = OilPaintPigmentReservoirState(cleanColor: darkRed)
        reservoir.load(brightYellow, amount: 0.35)

        let originalOld = try #require(reservoir.palette.components.first?.color)
        let followedOld = try #require(reservoir.palette(lightnessFollow: 0.75).components.first?.color)
        let latestLightness = OKLabColor(srgb: brightYellow).lightness
        let originalDistance = abs(OKLabColor(srgb: originalOld).lightness - latestLightness)
        let followedDistance = abs(OKLabColor(srgb: followedOld).lightness - latestLightness)

        #expect(followedDistance < originalDistance * 0.35)
        #expect(followedOld.alpha == originalOld.alpha)
    }

    @Test
    func currentColorOutputTemporarilyBypassesReservoirWithoutClearingIt() {
        let red = RGBAColor(red: 1, green: 0, blue: 0, alpha: 1)
        let blue = RGBAColor(red: 0, green: 0, blue: 1, alpha: 1)
        var session = ToolSessionState.stageOneDefault
        session.commitSelectedColor(red)
        session.brush.paintJitterAmount = 0.8
        session.brush.oilPaint = .init(isEnabled: true, newColorLoad: 0.4)
        session.commitSelectedColor(blue)
        let didLoad = session.loadSelectedColorIntoOilPaintReservoir()
        #expect(didLoad)
        let retainedReservoir = session.oilPaintReservoir

        session.oilPaintOutputMode = .currentColor
        #expect(session.activeOilPaintPalette == .empty)
        #expect(session.oilPaintReservoir == retainedReservoir)

        session.oilPaintOutputMode = .reservoir
        #expect(session.activeOilPaintPalette.components.count == 2)
        #expect(session.oilPaintReservoir == retainedReservoir)
    }

    @Test
    func canvasSampledCandidateStillRequiresExplicitLoad() {
        let red = RGBAColor(red: 1, green: 0, blue: 0, alpha: 1)
        let sampledBlue = RGBAColor(red: 0.05, green: 0.2, blue: 0.9, alpha: 1)
        var session = ToolSessionState.stageOneDefault
        session.commitSelectedColor(red)
        session.brush.paintJitterAmount = 0.8
        session.brush.oilPaint = .init(isEnabled: true, newColorLoad: 0.35)
        session.activeTool = .eyedropper

        session.commitSelectedColor(sampledBlue)

        #expect(session.selectedColor == sampledBlue)
        #expect(session.oilPaintReservoir.components == [.init(color: red, weight: 1)])
        let didLoad = session.loadSelectedColorIntoOilPaintReservoir()
        #expect(didLoad)
        #expect(session.oilPaintReservoir.components.contains(where: { $0.color == sampledBlue }))
    }

    @Test
    func legacyOilPaintSettingsDefaultLightnessFollow() throws {
        let encoded = try JSONEncoder().encode(
            OilPaintBrushSettings(isEnabled: true, newColorLoad: 0.4, lightnessFollow: 0.2)
        )
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "lightnessFollow")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(OilPaintBrushSettings.self, from: legacyData)

        #expect(abs(decoded.lightnessFollow - 0.75) < 0.0001)
    }

    private func weight(
        of color: RGBAColor,
        in reservoir: OilPaintPigmentReservoirState
    ) throws -> Float {
        try #require(reservoir.palette.components.first(where: { $0.color == color })?.weight)
    }
}

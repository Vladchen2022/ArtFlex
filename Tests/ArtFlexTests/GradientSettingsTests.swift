import Foundation
import Testing
@testable import ArtFlex

struct GradientSettingsTests {
    @Test
    func defaultGradientReproducesCurrentColorToTransparent() {
        let color = RGBAColor(red: 0.8, green: 0.2, blue: 0.4, alpha: 0.7)
        let settings = GradientSettings.currentColorToTransparent(color)

        #expect(settings.stops.count == 2)
        #expect(settings.color(at: 0) == color)
        #expect(settings.color(at: 1) == color.withAlpha(0))
    }

    @Test
    func stopsAreClampedSortedAndLimitedToEight() {
        let stops = (0..<12).map { index in
            GradientStop(
                position: Float(11 - index) / 10,
                color: .init(red: 2, green: -1, blue: 0.5, alpha: 3)
            )
        }
        let settings = GradientSettings(stops: stops)

        #expect(settings.stops.count == GradientSettings.maximumStopCount)
        #expect(settings.stops.map(\.position) == settings.stops.map(\.position).sorted())
        #expect(settings.stops.allSatisfy { (0...1).contains($0.position) })
        #expect(settings.stops.allSatisfy { $0.color.red == 1 && $0.color.green == 0 && $0.color.alpha == 1 })
    }

    @Test
    func interpolationUsesUnpremultipliedSRGBAndAlpha() {
        let settings = GradientSettings(stops: [
            .init(position: 0, color: .init(red: 1, green: 0, blue: 0, alpha: 1)),
            .init(position: 1, color: .init(red: 0, green: 0, blue: 1, alpha: 0))
        ])
        let midpoint = settings.color(at: 0.5)
        let premultiplied = settings.premultipliedColor(at: 0.5)

        #expect(midpoint == .init(red: 0.5, green: 0, blue: 0.5, alpha: 0.5))
        #expect(premultiplied == .init(red: 0.25, green: 0, blue: 0.25, alpha: 0.5))
    }

    @Test
    func duplicatePositionsCreateDeterministicHardStop() {
        let settings = GradientSettings(stops: [
            .init(position: 0, color: .black),
            .init(position: 0.5, color: .black),
            .init(position: 0.5, color: .white),
            .init(position: 1, color: .white)
        ])

        #expect(settings.color(at: 0.499).red < 0.01)
        #expect(settings.color(at: 0.5) == .white)
    }

    @Test
    func editingEnforcesTwoToEightStopsAndStableIDs() throws {
        let firstID = UUID()
        let secondID = UUID()
        var settings = GradientSettings(stops: [
            .init(id: firstID, position: 0, color: .black),
            .init(id: secondID, position: 1, color: .white)
        ])

        let removedBelowMinimum = settings.removeStop(id: firstID)
        #expect(removedBelowMinimum == false)
        let updated = settings.updateStop(id: secondID, position: 0.25, color: .black)
        #expect(updated)
        #expect(settings.stops.first(where: { $0.id == secondID })?.position == 0.25)

        for index in 0..<6 {
            let inserted = settings.insertStop(at: Float(index + 2) / 10, color: .white)
            #expect(inserted)
        }
        #expect(settings.stops.count == 8)
        let insertedBeyondMaximum = settings.insertStop(at: 0.5, color: .black)
        #expect(insertedBeyondMaximum == false)

        let encoded = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(GradientSettings.self, from: encoded) == settings)
    }
}

import CoreGraphics
import Foundation
import Testing
@testable import ArtFlex

struct BrushLibraryThumbnailTests {
    @Test func demonstrationPreservesPaintSettingsAndFitsAbsoluteTips() {
        var brush = BrushSettings.v2Crayon
        brush.size = 200
        brush.opacity = 0.36
        brush.compoundBrush.primary?.sizeMode = .absolutePixels
        brush.compoundBrush.primary?.size = 100
        brush.compoundBrush.secondary.sizeMode = .absolutePixels
        brush.compoundBrush.secondary.size = 150
        brush.engineV2?.flow = 0.42
        let original = brush
        let recipe = BrushLibraryPreviewRecipe(brush: brush, resolution: 256)
        let scale: Float = 256 * 0.24 / 150
        brush.size *= scale
        brush.compoundBrush.primary?.size *= scale
        brush.compoundBrush.secondary.size *= scale
        #expect(recipe.brush == brush)
        #expect(original.size == 200)
        #expect(recipe.points.first!.pressure > 0.9)
        #expect(recipe.points.last!.pressure < 0.2)
        #expect(abs(recipe.points[48].pressure - 0.59) < 0.05)
        #expect(zip(recipe.points, recipe.points.dropFirst()).allSatisfy { $0.pressure >= $1.pressure })
    }

    @Test func thumbnailEqualsRealEngineStrokeIncludingPenUp() throws {
        var legacy = BrushSettings.stageOneDefault
        legacy.opacity = 0.55
        legacy.pressureOpacityAmount = 0.8
        legacy.spacingPercent = 9
        var overlay = BrushSettings.v2Crayon
        overlay.engineV2?.combination = .overlayMask
        overlay.engineV2?.inputMaximum = 1
        overlay.compoundBrush.primary?.pressureOpacityAmount = 1
        overlay.compoundBrush.primary?.opacityPressureCurve = .identity
        for source in [legacy, BrushSettings.v2Default, BrushSettings.v2Crayon, overlay] {
            let recipe = BrushLibraryPreviewRecipe(brush: source, resolution: 128)
            let image = try #require(StageOneBrushPreviewRasterizer.libraryStrokePreviewImage(for: source, resolution: 128))
            var sampling: BrushStrokeSamplingState?
            let actual = try #require(StageOneBrushPreviewRasterizer.strokeAlphaBytes(for: recipe.brush,
                resolution: 128, points: [recipe.points[0]] + recipe.points, samplingState: &sampling,
                paintVariationSeed: BrushLibraryPreviewRecipe.seed, flushPendingSamples: true))
            #expect(try alpha(image) == actual)
            #expect(actual.contains { $0 > 64 })
            #expect(try alpha(image) == alpha(#require(StageOneBrushPreviewRasterizer.libraryStrokePreviewImage(for: source, resolution: 128))))
        }
    }

    @Test func cacheAndImageRespondToSecondaryMaskFlowAndCurves() throws {
        var source = BrushSettings.v2Crayon
        source.engineV2?.combination = .overlayMask
        source.engineV2?.inputMaximum = 1
        source.engineV2?.secondaryVariants = []
        source.compoundBrush.primary?.pressureOpacityAmount = 1
        source.compoundBrush.primary?.opacityPressureCurve = .identity
        func render(_ brush: BrushSettings) throws -> [UInt8] {
            try alpha(#require(StageOneBrushPreviewRasterizer.libraryStrokePreviewImage(for: brush, resolution: 128)))
        }
        let original = try render(source)
        var changed = source
        changed.compoundBrush.secondary.customTipMaskData = Data(repeating: 255, count: 32 * 32)
        #expect(try render(changed) != original)
        changed = source
        changed.engineV2?.flow = 0.08
        #expect(try render(changed) != original)
        changed = source
        changed.compoundBrush.primary?.opacityPressureCurve = CurveChannelState(points: [
            .init(x: 0, y: 0.7), .init(x: 1, y: 1)
        ])
        #expect(try render(changed) != original)
        changed = source
        changed.engineV2?.combination = .pressureBlend
        #expect(try render(changed) != original)
        #expect(try render(source) == original)
    }

    @Test func spacingAndOpacityRemainHonestAndEndpointsAreNotClipped() throws {
        var dense = BrushSettings.v2Default
        dense.spacingPercent = 6
        let full = try alpha(#require(StageOneBrushPreviewRasterizer.libraryStrokePreviewImage(for: dense, resolution: 128)))
        var sparse = dense
        sparse.spacingPercent = 180
        let spaced = try alpha(#require(StageOneBrushPreviewRasterizer.libraryStrokePreviewImage(for: sparse, resolution: 128)))
        #expect(full.filter { $0 > 0 }.count > spaced.filter { $0 > 0 }.count)
        dense.opacity = 0.1
        let faint = try alpha(#require(StageOneBrushPreviewRasterizer.libraryStrokePreviewImage(for: dense, resolution: 128)))
        #expect(faint.max()! <= 27)
        #expect(full.max()! >= 254)
        for index in 0..<128 {
            #expect(full[index] == 0)
            #expect(full[127 * 128 + index] == 0)
            #expect(full[index * 128] == 0)
            #expect(full[index * 128 + 127] == 0)
        }
        #expect(StageOneBrushPreviewRasterizer.libraryStrokePreviewImage(for: dense, resolution: 0) == nil)
    }

    @Test func currentLibraryCanRenderWithoutChangingAnyPreset() throws {
        guard let path = ProcessInfo.processInfo.environment["ARTFLEX_THUMBNAIL_LIBRARY"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let archive = try JSONDecoder().decode(BrushLibraryArchive.self, from: data)
        let before = archive.resolvedLibrary
        let started = Date()
        for preset in before.presets {
            let image = try #require(StageOneBrushPreviewRasterizer.libraryStrokePreviewImage(for: preset.brush))
            #expect(image.width == 256 && image.height == 256)
        }
        #expect(archive.resolvedLibrary == before)
        print("Rendered \(before.presets.count) saved brush thumbnails in \(Date().timeIntervalSince(started)) seconds")
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == data)
    }

    private func alpha(_ image: CGImage) throws -> [UInt8] {
        let data = try #require(image.dataProvider?.data) as Data
        return (0..<image.height).flatMap { y in
            (0..<image.width).map { x in data[y * image.bytesPerRow + x * 4 + 3] }
        }
    }
}

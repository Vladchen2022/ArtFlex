import CoreGraphics
import Foundation
import Testing
@testable import ArtFlex

struct StageOneBrushPreviewRasterizerTests {
    @Test
    func importedStampImageCropsToVisibleContent() {
        var brush = BrushSettings.stageOneDefault
        brush.tipShape = .customRound
        brush.customTipSourceSemantic = .importedImage
        brush.customTipMaskData = makeVerticalMask(side: 16)

        let importedImage = StageOneBrushPreviewRasterizer.stampImage(
            for: brush,
            resolution: 128
        )

        #expect(importedImage != nil)
        #expect(importedImage?.width ?? 0 < 128)
        #expect(importedImage?.height ?? 0 < 128)

        brush.customTipSourceSemantic = .customMask
        let uncroppedImage = StageOneBrushPreviewRasterizer.stampImage(
            for: brush,
            resolution: 128
        )

        #expect(uncroppedImage?.width == 128)
        #expect(uncroppedImage?.height == 128)
    }

    @Test
    func proceduralCustomRoundStampImageExistsWithoutMaskData() {
        var brush = BrushSettings.stageOneDefault
        brush.tipShape = .customRound
        brush.customTipSourceSemantic = .procedural
        brush.customTipMaskData = nil
        brush.customTipSoftness = 0.22
        brush.customTipRoundness = 0.58
        brush.customTipAngleDegrees = 31

        let image = StageOneBrushPreviewRasterizer.stampImage(
            for: brush,
            resolution: 128
        )

        #expect(image != nil)
        #expect(image?.width == 128)
        #expect(image?.height == 128)
    }

    @Test
    func builtInShapeStampImagesExistAtCompactPreviewResolutions() {
        for tipShape in [BrushTipShape.hardRound, .softRound, .square] {
            var brush = BrushSettings.stageOneDefault
            brush.tipShape = tipShape

            let image = StageOneBrushPreviewRasterizer.stampImage(
                for: brush,
                resolution: 28
            )

            #expect(image != nil)
            #expect(image?.width == 28)
            #expect(image?.height == 28)
        }
    }

    @Test
    func importedAssetPreviewPreservesRawMaskAlpha() throws {
        let image = StageOneBrushPreviewRasterizer.importedAssetImage(
            from: makeSoftCenteredMask(side: 16, alpha: 128),
            resolution: 128
        )

        #expect(image != nil)
        #expect(image?.width ?? 0 < 128)
        #expect(image?.height ?? 0 < 128)

        guard let image else {
            Issue.record("Expected imported asset preview image.")
            return
        }

        let sampledAlpha = try alpha(atX: image.width / 2, y: image.height / 2, in: image)
        #expect(abs(Int(sampledAlpha) - 128) <= 8)
    }

    @Test
    func editorMaskPreviewCropsAndUsesOpaqueMonochromePixels() throws {
        guard let image = StageOneBrushPreviewRasterizer.editorMaskImage(
            from: makeVerticalMask(side: 16),
            resolution: 128,
            cropToContent: true
        ) else {
            Issue.record("Expected editor mask preview image.")
            return
        }

        #expect(image.width < 128)
        #expect(image.height < 128)

        let sampled = try rgba(atX: image.width / 2, y: image.height / 2, in: image)
        #expect(sampled.red < 24)
        #expect(sampled.green < 24)
        #expect(sampled.blue < 24)
        #expect(sampled.alpha > 240)
    }

    @Test
    func maskFingerprintUsesStableContentIdentity() {
        let maskA = makeVerticalMask(side: 16)
        let maskB = makeSoftCenteredMask(side: 16, alpha: 128)

        let fingerprintA = StageOneBrushPreviewRasterizer.maskFingerprint(for: maskA)
        let fingerprintARepeat = StageOneBrushPreviewRasterizer.maskFingerprint(for: maskA)
        let fingerprintB = StageOneBrushPreviewRasterizer.maskFingerprint(for: maskB)

        #expect(fingerprintA != nil)
        #expect(fingerprintA == fingerprintARepeat)
        #expect(fingerprintA != fingerprintB)
    }

    private func makeVerticalMask(side: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: side * side)
        let xRange = max(0, side / 2 - 1)...min(side - 1, side / 2)
        let yRange = max(0, side / 5)...min(side - 1, side - side / 5)
        for y in yRange {
            for x in xRange {
                bytes[(y * side) + x] = 255
            }
        }
        return Data(bytes)
    }

    private func makeSoftCenteredMask(side: Int, alpha: UInt8) -> Data {
        var bytes = [UInt8](repeating: 0, count: side * side)
        let minX = max(0, side / 2 - 2)
        let maxX = min(side - 1, side / 2 + 1)
        let minY = max(0, side / 2 - 2)
        let maxY = min(side - 1, side / 2 + 1)
        for y in minY...maxY {
            for x in minX...maxX {
                bytes[(y * side) + x] = alpha
            }
        }
        return Data(bytes)
    }

    private func alpha(atX x: Int, y: Int, in image: CGImage) throws -> UInt8 {
        guard
            let provider = image.dataProvider,
            let providerData = provider.data
        else {
            throw PreviewSamplingError.missingData
        }

        let data = providerData as Data
        let bytesPerPixel = image.bitsPerPixel / 8
        let offset = (y * image.bytesPerRow) + (x * bytesPerPixel) + 3
        guard offset < data.count else {
            throw PreviewSamplingError.outOfBounds
        }
        return data[offset]
    }

    private func alphaSum(in image: CGImage) throws -> Int {
        guard
            let provider = image.dataProvider,
            let providerData = provider.data
        else {
            throw PreviewSamplingError.missingData
        }

        let data = providerData as Data
        let bytesPerPixel = image.bitsPerPixel / 8
        return stride(from: 3, to: data.count, by: bytesPerPixel).reduce(0) { partialResult, index in
            partialResult + Int(data[index])
        }
    }

    private func rgba(atX x: Int, y: Int, in image: CGImage) throws -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        guard
            let provider = image.dataProvider,
            let providerData = provider.data
        else {
            throw PreviewSamplingError.missingData
        }

        let data = providerData as Data
        let bytesPerPixel = image.bitsPerPixel / 8
        let offset = (y * image.bytesPerRow) + (x * bytesPerPixel)
        guard offset + 3 < data.count else {
            throw PreviewSamplingError.outOfBounds
        }

        return (
            red: data[offset],
            green: data[offset + 1],
            blue: data[offset + 2],
            alpha: data[offset + 3]
        )
    }

    private enum PreviewSamplingError: Error {
        case missingData
        case outOfBounds
    }
}

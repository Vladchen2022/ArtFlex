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

    @Test
    func subtractCompositePreviewCarvesOutCenterCoverage() throws {
        var brush = BrushSettings.stageOneDefault
        brush.dualTipEnabled = true
        brush.dualTipCombineMode = .subtract
        brush.dualTipStrength = 1
        brush.tipShape = .hardRound
        brush.secondaryTipDescriptor = SecondaryTipDescriptor(tipShape: .hardRound)
        brush.secondarySizeRatio = 0.45

        guard
            let primaryImage = StageOneBrushPreviewRasterizer.stampImage(for: brush, resolution: 128),
            let compositeImage = StageOneBrushPreviewRasterizer.compositeStampImage(
                for: brush,
                activeTool: .brush,
                resolution: 128
            )
        else {
            Issue.record("Expected preview rasterizer to create both primary and composite preview images.")
            return
        }

        let center = (x: 64, y: 64)
        let edge = (x: 96, y: 64)
        let primaryCenterAlpha = try alpha(atX: center.x, y: center.y, in: primaryImage)
        let compositeCenterAlpha = try alpha(atX: center.x, y: center.y, in: compositeImage)
        let compositeEdgeAlpha = try alpha(atX: edge.x, y: edge.y, in: compositeImage)

        #expect(primaryCenterAlpha > 240)
        #expect(compositeCenterAlpha < 24)
        #expect(compositeEdgeAlpha > 200)
    }

    @Test
    func compositePreviewStillRendersIllustrationOutsideCurrentRealDrawingGate() throws {
        var brush = BrushSettings.stageOneDefault
        brush.dualTipEnabled = true
        brush.dualTipCombineMode = .multiply
        brush.tipShape = .hardRound
        brush.secondaryTipDescriptor = SecondaryTipDescriptor(tipShape: .square)
        brush.secondarySizeRatio = 0.55

        guard let compositeImage = StageOneBrushPreviewRasterizer.compositeStampImage(
            for: brush,
            activeTool: .smudge,
            resolution: 128
        ) else {
            Issue.record("Expected illustrative composite preview even outside the current real drawing gate.")
            return
        }

        let centerAlpha = try alpha(atX: 64, y: 64, in: compositeImage)
        #expect(centerAlpha > 200)
    }

    @Test
    func compositePreviewStillRendersIllustrationWhenDualTipToggleIsOff() throws {
        var brush = BrushSettings.stageOneDefault
        brush.dualTipEnabled = false
        brush.dualTipCombineMode = .subtract
        brush.tipShape = .hardRound
        brush.secondaryTipDescriptor = SecondaryTipDescriptor(tipShape: .hardRound)
        brush.secondarySizeRatio = 0.45
        brush.dualTipStrength = 1

        guard let compositeImage = StageOneBrushPreviewRasterizer.compositeStampImage(
            for: brush,
            activeTool: .brush,
            resolution: 128
        ) else {
            Issue.record("Expected illustrative composite preview even when Dual Tip is toggled off.")
            return
        }

        let centerAlpha = try alpha(atX: 64, y: 64, in: compositeImage)
        #expect(centerAlpha < 24)
    }

    @Test
    func secondaryScatterOffsetIsStableAndToolGated() {
        var brush = BrushSettings.stageOneDefault
        brush.dualTipEnabled = true
        brush.dualTipCombineMode = .multiply
        brush.secondaryScatter = 2.4

        let point = CGPoint(x: 48, y: 19)
        let first = StageOneBrushPreviewRasterizer.secondaryScatterOffset(
            for: brush,
            activeTool: .brush,
            point: point,
            sampleIndex: 3
        )
        let second = StageOneBrushPreviewRasterizer.secondaryScatterOffset(
            for: brush,
            activeTool: .brush,
            point: point,
            sampleIndex: 3
        )

        #expect(abs(first.x - second.x) < 0.0001)
        #expect(abs(first.y - second.y) < 0.0001)
        #expect(abs(first.x) > 0.0001 || abs(first.y) > 0.0001)

        brush.dualTipEnabled = false
        let disabled = StageOneBrushPreviewRasterizer.secondaryScatterOffset(
            for: brush,
            activeTool: .brush,
            point: point,
            sampleIndex: 3
        )
        #expect(abs(disabled.x) < 0.0001)
        #expect(abs(disabled.y) < 0.0001)
    }

    @Test
    func secondaryScatterJitterIsStableAndToolGated() {
        var brush = BrushSettings.stageOneDefault
        brush.dualTipEnabled = true
        brush.dualTipCombineMode = .multiply
        brush.secondaryScatter = 2.4
        brush.secondaryScatterJitter = 0.4

        let point = CGPoint(x: 48, y: 19)
        let first = StageOneBrushPreviewRasterizer.secondaryScatterOffset(
            for: brush,
            activeTool: .brush,
            point: point,
            sampleIndex: 3
        )
        let second = StageOneBrushPreviewRasterizer.secondaryScatterOffset(
            for: brush,
            activeTool: .brush,
            point: point,
            sampleIndex: 3
        )

        #expect(abs(first.x - second.x) < 0.0001)
        #expect(abs(first.y - second.y) < 0.0001)

        var baseline = brush
        baseline.secondaryScatterJitter = 0
        let fixedScatter = StageOneBrushPreviewRasterizer.secondaryScatterOffset(
            for: baseline,
            activeTool: .brush,
            point: point,
            sampleIndex: 3
        )
        #expect(abs(first.x - fixedScatter.x) > 0.0001 || abs(first.y - fixedScatter.y) > 0.0001)

        let disabled = StageOneBrushPreviewRasterizer.secondaryScatterOffset(
            for: brush,
            activeTool: .smudge,
            point: point,
            sampleIndex: 3
        )
        #expect(abs(disabled.x) < 0.0001)
        #expect(abs(disabled.y) < 0.0001)
    }

    @Test
    func secondarySizeJitterIsStableAndToolGated() {
        var brush = BrushSettings.stageOneDefault
        brush.dualTipEnabled = true
        brush.dualTipCombineMode = .multiply
        brush.tipShape = .customRound
        brush.customTipMaskData = makeVerticalMask(side: 16)
        brush.secondaryTipDescriptor = SecondaryTipDescriptor(
            tipShape: .customRound,
            customTipMaskData: makeSoftCenteredMask(side: 16, alpha: 255),
            customTipSoftness: 0.4,
            customTipRoundness: 0.8,
            customTipAngleDegrees: 0
        )
        brush.secondarySizeRatio = 0.55
        brush.secondarySizeJitter = 0.4

        let point = CGPoint(x: 24, y: 11)
        let first = StageOneBrushPreviewRasterizer.secondaryResolvedSizeRatio(
            for: brush,
            activeTool: .brush,
            point: point,
            sampleIndex: 2
        )
        let second = StageOneBrushPreviewRasterizer.secondaryResolvedSizeRatio(
            for: brush,
            activeTool: .brush,
            point: point,
            sampleIndex: 2
        )

        #expect(abs(first - second) < 0.0001)
        #expect(abs(first - 0.55) > 0.0001)

        let disabled = StageOneBrushPreviewRasterizer.secondaryResolvedSizeRatio(
            for: brush,
            activeTool: .smudge,
            point: point,
            sampleIndex: 2
        )
        #expect(abs(disabled - 0.55) < 0.0001)
    }

    @Test
    func secondaryAngleJitterIsStableAndToolGated() {
        var brush = BrushSettings.stageOneDefault
        brush.dualTipEnabled = true
        brush.dualTipCombineMode = .multiply
        brush.tipShape = .customRound
        brush.customTipMaskData = makeVerticalMask(side: 16)
        brush.secondaryTipDescriptor = SecondaryTipDescriptor(
            tipShape: .customRound,
            customTipMaskData: makeSoftCenteredMask(side: 16, alpha: 255),
            customTipSoftness: 0.4,
            customTipRoundness: 0.8,
            customTipAngleDegrees: 17
        )
        brush.secondaryAngleJitterDegrees = 42

        let point = CGPoint(x: 31, y: 14)
        let first = StageOneBrushPreviewRasterizer.secondaryResolvedAngleDegrees(
            for: brush,
            activeTool: .brush,
            point: point,
            sampleIndex: 2
        )
        let second = StageOneBrushPreviewRasterizer.secondaryResolvedAngleDegrees(
            for: brush,
            activeTool: .brush,
            point: point,
            sampleIndex: 2
        )

        #expect(abs(first - second) < 0.0001)
        #expect(abs(first - 17) > 0.0001)

        let disabled = StageOneBrushPreviewRasterizer.secondaryResolvedAngleDegrees(
            for: brush,
            activeTool: .smudge,
            point: point,
            sampleIndex: 2
        )
        #expect(abs(disabled - 17) < 0.0001)
    }

    @Test
    func secondarySpacingPhaseOffsetIsStableAndToolGated() {
        var brush = BrushSettings.stageOneDefault
        brush.dualTipEnabled = true
        brush.dualTipCombineMode = .multiply
        brush.secondarySpacingPhase = 0.4
        brush.spacingPercent = 40

        let first = StageOneBrushPreviewRasterizer.secondarySpacingPhaseOffset(
            for: brush,
            activeTool: .brush,
            directionDegrees: 0
        )
        let second = StageOneBrushPreviewRasterizer.secondarySpacingPhaseOffset(
            for: brush,
            activeTool: .brush,
            directionDegrees: 0
        )

        #expect(abs(first.x - second.x) < 0.0001)
        #expect(abs(first.y - second.y) < 0.0001)
        #expect(abs(first.x - 0.32) < 0.0001)
        #expect(abs(first.y) < 0.0001)

        let disabled = StageOneBrushPreviewRasterizer.secondarySpacingPhaseOffset(
            for: brush,
            activeTool: .smudge,
            directionDegrees: 0
        )
        #expect(abs(disabled.x) < 0.0001)
        #expect(abs(disabled.y) < 0.0001)
    }

    @Test
    func secondarySpacingPhaseJitterIsStableAndToolGated() {
        var brush = BrushSettings.stageOneDefault
        brush.dualTipEnabled = true
        brush.dualTipCombineMode = .multiply
        brush.secondarySpacingPhase = 0.1
        brush.secondarySpacingPhaseJitter = 0.2
        brush.spacingPercent = 40

        let point = CGPoint(x: 28, y: 17)
        let first = StageOneBrushPreviewRasterizer.secondarySpacingPhaseOffset(
            for: brush,
            activeTool: .brush,
            point: point,
            sampleIndex: 3,
            directionDegrees: 0
        )
        let second = StageOneBrushPreviewRasterizer.secondarySpacingPhaseOffset(
            for: brush,
            activeTool: .brush,
            point: point,
            sampleIndex: 3,
            directionDegrees: 0
        )

        #expect(abs(first.x - second.x) < 0.0001)
        #expect(abs(first.y - second.y) < 0.0001)
        #expect(abs(first.x - 0.08) > 0.0001)

        let disabled = StageOneBrushPreviewRasterizer.secondarySpacingPhaseOffset(
            for: brush,
            activeTool: .smudge,
            point: point,
            sampleIndex: 3,
            directionDegrees: 0
        )
        #expect(abs(disabled.x) < 0.0001)
        #expect(abs(disabled.y) < 0.0001)
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

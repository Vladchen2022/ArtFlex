import CoreGraphics
import Foundation
import Testing
@testable import ArtFlex

struct StageOneBrushPreviewRasterizerTests {
    @Test
    func incrementalStrokeSessionMatchesWholeStrokeRasterization() throws {
        let resolution = 256
        let points = [
            StrokePoint(x: 28, y: 36, pressure: 0.35),
            StrokePoint(x: 58, y: 74, pressure: 0.48),
            StrokePoint(x: 96, y: 112, pressure: 0.62),
            StrokePoint(x: 142, y: 96, pressure: 0.76),
            StrokePoint(x: 184, y: 142, pressure: 0.9),
            StrokePoint(x: 224, y: 196, pressure: 1)
        ]

        for buildMode in [BrushBuildMode.buildUp, .opacityCap] {
            var brush = BrushSettings.stageOneDefault
            brush.size = 28
            brush.spacingPercent = 9
            brush.pressureSizeAmount = 0.7
            brush.pressureOpacityAmount = 0.6
            brush.buildMode = buildMode

            var wholeSamplingState: BrushStrokeSamplingState?
            let wholePoints = [points[0]] + points
            let wholeAlpha = try #require(StageOneBrushPreviewRasterizer.strokeAlphaBytes(
                for: brush,
                resolution: resolution,
                points: wholePoints,
                samplingState: &wholeSamplingState,
                flushPendingSamples: true
            ))
            let session = try #require(StageOneBrushPreviewRasterizer.makeStrokeAlphaSession(
                for: brush,
                resolution: resolution
            ))

            var incrementalAlpha = [UInt8](repeating: 0, count: resolution * resolution)
            var largestUpdatePixelCount = 0
            for index in points.indices {
                let start = index == points.startIndex ? points[index] : points[index - 1]
                if let update = session.append(points: [start, points[index]]) {
                    apply(update, to: &incrementalAlpha, resolution: resolution)
                    largestUpdatePixelCount = max(largestUpdatePixelCount, update.alphaBytes.count)
                }
            }
            #expect(largestUpdatePixelCount < (resolution * resolution) / 2)
            if let update = session.finish() {
                apply(update, to: &incrementalAlpha, resolution: resolution)
            }

            #expect(incrementalAlpha == wholeAlpha)
        }
    }

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
    func stampAlphaBytesReflectCurrentBrushTipShape() {
        var roundBrush = BrushSettings.stageOneDefault
        roundBrush.tipShape = .hardRound

        var squareBrush = BrushSettings.stageOneDefault
        squareBrush.tipShape = .square

        let resolution = 17
        let roundAlpha = StageOneBrushPreviewRasterizer.stampAlphaBytes(
            for: roundBrush,
            resolution: resolution
        )
        let squareAlpha = StageOneBrushPreviewRasterizer.stampAlphaBytes(
            for: squareBrush,
            resolution: resolution
        )

        #expect(roundAlpha.count == resolution * resolution)
        #expect(squareAlpha.count == resolution * resolution)
        #expect(roundAlpha[0] == 0)
        #expect(squareAlpha[0] > 0)
        #expect(squareAlpha[(resolution / 2) * resolution + (resolution / 2)] == 255)
    }

    @Test
    func compoundStrokeAlphaBytesRespectGlobalPressureOpacityForSecondaryDominantBrushes() {
        var brush = BrushSettings.stageOneDefault
        brush.size = 28
        brush.pressureOpacityAmount = 0
        brush.compoundBrush.enabled = true
        brush.compoundBrush.globalPressureOpacityAmount = 1
        brush.compoundBrush.pressureMix.primaryAtLowPressure = 0
        brush.compoundBrush.pressureMix.primaryAtMidPressure = 0
        brush.compoundBrush.pressureMix.primaryAtHighPressure = 0
        brush.compoundBrush.secondary.pressureOpacityAmount = 0

        var lowSamplingState: BrushStrokeSamplingState?
        let lowAlphaBytes = StageOneBrushPreviewRasterizer.strokeAlphaBytes(
            for: brush,
            resolution: 256,
            points: [
                StrokePoint(x: 64, y: 128, pressure: 0.15),
                StrokePoint(x: 192, y: 128, pressure: 0.15)
            ],
            samplingState: &lowSamplingState,
            flushPendingSamples: true
        )

        var highSamplingState: BrushStrokeSamplingState?
        let highAlphaBytes = StageOneBrushPreviewRasterizer.strokeAlphaBytes(
            for: brush,
            resolution: 256,
            points: [
                StrokePoint(x: 64, y: 128, pressure: 1.0),
                StrokePoint(x: 192, y: 128, pressure: 1.0)
            ],
            samplingState: &highSamplingState,
            flushPendingSamples: true
        )

        let lowAverageAlpha = alphaAverage(in: lowAlphaBytes ?? [])
        let highAverageAlpha = alphaAverage(in: highAlphaBytes ?? [])

        #expect(lowAverageAlpha > 0)
        #expect(highAverageAlpha > lowAverageAlpha * 2.5)
    }

    @Test
    func buildUpStrokeAlphaBytesRespectPressureOpacityUnderTightSpacing() {
        var brush = BrushSettings.stageOneDefault
        brush.size = 28
        brush.spacingPercent = 8
        brush.opacity = 1
        brush.pressureSizeAmount = 0
        brush.pressureOpacityAmount = 1
        brush.buildMode = .buildUp

        var lowSamplingState: BrushStrokeSamplingState?
        let lowAlphaBytes = StageOneBrushPreviewRasterizer.strokeAlphaBytes(
            for: brush,
            resolution: 256,
            points: [
                StrokePoint(x: 64, y: 128, pressure: 0.2),
                StrokePoint(x: 192, y: 128, pressure: 0.2)
            ],
            samplingState: &lowSamplingState,
            flushPendingSamples: true
        )

        var highSamplingState: BrushStrokeSamplingState?
        let highAlphaBytes = StageOneBrushPreviewRasterizer.strokeAlphaBytes(
            for: brush,
            resolution: 256,
            points: [
                StrokePoint(x: 64, y: 128, pressure: 1.0),
                StrokePoint(x: 192, y: 128, pressure: 1.0)
            ],
            samplingState: &highSamplingState,
            flushPendingSamples: true
        )

        let lowAverageAlpha = alphaAverage(in: lowAlphaBytes ?? [])
        let highAverageAlpha = alphaAverage(in: highAlphaBytes ?? [])

        #expect(lowAverageAlpha > 0)
        #expect(highAverageAlpha > lowAverageAlpha * 2.5)
    }

    @Test
    func compoundStrokeAlphaBytesRespectGlobalPressureSizeForSecondaryDominantBrushes() {
        var brush = BrushSettings.stageOneDefault
        brush.size = 28
        brush.pressureSizeAmount = 0
        brush.compoundBrush.enabled = true
        brush.compoundBrush.globalPressureSizeAmount = 1
        brush.compoundBrush.pressureMix.primaryAtLowPressure = 0
        brush.compoundBrush.pressureMix.primaryAtMidPressure = 0
        brush.compoundBrush.pressureMix.primaryAtHighPressure = 0
        brush.compoundBrush.secondary.pressureSizeAmount = 0

        var lowSamplingState: BrushStrokeSamplingState?
        let lowAlphaBytes = StageOneBrushPreviewRasterizer.strokeAlphaBytes(
            for: brush,
            resolution: 256,
            points: [
                StrokePoint(x: 64, y: 128, pressure: 0.45),
                StrokePoint(x: 192, y: 128, pressure: 0.45)
            ],
            samplingState: &lowSamplingState,
            flushPendingSamples: true
        )

        var highSamplingState: BrushStrokeSamplingState?
        let highAlphaBytes = StageOneBrushPreviewRasterizer.strokeAlphaBytes(
            for: brush,
            resolution: 256,
            points: [
                StrokePoint(x: 64, y: 128, pressure: 1.0),
                StrokePoint(x: 192, y: 128, pressure: 1.0)
            ],
            samplingState: &highSamplingState,
            flushPendingSamples: true
        )

        let lowCoverage = alphaCoverageCount(in: lowAlphaBytes ?? [], threshold: 18)
        let highCoverage = alphaCoverageCount(in: highAlphaBytes ?? [], threshold: 18)

        #expect(lowCoverage > 0)
        #expect(Double(highCoverage) > Double(lowCoverage) * 1.4)
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

    private func alphaMax(in bytes: [UInt8]) -> UInt8 {
        bytes.max() ?? 0
    }

    private func alphaCoverageCount(in bytes: [UInt8], threshold: UInt8) -> Int {
        bytes.reduce(into: 0) { count, value in
            if value >= threshold {
                count += 1
            }
        }
    }

    private func alphaAverage(in bytes: [UInt8]) -> Double {
        guard !bytes.isEmpty else { return 0 }
        let total = bytes.reduce(into: 0) { partialResult, value in
            partialResult += Int(value)
        }
        return Double(total) / Double(bytes.count)
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

private func apply(
    _ update: StageOneBrushPreviewRasterizer.StrokeAlphaUpdate,
    to destination: inout [UInt8],
    resolution: Int
) {
    for localY in 0..<update.bounds.height {
        for localX in 0..<update.bounds.width {
            let sourceIndex = (localY * update.bounds.width) + localX
            let destinationIndex =
                ((update.bounds.originY + localY) * resolution)
                + update.bounds.originX
                + localX
            destination[destinationIndex] = update.alphaBytes[sourceIndex]
        }
    }
}

import CoreGraphics
import Foundation
import Testing
@testable import ArtFlex

struct StageOneBrushPreviewRasterizerTests {
    @Test
    func previewVariationSeedIsStableAndCanBeRerolled() throws {
        var brush = BrushSettings.stageOneDefault
        brush.size = 24
        brush.spacingPercent = 18
        brush.paintJitterAmount = 1
        brush.paintContrastAmount = 0.6

        func render(seed: UInt32) throws -> Data {
            let image = try #require(StageOneBrushPreviewRasterizer.compoundStrokePreviewImage(
                for: brush,
                resolution: 256,
                pressure: 0.7,
                paintVariationSeed: seed
            ))
            return try pixelData(in: image)
        }

        let first = try render(seed: 17)
        let repeated = try render(seed: 17)
        let rerolled = try render(seed: 29)
        #expect(first == repeated)
        #expect(first != rerolled)
    }

    @Test
    func brushLibraryStrokePreviewUsesSparseBoundedStampCount() {
        #expect(StageOneBrushPreviewRasterizer.libraryStrokePreviewStampCount(spacingPercent: 0) == 7)
        #expect(StageOneBrushPreviewRasterizer.libraryStrokePreviewStampCount(spacingPercent: 18) == 7)
        #expect(StageOneBrushPreviewRasterizer.libraryStrokePreviewStampCount(spacingPercent: 50) == 6)
        #expect(StageOneBrushPreviewRasterizer.libraryStrokePreviewStampCount(spacingPercent: 100) == 4)
        #expect(StageOneBrushPreviewRasterizer.libraryStrokePreviewStampCount(spacingPercent: 150) == 3)
        #expect(StageOneBrushPreviewRasterizer.libraryStrokePreviewStampCount(spacingPercent: 500) == 3)
    }

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
    func pressureGrainCrayonMovesFromSparseTextureToDenseHeavyStroke() throws {
        var sourceBrush = BrushSettings.stageOneDefault
        sourceBrush.tipShape = .customRound
        sourceBrush.customTipSourceSemantic = .importedImage
        sourceBrush.customTipAssetID = BrushPreset.pressureGrainCrayonSourceTipAssetID
        sourceBrush.customTipMaskData = makeFiberedMask(side: 256)
        sourceBrush.customTipEnvelopeMaskData = Data(repeating: 255, count: 256 * 256)
        sourceBrush.compoundBrush.enabled = true
        sourceBrush.compoundBrush.secondary.tipShape = .customRound
        sourceBrush.compoundBrush.secondary.sourceSemantic = .customMask
        sourceBrush.compoundBrush.secondary.customTipMaskData = makeGrainMask(side: 256)

        let sourcePreset = BrushPreset(
            id: "source-fourth-brush",
            name: "第四支笔",
            brush: sourceBrush,
            isBuiltIn: false,
            slotIndex: 3
        )
        let crayon = try #require(
            BrushPreset.pressureGrainCrayon(derivedFrom: sourcePreset, slotIndex: 4)
        )
        #expect(crayon.brush.buildMode == .buildUp)

        let crayonBrush = crayon.brush

        func renderedAlpha(brush: BrushSettings, pressure: Float) throws -> [UInt8] {
            var samplingState: BrushStrokeSamplingState?
            return try #require(StageOneBrushPreviewRasterizer.strokeAlphaBytes(
                for: brush,
                resolution: 256,
                points: [
                    StrokePoint(x: 52, y: 128, pressure: pressure),
                    StrokePoint(x: 204, y: 128, pressure: pressure)
                ],
                samplingState: &samplingState,
                flushPendingSamples: true
            ))
        }

        let light = try renderedAlpha(brush: crayonBrush, pressure: 0.28)
        let medium = try renderedAlpha(brush: crayonBrush, pressure: 0.58)
        let heavy = try renderedAlpha(brush: crayonBrush, pressure: 1)
        let pressureSeries: [Float] = [
            0.15, 0.25, 0.35, 0.45, 0.55, 0.58, 0.60, 0.62, 0.65,
            0.68, 0.70, 0.72, 0.75, 0.80, 0.85, 0.90, 0.95, 1
        ]
        let pressureSeriesInteriorAverages = try pressureSeries.map { pressure in
            alphaAverageRatio(
                in: try renderedAlpha(brush: crayonBrush, pressure: pressure),
                resolution: 256,
                xRange: 72...184,
                yRange: 121...135
            )
        }
        let lightAverage = alphaAverage(in: light)
        let mediumAverage = alphaAverage(in: medium)
        let heavyAverage = alphaAverage(in: heavy)
        let lightCoverage = alphaCoverageCount(in: light, threshold: 24)
        let mediumInteriorVariation = alphaStandardDeviationRatio(
            in: medium,
            resolution: 256,
            xRange: 72...184,
            yRange: 121...135
        )
        let heavyNearBlackCoverage = alphaCoverageRatio(
            in: heavy,
            resolution: 256,
            xRange: 72...184,
            yRange: 121...135,
            threshold: 224
        )
        let heavyDenseCoverage = alphaCoverageRatio(
            in: heavy,
            resolution: 256,
            xRange: 72...184,
            yRange: 121...135,
            threshold: 128
        )

        #expect(lightAverage > 0)
        #expect(mediumAverage > lightAverage * 1.8)
        #expect(heavyAverage > mediumAverage * 1.5)
        #expect(lightCoverage > 0)
        #expect(alphaMax(in: heavy) >= 248)
        #expect((pressureSeriesInteriorAverages.first ?? 0) > 0.03)
        #expect((pressureSeriesInteriorAverages.last ?? 0) > 0.88)
        for index in 1..<pressureSeriesInteriorAverages.count {
            let previous = pressureSeriesInteriorAverages[index - 1]
            let current = pressureSeriesInteriorAverages[index]
            #expect(current > previous)
            #expect(current - previous < 0.18)
        }
        // Medium pressure must retain visible A-tip texture instead of becoming
        // a uniform translucent sheet.
        #expect(mediumInteriorVariation > 0.1)
        // The Photoshop reference resolves the primary body to an essentially
        // solid mark at maximum pressure.
        #expect(heavyDenseCoverage > 0.95)
        #expect(heavyNearBlackCoverage > 0.95)

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
    func textureFillMaterialFieldPreservesBrushTextureWithoutBecomingSolid() throws {
        var brush = BrushSettings.stageOneDefault
        brush.size = 28
        brush.spacingPercent = 18
        let resolution = 256

        let alphaBytes = try #require(StageOneBrushPreviewRasterizer.materialFieldAlphaBytes(
            for: brush,
            resolution: resolution
        ))

        #expect(alphaBytes.count == resolution * resolution)
        let visibleCount = alphaBytes.reduce(0) { $0 + ($1 > 24 ? 1 : 0) }
        let openCount = alphaBytes.reduce(0) { $0 + ($1 < 8 ? 1 : 0) }
        #expect(visibleCount > resolution * resolution / 8)
        #expect(openCount > resolution * resolution / 8)

        let cached = try #require(StageOneBrushPreviewRasterizer.materialFieldAlphaBytes(
            for: brush,
            resolution: resolution
        ))
        #expect(cached == alphaBytes)
    }

    @Test
    func textureFillResultPreviewUsesFinalRendererAndReflectsCoverage() throws {
        var brush = BrushSettings.stageOneDefault
        brush.size = 28
        brush.spacingPercent = 18

        var lowCoverage = TextureFillTipSettings.proceduralDefault
        lowCoverage.coverage = 0.2
        var highCoverage = lowCoverage
        highCoverage.coverage = 1

        let lowImage = try #require(StageOneBrushPreviewRasterizer.textureFillPreviewImage(
            for: brush,
            tipSettings: lowCoverage,
            color: .black,
            width: 192,
            height: 84
        ))
        let highImage = try #require(StageOneBrushPreviewRasterizer.textureFillPreviewImage(
            for: brush,
            tipSettings: highCoverage,
            color: .black,
            width: 192,
            height: 84
        ))

        #expect(lowImage.width == 192)
        #expect(lowImage.height == 84)
        #expect(highImage.width == 192)
        #expect(highImage.height == 84)
        let lowAlphaSum = try alphaSum(in: lowImage)
        let highAlphaSum = try alphaSum(in: highImage)
        let fullyOpaqueAlphaSum = 192 * 84 * 255
        #expect(highAlphaSum > lowAlphaSum)
        #expect(highAlphaSum > (fullyOpaqueAlphaSum * 50 / 100))
        #expect(highAlphaSum < (fullyOpaqueAlphaSum * 85 / 100))

        var changedShape = lowCoverage
        changedShape.materialScale = 2.2
        changedShape.variation = 0.85
        let changedShapeImage = try #require(StageOneBrushPreviewRasterizer.textureFillPreviewImage(
            for: brush,
            tipSettings: changedShape,
            color: .black,
            width: 192,
            height: 84
        ))
        #expect(try pixelData(in: changedShapeImage) != pixelData(in: lowImage))

        var noisySettings = highCoverage
        noisySettings.paintJitterAmount = 0.75
        let noisyImage = try #require(StageOneBrushPreviewRasterizer.textureFillPreviewImage(
            for: brush,
            tipSettings: noisySettings,
            color: RGBAColor(red: 0.76, green: 0.22, blue: 0.12, alpha: 1),
            width: 192,
            height: 84
        ))
        var flatColorSettings = noisySettings
        flatColorSettings.paintJitterAmount = 0
        let flatColorImage = try #require(StageOneBrushPreviewRasterizer.textureFillPreviewImage(
            for: brush,
            tipSettings: flatColorSettings,
            color: RGBAColor(red: 0.76, green: 0.22, blue: 0.12, alpha: 1),
            width: 192,
            height: 84
        ))
        #expect(try pixelData(in: noisyImage) != pixelData(in: flatColorImage))

        let cachedHighImage = try #require(StageOneBrushPreviewRasterizer.textureFillPreviewImage(
            for: brush,
            tipSettings: highCoverage,
            color: .black,
            width: 192,
            height: 84
        ))
        #expect(try alphaSum(in: cachedHighImage) == alphaSum(in: highImage))
    }

    @Test
    func textureFillResultPreviewAcceptsImportedMaterial() throws {
        var settings = TextureFillTipSettings.proceduralDefault
        settings.sourceSemantic = .importedImage
        settings.customTipMaskData = makeVerticalMask(side: 32)

        let image = try #require(StageOneBrushPreviewRasterizer.textureFillPreviewImage(
            for: .stageOneDefault,
            tipSettings: settings,
            color: RGBAColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1),
            width: 192,
            height: 84
        ))

        let alpha = try alphaSum(in: image)
        #expect(alpha > 0)
        #expect(alpha < 192 * 84 * 255)

        let proceduralImage = try #require(StageOneBrushPreviewRasterizer.textureFillPreviewImage(
            for: .stageOneDefault,
            tipSettings: .proceduralDefault,
            color: RGBAColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1),
            width: 192,
            height: 84
        ))
        #expect(try pixelData(in: image) != pixelData(in: proceduralImage))
    }

    @Test
    func textureFillArrangementModesProduceDistinctSpatialFields() throws {
        var settings = TextureFillTipSettings.proceduralDefault
        settings.sourceSemantic = .importedImage
        settings.customTipMaskData = makeVerticalMask(side: 32)
        settings.coverage = 0.58
        settings.variation = 0.45

        var renderedFields = Set<Data>()
        for arrangement in TextureFillArrangement.allCases {
            settings.arrangement = arrangement
            let image = try #require(StageOneBrushPreviewRasterizer.textureFillPreviewImage(
                for: .stageOneDefault,
                tipSettings: settings,
                color: .black,
                width: 192,
                height: 84
            ))
            renderedFields.insert(try pixelData(in: image))
        }

        #expect(renderedFields.count == TextureFillArrangement.allCases.count)
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

    private func makeGrainMask(side: Int) -> Data {
        Data((0..<(side * side)).map { index in
            let x = index % side
            let y = index / side
            let hash = (x &* 73) ^ (y &* 151) ^ ((x + y) &* 37)
            return hash.isMultiple(of: 5) ? UInt8(255) : UInt8(0)
        })
    }

    private func makeFiberedMask(side: Int) -> Data {
        Data((0..<(side * side)).map { index in
            let y = index / side
            return (y / 6).isMultiple(of: 2) ? UInt8(255) : UInt8(0)
        })
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

    private func pixelData(in image: CGImage) throws -> Data {
        guard
            let provider = image.dataProvider,
            let providerData = provider.data
        else {
            throw PreviewSamplingError.missingData
        }
        return providerData as Data
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

    private func alphaCoverageRatio(
        in bytes: [UInt8],
        resolution: Int,
        xRange: ClosedRange<Int>,
        yRange: ClosedRange<Int>,
        threshold: UInt8
    ) -> Double {
        var covered = 0
        var sampled = 0
        for y in yRange where y >= 0 && y < resolution {
            for x in xRange where x >= 0 && x < resolution {
                let index = (y * resolution) + x
                guard index < bytes.count else { continue }
                sampled += 1
                if bytes[index] >= threshold {
                    covered += 1
                }
            }
        }
        return sampled > 0 ? Double(covered) / Double(sampled) : 0
    }

    private func alphaAverageRatio(
        in bytes: [UInt8],
        resolution: Int,
        xRange: ClosedRange<Int>,
        yRange: ClosedRange<Int>
    ) -> Double {
        var total = 0
        var sampled = 0
        for y in yRange where y >= 0 && y < resolution {
            for x in xRange where x >= 0 && x < resolution {
                let index = (y * resolution) + x
                guard index < bytes.count else { continue }
                sampled += 1
                total += Int(bytes[index])
            }
        }
        return sampled > 0 ? Double(total) / Double(sampled * 255) : 0
    }

    private func alphaStandardDeviationRatio(
        in bytes: [UInt8],
        resolution: Int,
        xRange: ClosedRange<Int>,
        yRange: ClosedRange<Int>
    ) -> Double {
        var values: [Double] = []
        for y in yRange where y >= 0 && y < resolution {
            for x in xRange where x >= 0 && x < resolution {
                let index = (y * resolution) + x
                guard index < bytes.count else { continue }
                values.append(Double(bytes[index]) / 255)
            }
        }
        guard !values.isEmpty else { return 0 }
        let average = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { partialResult, value in
            let delta = value - average
            return partialResult + (delta * delta)
        } / Double(values.count)
        return sqrt(variance)
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

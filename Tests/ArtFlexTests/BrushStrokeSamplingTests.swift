import Metal
import Testing
@testable import ArtFlex

struct BrushStrokeSamplingTests {
    @Test
    func startupSegmentWaitsForThirdPointAndDoesNotDuplicateLeadingStamp() throws {
        let device = MTLCreateSystemDefaultDevice()
        #expect(device != nil)
        guard let device else { return }

        let renderer = try StageOneBrushRenderer(device: device)
        var samplingState: BrushStrokeSamplingState?
        var brush = BrushSettings.stageOneDefault
        brush.size = 100
        brush.spacingPercent = 100

        let firstPacket = StrokeDescriptor(
            tool: .brush,
            color: .black,
            brush: brush,
            points: [
                StrokePoint(x: 0, y: 0, pressure: 1)
            ],
            selectionShape: nil,
            skipLeadingStamp: false
        )
        let firstSamples = renderer.debugInterpolatedStrokeSamples(
            for: firstPacket,
            samplingState: &samplingState
        )

        #expect(firstSamples.isEmpty)
        #expect(samplingState?.pendingInputPoints.count == 1)
        #expect(samplingState?.nextSampleIndex == 0)

        let secondPacket = StrokeDescriptor(
            tool: .brush,
            color: .black,
            brush: brush,
            points: [
                StrokePoint(x: 10, y: 0, pressure: 1)
            ],
            selectionShape: nil,
            skipLeadingStamp: true
        )
        let secondSamples = renderer.debugInterpolatedStrokeSamples(
            for: secondPacket,
            samplingState: &samplingState
        )

        #expect(secondSamples.count == 1)
        #expect(secondSamples.first?.point == StrokePoint(x: 0, y: 0, pressure: 1))
        #expect(samplingState?.nextSampleIndex == 1)
        #expect(samplingState?.nextSegmentIndexToCommit == 0)
        #expect(samplingState?.hasEmittedLeadingStamp == true)

        let continuationPacket = StrokeDescriptor(
            tool: .brush,
            color: .black,
            brush: brush,
            points: [
                StrokePoint(x: 20, y: 0, pressure: 1)
            ],
            selectionShape: nil,
            skipLeadingStamp: true
        )
        let continuationSamples = renderer.debugInterpolatedStrokeSamples(
            for: continuationPacket,
            samplingState: &samplingState
        )

        #expect(continuationSamples.isEmpty)
        #expect(samplingState?.nextSegmentIndexToCommit == 1)
        #expect(samplingState?.hasEmittedLeadingStamp == true)
    }

    @Test
    func flushEmitsTailForSinglePointClickStroke() throws {
        let device = MTLCreateSystemDefaultDevice()
        #expect(device != nil)
        guard let device else { return }

        let renderer = try StageOneBrushRenderer(device: device)
        var samplingState: BrushStrokeSamplingState?
        let brush = BrushSettings.stageOneDefault
        let point = StrokePoint(x: 42, y: 84, pressure: 1)

        let clickPacket = StrokeDescriptor(
            tool: .brush,
            color: .black,
            brush: brush,
            points: [point],
            selectionShape: nil,
            skipLeadingStamp: false
        )
        let clickSamples = renderer.debugInterpolatedStrokeSamples(
            for: clickPacket,
            samplingState: &samplingState
        )

        #expect(clickSamples.isEmpty)
        #expect(samplingState?.pendingInputPoints.count == 1)

        samplingState?.isFlushing = true
        let flushStroke = StrokeDescriptor(
            tool: .brush,
            color: .black,
            brush: brush,
            points: [],
            selectionShape: nil,
            skipLeadingStamp: true
        )
        let flushedSamples = renderer.debugInterpolatedStrokeSamples(
            for: flushStroke,
            samplingState: &samplingState
        )

        #expect(flushedSamples.count >= 1)
        #expect(flushedSamples.first?.point == point)
        #expect(samplingState?.pendingInputPoints.isEmpty == true)
        #expect(samplingState?.isFlushing == false)
    }

    @Test
    func sparseSinglePointPacketsRemainContinuouslySpacedAfterFlush() throws {
        let device = MTLCreateSystemDefaultDevice()
        #expect(device != nil)
        guard let device else { return }

        let renderer = try StageOneBrushRenderer(device: device)
        var samplingState: BrushStrokeSamplingState?
        var brush = BrushSettings.stageOneDefault
        brush.size = 40
        brush.spacingPercent = 5

        var samples: [StampSample] = []
        for (index, x) in stride(from: 20.0, through: 340.0, by: 32.0).enumerated() {
            let packet = StrokeDescriptor(
                tool: .brush,
                color: .black,
                brush: brush,
                points: [StrokePoint(x: x, y: 64, pressure: 1)],
                selectionShape: nil,
                skipLeadingStamp: index > 0
            )
            samples.append(contentsOf: renderer.debugInterpolatedStrokeSamples(
                for: packet,
                samplingState: &samplingState
            ))
        }

        samplingState?.isFlushing = true
        let flush = StrokeDescriptor(
            tool: .brush,
            color: .black,
            brush: brush,
            points: [],
            selectionShape: nil,
            skipLeadingStamp: true
        )
        samples.append(contentsOf: renderer.debugInterpolatedStrokeSamples(
            for: flush,
            samplingState: &samplingState
        ))

        let orderedX = samples.map(\.point.x).sorted()
        #expect(orderedX.count > 100)
        #expect(orderedX.first.map { abs($0 - 20) < 0.01 } == true)
        let maximumGap = zip(orderedX, orderedX.dropFirst())
            .map { $1 - $0 }
            .max() ?? .infinity
        #expect(maximumGap <= 2.1)
        #expect(orderedX.last.map { $0 >= 338 } == true)
    }

    @Test
    func compoundSecondaryUsesItsOwnSparseStampCadence() throws {
        let device = MTLCreateSystemDefaultDevice()
        #expect(device != nil)
        guard let device else { return }

        let renderer = try StageOneBrushRenderer(device: device)
        var brush = BrushSettings.stageOneDefault
        brush.size = 29
        brush.spacingPercent = 6
        brush.compoundBrush.enabled = true
        brush.compoundBrush.mode = .overlay
        brush.compoundBrush.secondary.sizeMode = .relativeToPrimary
        brush.compoundBrush.secondary.relativeSizeRatio = 1.5454545
        brush.compoundBrush.secondary.spacingPercent = 65

        let stroke = StrokeDescriptor(
            tool: .brush,
            color: .black,
            brush: brush,
            points: [
                StrokePoint(x: 0, y: 20, pressure: 1),
                StrokePoint(x: 120, y: 20, pressure: 1)
            ],
            selectionShape: nil
        )

        var primaryState: BrushStrokeSamplingState?
        var secondaryState: BrushStrokeSamplingState?
        var primarySamples = renderer.debugInterpolatedStrokeSamples(
            for: stroke,
            samplingState: &primaryState
        )
        var secondarySamples = renderer.debugInterpolatedCompoundSecondarySamples(
            for: stroke,
            samplingState: &secondaryState
        )

        primaryState?.isFlushing = true
        secondaryState?.isFlushing = true
        let flush = StrokeDescriptor(
            tool: .brush,
            color: .black,
            brush: brush,
            points: [],
            selectionShape: nil,
            skipLeadingStamp: true
        )
        primarySamples += renderer.debugInterpolatedStrokeSamples(
            for: flush,
            samplingState: &primaryState
        )
        secondarySamples += renderer.debugInterpolatedCompoundSecondarySamples(
            for: flush,
            samplingState: &secondaryState
        )

        let primaryGaps = zip(primarySamples, primarySamples.dropFirst()).map {
            $1.point.x - $0.point.x
        }
        let secondaryGaps = zip(secondarySamples, secondarySamples.dropFirst()).map {
            $1.point.x - $0.point.x
        }
        let primaryFullGap = primaryGaps.dropFirst().first
        let secondaryFullGap = secondaryGaps.dropFirst().first

        #expect(primarySamples.count > secondarySamples.count * 10)
        #expect(primaryFullGap.map { abs($0 - 1.74) < 0.05 } == true)
        #expect(secondaryFullGap.map { abs($0 - 29.132) < 0.1 } == true)
    }

    @Test
    func pressureDualTipSamplesRangeAAndBAtThreeIndependentCadences() throws {
        let device = MTLCreateSystemDefaultDevice()
        #expect(device != nil)
        guard let device else { return }

        let renderer = try StageOneBrushRenderer(device: device)
        var brush = BrushSettings.stageOneDefault
        brush.size = 40
        brush.spacingPercent = 5
        brush.compoundBrush.enabled = true
        brush.compoundBrush.mode = .textureBlend
        brush.materializeCompoundPrimaryTipIfNeeded()
        brush.compoundBrush.primary?.sizeMode = .relativeToPrimary
        brush.compoundBrush.primary?.relativeSizeRatio = 1
        brush.compoundBrush.primary?.spacingPercent = 20
        brush.compoundBrush.secondary.sizeMode = .relativeToPrimary
        brush.compoundBrush.secondary.relativeSizeRatio = 1
        brush.compoundBrush.secondary.spacingPercent = 75

        let stroke = StrokeDescriptor(
            tool: .brush,
            color: .black,
            brush: brush,
            points: [
                StrokePoint(x: 0, y: 20, pressure: 0.5),
                StrokePoint(x: 160, y: 20, pressure: 0.5)
            ],
            selectionShape: nil
        )

        var rangeState: BrushStrokeSamplingState?
        var primaryState: BrushStrokeSamplingState?
        var secondaryState: BrushStrokeSamplingState?
        var rangeSamples = renderer.debugInterpolatedStrokeSamples(
            for: stroke,
            samplingState: &rangeState
        )
        var primarySamples = renderer.debugInterpolatedCompoundPrimarySamples(
            for: stroke,
            samplingState: &primaryState
        )
        var secondarySamples = renderer.debugInterpolatedCompoundSecondarySamples(
            for: stroke,
            samplingState: &secondaryState
        )

        rangeState?.isFlushing = true
        primaryState?.isFlushing = true
        secondaryState?.isFlushing = true
        let flush = StrokeDescriptor(
            tool: .brush,
            color: .black,
            brush: brush,
            points: [],
            selectionShape: nil,
            skipLeadingStamp: true
        )
        rangeSamples += renderer.debugInterpolatedStrokeSamples(
            for: flush,
            samplingState: &rangeState
        )
        primarySamples += renderer.debugInterpolatedCompoundPrimarySamples(
            for: flush,
            samplingState: &primaryState
        )
        secondarySamples += renderer.debugInterpolatedCompoundSecondarySamples(
            for: flush,
            samplingState: &secondaryState
        )

        #expect(rangeSamples.count > primarySamples.count * 3)
        #expect(primarySamples.count > secondarySamples.count * 2)
        #expect(rangeSamples.count > 60)
        #expect(primarySamples.count > 15)
        #expect(secondarySamples.count >= 5)
    }
}

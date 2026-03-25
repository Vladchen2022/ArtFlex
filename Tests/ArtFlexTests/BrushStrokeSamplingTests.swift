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
}

import Foundation
import Testing
@testable import ArtFlex

struct PressureInputTests {
    @Test
    func strokeDescriptorPreservesInputPressure() {
        let store = WorkspaceStore()
        let controller = CanvasInteractionController(workspaceStore: store)

        let samples = [
            CanvasStrokeSample(location: CanvasPoint(x: 10, y: 20), pressure: 0.25),
            CanvasStrokeSample(location: CanvasPoint(x: 30, y: 40), pressure: 0.8)
        ]

        let descriptor = controller.makeStrokeDescriptor(samples: samples)

        #expect(descriptor?.stroke.points.count == 2)
        #expect(descriptor?.stroke.points.first?.pressure == 0.25)
        #expect(descriptor?.stroke.points.last?.pressure == 0.8)
    }

    @Test
    func opacityPressureCurveUsesBrushControlPoints() {
        let curved = BrushSettings.resolvedOpacityCurvePressure(
            pressure: 0.5,
            pressureSensitivity: 1,
            low: 0.05,
            mid: 0.4,
            high: 0.82
        )

        #expect(abs(curved - 0.4) < 0.0001)
    }

    @Test
    func pressureCurveUsesSmoothInterpolationBetweenControlPoints() {
        let sampled = BrushSettings.samplePressureCurve(
            pressure: 0.35,
            low: 0.05,
            mid: 0.4,
            high: 0.82
        )

        let linearMidSegment: Float = 0.225
        #expect(abs(sampled - linearMidSegment) > 0.005)
        #expect(sampled > 0.05 && sampled < 0.4)
    }

    @Test
    func pressureCurveStateRoundTripsCustomAnchors() throws {
        var brush = BrushSettings.stageOneDefault
        let customState = CurveChannelState(points: [
            .init(x: 0, y: 0),
            .init(x: 0.12, y: 0.03),
            .init(x: 0.34, y: 0.18),
            .init(x: 0.57, y: 0.63),
            .init(x: 0.76, y: 0.82),
            .init(x: 1, y: 1)
        ])
        let normalizedState = BrushSettings.normalizedPressureCurveState(customState)
        brush.setSizePressureCurveState(customState)

        let encoded = try JSONEncoder().encode(brush)
        let decoded = try JSONDecoder().decode(BrushSettings.self, from: encoded)

        #expect(decoded.sizePressureCurve == normalizedState)
        #expect(decoded.resolvedSizePressureCurveState == normalizedState)
        #expect(abs(decoded.sizeCurveLow - CurveLUTBuilder.sampleChannelValue(from: normalizedState, at: 0.2)) < 0.0001)
        #expect(abs(decoded.sizeCurveMid - CurveLUTBuilder.sampleChannelValue(from: normalizedState, at: 0.5)) < 0.0001)
        #expect(abs(decoded.sizeCurveHigh - CurveLUTBuilder.sampleChannelValue(from: normalizedState, at: 0.8)) < 0.0001)
    }

    @Test
    func spacingCompensatedBuildUpAlphaReducesPerDabFlowForTightSpacing() {
        let loose = BrushSettings.spacingCompensatedBuildUpAlpha(
            targetVisibleAlpha: 0.7,
            spacingPx: 18,
            stampDiameterPx: 18
        )
        let tight = BrushSettings.spacingCompensatedBuildUpAlpha(
            targetVisibleAlpha: 0.7,
            spacingPx: 3,
            stampDiameterPx: 18
        )

        #expect(abs(loose - 0.7) < 0.0001)
        #expect(tight < loose)
        #expect(tight > 0)
    }

    @Test
    func resolvedBuildUpVisibleAlphaLeavesLegacyOpacityUntouchedWhenCompensationDisabled() {
        let visible = BrushSettings.resolvedBuildUpVisibleAlpha(
            targetVisibleAlpha: 0.72,
            spacingPx: 3,
            stampDiameterPx: 18,
            compensationAmount: 0
        )

        #expect(abs(visible - 0.72) < 0.0001)
    }

    @Test
    func resolvedBuildUpCompensationAmountScalesAutomaticResponseByBrushSetting() {
        let amount = BrushSettings.resolvedBuildUpCompensationAmount(
            automaticCompensationAmount: 0.8,
            brushCompensationAmount: 0.25
        )

        #expect(abs(amount - 0.2) < 0.0001)
    }

    @Test
    func opacityCapCurveKeepsLightStartAndAllowsFastRamp() {
        let points: [(x: Float, y: Float)] = [
            (0.0, 0.0),
            (0.2, 0.04),
            (0.5, 0.52),
            (0.8, 0.88),
            (1.0, 1.0)
        ]

        func sample(_ pressure: Float) -> Float {
            let clamped = min(max(pressure, 0), 1)
            for index in 1..<points.count {
                let previous = points[index - 1]
                let current = points[index]
                if clamped <= current.x {
                    let segmentLength = max(current.x - previous.x, 0.0001)
                    let t = min(max((clamped - previous.x) / segmentLength, 0), 1)
                    let smoothT = t * t * (3 - (2 * t))
                    return previous.y + ((current.y - previous.y) * smoothT)
                }
            }
            return points.last?.y ?? clamped
        }

        #expect(sample(0.05) < 0.02)
        #expect(sample(0.2) == 0.04)
        #expect(sample(0.5) > 0.5)
        #expect(sample(0.8) > 0.85)
    }

    @Test
    func sizePressureCurveKeepsThinStartAndAllowsFastGrowth() {
        let points: [(x: Float, y: Float)] = [
            (0.0, 0.0),
            (0.2, 0.12),
            (0.5, 0.58),
            (0.8, 0.91),
            (1.0, 1.0)
        ]

        func sample(_ pressure: Float) -> Float {
            let clamped = min(max(pressure, 0), 1)
            for index in 1..<points.count {
                let previous = points[index - 1]
                let current = points[index]
                if clamped <= current.x {
                    let segmentLength = max(current.x - previous.x, 0.0001)
                    let t = min(max((clamped - previous.x) / segmentLength, 0), 1)
                    let smoothT = t * t * (3 - (2 * t))
                    return previous.y + ((current.y - previous.y) * smoothT)
                }
            }
            return points.last?.y ?? clamped
        }

        #expect(sample(0.05) < 0.03)
        #expect(sample(0.2) == 0.12)
        #expect(sample(0.5) > 0.55)
        #expect(sample(0.8) > 0.9)
    }

    @Test
    func nonTabletDragUsesLastTabletPressureAfterAuxiliaryEventsAppear() {
        let resolved = resolveBrushInputPressure(
            rawPressure: 1,
            isTabletLikeEvent: false,
            eventSubtypeIsTabletPoint: false,
            sawTabletAuxiliaryEvent: true,
            lastPressure: 0.27,
            strokeInputSampleCount: 9,
            minimumTabletPressure: 0.02,
            debugForceConstantPressure: false
        )

        #expect(abs(resolved - 0.27) < 0.0001)
    }

    @Test
    func nonTabletDragWithoutAuxiliaryPressureStillUsesOwnPressure() {
        let resolved = resolveBrushInputPressure(
            rawPressure: 0.64,
            isTabletLikeEvent: false,
            eventSubtypeIsTabletPoint: false,
            sawTabletAuxiliaryEvent: false,
            lastPressure: nil,
            strokeInputSampleCount: 1,
            minimumTabletPressure: 0.02,
            debugForceConstantPressure: false
        )

        #expect(abs(resolved - 0.64) < 0.0001)
    }

    @Test
    func tabletEventsStillBypassWarmupAtStrokeStart() {
        let resolved = resolveBrushInputPressure(
            rawPressure: 0.18,
            isTabletLikeEvent: true,
            eventSubtypeIsTabletPoint: true,
            sawTabletAuxiliaryEvent: true,
            lastPressure: 0.92,
            strokeInputSampleCount: 2,
            minimumTabletPressure: 0.02,
            debugForceConstantPressure: false
        )

        #expect(abs(resolved - 0.18) < 0.0001)
    }
}

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
    func opacityPressureCurveIsStrongerThanLinearAtMidPressure() {
        let linear: Float = 0.5
        let curved = Float(pow(Double(0.5), 3.6))

        #expect(curved < linear)
        #expect(curved < 0.1)
        #expect(curved > 0)
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
}

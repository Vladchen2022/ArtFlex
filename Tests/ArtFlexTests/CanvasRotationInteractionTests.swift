import Testing
@testable import ArtFlex

struct CanvasRotationInteractionTests {
    @Test
    func rotationSensitivityUsesAStableCenterDeadZoneAndUpperBound() {
        #expect(canvasRotationDragSensitivity(startDistanceFromCenter: 0) == 0)
        #expect(canvasRotationDragSensitivity(startDistanceFromCenter: 24) == 0)
        #expect(abs(canvasRotationDragSensitivity(startDistanceFromCenter: 40) - (16.0 / 300.0)) < 0.000_001)
        #expect(abs(canvasRotationDragSensitivity(startDistanceFromCenter: 100) - (76.0 / 300.0)) < 0.000_001)
        #expect(canvasRotationDragSensitivity(startDistanceFromCenter: 500) == 0.65)
    }

    @Test
    func smallMovementNearTheCenterProducesOnlyASmallRotation() {
        let delta = canvasRotationDragDeltaDegrees(
            startAngleDegrees: 0,
            currentAngleDegrees: 20,
            startDistanceFromCenter: 40
        )

        #expect(delta > 1.0)
        #expect(delta < 1.1)
    }

    @Test
    func angleWrapUsesTheShortestDirectionInsteadOfJumpingAcrossFullCircle() {
        let clockwiseDelta = canvasRotationDragDeltaDegrees(
            startAngleDegrees: 179,
            currentAngleDegrees: -179,
            startDistanceFromCenter: 500
        )
        let counterclockwiseDelta = canvasRotationDragDeltaDegrees(
            startAngleDegrees: -179,
            currentAngleDegrees: 179,
            startDistanceFromCenter: 500
        )

        #expect(abs(clockwiseDelta - 1.3) < 0.000_001)
        #expect(abs(counterclockwiseDelta + 1.3) < 0.000_001)
    }

    @Test
    func incrementalAngleDeltasPreserveContinuousRotationAcrossBoundary() {
        let angles = [0.0, 90.0, 179.0, -90.0, 0.0]
        let accumulated = zip(angles, angles.dropFirst()).reduce(0.0) { partial, pair in
            partial + canvasRotationDragDeltaDegrees(
                startAngleDegrees: pair.0,
                currentAngleDegrees: pair.1,
                startDistanceFromCenter: 500
            )
        }

        #expect(abs(accumulated - 234) < 0.000_001)
    }
}

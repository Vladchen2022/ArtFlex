import Testing
@testable import ArtFlex

struct CurveAdjustmentDomainTests {
    @Test
    func channelStateAllowsMovableEndpointsWhileKeepingMonotonicOrder() {
        let state = CurveChannelState(points: [
            .init(x: 0.86, y: 0.92),
            .init(x: 0.34, y: 0.48),
            .init(x: 0.12, y: 0.18)
        ])

        #expect(state.points.first == .init(x: 0.12, y: 0.18))
        #expect(state.points.last == .init(x: 0.86, y: 0.92))
        #expect(state.points[1].x >= state.points[0].x)
        #expect(state.points[2].x >= state.points[1].x)
        #expect(state.points[1].y >= state.points[0].y)
        #expect(state.points[2].y >= state.points[1].y)
    }

    @Test
    func insertingMovingEndpointsAndRemovingIntermediatePointsWorks() {
        let initial = CurveChannelState(points: [
            .init(x: 0.12, y: 0.14),
            .init(x: 0.88, y: 0.94)
        ])
        let insertion = try! #require(initial.insertingPoint(.init(x: 0.5, y: 0.75)))
        #expect(insertion.state.points.count == 3)
        #expect(insertion.insertedIndex == 1)

        let movedBlackPoint = insertion.state.movingPoint(at: 0, to: .init(x: 0.2, y: 0.22))
        #expect(movedBlackPoint.points[0] == .init(x: 0.2, y: 0.22))

        let movedWhitePoint = movedBlackPoint.movingPoint(at: 2, to: .init(x: 0.82, y: 0.9))
        #expect(movedWhitePoint.points[2] == .init(x: 0.82, y: 0.9))

        let moved = movedWhitePoint.movingPoint(at: 1, to: .init(x: 0.7, y: 0.6))
        #expect(moved.points[1].x == 0.7)
        #expect(moved.points[1].y == 0.6)

        let removed = moved.removingPoint(at: 1)
        #expect(removed.points == [
            .init(x: 0.2, y: 0.22),
            .init(x: 0.82, y: 0.9)
        ])
    }

    @Test
    func parametersMaintainIndependentChannelCurvesAndReset() {
        var parameters = CurveAdjustmentParameters.neutral
        parameters.selectedChannel = .red
        parameters.setState(
            CurveChannelState(points: [
                .init(x: 0, y: 0),
                .init(x: 0.4, y: 0.8),
                .init(x: 1, y: 1)
            ]),
            for: .red
        )

        #expect(parameters.redCurve.isIdentity == false)
        #expect(parameters.greenCurve.isIdentity)
        #expect(parameters.isNeutral == false)

        parameters.resetAll()

        #expect(parameters == .neutral)
    }

    @Test
    func lutBuilderReturnsIdentityAndMovedEndpointVariants() {
        let identity = CurveLUTBuilder.buildAll(from: .neutral)
        #expect(identity.composite[0] == 0)
        #expect(identity.composite[255] == 1)
        #expect(identity.red[128] > 0.49 && identity.red[128] < 0.51)

        var parameters = CurveAdjustmentParameters.neutral
        parameters.setState(
            CurveChannelState(points: [
                .init(x: 0.2, y: 0.1),
                .init(x: 0.5, y: 0.25),
                .init(x: 0.82, y: 0.9)
            ]),
            for: .rgb
        )

        let curved = CurveLUTBuilder.buildAll(from: parameters)
        #expect(abs(curved.composite[0] - 0.1) < 0.0001)
        #expect(curved.composite[128] < identity.composite[128])
        #expect(abs(curved.composite[255] - 0.9) < 0.0001)
        #expect(curved.red == identity.red)
    }

    @Test
    func lutBuilderUsesSmoothMonotoneInterpolationInsteadOfPiecewiseLinearSegments() {
        let state = CurveChannelState(points: [
            .init(x: 0.2, y: 0.1),
            .init(x: 0.5, y: 0.25),
            .init(x: 0.82, y: 0.9)
        ])

        let sampled = CurveLUTBuilder.sampleChannelValue(from: state, at: 0.35)
        let linearBetweenFirstTwoPoints: Float = 0.175

        #expect(abs(sampled - linearBetweenFirstTwoPoints) > 0.005)
        #expect(sampled > 0.1 && sampled < 0.25)
    }
}

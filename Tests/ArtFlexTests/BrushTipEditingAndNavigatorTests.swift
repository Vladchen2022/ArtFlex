import Foundation
import Testing
@testable import ArtFlex

struct BrushTipEditingAndNavigatorTests {
    @Test
    func brushTipDraftHistorySupportsBoundedUndoRedoAndBranching() {
        let baseline = BrushTipDraftSnapshot.procedural
        let first = BrushTipDraftSnapshot(
            maskData: Data([1]),
            sourceSemantic: .customMask,
            assetID: nil,
            sourceInfo: nil
        )
        let second = BrushTipDraftSnapshot(
            maskData: Data([2]),
            sourceSemantic: .customMask,
            assetID: nil,
            sourceInfo: nil
        )
        var history = BrushTipDraftHistory(capacity: 2)

        history.record(current: baseline, next: first)
        history.record(current: first, next: second)
        #expect(history.canUndo)
        #expect(history.undo(current: second) == first)
        #expect(history.canRedo)
        #expect(history.redo(current: first) == second)

        _ = history.undo(current: second)
        history.record(current: first, next: baseline)
        #expect(!history.canRedo)
    }

    @Test
    func logarithmicNavigatorZoomRoundTripsRepresentativeValues() {
        for percent in [5.0, 25, 100, 400, 3200] {
            let position = NavigatorZoomMapping.sliderPosition(for: percent)
            let restored = NavigatorZoomMapping.percent(forSliderPosition: position)
            #expect(abs(restored - percent) < 0.000_001)
        }
        #expect(NavigatorZoomMapping.sliderPosition(for: 5) == 0)
        #expect(abs(NavigatorZoomMapping.sliderPosition(for: 3200) - 1) < 0.000_001)
    }

    @Test
    func navigatorPolygonClipsEdgesWithoutCollapsingRotatedCorners() {
        let clipped = NavigatorGeometry.clippedCanvasPolygon(
            [
                .init(x: -20, y: 30),
                .init(x: 40, y: -20),
                .init(x: 120, y: 60),
                .init(x: 40, y: 120)
            ],
            canvasSize: .init(width: 100, height: 100)
        )

        #expect(clipped.count >= 4)
        #expect(clipped.allSatisfy { $0.x >= 0 && $0.x <= 100 && $0.y >= 0 && $0.y <= 100 })
        #expect(clipped.contains { abs($0.x) < 0.000_001 })
        #expect(clipped.contains { abs($0.y) < 0.000_001 })
        #expect(clipped.contains { abs($0.x - 100) < 0.000_001 })
        #expect(clipped.contains { abs($0.y - 100) < 0.000_001 })
    }

    @Test
    func navigatorPolygonReturnsEmptyWhenViewportMissesCanvas() {
        let clipped = NavigatorGeometry.clippedCanvasPolygon(
            [
                .init(x: -100, y: -100),
                .init(x: -20, y: -100),
                .init(x: -20, y: -20),
                .init(x: -100, y: -20)
            ],
            canvasSize: .init(width: 100, height: 100)
        )
        #expect(clipped.isEmpty)
    }
}

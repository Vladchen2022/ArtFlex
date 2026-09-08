import Foundation
import Testing
@testable import ArtFlex

struct InspectorSplitLayoutTests {
    @Test func shortParametersYieldUnusedSpaceToLayers() {
        let layout = InspectorSplitLayout(availableHeight: 620, contentHeight: 90, preferredHeight: 340)
        #expect(layout.parameterHeight == 90)
        #expect(layout.layerHeight == 512)
    }

    @Test func tallParametersCannotSqueezeOutLayers() {
        for height in stride(from: 420.0, through: 1200.0, by: 20) {
            let layout = InspectorSplitLayout(availableHeight: height, contentHeight: 1800, preferredHeight: 2000)
            #expect(layout.layerHeight >= InspectorSplitLayout.minimumLayerHeight)
            #expect(layout.parameterHeight + layout.layerHeight + InspectorSplitLayout.dividerHeight == CGFloat(height))
        }
    }

    @Test func shrinkingDoesNotDestroyLargeWindowPreference() {
        let savedHeight = 390.0
        let small = InspectorSplitLayout(availableHeight: 440, contentHeight: 700, preferredHeight: savedHeight)
        let large = InspectorSplitLayout(availableHeight: 850, contentHeight: 700, preferredHeight: savedHeight)
        #expect(small.parameterHeight < CGFloat(savedHeight))
        #expect(large.parameterHeight == CGFloat(savedHeight))
    }

    @Test func draggingAndAccessibilityRespectBothLimits() {
        let layout = InspectorSplitLayout(availableHeight: 600, contentHeight: 800, preferredHeight: 0)
        #expect(layout.constrainedHeight(-100) == layout.parameterRange.lowerBound)
        #expect(layout.constrainedHeight(5000) == layout.parameterRange.upperBound)
        #expect(layout.constrainedHeight(.nan) == layout.parameterHeight)
    }

    @Test func invalidAndTransientGeometryNeverProducesNegativeOrNonfiniteFrames() {
        for height in [-100.0, 0, 1, 15, 80, Double.nan, Double.infinity] {
            let layout = InspectorSplitLayout(availableHeight: height, contentHeight: .nan, preferredHeight: .infinity)
            #expect(layout.parameterHeight.isFinite && layout.parameterHeight >= 0)
            #expect(layout.layerHeight.isFinite && layout.layerHeight >= 0)
        }
    }

    @Test func previewYieldsSpaceInShortWindowsAndRemainsBounded() {
        #expect(InspectorSplitLayout.previewPanelHeight(contentHeight: 600) == 160)
        #expect(InspectorSplitLayout.previewPanelHeight(contentHeight: 900) == 264)
        #expect(InspectorSplitLayout.previewPanelHeight(contentHeight: .nan) == 264)
        #expect(InspectorSplitLayout.previewPanelHeight(contentHeight: -100) == 160)
    }

    @Test func everySupportedWindowHeightLeavesUsefulLayerSpace() {
        // Minimum window: 700 points, less title/tool/status bars and padding.
        for contentHeight in stride(from: 590.0, through: 1500.0, by: 10) {
            let top = InspectorSplitLayout.previewPanelHeight(contentHeight: contentHeight)
            let layout = InspectorSplitLayout(availableHeight: contentHeight - top - 12,
                                              contentHeight: 1400, preferredHeight: 5000)
            #expect(layout.layerHeight >= 264)
            #expect(layout.parameterHeight >= 120)
        }
    }
}

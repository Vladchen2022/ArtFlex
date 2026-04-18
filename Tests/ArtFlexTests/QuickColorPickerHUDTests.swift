import Testing
@testable import ArtFlex

struct QuickColorPickerHUDTests {
    @Test
    func steppedSliderGuardRejectsDegenerateRanges() {
        #expect(quickColorPickerCanUseSteppedSlider(range: 1...1, step: 1) == false)
        #expect(quickColorPickerCanUseSteppedSlider(range: 0...0, step: 0.01) == false)
        #expect(quickColorPickerCanUseSteppedSlider(range: 1...4, step: 1) == true)
        #expect(quickColorPickerCanUseSteppedSlider(range: 0...1, step: 0.01) == true)
        #expect(quickColorPickerCanUseSteppedSlider(range: 0...1, step: 0) == false)
    }
}

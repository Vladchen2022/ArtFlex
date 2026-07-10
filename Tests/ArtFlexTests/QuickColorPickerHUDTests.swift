import Foundation
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

    @Test
    func svImageBuilderMatchesPickerColorReference() throws {
        var panel = ColorPanelState.stageOneDefault
        panel.pickerHue = 217
        panel.pickerLightness = 67
        panel.pickerSaturation = 73
        panel.lightingHue = 28
        panel.lightingStrength = 42
        let size = 9

        let image = try #require(makeColorPickerSVImage(size: size, panel: panel))
        let providerData = try #require(image.dataProvider?.data)
        let actualBytes = [UInt8](providerData as Data)
        var expectedBytes: [UInt8] = []
        expectedBytes.reserveCapacity(size * size * 4)

        for y in 0..<size {
            for x in 0..<size {
                var samplePanel = panel
                samplePanel.pickerX = Float(x) / Float(size - 1)
                samplePanel.pickerY = Float(y) / Float(size - 1)
                let color = ColorBlocksEngine.pickerColor(from: samplePanel)
                expectedBytes.append(UInt8(clamping: Int((color.red * 255).rounded())))
                expectedBytes.append(UInt8(clamping: Int((color.green * 255).rounded())))
                expectedBytes.append(UInt8(clamping: Int((color.blue * 255).rounded())))
                expectedBytes.append(255)
            }
        }

        #expect(actualBytes == expectedBytes)
    }

    @Test
    func svImageBuilderHonorsCancellation() {
        let image = makeColorPickerSVImage(
            size: 288,
            panel: .stageOneDefault,
            shouldCancel: { true }
        )
        #expect(image == nil)
    }
}

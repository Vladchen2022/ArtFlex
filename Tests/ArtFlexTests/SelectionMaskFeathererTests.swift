import Foundation
import Testing
@testable import ArtFlex

struct SelectionMaskFeathererTests {
    @Test
    func tentFeatherCreatesPartialAlphaOutsideAHardSelection() throws {
        let width = 17
        let height = 17
        var source = [UInt8](repeating: 0, count: width * height)
        for y in 4...12 {
            for x in 4...12 {
                source[(y * width) + x] = 255
            }
        }

        let result = try VImageSelectionMaskFeatherer.feather(
            alphaBytes: Data(source),
            width: width,
            height: height,
            radiusPixels: 3
        )
        let bytes = [UInt8](result)

        #expect(bytes[(8 * width) + 8] == 255)
        #expect(bytes[(8 * width) + 2] > 0)
        #expect(bytes[(8 * width) + 2] < 255)
        #expect(bytes[(8 * width)] == 0)
        #expect(bytes[(8 * width) + 16] == 0)
    }

    @Test
    func zeroRadiusPreservesTheOriginalMask() throws {
        let source = Data([0, 64, 128, 255])
        let result = try VImageSelectionMaskFeatherer.feather(
            alphaBytes: source,
            width: 2,
            height: 2,
            radiusPixels: 0
        )
        #expect(result == source)
    }
}

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

    @Test
    func featherFallsToZeroBeforeTheAllocatedBoundary() throws {
        let width = 33
        let height = 33
        let radius = 8
        var source = [UInt8](repeating: 0, count: width * height)
        for y in 8..<25 {
            for x in 8..<25 {
                source[(y * width) + x] = 255
            }
        }

        let result = [UInt8](try VImageSelectionMaskFeatherer.feather(
            alphaBytes: Data(source),
            width: width,
            height: height,
            radiusPixels: radius
        ))
        let centerRow = Array(result[(16 * width)..<(17 * width)])

        #expect(centerRow[0] == 0)
        #expect(centerRow[width - 1] == 0)
        #expect(centerRow[1] <= 2)
        #expect(centerRow[2] > centerRow[1])
        #expect(centerRow[8] > centerRow[7])
        #expect(centerRow[16] >= 250)
    }
}

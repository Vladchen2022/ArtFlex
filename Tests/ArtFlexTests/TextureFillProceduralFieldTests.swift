import Foundation
import Testing
@testable import ArtFlex

struct TextureFillProceduralFieldTests {
    @Test
    func sameRawPathAndSameSeedProduceDeterministicTextureField() {
        let mask = Data(repeating: 255, count: 32 * 32)
        let anchor = CanvasPoint(x: 4, y: 4)
        let previous = CanvasPoint(x: 24, y: 8)
        let current = CanvasPoint(x: 28, y: 24)
        let seed = TextureFillProceduralField.sessionSeed(anchorPoint: anchor)

        let first = TextureFillProceduralField.alphaBytes(
            baseMaskOriginX: 0,
            baseMaskOriginY: 0,
            width: 32,
            height: 32,
            baseMaskAlphaBytes: mask,
            anchorPoint: anchor,
            previousEdgePoint: previous,
            currentEdgePoint: current,
            sessionSeed: seed
        )
        let second = TextureFillProceduralField.alphaBytes(
            baseMaskOriginX: 0,
            baseMaskOriginY: 0,
            width: 32,
            height: 32,
            baseMaskAlphaBytes: mask,
            anchorPoint: anchor,
            previousEdgePoint: previous,
            currentEdgePoint: current,
            sessionSeed: seed
        )

        #expect(first == second)
    }
}

import Testing
@testable import ArtFlex

struct GeneratorRegionRasterizerTests {
    private let width = 96
    private let height = 80

    @Test
    func everyGeneratorProducesDeterministicVisiblePixels() {
        var digests: Set<UInt64> = []

        for kind in GeneratorKind.allCases {
            let first = render(kind: kind)
            let second = render(kind: kind)

            #expect(first.bytes == second.bytes)
            #expect(first.summary.primitiveCount > 0)
            #expect(first.summary.touchedPixelCount > 0)
            digests.insert(digest(first.bytes))
        }

        #expect(digests.count == GeneratorKind.allCases.count)
    }

    @Test
    func generatorsNeverPaintOutsideCommittedSelection() {
        let selection = SelectionShape(
            kind: .ellipse,
            bounds: CanvasRect(
                origin: CanvasPoint(x: 19, y: 13),
                size: CanvasPoint(x: 48, y: 42)
            ),
            pathPoints: []
        )

        for kind in GeneratorKind.allCases {
            let output = render(kind: kind, selection: selection)
            var paintedInside = false
            for y in 0..<height {
                for x in 0..<width {
                    let alpha = output.bytes[(y * width * 4) + (x * 4) + 3]
                    if selection.contains(CanvasPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
                        paintedInside = paintedInside || alpha > 0
                    } else {
                        #expect(alpha == 0)
                    }
                }
            }
            #expect(paintedInside)
        }
    }

    @Test
    func currentColorAndGeneratorOpacityAffectOutput() {
        let low = render(
            kind: .elasticWhip,
            color: RGBAColor(red: 0.9, green: 0.12, blue: 0.05, alpha: 1),
            opacity: 0.2
        )
        let high = render(
            kind: .elasticWhip,
            color: RGBAColor(red: 0.9, green: 0.12, blue: 0.05, alpha: 1),
            opacity: 1
        )

        let lowAlpha = stride(from: 3, to: low.bytes.count, by: 4).reduce(0) { $0 + Int(low.bytes[$1]) }
        let highAlpha = stride(from: 3, to: high.bytes.count, by: 4).reduce(0) { $0 + Int(high.bytes[$1]) }
        #expect(highAlpha > lowAlpha)

        let paintedPixel = stride(from: 0, to: high.bytes.count, by: 4).first { high.bytes[$0 + 3] > 0 }
        #expect(paintedPixel != nil)
        if let paintedPixel {
            #expect(high.bytes[paintedPixel + 2] > high.bytes[paintedPixel])
            #expect(high.bytes[paintedPixel + 2] > high.bytes[paintedPixel + 1])
        }
    }

    private func render(
        kind: GeneratorKind,
        selection: SelectionShape? = nil,
        color: RGBAColor = RGBAColor(red: 0.28, green: 0.62, blue: 0.88, alpha: 1),
        opacity: Float = 0.78
    ) -> (bytes: [UInt8], summary: GeneratorRasterSummary) {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let settings = GeneratorSettings(
            kind: kind,
            density: 0.62,
            drift: 0.57,
            branch: 0.48,
            opacity: opacity
        )
        let summary = GeneratorRegionRasterizer.apply(
            settings: settings,
            color: color,
            targetShape: selection,
            originX: 0,
            originY: 0,
            width: width,
            height: height,
            bytesPerRow: width * 4,
            bytes: &bytes
        )
        return (bytes, summary)
    }

    private func digest(_ bytes: [UInt8]) -> UInt64 {
        bytes.reduce(0xCBF2_9CE4_8422_2325) { hash, byte in
            (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
    }
}

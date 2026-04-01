import Testing
@testable import ArtFlex

struct ClosedPolygonMaskRasterizerTests {
    @Test
    func rasterizedClosedPolygonMaskUsesAntialiasedEdgeValues() {
        let bytes = rasterizedClosedPolygonMaskBytes(
            points: [
                .init(x: 1.2, y: 1.2),
                .init(x: 18.4, y: 3.1),
                .init(x: 4.6, y: 18.7)
            ],
            originX: 0,
            originY: 0,
            width: 24,
            height: 24
        )

        #expect(bytes.contains { $0 > 0 && $0 < 255 })
    }
}

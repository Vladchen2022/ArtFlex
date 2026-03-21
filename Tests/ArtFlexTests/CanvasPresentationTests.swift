import Foundation
import Testing
@testable import ArtFlex

struct CanvasPresentationTests {
    @Test
    func viewportDecodesLegacyPayloadWithoutRotationDegrees() throws {
        let data = Data("""
        {
          "zoomScale": 1.5,
          "contentOffset": {
            "x": 12,
            "y": -8
          }
        }
        """.utf8)

        let viewport = try JSONDecoder().decode(CanvasViewport.self, from: data)

        #expect(viewport.zoomScale == 1.5)
        #expect(viewport.contentOffset == CanvasPoint(x: 12, y: -8))
        #expect(viewport.rotationDegrees == 0)
    }

    @Test
    func presentationCentersDocumentWhenViewportOffsetIsZero() {
        let presentation = CanvasPresentationBuilder.makePresentation(
            canvasSize: CanvasSize(width: 1000, height: 1000),
            viewport: .stageOneDefault,
            availableWidth: 1200,
            availableHeight: 1000
        )

        #expect(presentation.documentDisplaySize.x == 904)
        #expect(presentation.documentDisplaySize.y == 904)
        #expect(presentation.documentOrigin.x == 148)
        #expect(presentation.documentOrigin.y == 48)
    }

    @Test
    func presentationAppliesViewportOffsetOnTopOfCentering() {
        let viewport = CanvasViewport(
            zoomScale: 1,
            contentOffset: CanvasPoint(x: 25, y: -10)
        )

        let presentation = CanvasPresentationBuilder.makePresentation(
            canvasSize: CanvasSize(width: 1000, height: 1000),
            viewport: viewport,
            availableWidth: 1200,
            availableHeight: 1000
        )

        #expect(presentation.documentOrigin.x == 173)
        #expect(presentation.documentOrigin.y == 38)
    }
}

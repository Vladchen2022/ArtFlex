import Foundation
import Testing
@testable import ArtFlex

struct TileGridTests {
    @Test
    func defaultGridCoversPartialEdgeTiles() throws {
        let grid = try #require(TileGrid(canvasSize: CanvasSize(width: 1_025, height: 700)))

        #expect(grid.tileLength == 512)
        #expect(grid.tileCountX == 3)
        #expect(grid.tileCountY == 2)
        #expect(grid.tileCount == 6)
        #expect(
            grid.bounds(for: .init(x: 2, y: 1)) ==
                PixelRegion(originX: 1_024, originY: 512, width: 1, height: 188)
        )
        #expect(grid.bounds(for: .init(x: 3, y: 1)) == nil)
    }

    @Test
    func pixelLocationsUseHalfOpenTileBoundaries() throws {
        let grid = try #require(TileGrid(canvasSize: CanvasSize(width: 1_025, height: 700)))

        #expect(grid.location(ofCanvasX: 511, canvasY: 511) == .init(
            tile: .init(x: 0, y: 0),
            localX: 511,
            localY: 511
        ))
        #expect(grid.location(ofCanvasX: 512, canvasY: 512) == .init(
            tile: .init(x: 1, y: 1),
            localX: 0,
            localY: 0
        ))
        #expect(grid.location(ofCanvasX: 1_024, canvasY: 699) == .init(
            tile: .init(x: 2, y: 1),
            localX: 0,
            localY: 187
        ))
        #expect(grid.location(ofCanvasX: -1, canvasY: 0) == nil)
        #expect(grid.location(ofCanvasX: 1_025, canvasY: 0) == nil)
    }

    @Test
    func crossTileIntersectionReturnsCanvasAndLocalRegions() throws {
        let grid = try #require(TileGrid(canvasSize: CanvasSize(width: 1_024, height: 1_024)))
        let intersections = grid.intersections(
            with: PixelRegion(originX: 500, originY: 500, width: 40, height: 30)
        )

        #expect(intersections.map(\.tile) == [
            .init(x: 0, y: 0),
            .init(x: 1, y: 0),
            .init(x: 0, y: 1),
            .init(x: 1, y: 1)
        ])
        #expect(intersections[0].canvasRegion == .init(originX: 500, originY: 500, width: 12, height: 12))
        #expect(intersections[0].localRegion == .init(originX: 500, originY: 500, width: 12, height: 12))
        #expect(intersections[1].localRegion == .init(originX: 0, originY: 500, width: 28, height: 12))
        #expect(intersections[2].localRegion == .init(originX: 500, originY: 0, width: 12, height: 18))
        #expect(intersections[3].localRegion == .init(originX: 0, originY: 0, width: 28, height: 18))
    }

    @Test
    func intersectionClampsToCanvasAndRejectsEmptyRegions() throws {
        let grid = try #require(TileGrid(canvasSize: CanvasSize(width: 700, height: 700)))

        let clipped = grid.intersections(
            with: PixelRegion(originX: -20, originY: 680, width: 60, height: 50)
        )
        #expect(clipped.count == 1)
        #expect(clipped[0].tile == .init(x: 0, y: 1))
        #expect(clipped[0].canvasRegion == .init(originX: 0, originY: 680, width: 40, height: 20))
        #expect(clipped[0].localRegion == .init(originX: 0, originY: 168, width: 40, height: 20))

        #expect(grid.coordinates(intersecting: .init(originX: 800, originY: 0, width: 10, height: 10)).isEmpty)
        #expect(grid.coordinates(intersecting: .init(originX: 0, originY: 0, width: 0, height: 10)).isEmpty)
    }

    @Test
    func gridRoundTripsAndRejectsInvalidEncodedGeometry() throws {
        let grid = try #require(TileGrid(canvasSize: CanvasSize(width: 2_048, height: 1_536), tileLength: 256))
        let encoded = try JSONEncoder().encode(grid)
        #expect(try JSONDecoder().decode(TileGrid.self, from: encoded) == grid)

        let invalid = Data(#"{"canvasSize":{"width":100,"height":100},"tileLength":0}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TileGrid.self, from: invalid)
        }
    }
}

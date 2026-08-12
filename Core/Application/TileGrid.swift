import Foundation

/// An integer pixel rectangle using half-open bounds: `[origin, max)`.
struct PixelRegion: Codable, Hashable, Sendable, Equatable {
    var originX: Int
    var originY: Int
    var width: Int
    var height: Int

    var isEmpty: Bool {
        width <= 0 || height <= 0
    }

    var maxX: Int {
        Self.addingWithoutTrapping(originX, width)
    }

    var maxY: Int {
        Self.addingWithoutTrapping(originY, height)
    }

    func contains(pixelX: Int, pixelY: Int) -> Bool {
        !isEmpty &&
            pixelX >= originX && pixelX < maxX &&
            pixelY >= originY && pixelY < maxY
    }

    func intersection(with other: PixelRegion) -> PixelRegion? {
        guard !isEmpty, !other.isEmpty else { return nil }

        let intersectionMinX = max(originX, other.originX)
        let intersectionMinY = max(originY, other.originY)
        let intersectionMaxX = min(maxX, other.maxX)
        let intersectionMaxY = min(maxY, other.maxY)
        guard intersectionMinX < intersectionMaxX, intersectionMinY < intersectionMaxY else {
            return nil
        }

        return PixelRegion(
            originX: intersectionMinX,
            originY: intersectionMinY,
            width: intersectionMaxX - intersectionMinX,
            height: intersectionMaxY - intersectionMinY
        )
    }

    func translatedBy(x: Int, y: Int) -> PixelRegion {
        PixelRegion(
            originX: Self.addingWithoutTrapping(originX, x),
            originY: Self.addingWithoutTrapping(originY, y),
            width: width,
            height: height
        )
    }

    static func canvasBounds(for canvasSize: CanvasSize) -> PixelRegion? {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        return PixelRegion(originX: 0, originY: 0, width: canvasSize.width, height: canvasSize.height)
    }

    private static func addingWithoutTrapping(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard overflow else { return value }
        return rhs >= 0 ? Int.max : Int.min
    }
}

struct TileCoordinate: Codable, Hashable, Sendable, Equatable {
    var x: Int
    var y: Int
}

struct TilePixelLocation: Codable, Hashable, Sendable, Equatable {
    var tile: TileCoordinate
    var localX: Int
    var localY: Int
}

struct TileRegionIntersection: Codable, Hashable, Sendable, Equatable {
    var tile: TileCoordinate
    var canvasRegion: PixelRegion
    var localRegion: PixelRegion
}

/// Pure geometry for a fixed-size tile grid. It does not allocate or own pixel resources.
struct TileGrid: Codable, Sendable, Equatable {
    static let defaultTileLength = 512

    let canvasSize: CanvasSize
    let tileLength: Int

    init?(canvasSize: CanvasSize, tileLength: Int = TileGrid.defaultTileLength) {
        guard canvasSize.width > 0, canvasSize.height > 0, tileLength > 0 else {
            return nil
        }
        self.canvasSize = canvasSize
        self.tileLength = tileLength
    }

    var tileCountX: Int {
        Self.ceilingDivision(canvasSize.width, by: tileLength)
    }

    var tileCountY: Int {
        Self.ceilingDivision(canvasSize.height, by: tileLength)
    }

    var tileCount: Int {
        let (count, overflow) = tileCountX.multipliedReportingOverflow(by: tileCountY)
        return overflow ? Int.max : count
    }

    var canvasBounds: PixelRegion {
        PixelRegion(originX: 0, originY: 0, width: canvasSize.width, height: canvasSize.height)
    }

    func contains(_ coordinate: TileCoordinate) -> Bool {
        coordinate.x >= 0 && coordinate.x < tileCountX &&
            coordinate.y >= 0 && coordinate.y < tileCountY
    }

    func coordinate(containingCanvasX canvasX: Int, canvasY: Int) -> TileCoordinate? {
        guard canvasBounds.contains(pixelX: canvasX, pixelY: canvasY) else { return nil }
        return TileCoordinate(x: canvasX / tileLength, y: canvasY / tileLength)
    }

    func bounds(for coordinate: TileCoordinate) -> PixelRegion? {
        guard contains(coordinate) else { return nil }
        let originX = coordinate.x * tileLength
        let originY = coordinate.y * tileLength
        return PixelRegion(
            originX: originX,
            originY: originY,
            width: min(tileLength, canvasSize.width - originX),
            height: min(tileLength, canvasSize.height - originY)
        )
    }

    func location(ofCanvasX canvasX: Int, canvasY: Int) -> TilePixelLocation? {
        guard let tile = coordinate(containingCanvasX: canvasX, canvasY: canvasY),
              let tileBounds = bounds(for: tile) else {
            return nil
        }
        return TilePixelLocation(
            tile: tile,
            localX: canvasX - tileBounds.originX,
            localY: canvasY - tileBounds.originY
        )
    }

    /// Returns intersecting coordinates in deterministic row-major order.
    func coordinates(intersecting region: PixelRegion) -> [TileCoordinate] {
        intersections(with: region).map(\.tile)
    }

    /// Returns canvas-space and tile-local intersections in deterministic row-major order.
    func intersections(with region: PixelRegion) -> [TileRegionIntersection] {
        guard let clippedRegion = canvasBounds.intersection(with: region) else { return [] }

        let firstTileX = clippedRegion.originX / tileLength
        let firstTileY = clippedRegion.originY / tileLength
        let lastTileX = (clippedRegion.maxX - 1) / tileLength
        let lastTileY = (clippedRegion.maxY - 1) / tileLength

        var result: [TileRegionIntersection] = []
        result.reserveCapacity((lastTileX - firstTileX + 1) * (lastTileY - firstTileY + 1))

        for tileY in firstTileY...lastTileY {
            for tileX in firstTileX...lastTileX {
                let tile = TileCoordinate(x: tileX, y: tileY)
                guard let tileBounds = bounds(for: tile),
                      let canvasIntersection = tileBounds.intersection(with: clippedRegion) else {
                    continue
                }
                let localIntersection = canvasIntersection.translatedBy(
                    x: -tileBounds.originX,
                    y: -tileBounds.originY
                )
                result.append(
                    TileRegionIntersection(
                        tile: tile,
                        canvasRegion: canvasIntersection,
                        localRegion: localIntersection
                    )
                )
            }
        }
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case canvasSize
        case tileLength
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let canvasSize = try container.decode(CanvasSize.self, forKey: .canvasSize)
        let tileLength = try container.decode(Int.self, forKey: .tileLength)
        guard let validated = TileGrid(canvasSize: canvasSize, tileLength: tileLength) else {
            throw DecodingError.dataCorruptedError(
                forKey: .tileLength,
                in: container,
                debugDescription: "Tile grid requires positive canvas dimensions and tile length."
            )
        }
        self = validated
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(canvasSize, forKey: .canvasSize)
        try container.encode(tileLength, forKey: .tileLength)
    }

    private static func ceilingDivision(_ value: Int, by divisor: Int) -> Int {
        let quotient = value / divisor
        return value.isMultiple(of: divisor) ? quotient : quotient + 1
    }
}

import Foundation

enum NavigatorZoomMapping {
    static let supportedPercentRange = 5.0...3200.0

    static func sliderPosition(for percent: Double) -> Double {
        let range = supportedPercentRange
        let clamped = min(max(percent, range.lowerBound), range.upperBound)
        return log(clamped / range.lowerBound) / log(range.upperBound / range.lowerBound)
    }

    static func percent(forSliderPosition position: Double) -> Double {
        let range = supportedPercentRange
        let t = min(max(position, 0), 1)
        return range.lowerBound * pow(range.upperBound / range.lowerBound, t)
    }
}

enum NavigatorGeometry {
    static func clippedCanvasPolygon(
        _ polygon: [CanvasPoint],
        canvasSize: CanvasSize
    ) -> [CanvasPoint] {
        guard canvasSize.width > 0, canvasSize.height > 0, polygon.count >= 3 else {
            return []
        }

        let width = Double(canvasSize.width)
        let height = Double(canvasSize.height)
        var result = polygon
        result = clip(result, isInside: { $0.x >= 0 }) { start, end in
            intersection(start, end, axisValue: 0, usesX: true)
        }
        result = clip(result, isInside: { $0.x <= width }) { start, end in
            intersection(start, end, axisValue: width, usesX: true)
        }
        result = clip(result, isInside: { $0.y >= 0 }) { start, end in
            intersection(start, end, axisValue: 0, usesX: false)
        }
        result = clip(result, isInside: { $0.y <= height }) { start, end in
            intersection(start, end, axisValue: height, usesX: false)
        }
        return removingAdjacentDuplicates(result)
    }

    private static func clip(
        _ polygon: [CanvasPoint],
        isInside: (CanvasPoint) -> Bool,
        intersection: (CanvasPoint, CanvasPoint) -> CanvasPoint
    ) -> [CanvasPoint] {
        guard let last = polygon.last else { return [] }
        var result: [CanvasPoint] = []
        var start = last
        var startInside = isInside(start)

        for end in polygon {
            let endInside = isInside(end)
            if endInside {
                if !startInside {
                    result.append(intersection(start, end))
                }
                result.append(end)
            } else if startInside {
                result.append(intersection(start, end))
            }
            start = end
            startInside = endInside
        }
        return result
    }

    private static func intersection(
        _ start: CanvasPoint,
        _ end: CanvasPoint,
        axisValue: Double,
        usesX: Bool
    ) -> CanvasPoint {
        let startAxis = usesX ? start.x : start.y
        let endAxis = usesX ? end.x : end.y
        let denominator = endAxis - startAxis
        let t = abs(denominator) > 0.000_001 ? (axisValue - startAxis) / denominator : 0
        return CanvasPoint(
            x: usesX ? axisValue : start.x + ((end.x - start.x) * t),
            y: usesX ? start.y + ((end.y - start.y) * t) : axisValue
        )
    }

    private static func removingAdjacentDuplicates(_ polygon: [CanvasPoint]) -> [CanvasPoint] {
        var result: [CanvasPoint] = []
        for point in polygon {
            if let previous = result.last,
               abs(previous.x - point.x) < 0.000_001,
               abs(previous.y - point.y) < 0.000_001 {
                continue
            }
            result.append(point)
        }
        if result.count > 1,
           let first = result.first,
           let last = result.last,
           abs(first.x - last.x) < 0.000_001,
           abs(first.y - last.y) < 0.000_001 {
            result.removeLast()
        }
        return result
    }
}

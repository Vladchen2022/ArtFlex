import Foundation

/// Shared alpha-mask boolean operations for every selection tool.
///
/// The formulas preserve fractional coverage produced by anti-aliasing and
/// feathering instead of collapsing selection edges to binary values.
enum SelectionMaskCombiner {
    struct Patch: Sendable, Equatable {
        var originX: Int
        var originY: Int
        var width: Int
        var height: Int
        var alphaBytes: Data
    }

    struct CanvasResult: Sendable, Equatable {
        var alphaBytes: Data
        var bounds: CanvasRect
    }

    static func combine(
        base: [UInt8]?,
        incoming: [UInt8],
        mode: SelectionCombineMode
    ) -> [UInt8] {
        if mode == .replace {
            return incoming
        }

        guard let base, !base.isEmpty else {
            switch mode {
            case .replace, .add:
                return incoming
            case .subtract, .intersect:
                return [UInt8](repeating: 0, count: incoming.count)
            }
        }

        var result = base
        let count = min(result.count, incoming.count)
        for index in 0..<count {
            let old = Int(result[index])
            let new = Int(incoming[index])
            switch mode {
            case .replace:
                result[index] = incoming[index]
            case .add:
                result[index] = max(result[index], incoming[index])
            case .subtract:
                result[index] = UInt8(clamping: (old * (255 - new) + 127) / 255)
            case .intersect:
                result[index] = UInt8(clamping: (old * new + 127) / 255)
            }
        }
        return result
    }

    /// Combines a bounded incoming mask into a canvas-sized mask.
    ///
    /// Selection gestures normally touch only a small part of a large canvas.
    /// Keeping the incoming mask bounded avoids allocating and scanning a second
    /// full-canvas buffer for every add/subtract/intersect operation.
    static func combineCanvas(
        base: Data?,
        baseBounds: CanvasRect?,
        incoming: Patch,
        canvasWidth: Int,
        canvasHeight: Int,
        mode: SelectionCombineMode
    ) -> CanvasResult {
        let canvasCount = max(canvasWidth, 0) * max(canvasHeight, 0)
        guard canvasWidth > 0, canvasHeight > 0, canvasCount > 0 else {
            return CanvasResult(alphaBytes: Data(), bounds: emptyBounds)
        }

        let patch = clippedPatch(incoming, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        let validBase = base.flatMap { $0.count == canvasCount ? $0 : nil }

        if mode == .replace || validBase == nil {
            guard mode == .replace || mode == .add else {
                return CanvasResult(alphaBytes: Data(count: canvasCount), bounds: emptyBounds)
            }
            var result = Data(count: canvasCount)
            let bounds = writeReplacement(
                patch,
                into: &result,
                canvasWidth: canvasWidth
            )
            return CanvasResult(alphaBytes: result, bounds: bounds)
        }

        switch mode {
        case .replace:
            preconditionFailure("replace is handled above")
        case .add, .subtract:
            var result = validBase ?? Data(count: canvasCount)
            apply(patch, to: &result, canvasWidth: canvasWidth, mode: mode)

            let bounds: CanvasRect
            if mode == .add {
                let incomingBounds = nonzeroBounds(in: patch)
                bounds = union(baseBounds, incomingBounds)
            } else if let baseBounds, !baseBounds.isEmpty,
                      intersects(baseBounds, patch: patch) {
                bounds = nonzeroBounds(
                    in: result,
                    canvasWidth: canvasWidth,
                    canvasHeight: canvasHeight,
                    searchBounds: baseBounds
                )
            } else {
                bounds = baseBounds ?? emptyBounds
            }
            return CanvasResult(alphaBytes: result, bounds: bounds)
        case .intersect:
            var result = Data(count: canvasCount)
            let searchBounds = intersection(baseBounds, patch: patch)
            guard !searchBounds.isEmpty else {
                return CanvasResult(alphaBytes: result, bounds: emptyBounds)
            }
            let bounds = writeIntersection(
                base: validBase ?? Data(),
                incoming: patch,
                into: &result,
                canvasWidth: canvasWidth,
                searchBounds: searchBounds
            )
            return CanvasResult(alphaBytes: result, bounds: bounds)
        }
    }

    private static let emptyBounds = CanvasRect(
        origin: .init(x: 0, y: 0),
        size: .init(x: 0, y: 0)
    )

    private static func clippedPatch(
        _ patch: Patch,
        canvasWidth: Int,
        canvasHeight: Int
    ) -> Patch {
        guard patch.width > 0, patch.height > 0,
              patch.alphaBytes.count >= patch.width * patch.height else {
            return Patch(originX: 0, originY: 0, width: 0, height: 0, alphaBytes: Data())
        }

        let minX = min(max(patch.originX, 0), canvasWidth)
        let minY = min(max(patch.originY, 0), canvasHeight)
        let maxX = min(max(patch.originX + patch.width, 0), canvasWidth)
        let maxY = min(max(patch.originY + patch.height, 0), canvasHeight)
        let width = maxX - minX
        let height = maxY - minY
        guard width > 0, height > 0 else {
            return Patch(originX: 0, originY: 0, width: 0, height: 0, alphaBytes: Data())
        }
        guard minX != patch.originX || minY != patch.originY ||
                width != patch.width || height != patch.height else {
            return patch
        }

        var bytes = Data(count: width * height)
        bytes.withUnsafeMutableBytes { destinationRaw in
            patch.alphaBytes.withUnsafeBytes { sourceRaw in
                guard let destination = destinationRaw.baseAddress,
                      let source = sourceRaw.baseAddress else { return }
                let sourceStartX = minX - patch.originX
                let sourceStartY = minY - patch.originY
                for row in 0..<height {
                    destination.advanced(by: row * width).copyMemory(
                        from: source.advanced(by: ((sourceStartY + row) * patch.width) + sourceStartX),
                        byteCount: width
                    )
                }
            }
        }
        return Patch(originX: minX, originY: minY, width: width, height: height, alphaBytes: bytes)
    }

    private static func writeReplacement(
        _ patch: Patch,
        into result: inout Data,
        canvasWidth: Int
    ) -> CanvasRect {
        guard patch.width > 0, patch.height > 0 else { return emptyBounds }
        result.withUnsafeMutableBytes { destinationRaw in
            patch.alphaBytes.withUnsafeBytes { sourceRaw in
                guard let destination = destinationRaw.baseAddress,
                      let source = sourceRaw.baseAddress else { return }
                for row in 0..<patch.height {
                    destination.advanced(
                        by: ((patch.originY + row) * canvasWidth) + patch.originX
                    ).copyMemory(
                        from: source.advanced(by: row * patch.width),
                        byteCount: patch.width
                    )
                }
            }
        }
        return nonzeroBounds(in: patch)
    }

    private static func apply(
        _ patch: Patch,
        to result: inout Data,
        canvasWidth: Int,
        mode: SelectionCombineMode
    ) {
        guard patch.width > 0, patch.height > 0 else { return }
        result.withUnsafeMutableBytes { destinationRaw in
            patch.alphaBytes.withUnsafeBytes { sourceRaw in
                guard let destination = destinationRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let source = sourceRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for row in 0..<patch.height {
                    let destinationOffset = ((patch.originY + row) * canvasWidth) + patch.originX
                    let sourceOffset = row * patch.width
                    for column in 0..<patch.width {
                        let destinationIndex = destinationOffset + column
                        let incoming = Int(source[sourceOffset + column])
                        switch mode {
                        case .add:
                            destination[destinationIndex] = max(
                                destination[destinationIndex],
                                UInt8(incoming)
                            )
                        case .subtract:
                            let existing = Int(destination[destinationIndex])
                            destination[destinationIndex] = UInt8(
                                clamping: (existing * (255 - incoming) + 127) / 255
                            )
                        case .replace, .intersect:
                            break
                        }
                    }
                }
            }
        }
    }

    private static func writeIntersection(
        base: Data,
        incoming: Patch,
        into result: inout Data,
        canvasWidth: Int,
        searchBounds: CanvasRect
    ) -> CanvasRect {
        let minX = Int(searchBounds.minX)
        let minY = Int(searchBounds.minY)
        let maxX = Int(searchBounds.maxX)
        let maxY = Int(searchBounds.maxY)
        var foundMinX = maxX
        var foundMinY = maxY
        var foundMaxX = -1
        var foundMaxY = -1

        result.withUnsafeMutableBytes { destinationRaw in
            base.withUnsafeBytes { baseRaw in
                incoming.alphaBytes.withUnsafeBytes { incomingRaw in
                    guard let destination = destinationRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let baseBytes = baseRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let incomingBytes = incomingRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                    for y in minY..<maxY {
                        let canvasRow = y * canvasWidth
                        let incomingRow = (y - incoming.originY) * incoming.width
                        for x in minX..<maxX {
                            let index = canvasRow + x
                            let incomingIndex = incomingRow + (x - incoming.originX)
                            let value = UInt8(
                                clamping: (Int(baseBytes[index]) * Int(incomingBytes[incomingIndex]) + 127) / 255
                            )
                            destination[index] = value
                            guard value > 0 else { continue }
                            foundMinX = min(foundMinX, x)
                            foundMinY = min(foundMinY, y)
                            foundMaxX = max(foundMaxX, x)
                            foundMaxY = max(foundMaxY, y)
                        }
                    }
                }
            }
        }
        return bounds(minX: foundMinX, minY: foundMinY, maxX: foundMaxX, maxY: foundMaxY)
    }

    private static func nonzeroBounds(in patch: Patch) -> CanvasRect {
        guard patch.width > 0, patch.height > 0 else { return emptyBounds }
        var minX = patch.width
        var minY = patch.height
        var maxX = -1
        var maxY = -1
        patch.alphaBytes.withUnsafeBytes { raw in
            guard let bytes = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for y in 0..<patch.height {
                let row = y * patch.width
                for x in 0..<patch.width where bytes[row + x] > 0 {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return emptyBounds }
        return bounds(
            minX: minX + patch.originX,
            minY: minY + patch.originY,
            maxX: maxX + patch.originX,
            maxY: maxY + patch.originY
        )
    }

    private static func nonzeroBounds(
        in data: Data,
        canvasWidth: Int,
        canvasHeight: Int,
        searchBounds: CanvasRect
    ) -> CanvasRect {
        let minSearchX = min(max(Int(searchBounds.minX.rounded(.down)), 0), canvasWidth)
        let minSearchY = min(max(Int(searchBounds.minY.rounded(.down)), 0), canvasHeight)
        let maxSearchX = min(max(Int(searchBounds.maxX.rounded(.up)), 0), canvasWidth)
        let maxSearchY = min(max(Int(searchBounds.maxY.rounded(.up)), 0), canvasHeight)
        var minX = maxSearchX
        var minY = maxSearchY
        var maxX = -1
        var maxY = -1
        data.withUnsafeBytes { raw in
            guard let bytes = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for y in minSearchY..<maxSearchY {
                let row = y * canvasWidth
                for x in minSearchX..<maxSearchX where bytes[row + x] > 0 {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }
        return bounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    private static func bounds(minX: Int, minY: Int, maxX: Int, maxY: Int) -> CanvasRect {
        guard maxX >= minX, maxY >= minY else { return emptyBounds }
        return CanvasRect(
            origin: .init(x: Double(minX), y: Double(minY)),
            size: .init(x: Double(maxX - minX + 1), y: Double(maxY - minY + 1))
        )
    }

    private static func union(_ lhs: CanvasRect?, _ rhs: CanvasRect) -> CanvasRect {
        guard let lhs, !lhs.isEmpty else { return rhs }
        guard !rhs.isEmpty else { return lhs }
        let minX = min(lhs.minX, rhs.minX)
        let minY = min(lhs.minY, rhs.minY)
        let maxX = max(lhs.maxX, rhs.maxX)
        let maxY = max(lhs.maxY, rhs.maxY)
        return CanvasRect(
            origin: .init(x: minX, y: minY),
            size: .init(x: maxX - minX, y: maxY - minY)
        )
    }

    private static func intersection(_ bounds: CanvasRect?, patch: Patch) -> CanvasRect {
        guard let bounds, !bounds.isEmpty, patch.width > 0, patch.height > 0 else {
            return emptyBounds
        }
        let minX = max(bounds.minX, Double(patch.originX))
        let minY = max(bounds.minY, Double(patch.originY))
        let maxX = min(bounds.maxX, Double(patch.originX + patch.width))
        let maxY = min(bounds.maxY, Double(patch.originY + patch.height))
        guard maxX > minX, maxY > minY else { return emptyBounds }
        return CanvasRect(
            origin: .init(x: minX, y: minY),
            size: .init(x: maxX - minX, y: maxY - minY)
        )
    }

    private static func intersects(_ bounds: CanvasRect, patch: Patch) -> Bool {
        !intersection(bounds, patch: patch).isEmpty
    }
}

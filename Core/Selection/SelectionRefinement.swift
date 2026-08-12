import Foundation

enum SelectionRefinementKind: String, Codable, Sendable, Equatable, CaseIterable {
    case invert
    case feather
    case expand
    case contract
}

struct SelectionRefinementRequest: Codable, Sendable, Equatable {
    var kind: SelectionRefinementKind
    var radiusPixels: Int

    init(kind: SelectionRefinementKind, radiusPixels: Int = 0) {
        self.kind = kind
        self.radiusPixels = Self.normalizedRadius(radiusPixels, for: kind)
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case radiusPixels
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(SelectionRefinementKind.self, forKey: .kind)
        self.init(
            kind: kind,
            radiusPixels: try container.decodeIfPresent(Int.self, forKey: .radiusPixels) ?? 0
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(radiusPixels, forKey: .radiusPixels)
    }

    private static func normalizedRadius(
        _ radius: Int,
        for kind: SelectionRefinementKind
    ) -> Int {
        switch kind {
        case .invert:
            return 0
        case .feather, .expand, .contract:
            return min(max(radius, 0), 4_096)
        }
    }
}

enum SelectionRefinement {
    static func fullCanvasShape(canvasSize: CanvasSize) -> SelectionShape? {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        return SelectionShape(
            kind: .rectangle,
            bounds: CanvasRect(
                origin: .init(x: 0, y: 0),
                size: .init(x: Double(canvasSize.width), y: Double(canvasSize.height))
            ),
            pathPoints: []
        )
    }

    /// Returns the complement of `selection` within the canvas.
    ///
    /// Simple vector selections remain vector-based. Masks and composite selections are
    /// resolved to a mask so feathered alpha and nested boolean operations remain correct.
    static func inverted(
        _ selection: SelectionShape?,
        canvasSize: CanvasSize
    ) -> SelectionShape? {
        guard let fullCanvas = fullCanvasShape(canvasSize: canvasSize) else { return nil }
        guard let selection, !selection.isEmpty else { return fullCanvas }

        switch selection.kind {
        case .rectangle, .ellipse, .lasso:
            return SelectionShape.composite([
                .init(operation: .add, shape: fullCanvas),
                .init(operation: .subtract, shape: selection.clamped(to: canvasSize))
            ])
        case .mask, .composite:
            return invertedMask(selection, canvasSize: canvasSize)
        }
    }

    static func invertedMask(
        _ selection: SelectionShape,
        canvasSize: CanvasSize
    ) -> SelectionShape? {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        let pixelCount = canvasSize.width.multipliedReportingOverflow(by: canvasSize.height)
        guard !pixelCount.overflow, pixelCount.partialValue > 0 else { return nil }

        var bytes = [UInt8](repeating: 0, count: pixelCount.partialValue)
        for y in 0..<canvasSize.height {
            for x in 0..<canvasSize.width {
                let point = CanvasPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                let alpha = resolvedAlphaByte(of: selection, at: point)
                bytes[(y * canvasSize.width) + x] = 255 &- alpha
            }
        }
        return SelectionShape.mask(
            canvasWidth: canvasSize.width,
            canvasHeight: canvasSize.height,
            alphaBytes: bytes
        )
    }

    static func expanded(
        _ selection: SelectionShape,
        canvasSize: CanvasSize,
        radiusPixels: Int
    ) -> SelectionShape? {
        morphologicallyRefined(
            selection,
            canvasSize: canvasSize,
            radiusPixels: radiusPixels,
            operation: .maximum
        )
    }

    static func contracted(
        _ selection: SelectionShape,
        canvasSize: CanvasSize,
        radiusPixels: Int
    ) -> SelectionShape? {
        morphologicallyRefined(
            selection,
            canvasSize: canvasSize,
            radiusPixels: radiusPixels,
            operation: .minimum
        )
    }

    private enum MorphologyOperation {
        case minimum
        case maximum
    }

    /// Applies a square morphology kernel in two O(pixelCount) passes. The canvas
    /// exterior is treated as unselected, matching selection clipping semantics.
    private static func morphologicallyRefined(
        _ selection: SelectionShape,
        canvasSize: CanvasSize,
        radiusPixels: Int,
        operation: MorphologyOperation
    ) -> SelectionShape? {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        let radius = min(max(radiusPixels, 0), 4_096)
        guard radius > 0 else { return selection.clamped(to: canvasSize) }

        let pixelCount = canvasSize.width.multipliedReportingOverflow(by: canvasSize.height)
        guard !pixelCount.overflow, pixelCount.partialValue > 0 else { return nil }

        let selectionBounds = selection.bounds.clamped(to: canvasSize)
        let expansion = operation == .maximum ? radius : 0
        let originX = max(0, Int(floor(selectionBounds.minX)) - expansion)
        let originY = max(0, Int(floor(selectionBounds.minY)) - expansion)
        let maxX = min(canvasSize.width, Int(ceil(selectionBounds.maxX)) + expansion)
        let maxY = min(canvasSize.height, Int(ceil(selectionBounds.maxY)) + expansion)
        let regionWidth = max(0, maxX - originX)
        let regionHeight = max(0, maxY - originY)
        guard regionWidth > 0, regionHeight > 0 else { return nil }

        var source = [UInt8](repeating: 0, count: regionWidth * regionHeight)
        for localY in 0..<regionHeight {
            let y = originY + localY
            for localX in 0..<regionWidth {
                let x = originX + localX
                source[(localY * regionWidth) + localX] = resolvedAlphaByte(
                    of: selection,
                    at: CanvasPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                )
            }
        }

        var horizontal = [UInt8](repeating: 0, count: source.count)
        for y in 0..<regionHeight {
            let rowStart = y * regionWidth
            let line = Array(source[rowStart..<(rowStart + regionWidth)])
            let filtered = slidingExtremum(line, radius: radius, operation: operation)
            horizontal.replaceSubrange(rowStart..<(rowStart + regionWidth), with: filtered)
        }

        var regionResult = [UInt8](repeating: 0, count: source.count)
        var column = [UInt8](repeating: 0, count: regionHeight)
        for x in 0..<regionWidth {
            for y in 0..<regionHeight {
                column[y] = horizontal[(y * regionWidth) + x]
            }
            let filtered = slidingExtremum(column, radius: radius, operation: operation)
            for y in 0..<regionHeight {
                regionResult[(y * regionWidth) + x] = filtered[y]
            }
        }

        // Selection masks remain full-canvas for compatibility with the Metal
        // mask pipeline, but all expensive morphology work is restricted to ROI.
        var result = [UInt8](repeating: 0, count: pixelCount.partialValue)
        for localY in 0..<regionHeight {
            let destinationStart = ((originY + localY) * canvasSize.width) + originX
            let sourceStart = localY * regionWidth
            result.replaceSubrange(
                destinationStart..<(destinationStart + regionWidth),
                with: regionResult[sourceStart..<(sourceStart + regionWidth)]
            )
        }

        let refined = SelectionShape.mask(
            canvasWidth: canvasSize.width,
            canvasHeight: canvasSize.height,
            alphaBytes: result
        )
        return refined.isEmpty ? nil : refined
    }

    private static func slidingExtremum(
        _ source: [UInt8],
        radius: Int,
        operation: MorphologyOperation
    ) -> [UInt8] {
        guard !source.isEmpty else { return [] }
        let paddedCount = source.count + (radius * 2)
        var padded = [UInt8](repeating: 0, count: paddedCount)
        padded.replaceSubrange(radius..<(radius + source.count), with: source)

        let windowLength = (radius * 2) + 1
        var deque = [Int](repeating: 0, count: paddedCount)
        var head = 0
        var tail = 0
        var output = [UInt8](repeating: 0, count: source.count)

        @inline(__always)
        func shouldDiscard(_ existing: UInt8, for incoming: UInt8) -> Bool {
            switch operation {
            case .minimum:
                return existing >= incoming
            case .maximum:
                return existing <= incoming
            }
        }

        for index in padded.indices {
            while head < tail, deque[head] <= index - windowLength {
                head += 1
            }
            while head < tail, shouldDiscard(padded[deque[tail - 1]], for: padded[index]) {
                tail -= 1
            }
            deque[tail] = index
            tail += 1

            if index >= windowLength - 1 {
                let outputIndex = index - (windowLength - 1)
                if outputIndex < output.count {
                    output[outputIndex] = padded[deque[head]]
                }
            }
        }
        return output
    }

    private static func resolvedAlphaByte(
        of selection: SelectionShape,
        at point: CanvasPoint
    ) -> UInt8 {
        guard selection.bounds.contains(point) else { return 0 }

        switch selection.kind {
        case .rectangle, .ellipse, .lasso:
            return selection.contains(point) ? 255 : 0
        case .mask:
            guard
                let mask = selection.maskData,
                point.x >= 0,
                point.y >= 0
            else {
                return 0
            }
            let x = Int(point.x.rounded(.down))
            let y = Int(point.y.rounded(.down))
            guard x < mask.canvasWidth, y < mask.canvasHeight else { return 0 }
            return mask.alphaByte(at: (y * mask.canvasWidth) + x) ?? 0
        case .composite:
            var result = 0
            for component in selection.components {
                let componentAlpha = Int(resolvedAlphaByte(of: component.shape, at: point))
                switch component.operation {
                case .add:
                    result = max(result, componentAlpha)
                case .subtract:
                    result = (result * (255 - componentAlpha) + 127) / 255
                }
            }
            return UInt8(clamping: result)
        }
    }
}

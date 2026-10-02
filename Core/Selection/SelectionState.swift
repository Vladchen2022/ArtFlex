import Foundation

enum SelectionShapeKind: String, Codable, Sendable, Equatable {
    case rectangle
    case ellipse
    case lasso
    case mask
    case composite
}

enum SelectionCombineMode: String, Codable, Sendable, Equatable, CaseIterable {
    case replace
    case add
    case subtract
    case intersect
}

enum SelectionComponentOperation: String, Codable, Sendable, Equatable {
    case add
    case subtract
}

struct SelectionShapeComponent: Codable, Sendable, Equatable {
    var operation: SelectionComponentOperation
    var shape: SelectionShape
}

struct SelectionMaskData: Codable, Sendable, Equatable {
    var canvasWidth: Int
    var canvasHeight: Int
    private(set) var storageRegion: PixelRegion?
    private var storage: Data
    var storedByteCount: Int { storage.count }

    /// Legacy interchange view. Pixel/region consumers must use the bounded
    /// helpers below so reading a small selection does not allocate the canvas.
    var alphaBytes: Data {
        get { alphaBytes(in: .init(originX: 0, originY: 0, width: canvasWidth, height: canvasHeight)) }
        set { self = .init(canvasWidth: canvasWidth, canvasHeight: canvasHeight, alphaBytes: newValue) }
    }

    var patch: SelectionMaskCombiner.Patch {
        guard let r = storageRegion else { return .init(originX: 0, originY: 0, width: 0, height: 0, alphaBytes: Data()) }
        return .init(originX: r.originX, originY: r.originY, width: r.width, height: r.height, alphaBytes: storage)
    }

    init(canvasWidth: Int, canvasHeight: Int, alphaBytes: Data, knownBounds: CanvasRect? = nil) {
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.storageRegion = nil
        self.storage = Data()
        guard canvasWidth > 0, canvasHeight > 0,
              !canvasWidth.multipliedReportingOverflow(by: canvasHeight).overflow,
              alphaBytes.count == canvasWidth * canvasHeight else { return }
        if let knownBounds {
            let b = knownBounds.clamped(to: .init(width: canvasWidth, height: canvasHeight))
            let x = max(0, Int(floor(b.minX))), y = max(0, Int(floor(b.minY)))
            let w = min(canvasWidth, Int(ceil(b.maxX))) - x
            let h = min(canvasHeight, Int(ceil(b.maxY))) - y
            guard w > 0, h > 0 else { return }
            var regionBytes = Data(count: w * h)
            regionBytes.withUnsafeMutableBytes { dest in
                alphaBytes.withUnsafeBytes { source in
                    for row in 0..<h {
                        dest.baseAddress!.advanced(by: row * w).copyMemory(
                            from: source.baseAddress!.advanced(by: (y + row) * canvasWidth + x), byteCount: w)
                    }
                }
            }
            self = Self(canvasWidth: canvasWidth, canvasHeight: canvasHeight,
                      patch: .init(originX: x, originY: y, width: w, height: h, alphaBytes: regionBytes))
        } else {
            self = Self(canvasWidth: canvasWidth, canvasHeight: canvasHeight,
                      patch: .init(originX: 0, originY: 0, width: canvasWidth, height: canvasHeight, alphaBytes: alphaBytes))
        }
    }

    init(canvasWidth: Int, canvasHeight: Int, patch: SelectionMaskCombiner.Patch) {
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.storageRegion = nil
        self.storage = Data()
        guard canvasWidth > 0, canvasHeight > 0, patch.width > 0, patch.height > 0,
              !patch.width.multipliedReportingOverflow(by: patch.height).overflow,
              patch.alphaBytes.count == patch.width * patch.height else { return }
        let x0 = max(0, patch.originX), y0 = max(0, patch.originY)
        let x1 = min(canvasWidth, patch.originX + patch.width), y1 = min(canvasHeight, patch.originY + patch.height)
        guard x1 > x0, y1 > y0 else { return }
        var minX = x1, minY = y1, maxX = -1, maxY = -1
        patch.alphaBytes.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for y in y0..<y1 {
                for x in x0..<x1 where bytes[(y - patch.originY) * patch.width + x - patch.originX] > 0 {
                    minX = min(minX, x); minY = min(minY, y)
                    maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return }
        let region = PixelRegion(originX: minX, originY: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        storageRegion = region
        if region.originX == patch.originX, region.originY == patch.originY,
           region.width == patch.width, region.height == patch.height { storage = patch.alphaBytes; return }
        storage = Data(count: region.width * region.height)
        storage.withUnsafeMutableBytes { dest in
            patch.alphaBytes.withUnsafeBytes { source in
                for row in 0..<region.height {
                    dest.baseAddress!.advanced(by: row * region.width).copyMemory(
                        from: source.baseAddress!.advanced(by: (region.originY + row - patch.originY) * patch.width
                            + region.originX - patch.originX), byteCount: region.width)
                }
            }
        }
    }

    func alphaBytes(in region: PixelRegion) -> Data {
        guard region.width > 0, region.height > 0,
              !region.width.multipliedReportingOverflow(by: region.height).overflow else { return Data() }
        if region == storageRegion { return storage }
        var result = Data(count: region.width * region.height)
        guard let stored = storageRegion, let overlap = stored.intersection(with: region) else { return result }
        result.withUnsafeMutableBytes { dest in
            storage.withUnsafeBytes { source in
                for row in 0..<overlap.height {
                    dest.baseAddress!.advanced(by: (overlap.originY + row - region.originY) * region.width
                        + overlap.originX - region.originX).copyMemory(
                        from: source.baseAddress!.advanced(by: (overlap.originY + row - stored.originY) * stored.width
                            + overlap.originX - stored.originX), byteCount: overlap.width)
                }
            }
        }
        return result
    }

    func withAlphaBytes<Result>(_ body: (UnsafeBufferPointer<UInt8>) -> Result) -> Result {
        alphaBytes.withUnsafeBytes { body($0.bindMemory(to: UInt8.self)) }
    }

    @inline(__always)
    func alphaByte(at index: Int) -> UInt8? {
        guard canvasWidth > 0, canvasHeight > 0, index >= 0,
              index / canvasWidth < canvasHeight else { return nil }
        let x = index % canvasWidth, y = index / canvasWidth
        guard let r = storageRegion, x >= r.originX, x < r.maxX, y >= r.originY, y < r.maxY else { return 0 }
        return storage.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UInt8 in
            raw[(y - r.originY) * r.width + x - r.originX]
        }
    }

    private enum CodingKeys: String, CodingKey { case canvasWidth, canvasHeight, alphaBytes }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let width = try container.decode(Int.self, forKey: .canvasWidth)
        let height = try container.decode(Int.self, forKey: .canvasHeight)
        let bytes = try container.decode(Data.self, forKey: .alphaBytes)
        guard width > 0, height > 0, !width.multipliedReportingOverflow(by: height).overflow,
              bytes.count == width * height else {
            throw DecodingError.dataCorruptedError(forKey: .alphaBytes, in: container, debugDescription: "Invalid selection mask dimensions")
        }
        self.init(canvasWidth: width, canvasHeight: height, alphaBytes: bytes)
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(canvasWidth, forKey: .canvasWidth)
        try container.encode(canvasHeight, forKey: .canvasHeight)
        try container.encode(alphaBytes, forKey: .alphaBytes)
    }
}

struct CanvasRect: Codable, Sendable, Equatable {
    var origin: CanvasPoint
    var size: CanvasPoint

    var minX: Double { min(origin.x, origin.x + size.x) }
    var minY: Double { min(origin.y, origin.y + size.y) }
    var maxX: Double { max(origin.x, origin.x + size.x) }
    var maxY: Double { max(origin.y, origin.y + size.y) }

    var isEmpty: Bool {
        size.x <= 0 || size.y <= 0
    }

    static func fromPoints(_ start: CanvasPoint, _ end: CanvasPoint) -> CanvasRect {
        CanvasRect(
            origin: CanvasPoint(x: min(start.x, end.x), y: min(start.y, end.y)),
            size: CanvasPoint(
                x: abs(end.x - start.x),
                y: abs(end.y - start.y)
            )
        )
    }

    static func bounding(points: [CanvasPoint]) -> CanvasRect {
        guard let first = points.first else {
            return CanvasRect(origin: .init(x: 0, y: 0), size: .init(x: 0, y: 0))
        }

        var minX = first.x
        var minY = first.y
        var maxX = first.x
        var maxY = first.y

        for point in points.dropFirst() {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }

        return CanvasRect(
            origin: CanvasPoint(x: minX, y: minY),
            size: CanvasPoint(x: maxX - minX, y: maxY - minY)
        )
    }

    func contains(_ point: CanvasPoint) -> Bool {
        point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
    }

    func clamped(to canvasSize: CanvasSize) -> CanvasRect {
        let clampedMinX = min(max(minX, 0), Double(canvasSize.width))
        let clampedMinY = min(max(minY, 0), Double(canvasSize.height))
        let clampedMaxX = min(max(maxX, 0), Double(canvasSize.width))
        let clampedMaxY = min(max(maxY, 0), Double(canvasSize.height))

        return CanvasRect(
            origin: CanvasPoint(x: clampedMinX, y: clampedMinY),
            size: CanvasPoint(
                x: max(clampedMaxX - clampedMinX, 0),
                y: max(clampedMaxY - clampedMinY, 0)
            )
        )
    }
}

struct SelectionShape: Codable, Sendable, Equatable {
    var kind: SelectionShapeKind
    var bounds: CanvasRect
    var pathPoints: [CanvasPoint]
    var maskData: SelectionMaskData? = nil
    var components: [SelectionShapeComponent] = []

    enum CodingKeys: String, CodingKey {
        case kind
        case bounds
        case pathPoints
        case maskData
        case components
    }

    init(
        kind: SelectionShapeKind,
        bounds: CanvasRect,
        pathPoints: [CanvasPoint],
        maskData: SelectionMaskData? = nil,
        components: [SelectionShapeComponent] = []
    ) {
        self.kind = kind
        self.bounds = bounds
        self.pathPoints = pathPoints
        self.maskData = maskData
        self.components = components
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(SelectionShapeKind.self, forKey: .kind)
        bounds = try container.decode(CanvasRect.self, forKey: .bounds)
        pathPoints = try container.decodeIfPresent([CanvasPoint].self, forKey: .pathPoints) ?? []
        maskData = try container.decodeIfPresent(SelectionMaskData.self, forKey: .maskData)
        components = try container.decodeIfPresent([SelectionShapeComponent].self, forKey: .components) ?? []
    }

    var isEmpty: Bool {
        switch kind {
        case .lasso:
            return pathPoints.count < 3 || bounds.isEmpty
        case .mask:
            return maskData == nil || bounds.isEmpty
        case .rectangle, .ellipse:
            return bounds.isEmpty
        case .composite:
            return components.filter { $0.operation == .add }.isEmpty || bounds.isEmpty
        }
    }

    func contains(_ point: CanvasPoint) -> Bool {
        guard bounds.contains(point) else { return false }

        switch kind {
        case .rectangle:
            return true
        case .ellipse:
            let radiusX = max(bounds.size.x / 2, 0.0001)
            let radiusY = max(bounds.size.y / 2, 0.0001)
            let centerX = bounds.origin.x + radiusX
            let centerY = bounds.origin.y + radiusY
            let normalizedX = (point.x - centerX) / radiusX
            let normalizedY = (point.y - centerY) / radiusY
            return (normalizedX * normalizedX) + (normalizedY * normalizedY) <= 1
        case .lasso:
            guard pathPoints.count >= 3 else { return false }
            var contains = false
            var previous = pathPoints[pathPoints.count - 1]
            for current in pathPoints {
                let deltaY = previous.y - current.y
                let safeDeltaY = abs(deltaY) < 0.000001 ? 0.000001 : deltaY
                let intersects = ((current.y > point.y) != (previous.y > point.y)) &&
                    (point.x < ((previous.x - current.x) * (point.y - current.y) / safeDeltaY) + current.x)
                if intersects {
                    contains.toggle()
                }
                previous = current
            }
            return contains
        case .mask:
            guard
                let maskData,
                point.x >= 0,
                point.y >= 0,
                Int(point.x.rounded(.down)) < maskData.canvasWidth,
                Int(point.y.rounded(.down)) < maskData.canvasHeight
            else {
                return false
            }
            let x = Int(point.x.rounded(.down))
            let y = Int(point.y.rounded(.down))
            let index = (y * maskData.canvasWidth) + x
            guard let alpha = maskData.alphaByte(at: index) else { return false }
            return alpha > 0
        case .composite:
            var isSelected = false
            forEachFlattenedComponent { component in
                switch component.operation {
                case .add:
                    if component.shape.contains(point) {
                        isSelected = true
                    }
                case .subtract:
                    if component.shape.contains(point) {
                        isSelected = false
                    }
                }
            }
            return isSelected
        }
    }

    func clamped(to canvasSize: CanvasSize) -> SelectionShape {
        if kind == .mask, let maskData {
            if maskData.canvasWidth == canvasSize.width, maskData.canvasHeight == canvasSize.height {
                return self
            }
            let clampedMask = SelectionShape.mask(canvasWidth: canvasSize.width,
                canvasHeight: canvasSize.height, patch: maskData.patch)
            return SelectionShape(
                kind: .mask,
                bounds: clampedMask.bounds,
                pathPoints: pathPoints,
                maskData: clampedMask.maskData,
                components: components
            )
        }
        if kind == .composite {
            return SelectionShape.composite(
                components.map {
                    SelectionShapeComponent(
                        operation: $0.operation,
                        shape: $0.shape.clamped(to: canvasSize)
                    )
                }
            )
        }
        let clampedBounds = bounds.clamped(to: canvasSize)
        let clampedPoints = pathPoints.map {
            CanvasPoint(
                x: min(max($0.x, 0), Double(canvasSize.width)),
                y: min(max($0.y, 0), Double(canvasSize.height))
            )
        }
        return SelectionShape(
            kind: kind,
            bounds: clampedBounds,
            pathPoints: clampedPoints,
            maskData: maskData
        )
    }

    func translatedBy(x deltaX: Double, y deltaY: Double) -> SelectionShape {
        if kind == .mask, let maskData {
            let shiftX = Int(deltaX.rounded())
            let shiftY = Int(deltaY.rounded())
            var patch = maskData.patch
            patch.originX += shiftX
            patch.originY += shiftY
            let translatedMask = SelectionShape.mask(canvasWidth: maskData.canvasWidth,
                canvasHeight: maskData.canvasHeight, patch: patch)
            return SelectionShape(
                kind: .mask,
                bounds: translatedMask.bounds,
                pathPoints: pathPoints.map {
                    CanvasPoint(x: $0.x + deltaX, y: $0.y + deltaY)
                },
                maskData: translatedMask.maskData,
                components: components.map {
                    SelectionShapeComponent(
                        operation: $0.operation,
                        shape: $0.shape.translatedBy(x: deltaX, y: deltaY)
                    )
                }
            )
        }
        if kind == .composite {
            return SelectionShape.composite(
                components.map {
                    SelectionShapeComponent(
                        operation: $0.operation,
                        shape: $0.shape.translatedBy(x: deltaX, y: deltaY)
                    )
                }
            )
        }
        return SelectionShape(
            kind: kind,
            bounds: CanvasRect(
                origin: CanvasPoint(
                    x: bounds.origin.x + deltaX,
                    y: bounds.origin.y + deltaY
                ),
                size: bounds.size
            ),
            pathPoints: pathPoints.map {
                CanvasPoint(x: $0.x + deltaX, y: $0.y + deltaY)
            },
            maskData: maskData,
            components: components
        )
    }

    var containsLassoContent: Bool {
        switch kind {
        case .lasso:
            return true
        case .mask:
            return true
        case .composite:
            var hasComponent = false
            var allComponentsContainLassoContent = true
            forEachFlattenedComponent { component in
                hasComponent = true
                if component.shape.containsLassoContent == false {
                    allComponentsContainLassoContent = false
                }
            }
            return hasComponent && allComponentsContainLassoContent
        case .rectangle, .ellipse:
            return false
        }
    }

    func flattenedComponents() -> [SelectionShapeComponent] {
        var flattened: [SelectionShapeComponent] = []
        flattened.reserveCapacity(max(components.count, 1))
        forEachFlattenedComponent { component in
            flattened.append(component)
        }
        return flattened
    }

    static func composite(_ components: [SelectionShapeComponent]) -> SelectionShape {
        let normalized = components.flatMap { component -> [SelectionShapeComponent] in
            if component.shape.kind == .composite {
                return component.shape.flattenedComponents().map {
                    SelectionShapeComponent(
                        operation: component.operation == .subtract ? .subtract : $0.operation,
                        shape: $0.shape
                    )
                }
            }
            return [component]
        }
        let additiveBounds = normalized
            .filter { $0.operation == .add }
            .map(\.shape.bounds)

        let bounds: CanvasRect
        if additiveBounds.isEmpty {
            bounds = CanvasRect(origin: .init(x: 0, y: 0), size: .init(x: 0, y: 0))
        } else {
            let minX = additiveBounds.map(\.minX).min() ?? 0
            let minY = additiveBounds.map(\.minY).min() ?? 0
            let maxX = additiveBounds.map(\.maxX).max() ?? 0
            let maxY = additiveBounds.map(\.maxY).max() ?? 0
            bounds = CanvasRect(
                origin: .init(x: minX, y: minY),
                size: .init(x: maxX - minX, y: maxY - minY)
            )
        }

        return SelectionShape(
            kind: .composite,
            bounds: bounds,
            pathPoints: [],
            components: normalized
        )
    }

    static func mask(canvasWidth: Int, canvasHeight: Int, alphaBytes: [UInt8]) -> SelectionShape {
        let bounds = Self.maskBounds(
            alphaBytes: alphaBytes,
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight
        )
        return SelectionShape(
            kind: .mask,
            bounds: bounds,
            pathPoints: [],
            maskData: SelectionMaskData(
                canvasWidth: canvasWidth,
                canvasHeight: canvasHeight,
                alphaBytes: Data(alphaBytes), knownBounds: bounds
            )
        )
    }

    static func mask(
        canvasWidth: Int,
        canvasHeight: Int,
        alphaBytes: Data,
        knownBounds: CanvasRect? = nil
    ) -> SelectionShape {
        let bounds = knownBounds ?? Self.maskBounds(
            alphaBytes: alphaBytes,
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight
        )
        return SelectionShape(
            kind: .mask,
            bounds: bounds,
            pathPoints: [],
            maskData: SelectionMaskData(
                canvasWidth: canvasWidth,
                canvasHeight: canvasHeight,
                alphaBytes: alphaBytes, knownBounds: bounds
            )
        )
    }

    static func mask(canvasWidth: Int, canvasHeight: Int, patch: SelectionMaskCombiner.Patch) -> SelectionShape {
        let mask = SelectionMaskData(canvasWidth: canvasWidth, canvasHeight: canvasHeight, patch: patch)
        let bounds = mask.storageRegion.map {
            CanvasRect(origin: .init(x: Double($0.originX), y: Double($0.originY)),
                       size: .init(x: Double($0.width), y: Double($0.height)))
        } ?? CanvasRect(origin: .init(x: 0, y: 0), size: .init(x: 0, y: 0))
        return SelectionShape(kind: .mask, bounds: bounds, pathPoints: [], maskData: mask)
    }

    private static func maskBounds(alphaBytes: [UInt8], canvasWidth: Int, canvasHeight: Int) -> CanvasRect {
        var minX = canvasWidth
        var minY = canvasHeight
        var maxX = -1
        var maxY = -1

        for y in 0..<canvasHeight {
            for x in 0..<canvasWidth {
                guard alphaBytes[(y * canvasWidth) + x] > 0 else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard maxX >= minX, maxY >= minY else {
            return CanvasRect(origin: .init(x: 0, y: 0), size: .init(x: 0, y: 0))
        }

        return CanvasRect(
            origin: .init(x: Double(minX), y: Double(minY)),
            size: .init(x: Double(maxX - minX + 1), y: Double(maxY - minY + 1))
        )
    }


    private static func maskBounds(alphaBytes: Data, canvasWidth: Int, canvasHeight: Int) -> CanvasRect {
        var minX = canvasWidth
        var minY = canvasHeight
        var maxX = -1
        var maxY = -1

        alphaBytes.withUnsafeBytes { rawBuffer in
            guard let bytes = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for y in 0..<canvasHeight {
                let row = y * canvasWidth
                for x in 0..<canvasWidth where bytes[row + x] > 0 {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }

        guard maxX >= minX, maxY >= minY else {
            return CanvasRect(origin: .init(x: 0, y: 0), size: .init(x: 0, y: 0))
        }
        return CanvasRect(
            origin: .init(x: Double(minX), y: Double(minY)),
            size: .init(x: Double(maxX - minX + 1), y: Double(maxY - minY + 1))
        )
    }

    private func forEachFlattenedComponent(
        inheritedOperation: SelectionComponentOperation = .add,
        _ body: (SelectionShapeComponent) -> Void
    ) {
        guard kind == .composite else {
            body(SelectionShapeComponent(operation: inheritedOperation, shape: self))
            return
        }

        for component in components {
            let effectiveOperation: SelectionComponentOperation =
                inheritedOperation == .subtract ? .subtract : component.operation
            if component.shape.kind == .composite {
                component.shape.forEachFlattenedComponent(
                    inheritedOperation: effectiveOperation,
                    body
                )
            } else {
                body(
                    SelectionShapeComponent(
                        operation: effectiveOperation,
                        shape: component.shape
                    )
                )
            }
        }
    }
}

struct SelectionState: Codable, Sendable, Equatable {
    var anchorPoint: CanvasPoint?
    var activeKind: SelectionShapeKind?
    var activeCombineMode: SelectionCombineMode
    var committedShape: SelectionShape?
    var inProgressShape: SelectionShape?

    static let empty = SelectionState(
        anchorPoint: nil,
        activeKind: nil,
        activeCombineMode: .replace,
        committedShape: nil,
        inProgressShape: nil
    )

    var displayShape: SelectionShape? {
        inProgressShape ?? committedShape
    }

    var displayRect: CanvasRect? {
        displayShape?.bounds
    }

    enum CodingKeys: String, CodingKey {
        case anchorPoint
        case activeKind
        case activeCombineMode
        case committedShape
        case inProgressShape
    }

    init(
        anchorPoint: CanvasPoint?,
        activeKind: SelectionShapeKind?,
        activeCombineMode: SelectionCombineMode,
        committedShape: SelectionShape?,
        inProgressShape: SelectionShape?
    ) {
        self.anchorPoint = anchorPoint
        self.activeKind = activeKind
        self.activeCombineMode = activeCombineMode
        self.committedShape = committedShape
        self.inProgressShape = inProgressShape
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        anchorPoint = try container.decodeIfPresent(CanvasPoint.self, forKey: .anchorPoint)
        activeKind = try container.decodeIfPresent(SelectionShapeKind.self, forKey: .activeKind)
        activeCombineMode = try container.decodeIfPresent(SelectionCombineMode.self, forKey: .activeCombineMode) ?? .replace
        committedShape = try container.decodeIfPresent(SelectionShape.self, forKey: .committedShape)
        inProgressShape = try container.decodeIfPresent(SelectionShape.self, forKey: .inProgressShape)
    }
}

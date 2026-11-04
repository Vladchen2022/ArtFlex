import Foundation
import CoreGraphics
import OSLog

/// Stateless geometry and mask conversion. No workspace, UI, or mutable document dependencies.
typealias SelectionPolygonShape = [[CGPoint]]

enum SelectionMaskRasterizer {
    static func selectionOutlinePoints(
        for kind: SelectionShapeKind,
        bounds: CanvasRect
    ) -> SelectionPolygonShape {
        switch kind {
        case .rectangle:
            return [[
                CGPoint(x: bounds.minX, y: bounds.minY),
                CGPoint(x: bounds.minX, y: bounds.maxY),
                CGPoint(x: bounds.maxX, y: bounds.maxY),
                CGPoint(x: bounds.maxX, y: bounds.minY)
            ]]
        case .ellipse:
            return [ellipsePolygonPoints(for: bounds)]
        case .lasso:
            return []
        case .mask, .composite:
            return []
        }
    }

    static func ellipsePolygonPoints(for bounds: CanvasRect, segments: Int = 96) -> [CGPoint] {
        let radiusX = max(bounds.size.x / 2, 0.5)
        let radiusY = max(bounds.size.y / 2, 0.5)
        let centerX = bounds.origin.x + radiusX
        let centerY = bounds.origin.y + radiusY

        return (0..<segments).map { index in
            let angle = (Double(index) / Double(segments)) * .pi * 2
            return CGPoint(
                x: centerX + (cos(angle) * radiusX),
                y: centerY + (sin(angle) * radiusY)
            )
        }
    }

    static func selectionMaskShape(
        from polygonShapes: [SelectionPolygonShape],
        canvasSize: CanvasSize,
        preferredDisplayShape: SelectionShape?
    ) -> SelectionShape {
        let components = polygonShapes.flatMap { polygonShape -> [SelectionShapeComponent] in
            polygonShape.compactMap { path in
                let clamped = path.map {
                    CanvasPoint(
                        x: min(max(Double($0.x), 0), Double(canvasSize.width)),
                        y: min(max(Double($0.y), 0), Double(canvasSize.height))
                    )
                }
                guard clamped.count >= 3 else { return nil }
                return SelectionShapeComponent(
                    operation: .add,
                    shape: SelectionShape(
                        kind: .lasso,
                        bounds: CanvasRect.bounding(points: clamped),
                        pathPoints: clamped
                    )
                )
            }
        }

        if components.isEmpty {
            return emptySelectionMaskShape(canvasSize: canvasSize)
        }

        let maskPatch = selectionMaskPatch(from: polygonShapes, canvasSize: canvasSize)
        let maskShape = SelectionShape.mask(
            canvasWidth: canvasSize.width,
            canvasHeight: canvasSize.height,
            patch: maskPatch
        )
        if RuntimeDiagnostics.selectionTraceLoggingEnabled {
            let maskMessage = "[selectionMaskShape] polygonShapeCount=\(polygonShapes.count) maskBoundsOrigin=(\(maskShape.bounds.origin.x),\(maskShape.bounds.origin.y)) maskBoundsSize=(\(maskShape.bounds.size.x),\(maskShape.bounds.size.y)) preferredDisplayKind=\(preferredDisplayShape?.kind.rawValue ?? "nil")"
            Logger(subsystem: "ArtFlex", category: "SelectionTrace").debug("\(maskMessage, privacy: .public)")

        }

        return SelectionShape(
            kind: .mask,
            bounds: maskShape.bounds,
            pathPoints: preferredDisplayShape?.pathPoints ?? [],
            maskData: maskShape.maskData,
            components: preferredDisplayShape.map {
                [SelectionShapeComponent(operation: .add, shape: $0.clamped(to: canvasSize))]
            } ?? []
        )
    }

    static func emptySelectionMaskShape(canvasSize: CanvasSize) -> SelectionShape {
        SelectionShape.mask(
            canvasWidth: canvasSize.width,
            canvasHeight: canvasSize.height,
            patch: .init(originX: 0, originY: 0, width: 0, height: 0, alphaBytes: Data())
        )
    }

    static func boundedSelectionMask(for shape: SelectionShape?, canvasSize: CanvasSize) -> SelectionMaskData? {
        guard let shape else { return nil }
        if let mask = shape.maskData, mask.canvasWidth == canvasSize.width, mask.canvasHeight == canvasSize.height { return mask }
        let bounds = shape.bounds.clamped(to: canvasSize)
        guard !bounds.isEmpty else { return nil }
        let x = max(0, Int(floor(bounds.minX))), y = max(0, Int(floor(bounds.minY)))
        let width = min(canvasSize.width, Int(ceil(bounds.maxX))) - x
        let height = min(canvasSize.height, Int(ceil(bounds.maxY))) - y
        let region = selectionMaskRegion(for: shape, canvasSize: canvasSize,
            originX: x, originY: y, width: width, height: height)
        return SelectionMaskData(canvasWidth: canvasSize.width, canvasHeight: canvasSize.height,
            patch: .init(originX: x, originY: y, width: width, height: height, alphaBytes: region.alphaBytes))
    }

    static func selectionMaskBytes(for shape: SelectionShape?, canvasSize: CanvasSize) -> [UInt8] {
        guard let shape else {
            return [UInt8](repeating: 0, count: canvasSize.width * canvasSize.height)
        }

        if let maskData = shape.maskData,
           maskData.canvasWidth == canvasSize.width,
           maskData.canvasHeight == canvasSize.height {
            return [UInt8](maskData.alphaBytes)
        }

        let polygonShapes: [SelectionPolygonShape]
        switch shape.kind {
        case .lasso:
            guard shape.pathPoints.count >= 3 else {
                return [UInt8](repeating: 0, count: canvasSize.width * canvasSize.height)
            }
            polygonShapes = [[shape.pathPoints.map { CGPoint(x: $0.x, y: $0.y) }]]
        case .rectangle, .ellipse:
            polygonShapes = [selectionOutlinePoints(for: shape.kind, bounds: shape.bounds)]
        case .mask:
            if shape.components.count == 1,
               let component = shape.components.first,
               component.operation == .add {
                return selectionMaskBytes(for: component.shape, canvasSize: canvasSize)
            }
            if shape.pathPoints.count >= 3 {
                polygonShapes = [[shape.pathPoints.map { CGPoint(x: $0.x, y: $0.y) }]]
            } else {
                return [UInt8](repeating: 0, count: canvasSize.width * canvasSize.height)
            }
        case .composite:
            return compositedSelectionMaskBytes(for: shape, canvasSize: canvasSize)
        }

        return rasterizedSelectionMaskBytes(
            polygonShapes: polygonShapes,
            canvasSize: canvasSize
        )
    }

    static func selectionMaskRegion(
        for shape: SelectionShape?,
        canvasSize: CanvasSize,
        originX: Int,
        originY: Int,
        width: Int,
        height: Int
    ) -> SelectionMaskRegion {
        guard width > 0, height > 0 else {
            return SelectionMaskRegion(originX: originX, originY: originY, width: 0, height: 0, alphaBytes: Data())
        }

        guard let shape else {
            return SelectionMaskRegion(
                originX: originX,
                originY: originY,
                width: width,
                height: height,
                alphaBytes: Data(count: width * height)
            )
        }

        if let maskData = shape.maskData,
           maskData.canvasWidth == canvasSize.width,
           maskData.canvasHeight == canvasSize.height {
            return SelectionMaskRegion(
                originX: originX,
                originY: originY,
                width: width,
                height: height,
                alphaBytes: maskData.alphaBytes(in: .init(originX: originX, originY: originY, width: width, height: height))
            )
        }

        let polygonShapes: [SelectionPolygonShape]
        switch shape.kind {
        case .lasso:
            guard shape.pathPoints.count >= 3 else {
                return SelectionMaskRegion(
                    originX: originX,
                    originY: originY,
                    width: width,
                    height: height,
                    alphaBytes: Data(count: width * height)
                )
            }
            polygonShapes = [[shape.pathPoints.map { CGPoint(x: $0.x, y: $0.y) }]]
        case .rectangle, .ellipse:
            polygonShapes = [selectionOutlinePoints(for: shape.kind, bounds: shape.bounds)]
        case .mask:
            if shape.components.count == 1,
               let component = shape.components.first,
               component.operation == .add {
                return selectionMaskRegion(
                    for: component.shape,
                    canvasSize: canvasSize,
                    originX: originX,
                    originY: originY,
                    width: width,
                    height: height
                )
            }
            if shape.pathPoints.count >= 3 {
                polygonShapes = [[shape.pathPoints.map { CGPoint(x: $0.x, y: $0.y) }]]
            } else {
                return SelectionMaskRegion(
                    originX: originX,
                    originY: originY,
                    width: width,
                    height: height,
                    alphaBytes: Data(count: width * height)
                )
            }
        case .composite:
            return compositedSelectionMaskRegion(
                for: shape,
                canvasSize: canvasSize,
                originX: originX,
                originY: originY,
                width: width,
                height: height
            )
        }

        return SelectionMaskRegion(
            originX: originX,
            originY: originY,
            width: width,
            height: height,
            alphaBytes: rasterizedSelectionMaskRegionBytes(
                polygonShapes: polygonShapes,
                originX: originX,
                originY: originY,
                width: width,
                height: height
            )
        )
    }

    static func featheredSelectionShape(
        _ shape: SelectionShape,
        canvasSize: CanvasSize,
        radiusPixels: Int,
        cancellation: WorkCancellation? = nil
    ) throws -> SelectionShape {
        try cancellation?.check()
        let clampedShape = shape.clamped(to: canvasSize)
        guard !clampedShape.isEmpty else {
            throw SelectionMaskFeatheringError.invalidDimensions
        }

        let minX = max(Int(clampedShape.bounds.minX.rounded(.down)) - radiusPixels, 0)
        let minY = max(Int(clampedShape.bounds.minY.rounded(.down)) - radiusPixels, 0)
        let maxX = min(Int(clampedShape.bounds.maxX.rounded(.up)) + radiusPixels, canvasSize.width)
        let maxY = min(Int(clampedShape.bounds.maxY.rounded(.up)) + radiusPixels, canvasSize.height)
        let width = maxX - minX
        let height = maxY - minY
        guard width > 0, height > 0 else {
            throw SelectionMaskFeatheringError.invalidDimensions
        }

        let sourceRegion = selectionMaskRegion(
            for: clampedShape,
            canvasSize: canvasSize,
            originX: minX,
            originY: minY,
            width: width,
            height: height
        )
        try cancellation?.check()
        let featheredRegionBytes = try VImageSelectionMaskFeatherer.feather(
            alphaBytes: sourceRegion.alphaBytes,
            width: width,
            height: height,
            radiusPixels: radiusPixels
        )

        try cancellation?.check()
        let result = SelectionShape.mask(canvasWidth: canvasSize.width, canvasHeight: canvasSize.height,
            patch: .init(originX: minX, originY: minY, width: width, height: height, alphaBytes: featheredRegionBytes))
        guard !result.isEmpty else {
            throw SelectionMaskFeatheringError.invalidDimensions
        }

        // The feathered mask controls pixel coverage, while the original vector
        // geometry remains the stable 50% contour used by the marching-ants overlay.
        // Existing mask selections may already carry display-only components.
        let displayComponents: [SelectionShapeComponent]
        if clampedShape.kind == .mask {
            displayComponents = clampedShape.components
        } else {
            displayComponents = [
                SelectionShapeComponent(operation: .add, shape: clampedShape)
            ]
        }
        return SelectionShape(
            kind: .mask,
            bounds: result.bounds,
            pathPoints: clampedShape.pathPoints,
            maskData: result.maskData,
            components: displayComponents
        )
    }

    static func maskRegionBytes(
        from alphaBytes: Data,
        canvasWidth: Int,
        originX: Int,
        originY: Int,
        width: Int,
        height: Int
    ) -> Data {
        var result = Data(count: width * height)
        guard !result.isEmpty else { return result }

        result.withUnsafeMutableBytes { destinationRawBuffer in
            alphaBytes.withUnsafeBytes { sourceRawBuffer in
                guard
                    let destinationBase = destinationRawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    let sourceBase = sourceRawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else {
                    return
                }

                for row in 0..<height {
                    let sourceOffset = ((originY + row) * canvasWidth) + originX
                    let destinationOffset = row * width
                    UnsafeMutableRawPointer(destinationBase.advanced(by: destinationOffset))
                        .copyMemory(
                            from: UnsafeRawPointer(sourceBase.advanced(by: sourceOffset)),
                            byteCount: width
                        )
                }
            }
        }

        return result
    }

    static func maskRegionBytes(
        from alphaBytes: [UInt8],
        canvasWidth: Int,
        originX: Int,
        originY: Int,
        width: Int,
        height: Int
    ) -> Data {
        var result = Data(count: width * height)
        guard !result.isEmpty else { return result }

        result.withUnsafeMutableBytes { destinationRawBuffer in
            alphaBytes.withUnsafeBufferPointer { sourceBuffer in
                guard
                    let destinationBase = destinationRawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    let sourceBase = sourceBuffer.baseAddress
                else {
                    return
                }

                for row in 0..<height {
                    let sourceOffset = ((originY + row) * canvasWidth) + originX
                    let destinationOffset = row * width
                    UnsafeMutableRawPointer(destinationBase.advanced(by: destinationOffset))
                        .copyMemory(
                            from: UnsafeRawPointer(sourceBase.advanced(by: sourceOffset)),
                            byteCount: width
                        )
                }
            }
        }

        return result
    }

    static func applyIncomingMask(
        to result: inout [UInt8],
        incomingMaskData: SelectionMaskData,
        incomingBounds: CanvasRect,
        canvasSize: CanvasSize,
        mode: SelectionCombineMode
    ) {
        let minX = max(Int(floor(incomingBounds.minX)), 0)
        let minY = max(Int(floor(incomingBounds.minY)), 0)
        let maxX = min(Int(ceil(incomingBounds.maxX)), canvasSize.width)
        let maxY = min(Int(ceil(incomingBounds.maxY)), canvasSize.height)
        guard minX < maxX, minY < maxY else { return }

        incomingMaskData.withAlphaBytes { incomingBytes in
            for y in minY..<maxY {
                let rowOffset = y * canvasSize.width
                for x in minX..<maxX {
                    let index = rowOffset + x
                    guard index < incomingBytes.count else { continue }
                    let incoming = incomingBytes[index]
                    guard incoming > 0 else { continue }

                    switch mode {
                    case .replace:
                        result[index] = incoming
                    case .add:
                        result[index] = max(result[index], incoming)
                    case .subtract:
                        let kept = (Int(result[index]) * (255 - Int(incoming))) / 255
                        result[index] = UInt8(clamping: kept)
                    case .intersect:
                        result[index] = UInt8(clamping: (Int(result[index]) * Int(incoming)) / 255)
                    }
                }
            }
        }
    }

    static func compositedSelectionMaskBytes(
        for shape: SelectionShape,
        canvasSize: CanvasSize
    ) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: canvasSize.width * canvasSize.height)
        guard canvasSize.width > 0, canvasSize.height > 0 else { return result }

        for component in shape.flattenedComponents() {
            guard let regionBounds = selectionMaskIntersectionRegion(
                for: component.shape,
                canvasSize: canvasSize,
                originX: 0,
                originY: 0,
                width: canvasSize.width,
                height: canvasSize.height
            ) else {
                continue
            }
            let incomingRegion = selectionMaskRegion(
                for: component.shape,
                canvasSize: canvasSize,
                originX: regionBounds.originX,
                originY: regionBounds.originY,
                width: regionBounds.width,
                height: regionBounds.height
            )
            applySelectionMaskRegion(
                to: &result,
                canvasWidth: canvasSize.width,
                incomingRegion: incomingRegion,
                operation: component.operation
            )
        }

        return result
    }

    static func compositedSelectionMaskRegion(
        for shape: SelectionShape,
        canvasSize: CanvasSize,
        originX: Int,
        originY: Int,
        width: Int,
        height: Int
    ) -> SelectionMaskRegion {
        var result = Data(count: width * height)
        guard width > 0, height > 0 else {
            return SelectionMaskRegion(originX: originX, originY: originY, width: 0, height: 0, alphaBytes: Data())
        }

        for component in shape.flattenedComponents() {
            guard let regionBounds = selectionMaskIntersectionRegion(
                for: component.shape,
                canvasSize: canvasSize,
                originX: originX,
                originY: originY,
                width: width,
                height: height
            ) else {
                continue
            }
            let incomingRegion = selectionMaskRegion(
                for: component.shape,
                canvasSize: canvasSize,
                originX: regionBounds.originX,
                originY: regionBounds.originY,
                width: regionBounds.width,
                height: regionBounds.height
            )
            applySelectionMaskRegion(
                to: &result,
                destinationOriginX: originX,
                destinationOriginY: originY,
                destinationWidth: width,
                incomingRegion: incomingRegion,
                operation: component.operation
            )
        }

        return SelectionMaskRegion(
            originX: originX,
            originY: originY,
            width: width,
            height: height,
            alphaBytes: result
        )
    }

    static func selectionMaskIntersectionRegion(
        for shape: SelectionShape,
        canvasSize: CanvasSize,
        originX: Int,
        originY: Int,
        width: Int,
        height: Int
    ) -> (originX: Int, originY: Int, width: Int, height: Int)? {
        let bounds = shape.bounds.clamped(to: canvasSize)
        let shapeMinX = max(Int(floor(bounds.minX)) - 1, 0)
        let shapeMinY = max(Int(floor(bounds.minY)) - 1, 0)
        let shapeMaxX = min(Int(ceil(bounds.maxX)) + 1, canvasSize.width)
        let shapeMaxY = min(Int(ceil(bounds.maxY)) + 1, canvasSize.height)
        let minX = max(originX, shapeMinX)
        let minY = max(originY, shapeMinY)
        let maxX = min(originX + width, shapeMaxX)
        let maxY = min(originY + height, shapeMaxY)

        guard minX < maxX, minY < maxY else { return nil }
        return (originX: minX, originY: minY, width: maxX - minX, height: maxY - minY)
    }

    static func applySelectionMaskRegion(
        to result: inout [UInt8],
        canvasWidth: Int,
        incomingRegion: SelectionMaskRegion,
        operation: SelectionComponentOperation
    ) {
        guard incomingRegion.width > 0, incomingRegion.height > 0 else { return }
        incomingRegion.withAlphaBytes { incomingBytes in
            for localY in 0..<incomingRegion.height {
                let resultRowOffset = (incomingRegion.originY + localY) * canvasWidth
                let incomingRowOffset = localY * incomingRegion.width
                for localX in 0..<incomingRegion.width {
                    let incoming = incomingBytes[incomingRowOffset + localX]
                    guard incoming > 0 else { continue }
                    let resultIndex = resultRowOffset + incomingRegion.originX + localX
                    switch operation {
                    case .add:
                        result[resultIndex] = max(result[resultIndex], incoming)
                    case .subtract:
                        let kept = (Int(result[resultIndex]) * (255 - Int(incoming))) / 255
                        result[resultIndex] = UInt8(clamping: kept)
                    }
                }
            }
        }
    }

    static func applySelectionMaskRegion(
        to result: inout Data,
        destinationOriginX: Int,
        destinationOriginY: Int,
        destinationWidth: Int,
        incomingRegion: SelectionMaskRegion,
        operation: SelectionComponentOperation
    ) {
        guard incomingRegion.width > 0, incomingRegion.height > 0 else { return }
        result.withUnsafeMutableBytes { destinationRawBuffer in
            incomingRegion.withAlphaBytes { incomingBytes in
                guard let destinationBase = destinationRawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return
                }
                for localY in 0..<incomingRegion.height {
                    let destinationY = incomingRegion.originY + localY - destinationOriginY
                    let destinationX = incomingRegion.originX - destinationOriginX
                    let destinationRowOffset = (destinationY * destinationWidth) + destinationX
                    let incomingRowOffset = localY * incomingRegion.width
                    for localX in 0..<incomingRegion.width {
                        let incoming = incomingBytes[incomingRowOffset + localX]
                        guard incoming > 0 else { continue }
                        let resultIndex = destinationRowOffset + localX
                        switch operation {
                        case .add:
                            destinationBase[resultIndex] = max(destinationBase[resultIndex], incoming)
                        case .subtract:
                            let kept = (Int(destinationBase[resultIndex]) * (255 - Int(incoming))) / 255
                            destinationBase[resultIndex] = UInt8(clamping: kept)
                        }
                    }
                }
            }
        }
    }

    static func rasterizedSelectionMaskBytes(
        polygonShapes: [SelectionPolygonShape],
        canvasSize: CanvasSize
    ) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: canvasSize.width * canvasSize.height)
        guard !polygonShapes.isEmpty else { return result }

        let allPoints = polygonShapes.flatMap { polygonShape in
            polygonShape.flatMap { polygon in
                polygon.map { CanvasPoint(x: Double($0.x), y: Double($0.y)) }
            }
        }
        let bounds = CanvasRect.bounding(points: allPoints).clamped(to: canvasSize)
        let minX = max(Int(floor(bounds.minX)) - 1, 0)
        let minY = max(Int(floor(bounds.minY)) - 1, 0)
        let maxX = min(Int(ceil(bounds.maxX)) + 1, canvasSize.width)
        let maxY = min(Int(ceil(bounds.maxY)) + 1, canvasSize.height)
        if RuntimeDiagnostics.selectionTraceLoggingEnabled {
            let rasterMessage = "[rasterizedSelectionMaskBytes] allPointCount=\(allPoints.count) clampedBoundsOrigin=(\(bounds.origin.x),\(bounds.origin.y)) clampedBoundsSize=(\(bounds.size.x),\(bounds.size.y)) localRect=(\(minX),\(minY))-(\(maxX),\(maxY))"
            Logger(subsystem: "ArtFlex", category: "SelectionTrace").debug("\(rasterMessage, privacy: .public)")

        }
        guard minX < maxX, minY < maxY else { return result }

        let width = maxX - minX
        let height = maxY - minY
        let bytesPerRow = width
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var localBytes = [UInt8](repeating: 0, count: width * height)

        guard let context = CGContext(
            data: &localBytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return result
        }
        context.translateBy(x: 0, y: Double(height))
        context.scaleBy(x: 1, y: -1)
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)

        for polygonShape in polygonShapes {
            for polygon in polygonShape {
                guard polygon.count >= 3 else { continue }
                let path = CGMutablePath()
                let localPoints = polygon.map {
                    CGPoint(x: $0.x - Double(minX), y: $0.y - Double(minY))
                }
                path.addLines(between: localPoints)
                path.closeSubpath()

                context.addPath(path)
                context.setBlendMode(.normal)
                context.setFillColor(gray: 1, alpha: 1)
                context.fillPath()
            }
        }

        for localY in 0..<height {
            let destinationRow = (localY + minY) * canvasSize.width
            let sourceRow = localY * width
            for localX in 0..<width {
                result[destinationRow + localX + minX] = localBytes[sourceRow + localX]
            }
        }

        return result
    }

    static func rasterizedSelectionMaskRegionBytes(
        polygonShapes: [SelectionPolygonShape],
        originX: Int,
        originY: Int,
        width: Int,
        height: Int
    ) -> Data {
        var result = Data(count: width * height)
        guard !polygonShapes.isEmpty, width > 0, height > 0 else { return result }

        let padding = 1
        let paddedWidth = width + (padding * 2)
        let paddedHeight = height + (padding * 2)
        let bytesPerRow = paddedWidth
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var paddedBytes = [UInt8](repeating: 0, count: paddedWidth * paddedHeight)

        guard let context = CGContext(
            data: &paddedBytes,
            width: paddedWidth,
            height: paddedHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return result
        }

        context.translateBy(
            x: Double(-originX + padding),
            y: Double(originY - padding + paddedHeight)
        )
        context.scaleBy(x: 1, y: -1)
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)

        for polygonShape in polygonShapes {
            for polygon in polygonShape {
                guard polygon.count >= 3 else { continue }
                let path = CGMutablePath()
                path.addLines(between: polygon)
                path.closeSubpath()

                context.addPath(path)
                context.setBlendMode(.normal)
                context.setFillColor(gray: 1, alpha: 1)
                context.fillPath()
            }
        }

        result.withUnsafeMutableBytes { destinationRawBuffer in
            paddedBytes.withUnsafeBufferPointer { sourceBuffer in
                guard
                    let destinationBase = destinationRawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    let sourceBase = sourceBuffer.baseAddress
                else {
                    return
                }

                for localY in 0..<height {
                    let destinationOffset = localY * width
                    let sourceOffset = ((localY + padding) * paddedWidth) + padding
                    UnsafeMutableRawPointer(destinationBase.advanced(by: destinationOffset))
                        .copyMemory(
                            from: UnsafeRawPointer(sourceBase.advanced(by: sourceOffset)),
                            byteCount: width
                        )
                }
            }
        }

        return result
    }

    static func selectionMaskPatch(
        from polygonShapes: [SelectionPolygonShape],
        canvasSize: CanvasSize
    ) -> SelectionMaskCombiner.Patch {
        let points = polygonShapes.lazy.flatMap { $0 }.flatMap { $0 }
        guard let first = points.first else {
            return .init(originX: 0, originY: 0, width: 0, height: 0, alphaBytes: Data())
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

        // Preserve Core Graphics antialiasing at the boundary without turning
        // a local gesture into a full-canvas rasterization.
        let originX = min(max(Int(minX.rounded(.down)) - 1, 0), canvasSize.width)
        let originY = min(max(Int(minY.rounded(.down)) - 1, 0), canvasSize.height)
        let endX = min(max(Int(maxX.rounded(.up)) + 1, 0), canvasSize.width)
        let endY = min(max(Int(maxY.rounded(.up)) + 1, 0), canvasSize.height)
        let width = max(endX - originX, 0)
        let height = max(endY - originY, 0)
        guard width > 0, height > 0 else {
            return .init(originX: 0, originY: 0, width: 0, height: 0, alphaBytes: Data())
        }

        return SelectionMaskCombiner.Patch(
            originX: originX,
            originY: originY,
            width: width,
            height: height,
            alphaBytes: rasterizedSelectionMaskRegionBytes(
                polygonShapes: polygonShapes,
                originX: originX,
                originY: originY,
                width: width,
                height: height
            )
        )
    }

    static func textureFillMaterialAngle(from points: [CanvasPoint]) -> Float {
        guard points.count >= 3 else { return 0 }
        let count = Double(points.count)
        let meanX = points.reduce(0) { $0 + $1.x } / count
        let meanY = points.reduce(0) { $0 + $1.y } / count
        var xx = 0.0
        var yy = 0.0
        var xy = 0.0
        for point in points {
            let dx = point.x - meanX
            let dy = point.y - meanY
            xx += dx * dx
            yy += dy * dy
            xy += dx * dy
        }
        return Float(0.5 * atan2(2 * xy, xx - yy))
    }

    static func textureFillSmoothFinalSelectionShape(
        from rawEdgePoints: [CanvasPoint],
        anchorPoint: CanvasPoint,
        canvasSize: CanvasSize
    ) -> SelectionShape? {
        let smoothedPoints = smoothedClosedLassoPoints(
            rawPoints: rawEdgePoints,
            closingTo: anchorPoint
        )
        guard smoothedPoints.count >= 3 else {
            return nil
        }
        return SelectionShape(
            kind: .lasso,
            bounds: CanvasRect.bounding(points: smoothedPoints),
            pathPoints: smoothedPoints
        ).clamped(to: canvasSize)
    }

}

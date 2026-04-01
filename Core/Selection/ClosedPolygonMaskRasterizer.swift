import CoreGraphics
import Foundation

func rasterizedClosedPolygonMaskBytes(
    points: [CanvasPoint],
    originX: Int,
    originY: Int,
    width: Int,
    height: Int,
    padding: Int = 1,
    supersampleScale: Int = 2
) -> [UInt8] {
    let path = smoothedClosedLassoPath(points: points) ?? {
        let fallback = CGMutablePath()
        fallback.addLines(between: points.map { CGPoint(x: $0.x, y: $0.y) })
        fallback.closeSubpath()
        return fallback
    }()
    return rasterizedClosedPolygonMaskBytes(
        path: path,
        originX: originX,
        originY: originY,
        width: width,
        height: height,
        padding: padding,
        supersampleScale: supersampleScale
    )
}

func rasterizedClosedPolygonMaskBytes(
    path: CGPath,
    originX: Int,
    originY: Int,
    width: Int,
    height: Int,
    padding: Int = 1,
    supersampleScale: Int = 2
) -> [UInt8] {
    var result = [UInt8](repeating: 0, count: max(width * height, 0))
    guard width > 0, height > 0 else { return result }
    let scale = max(supersampleScale, 1)

    let paddedWidth = width + (padding * 2)
    let paddedHeight = height + (padding * 2)
    let supersampledWidth = paddedWidth * scale
    let supersampledHeight = paddedHeight * scale
    let bytesPerRow = supersampledWidth
    let colorSpace = CGColorSpaceCreateDeviceGray()
    var paddedBytes = [UInt8](repeating: 0, count: supersampledWidth * supersampledHeight)

    guard let context = CGContext(
        data: &paddedBytes,
        width: supersampledWidth,
        height: supersampledHeight,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else {
        return result
    }

    context.translateBy(
        x: Double(-originX + padding) * Double(scale),
        y: Double(originY - padding + paddedHeight) * Double(scale)
    )
    context.scaleBy(x: Double(scale), y: -Double(scale))
    context.setShouldAntialias(true)
    context.setAllowsAntialiasing(true)

    context.addPath(path)
    context.setBlendMode(.normal)
    context.setFillColor(gray: 1, alpha: 1)
    context.fillPath()

    result.withUnsafeMutableBufferPointer { destinationBuffer in
        paddedBytes.withUnsafeBufferPointer { sourceBuffer in
            guard
                let destinationBase = destinationBuffer.baseAddress,
                let sourceBase = sourceBuffer.baseAddress
            else {
                return
            }

            for localY in 0..<height {
                let destinationOffset = localY * width
                let sourceY = (localY + padding) * scale
                for localX in 0..<width {
                    let sourceX = (localX + padding) * scale
                    var total = 0
                    for sampleY in 0..<scale {
                        let rowOffset = (sourceY + sampleY) * supersampledWidth
                        for sampleX in 0..<scale {
                            total += Int(sourceBase[rowOffset + sourceX + sampleX])
                        }
                    }
                    destinationBase[destinationOffset + localX] = UInt8(total / (scale * scale))
                }
            }
        }
    }

    return result
}

import Foundation

struct TextureFillProceduralFieldConfiguration {
    var baseStampRadius: Double
    var radialSpacing: Double
    var chordSpacing: Double
    var gapProbability: Double

    static let phase3Default = TextureFillProceduralFieldConfiguration(
        baseStampRadius: 5,
        radialSpacing: 9,
        chordSpacing: 11,
        gapProbability: 0.35
    )
}

enum TextureFillProceduralField {
    static func sessionSeed(anchorPoint: CanvasPoint) -> UInt64 {
        let quantizedX = UInt64(bitPattern: Int64((anchorPoint.x * 1024).rounded()))
        let quantizedY = UInt64(bitPattern: Int64((anchorPoint.y * 1024).rounded()))
        return splitMix64(quantizedX ^ (quantizedY &* 0x9E37_79B9_7F4A_7C15))
    }

    static func alphaBytes(
        baseMaskOriginX: Int,
        baseMaskOriginY: Int,
        width: Int,
        height: Int,
        baseMaskAlphaBytes: Data,
        anchorPoint: CanvasPoint,
        previousEdgePoint: CanvasPoint,
        currentEdgePoint: CanvasPoint,
        sessionSeed: UInt64,
        configuration: TextureFillProceduralFieldConfiguration = .phase3Default
    ) -> Data {
        guard width > 0, height > 0 else { return Data() }

        let totalCount = width * height
        var baseMask = [UInt8](repeating: 0, count: totalCount)
        baseMaskAlphaBytes.withUnsafeBytes { rawBuffer in
            let source = rawBuffer.bindMemory(to: UInt8.self)
            guard let sourceBaseAddress = source.baseAddress else { return }
            baseMask.withUnsafeMutableBufferPointer { destination in
                guard let destinationBaseAddress = destination.baseAddress else { return }
                destinationBaseAddress.update(from: sourceBaseAddress, count: min(totalCount, source.count))
            }
        }

        let previousDistance = max(distance(from: anchorPoint, to: previousEdgePoint), 0.0001)
        let currentDistance = max(distance(from: anchorPoint, to: currentEdgePoint), 0.0001)
        let maxRadius = max(previousDistance, currentDistance)
        guard maxRadius > 0 else { return Data(baseMask) }

        var dabMask = [UInt8](repeating: 0, count: totalCount)
        let baseRadius = configuration.baseStampRadius
        var randomIndex = 0
        var radius = baseRadius

        while radius <= maxRadius + baseRadius {
            let previousT = min(max(radius / previousDistance, 0), 1)
            let currentT = min(max(radius / currentDistance, 0), 1)
            let previousPoint = interpolatedPoint(anchorPoint, previousEdgePoint, t: previousT)
            let currentPoint = interpolatedPoint(anchorPoint, currentEdgePoint, t: currentT)
            let spanLength = distance(from: previousPoint, to: currentPoint)
            let stepCount = max(Int((spanLength / configuration.chordSpacing).rounded(.up)), 1)
            let rotation = atan2(currentPoint.y - previousPoint.y, currentPoint.x - previousPoint.x)

            for index in 0...stepCount {
                let t = stepCount == 0 ? 0.5 : Double(index) / Double(stepCount)
                let gapRoll = randomUnit(sessionSeed: sessionSeed, index: randomIndex)
                randomIndex += 1
                if gapRoll < configuration.gapProbability {
                    continue
                }

                let center = interpolatedPoint(previousPoint, currentPoint, t: t)
                let radiusScale = 0.8 + (0.4 * randomUnit(sessionSeed: sessionSeed, index: randomIndex))
                randomIndex += 1
                let secondaryScale = 0.55 + (0.25 * randomUnit(sessionSeed: sessionSeed, index: randomIndex))
                randomIndex += 1
                let jitterX = (randomUnit(sessionSeed: sessionSeed, index: randomIndex) - 0.5) * 1.5
                randomIndex += 1
                let jitterY = (randomUnit(sessionSeed: sessionSeed, index: randomIndex) - 0.5) * 1.5
                randomIndex += 1

                stampEllipse(
                    into: &dabMask,
                    originX: baseMaskOriginX,
                    originY: baseMaskOriginY,
                    width: width,
                    height: height,
                    center: CanvasPoint(x: center.x + jitterX, y: center.y + jitterY),
                    radiusX: max(baseRadius * radiusScale, 1),
                    radiusY: max(baseRadius * secondaryScale, 1),
                    rotationRadians: rotation
                )
            }

            radius += configuration.radialSpacing
        }

        var output = [UInt8](repeating: 0, count: totalCount)
        for index in 0..<totalCount where baseMask[index] > 0 && dabMask[index] > 0 {
            output[index] = min(baseMask[index], dabMask[index])
        }
        return Data(output)
    }

    private static func randomUnit(sessionSeed: UInt64, index: Int) -> Double {
        let mixed = splitMix64(sessionSeed &+ (UInt64(index) &* 0x9E37_79B9_7F4A_7C15))
        return Double(mixed >> 11) / Double(1 << 53)
    }

    private static func splitMix64(_ value: UInt64) -> UInt64 {
        var state = value &+ 0x9E37_79B9_7F4A_7C15
        state = (state ^ (state >> 30)) &* 0xBF58_476D_1CE4_E5B9
        state = (state ^ (state >> 27)) &* 0x94D0_49BB_1331_11EB
        return state ^ (state >> 31)
    }

    private static func interpolatedPoint(_ start: CanvasPoint, _ end: CanvasPoint, t: Double) -> CanvasPoint {
        CanvasPoint(
            x: start.x + ((end.x - start.x) * t),
            y: start.y + ((end.y - start.y) * t)
        )
    }

    private static func distance(from start: CanvasPoint, to end: CanvasPoint) -> Double {
        hypot(end.x - start.x, end.y - start.y)
    }

    private static func stampEllipse(
        into alphaBytes: inout [UInt8],
        originX: Int,
        originY: Int,
        width: Int,
        height: Int,
        center: CanvasPoint,
        radiusX: Double,
        radiusY: Double,
        rotationRadians: Double
    ) {
        guard radiusX > 0, radiusY > 0 else { return }

        let minX = max(Int(floor(center.x - radiusX)) - originX, 0)
        let minY = max(Int(floor(center.y - radiusY)) - originY, 0)
        let maxX = min(Int(ceil(center.x + radiusX)) - originX, width - 1)
        let maxY = min(Int(ceil(center.y + radiusY)) - originY, height - 1)
        guard minX <= maxX, minY <= maxY else { return }

        let cosTheta = cos(rotationRadians)
        let sinTheta = sin(rotationRadians)

        for localY in minY...maxY {
            let worldY = Double(originY + localY) + 0.5
            for localX in minX...maxX {
                let worldX = Double(originX + localX) + 0.5
                let translatedX = worldX - center.x
                let translatedY = worldY - center.y
                let rotatedX = (translatedX * cosTheta) + (translatedY * sinTheta)
                let rotatedY = (-translatedX * sinTheta) + (translatedY * cosTheta)
                let normalized = (rotatedX * rotatedX) / (radiusX * radiusX) + (rotatedY * rotatedY) / (radiusY * radiusY)
                if normalized <= 1 {
                    alphaBytes[(localY * width) + localX] = 255
                }
            }
        }
    }
}

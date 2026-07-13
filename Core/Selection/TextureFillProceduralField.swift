import Foundation

enum TextureFillProceduralField {
    static func sessionSeed(anchorPoint: CanvasPoint, sequence: UInt64 = 0) -> UInt64 {
        let quantizedX = UInt64(bitPattern: Int64((anchorPoint.x * 1024).rounded()))
        let quantizedY = UInt64(bitPattern: Int64((anchorPoint.y * 1024).rounded()))
        let anchorSeed = quantizedX ^ (quantizedY &* 0x9E37_79B9_7F4A_7C15)
        return splitMix64(anchorSeed ^ splitMix64(sequence))
    }

    static func importedRegionAlphaBytes(
        baseMaskOriginX: Int,
        baseMaskOriginY: Int,
        width: Int,
        height: Int,
        baseMaskAlphaBytes: Data,
        fieldBounds: CanvasRect,
        stampMaskData: Data,
        importedSourceInfo: ImportedTipSourceInfo? = nil
    ) -> Data {
        guard width > 0, height > 0 else { return Data() }
        guard let resolvedMask = resolvedStampMask(from: stampMaskData) else { return Data() }

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

        let contentWidth = max(resolvedMask.contentMaxX - resolvedMask.contentMinX + 1, 1)
        let contentHeight = max(resolvedMask.contentMaxY - resolvedMask.contentMinY + 1, 1)
        let sourceAspect = importedSourceInfo.map {
            Double($0.pixelWidth) / max(Double($0.pixelHeight), 1)
        } ?? (Double(contentWidth) / Double(contentHeight))

        let boundsWidth = max(fieldBounds.maxX - fieldBounds.minX, 1)
        let boundsHeight = max(fieldBounds.maxY - fieldBounds.minY, 1)
        let boundsAspect = boundsWidth / boundsHeight

        var sampleWidth = boundsWidth
        var sampleHeight = boundsHeight
        var offsetX = 0.0
        var offsetY = 0.0

        if sourceAspect > boundsAspect {
            sampleWidth = boundsHeight * sourceAspect
            offsetX = (boundsWidth - sampleWidth) * 0.5
        } else {
            sampleHeight = boundsWidth / max(sourceAspect, 0.0001)
            offsetY = (boundsHeight - sampleHeight) * 0.5
        }

        let sampleMinX = fieldBounds.minX + offsetX
        let sampleMinY = fieldBounds.minY + offsetY
        let sampleMaxX = sampleMinX + sampleWidth
        let sampleMaxY = sampleMinY + sampleHeight

        var output = [UInt8](repeating: 0, count: totalCount)
        for localY in 0..<height {
            let worldY = Double(baseMaskOriginY + localY) + 0.5
            for localX in 0..<width {
                let index = (localY * width) + localX
                guard baseMask[index] > 0 else { continue }

                let worldX = Double(baseMaskOriginX + localX) + 0.5
                guard
                    worldX >= sampleMinX,
                    worldX <= sampleMaxX,
                    worldY >= sampleMinY,
                    worldY <= sampleMaxY
                else {
                    continue
                }

                let normalizedX = min(max((worldX - sampleMinX) / max(sampleWidth, 0.0001), 0), 1)
                let normalizedY = min(max((worldY - sampleMinY) / max(sampleHeight, 0.0001), 0), 1)
                let sampleX = resolvedMask.contentMinX
                    + min(max(Int((normalizedX * Double(contentWidth - 1)).rounded()), 0), contentWidth - 1)
                let sampleY = resolvedMask.contentMinY
                    + min(max(Int((normalizedY * Double(contentHeight - 1)).rounded()), 0), contentHeight - 1)
                let sampleAlpha = resolvedMask.bytes[(sampleY * resolvedMask.resolution) + sampleX]
                guard sampleAlpha > 0 else { continue }
                output[index] = min(baseMask[index], sampleAlpha)
            }
        }

        return Data(output)
    }

    private static func splitMix64(_ value: UInt64) -> UInt64 {
        var state = value &+ 0x9E37_79B9_7F4A_7C15
        state = (state ^ (state >> 30)) &* 0xBF58_476D_1CE4_E5B9
        state = (state ^ (state >> 27)) &* 0x94D0_49BB_1331_11EB
        return state ^ (state >> 31)
    }

    private static func resolvedStampMask(from stampMaskData: Data?) -> (
        bytes: [UInt8],
        resolution: Int,
        contentMinX: Int,
        contentMaxX: Int,
        contentMinY: Int,
        contentMaxY: Int
    )? {
        guard let stampMaskData, !stampMaskData.isEmpty else { return nil }
        let count = stampMaskData.count
        let resolution = Int(Double(count).squareRoot())
        guard resolution > 0, resolution * resolution == count else { return nil }
        let bytes = [UInt8](stampMaskData)
        var minX = resolution
        var maxX = -1
        var minY = resolution
        var maxY = -1

        for y in 0..<resolution {
            for x in 0..<resolution where bytes[(y * resolution) + x] > 0 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }

        guard maxX >= minX, maxY >= minY else { return nil }
        return (bytes, resolution, minX, maxX, minY, maxY)
    }
}

enum TextureFillMaterialResponse {
    static func amplifiedCoverage(_ coverage: Float) -> Float {
        amplifiedTail(value: coverage, tailStart: 0.65, maximumMultiplier: 2)
    }

    static func amplifiedVariation(_ variation: Float) -> Float {
        amplifiedTail(value: variation, tailStart: 0.55, maximumMultiplier: 4)
    }

    private static func amplifiedTail(
        value: Float,
        tailStart: Float,
        maximumMultiplier: Float
    ) -> Float {
        let clamped = min(max(value, 0), 1)
        guard clamped > tailStart else { return clamped }
        let normalized = (clamped - tailStart) / (1 - tailStart)
        let smoothTail = normalized * normalized * (3 - (2 * normalized))
        return clamped * (1 + ((maximumMultiplier - 1) * smoothTail))
    }
}

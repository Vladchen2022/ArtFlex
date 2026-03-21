import AppKit
import CoreGraphics
import Foundation
import simd

@MainActor
final class ImagePaletteExtractor {
    func extractPalette(from url: URL, count: Int = 25) throws -> [RGBAColor] {
        guard let image = NSImage(contentsOf: url) else {
            throw NSError(domain: "ArtFlex.ImagePaletteExtractor", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "无法打开图片"
            ])
        }

        return try extractPalette(from: image, count: count)
    }

    func extractPalette(from image: NSImage, count: Int = 25) throws -> [RGBAColor] {
        let thumbnailSize = 220
        let rect = CGRect(x: 0, y: 0, width: thumbnailSize, height: thumbnailSize)
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: thumbnailSize,
                height: thumbnailSize,
                bitsPerComponent: 8,
                bytesPerRow: thumbnailSize * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw NSError(domain: "ArtFlex.ImagePaletteExtractor", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "无法创建图片采样上下文"
            ])
        }

        context.interpolationQuality = .medium
        context.setFillColor(NSColor.white.cgColor)
        context.fill(rect)

        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            context.draw(cgImage, in: rect)
        } else {
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: thumbnailSize,
                pixelsHigh: thumbnailSize,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: thumbnailSize * 4,
                bitsPerPixel: 32
            )
            guard let rep else {
                throw NSError(domain: "ArtFlex.ImagePaletteExtractor", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "无法读取图片像素"
                ])
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
            guard let fallbackImage = rep.cgImage else {
                throw NSError(domain: "ArtFlex.ImagePaletteExtractor", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "无法生成图片位图"
                ])
            }
            context.draw(fallbackImage, in: rect)
        }

        guard let data = context.data else {
            throw NSError(domain: "ArtFlex.ImagePaletteExtractor", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "无法访问图片采样数据"
            ])
        }

        let bytes = data.bindMemory(to: UInt8.self, capacity: thumbnailSize * thumbnailSize * 4)
        let samples = samplePixels(from: bytes, width: thumbnailSize, height: thumbnailSize)
        guard samples.count >= 80 else {
            throw NSError(domain: "ArtFlex.ImagePaletteExtractor", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "图片中可用颜色过少"
            ])
        }

        let palette = kmeans(samples: samples, k: count)
        return ColorBlocksEngine.orderPaletteForGrid(palette)
    }

    private func samplePixels(from bytes: UnsafePointer<UInt8>, width: Int, height: Int) -> [SIMD3<Float>] {
        let maxSamples = 12_000
        let total = width * height
        let step = max(1, total / maxSamples)
        var samples: [SIMD3<Float>] = []
        samples.reserveCapacity(maxSamples)

        for pixelIndex in stride(from: 0, to: total, by: step) {
            let base = pixelIndex * 4
            let r = Float(bytes[base]) / 255
            let g = Float(bytes[base + 1]) / 255
            let b = Float(bytes[base + 2]) / 255
            let maxValue = max(r, max(g, b))
            let minValue = min(r, min(g, b))
            if maxValue < 0.03 || minValue > 0.97 {
                continue
            }
            let hsv = ColorBlocksEngine.rgbToHsv(RGBAColor(red: r, green: g, blue: b, alpha: 1))
            if hsv.s < 0.03 {
                continue
            }
            samples.append(SIMD3<Float>(r, g, b))
            if samples.count >= maxSamples {
                break
            }
        }

        return samples
    }

    private func initKMeansPP(samples: [SIMD3<Float>], k: Int) -> [SIMD3<Float>] {
        var centers: [SIMD3<Float>] = [samples.randomElement() ?? SIMD3<Float>(repeating: 0.5)]
        var distances = Array(repeating: Float.zero, count: samples.count)

        while centers.count < k {
            var sum: Float = 0
            for (index, sample) in samples.enumerated() {
                var best = Float.greatestFiniteMagnitude
                for center in centers {
                    best = min(best, simd_distance_squared(sample, center))
                }
                distances[index] = best
                sum += best
            }

            var pick = Float.random(in: 0...max(sum, 0.0001))
            var pickedIndex = 0
            for (index, distance) in distances.enumerated() {
                pick -= distance
                if pick <= 0 {
                    pickedIndex = index
                    break
                }
            }

            centers.append(samples[pickedIndex])
        }

        return centers
    }

    private func kmeans(samples: [SIMD3<Float>], k: Int) -> [RGBAColor] {
        var centers = initKMeansPP(samples: samples, k: k)
        var assignments = Array(repeating: 0, count: samples.count)

        for _ in 0..<10 {
            for (sampleIndex, sample) in samples.enumerated() {
                var bestIndex = 0
                var bestDistance = Float.greatestFiniteMagnitude
                for (centerIndex, center) in centers.enumerated() {
                    let distance = simd_distance_squared(sample, center)
                    if distance < bestDistance {
                        bestDistance = distance
                        bestIndex = centerIndex
                    }
                }
                assignments[sampleIndex] = bestIndex
            }

            var sums = Array(repeating: SIMD4<Float>(repeating: 0), count: k)
            for (sampleIndex, sample) in samples.enumerated() {
                let cluster = assignments[sampleIndex]
                sums[cluster].x += sample.x
                sums[cluster].y += sample.y
                sums[cluster].z += sample.z
                sums[cluster].w += 1
            }

            for cluster in 0..<k {
                if sums[cluster].w == 0 {
                    centers[cluster] = samples.randomElement() ?? centers[cluster]
                } else {
                    centers[cluster] = SIMD3<Float>(
                        sums[cluster].x / sums[cluster].w,
                        sums[cluster].y / sums[cluster].w,
                        sums[cluster].z / sums[cluster].w
                    )
                }
            }
        }

        let colors = centers.map {
            RGBAColor(red: $0.x, green: $0.y, blue: $0.z, alpha: 1)
        }

        return dedupe(colors: colors, targetCount: k)
    }

    private func dedupe(colors: [RGBAColor], targetCount: Int) -> [RGBAColor] {
        var output: [RGBAColor] = []
        let minimumDistanceSquared: Float = pow(18.0 / 255.0, 2)

        for color in colors {
            let isDistinct = output.allSatisfy { existing in
                let dr = color.red - existing.red
                let dg = color.green - existing.green
                let db = color.blue - existing.blue
                return dr * dr + dg * dg + db * db >= minimumDistanceSquared
            }
            if isDistinct {
                output.append(color)
            }
        }

        while output.count < targetCount, !colors.isEmpty {
            output.append(colors[output.count % colors.count])
        }

        return Array(output.prefix(targetCount))
    }
}

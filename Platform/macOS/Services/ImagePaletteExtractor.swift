import AppKit
import Combine
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import simd

@MainActor
final class ImagePaletteExtractor: ObservableObject {
    @Published private(set) var isExtracting = false
    @Published private(set) var errorMessage: String?
    private var request: WorkCancellation?
    // One decoder at a time: rapid drops cannot allocate several large images in parallel.
    private static let queue = DispatchQueue(label: "ArtFlex.palette-import", qos: .userInitiated)

    enum Source: Sendable {
        case file(URL)
        case encoded(Data)
    }

    typealias Completion = @MainActor @Sendable ([RGBAColor], String) -> Void

    func cancel() {
        request?.cancel()
        request = nil
        isExtracting = false
        errorMessage = nil
    }

    private func beginRequest() -> WorkCancellation {
        cancel()
        let next = WorkCancellation()
        request = next
        isExtracting = true
        return next
    }

    func start(from source: Source, name: String, completion: @escaping Completion) {
        run(source, name: name, request: beginRequest(), completion: completion)
    }

    @discardableResult
    func start(from pasteboard: NSPasteboard, completion: @escaping Completion) -> Bool {
        // Prefer encoded bytes / file URLs. NSImage.tiffRepresentation may decode a full image on the UI thread.
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL])?.first {
            start(from: .file(url), name: url.deletingPathExtension().lastPathComponent, completion: completion)
            return true
        }
        for identifier in [UTType.png.identifier, UTType.tiff.identifier, UTType.jpeg.identifier, UTType.heic.identifier] {
            if let data = pasteboard.data(forType: .init(identifier)) {
                start(from: .encoded(data), name: "剪贴板图片", completion: completion)
                return true
            }
        }
        cancel()
        errorMessage = "剪贴板中没有可读取的图片，原色板未改变"
        return false
    }

    @discardableResult
    func start(from providers: [NSItemProvider], completion: @escaping Completion) -> Bool {
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            let current = beginRequest()
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { [weak self] data, error in
                Task { @MainActor in
                    guard let self, self.request === current else { return }
                    guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else {
                        self.finishFailure(error ?? Self.failure("无法读取拖入的图片文件"), request: current)
                        return
                    }
                    self.run(.file(url), name: url.deletingPathExtension().lastPathComponent,
                             request: current, completion: completion)
                }
            }
            return true
        }
        for provider in providers {
            let types = provider.registeredTypeIdentifiers
            let preferred = [UTType.png.identifier, UTType.tiff.identifier, UTType.jpeg.identifier, UTType.heic.identifier]
            guard let identifier = preferred.first(where: { types.contains($0) })
                    ?? types.first(where: { UTType($0)?.conforms(to: .image) == true }) else { continue }
            let current = beginRequest()
            provider.loadDataRepresentation(forTypeIdentifier: identifier) { [weak self] data, error in
                Task { @MainActor in
                    guard let self, self.request === current else { return }
                    guard let data else {
                        self.finishFailure(error ?? Self.failure("无法读取拖入的图片"), request: current)
                        return
                    }
                    self.run(.encoded(data), name: "拖入图片", request: current, completion: completion)
                }
            }
            return true
        }
        return false
    }

    private func run(_ source: Source, name: String, request current: WorkCancellation, completion: @escaping Completion) {
        Self.queue.async { [weak self] in
            let result: Result<[RGBAColor], Error> = Result {
                try current.check()
                return try autoreleasepool {
                    let samples = try Self.prepareSamples(from: source, cancellation: current)
                    try current.check()
                    let colors = Self.palette(from: samples, cancellation: current)
                    try current.check()
                    return colors
                }
            }
            Task { @MainActor in
                guard let self, self.request === current, !current.isCancelled else { return }
                switch result {
                case .success(let colors):
                    self.request = nil
                    self.isExtracting = false
                    completion(colors, name)
                case .failure(let error):
                    self.finishFailure(error, request: current)
                }
            }
        }
    }

    private func finishFailure(_ error: Error, request current: WorkCancellation) {
        guard request === current else { return }
        request = nil
        isExtracting = false
        errorMessage = "\(error.localizedDescription)，原色板未改变"
    }

    nonisolated private static func failure(_ message: String) -> NSError {
        NSError(domain: "ArtFlex.ImagePaletteExtractor", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    nonisolated static func prepareSamples(from source: Source, cancellation: WorkCancellation) throws -> [SIMD3<Float>] {
        try cancellation.check()
        let imageSource: CGImageSource?
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        let accessedURL: URL?
        switch source {
        case .file(let url):
            accessedURL = url.startAccessingSecurityScopedResource() ? url : nil
            imageSource = CGImageSourceCreateWithURL(url as CFURL, options)
        case .encoded(let data):
            accessedURL = nil
            imageSource = CGImageSourceCreateWithData(data as CFData, options)
        }
        defer { accessedURL?.stopAccessingSecurityScopedResource() }
        guard let imageSource,
              let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 220
              ] as CFDictionary) else {
            throw failure("无法解码图片，文件可能损坏或格式不受支持")
        }
        try cancellation.check()
        // No full-resolution fallback. The sampling buffer is bounded by 220 × 220.
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width <= 220, height <= 220 else { throw failure("图片尺寸无效") }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            )
        else {
            throw failure("无法创建图片采样上下文")
        }
        context.interpolationQuality = .medium
        context.clear(rect)
        context.draw(image, in: rect)
        guard let data = context.data else {
            throw failure("无法访问图片采样数据")
        }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let samples = samplePixels(from: bytes, width: width, height: height)
        guard !samples.isEmpty else { throw failure("图片没有可见像素") }
        return samples
    }

    nonisolated static func palette(
        from samples: [SIMD3<Float>], count: Int = 25, cancellation: WorkCancellation? = nil
    ) -> [RGBAColor] {
        guard !samples.isEmpty, cancellation?.isCancelled != true else { return [] }
        return ColorBlocksEngine.orderPaletteForGrid(kmeans(samples: samples, k: min(max(count, 1), 64), cancellation: cancellation))
    }

    nonisolated private static func samplePixels(from bytes: UnsafePointer<UInt8>, width: Int, height: Int) -> [SIMD3<Float>] {
        let maxSamples = 12_000
        let total = width * height
        let sampleCount = min(total, maxSamples)
        var samples: [SIMD3<Float>] = []
        samples.reserveCapacity(maxSamples)

        for sampleIndex in 0..<sampleCount {
            let pixelIndex = sampleIndex * total / sampleCount
            let base = pixelIndex * 4
            let alpha = Float(bytes[base + 3])
            guard alpha >= 16 else { continue }
            let r = min(Float(bytes[base]) / alpha, 1)
            let g = min(Float(bytes[base + 1]) / alpha, 1)
            let b = min(Float(bytes[base + 2]) / alpha, 1)
            samples.append(SIMD3<Float>(r, g, b))
        }

        return samples
    }

    nonisolated private static func initKMeansPP(samples: [SIMD3<Float>], k: Int, cancellation: WorkCancellation?) -> [SIMD3<Float>] {
        var random = SeededGeneratorRandom(seed: 0x41525450414C4554)
        var centers: [SIMD3<Float>] = [samples.randomElement(using: &random) ?? SIMD3<Float>(repeating: 0.5)]
        var distances = Array(repeating: Float.zero, count: samples.count)

        while centers.count < k {
            guard cancellation?.isCancelled != true else { return [] }
            var sum: Float = 0
            for (index, sample) in samples.enumerated() {
                var best = Float.greatestFiniteMagnitude
                for center in centers {
                    best = min(best, simd_distance_squared(sample, center))
                }
                distances[index] = best
                sum += best
            }

            var pick = random.nextFloat(in: 0...max(sum, 0.0001))
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

    nonisolated private static func kmeans(samples: [SIMD3<Float>], k: Int, cancellation: WorkCancellation?) -> [RGBAColor] {
        var centers = initKMeansPP(samples: samples, k: k, cancellation: cancellation)
        guard centers.count == k else { return [] }
        var assignments = Array(repeating: 0, count: samples.count)

        for _ in 0..<10 {
            guard cancellation?.isCancelled != true else { return [] }
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
                    centers[cluster] = samples[(cluster * 499) % samples.count]
                } else {
                    centers[cluster] = SIMD3<Float>(
                        sums[cluster].x / sums[cluster].w,
                        sums[cluster].y / sums[cluster].w,
                        sums[cluster].z / sums[cluster].w
                    )
                }
            }
        }

        var populations = Array(repeating: 0, count: k)
        for assignment in assignments { populations[assignment] += 1 }
        // Do not spend most swatches on interpolation slivers between large flat areas.
        let minimumPopulation = max(1, samples.count / 200)
        let colors = centers.enumerated().filter { populations[$0.offset] >= minimumPopulation }.map { _, center in
            RGBAColor(red: center.x, green: center.y, blue: center.z, alpha: 1)
        }

        return dedupe(colors: colors, targetCount: k)
    }

    nonisolated private static func dedupe(colors: [RGBAColor], targetCount: Int) -> [RGBAColor] {
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

        let distinct = output
        while output.count < targetCount, !distinct.isEmpty {
            output.append(distinct[output.count % distinct.count])
        }

        return Array(output.prefix(targetCount))
    }
}

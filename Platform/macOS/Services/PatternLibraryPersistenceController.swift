import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class PatternImportPreviewAsset: @unchecked Sendable {
    let fileName: String
    let sourcePixelWidth: Int
    let sourcePixelHeight: Int
    let processedPixelWidth: Int
    let processedPixelHeight: Int
    let originalImage: CGImage
    let processedImage: CGImage
    let processedPreviewPixelWidth: Int
    let processedPreviewPixelHeight: Int
    let processedPreviewRGBABytes: Data

    init(
        fileName: String,
        sourcePixelWidth: Int,
        sourcePixelHeight: Int,
        processedPixelWidth: Int,
        processedPixelHeight: Int,
        originalImage: CGImage,
        processedImage: CGImage,
        processedPreviewPixelWidth: Int,
        processedPreviewPixelHeight: Int,
        processedPreviewRGBABytes: Data
    ) {
        self.fileName = fileName
        self.sourcePixelWidth = sourcePixelWidth
        self.sourcePixelHeight = sourcePixelHeight
        self.processedPixelWidth = processedPixelWidth
        self.processedPixelHeight = processedPixelHeight
        self.originalImage = originalImage
        self.processedImage = processedImage
        self.processedPreviewPixelWidth = processedPreviewPixelWidth
        self.processedPreviewPixelHeight = processedPreviewPixelHeight
        self.processedPreviewRGBABytes = processedPreviewRGBABytes
    }
}

final class PatternImportPreviewSourceAsset: @unchecked Sendable {
    let fileName: String
    let image: DecodedPatternImage
    let originalPreviewImage: CGImage

    init(
        fileName: String,
        image: DecodedPatternImage,
        originalPreviewImage: CGImage
    ) {
        self.fileName = fileName
        self.image = image
        self.originalPreviewImage = originalPreviewImage
    }
}

struct PatternLibraryLoadResult {
    let library: PatternLibraryState
    let didSanitize: Bool
}

struct PatternLibraryImportBatchResult {
    let updatedLibrary: PatternLibraryState
    let importedItems: [PatternLibraryItem]
    let skippedDuplicateCount: Int
    let failedFileNames: [String]
}

struct DecodedPatternImage {
    let width: Int
    let height: Int
    let rgbaBytes: [UInt8]
}

struct CroppedPatternImage {
    let image: DecodedPatternImage
    let cropped: Bool
}

final class PatternLibraryPersistenceController: @unchecked Sendable {
    // The render asset is the painting source, not a thumbnail. A 1,000 px cap
    // becomes visibly soft on modern canvases; keep a practical GPU-safe working
    // copy and continue generating the small thumbnail separately.
    private static let maximumImportDimension = 4096
    private let fileManager: FileManager
    private let rootDirectoryURL: URL?
    private let protectedFile = ProtectedLibraryFile()
    var loadFailureDescription: String? { protectedFile.loadFailureDescription }

    init(
        fileManager: FileManager = .default,
        rootDirectoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.rootDirectoryURL = rootDirectoryURL
    }

    func loadLibrary() -> PatternLibraryLoadResult? {
        guard let url = persistentLibraryURL() else { return nil }
        guard let library = protectedFile.load(from: url, decode: {
            try JSONDecoder().decode(PatternLibraryState.self, from: $0)
        }) else { return nil }

        let sanitized = sanitizedLibraryRemovingMissingAssets(library)
        return PatternLibraryLoadResult(
            library: sanitized,
            didSanitize: sanitized != library
        )
    }

    func saveLibrary(_ library: PatternLibraryState) throws {
        guard let url = persistentLibraryURL(createDirectories: true) else {
            throw NSError(domain: "ArtFlex.PatternLibraryPersistence", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "无法创建图案库存储目录"
            ])
        }

        let data = try Self.makeEncoder().encode(library)
        try protectedFile.save(data, to: url) { _ = try JSONDecoder().decode(PatternLibraryState.self, from: $0) }
        purgeOrphanedManagedAssets(for: library)
    }

    func resolveAssetURL(for location: PatternAssetLocation) -> URL? {
        switch location {
        case .managedCopy(let relativePath):
            guard let root = patternLibraryRootURL(createDirectories: false) else { return nil }
            return root.appendingPathComponent(relativePath)
        case .externalReference(let bookmarkData):
            var isStale = false
            return try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withoutUI, .withoutMounting],
                bookmarkDataIsStale: &isStale
            )
        }
    }

    func revealableURL(for item: PatternLibraryItem) -> URL? {
        resolveAssetURL(for: item.renderAssetLocation)
    }

    func loadRenderImage(for item: PatternLibraryItem) -> DecodedPatternImage? {
        guard let url = resolveAssetURL(for: item.renderAssetLocation) else {
            return nil
        }
        return decodeImage(at: url)
    }

    func removeAssets(for item: PatternLibraryItem) {
        if case .managedCopy(let relativePath) = item.renderAssetLocation,
           let url = patternLibraryRootURL(createDirectories: false)?.appendingPathComponent(relativePath) {
            try? fileManager.removeItem(at: url)
        }

        if case .managedCopy(let relativePath) = item.thumbnailLocation,
           let url = patternLibraryRootURL(createDirectories: false)?.appendingPathComponent(relativePath) {
            try? fileManager.removeItem(at: url)
        }
    }

    func rebuildThumbnail(for item: PatternLibraryItem) throws {
        guard let renderURL = resolveAssetURL(for: item.renderAssetLocation),
              let sourceImage = decodeImage(at: renderURL) else {
            throw NSError(domain: "ArtFlex.PatternLibraryPersistence", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "无法读取图案渲染素材"
            ])
        }

        guard let thumbnailURL = resolveAssetURL(for: item.thumbnailLocation) else {
            throw NSError(domain: "ArtFlex.PatternLibraryPersistence", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "无法定位图案缩略图"
            ])
        }

        try ensureParentDirectoryExists(for: thumbnailURL)
        let thumbnail = makeThumbnailImage(from: sourceImage, maxDimension: 256)
        try writePNG(image: thumbnail, to: thumbnailURL)
    }

    func rebuildAllThumbnails(in library: PatternLibraryState) throws {
        for item in library.items {
            try rebuildThumbnail(for: item)
        }
    }

    func makePreviewSource(for fileURL: URL) -> PatternImportPreviewSourceAsset? {
        guard let sourceImage = preparedImportSourceImage(at: fileURL) else {
            return nil
        }

        guard let originalPreview = makePreviewImage(from: sourceImage, maxDimension: 560) else {
            return nil
        }

        return PatternImportPreviewSourceAsset(
            fileName: fileURL.lastPathComponent,
            image: sourceImage,
            originalPreviewImage: originalPreview
        )
    }

    func makePreview(
        from source: PatternImportPreviewSourceAsset,
        recipe: PatternImportRecipe
    ) -> PatternImportPreviewAsset? {
        let processed = processDecodedImage(source.image, recipe: recipe)
        let processedPreviewImage = makeThumbnailImage(from: processed.image, maxDimension: 560)
        guard let processedPreviewCGImage = makeCGImage(from: processedPreviewImage, shouldInterpolate: true) else {
            return nil
        }

        return PatternImportPreviewAsset(
            fileName: source.fileName,
            sourcePixelWidth: source.image.width,
            sourcePixelHeight: source.image.height,
            processedPixelWidth: processed.image.width,
            processedPixelHeight: processed.image.height,
            originalImage: source.originalPreviewImage,
            processedImage: processedPreviewCGImage,
            processedPreviewPixelWidth: processedPreviewImage.width,
            processedPreviewPixelHeight: processedPreviewImage.height,
            processedPreviewRGBABytes: Data(processedPreviewImage.rgbaBytes)
        )
    }

    func makePreview(
        for fileURL: URL,
        recipe: PatternImportRecipe
    ) -> PatternImportPreviewAsset? {
        guard let source = makePreviewSource(for: fileURL) else {
            return nil
        }
        return makePreview(from: source, recipe: recipe)
    }

    func importFiles(
        _ fileURLs: [URL],
        recipe: PatternImportRecipe,
        eraseMaskDataByFileURL: [URL: Data] = [:],
        into library: PatternLibraryState,
        persistsLibrary: Bool = true
    ) throws -> PatternLibraryImportBatchResult {
        guard !fileURLs.isEmpty else {
            return PatternLibraryImportBatchResult(
                updatedLibrary: library,
                importedItems: [],
                skippedDuplicateCount: 0,
                failedFileNames: []
            )
        }

        guard let root = patternLibraryRootURL(createDirectories: true) else {
            throw NSError(domain: "ArtFlex.PatternLibraryPersistence", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "无法创建图案库资产目录"
            ])
        }

        let normalizedURLs = uniqueNormalizedURLs(fileURLs)
        let existingHashes = existingRenderHashes(in: library)
        var knownHashes = existingHashes
        var mutableLibrary = library
        var importedItems: [PatternLibraryItem] = []
        var failedFileNames: [String] = []
        var skippedDuplicateCount = 0
        var nextSlotIndex = mutableLibrary.firstEmptySlotIndex()

        for fileURL in normalizedURLs {
            guard let sourceImage = preparedImportSourceImage(at: fileURL) else {
                failedFileNames.append(fileURL.lastPathComponent)
                continue
            }

            let processed = processDecodedImage(
                sourceImage,
                recipe: recipe,
                eraseMaskData: eraseMaskDataByFileURL[fileURL]
            )
            let renderDigest = digestForImage(processed.image)
            guard !knownHashes.contains(renderDigest) else {
                skippedDuplicateCount += 1
                continue
            }

            let renderRelativePath = managedAssetRelativePath(
                category: "renders",
                digest: renderDigest
            )
            let thumbnailRelativePath = managedAssetRelativePath(
                category: "thumbnails",
                digest: renderDigest
            )
            let renderURL = root.appendingPathComponent(renderRelativePath)
            let thumbnailURL = root.appendingPathComponent(thumbnailRelativePath)

            do {
                try ensureParentDirectoryExists(for: renderURL)
                try ensureParentDirectoryExists(for: thumbnailURL)
                try writePNG(image: processed.image, to: renderURL)

                let thumbnail = makeThumbnailImage(from: processed.image, maxDimension: 256)
                try writePNG(image: thumbnail, to: thumbnailURL)
            } catch {
                failedFileNames.append(fileURL.lastPathComponent)
                continue
            }

            let item = PatternLibraryItem(
                displayName: fileURL.deletingPathExtension().lastPathComponent,
                slotIndex: nextSlotIndex,
                importRecipe: recipe,
                originalFilename: fileURL.lastPathComponent,
                sourcePixelWidth: sourceImage.width,
                sourcePixelHeight: sourceImage.height,
                renderAssetLocation: .managedCopy(relativePath: renderRelativePath),
                thumbnailLocation: .managedCopy(relativePath: thumbnailRelativePath)
            )
            importedItems.append(item)
            mutableLibrary.items.append(item)
            knownHashes.insert(renderDigest)
            nextSlotIndex += 1
        }

        if let firstImportedID = importedItems.first?.id {
            mutableLibrary.selectedItemID = firstImportedID
        }

        if persistsLibrary {
            try saveLibrary(mutableLibrary)
        }

        return PatternLibraryImportBatchResult(
            updatedLibrary: mutableLibrary,
            importedItems: importedItems,
            skippedDuplicateCount: skippedDuplicateCount,
            failedFileNames: failedFileNames
        )
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private func sanitizedLibraryRemovingMissingAssets(
        _ library: PatternLibraryState
    ) -> PatternLibraryState {
        var sanitized = library
        sanitized.items = library.items.filter { item in
            guard
                let renderURL = resolveAssetURL(for: item.renderAssetLocation),
                let thumbnailURL = resolveAssetURL(for: item.thumbnailLocation)
            else {
                return false
            }

            return fileManager.fileExists(atPath: renderURL.path)
                && fileManager.fileExists(atPath: thumbnailURL.path)
        }
        sanitized.deletedItems = library.deletedItems.filter { item in
            guard
                let renderURL = resolveAssetURL(for: item.renderAssetLocation),
                let thumbnailURL = resolveAssetURL(for: item.thumbnailLocation)
            else {
                return false
            }

            return fileManager.fileExists(atPath: renderURL.path)
                && fileManager.fileExists(atPath: thumbnailURL.path)
        }

        if let selectedItemID = sanitized.selectedItemID,
           sanitized.items.contains(where: { $0.id == selectedItemID }) == false {
            sanitized.selectedItemID = sanitized.items.first?.id
        }

        sanitized.recentItemIDs = sanitized.recentItemIDs.filter { recentID in
            sanitized.items.contains(where: { $0.id == recentID })
        }

        return sanitized
    }

    private func existingRenderHashes(in library: PatternLibraryState) -> Set<String> {
        Set(library.items.compactMap { item in
            guard let renderURL = resolveAssetURL(for: item.renderAssetLocation),
                  let image = decodeImage(at: renderURL) else {
                return nil
            }
            return digestForImage(image)
        })
    }

    private func uniqueNormalizedURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []

        for url in urls {
            let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
            let key = normalized.path
            if seen.insert(key).inserted {
                result.append(normalized)
            }
        }

        return result
    }

    private func decodeImage(at url: URL) -> DecodedPatternImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else {
            return nil
        }

        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let data = context.data else {
            return nil
        }

        return DecodedPatternImage(
            width: width,
            height: height,
            rgbaBytes: [UInt8](UnsafeBufferPointer(
                start: data.assumingMemoryBound(to: UInt8.self),
                count: width * height * 4
            ))
        )
    }

    private func preparedImportSourceImage(at url: URL) -> DecodedPatternImage? {
        guard let decoded = decodeImage(at: url) else {
            return nil
        }
        return scaledImage(from: decoded, maxDimension: Self.maximumImportDimension)
    }

    private func processDecodedImage(
        _ image: DecodedPatternImage,
        recipe: PatternImportRecipe,
        eraseMaskData: Data? = nil
    ) -> CroppedPatternImage {
        let baseImage: DecodedPatternImage
        switch recipe.mode {
        case .originalColor:
            baseImage = image
        case .transparentMonochrome:
            baseImage = makeTransparentMonochromeImage(image, contrast: recipe.contrast)
        }

        let resolvedImage = applyEraseMask(eraseMaskData, to: baseImage) ?? baseImage
        guard recipe.autoCropToContent else {
            return CroppedPatternImage(image: resolvedImage, cropped: false)
        }

        return cropImageToVisibleContent(resolvedImage, padding: 2) ?? CroppedPatternImage(image: resolvedImage, cropped: false)
    }

    private func makeTransparentMonochromeImage(
        _ image: DecodedPatternImage,
        contrast: Float
    ) -> DecodedPatternImage {
        let clampedContrast = min(max(contrast, -1), 1)
        let threshold = min(max(0.5 + (clampedContrast * 0.35), 0.05), 0.95)

        var output = image.rgbaBytes
        var index = 0
        while index < output.count {
            let alpha = Float(output[index + 3]) / 255
            guard alpha > 0.0001 else {
                output[index] = 0
                output[index + 1] = 0
                output[index + 2] = 0
                output[index + 3] = 0
                index += 4
                continue
            }

            let red = min(max((Float(output[index]) / 255) / alpha, 0), 1)
            let green = min(max((Float(output[index + 1]) / 255) / alpha, 0), 1)
            let blue = min(max((Float(output[index + 2]) / 255) / alpha, 0), 1)
            let luma = (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
            let resolvedAlpha = luma < threshold ? alpha : 0

            output[index] = 0
            output[index + 1] = 0
            output[index + 2] = 0
            output[index + 3] = UInt8(clamping: Int((resolvedAlpha * 255).rounded()))
            index += 4
        }

        return DecodedPatternImage(
            width: image.width,
            height: image.height,
            rgbaBytes: output
        )
    }

    private func applyEraseMask(
        _ eraseMaskData: Data?,
        to image: DecodedPatternImage
    ) -> DecodedPatternImage? {
        guard let eraseMaskData,
              let resampledMaskBytes = resampledMaskBytes(
                eraseMaskData,
                sourceResolution: 256,
                targetWidth: image.width,
                targetHeight: image.height
              ) else {
            return nil
        }

        var output = image.rgbaBytes
        var index = 0
        var maskIndex = 0
        while index < output.count, maskIndex < resampledMaskBytes.count {
            let keepAlpha = Float(resampledMaskBytes[maskIndex]) / 255
            let red = Float(output[index]) / 255
            let green = Float(output[index + 1]) / 255
            let blue = Float(output[index + 2]) / 255
            let alpha = Float(output[index + 3]) / 255
            let resolvedAlpha = alpha * keepAlpha

            output[index] = UInt8(clamping: Int((red * keepAlpha * 255).rounded()))
            output[index + 1] = UInt8(clamping: Int((green * keepAlpha * 255).rounded()))
            output[index + 2] = UInt8(clamping: Int((blue * keepAlpha * 255).rounded()))
            output[index + 3] = UInt8(clamping: Int((resolvedAlpha * 255).rounded()))

            index += 4
            maskIndex += 1
        }

        return DecodedPatternImage(
            width: image.width,
            height: image.height,
            rgbaBytes: output
        )
    }

    private func cropImageToVisibleContent(
        _ image: DecodedPatternImage,
        padding: Int
    ) -> CroppedPatternImage? {
        guard image.width > 0, image.height > 0 else { return nil }

        var minX = image.width
        var minY = image.height
        var maxX = -1
        var maxY = -1

        for y in 0..<image.height {
            for x in 0..<image.width {
                let alphaIndex = ((y * image.width) + x) * 4 + 3
                if image.rgbaBytes[alphaIndex] > 0 {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }

        guard maxX >= minX, maxY >= minY else { return nil }

        let paddedMinX = max(0, minX - padding)
        let paddedMinY = max(0, minY - padding)
        let paddedMaxX = min(image.width - 1, maxX + padding)
        let paddedMaxY = min(image.height - 1, maxY + padding)

        let croppedWidth = paddedMaxX - paddedMinX + 1
        let croppedHeight = paddedMaxY - paddedMinY + 1
        guard croppedWidth > 0, croppedHeight > 0 else { return nil }

        var croppedBytes = [UInt8](repeating: 0, count: croppedWidth * croppedHeight * 4)
        for y in 0..<croppedHeight {
            let sourceY = paddedMinY + y
            let sourceStart = ((sourceY * image.width) + paddedMinX) * 4
            let sourceEnd = sourceStart + (croppedWidth * 4)
            let destinationStart = y * croppedWidth * 4
            croppedBytes[destinationStart..<(destinationStart + croppedWidth * 4)] = image.rgbaBytes[sourceStart..<sourceEnd]
        }

        return CroppedPatternImage(
            image: DecodedPatternImage(
                width: croppedWidth,
                height: croppedHeight,
                rgbaBytes: croppedBytes
            ),
            cropped: true
        )
    }

    private func makePreviewImage(
        from image: DecodedPatternImage,
        maxDimension: Int
    ) -> CGImage? {
        let target = scaledImage(from: image, maxDimension: maxDimension)
        return makeCGImage(from: target, shouldInterpolate: true)
    }

    private func makeThumbnailImage(
        from image: DecodedPatternImage,
        maxDimension: Int
    ) -> DecodedPatternImage {
        let contentImage = cropImageToVisibleContent(image, padding: 0)?.image ?? image
        return scaledImage(from: contentImage, maxDimension: maxDimension)
    }

    private func scaledImage(
        from image: DecodedPatternImage,
        maxDimension: Int
    ) -> DecodedPatternImage {
        let largestDimension = max(image.width, image.height)
        guard largestDimension > maxDimension, maxDimension > 0 else {
            return image
        }

        let scale = CGFloat(maxDimension) / CGFloat(largestDimension)
        let targetWidth = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let targetHeight = max(1, Int((CGFloat(image.height) * scale).rounded()))

        guard
            let sourceCGImage = makeCGImage(from: image, shouldInterpolate: true),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: targetWidth * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return image
        }

        context.interpolationQuality = .high
        context.draw(sourceCGImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        guard let data = context.data else {
            return image
        }

        return DecodedPatternImage(
            width: targetWidth,
            height: targetHeight,
            rgbaBytes: [UInt8](UnsafeBufferPointer(
                start: data.assumingMemoryBound(to: UInt8.self),
                count: targetWidth * targetHeight * 4
            ))
        )
    }

    private func makeCGImage(
        from image: DecodedPatternImage,
        shouldInterpolate: Bool
    ) -> CGImage? {
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let provider = CGDataProvider(data: Data(image.rgbaBytes) as CFData)
        else {
            return nil
        }

        return CGImage(
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: image.width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: shouldInterpolate,
            intent: .defaultIntent
        )
    }

    private func resampledMaskBytes(
        _ data: Data,
        sourceResolution: Int,
        targetWidth: Int,
        targetHeight: Int
    ) -> [UInt8]? {
        guard sourceResolution > 0, targetWidth > 0, targetHeight > 0 else { return nil }
        let sourceBytes = [UInt8](data)
        guard sourceBytes.count == sourceResolution * sourceResolution else { return nil }

        var output = [UInt8](repeating: 255, count: targetWidth * targetHeight)
        for y in 0..<targetHeight {
            let normalizedY = targetHeight == 1 ? 0 : CGFloat(y) / CGFloat(targetHeight - 1)
            let sourceY = min(
                sourceResolution - 1,
                max(0, Int((normalizedY * CGFloat(sourceResolution - 1)).rounded()))
            )
            for x in 0..<targetWidth {
                let normalizedX = targetWidth == 1 ? 0 : CGFloat(x) / CGFloat(targetWidth - 1)
                let sourceX = min(
                    sourceResolution - 1,
                    max(0, Int((normalizedX * CGFloat(sourceResolution - 1)).rounded()))
                )
                output[(y * targetWidth) + x] = sourceBytes[(sourceY * sourceResolution) + sourceX]
            }
        }
        return output
    }

    private func digestForImage(_ image: DecodedPatternImage) -> String {
        var header = withUnsafeBytes(of: UInt32(image.width).littleEndian, Array.init)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(image.height).littleEndian, Array.init))
        header.append(contentsOf: image.rgbaBytes)
        let digest = SHA256.hash(data: Data(header))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func writePNG(
        image: DecodedPatternImage,
        to url: URL
    ) throws {
        guard
            let cgImage = makeCGImage(from: image, shouldInterpolate: false),
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            throw CocoaError(.fileWriteUnknown)
        }

        CGImageDestinationAddImage(destination, cgImage, nil)
        if !CGImageDestinationFinalize(destination) {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func ensureParentDirectoryExists(for url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private func patternLibraryRootURL(createDirectories: Bool) -> URL? {
        let baseURL: URL
        if let rootDirectoryURL {
            baseURL = rootDirectoryURL
        } else {
            guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                return nil
            }
            baseURL = appSupport.appendingPathComponent("ArtFlex", isDirectory: true)
        }

        let root = baseURL.appendingPathComponent("PatternLibrary", isDirectory: true)
        if createDirectories {
            try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }

    private func persistentLibraryURL(createDirectories: Bool = false) -> URL? {
        guard let root = patternLibraryRootURL(createDirectories: createDirectories) else {
            return nil
        }
        return root.appendingPathComponent("pattern-library.json")
    }

    private func managedAssetRelativePath(category: String, digest: String) -> String {
        let shard = String(digest.prefix(2))
        return "\(category)/\(shard)/\(digest).png"
    }

    private func purgeOrphanedManagedAssets(for library: PatternLibraryState) {
        guard let root = patternLibraryRootURL(createDirectories: false) else { return }

        var retainedItems = library.items + library.deletedItems
        if let libraryURL = persistentLibraryURL() {
            let previousURL = ProtectedLibraryFile.previousVersionURL(for: libraryURL)
            do {
                let data = try Data(contentsOf: previousURL)
                let previous = try JSONDecoder().decode(PatternLibraryState.self, from: data)
                retainedItems += previous.items + previous.deletedItems
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && error.code == NSFileReadNoSuchFileError {
                // First save has no previous generation.
            } catch {
                // If the backup cannot be inspected, deleting assets is unsafe.
                return
            }
        }
        let referencedRelativePaths = Set(
            retainedItems.flatMap { item -> [String] in
                var paths: [String] = []
                if case .managedCopy(let relativePath) = item.renderAssetLocation {
                    paths.append(relativePath)
                }
                if case .managedCopy(let relativePath) = item.thumbnailLocation {
                    paths.append(relativePath)
                }
                return paths
            }
        )

        for category in ["renders", "thumbnails"] {
            let categoryURL = root.appendingPathComponent(category, isDirectory: true).standardizedFileURL
            guard let enumerator = fileManager.enumerator(
                at: categoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                let standardizedFileURL = fileURL.standardizedFileURL
                let resourceValues = try? standardizedFileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard resourceValues?.isRegularFile == true else { continue }
                let categoryPrefix = categoryURL.path + "/"
                guard standardizedFileURL.path.hasPrefix(categoryPrefix) else { continue }
                let relativeWithinCategory = String(standardizedFileURL.path.dropFirst(categoryPrefix.count))
                let relativePath = "\(category)/\(relativeWithinCategory)"
                guard referencedRelativePaths.contains(relativePath) == false else { continue }
                try? fileManager.removeItem(at: standardizedFileURL)
            }
        }
    }
}

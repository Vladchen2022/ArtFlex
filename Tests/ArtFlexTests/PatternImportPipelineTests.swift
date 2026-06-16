import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ArtFlex

struct PatternImportPipelineTests {
    @Test
    func originalColorImportCreatesThumbnailAndPersistsLibrary() throws {
        let tempRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtFlexPatternImportTests-\(UUID().uuidString)", isDirectory: true)
        let redirectedFileManager = RedirectedPatternApplicationSupportFileManager(
            applicationSupportRootURL: tempRootURL
        )
        let controller = PatternLibraryPersistenceController(fileManager: redirectedFileManager)

        defer {
            try? FileManager.default.removeItem(at: tempRootURL)
        }

        let sourceURL = tempRootURL.appendingPathComponent("original.png")
        try writeTestPNG(
            to: sourceURL,
            width: 6,
            height: 4,
            rgbaBytes: [
                255, 0, 0, 255,   255, 0, 0, 255,   0, 255, 0, 255,   0, 255, 0, 255,   0, 0, 255, 255,   0, 0, 255, 255,
                255, 0, 0, 255,   255, 0, 0, 255,   0, 255, 0, 255,   0, 255, 0, 255,   0, 0, 255, 255,   0, 0, 255, 255,
                255, 255, 255, 0, 255, 255, 255, 0, 0, 0, 0, 0,       0, 0, 0, 0,       255, 255, 255, 0, 255, 255, 255, 0,
                255, 255, 255, 0, 255, 255, 255, 0, 0, 0, 0, 0,       0, 0, 0, 0,       255, 255, 255, 0, 255, 255, 255, 0
            ]
        )

        let result = try controller.importFiles(
            [sourceURL],
            recipe: PatternImportRecipe(mode: .originalColor, contrast: 0, autoCropToContent: false),
            into: .init()
        )

        #expect(result.importedItems.count == 1)
        #expect(result.skippedDuplicateCount == 0)
        #expect(result.failedFileNames.isEmpty)
        #expect(result.updatedLibrary.items.count == 1)
        #expect(result.updatedLibrary.selectedItemID == result.importedItems.first?.id)

        let importedItem = try #require(result.importedItems.first)
        let renderURL = try #require(controller.resolveAssetURL(for: importedItem.renderAssetLocation))
        let thumbnailURL = try #require(controller.resolveAssetURL(for: importedItem.thumbnailLocation))
        if case .managedCopy(let renderRelativePath) = importedItem.renderAssetLocation {
            #expect(renderRelativePath.split(separator: "/").count == 3)
        } else {
            Issue.record("Expected imported render asset to be stored as a managed copy.")
        }
        if case .managedCopy(let thumbnailRelativePath) = importedItem.thumbnailLocation {
            #expect(thumbnailRelativePath.split(separator: "/").count == 3)
        } else {
            Issue.record("Expected imported thumbnail asset to be stored as a managed copy.")
        }
        #expect(FileManager.default.fileExists(atPath: renderURL.path))
        #expect(FileManager.default.fileExists(atPath: thumbnailURL.path))
        #expect(controller.loadLibrary()?.library == result.updatedLibrary)
    }

    @Test
    func importFilesCanDeferLibraryPersistenceForMainActorMerge() throws {
        let tempRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtFlexPatternImportTests-\(UUID().uuidString)", isDirectory: true)
        let redirectedFileManager = RedirectedPatternApplicationSupportFileManager(
            applicationSupportRootURL: tempRootURL
        )
        let controller = PatternLibraryPersistenceController(fileManager: redirectedFileManager)

        defer {
            try? FileManager.default.removeItem(at: tempRootURL)
        }

        let sourceURL = tempRootURL.appendingPathComponent("deferred.png")
        try writeTestPNG(
            to: sourceURL,
            width: 2,
            height: 2,
            rgbaBytes: [
                0, 0, 0, 255, 255, 255, 255, 255,
                0, 0, 0, 255, 255, 255, 255, 255
            ]
        )

        let result = try controller.importFiles(
            [sourceURL],
            recipe: .init(),
            into: .init(),
            persistsLibrary: false
        )

        let importedItem = try #require(result.importedItems.first)
        let renderURL = try #require(controller.resolveAssetURL(for: importedItem.renderAssetLocation))
        let thumbnailURL = try #require(controller.resolveAssetURL(for: importedItem.thumbnailLocation))

        #expect(FileManager.default.fileExists(atPath: renderURL.path))
        #expect(FileManager.default.fileExists(atPath: thumbnailURL.path))
        #expect(controller.loadLibrary() == nil)

        try controller.saveLibrary(result.updatedLibrary)

        #expect(controller.loadLibrary()?.library == result.updatedLibrary)
    }

    @Test
    func transparentMonochromePreviewMakesWhitePixelsTransparent() throws {
        let tempRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtFlexPatternImportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRootURL) }

        let sourceURL = tempRootURL.appendingPathComponent("monochrome.png")
        try writeTestPNG(
            to: sourceURL,
            width: 5,
            height: 1,
            rgbaBytes: [
                0, 0, 0, 255,
                255, 255, 255, 255,
                128, 128, 128, 255,
                0, 0, 0, 255,
                0, 0, 0, 255
            ]
        )

        let controller = PatternLibraryPersistenceController(rootDirectoryURL: tempRootURL)
        let preview = try #require(controller.makePreview(
            for: sourceURL,
            recipe: PatternImportRecipe(mode: .transparentMonochrome, contrast: 0, autoCropToContent: false)
        ))

        let processed = [UInt8](preview.processedPreviewRGBABytes)
        let leadingBlackAlpha = processed[3]
        let whiteAlpha = processed[7]
        let grayAlpha = processed[11]

        #expect(leadingBlackAlpha > 250)
        #expect(whiteAlpha < 5)
        #expect(grayAlpha < 5)
    }

    @Test
    func eraseMaskRemovesPixelsFromImportedResult() throws {
        let tempRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtFlexPatternImportTests-\(UUID().uuidString)", isDirectory: true)
        let redirectedFileManager = RedirectedPatternApplicationSupportFileManager(
            applicationSupportRootURL: tempRootURL
        )
        let controller = PatternLibraryPersistenceController(fileManager: redirectedFileManager)
        defer { try? FileManager.default.removeItem(at: tempRootURL) }

        let sourceURL = tempRootURL.appendingPathComponent("erase.png")
        let rgbaBytes: [UInt8] = [UInt8](repeating: 0, count: 8 * 8 * 4).enumerated().map { index, _ in
            let channel = index % 4
            return channel == 3 ? 255 : 0
        }
        try writeTestPNG(to: sourceURL, width: 8, height: 8, rgbaBytes: rgbaBytes)

        var eraseMask = [UInt8](repeating: 255, count: 256 * 256)
        for y in 0..<256 {
            for x in 0..<128 {
                eraseMask[(y * 256) + x] = 0
            }
        }

        let result = try controller.importFiles(
            [sourceURL],
            recipe: PatternImportRecipe(mode: .originalColor, contrast: 0, autoCropToContent: false),
            eraseMaskDataByFileURL: [sourceURL: Data(eraseMask)],
            into: .init()
        )

        let importedItem = try #require(result.importedItems.first)
        let renderImage = try #require(controller.loadRenderImage(for: importedItem))
        #expect(renderImage.rgbaBytes[3] < 5)
        let retainedPixelAlphaIndex = ((0 * renderImage.width) + (renderImage.width - 1)) * 4 + 3
        #expect(renderImage.rgbaBytes[retainedPixelAlphaIndex] > 250)
    }

    @Test
    func eraseMaskSupportsPartialAlphaForSoftEdgeOriginalColorImport() throws {
        let tempRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtFlexPatternImportTests-\(UUID().uuidString)", isDirectory: true)
        let redirectedFileManager = RedirectedPatternApplicationSupportFileManager(
            applicationSupportRootURL: tempRootURL
        )
        let controller = PatternLibraryPersistenceController(fileManager: redirectedFileManager)
        defer { try? FileManager.default.removeItem(at: tempRootURL) }

        let sourceURL = tempRootURL.appendingPathComponent("soft-erase.png")
        try writeTestPNG(
            to: sourceURL,
            width: 1,
            height: 1,
            rgbaBytes: [0, 0, 0, 255]
        )

        let partialMask = Data([UInt8](repeating: 128, count: 256 * 256))
        let result = try controller.importFiles(
            [sourceURL],
            recipe: PatternImportRecipe(mode: .originalColor, contrast: 0, autoCropToContent: false),
            eraseMaskDataByFileURL: [sourceURL: partialMask],
            into: .init()
        )

        let importedItem = try #require(result.importedItems.first)
        let renderURL = try #require(controller.resolveAssetURL(for: importedItem.renderAssetLocation))
        let renderPreview = try #require(controller.makePreview(
            for: renderURL,
            recipe: PatternImportRecipe(mode: .originalColor, contrast: 0, autoCropToContent: false)
        ))
        let processed = [UInt8](renderPreview.processedPreviewRGBABytes)
        #expect(processed[3] > 120)
        #expect(processed[3] < 136)
    }

    @Test
    func duplicateRenderedContentIsSkipped() throws {
        let tempRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtFlexPatternImportTests-\(UUID().uuidString)", isDirectory: true)
        let redirectedFileManager = RedirectedPatternApplicationSupportFileManager(
            applicationSupportRootURL: tempRootURL
        )
        let controller = PatternLibraryPersistenceController(fileManager: redirectedFileManager)

        defer {
            try? FileManager.default.removeItem(at: tempRootURL)
        }

        let firstURL = tempRootURL.appendingPathComponent("first.png")
        let secondURL = tempRootURL.appendingPathComponent("second.png")
        let rgbaBytes: [UInt8] = [
            0, 0, 0, 255, 255, 255, 255, 255,
            0, 0, 0, 255, 255, 255, 255, 255
        ]
        try writeTestPNG(to: firstURL, width: 2, height: 2, rgbaBytes: rgbaBytes)
        try writeTestPNG(to: secondURL, width: 2, height: 2, rgbaBytes: rgbaBytes)

        let firstBatch = try controller.importFiles([firstURL], recipe: .init(), into: .init())
        let secondBatch = try controller.importFiles([secondURL], recipe: .init(), into: firstBatch.updatedLibrary)

        #expect(firstBatch.importedItems.count == 1)
        #expect(secondBatch.importedItems.isEmpty)
        #expect(secondBatch.skippedDuplicateCount == 1)
        #expect(secondBatch.updatedLibrary.items.count == 1)
    }

    @Test
    func largeImportedImagesAreDownscaledToMaximumDimension1000() throws {
        let tempRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtFlexPatternImportTests-\(UUID().uuidString)", isDirectory: true)
        let redirectedFileManager = RedirectedPatternApplicationSupportFileManager(
            applicationSupportRootURL: tempRootURL
        )
        let controller = PatternLibraryPersistenceController(fileManager: redirectedFileManager)

        defer {
            try? FileManager.default.removeItem(at: tempRootURL)
        }

        let sourceURL = tempRootURL.appendingPathComponent("large.png")
        let width = 1400
        let height = 700
        let rgbaBytes = [UInt8](repeating: 255, count: width * height * 4)
        try writeTestPNG(to: sourceURL, width: width, height: height, rgbaBytes: rgbaBytes)

        let preview = try #require(controller.makePreview(
            for: sourceURL,
            recipe: PatternImportRecipe(mode: .originalColor, contrast: 0, autoCropToContent: false)
        ))
        #expect(preview.sourcePixelWidth == 1000)
        #expect(preview.sourcePixelHeight == 500)

        let result = try controller.importFiles(
            [sourceURL],
            recipe: PatternImportRecipe(mode: .originalColor, contrast: 0, autoCropToContent: false),
            into: .init()
        )

        let importedItem = try #require(result.importedItems.first)
        #expect(importedItem.sourcePixelWidth == 1000)
        #expect(importedItem.sourcePixelHeight == 500)

        let renderImage = try #require(controller.loadRenderImage(for: importedItem))
        #expect(renderImage.width == 1000)
        #expect(renderImage.height == 500)
    }

    @Test
    func rebuildThumbnailRegeneratesManagedThumbnailAsset() throws {
        let tempRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtFlexPatternImportTests-\(UUID().uuidString)", isDirectory: true)
        let redirectedFileManager = RedirectedPatternApplicationSupportFileManager(
            applicationSupportRootURL: tempRootURL
        )
        let controller = PatternLibraryPersistenceController(fileManager: redirectedFileManager)

        defer {
            try? FileManager.default.removeItem(at: tempRootURL)
        }

        let sourceURL = tempRootURL.appendingPathComponent("rebuild-thumb.png")
        try writeTestPNG(
            to: sourceURL,
            width: 4,
            height: 4,
            rgbaBytes: [
                0, 0, 0, 0,   0, 0, 0, 0,   0, 0, 0, 0,   0, 0, 0, 0,
                0, 0, 0, 0,   0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 0,
                0, 0, 0, 0,   0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 0,
                0, 0, 0, 0,   0, 0, 0, 0,   0, 0, 0, 0,   0, 0, 0, 0
            ]
        )

        let result = try controller.importFiles(
            [sourceURL],
            recipe: PatternImportRecipe(mode: .originalColor, contrast: 0, autoCropToContent: false),
            into: .init()
        )
        let item = try #require(result.importedItems.first)
        let thumbnailURL = try #require(controller.resolveAssetURL(for: item.thumbnailLocation))

        try Data().write(to: thumbnailURL, options: .atomic)
        #expect((try Data(contentsOf: thumbnailURL)).isEmpty)

        try controller.rebuildThumbnail(for: item)

        let rebuiltData = try Data(contentsOf: thumbnailURL)
        #expect(rebuiltData.isEmpty == false)
    }

    @Test
    func savingLibraryPurgesUnreferencedManagedAssets() throws {
        let tempRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtFlexPatternImportTests-\(UUID().uuidString)", isDirectory: true)
        let redirectedFileManager = RedirectedPatternApplicationSupportFileManager(
            applicationSupportRootURL: tempRootURL
        )
        let controller = PatternLibraryPersistenceController(fileManager: redirectedFileManager)

        defer {
            try? FileManager.default.removeItem(at: tempRootURL)
        }

        let sourceURL = tempRootURL.appendingPathComponent("purge.png")
        try writeTestPNG(
            to: sourceURL,
            width: 2,
            height: 2,
            rgbaBytes: [
                0, 0, 0, 255, 255, 255, 255, 255,
                0, 0, 0, 255, 255, 255, 255, 255
            ]
        )

        let result = try controller.importFiles(
            [sourceURL],
            recipe: PatternImportRecipe(mode: .originalColor, contrast: 0, autoCropToContent: false),
            into: .init()
        )
        let item = try #require(result.importedItems.first)
        let root = try #require(
            controller.resolveAssetURL(for: item.renderAssetLocation)?
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        )

        let orphanRenderURL = root.appendingPathComponent("renders/zz/orphan.png")
        let orphanThumbnailURL = root.appendingPathComponent("thumbnails/zz/orphan.png")
        try FileManager.default.createDirectory(at: orphanRenderURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: orphanThumbnailURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: orphanRenderURL)
        try Data([4, 5, 6]).write(to: orphanThumbnailURL)

        try controller.saveLibrary(result.updatedLibrary)

        #expect(FileManager.default.fileExists(atPath: orphanRenderURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: orphanThumbnailURL.path) == false)
    }
}

private final class RedirectedPatternApplicationSupportFileManager: FileManager {
    private let applicationSupportRootURL: URL

    init(applicationSupportRootURL: URL) {
        self.applicationSupportRootURL = applicationSupportRootURL
        super.init()
    }

    override func urls(
        for directory: SearchPathDirectory,
        in domainMask: SearchPathDomainMask
    ) -> [URL] {
        guard directory == .applicationSupportDirectory,
              domainMask == .userDomainMask else {
            return super.urls(for: directory, in: domainMask)
        }
        return [applicationSupportRootURL]
    }
}

private func writeTestPNG(
    to url: URL,
    width: Int,
    height: Int,
    rgbaBytes: [UInt8]
) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    guard
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
        let provider = CGDataProvider(data: Data(rgbaBytes) as CFData),
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ),
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        )
    else {
        throw CocoaError(.fileWriteUnknown)
    }

    CGImageDestinationAddImage(destination, image, nil)
    if !CGImageDestinationFinalize(destination) {
        throw CocoaError(.fileWriteUnknown)
    }
}

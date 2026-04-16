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
        #expect(FileManager.default.fileExists(atPath: renderURL.path))
        #expect(FileManager.default.fileExists(atPath: thumbnailURL.path))
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
            width: 3,
            height: 1,
            rgbaBytes: [
                255, 255, 255, 255,
                128, 128, 128, 255,
                0, 0, 0, 255
            ]
        )

        let controller = PatternLibraryPersistenceController(rootDirectoryURL: tempRootURL)
        let preview = try #require(controller.makePreview(
            for: sourceURL,
            recipe: PatternImportRecipe(mode: .transparentMonochrome, contrast: 0, autoCropToContent: false)
        ))

        let processed = [UInt8](preview.processedPreviewRGBABytes)
        let whiteAlpha = processed[3]
        let grayAlpha = processed[7]
        let blackAlpha = processed[11]

        #expect(whiteAlpha < 5)
        #expect(grayAlpha < 5)
        #expect(blackAlpha > 250)
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
        let renderURL = try #require(controller.resolveAssetURL(for: importedItem.renderAssetLocation))
        let renderPreview = try #require(controller.makePreview(
            for: renderURL,
            recipe: PatternImportRecipe(mode: .originalColor, contrast: 0, autoCropToContent: false)
        ))
        let processed = [UInt8](renderPreview.processedPreviewRGBABytes)
        #expect(processed[3] < 5)
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

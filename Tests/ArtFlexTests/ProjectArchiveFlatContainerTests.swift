import Foundation
import ImageIO
import Testing
import Darwin
@testable import ArtFlex

@Suite("Flat project container and preview")
struct ProjectArchiveFlatContainerTests {
    @Test("AppleArchive container turns a package into one regular file")
    func flatContainerRoundTripsPackageContents() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Package", isDirectory: true)
        let layers = package.appendingPathComponent("layers", isDirectory: true)
        try FileManager.default.createDirectory(at: layers, withIntermediateDirectories: true)
        try Data("manifest".utf8).write(to: package.appendingPathComponent("manifest.json"))
        try Data([1, 2, 3, 4]).write(to: layers.appendingPathComponent("layer.bin"))

        let archive = root.appendingPathComponent("Drawing.artflex")
        let container = ProjectArchiveFlatContainer()
        try container.encodePackage(at: package, to: archive)

        var isDirectory: ObjCBool = true
        #expect(FileManager.default.fileExists(atPath: archive.path, isDirectory: &isDirectory))
        #expect(!isDirectory.boolValue)
        try container.withExtractedPackage(from: archive, limits: .standard) { extracted in
            let manifest = try Data(contentsOf: extracted.appendingPathComponent("manifest.json"))
            let layer = try Data(contentsOf: extracted.appendingPathComponent("layers/layer.bin"))
            #expect(manifest == Data("manifest".utf8))
            #expect(layer == Data([1, 2, 3, 4]))
        }
    }

    @Test("flat projects open when source and extraction directories have different groups")
    func flatContainerIgnoresNonportableOwnershipMetadata() throws {
        let sourceRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
                "ArtFlex-FlatOwnershipTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: sourceRoot) }

        let package = sourceRoot.appendingPathComponent("Package", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        try Data("portable".utf8).write(to: package.appendingPathComponent("project.json"))

        let attributes = try FileManager.default.attributesOfItem(atPath: package.path)
        let sourceGroupID = (attributes[.groupOwnerAccountID] as? NSNumber)?.uint32Value
        #expect(sourceGroupID != getgid())

        let archive = sourceRoot.appendingPathComponent("Drawing.artflex")
        let container = ProjectArchiveFlatContainer()
        try container.encodePackage(at: package, to: archive)
        try container.withExtractedPackage(from: archive, limits: .standard) { extracted in
            let project = try Data(contentsOf: extracted.appendingPathComponent("project.json"))
            #expect(project == Data("portable".utf8))
        }
    }

    @Test("empty and oversized flat files are rejected before extraction")
    func flatContainerRejectsInvalidOuterFiles() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appendingPathComponent("Empty.artflex")
        try Data().write(to: empty)
        let container = ProjectArchiveFlatContainer()

        #expect(throws: ProjectArchiveFlatContainerError.emptyArchive) {
            try container.withExtractedPackage(from: empty, limits: .standard) { _ in }
        }

        var limits = ProjectArchiveReadLimits.standard
        limits.maximumTotalUncompressedBytes = 1
        let oversized = root.appendingPathComponent("Oversized.artflex")
        try Data(repeating: 7, count: 33 * 1024 * 1024).write(to: oversized)
        #expect(throws: ProjectArchiveFlatContainerError.self) {
            try container.withExtractedPackage(from: oversized, limits: limits) { _ in }
        }
    }

    @Test("project thumbnail is a bounded PNG with the saved canvas aspect ratio")
    func thumbnailEncoderProducesBoundedPNG() throws {
        let width = 8
        let height = 4
        let pixel = [UInt8](arrayLiteral: 12, 34, 220, 255)
        let pixels = Data(Array(repeating: pixel, count: width * height).flatMap { $0 })
        let snapshot = LayerTextureSnapshot(
            width: width,
            height: height,
            bytesPerRow: width * 4,
            pixelData: pixels
        )

        let png = try ProjectThumbnailEncoder().encodePNG(from: snapshot, maximumDimension: 4)
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))

        #expect(png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]))
        #expect(image.width == 4)
        #expect(image.height == 2)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ArtFlex-FlatContainerTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

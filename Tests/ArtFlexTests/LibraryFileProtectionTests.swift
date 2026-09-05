import Foundation
import Testing
@testable import ArtFlex

struct LibraryFileProtectionTests {
    @Test
    func corruptBrushLibraryIsProtectedEvenWithoutPriorLoad() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("brush-library.json")
        let damaged = Data("damaged-user-library".utf8)
        try damaged.write(to: url)
        let controller = BrushLibraryPersistenceController(rootDirectoryURL: root)
        #expect(throws: (any Error).self) {
            try controller.saveResources(library: .stageOneDefault, tipImageLibrary: .empty)
        }
        #expect(try Data(contentsOf: url) == damaged)
        #expect(controller.loadFailureDescription != nil)
        #expect(controller.loadResources() == nil)
    }

    @Test
    func failedLoadRemainsProtectedIfOriginalDisappearsBeforeQueuedSave() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("brush-library.json")
        try Data([0xff]).write(to: url)
        let controller = BrushLibraryPersistenceController(rootDirectoryURL: root)
        #expect(controller.loadResources() == nil)
        try FileManager.default.moveItem(at: url, to: root.appendingPathComponent("original-damaged.json"))
        #expect(throws: (any Error).self) {
            try controller.saveResources(library: .stageOneDefault, tipImageLibrary: .empty)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test
    func validBrushSaveRetainsPreviousVersionAndSupportsLegacyJSON() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("brush-library.json")
        let original = try JSONEncoder().encode(BrushLibraryState.stageOneDefault)
        try original.write(to: url)
        let controller = BrushLibraryPersistenceController(rootDirectoryURL: root)
        #expect(controller.loadResources() != nil)
        try controller.saveResources(library: .stageOneDefault, tipImageLibrary: .empty)
        #expect(controller.loadResources() != nil)
        #expect(try Data(contentsOf: ProtectedLibraryFile.previousVersionURL(for: url)) == original)
        // Re-saving identical content must not replace the previous generation with itself.
        try controller.saveResources(library: .stageOneDefault, tipImageLibrary: .empty)
        #expect(try Data(contentsOf: ProtectedLibraryFile.previousVersionURL(for: url)) == original)
    }

    @Test
    func backupFailureDoesNotReplaceTheValidLibrary() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("brush-library.json")
        let original = try JSONEncoder().encode(BrushLibraryState.stageOneDefault)
        try original.write(to: url)
        try FileManager.default.createDirectory(at: ProtectedLibraryFile.previousVersionURL(for: url), withIntermediateDirectories: false)
        let controller = BrushLibraryPersistenceController(rootDirectoryURL: root)
        #expect(throws: (any Error).self) {
            try controller.saveResources(library: .stageOneDefault, tipImageLibrary: .empty)
        }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test
    func absentLibraryIsNormalButUnreadablePathIsNot() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = BrushLibraryPersistenceController(rootDirectoryURL: root)
        #expect(controller.loadResources() == nil)
        #expect(controller.loadFailureDescription == nil)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("brush-library.json"), withIntermediateDirectories: false)
        #expect(controller.loadResources() == nil)
        #expect(controller.loadFailureDescription != nil)
    }

    @Test
    func patternAndTextureLibrariesAlsoProtectFailedLoads() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pattern = PatternLibraryPersistenceController(rootDirectoryURL: root)
        let texture = TextureFillLibraryPersistenceController(rootDirectoryURL: root)
        let patternRoot = root.appendingPathComponent("PatternLibrary")
        try FileManager.default.createDirectory(at: patternRoot, withIntermediateDirectories: true)
        let patternURL = patternRoot.appendingPathComponent("pattern-library.json")
        let textureURL = root.appendingPathComponent("texture-library.json")
        let damaged = Data([0xff])
        try damaged.write(to: patternURL)
        try damaged.write(to: textureURL)
        #expect(pattern.loadLibrary() == nil)
        #expect(texture.loadLibrary() == nil)
        #expect(pattern.loadFailureDescription != nil)
        #expect(texture.loadFailureDescription != nil)
        #expect(throws: (any Error).self) { try pattern.saveLibrary(.init()) }
        #expect(throws: (any Error).self) { try texture.saveLibrary(.init()) }
        #expect(try Data(contentsOf: patternURL) == damaged)
        #expect(try Data(contentsOf: textureURL) == damaged)
    }

    @Test
    func previousPatternLibraryRetainsItsManagedAssets() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let patternRoot = root.appendingPathComponent("PatternLibrary")
        let renderURL = patternRoot.appendingPathComponent("renders/old.png")
        let thumbnailURL = patternRoot.appendingPathComponent("thumbnails/old.png")
        for url in [renderURL, thumbnailURL] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: url)
        }
        let item = PatternLibraryItem(
            displayName: "备份图案", importRecipe: .init(), originalFilename: "old.png",
            sourcePixelWidth: 1, sourcePixelHeight: 1,
            renderAssetLocation: .managedCopy(relativePath: "renders/old.png"),
            thumbnailLocation: .managedCopy(relativePath: "thumbnails/old.png")
        )
        let controller = PatternLibraryPersistenceController(rootDirectoryURL: root)
        try controller.saveLibrary(.init(items: [item]))
        try controller.saveLibrary(.init())
        try controller.saveLibrary(.init())
        #expect(FileManager.default.fileExists(atPath: renderURL.path))
        #expect(FileManager.default.fileExists(atPath: thumbnailURL.path))
        let previous = try Data(contentsOf: ProtectedLibraryFile.previousVersionURL(
            for: patternRoot.appendingPathComponent("pattern-library.json")
        ))
        #expect(try JSONDecoder().decode(PatternLibraryState.self, from: previous).items.map(\.id) == [item.id])
    }

    @Test
    func successfulReloadUnlocksARepairedLibrary() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("brush-library.json")
        try Data([0xff]).write(to: url)
        let controller = BrushLibraryPersistenceController(rootDirectoryURL: root)
        #expect(controller.loadResources() == nil)
        try JSONEncoder().encode(BrushLibraryState.stageOneDefault).write(to: url)
        #expect(controller.loadResources() != nil)
        #expect(controller.loadFailureDescription == nil)
        try controller.saveResources(library: .stageOneDefault, tipImageLibrary: .empty)
        #expect(controller.loadResources() != nil)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArtFlex-LibraryProtection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

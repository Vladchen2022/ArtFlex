import Foundation

final class BrushLibraryPersistenceController {
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func loadLibrary() -> BrushLibraryState? {
        guard let url = persistentLibraryURL() else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let archive = try? decoder.decode(BrushLibraryArchive.self, from: data) {
            return archive.resolvedLibrary
        }
        return try? decoder.decode(BrushLibraryState.self, from: data)
    }

    func saveLibrary(_ library: BrushLibraryState) throws {
        guard let url = persistentLibraryURL(createDirectories: true) else {
            throw NSError(domain: "ArtFlex.BrushLibraryPersistence", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "无法创建画笔库存储目录"
            ])
        }

        let data = try encoder.encode(BrushLibraryArchive(library: library))
        try data.write(to: url, options: .atomic)
    }

    func exportLibrary(_ library: BrushLibraryState, to url: URL) throws {
        let data = try encoder.encode(BrushLibraryArchive(library: library))
        try data.write(to: url, options: .atomic)
    }

    func importLibrary(from url: URL) throws -> BrushLibraryState {
        let data = try Data(contentsOf: url)
        if let archive = try? decoder.decode(BrushLibraryArchive.self, from: data) {
            return archive.resolvedLibrary
        }
        return try decoder.decode(BrushLibraryState.self, from: data)
    }

    private func persistentLibraryURL(createDirectories: Bool = false) -> URL? {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = appSupport.appendingPathComponent("ArtFlex", isDirectory: true)
        if createDirectories {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent("brush-library.json")
    }
}

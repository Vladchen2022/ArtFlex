import Foundation

struct PersistedBrushResources {
    var library: BrushLibraryState
    var tipImageLibrary: TipImageLibraryState
}

final class BrushLibraryPersistenceController: @unchecked Sendable {
    private let fileManager: FileManager
    private let rootDirectoryURL: URL?

    init(
        fileManager: FileManager = .default,
        rootDirectoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.rootDirectoryURL = rootDirectoryURL
    }

    func loadResources() -> PersistedBrushResources? {
        guard let url = persistentLibraryURL() else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        if let archive = try? decoder.decode(BrushLibraryArchive.self, from: data) {
            return PersistedBrushResources(
                library: archive.resolvedLibrary,
                tipImageLibrary: archive.resolvedTipImageLibrary
            )
        }
        if let library = try? decoder.decode(BrushLibraryState.self, from: data) {
            return PersistedBrushResources(
                library: library,
                tipImageLibrary: .empty
            )
        }
        return nil
    }

    func saveResources(
        library: BrushLibraryState,
        tipImageLibrary: TipImageLibraryState
    ) throws {
        guard let url = persistentLibraryURL(createDirectories: true) else {
            throw NSError(domain: "ArtFlex.BrushLibraryPersistence", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "无法创建画笔库存储目录"
            ])
        }

        let data = try Self.makeEncoder().encode(
            BrushLibraryArchive(
                library: library,
                tipImageLibrary: tipImageLibrary
            )
        )
        try data.write(to: url, options: .atomic)
    }

    func exportLibrary(
        _ library: BrushLibraryState,
        tipImageLibrary: TipImageLibraryState,
        to url: URL
    ) throws {
        let data = try Self.makeEncoder().encode(
            BrushLibraryArchive(
                library: library,
                tipImageLibrary: tipImageLibrary
            )
        )
        try data.write(to: url, options: .atomic)
    }

    func importLibrary(from url: URL) throws -> PersistedBrushResources {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        if let archive = try? decoder.decode(BrushLibraryArchive.self, from: data) {
            return PersistedBrushResources(
                library: archive.resolvedLibrary,
                tipImageLibrary: archive.resolvedTipImageLibrary
            )
        }
        let library = try decoder.decode(BrushLibraryState.self, from: data)
        return PersistedBrushResources(
            library: library,
            tipImageLibrary: .empty
        )
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private func persistentLibraryURL(createDirectories: Bool = false) -> URL? {
        let directory: URL
        if let rootDirectoryURL {
            directory = rootDirectoryURL
        } else {
            guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                return nil
            }
            directory = appSupport.appendingPathComponent("ArtFlex", isDirectory: true)
        }
        if createDirectories {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent("brush-library.json")
    }
}

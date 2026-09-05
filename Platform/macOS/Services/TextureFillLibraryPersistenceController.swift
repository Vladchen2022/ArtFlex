import Foundation

final class TextureFillLibraryPersistenceController: @unchecked Sendable {
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

    func loadLibrary() -> TextureFillLibraryState? {
        guard let url = persistentLibraryURL() else { return nil }
        return protectedFile.load(from: url) { try JSONDecoder().decode(TextureFillLibraryState.self, from: $0) }
    }

    func saveLibrary(_ library: TextureFillLibraryState) throws {
        guard let url = persistentLibraryURL(createDirectories: true) else {
            throw NSError(domain: "ArtFlex.TextureFillLibraryPersistence", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "无法创建纹理库存储目录"
            ])
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try protectedFile.save(encoder.encode(library), to: url) {
            _ = try JSONDecoder().decode(TextureFillLibraryState.self, from: $0)
        }
    }

    private func persistentLibraryURL(createDirectories: Bool = false) -> URL? {
        let directory: URL
        if let rootDirectoryURL {
            directory = rootDirectoryURL
        } else {
            guard let appSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                return nil
            }
            directory = appSupport.appendingPathComponent("ArtFlex", isDirectory: true)
        }

        if createDirectories {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent("texture-library.json")
    }
}

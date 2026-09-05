import Foundation

final class BlockReferenceModuleLibraryPersistenceController: @unchecked Sendable {
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

    func loadLibrary() -> BlockReferenceModuleLibraryState? {
        guard let url = persistentLibraryURL(),
              var library = protectedFile.load(from: url, decode: {
                  try JSONDecoder().decode(BlockReferenceModuleLibraryState.self, from: $0)
              }) else { return nil }
        library.normalize()
        return library
    }

    func saveLibrary(_ library: BlockReferenceModuleLibraryState) throws {
        guard let url = persistentLibraryURL(createDirectories: true) else {
            throw NSError(domain: "ArtFlex.BlockReferenceModuleLibraryPersistence", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "无法创建体块库存储目录"
            ])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try protectedFile.save(encoder.encode(library), to: url) {
            _ = try JSONDecoder().decode(BlockReferenceModuleLibraryState.self, from: $0)
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
            ).first else { return nil }
            directory = appSupport.appendingPathComponent("ArtFlex", isDirectory: true)
        }
        if createDirectories {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent("block-reference-module-library.json")
    }
}

import Foundation

/// File-system identity and revision are kept separate: atomic saves change the inode,
/// while aliases and hard links may refer to the same document through different paths.
struct ProjectFileRevision: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var path: String
        var volume: UInt64
        var inode: UInt64
        var size: UInt64
        var modified: Date?
    }
    var entries: [Entry]

    static func read(_ url: URL) throws -> Self {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return .init(entries: []) }
        func entry(_ file: URL, path: String) throws -> Entry {
            let attributes = try manager.attributesOfItem(atPath: file.path)
            return .init(path: path, volume: (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0,
                inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                modified: attributes[.modificationDate] as? Date)
        }
        var entries = [try entry(url, path: "")]
        if (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
            var enumerationError: Error?
            let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: nil, errorHandler: { _, error in
                enumerationError = error; return false
            })
            while let child = enumerator?.nextObject() as? URL {
                entries.append(try entry(child, path: String(child.path.dropFirst(url.path.count))))
            }
            if let enumerationError { throw enumerationError }
        }
        return .init(entries: entries.sorted { $0.path < $1.path })
    }

    func verify(at url: URL) throws {
        let actual = try Self.read(url)
        guard actual == self else {
            throw CanvasResourceError(message: "磁盘上的工程已改变，保存已停止。请另存为新文件，或重新打开磁盘版本。")
        }
    }
}

enum ProjectFileAccess {
    static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        if lhs.standardizedFileURL.resolvingSymlinksInPath().path == rhs.standardizedFileURL.resolvingSymlinksInPath().path { return true }
        guard let a = try? FileManager.default.attributesOfItem(atPath: lhs.path),
              let b = try? FileManager.default.attributesOfItem(atPath: rhs.path),
              let inode = a[.systemFileNumber] as? NSNumber, let volume = a[.systemNumber] as? NSNumber else { return false }
        return inode == b[.systemFileNumber] as? NSNumber && volume == b[.systemNumber] as? NSNumber
    }

    static func read<T>(_ url: URL, _ body: (URL) throws -> T) throws -> T {
        var failure: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &failure) { coordinated in
            result = Result { try body(coordinated) }
        }
        if let failure { throw failure }
        return try result?.get() ?? { throw CocoaError(.fileReadUnknown) }()
    }

    static func write<T>(_ url: URL, _ body: (URL) throws -> T) throws -> T {
        var failure: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &failure) { coordinated in
            result = Result { try body(coordinated) }
        }
        if let failure { throw failure }
        return try result?.get() ?? { throw CocoaError(.fileWriteUnknown) }()
    }
}

/// Main-actor reservations cover the entire asynchronous open/save, including before a
/// new tab has acquired its final URL. The weak owners do not prolong document lifetimes.
@MainActor
final class DocumentFileRegistry {
    private final class Owner {
        weak var model: WorkspaceViewModel?
        init(_ model: WorkspaceViewModel) { self.model = model }
    }
    private var owners: [Owner] = []
    private var claims: [UUID: (ObjectIdentifier, URL)] = [:]

    func register(_ model: WorkspaceViewModel) { owners.removeAll { $0.model == nil }; owners.append(Owner(model)) }

    func owner(of url: URL) -> WorkspaceViewModel? {
        owners.compactMap(\.model).first { model in
            model.documentFileURL.map { ProjectFileAccess.sameFile($0, url) } == true
                || claims.values.contains { $0.0 == ObjectIdentifier(model) && ProjectFileAccess.sameFile($0.1, url) }
        }
    }

    func claim(_ url: URL, for model: WorkspaceViewModel) throws -> UUID {
        if let owner = owner(of: url), owner !== model {
            throw CanvasResourceError(message: "这个文件已由另一个文档使用，请切换到该文档，或选择新的保存位置。")
        }
        let id = UUID(); claims[id] = (ObjectIdentifier(model), url); return id
    }
    func release(_ id: UUID) { claims[id] = nil }
}

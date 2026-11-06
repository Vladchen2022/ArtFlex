import Foundation

/// Recovery sources are read-only inputs. A recovered document always receives a new
/// autosave directory; cancelling or closing that document cannot delete its source.
enum RecoveryCatalog {
    static func identity(_ root: URL) -> String { root.standardizedFileURL.resolvingSymlinksInPath().path }
    static func candidates(in root: URL) -> [URL] {
        [root.appendingPathComponent("Autosave.artflex")] +
        (1...PersistenceController.recoveryBackupGenerationCount).map {
            root.appendingPathComponent("Autosave-\($0).artflex")
        }
    }

    static func roots(in recoveryRoot: URL) -> [URL] {
        let manager = FileManager.default
        func directories(_ parent: URL) -> [URL] {
            ((try? manager.contentsOfDirectory(at: parent,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []).filter {
                guard let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
                return values.isDirectory == true && values.isSymbolicLink != true
            }
        }
        let documentRoots = directories(recoveryRoot.appendingPathComponent("Documents"))
        let owners = [recoveryRoot] + documentRoots
        let branchRoots = owners.flatMap { owner in
            directories(owner.appendingPathComponent("Branches")).flatMap(directories)
        }
        return (owners + branchRoots).filter { root in
            candidates(in: root).contains { manager.fileExists(atPath: $0.path) }
        }.sorted { $0.path < $1.path }
    }
}

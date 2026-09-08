import Foundation
import Darwin

enum HistoryCacheDirectory {
    static func makeCache() -> HistoryDiskCache {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.vladchen.artflex/Undo", isDirectory: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        DispatchQueue.global(qos: .utility).async {
            removeAbandonedProcessDirectories(in: root, currentPID: pid)
        }
        return HistoryDiskCache(rootURL: root.appendingPathComponent("Process-\(pid)", isDirectory: true))
    }

    /// Crash leftovers only. Active processes (including a second app instance) are untouched.
    /// Never traverse arbitrary user directories or follow symbolic links.
    static func removeAbandonedProcessDirectories(in root: URL, currentPID: Int32) {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
        for url in entries {
            let name = url.lastPathComponent
            guard name.hasPrefix("Process-"),
                  let pid = Int32(name.dropFirst("Process-".count)), pid > 0, pid != currentPID,
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  kill(pid, 0) == -1, errno == ESRCH else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

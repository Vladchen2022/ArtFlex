import Foundation

private let selectionTraceLogPath = "/Users/victorcloux/Desktop/ArtFlex/selection-trace.log"
private let selectionTraceQueue = DispatchQueue(label: "ArtFlex.SelectionTraceLog")

func resetSelectionTraceLog() {
#if DEBUG
    guard RuntimeDiagnostics.selectionTraceLoggingEnabled else { return }
    _ = selectionTraceQueue.sync {
        FileManager.default.createFile(atPath: selectionTraceLogPath, contents: Data(), attributes: nil)
    }
#endif
}

func appendSelectionTrace(_ message: String) {
#if DEBUG
    guard RuntimeDiagnostics.selectionTraceLoggingEnabled else { return }
    selectionTraceQueue.async {
        let line = "SelectionTrace \(message)\n"
        let data = Data(line.utf8)

        if !FileManager.default.fileExists(atPath: selectionTraceLogPath) {
            FileManager.default.createFile(atPath: selectionTraceLogPath, contents: data, attributes: nil)
            return
        }

        do {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: selectionTraceLogPath))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Keep trace logging best-effort only.
        }
    }
#endif
}

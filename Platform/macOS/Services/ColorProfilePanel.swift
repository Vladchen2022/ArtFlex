import AppKit
import UniformTypeIdentifiers

@MainActor
enum ColorProfilePanel {
    static func select(completion: @escaping (Result<ManagedRGBProfile?, Error>) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "选择 RGB ICC 配置文件"
        panel.allowedContentTypes = [UTType(filenameExtension: "icc"), UTType(filenameExtension: "icm")].compactMap { $0 }
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        func finish(_ response: NSApplication.ModalResponse) {
            guard response == .OK, let url = panel.url else { completion(.success(nil)); return }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                guard size > 0, size <= 4 * 1024 * 1024 else { throw CanvasResourceError(message: "ICC 文件须小于 4 MiB") }
                let profile = ManagedRGBProfile(kind: .icc, name: url.deletingPathExtension().lastPathComponent,
                    iccData: try Data(contentsOf: url))
                _ = try ManagedColorTransform.colorSpace(profile)
                completion(.success(profile))
            } catch { completion(.failure(error)) }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { panel.begin(completionHandler: finish) }
    }
}

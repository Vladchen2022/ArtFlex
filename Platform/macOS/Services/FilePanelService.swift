import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class FilePanelService {
    private static let artFlexProjectType: UTType = UTType(
        tag: "artflex",
        tagClass: .filenameExtension,
        conformingTo: .data
    ) ?? UTType(exportedAs: "com.vladchen.artflex.project", conformingTo: .data)
    private static let legacyArtFlexPackageType: UTType = UTType(
        tag: "artflex",
        tagClass: .filenameExtension,
        conformingTo: .package
    ) ?? UTType(exportedAs: "com.vladchen.artflex.project-package", conformingTo: .package)

    func presentProjectSavePanel(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.artFlexProjectType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(defaultName).artflex"
        panel.title = "保存 ArtFlex 工程"
        panel.prompt = "保存"
        return panel.runModal() == .OK ? panel.url : nil
    }

    func presentProjectOpenPanel(completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.artFlexProjectType, Self.legacyArtFlexPackageType, .json]
        // Older projects may have been created before the package UTI was
        // registered, so Finder still reports them as ordinary directories.
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.title = "打开 ArtFlex 工程"
        panel.message = "选择 .artflex 工程文件、旧版工程包或 .artflex.json 文件"
        panel.prompt = "打开"
        presentAsynchronousPanel(panel) { selectedURL in
            completion(selectedURL.flatMap(Self.normalizedProjectOpenURL))
        }
    }

    nonisolated static func normalizedProjectOpenURL(_ selectedURL: URL) -> URL? {
        var candidate = selectedURL.standardizedFileURL
        while candidate.path != candidate.pathComponents.first {
            if candidate.pathExtension.lowercased() == "artflex" {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent != candidate else { break }
            candidate = parent
        }
        return selectedURL.pathExtension.lowercased() == "json"
            ? selectedURL.standardizedFileURL
            : nil
    }

    func presentPNGExportPanel(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(defaultName).png"
        panel.title = "Export PNG"
        panel.prompt = "Export"

        return panel.runModal() == .OK ? panel.url : nil
    }

    func presentRasterExportPanel(
        defaultName: String,
        format: RasterExportFormat,
        completion: @escaping (URL?) -> Void
    ) {
        let contentType: UTType
        switch format {
        case .png:
            contentType = .png
        case .jpeg:
            contentType = .jpeg
        case .tiff:
            contentType = .tiff
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(defaultName).\(format.fileExtension)"
        panel.title = "导出 \(format.rawValue.uppercased())"
        panel.prompt = "导出"
        presentAsynchronousPanel(panel, usesPresentedSheet: true, completion: completion)
    }

    func presentDirectorySelectionPanel(title: String, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = title
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    func presentDirectorySelectionPanel(
        title: String,
        prompt: String,
        completion: @escaping (URL?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = title
        panel.prompt = prompt
        presentAsynchronousPanel(panel, completion: completion)
    }

    private func presentAsynchronousPanel(
        _ panel: NSSavePanel,
        usesPresentedSheet: Bool = false,
        completion: @escaping (URL?) -> Void
    ) {
        var parent = NSApp.mainWindow ?? NSApp.windows.first { $0.identifier?.rawValue == "main" }
        // An export settings sheet is already visible. Attaching to the document
        // would queue this panel behind it instead of letting the user choose a URL.
        if usesPresentedSheet {
            while let sheet = parent?.attachedSheet { parent = sheet }
        }
        let presentationParent = parent
        // Let a presenting popover dismiss before opening the system panel.
        DispatchQueue.main.async {
            let finish: (NSApplication.ModalResponse) -> Void = { response in
                panel.orderOut(nil)
                completion(response == .OK ? panel.url : nil)
            }
            if let parent = presentationParent {
                panel.beginSheetModal(for: parent, completionHandler: finish)
            } else {
                panel.begin(completionHandler: finish)
            }
        }
    }

    func presentVideoExportPanel(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(defaultName).mp4"
        panel.title = "导出视频"
        panel.prompt = "导出"
        return panel.runModal() == .OK ? panel.url : nil
    }

    func presentVideoExportPanel(defaultName: String, completion: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(defaultName).mp4"
        panel.title = "导出视频"
        panel.prompt = "导出"
        presentAsynchronousPanel(panel, completion: completion)
    }

    func presentImageOpenPanel() -> URL? {
        presentImageOpenPanelURLs()?.first
    }

    func presentPaletteImageOpenPanel(completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .bmp, .gif]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.title = "从图片提取色板"
        panel.message = "提取图片中的代表色；不会把图片导入画布。动图使用第一帧。"
        panel.prompt = "提取色板"
        presentAsynchronousPanel(panel, completion: completion)
    }

    func presentImageOpenPanelURLs(allowsMultipleSelection: Bool = false) -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.title = "选择图片"
        panel.prompt = "导入"
        return panel.runModal() == .OK ? panel.urls : nil
    }

    func presentBrushLibraryExportPanel(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(defaultName).brushes.json"
        panel.title = "导出画笔库"
        panel.prompt = "导出"
        return panel.runModal() == .OK ? panel.url : nil
    }

    func presentBrushLibraryImportPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.title = "导入画笔库"
        panel.prompt = "导入"
        return panel.runModal() == .OK ? panel.url : nil
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @discardableResult
    func applyProjectThumbnail(_ pngData: Data, to fileURL: URL) -> Bool {
        guard let image = NSImage(data: pngData) else { return false }
        return NSWorkspace.shared.setIcon(image, forFile: fileURL.path, options: [])
    }

    @discardableResult
    func openURL(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

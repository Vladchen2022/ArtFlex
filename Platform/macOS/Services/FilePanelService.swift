import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class FilePanelService {
    private static let artFlexProjectType: UTType = UTType(
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

    func presentProjectOpenPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.artFlexProjectType, .json]
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.title = "打开 ArtFlex 工程"
        panel.prompt = "打开"
        return panel.runModal() == .OK ? panel.url : nil
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
        format: RasterExportFormat
    ) -> URL? {
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
        return panel.runModal() == .OK ? panel.url : nil
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

    func presentVideoExportPanel(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(defaultName).mp4"
        panel.title = "导出视频"
        panel.prompt = "导出"
        return panel.runModal() == .OK ? panel.url : nil
    }

    func presentImageOpenPanel() -> URL? {
        presentImageOpenPanelURLs()?.first
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
    func openURL(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

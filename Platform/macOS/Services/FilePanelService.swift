import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class FilePanelService {
    func presentProjectSavePanel(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(defaultName).artflex.json"
        panel.title = "Save Project"
        panel.prompt = "Save"
        return panel.runModal() == .OK ? panel.url : nil
    }

    func presentProjectOpenPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.title = "Open Project"
        panel.prompt = "Open"
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

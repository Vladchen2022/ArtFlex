import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class FilePanelService {
    private var activeDialog: NSWindow?
    var isPresentingDialog: Bool { activeDialog != nil }

    #if DEBUG
    var selectURLsForTesting: ((NSSavePanel, @escaping ([URL]?) -> Void) -> Void)?
    var confirmForTesting: ((@escaping (NSApplication.ModalResponse) -> Void) -> Void)?
    #endif
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

    func presentProjectSavePanel(defaultName: String, completion: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.artFlexProjectType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(defaultName).artflex"
        panel.title = "保存 ArtFlex 工程"
        panel.prompt = "保存"
        presentAsynchronousPanel(panel, completion: completion)
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

    func presentPNGExportPanel(defaultName: String, completion: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(defaultName).png"
        panel.title = "Export PNG"
        panel.prompt = "Export"

        presentAsynchronousPanel(panel, completion: completion)
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
        presentAsynchronousPanel(panel, completion: completion)
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
        completion: @escaping (URL?) -> Void
    ) {
        presentSelection(panel) { completion($0?.first) }
    }

    private func presentationParent() -> NSWindow? {
        var parent = NSApp.mainWindow ?? NSApp.windows.first { $0.identifier?.rawValue == "main" }
        // A brush editor, import sheet or export sheet can already be attached.
        while let sheet = parent?.attachedSheet { parent = sheet }
        return parent
    }

    private func presentSelection(_ panel: NSSavePanel, completion: @escaping ([URL]?) -> Void) {
        guard activeDialog == nil else {
            completion(nil)
            return
        }
        activeDialog = panel
        let finish: ([URL]?) -> Void = { [self] urls in
            guard activeDialog === panel else { return }
            panel.orderOut(nil)
            activeDialog = nil
            completion(urls)
        }
        #if DEBUG
        if let selectURLsForTesting {
            selectURLsForTesting(panel, finish)
            return
        }
        #endif
        // Resolve the parent after the button's popover/sheet state has settled.
        DispatchQueue.main.async { [self] in
            let handler: (NSApplication.ModalResponse) -> Void = { response in
                let urls = (panel as? NSOpenPanel)?.urls ?? panel.url.map { [$0] }
                finish(response == .OK ? urls : nil)
            }
            if let parent = presentationParent() {
                panel.beginSheetModal(for: parent, completionHandler: handler)
            } else {
                panel.begin(completionHandler: handler)
            }
        }
    }

    func presentUnsavedChangesConfirmation(
        message: String,
        detail: String,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        guard activeDialog == nil else { completion(.abort); return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "放弃")
        alert.addButton(withTitle: "取消")
        activeDialog = alert.window
        let finish: (NSApplication.ModalResponse) -> Void = { [self] response in
            guard activeDialog === alert.window else { return }
            alert.window.orderOut(nil)
            activeDialog = nil
            completion(response)
        }
        #if DEBUG
        if let confirmForTesting { confirmForTesting(finish); return }
        #endif
        DispatchQueue.main.async { [self] in
            guard let parent = presentationParent() else { finish(.abort); return }
            alert.beginSheetModal(for: parent, completionHandler: finish)
        }
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

    func presentImageOpenPanel(completion: @escaping (URL?) -> Void) {
        presentImageOpenPanelURLs { completion($0?.first) }
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

    func presentImageOpenPanelURLs(
        allowsMultipleSelection: Bool = false,
        completion: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.title = "选择图片"
        panel.prompt = "导入"
        presentSelection(panel, completion: completion)
    }

    func presentKritaBrushOpenPanel(completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "导入 Krita 像素笔刷 · PNG 双笔尖 / Overlay"
        panel.allowedContentTypes = [UTType(filenameExtension: "kpp") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        presentAsynchronousPanel(panel, completion: completion)
    }

    func presentBrushLibraryExportPanel(defaultName: String, completion: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(defaultName).brushes.json"
        panel.title = "导出画笔库"
        panel.prompt = "导出"
        presentAsynchronousPanel(panel, completion: completion)
    }

    func presentBrushLibraryImportPanel(completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.title = "导入画笔库"
        panel.prompt = "导入"
        presentAsynchronousPanel(panel, completion: completion)
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @discardableResult
    func applyProjectThumbnail(_ pngData: Data, to fileURL: URL) -> Bool {
        guard let thumbnail = Self.projectThumbnail(from: pngData) else { return false }
        let image = NSImage(cgImage: thumbnail, size: .init(width: thumbnail.width, height: thumbnail.height))
        return NSWorkspace.shared.setIcon(image, forFile: fileURL.path, options: [])
    }

    nonisolated static func projectThumbnail(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    @discardableResult
    func openURL(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

import AppKit
import SwiftUI

@main
struct ArtFlexApp: App {
    @NSApplicationDelegateAdaptor(ArtFlexApplicationDelegate.self)
    private var appDelegate

    @StateObject private var viewModel: WorkspaceViewModel
    @StateObject private var presentationState = AppPresentationState()

    init() {
        do {
            let bootstrap = try AppBootstrap()
            let viewModel = WorkspaceViewModel(bootstrap: bootstrap)
            bootstrap.drawingStatsController.milestoneHandler = { [weak viewModel] milestone in
                viewModel?.showDrawingStatsMilestone(milestone)
            }
            _viewModel = StateObject(wrappedValue: viewModel)
        } catch {
            fatalError("Failed to initialize ArtFlex: \(error.localizedDescription)")
        }
    }

    private var commandTargetViewModel: WorkspaceViewModel {
        viewModel.ideationActiveBranchViewModel ?? viewModel
    }

    var body: some Scene {
        WindowGroup {
            MainWindowView(
                viewModel: viewModel,
                presentationState: presentationState
            )
                .frame(minWidth: 1200, minHeight: 760)
                .onAppear {
                    appDelegate.viewModel = viewModel
                }
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    presentationState.presentSettingsSheet()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }

            CommandGroup(replacing: .newItem) {
                Button("新建文件") {
                    viewModel.presentNewCanvasSheet()
                }
                .keyboardShortcut("n")
            }

            CommandGroup(after: .newItem) {
                Button("清除选区") {
                    commandTargetViewModel.clearSelection()
                }
                .keyboardShortcut("d")
                .disabled(commandTargetViewModel.isTransformingSelection)

                Button("删除选区内容") {
                    commandTargetViewModel.deleteSelectionOrActiveLayer()
                }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(commandTargetViewModel.isTransformingSelection)

                Button("向下合并") {
                    commandTargetViewModel.mergeActiveLayerDown()
                }
                .disabled(!commandTargetViewModel.canMergeDown)

                Button("合并可见") {
                    commandTargetViewModel.mergeVisibleLayers()
                }
                .disabled(!commandTargetViewModel.canMergeVisible)

                Button("盖印图层") {
                    commandTargetViewModel.stampVisibleLayers()
                }
                .keyboardShortcut("e", modifiers: [.command, .option, .shift])
                .disabled(commandTargetViewModel.isTransformingSelection)

                Button("合并拷贝") {
                    commandTargetViewModel.copyMergedPixels()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(commandTargetViewModel.isTransformingSelection)

                Button("应用变形") {
                    commandTargetViewModel.applySelectionTransform()
                }

                Button("取消变形") {
                    commandTargetViewModel.cancelSelectionTransform()
                }

                Button("填充选区内容") {
                    commandTargetViewModel.fillSelectionContents()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(commandTargetViewModel.isTransformingSelection)

                Button("填充套索内容") {
                    commandTargetViewModel.fillLassoContents()
                }
                .disabled(commandTargetViewModel.isTransformingSelection)

                Button("擦除套索内容") {
                    commandTargetViewModel.eraseLassoContents()
                }
                .disabled(commandTargetViewModel.isTransformingSelection)

                Button("撤销") {
                    commandTargetViewModel.undo()
                }
                .keyboardShortcut("z")

                Button("重做") {
                    commandTargetViewModel.redo()
                }
                .keyboardShortcut("Z", modifiers: [.command, .shift])

                Button("打开工程") {
                    viewModel.openProject()
                }
                .keyboardShortcut("o")

                Button("保存工程") {
                    viewModel.saveProject()
                }
                .keyboardShortcut("s")

                Button("导出图像") {
                    viewModel.presentRasterExportSheet()
                }
                .keyboardShortcut("e")

                Button("重置视图") {
                    commandTargetViewModel.resetViewport()
                }
                .keyboardShortcut("0", modifiers: [.command])

                Button("放大") {
                    commandTargetViewModel.zoomIn()
                }

                Button("缩小") {
                    commandTargetViewModel.zoomOut()
                }
            }
        }
    }
}

@MainActor
final class ArtFlexApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var viewModel: WorkspaceViewModel?
    private var isApprovingTermination = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        applyApplicationIconIfAvailable()

        DispatchQueue.main.async {
            if let window = NSApp.windows.first {
                Self.applyWindowChrome(to: window)
                window.delegate = self
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        NSApp.windows.forEach {
            Self.applyWindowChrome(to: $0)
            if isReferenceImageFloatingPanel($0) == false {
                $0.delegate = self
            }
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        viewModel?.pauseDrawingStatsTracking()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let viewModel else {
            return .terminateNow
        }

        if viewModel.confirmCloseOrQuitIfNeeded() {
            isApprovingTermination = true
            return .terminateNow
        }

        return .terminateCancel
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isReferenceImageFloatingPanel(sender) {
            return true
        }

        if isApprovingTermination {
            return true
        }

        guard let viewModel else {
            return true
        }

        return viewModel.confirmCloseOrQuitIfNeeded()
    }

    func windowDidResignKey(_ notification: Notification) {
        viewModel?.pauseDrawingStatsTracking()
    }

    @MainActor
    private static func applyWindowChrome(to window: NSWindow) {
        let chromeColor = NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = chromeColor
        window.isOpaque = true
    }

    private func isReferenceImageFloatingPanel(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue == "ReferenceImageFloatingPanel"
    }

    @MainActor
    private func applyApplicationIconIfAvailable() {
        let candidateURLs: [URL?] = [
            Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
            Bundle.main.resourceURL?.appendingPathComponent("ArtFlex_ArtFlex.bundle/AppIcon.png"),
            Bundle.allBundles.first(where: {
                $0.bundleURL.lastPathComponent == "ArtFlex_ArtFlex.bundle"
            })?.url(forResource: "AppIcon", withExtension: "png"),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/AppIcon.png")
        ]

        for candidateURL in candidateURLs {
            guard let candidateURL,
                  let iconImage = NSImage(contentsOf: candidateURL) else {
                continue
            }
            NSApp.applicationIconImage = iconImage
            return
        }
    }
}

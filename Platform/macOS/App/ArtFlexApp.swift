import AppKit
import SwiftUI

@main
struct ArtFlexApp: App {
    @NSApplicationDelegateAdaptor(ArtFlexApplicationDelegate.self)
    private var appDelegate

    @StateObject private var viewModel: WorkspaceViewModel

    init() {
        do {
            let bootstrap = try AppBootstrap()
            _viewModel = StateObject(
                wrappedValue: WorkspaceViewModel(bootstrap: bootstrap)
            )
        } catch {
            fatalError("Failed to initialize ArtFlex: \(error.localizedDescription)")
        }
    }

    private var commandTargetViewModel: WorkspaceViewModel {
        viewModel.ideationActiveBranchViewModel ?? viewModel
    }

    var body: some Scene {
        WindowGroup {
            MainWindowView(viewModel: viewModel)
                .frame(minWidth: 1200, minHeight: 760)
                .onAppear {
                    appDelegate.viewModel = viewModel
                }
        }
        .commands {
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
                    commandTargetViewModel.deleteSelectionContents()
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

                Button("导出 PNG") {
                    viewModel.exportPNG()
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

final class ArtFlexApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var viewModel: WorkspaceViewModel?
    private var isApprovingTermination = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

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
            $0.delegate = self
        }
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
        if isApprovingTermination {
            return true
        }

        guard let viewModel else {
            return true
        }

        return viewModel.confirmCloseOrQuitIfNeeded()
    }

    @MainActor
    private static func applyWindowChrome(to window: NSWindow) {
        let chromeColor = NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = chromeColor
        window.isOpaque = true
    }
}

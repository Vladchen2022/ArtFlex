import AppKit
import Combine
import SwiftUI

@main
struct ArtFlexApp: App {
    @NSApplicationDelegateAdaptor(ArtFlexApplicationDelegate.self)
    private var appDelegate

    @StateObject private var launchState: ArtFlexLaunchState
    @StateObject private var presentationState = AppPresentationState()

    init() {
        _launchState = StateObject(wrappedValue: ArtFlexLaunchState())
    }

    var body: some Scene {
        Window("ArtFlex", id: "main") {
            if let documents = launchState.documents {
                DocumentSessionWorkspace(documents: documents, presentationState: presentationState,
                    onCanvasReady: { appDelegate.canvasDidBecomeReady(viewModel: $0) })
                    .frame(minWidth: 960, minHeight: 700)
                    .onAppear {
                        appDelegate.documents = documents
                        appDelegate.viewModel = documents.active
                        let delegate = appDelegate
                        documents.onActiveChange = { [weak delegate] in delegate?.viewModel = $0 }
                    }
                    .onOpenURL { appDelegate.receiveExternalProjectOpenURL($0) }
            } else {
                ArtFlexLaunchFailureView(
                    message: launchState.errorMessage ?? "ArtFlex 初始化失败"
                )
                .frame(minWidth: 520, minHeight: 300)
            }
        }
        .commands {
            if let viewModel = launchState.viewModel {
                CommandGroup(replacing: .appInfo) {
                    Button("关于 ArtFlex") { AppBuildIdentity.showAbout() }
                }
                CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    presentationState.presentSettingsSheet()
                }
                .keyboardShortcut(",", modifiers: [.command])
                }

                ArtFlexWorkspaceCommands(host: viewModel, documents: launchState.documents)

            }
        }
    }
}

@MainActor
private final class ArtFlexLaunchState: ObservableObject {
    let documents: DocumentSessionController?
    var viewModel: WorkspaceViewModel? { documents?.active }
    private var relay: AnyCancellable?
    let errorMessage: String?

    init() {
        do {
            let bootstrap = try AppBootstrap()
            let viewModel = WorkspaceViewModel(bootstrap: bootstrap)
            bootstrap.drawingStatsController.milestoneHandler = { [weak viewModel] milestone in
                viewModel?.showDrawingStatsMilestone(milestone)
            }
            self.documents = DocumentSessionController(bootstrap: bootstrap, model: viewModel)
            self.errorMessage = nil
            relay = documents?.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        } catch {
            self.documents = nil
            self.errorMessage = error.localizedDescription
        }
    }
}

private struct ArtFlexLaunchFailureView: View {
    let message: String

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("ArtFlex 无法启动")
                .font(.title2.weight(.semibold))
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
                .textSelection(.enabled)
            Button("退出") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(36)
    }
}

@MainActor
final class ArtFlexApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var documents: DocumentSessionController?
    private func confirmDocumentsClose(_ completion: @escaping (Bool) -> Void) {
        if let documents { documents.confirmCloseAll(completion: completion) }
        else if let viewModel { viewModel.confirmCloseOrQuitIfNeeded(completion: completion) }
        else { completion(true) }
    }
    weak var viewModel: WorkspaceViewModel? {
        didSet {
            guard viewModel != nil else { return }
            DispatchQueue.main.async { [weak self] in
                self?.openPendingExternalProjectIfNeeded()
            }
        }
    }
    private var isApprovingTermination = false
    var terminationReplyHandler: (NSApplication, Bool) -> Void = { $0.reply(toApplicationShouldTerminate: $1) }
    private var isTerminationRequestPending = false
    private var isWindowCloseRequestPending = false
    private weak var approvedClosingWindow: NSWindow?
    private var isCanvasReady = false
    private var externalProjectOpenRequests = ExternalProjectOpenRequestBuffer()

    func application(_ application: NSApplication, open urls: [URL]) {
        _ = receiveExternalProjectOpenRequest(urls)
    }

    func application(_ application: NSApplication, openFile filename: String) -> Bool {
        receiveExternalProjectOpenRequest([URL(fileURLWithPath: filename)])
    }

    func application(_ application: NSApplication, openFiles filenames: [String]) {
        let didAcceptRequest = receiveExternalProjectOpenRequest(
            filenames.map { URL(fileURLWithPath: $0) }
        )
        application.reply(toOpenOrPrint: didAcceptRequest ? .success : .failure)
    }

    func receiveExternalProjectOpenURL(_ url: URL) {
        _ = receiveExternalProjectOpenRequest([url])
    }

    func canvasDidBecomeReady(viewModel: WorkspaceViewModel) {
        self.viewModel = viewModel
        isCanvasReady = true
        DispatchQueue.main.async { [weak self] in
            self?.openPendingExternalProjectIfNeeded()
        }
    }

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
        NSApp.windows.filter { $0.identifier?.rawValue == "main" }.forEach {
            Self.applyWindowChrome(to: $0)
            // Do not replace the system file panel / editor sheet's delegate.
            $0.delegate = self
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        if let documents { documents.sessions.forEach { $0.model.applicationDidResignActiveForPersistence() } }
        else { viewModel?.applicationDidResignActiveForPersistence() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isApprovingTermination { return .terminateNow }
        guard viewModel != nil else {
            return .terminateNow
        }

        guard !isTerminationRequestPending else { return .terminateLater }
        isTerminationRequestPending = true
        MainRunLoopDelivery.perform { [self] in
            confirmDocumentsClose { [self] allowed in
                isTerminationRequestPending = false
                isApprovingTermination = allowed
                terminationReplyHandler(sender, allowed)
            }
        }
        return .terminateLater
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isReferenceImageFloatingPanel(sender) {
            return true
        }

        if isApprovingTermination {
            return true
        }
        if approvedClosingWindow === sender {
            approvedClosingWindow = nil
            return true
        }

        guard viewModel != nil else {
            return true
        }

        guard !isWindowCloseRequestPending, !isTerminationRequestPending else { return false }
        isWindowCloseRequestPending = true
        DispatchQueue.main.async { [self, weak sender] in
            confirmDocumentsClose { [self] allowed in
                isWindowCloseRequestPending = false
                guard allowed, let sender else { return }
                approvedClosingWindow = sender
                sender.performClose(nil)
            }
        }
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        viewModel?.pauseDrawingStatsTracking()
    }

    private func openPendingExternalProjectIfNeeded() {
        guard viewModel != nil, isCanvasReady else { return }
        guard let projectURL = externalProjectOpenRequests.takePendingURL() else {
            return
        }
        openExternalProject(projectURL)
    }

    @discardableResult
    private func receiveExternalProjectOpenRequest(_ urls: [URL]) -> Bool {
        let projectURLs = urls.compactMap(FilePanelService.normalizedProjectOpenURL)
        guard !projectURLs.isEmpty else { return false }
        guard let projectURL = externalProjectOpenRequests.receive(
            projectURLs,
            isHandlerReady: viewModel != nil && isCanvasReady
        ) else {
            // A valid cold-launch request has been queued until the Metal canvas exists.
            return true
        }
        openExternalProject(projectURL)
        return true
    }

    private func openExternalProject(_ url: URL) {
        guard let viewModel else {
            _ = externalProjectOpenRequests.receive([url], isHandlerReady: false)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
        viewModel.openProjectFromExternalURL(url)
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
            Bundle.main.resourceURL?.appendingPathComponent("ArtFlex_ArtFlex.bundle/Contents/Resources/AppIcon.png"),
            Bundle.allBundles.first(where: {
                $0.bundleURL.lastPathComponent == "ArtFlex_ArtFlex.bundle"
            })?.url(forResource: "AppIcon", withExtension: "png")
        ]

        for candidateURL in candidateURLs {
            guard let candidateURL,
                  FileManager.default.fileExists(atPath: candidateURL.path),
                  let iconImage = NSImage(contentsOf: candidateURL) else {
                continue
            }
            NSApp.applicationIconImage = iconImage
            return
        }
    }
}

import SwiftUI

struct MainWindowView: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    let presentationState: AppPresentationState
    let onCanvasReady: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let snapshotCompareSession = viewModel.snapshotCompareSession {
                SnapshotCompareWorkspaceShell(
                    hostViewModel: viewModel,
                    session: snapshotCompareSession,
                    openSettings: presentationState.presentSettingsSheet
                )
            } else if let ideationSession = viewModel.ideationSession {
                IdeationWorkspaceShell(
                    hostViewModel: viewModel,
                    session: ideationSession,
                    openSettings: presentationState.presentSettingsSheet
                )
            } else {
                StandardWorkspaceShell(
                    viewModel: viewModel,
                    openSettings: presentationState.presentSettingsSheet,
                    onCanvasReady: onCanvasReady
                )
            }
        }
        .background(Color(red: 0.11, green: 0.11, blue: 0.12))
        .background(
            WindowKeyboardBridge(
                keyDownHandler: handleKeyDown(_:),
                keyUpHandler: handleKeyUp(_:),
                flagsChangedHandler: handleModifierFlagsChanged(_:),
                shouldMonitorBrushSizeShortcut: {
                    activeKeyboardTarget.isBrushTipCanvasFocused
                }
            )
            .frame(width: 0, height: 0)
        )
        .sheet(isPresented: $viewModel.isNewCanvasSheetPresented) {
            NewCanvasSheetView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isRasterExportSheetPresented) {
            RasterExportSheet(viewModel: viewModel)
        }
        .sheet(
            isPresented: Binding(
                get: { viewModel.isPatternImportSheetPresented },
                set: { viewModel.setPatternImportSheetPresented($0) }
            )
        ) {
            PatternImportSheet(viewModel: viewModel)
        }
        .background(
            SettingsSheetPresenter(
                presentationState: presentationState,
                shortcutSettings: viewModel.shortcutSettings
            )
            .frame(width: 0, height: 0)
        )
    }

    private var activeKeyboardTarget: WorkspaceViewModel {
        if viewModel.snapshotCompareSession != nil {
            return viewModel
        }
        return viewModel.ideationActiveBranchViewModel ?? viewModel
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let normalizedModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if normalizedModifiers.isEmpty, event.keyCode == 48 {
            viewModel.toggleWorkspaceChromeVisibility()
            return true
        }
        return activeKeyboardTarget.handleKeyDown(event)
    }

    private func handleKeyUp(_ event: NSEvent) -> Bool {
        activeKeyboardTarget.handleKeyUp(event)
    }

    private func handleModifierFlagsChanged(_ event: NSEvent) -> Bool {
        activeKeyboardTarget.handleModifierFlagsChanged(event.modifierFlags)
    }
}

private struct SnapshotCompareWorkspaceShell: View {
    @ObservedObject var hostViewModel: WorkspaceViewModel
    @ObservedObject var session: SnapshotCompareSessionState
    let openSettings: () -> Void

    var body: some View {
        let chromeHidden = hostViewModel.isWorkspaceChromeHidden

        VStack(spacing: 0) {
            if !chromeHidden {
                MainToolbarView(
                    hostViewModel: hostViewModel,
                    editingViewModel: hostViewModel,
                    openSettings: openSettings
                )
                .allowsHitTesting(false)
                .opacity(0.88)
            }

            HStack(spacing: 0) {
                if !chromeHidden {
                    ToolSidebarView(viewModel: hostViewModel, hostViewModel: hostViewModel)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .overlay(alignment: .trailing) {
                            Divider()
                                .overlay(Color.white.opacity(0.08))
                        }
                }

                SnapshotCompareGridView(
                    hostViewModel: hostViewModel,
                    session: session
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .contentShape(Rectangle())

                if !chromeHidden {
                    RightInspectorView(viewModel: hostViewModel)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .overlay(alignment: .leading) {
                            Divider()
                                .overlay(Color.white.opacity(0.08))
                        }
                        .allowsHitTesting(false)
                        .opacity(0.64)
                }
            }

            if !chromeHidden {
                WorkspaceStatusBarChrome(status: hostViewModel.status)
            }
        }
    }
}

private struct StandardWorkspaceShell: View {
    private static let minimumCanvasWidthWithDockedInspector: CGFloat = 900

    @ObservedObject var viewModel: WorkspaceViewModel
    let openSettings: () -> Void
    let onCanvasReady: () -> Void
    @State private var showsCompactInspector = false

    var body: some View {
        let chromeHidden = viewModel.isWorkspaceChromeHidden

        GeometryReader { proxy in
            let dockedInspectorThreshold = ToolSidebarView.standardWidth
                + RightInspectorView.standardWidth
                + Self.minimumCanvasWidthWithDockedInspector
            let showsInspector = !chromeHidden && proxy.size.width >= dockedInspectorThreshold
            VStack(spacing: 0) {
                if !chromeHidden {
                    MainToolbarView(
                        hostViewModel: viewModel,
                        editingViewModel: viewModel,
                        openSettings: openSettings
                    )
                }

                HStack(spacing: 0) {
                    if !chromeHidden {
                        ToolSidebarView(viewModel: viewModel, hostViewModel: viewModel)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .overlay(alignment: .trailing) {
                                Divider().overlay(Color.white.opacity(0.08))
                            }
                    }

                    CanvasContainerView(
                        viewModel: viewModel,
                        onReady: onCanvasReady
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .contentShape(Rectangle())

                    if showsInspector {
                        RightInspectorView(viewModel: viewModel)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .overlay(alignment: .leading) {
                                Divider().overlay(Color.white.opacity(0.08))
                            }
                    }
                }

                if !chromeHidden {
                    WorkspaceStatusBarChrome(status: viewModel.status)
                }
            }
            .overlay(alignment: .topTrailing) {
                if !chromeHidden && !showsInspector {
                    Button {
                        showsCompactInspector.toggle()
                    } label: {
                        Label("检查器", systemImage: "sidebar.right")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 50)
                    .padding(.trailing, 12)
                    .popover(isPresented: $showsCompactInspector, arrowEdge: .top) {
                        RightInspectorView(viewModel: viewModel)
                            .frame(
                                width: RightInspectorView.standardWidth,
                                height: max(560, proxy.size.height - 90)
                            )
                    }
                    .help("在窄窗口中打开右侧检查器")
                }
            }
            .onChange(of: showsInspector) { _, isVisible in
                if isVisible {
                    showsCompactInspector = false
                }
            }
        }
    }
}

private struct IdeationWorkspaceShell: View {
    @ObservedObject var hostViewModel: WorkspaceViewModel
    @ObservedObject var session: IdeationSessionState
    let openSettings: () -> Void

    var body: some View {
        let editingViewModel = session.activeBranchViewModel
        let chromeHidden = hostViewModel.isWorkspaceChromeHidden

        VStack(spacing: 0) {
            if !chromeHidden {
                MainToolbarView(
                    hostViewModel: hostViewModel,
                    editingViewModel: editingViewModel,
                    openSettings: openSettings
                )
            }

            HStack(spacing: 0) {
                if !chromeHidden {
                    ToolSidebarView(viewModel: editingViewModel, hostViewModel: hostViewModel)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .overlay(alignment: .trailing) {
                            Divider()
                                .overlay(Color.white.opacity(0.08))
                        }
                }

                IdeationCanvasGridView(
                    hostViewModel: hostViewModel,
                    session: session
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .contentShape(Rectangle())

                if !chromeHidden {
                    RightInspectorView(viewModel: editingViewModel)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .overlay(alignment: .leading) {
                            Divider()
                                .overlay(Color.white.opacity(0.08))
                        }
                }
            }

            if !chromeHidden {
                WorkspaceStatusBarChrome(status: editingViewModel.status)
            }
        }
    }
}

private struct SettingsSheetPresenter: View {
    @ObservedObject var presentationState: AppPresentationState
    @ObservedObject var shortcutSettings: AppShortcutSettingsStore

    var body: some View {
        Color.clear
            .sheet(isPresented: $presentationState.isSettingsSheetPresented) {
                SettingsSheetView(
                    settings: shortcutSettings,
                    onClose: presentationState.dismissSettingsSheet
                )
            }
    }
}

private struct WorkspaceStatusBarChrome: View {
    let status: WorkspaceStatus?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Color(red: 0.14, green: 0.14, blue: 0.15)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(Color.white.opacity(0.07))
                            .frame(height: 1)
                    }

                WorkspaceOperationStatusBar(status: status)
                    .position(x: proxy.size.width * 0.5, y: 11)
            }
        }
        .frame(height: 22)
    }

}

private struct WorkspaceOperationStatusBar: View {
    let status: WorkspaceStatus?
    static let width: CGFloat = 340

    var body: some View {
        HStack(spacing: 10) {
            shortcutBadge

            Text(status?.message ?? "准备就绪")
                .font(.system(size: 11, weight: status == nil ? .regular : .semibold))
                .foregroundStyle(messageColor)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .frame(width: Self.width, height: 22)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var shortcutBadge: some View {
        if let shortcutLabel = status?.shortcutLabel, !shortcutLabel.isEmpty {
            Text(shortcutLabel)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.45))
                .frame(width: 62, height: 16)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.white.opacity(0.04), lineWidth: 1)
                )
        } else {
            Color.clear
                .frame(width: 62, height: 16)
        }
    }

    private var messageColor: Color {
        switch status?.kind {
        case .success:
            return Color.green.opacity(0.9)
        case .error:
            return Color.red.opacity(0.95)
        case .info:
            return Color.white.opacity(0.82)
        case nil:
            return Color.white.opacity(0.5)
        }
    }
}

import SwiftUI

struct MainWindowView: View {
    @ObservedObject var viewModel: WorkspaceViewModel

    var body: some View {
        VStack(spacing: 0) {
            if let ideationSession = viewModel.ideationSession {
                IdeationWorkspaceShell(
                    hostViewModel: viewModel,
                    session: ideationSession
                )
            } else {
                StandardWorkspaceShell(viewModel: viewModel)
            }
        }
        .background(Color(red: 0.11, green: 0.11, blue: 0.12))
        .sheet(isPresented: $viewModel.isNewCanvasSheetPresented) {
            NewCanvasSheetView(viewModel: viewModel)
        }
    }
}

private struct StandardWorkspaceShell: View {
    @ObservedObject var viewModel: WorkspaceViewModel

    var body: some View {
        VStack(spacing: 0) {
            MainToolbarView(
                hostViewModel: viewModel,
                editingViewModel: viewModel
            )

            HStack(spacing: 0) {
                ToolSidebarView(viewModel: viewModel, hostViewModel: viewModel)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .overlay(alignment: .trailing) {
                        Divider()
                            .overlay(Color.white.opacity(0.08))
                    }

                CanvasContainerView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .contentShape(Rectangle())

                RightInspectorView(viewModel: viewModel)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .overlay(alignment: .leading) {
                        Divider()
                            .overlay(Color.white.opacity(0.08))
                    }
            }
        }
        .background(
            WindowKeyboardBridge(viewModel: viewModel)
                .frame(width: 0, height: 0)
        )
    }
}

private struct IdeationWorkspaceShell: View {
    @ObservedObject var hostViewModel: WorkspaceViewModel
    @ObservedObject var session: IdeationSessionState

    var body: some View {
        let editingViewModel = session.activeBranchViewModel

        VStack(spacing: 0) {
            MainToolbarView(
                hostViewModel: hostViewModel,
                editingViewModel: editingViewModel
            )

            HStack(spacing: 0) {
                ToolSidebarView(viewModel: editingViewModel, hostViewModel: hostViewModel)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .overlay(alignment: .trailing) {
                        Divider()
                            .overlay(Color.white.opacity(0.08))
                    }

                IdeationCanvasGridView(
                    hostViewModel: hostViewModel,
                    session: session
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .contentShape(Rectangle())

                RightInspectorView(viewModel: editingViewModel)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .overlay(alignment: .leading) {
                        Divider()
                            .overlay(Color.white.opacity(0.08))
                    }
            }
        }
        .background(
            WindowKeyboardBridge(viewModel: editingViewModel)
                .frame(width: 0, height: 0)
        )
    }
}

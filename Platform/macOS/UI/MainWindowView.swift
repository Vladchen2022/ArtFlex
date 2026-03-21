import SwiftUI

struct MainWindowView: View {
    @ObservedObject var viewModel: WorkspaceViewModel

    var body: some View {
        VStack(spacing: 0) {
            MainToolbarView(viewModel: viewModel)

            HStack(spacing: 0) {
                ToolSidebarView(viewModel: viewModel)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .overlay(alignment: .trailing) {
                        Divider()
                            .overlay(Color.white.opacity(0.08))
                    }

                ZStack {
                    CanvasContainerView(viewModel: viewModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
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
        .background(Color(red: 0.11, green: 0.11, blue: 0.12))
        .background(
            WindowKeyboardBridge(viewModel: viewModel)
                .frame(width: 0, height: 0)
        )
        .sheet(isPresented: $viewModel.isNewCanvasSheetPresented) {
            NewCanvasSheetView(viewModel: viewModel)
        }
    }
}

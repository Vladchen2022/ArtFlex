import SwiftUI

struct DocumentSessionWorkspace: View {
    @ObservedObject var documents: DocumentSessionController
    let presentationState: AppPresentationState
    let onCanvasReady: (WorkspaceViewModel) -> Void
    var body: some View {
        VStack(spacing: 0) {
            if documents.sessions.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        ForEach(documents.sessions) { session in
                            HStack(spacing: 9) {
                                Button {
                                    _ = documents.activate(session.id)
                                } label: {
                                    HStack(spacing: 5) {
                                        if session.model.hasUnsavedChanges { Circle().frame(width: 5, height: 5) }
                                        Text(session.model.workspace.document.metadata.name).lineLimit(1)
                                    }.frame(minWidth: 80, maxWidth: 210)
                                }.buttonStyle(.plain)
                                Button { documents.close(session.id) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                                    .buttonStyle(.plain).accessibilityLabel("关闭文档 \(session.model.workspace.document.metadata.name)")
                            }.padding(.horizontal, 12).padding(.vertical, 8)
                                .background(documents.activeID == session.id ? Color.accentColor.opacity(0.3) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                                .contextMenu {
                                    if session.id != documents.activeID {
                                        Button("将当前图层复制到此文档") { documents.copyActiveLayer(to: session.id) }
                                            .disabled(documents.isTransferring)
                                    }
                                    Button("关闭文档") { documents.close(session.id) }
                                }
                        }
                    }.padding(4)
                }.frame(height: 36).background(Color.black.opacity(0.25))
            }
            MainWindowView(viewModel: documents.active, presentationState: presentationState,
                onCanvasReady: { onCanvasReady(documents.active) }).id(documents.activeID)
        }
    }
}

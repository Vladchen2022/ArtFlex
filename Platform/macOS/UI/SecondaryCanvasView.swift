import SwiftUI

/// A synchronized observation view. Editing, undo and file state belong to the primary document.
struct SecondaryCanvasView: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    @State private var zoom = 1.0
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("同稿观察").font(.caption.bold())
                Spacer(minLength: 4)
                Button("−") { zoom = max(0.1, zoom / 1.25) }
                Text("适合 × \(zoom, specifier: "%.2f")").font(.caption).monospacedDigit().frame(width: 92)
                Button("+") { zoom = min(16, zoom * 1.25) }
                Button("适合") { zoom = 1 }
                Button { viewModel.showsDualCanvas = false } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("关闭同稿观察")
            }.buttonStyle(.borderless).padding(8).background(Color.black.opacity(0.25))
            GeometryReader { geometry in
                let size = viewModel.workspace.document.canvasSize
                let fit = min(max(1, geometry.size.width - 24) / Double(size.width), max(1, geometry.size.height - 24) / Double(size.height))
                ScrollView([.horizontal, .vertical]) {
                    MetalCanvasHost(readOnly: viewModel, sceneSnapshot: viewModel.navigatorSceneSnapshot,
                        redrawRevision: viewModel.colorAdjustmentRedrawRevision &+ viewModel.recentBrushAdjustmentRedrawRevision,
                        scale: fit * zoom, luminosity: viewModel.isLuminosityPreviewEnabled)
                        .id(viewModel.documentRenderGeneration)
                        .frame(width: Double(size.width) * fit * zoom, height: Double(size.height) * fit * zoom)
                        .allowsHitTesting(false)
                        .padding(12)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                }.background(Color(white: 0.22))
            }
            Text("左侧绘画同步显示；本视图独立缩放与滚动。")
                .font(.caption2).foregroundStyle(.secondary).padding(7)
        }
        .environment(\.colorScheme, .dark)
    }
}

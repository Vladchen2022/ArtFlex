import SwiftUI

struct NamedExportPreset: Identifiable, Codable {
    var id = UUID()
    var name: String
    var options: RasterExportOptions
}

struct ExportPreviewPanel: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    let options: RasterExportOptions
    @State private var image: CGImage?
    @State private var preparing = true
    var body: some View {
        VStack(spacing: 8) {
            Text("导出预览").font(.headline)
            ZStack {
                Canvas { context, size in
                    for row in 0..<Int(size.height / 12 + 1) {
                        for column in 0..<Int(size.width / 12 + 1) {
                            context.fill(Path(CGRect(x: column * 12, y: row * 12, width: 12, height: 12)),
                                with: .color((row + column) % 2 == 0 ? Color(white: 0.35) : Color(white: 0.5)))
                        }
                    }
                }
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit().padding(8)
                }
                if preparing { ProgressView().padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)) }
                else if image == nil { Text("当前设置无法生成预览").padding().background(.regularMaterial) }
            }.frame(width: 270, height: 285).clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("导出图像预览")
            Text("棋盘格表示透明区域；预览为缩小显示。\n实际输出尺寸和颜色精度以左侧设置为准。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .task(id: options) {
            preparing = true
            image = nil
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let result = await viewModel.rasterExportPreview(options: options)
            guard !Task.isCancelled else { return }
            image = result
            preparing = false
        }
    }
}

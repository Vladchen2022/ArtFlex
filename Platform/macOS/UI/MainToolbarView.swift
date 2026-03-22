import SwiftUI

struct MainToolbarView: View {
    @ObservedObject var hostViewModel: WorkspaceViewModel
    @ObservedObject var editingViewModel: WorkspaceViewModel

    var body: some View {
        HStack(spacing: 14) {
            toolbarIconButton("新建文件", systemImage: "doc.badge.plus") {
                hostViewModel.presentNewCanvasSheet()
            }

            toolbarIconButton("打开", systemImage: "folder") {
                hostViewModel.openProject()
            }

            toolbarIconButton("保存", systemImage: "square.and.arrow.down") {
                hostViewModel.saveProject()
            }

            toolbarIconButton("导出", systemImage: "square.and.arrow.up") {
                hostViewModel.exportPNG()
            }

            divider

            compactSlider(
                title: "大小",
                valueText: "\(Int(editingViewModel.workspace.toolSession.brush.size))",
                value: Binding(
                    get: { Double(editingViewModel.workspace.toolSession.brush.size) },
                    set: { editingViewModel.setBrushSize(Float($0)) }
                ),
                range: 1...1000,
                width: 110
            )

            compactSlider(
                title: "不透明度",
                valueText: "\(Int(editingViewModel.workspace.toolSession.brush.opacity * 100))%",
                value: Binding(
                    get: { Double(editingViewModel.workspace.toolSession.brush.opacity) },
                    set: { editingViewModel.setBrushOpacity(Float($0)) }
                ),
                range: 0...1,
                width: 110
            )

            Spacer(minLength: 0)

            Text(hostViewModel.workspace.document.metadata.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.82))
                .lineLimit(1)

            Circle()
                .fill(hostViewModel.hasUnsavedChanges ? Color.red : Color.green)
                .frame(width: 10, height: 10)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .help(hostViewModel.hasUnsavedChanges ? "有未保存内容" : "已保存")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(red: 0.13, green: 0.13, blue: 0.14))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 1)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.1))
            .frame(width: 1, height: 20)
    }

    private func toolbarIconButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.86))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private func compactSlider(
        title: String,
        valueText: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        width: CGFloat
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.68))
            Slider(value: value, in: range)
                .frame(width: width)
            Text(valueText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.88))
                .frame(width: 36, alignment: .leading)
        }
    }
}

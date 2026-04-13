import SwiftUI

struct MainToolbarView: View {
    @ObservedObject var hostViewModel: WorkspaceViewModel
    @ObservedObject var editingViewModel: WorkspaceViewModel

    var body: some View {
        HStack(spacing: 14) {
            toolbarTextButton("新建") {
                hostViewModel.presentNewCanvasSheet()
            }

            toolbarTextButton("打开") {
                hostViewModel.openProject()
            }

            toolbarTextButton("保存") {
                hostViewModel.saveProject()
            }

            toolbarTextButton("导出") {
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

            toolbarToggleButton(
                title: "锁定画布",
                systemImage: editingViewModel.isCanvasViewportLocked ? "lock.fill" : "lock.open",
                isOn: editingViewModel.isCanvasViewportLocked
            ) {
                editingViewModel.setCanvasViewportLocked(!editingViewModel.isCanvasViewportLocked)
            }

            toolbarToggleButton(
                title: "黑白模式",
                systemImage: "circle.lefthalf.filled",
                isOn: editingViewModel.isLuminosityPreviewEnabled,
                helpText: "切换主画布和参考图的黑白预览"
            ) {
                editingViewModel.toggleLuminosityPreview()
            }

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

    private func toolbarTextButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.86))
                .frame(minWidth: 28)
                .frame(height: 18)
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

    private func toolbarToggleButton(
        title: String,
        systemImage: String,
        isOn: Bool,
        helpText: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Color.white.opacity(isOn ? 0.98 : 0.86))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isOn ? Color.accentColor.opacity(0.92) : Color.white.opacity(0.09))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isOn ? Color.accentColor.opacity(0.95) : Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(helpText ?? (isOn ? "已锁定画布：主画布不能缩放、旋转或移动" : "锁定画布：主画布不能缩放、旋转或移动"))
    }
}

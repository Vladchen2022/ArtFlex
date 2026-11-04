import SwiftUI

struct ManagedColorProfilePicker: View {
    @Binding var profile: ManagedRGBProfile
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Menu("色彩空间：\(profile.name)") {
                    Button("sRGB") { profile = .sRGB }
                    Button("Display P3") { profile = .displayP3 }
                    Button("载入 RGB ICC…") {
                        ColorProfilePanel.select { result in
                            switch result {
                            case .success(let value): if let value { profile = value; error = nil }
                            case .failure(let failure): error = failure.localizedDescription
                            }
                        }
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
    }
}

struct ColorManagementSheet: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var profile = ManagedRGBProfile.sRGB
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("颜色管理与校样").font(.title2.bold())
            Text(viewModel.workspace.document.colorStandard.colorSpace == .extendedSRGB
                ? "当前画稿：广色域 16F，扩展线性 sRGB 存储，可保留 P3 颜色。"
                : "当前画稿：sRGB；新建时选择 16F 和广色域可保留 P3 颜色。")
            Text("导入按图像内嵌 ICC 转换；没有 ICC 的普通 RGB 图像按 sRGB 处理。屏幕由系统色彩管理，实际可见范围取决于显示器。")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            ManagedColorProfilePicker(profile: $profile)
            Text("校样模拟 RGB 输出后的颜色，只改变观察效果。吸管读取原画稿，导出使用导出窗口的色彩空间。当前不支持 CMYK 纸张与油墨模拟。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("关闭校样") { viewModel.colorProofProfile = nil; dismiss() }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("启用校样") { viewModel.colorProofProfile = profile; dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 490).onAppear { profile = viewModel.colorProofProfile ?? .sRGB }
    }
}

/// The system picker can select calibrated P3 colors. Store its canonical extended sRGB value.
struct WideGamutColorPicker: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    var body: some View {
        ColorPicker("广色域颜色", selection: Binding(get: {
            let c = viewModel.workspace.toolSession.selectedColor
            let space = NSColorSpace.extendedSRGB
            return Color(nsColor: NSColor(colorSpace: space, components: [CGFloat(c.red), CGFloat(c.green), CGFloat(c.blue), CGFloat(c.alpha)], count: 4))
        }, set: { value in
            guard let color = NSColor(value).usingColorSpace(.extendedSRGB) else { return }
            viewModel.setSelectedColor(.init(red: Float(color.redComponent), green: Float(color.greenComponent),
                blue: Float(color.blueComponent), alpha: Float(color.alphaComponent)))
        }), supportsOpacity: true)
        .font(.caption)
        .help("系统色彩面板支持 Display P3；色块与色环仍使用现有 sRGB 色板")
    }
}

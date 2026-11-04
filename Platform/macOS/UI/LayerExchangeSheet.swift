import SwiftUI

struct LayerExchangeSheet: View {
    @ObservedObject var controller: WorkspaceLayerExchangeController
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(controller.mode == .importing ? "导入 OpenRaster 分层工程" : "导出 OpenRaster 分层工程").font(.title2)
            Text("支持 PNG 图层、名称、位置、透明度、可见性、穿透组和 8 种混合模式。各软件的颜色合成方式可能不同，请对照合并图像。")
            Text("原生工程保留完整能力；ORA 不保留无损源参数、方案、体块、参考图、历史或画布外像素。隔离组、蒙版、剪贴和调整图层暂不支持结构交换。")
                .foregroundStyle(.secondary)
            Toggle("仅交换合并图像（失去图层结构）", isOn: $controller.flattened).disabled(controller.isBusy)
            if controller.mode == .exporting && !controller.unsupported.isEmpty && !controller.flattened {
                Text("当前不能分层导出：\(controller.unsupported.prefix(6).joined(separator: "、"))").foregroundStyle(.orange)
            }
            if let progress = controller.progress {
                HStack { ProgressView().controlSize(.small); Text(progress.phase.rawValue)
                    if let total = progress.total { Text("\(progress.completed) / \(total)") }
                }
            }
            if let message = controller.message { Text(message).textSelection(.enabled) }
            HStack {
                Spacer()
                if controller.isBusy { Button("取消作业", action: controller.cancel) }
                else {
                    Button("关闭") { controller.isPresented = false }.keyboardShortcut(.cancelAction)
                    Button(controller.mode == .importing ? "选择 ORA 文件…" : "选择导出位置…", action: controller.chooseFile)
                        .disabled(controller.mode == .exporting && !controller.flattened && !controller.unsupported.isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }.padding(24).frame(width: 540).preferredColorScheme(.dark).interactiveDismissDisabled(controller.isBusy)
    }
}

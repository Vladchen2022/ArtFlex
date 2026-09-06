import SwiftUI

extension BlockReferenceParameterPanel {
    func cameraWorkflowControls(_ scene: BlockReferenceScene) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if viewModel.blockReferenceWorkflow.inspectionCamera != nil {
                Button("返回原构图") { viewModel.returnToBlockReferenceComposition() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("临时环绕检查") { viewModel.beginBlockReferenceInspection() }
                    .disabled(scene.objects.isEmpty)
            }
            HStack {
                navigationButton("环绕", .orbit)
                navigationButton("平移", .pan)
                navigationButton("远近", .zoom)
            }
            .disabled(scene.display.isFrozen && viewModel.blockReferenceWorkflow.inspectionCamera == nil)
            Text("选择上方操作后直接拖动画布。⌥ 拖动环绕，⌥⇧ 拖动平移；触控板双指平移，捏合远近。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Button("正面") { viewModel.setBlockReferenceStandardView(yaw: -90, pitch: 0) }
                Button("侧面") { viewModel.setBlockReferenceStandardView(yaw: 0, pitch: 0) }
                Button("顶面") { viewModel.setBlockReferenceStandardView(yaw: -90, pitch: 89.9) }
                Button("斜视") { viewModel.setBlockReferenceStandardView(yaw: -45, pitch: 30) }
            }.disabled(scene.display.isFrozen && viewModel.blockReferenceWorkflow.inspectionCamera == nil)
            HStack {
                Button("对准所选") { viewModel.frameBlockReferenceCamera(selectedOnly: true) }
                Button("显示全部") { viewModel.frameBlockReferenceCamera(selectedOnly: false) }
            }.disabled(scene.display.isFrozen || viewModel.blockReferenceWorkflow.inspectionCamera != nil)
            Text("这里调整 3D 相机；主画布缩放不会改变模型透视。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.buttonStyle(.bordered).controlSize(.small)
    }

    private func navigationButton(_ title: String, _ mode: BlockReferenceNavigationMode) -> some View {
        Button(title) { viewModel.setBlockReferenceNavigationTool(mode) }
            .tint(viewModel.blockReferenceWorkflow.navigationMode == mode ? .blue : .gray)
    }

    func referenceWorkflowControls(_ scene: BlockReferenceScene) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("锁定参考，返回绘画") { viewModel.freezeBlockReferenceAndSelectBrush() }
                .buttonStyle(.borderedProminent)
            Text("保留可编辑的 3D 数据；不烘焙、不删除体块。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach(BlockReferenceDisplayPreset.allCases, id: \.rawValue) { preset in
                Button(preset.rawValue) { viewModel.setBlockReferenceDisplayPreset(preset) }
                    .buttonStyle(.bordered)
            }
            Text("绘画时透明度 \(Int(scene.display.paintingOpacity * 100))%")
            Slider(value: Binding(get: { Double(scene.display.paintingOpacity) },
                set: { viewModel.setBlockReferencePaintingOpacity(Float($0)) }), in: 0.05...1,
                onEditingChanged: viewModel.setBlockReferenceParameterEditing)
                .accessibilityLabel("绘画参考透明度")
            Text("建模透明度与绘画透明度分别记忆。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            DisclosureGroup("简单光向") {
                Text("水平方向")
                Slider(value: Binding(get: { scene.display.lightAzimuth },
                    set: { viewModel.setBlockReferenceLight(azimuth: $0) }), in: -180...180,
                    onEditingChanged: viewModel.setBlockReferenceParameterEditing)
                Text("光源高度")
                Slider(value: Binding(get: { scene.display.lightElevation },
                    set: { viewModel.setBlockReferenceLight(elevation: $0) }), in: 5...90,
                    onEditingChanged: viewModel.setBlockReferenceParameterEditing)
            }
            Text("3D 随工程保存。普通图片导出仅包含绘画图层，不包含这层辅助参考。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

struct BlockReferencePaintingBar: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    var body: some View {
        if let scene = viewModel.blockReferenceScene {
            HStack(spacing: 10) {
                Button(scene.display.isVisible ? "隐藏参考" : "显示参考") {
                    viewModel.setBlockReferenceVisibility(!scene.display.isVisible)
                }
                Text("参考")
                Slider(value: Binding(get: { Double(scene.display.paintingOpacity) },
                    set: { viewModel.setBlockReferencePaintingOpacity(Float($0)) }), in: 0.05...1,
                    onEditingChanged: viewModel.setBlockReferenceParameterEditing)
                    .frame(width: 90).accessibilityLabel("绘画参考透明度")
                Menu("样式") {
                    ForEach(BlockReferenceDisplayPreset.allCases, id: \.rawValue) { preset in
                        Button(preset.rawValue) { viewModel.setBlockReferenceDisplayPreset(preset) }
                    }
                }
                Button("返回体块编辑") { viewModel.selectTool(.blockReference) }
            }
            .font(.system(size: 12)).buttonStyle(.borderless)
            .padding(10).foregroundStyle(.white)
            .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: 560)
            .environment(\.colorScheme, .dark)
        }
    }
}

import SwiftUI

struct GeneratorParameterPanel: View {
    @ObservedObject var viewModel: WorkspaceViewModel

    private var selectedKind: GeneratorKind {
        viewModel.workspace.generator.kind
    }

    private var support: GeneratorKindSupport {
        GeneratorFeatureSupport.support(for: selectedKind)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedKind.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white)
                    Text(generatorDescription)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.72))
                }
                Spacer(minLength: 8)
                Circle()
                    .fill(
                        viewModel.isGeneratorStrokeModeEnabled || viewModel.isGeneratorRegionSelectionArmed
                            ? Color.green
                            : Color.secondary.opacity(0.45)
                    )
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(
                        viewModel.isGeneratorStrokeModeEnabled || viewModel.isGeneratorRegionSelectionArmed
                            ? "生成器已启用"
                            : "生成器未启用"
                    )
            }

            Picker("类型", selection: Binding(
                get: { selectedKind },
                set: { viewModel.setGeneratorKind($0) }
            )) {
                ForEach(GeneratorFeatureSupport.userVisibleKinds, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.menu)
            .foregroundStyle(Color.white)

            generatorSlider(
                title: "密度",
                value: viewModel.workspace.generator.density,
                setter: viewModel.setGeneratorDensity
            )
            generatorSlider(
                title: "漂移",
                value: viewModel.workspace.generator.drift,
                setter: viewModel.setGeneratorDrift
            )
            generatorSlider(
                title: "分支",
                value: viewModel.workspace.generator.branch,
                setter: viewModel.setGeneratorBranch
            )
            generatorSlider(
                title: "不透明度",
                value: viewModel.workspace.generator.opacity,
                setter: viewModel.setGeneratorOpacity
            )

            HStack(spacing: 8) {
                if support.supports(.directStroke) {
                    Button(viewModel.isGeneratorStrokeModeEnabled ? "重新进入直接绘制" : "直接绘制") {
                        viewModel.setGeneratorKind(selectedKind)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Label("仅支持区域生成", systemImage: "selection.pin.in.out")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                Button("圈选区域生成") {
                    viewModel.beginGeneratorRegionSelection()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isGeneratorRegionSelectionArmed)
            }

            if viewModel.isGeneratorRegionSelectionArmed {
                Label("连续圈选已开启；每次生成后可直接圈选下一区域", systemImage: "repeat")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.green.opacity(0.9))
            }

            HStack {
                Button("应用到当前选区") {
                    viewModel.applyGeneratorToActiveLayer()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.workspace.selection.committedShape == nil)

                Spacer()

                Button("退出") {
                    viewModel.exitGeneratorMode()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.white.opacity(0.72))
                .disabled(!viewModel.isGeneratorStrokeModeEnabled && !viewModel.isGeneratorRegionSelectionArmed)
            }
        }
        .padding(12)
        .frame(width: 310)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(red: 0.115, green: 0.12, blue: 0.135))
        )
        .foregroundStyle(Color.white)
        .tint(Color.accentColor)
        .preferredColorScheme(.dark)
    }

    private var generatorDescription: String {
        switch selectedKind {
        case .automaticLines:
            return "游走线条与分支，可直接绘制或在区域内生成"
        case .driftDraw:
            return "带低频偏移的手绘轨迹，可直接绘制或在区域内生成"
        case .elasticWhip:
            return "带滞后与回弹的长弧线，转向时会产生甩动"
        case .tremorTrace:
            return "高频细碎颤动，保留手势的大方向"
        case .angularBreaks:
            return "方向会突然折转，形成不规则的折线节奏"
        }
    }

    private func generatorSlider(
        title: String,
        value: Float,
        setter: @escaping (Float) -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))
                .frame(width: 54, alignment: .leading)
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { setter(Float($0)) }
                ),
                in: 0...1
            )
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .frame(width: 36, alignment: .trailing)
                .foregroundStyle(Color.white.opacity(0.72))
        }
    }
}

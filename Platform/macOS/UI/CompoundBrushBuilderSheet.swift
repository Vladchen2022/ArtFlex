import AppKit
import SwiftUI

struct CompoundBrushBuilderSheet: View {
    private enum EditorScope: String, CaseIterable, Identifiable {
        case overall = "整体"
        case primary = "A 外形"
        case secondary = "B 纹理"
        case mix = "压感组合"

        var id: String { rawValue }
    }

    private enum TipLibraryTarget: String, Identifiable {
        case primary
        case compoundSecondary

        var id: String { rawValue }

        var title: String {
            switch self {
            case .primary:
                return "A 外形笔尖图片资料库"
            case .compoundSecondary:
                return "B 纹理笔尖图片资料库"
            }
        }
    }

    @ObservedObject var viewModel: WorkspaceViewModel
    let onClose: () -> Void

    @State private var selectedScope: EditorScope = .overall
    @State private var primaryPreviewImage: CGImage?
    @State private var secondaryPreviewImage: CGImage?
    @State private var lightPressurePreviewImage: CGImage?
    @State private var mediumPressurePreviewImage: CGImage?
    @State private var heavyPressurePreviewImage: CGImage?
    @State private var tipLibraryTarget: TipLibraryTarget?
    @State private var primaryPendingSelection: BrushTipImageAssetID?
    @State private var compoundPendingSelection: BrushTipImageAssetID?
    @State private var initialBrush: BrushSettings?
    @State private var previewTask: Task<Void, Never>?
    @State private var previewGeneration = 0
    @State private var previewChannel: CompoundBrushPreviewChannel = .result
    @State private var previewBackground: CompoundBrushPreviewBackground = .dark
    @State private var previewPressure: Float = 0.5
    @State private var drawingPadClearToken = 0
    @State private var didFinalizeEditing = false

    private var brush: BrushSettings { viewModel.workspace.toolSession.brush }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            livePreviewWorkspace
            scopeNavigator
            Divider().overlay(Color.white.opacity(0.08))

            ScrollView(.vertical, showsIndicators: true) {
                scopeContent
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            Divider().overlay(Color.white.opacity(0.08))
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.10, green: 0.10, blue: 0.11))
        .onAppear {
            if initialBrush == nil {
                initialBrush = brush
            }
            schedulePreviews(for: brush, immediate: true)
        }
        .onChange(of: brush) { _, updatedBrush in
            schedulePreviews(for: updatedBrush)
        }
        .onDisappear {
            previewTask?.cancel()
            previewTask = nil
            if didFinalizeEditing == false, let initialBrush {
                viewModel.restoreCompoundBrushEditingSnapshot(initialBrush)
            }
        }
        .sheet(item: $tipLibraryTarget) { target in
            tipImageLibrarySheet(for: target)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: cancelAndClose) {
                Image(systemName: "chevron.right")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.white.opacity(0.9))
            .help("返回右侧面板")

            VStack(alignment: .leading, spacing: 2) {
                Text("组合笔刷编辑器")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                Text("A 决定边界，B 决定边界内部的纹理")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.56))
            }

            Spacer(minLength: 8)

            Toggle(
                brush.compoundBrush.enabled ? "已启用" : "已停用",
                isOn: Binding(
                    get: { brush.compoundBrush.enabled },
                    set: { viewModel.setCompoundBrushEnabled($0) }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.86))
        }
        .padding(.horizontal, 14)
        .frame(height: 54)
    }

    private var livePreviewWorkspace: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("真实渲染画板")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.88))

                Picker("预览通道", selection: $previewChannel) {
                    ForEach(CompoundBrushPreviewChannel.allCases) { channel in
                        Text(channel.rawValue).tag(channel)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(maxWidth: 230)

                Spacer(minLength: 0)

                Menu {
                    ForEach(CompoundBrushPreviewBackground.allCases) { background in
                        Button {
                            previewBackground = background
                        } label: {
                            Label(background.rawValue, systemImage: background.systemImage)
                        }
                    }
                } label: {
                    Image(systemName: previewBackground.systemImage)
                        .frame(width: 28, height: 26)
                }
                .menuStyle(.borderlessButton)
                .help("切换预览背景")

                Button {
                    drawingPadClearToken &+= 1
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 28, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.white.opacity(0.82))
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.07)))
                .help("清空画板")
            }

            ZStack(alignment: .topLeading) {
                CompoundBrushDrawingPad(
                    brush: drawingPadBrush,
                    pressure: previewPressure,
                    background: previewBackground,
                    clearToken: drawingPadClearToken
                )
                .frame(height: 154)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )

                if previewChannel == .result, brush.compoundBrush.enabled == false {
                    Text("组合已停用：结果通道按真实状态仅显示 A")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.orange.opacity(0.9))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.52), in: RoundedRectangle(cornerRadius: 5))
                        .padding(7)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: 8) {
                Text("画板压力")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.62))
                Slider(
                    value: Binding(
                        get: { Double(previewPressure) },
                        set: { previewPressure = Float($0) }
                    ),
                    in: 0.05...1
                )
                .controlSize(.small)
                Text("\(Int(previewPressure * 100))%")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.66))
                    .frame(width: 36, alignment: .trailing)
                Text("拖动画板直接试笔；参数变化会重放已有笔迹")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.40))
            }

            pressurePreviewStrip
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.16))
    }

    private var pressurePreviewStrip: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("真实笔迹预览")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.88))
                Spacer()
                if previewTask != nil {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text("轻压 → 重压")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.46))
            }

            HStack(spacing: 7) {
                pressurePreviewCell(title: "轻 20%", image: lightPressurePreviewImage)
                pressurePreviewCell(title: "中 50%", image: mediumPressurePreviewImage)
                pressurePreviewCell(title: "重 85%", image: heavyPressurePreviewImage)
            }
        }
        .padding(.top, 2)
    }

    private func pressurePreviewCell(title: String, image: CGImage?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ZStack {
                Color.black.opacity(0.34)
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .padding(4)
                } else {
                    Text("生成中")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.34))
                }
            }
            .frame(height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(title)
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.58))
        }
        .frame(maxWidth: .infinity)
    }

    private var scopeNavigator: some View {
        HStack(spacing: 7) {
            scopeNavigatorButton(.overall, systemImage: "slider.horizontal.3", preview: nil)
            scopeNavigatorButton(.primary, systemImage: nil, preview: primaryPreviewImage)
            scopeNavigatorButton(.mix, systemImage: "circle.grid.cross", preview: nil)
            scopeNavigatorButton(.secondary, systemImage: nil, preview: secondaryPreviewImage)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.white.opacity(0.025))
    }

    private func scopeNavigatorButton(
        _ scope: EditorScope,
        systemImage: String?,
        preview: CGImage?
    ) -> some View {
        Button {
            selectedScope = scope
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    if let preview {
                        Image(decorative: preview, scale: 1)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .padding(3)
                    } else if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .frame(height: 25)

                Text(scope.rawValue)
                    .font(.system(size: 9, weight: .bold))
                    .lineLimit(1)
            }
            .foregroundStyle(selectedScope == scope ? Color.white : Color.white.opacity(0.62))
            .frame(maxWidth: .infinity, minHeight: 49)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selectedScope == scope ? Color.accentColor.opacity(0.76) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(selectedScope == scope ? Color.accentColor : Color.white.opacity(0.07), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var scopeContent: some View {
        switch selectedScope {
        case .overall:
            overallControls
        case .primary:
            primaryControls
        case .secondary:
            secondaryControls
        case .mix:
            mixControls
        }
    }

    private var overallControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            editorSectionHeader("整体响应", detail: "这些参数同时影响最终组合结果")

            editorSlider(
                title: "整体透明",
                value: Double(brush.opacity),
                valueText: "\(Int(brush.opacity * 100))%",
                range: 0...1,
                liveValueText: { "\(Int($0 * 100))%" }
            ) { viewModel.setBrushOpacity(Float($0)) }

            editorSlider(
                title: "散布",
                value: Double(brush.scatterAmount),
                valueText: String(format: "%.1fx", brush.scatterAmount),
                range: 0...5,
                liveValueText: { String(format: "%.1fx", $0) }
            ) { viewModel.setBrushScatterAmount(Float($0)) }

            editorSlider(
                title: "位置抖动",
                value: Double(brush.jitterAmount),
                valueText: "\(Int(brush.jitterAmount * 100))%",
                range: 0...1,
                liveValueText: { "\(Int($0 * 100))%" }
            ) { viewModel.setBrushJitterAmount(Float($0)) }

            editorDivider
            editorSectionHeader("整体压感", detail: "区别于 A、B 各自的压感响应")

            editorSlider(
                title: "整体大小压感",
                value: Double(brush.compoundBrush.globalPressureSizeAmount),
                valueText: "\(Int(brush.compoundBrush.globalPressureSizeAmount * 100))%",
                range: 0...1,
                liveValueText: { "\(Int($0 * 100))%" }
            ) { viewModel.setPressureSizeAmount(Float($0)) }

            editorSlider(
                title: "整体透明压感",
                value: Double(brush.compoundBrush.globalPressureOpacityAmount),
                valueText: "\(Int(brush.compoundBrush.globalPressureOpacityAmount * 100))%",
                range: 0...1,
                liveValueText: { "\(Int($0 * 100))%" }
            ) { viewModel.setPressureOpacityAmount(Float($0)) }

            editorDivider
            editorSectionHeader("颜料变化", detail: "作用于组合后的整条笔迹")

            editorSlider(
                title: "杂色",
                value: Double(brush.compoundBrush.globalPaintJitterAmount),
                valueText: "\(Int(brush.compoundBrush.globalPaintJitterAmount * 100))%",
                range: 0...1,
                liveValueText: { "\(Int($0 * 100))%" }
            ) { viewModel.setPaintJitterAmount(Float($0)) }

            editorSlider(
                title: "颜料反差",
                value: Double(brush.compoundBrush.globalPaintContrastAmount),
                valueText: "\(Int(brush.compoundBrush.globalPaintContrastAmount * 100))%",
                range: 0...1,
                liveValueText: { "\(Int($0 * 100))%" }
            ) { viewModel.setPaintContrastAmount(Float($0)) }

            Toggle(
                "不透明度封顶",
                isOn: Binding(
                    get: { brush.buildMode == .opacityCap },
                    set: { viewModel.setBrushBuildMode($0 ? .opacityCap : .buildUp) }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.84))

            if brush.buildMode == .buildUp {
                editorSlider(
                    title: "透明修正",
                    value: Double(brush.buildUpOpacityCompensationAmount),
                    valueText: "\(Int(brush.buildUpOpacityCompensationAmount * 100))%",
                    range: 0...1,
                    liveValueText: { "\(Int($0 * 100))%" }
                ) { viewModel.setBuildUpOpacityCompensationAmount(Float($0)) }
            }
        }
    }

    private var primaryControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            tipSourceControls(
                title: "A 外形笔尖",
                summary: primaryTipSummary(for: brush),
                image: primaryPreviewImage,
                importAction: viewModel.importBrushTipImageFromDisk,
                libraryAction: {
                    primaryPendingSelection = brush.customTipAssetID
                    tipLibraryTarget = .primary
                },
                clearAction: nil
            )

            tipShapePicker(selected: brush.tipShape) { viewModel.setBrushTipShape($0) }

            Toggle(
                "跟随笔迹方向",
                isOn: Binding(
                    get: { brush.followsStrokeDirection },
                    set: { viewModel.setBrushFollowsStrokeDirection($0) }
                )
            )
            .editorToggleStyle()

            editorSlider(
                title: "A 基准大小",
                value: Double(brush.size),
                valueText: "\(Int(brush.size)) px",
                range: 1...512,
                liveValueText: { "\(Int($0)) px" }
            ) { viewModel.setBrushSize(Float($0)) }

            editorSlider(
                title: "A 间距",
                value: Double(brush.spacingPercent),
                valueText: "\(Int(brush.spacingPercent))%",
                range: 5...150,
                liveValueText: { "\(Int($0))%" }
            ) { viewModel.setBrushSpacingPercent(Float($0)) }

            editorSlider(
                title: "A 旋转",
                value: Double(brush.stampRotationDegrees),
                valueText: "\(Int(brush.stampRotationDegrees))°",
                range: 0...360,
                liveValueText: { "\(Int($0))°" }
            ) { viewModel.setBrushStampRotationDegrees(Float($0)) }

            editorDivider
            editorSectionHeader("A 自身压感", detail: "只改变外形笔尖，不替代整体压感")

            editorSlider(
                title: "A 大小压感",
                value: Double(brush.pressureSizeAmount),
                valueText: "\(Int(brush.pressureSizeAmount * 100))%",
                range: 0...1,
                liveValueText: { "\(Int($0 * 100))%" }
            ) { viewModel.setCompoundPrimaryPressureSizeAmount(Float($0)) }

            editorSlider(
                title: "A 透明压感",
                value: Double(brush.pressureOpacityAmount),
                valueText: "\(Int(brush.pressureOpacityAmount * 100))%",
                range: 0...1,
                liveValueText: { "\(Int($0 * 100))%" }
            ) { viewModel.setCompoundPrimaryPressureOpacityAmount(Float($0)) }

            if brush.tipShape == .customRound {
                editorDivider
                editorSectionHeader("A 笔尖形状", detail: nil)
                editorSlider(
                    title: "柔度",
                    value: Double(brush.customTipSoftness),
                    valueText: "\(Int(brush.customTipSoftness * 100))%",
                    range: 0...1,
                    liveValueText: { "\(Int($0 * 100))%" }
                ) { viewModel.setCustomTipSoftness(Float($0)) }
                editorSlider(
                    title: "圆度",
                    value: Double(brush.customTipRoundness),
                    valueText: "\(Int(brush.customTipRoundness * 100))%",
                    range: 0.25...1,
                    liveValueText: { "\(Int($0 * 100))%" }
                ) { viewModel.setCustomTipRoundness(Float($0)) }
            }
        }
    }

    private var secondaryControls: some View {
        let secondary = brush.compoundBrush.secondary
        return VStack(alignment: .leading, spacing: 12) {
            tipSourceControls(
                title: "B 纹理笔尖",
                summary: secondaryTipSummary(for: secondary),
                image: secondaryPreviewImage,
                importAction: viewModel.importCompoundSecondaryTipImageFromDisk,
                libraryAction: {
                    compoundPendingSelection = secondary.tipAssetID
                    tipLibraryTarget = .compoundSecondary
                },
                clearAction: viewModel.clearCompoundSecondaryTipMask
            )

            tipShapePicker(selected: secondary.tipShape) { viewModel.setCompoundSecondaryTipShape($0) }

            HStack(spacing: 16) {
                Toggle(
                    "跟随笔迹方向",
                    isOn: Binding(
                        get: { secondary.followsStrokeDirection },
                        set: { viewModel.setCompoundSecondaryFollowsStrokeDirection($0) }
                    )
                )
                Toggle(
                    "相对 A 大小",
                    isOn: Binding(
                        get: { secondary.sizeMode == .relativeToPrimary },
                        set: { viewModel.setCompoundSecondaryUsesRelativeSize($0) }
                    )
                )
            }
            .editorToggleStyle()

            editorSlider(
                title: secondary.sizeMode == .relativeToPrimary ? "B 相对大小" : "B 绝对大小",
                value: secondary.sizeMode == .relativeToPrimary
                    ? Double(secondary.relativeSizeRatio * 100)
                    : Double(secondary.size),
                valueText: secondary.sizeMode == .relativeToPrimary
                    ? "\(Int(secondary.relativeSizeRatio * 100))%"
                    : "\(Int(secondary.size)) px",
                range: secondary.sizeMode == .relativeToPrimary ? 5...400 : 1...512,
                liveValueText: { value in
                    secondary.sizeMode == .relativeToPrimary ? "\(Int(value))%" : "\(Int(value)) px"
                }
            ) {
                if secondary.sizeMode == .relativeToPrimary {
                    viewModel.setCompoundSecondaryRelativeSizeRatio(Float($0 / 100))
                } else {
                    viewModel.setCompoundSecondarySize(Float($0))
                }
            }

            editorSlider(
                title: "B 间距",
                value: Double(secondary.spacingPercent),
                valueText: "\(Int(secondary.spacingPercent))%",
                range: 1...400,
                liveValueText: { "\(Int($0))%" }
            ) { viewModel.setCompoundSecondarySpacingPercent(Float($0)) }

            editorSlider(
                title: "B 角度",
                value: Double(secondary.angleDegrees),
                valueText: "\(Int(secondary.angleDegrees))°",
                range: 0...180,
                liveValueText: { "\(Int($0))°" }
            ) { viewModel.setCompoundSecondaryTipAngleDegrees(Float($0)) }

            editorSlider(
                title: "B 随机旋转",
                value: Double(secondary.tileRandomRotation),
                valueText: "\(Int(secondary.tileRandomRotation * 100))%",
                range: 0...1,
                liveValueText: { "\(Int($0 * 100))%" }
            ) { viewModel.setCompoundSecondaryTileRandomRotation(Float($0)) }

            editorDivider
            editorSectionHeader("B 自身压感", detail: "控制纹理印记随压力的大小和透明变化")

            editorSlider(
                title: "B 大小压感",
                value: Double(secondary.pressureSizeAmount),
                valueText: "\(Int(secondary.pressureSizeAmount * 100))%",
                range: 0...1,
                liveValueText: { "\(Int($0 * 100))%" }
            ) { viewModel.setCompoundSecondaryPressureSizeAmount(Float($0)) }

            editorSlider(
                title: "B 透明压感",
                value: Double(secondary.pressureOpacityAmount),
                valueText: "\(Int(secondary.pressureOpacityAmount * 100))%",
                range: 0...1,
                liveValueText: { "\(Int($0 * 100))%" }
            ) { viewModel.setCompoundSecondaryPressureOpacityAmount(Float($0)) }

            if secondary.tipShape == .customRound {
                editorDivider
                editorSectionHeader("B 笔尖形状", detail: nil)
                editorSlider(
                    title: "柔度",
                    value: Double(secondary.softness),
                    valueText: "\(Int(secondary.softness * 100))%",
                    range: 0...1,
                    liveValueText: { "\(Int($0 * 100))%" }
                ) { viewModel.setCompoundSecondaryTipSoftness(Float($0)) }
                editorSlider(
                    title: "圆度",
                    value: Double(secondary.roundness),
                    valueText: "\(Int(secondary.roundness * 100))%",
                    range: 0.25...1,
                    liveValueText: { "\(Int($0 * 100))%" }
                ) { viewModel.setCompoundSecondaryTipRoundness(Float($0)) }
            }

            Text("B 始终被 A 的外形边界裁切，不会画到 A 之外。")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.48))
        }
    }

    private var mixControls: some View {
        let mix = brush.compoundBrush.pressureMix
        let mode = brush.compoundBrush.mode.editorEquivalent
        let usesOverlay = mode == .overlay
        return VStack(alignment: .leading, spacing: 12) {
            editorSectionHeader("组合方式", detail: "可直接保留 B，也可用 B 叠加调制 A 的透明度")

            HStack(spacing: 8) {
                ForEach(CompoundBrushMode.editorCases, id: \.self) { mode in
                    compoundModeButton(mode, selected: brush.compoundBrush.mode.editorEquivalent == mode)
                }
            }

            editorDivider
            editorSectionHeader(
                "压感组合",
                detail: usesOverlay
                    ? "压力控制结果从原始 B 纹理逐渐迁移到 B 叠加调制 A"
                    : "压力越大，结果可以从 B 纹理逐渐迁移到完整 A 外形"
            )

            CompoundPressureMixCurveEditor(
                mix: mix,
                mode: mode,
                onChange: viewModel.setCompoundPressureMix
            )
                .frame(height: 138)

            HStack(spacing: 7) {
                pressurePresetButton(usesOverlay ? "B → 叠加" : "B → A", settings: .default)
                pressurePresetButton(usesOverlay ? "叠加 → B" : "A → B", settings: .reversed)
                pressurePresetButton("中压 B", settings: .secondaryAtMidPressure)
            }

            HStack(spacing: 7) {
                pressurePresetButton(usesOverlay ? "始终叠加" : "始终 A", settings: .primaryOnly)
                pressurePresetButton("始终 B", settings: .secondaryOnly)
                pressurePresetButton("固定混合", settings: .balanced)
            }

            mixSlider(
                title: "轻压结果",
                value: Double(mix.primaryAtLowPressure)
            ) { viewModel.setCompoundPrimaryMixAtLowPressure(Float($0)) }

            mixSlider(
                title: "中压结果",
                value: Double(mix.primaryAtMidPressure)
            ) { viewModel.setCompoundPrimaryMixAtMidPressure(Float($0)) }

            mixSlider(
                title: "重压结果",
                value: Double(mix.primaryAtHighPressure)
            ) { viewModel.setCompoundPrimaryMixAtHighPressure(Float($0)) }

            HStack {
                Text("B 纹理")
                Spacer()
                Text(usesOverlay ? "叠加结果" : "A 外形")
            }
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Color.white.opacity(0.5))
        }
    }

    private func compoundModeButton(_ mode: CompoundBrushMode, selected: Bool) -> some View {
        Button {
            viewModel.setCompoundBrushMode(mode)
        } label: {
            HStack(spacing: 9) {
                CompoundModeGlyph(mode: mode)
                    .frame(width: 54, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.displayName)
                        .font(.system(size: 11, weight: .bold))
                    Text(compoundModeDescription(mode))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Color.accentColor.opacity(0.16) : Color.white.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(selected ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.07), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private func compoundModeDescription(_ mode: CompoundBrushMode) -> String {
        switch mode {
        case .subtract:
            return "保留 B 的空白"
        case .overlay:
            return "B 叠加调制 A"
        case .textureBlend, .intersect:
            return "保留 B 的形状"
        }
    }

    private func pressurePresetButton(
        _ title: String,
        settings: CompoundPressureMixSettings
    ) -> some View {
        Button(title) {
            viewModel.setCompoundPressureMix(settings)
        }
        .buttonStyle(CompoundEditorButtonStyle(isProminent: mixApproximatelyEquals(settings)))
        .frame(maxWidth: .infinity)
    }

    private func mixApproximatelyEquals(_ settings: CompoundPressureMixSettings) -> Bool {
        let current = brush.compoundBrush.pressureMix
        return abs(current.primaryAtLowPressure - settings.primaryAtLowPressure) < 0.001
            && abs(current.primaryAtMidPressure - settings.primaryAtMidPressure) < 0.001
            && abs(current.primaryAtHighPressure - settings.primaryAtHighPressure) < 0.001
    }

    private func mixSlider(
        title: String,
        value: Double,
        onCommit: @escaping (Double) -> Void
    ) -> some View {
        CompoundEditorSlider(
            title: title,
            value: value,
            range: 0...1,
            valueText: { "\(Int(($0 * 100).rounded()))%" },
            onCommit: onCommit
        )
    }

    private func tipSourceControls(
        title: String,
        summary: String,
        image: CGImage?,
        importAction: @escaping () -> Void,
        libraryAction: @escaping () -> Void,
        clearAction: (() -> Void)?
    ) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Color.black.opacity(0.34)
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .padding(7)
                }
            }
            .frame(width: 76, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                Text(summary)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.56))
                    .lineLimit(2)

                HStack(spacing: 7) {
                    editorIconButton("photo.badge.plus", help: "导入笔尖", action: importAction)
                    editorIconButton("square.grid.3x2", help: "打开笔尖资料库", action: libraryAction)
                    if let clearAction {
                        editorIconButton("trash", help: "清空自定义笔尖", action: clearAction)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func tipShapePicker(
        selected: BrushTipShape,
        onSelect: @escaping (BrushTipShape) -> Void
    ) -> some View {
        HStack(spacing: 7) {
            ForEach(
                [BrushTipShape.hardRound, .softRound, .square, .customRound],
                id: \.self
            ) { shape in
                Button(shape.displayName) { onSelect(shape) }
                    .buttonStyle(CompoundEditorButtonStyle(isProminent: selected == shape))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func editorIconButton(
        _ systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 29, height: 27)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.white.opacity(0.88))
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .help(help)
    }

    private func editorSlider(
        title: String,
        value: Double,
        valueText: String,
        range: ClosedRange<Double>,
        liveValueText: @escaping (Double) -> String,
        onCommit: @escaping (Double) -> Void
    ) -> some View {
        CompoundEditorSlider(
            title: title,
            value: value,
            range: range,
            valueText: liveValueText,
            onCommit: onCommit
        )
    }

    private func editorSectionHeader(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.9))
            if let detail {
                Text(detail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.48))
            }
        }
    }

    private var editorDivider: some View {
        Divider()
            .overlay(Color.white.opacity(0.07))
            .padding(.vertical, 2)
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Button {
                if let initialBrush {
                    viewModel.restoreCompoundBrushEditingSnapshot(initialBrush)
                }
            } label: {
                Label("恢复打开时状态", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(CompoundEditorButtonStyle(isProminent: false))
            .disabled(initialBrush == nil || initialBrush == brush)

            Spacer()

            Button(action: saveAsPreset) {
                Label("另存为笔刷", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(CompoundEditorButtonStyle(isProminent: false))

            Button("取消", action: cancelAndClose)
                .buttonStyle(CompoundEditorButtonStyle(isProminent: false))
                .keyboardShortcut(.cancelAction)

            Button("应用", action: applyAndClose)
                .buttonStyle(CompoundEditorButtonStyle(isProminent: true))
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    private var drawingPadBrush: BrushSettings {
        switch previewChannel {
        case .result:
            var result = brush
            result.compoundBrush.mode = result.compoundBrush.mode.editorEquivalent
            return result
        case .primary:
            var primary = brush
            primary.compoundBrush.enabled = false
            return primary
        case .secondary:
            return secondaryPreviewBrush(from: brush)
        }
    }

    private func cancelAndClose() {
        let openingBrush = initialBrush
        endFocusedTextEditing()
        Task { @MainActor in
            await Task.yield()
            if let openingBrush {
                viewModel.restoreCompoundBrushEditingSnapshot(openingBrush)
            }
            didFinalizeEditing = true
            onClose()
        }
    }

    private func applyAndClose() {
        endFocusedTextEditing()
        Task { @MainActor in
            await Task.yield()
            didFinalizeEditing = true
            onClose()
        }
    }

    private func saveAsPreset() {
        endFocusedTextEditing()
        Task { @MainActor in
            await Task.yield()
            viewModel.saveCurrentBrushPreset()
            initialBrush = brush
        }
    }

    private func endFocusedTextEditing() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private func schedulePreviews(for brush: BrushSettings, immediate: Bool = false) {
        previewTask?.cancel()
        previewGeneration &+= 1
        let generation = previewGeneration
        var previewBrush = brush
        previewBrush.compoundBrush.mode = previewBrush.compoundBrush.mode.editorEquivalent

        previewTask = Task { @MainActor in
            if !immediate {
                try? await Task.sleep(for: .milliseconds(70))
            }
            guard !Task.isCancelled else { return }

            let secondaryBrush = secondaryPreviewBrush(from: previewBrush)
            let input = CompoundPreviewInput(primary: previewBrush, secondary: secondaryBrush)
            let result = await Task.detached(priority: .utility) { [input] in
                let primary = StageOneBrushPreviewRasterizer.stampImage(for: input.primary, resolution: 64)
                let secondary = StageOneBrushPreviewRasterizer.stampImage(for: input.secondary, resolution: 64)
                let light = StageOneBrushPreviewRasterizer.compoundStrokePreviewImage(
                    for: input.primary,
                    resolution: 72,
                    width: 220,
                    pressure: 0.2
                )
                let medium = StageOneBrushPreviewRasterizer.compoundStrokePreviewImage(
                    for: input.primary,
                    resolution: 72,
                    width: 220,
                    pressure: 0.5
                )
                let heavy = StageOneBrushPreviewRasterizer.compoundStrokePreviewImage(
                    for: input.primary,
                    resolution: 72,
                    width: 220,
                    pressure: 0.85
                )
                return CompoundPreviewImages(
                    primary: primary,
                    secondary: secondary,
                    light: light,
                    medium: medium,
                    heavy: heavy
                )
            }.value

            guard !Task.isCancelled, generation == previewGeneration else { return }
            primaryPreviewImage = result.primary
            secondaryPreviewImage = result.secondary
            lightPressurePreviewImage = result.light
            mediumPressurePreviewImage = result.medium
            heavyPressurePreviewImage = result.heavy
            previewTask = nil
        }
    }

    private func secondaryPreviewBrush(from brush: BrushSettings) -> BrushSettings {
        let secondary = brush.compoundBrush.secondary
        var preview = brush
        preview.compoundBrush.enabled = false
        preview.tipShape = secondary.tipShape
        preview.customTipSourceSemantic = secondary.sourceSemantic
        preview.customTipAssetID = secondary.tipAssetID
        preview.customTipImportedSourceInfo = secondary.importedSourceInfo
        preview.customTipMaskData = secondary.customTipMaskData
        preview.customTipEnvelopeMaskData = secondary.customTipMaskData
        preview.customTipSoftness = secondary.softness
        preview.customTipRoundness = secondary.roundness
        preview.customTipAngleDegrees = secondary.angleDegrees
        preview.followsStrokeDirection = secondary.followsStrokeDirection
        preview.size = secondary.resolvedBaseSize(for: brush.size)
        preview.spacingPercent = secondary.spacingPercent
        preview.pressureSizeAmount = secondary.pressureSizeAmount
        preview.pressureOpacityAmount = secondary.pressureOpacityAmount
        preview.sizeCurveLow = secondary.sizeCurveLow
        preview.sizeCurveMid = secondary.sizeCurveMid
        preview.sizeCurveHigh = secondary.sizeCurveHigh
        preview.opacityCurveLow = secondary.opacityCurveLow
        preview.opacityCurveMid = secondary.opacityCurveMid
        preview.opacityCurveHigh = secondary.opacityCurveHigh
        preview.opacityPressureCurve = secondary.opacityPressureCurve
        return preview
    }

    private func primaryTipSummary(for brush: BrushSettings) -> String {
        if brush.tipShape == .customRound {
            switch brush.customTipSourceSemantic {
            case .importedImage:
                return brush.customTipImportedSourceInfo?.sourceLabel ?? "导入图像笔尖"
            case .customMask:
                return "自定义绘制笔尖"
            case .procedural:
                return "自定义圆形笔尖"
            }
        }
        return brush.tipShape.displayName
    }

    private func secondaryTipSummary(for secondary: CompoundSecondaryTipSettings) -> String {
        if secondary.tipShape == .customRound {
            switch secondary.sourceSemantic {
            case .importedImage:
                return secondary.importedSourceInfo?.sourceLabel ?? "导入图像笔尖"
            case .customMask:
                return "自定义纹理笔尖"
            case .procedural:
                return "自定义圆形笔尖"
            }
        }
        return secondary.tipShape.displayName
    }

    private func pendingSelection(for target: TipLibraryTarget) -> BrushTipImageAssetID? {
        switch target {
        case .primary:
            return primaryPendingSelection
        case .compoundSecondary:
            return compoundPendingSelection
        }
    }

    private func setPendingSelection(_ assetID: BrushTipImageAssetID?, for target: TipLibraryTarget) {
        switch target {
        case .primary:
            primaryPendingSelection = assetID
        case .compoundSecondary:
            compoundPendingSelection = assetID
        }
    }

    @ViewBuilder
    private func tipImageLibrarySheet(for target: TipLibraryTarget) -> some View {
        let items = viewModel.workspace.tipImageLibrary.items
        let selectedPendingAssetID = pendingSelection(for: target)

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(target.title)
                        .font(.system(size: 20, weight: .bold))
                    Text("选择素材后点击应用；右键素材可删除。")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.55))
                }
                Spacer()
                Button("导入") {
                    if let importedIDs = viewModel.importTipImageLibraryItemsFromDisk(),
                       importedIDs.count == 1,
                       let assetID = importedIDs.first {
                        setPendingSelection(assetID, for: target)
                    }
                }
                .buttonStyle(.bordered)
                Button("应用") {
                    if let assetID = selectedPendingAssetID {
                        switch target {
                        case .primary:
                            viewModel.applyPrimaryTipImageLibraryItem(assetID)
                        case .compoundSecondary:
                            viewModel.applyCompoundSecondaryTipImageLibraryItem(assetID)
                        }
                    }
                    tipLibraryTarget = nil
                }
                .buttonStyle(.borderedProminent)
            }

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 180), spacing: 10)], spacing: 10) {
                    ForEach(items) { item in
                        Button {
                            setPendingSelection(item.id, for: target)
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                ZStack {
                                    Color.black.frame(height: 90)
                                    if let image = StageOneBrushPreviewRasterizer.importedAssetImage(
                                        from: item.maskData,
                                        resolution: 90
                                    ) {
                                        Image(decorative: image, scale: 1)
                                            .resizable()
                                            .interpolation(.none)
                                            .scaledToFit()
                                            .padding(8)
                                            .frame(maxWidth: .infinity, minHeight: 90, maxHeight: 90)
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 6))

                                Text(item.displayName)
                                    .font(.system(size: 11, weight: .semibold))
                                    .lineLimit(1)
                                Text("\(item.sourceInfo.pixelWidth)x\(item.sourceInfo.pixelHeight)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.055)))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(
                                        selectedPendingAssetID == item.id ? Color.accentColor : Color.white.opacity(0.08),
                                        lineWidth: selectedPendingAssetID == item.id ? 2 : 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                _ = viewModel.deleteTipImageLibraryItem(item.id)
                                if pendingSelection(for: target) == item.id {
                                    setPendingSelection(nil, for: target)
                                }
                            } label: {
                                Label("删除素材", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(minWidth: 820, minHeight: 600)
        .foregroundStyle(.white)
        .background(Color(red: 0.10, green: 0.10, blue: 0.11))
    }
}

private struct CompoundPreviewInput: Sendable {
    let primary: BrushSettings
    let secondary: BrushSettings
}

private struct CompoundPreviewImages: @unchecked Sendable {
    let primary: CGImage?
    let secondary: CGImage?
    let light: CGImage?
    let medium: CGImage?
    let heavy: CGImage?
}

private struct CompoundModeGlyph: View {
    let mode: CompoundBrushMode

    var body: some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
            context.fill(Path(roundedRect: bounds, cornerRadius: 5), with: .color(.white.opacity(0.12)))
            for index in 0..<5 {
                let x = bounds.minX + 6 + (CGFloat(index) * 9)
                let stripe = CGRect(x: x, y: bounds.minY + 5, width: 5, height: bounds.height - 10)
                if mode == .subtract {
                    context.fill(Path(roundedRect: stripe, cornerRadius: 2), with: .color(.black.opacity(0.75)))
                } else if mode == .overlay {
                    let alpha = 0.25 + (CGFloat(index) * 0.13)
                    context.fill(Path(roundedRect: stripe, cornerRadius: 2), with: .color(.white.opacity(alpha)))
                } else {
                    context.fill(Path(roundedRect: stripe, cornerRadius: 2), with: .color(.white.opacity(0.78)))
                }
            }
        }
    }
}

private struct CompoundEditorButtonStyle: ButtonStyle {
    let isProminent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.76 : 0.92))
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, 8)
            .frame(minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isProminent ? Color.accentColor.opacity(0.82) : Color.white.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isProminent ? Color.accentColor.opacity(0.95) : Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}

private extension View {
    func editorToggleStyle() -> some View {
        toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.84))
    }
}

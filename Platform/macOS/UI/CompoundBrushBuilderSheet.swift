import AppKit
import SwiftUI

enum CompoundBrushTipLibraryLayout {
    static let idealSize = CGSize(width: 820, height: 600)
    static let containerInset: CGFloat = 32
    static let thumbnailHeight: CGFloat = 88
    static let thumbnailInset: CGFloat = 8

    static func size(fitting containerSize: CGSize) -> CGSize {
        CGSize(
            width: min(idealSize.width, max(1, containerSize.width - containerInset)),
            height: min(idealSize.height, max(1, containerSize.height - containerInset))
        )
    }
}

private struct CompoundBrushEditorSizePreferenceKey: PreferenceKey {
    static let defaultValue = CGSize(
        width: CompoundBrushTipLibraryLayout.idealSize.width + CompoundBrushTipLibraryLayout.containerInset,
        height: CompoundBrushTipLibraryLayout.idealSize.height + CompoundBrushTipLibraryLayout.containerInset
    )

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// A result-oriented brush editor. The active workspace brush is not
/// mutated while this sheet is open; Apply is the only operation that writes
/// the isolated draft back to the tool session.
struct CompoundBrushBuilderSheet: View {
    private enum PressureCurveKind: Equatable {
        case size
        case opacity
        case secondaryOpacity
    }

    private enum TipLibraryTarget: String, Identifiable {
        case range
        case primary
        case secondary

        var id: String { rawValue }
        var title: String {
            switch self {
            case .range: return "笔触范围素材库"
            case .primary: return "笔尖 A 素材库"
            case .secondary: return "笔尖 B 素材库"
            }
        }

        var detailName: String {
            switch self {
            case .range: return "笔触范围"
            case .primary: return "重压笔尖 A"
            case .secondary: return "轻压笔尖 B"
            }
        }
    }

    @ObservedObject var viewModel: WorkspaceViewModel
    let onClose: () -> Void

    @State private var draftBrush: BrushSettings
    @State private var openingBrush: BrushSettings
    @State private var undoStack: [BrushSettings] = []
    @State private var redoStack: [BrushSettings] = []
    @State private var interactiveAnchor: BrushSettings?

    @State private var previewChannel: CompoundBrushPreviewChannel = .result
    @State private var previewBackground: CompoundBrushPreviewBackground = .dark
    @State private var previewPressure: Float = 0.5
    @State private var previewPath: CompoundBrushPreviewPath? = .curve
    @State private var previewPathToken = 1
    @State private var clearToken = 0
    @State private var previewSeed: UInt32 = 0xA17F_1E25
    @State private var previewSeedLocked = true
    @State private var rangePreviewImage: CGImage?
    @State private var primaryPreviewImage: CGImage?
    @State private var secondaryPreviewImage: CGImage?
    @State private var lightPressurePreviewImage: CGImage?
    @State private var mediumPressurePreviewImage: CGImage?
    @State private var heavyPressurePreviewImage: CGImage?
    @State private var previewTask: Task<Void, Never>?
    @State private var previewGeneration = 0

    @State private var showsAdvanced = false
    @State private var showsSizeCurveEditor = false
    @State private var showsOpacityCurveEditor = false
    @State private var showsSecondaryOpacityCurveEditor = false
    @State private var tipLibraryTarget: TipLibraryTarget?
    @State private var rangePendingSelection: BrushTipImageAssetID?
    @State private var primaryPendingSelection: BrushTipImageAssetID?
    @State private var secondaryPendingSelection: BrushTipImageAssetID?
    @State private var isSaveSheetPresented = false
    @State private var editorViewportSize = CompoundBrushEditorSizePreferenceKey.defaultValue

    init(viewModel: WorkspaceViewModel, onClose: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onClose = onClose
        var brush = viewModel.workspace.toolSession.brush
        if brush.compoundBrush.enabled {
            brush.materializeCompoundPrimaryTipIfNeeded()
        }
        _draftBrush = State(initialValue: brush)
        _openingBrush = State(initialValue: brush)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))

            GeometryReader { proxy in
                if proxy.size.width >= 820 {
                    HStack(spacing: 0) {
                        previewColumn
                            .frame(width: min(max(proxy.size.width * 0.42, 360), 430))
                        Divider().overlay(Color.white.opacity(0.08))
                        settingsColumn
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            previewColumn
                            Divider().overlay(Color.white.opacity(0.08))
                            settingsContent
                                .padding(16)
                        }
                    }
                }
            }

            Divider().overlay(Color.white.opacity(0.08))
            footer
        }
        .frame(minWidth: 760, idealWidth: 1040, minHeight: 660, idealHeight: 760)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: CompoundBrushEditorSizePreferenceKey.self,
                    value: proxy.size
                )
            }
        }
        .onPreferenceChange(CompoundBrushEditorSizePreferenceKey.self) { size in
            guard size.width > 0, size.height > 0 else { return }
            editorViewportSize = size
        }
        .background(Color(red: 0.10, green: 0.10, blue: 0.11))
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
        .onAppear {
            previewPathToken &+= 1
            schedulePreviews(immediate: true)
        }
        .onChange(of: draftBrush) { _, _ in
            if previewSeedLocked == false { randomizePreviewSeed() }
            schedulePreviews()
        }
        .onChange(of: previewSeed) { _, _ in schedulePreviews(immediate: true) }
        .onDisappear {
            previewTask?.cancel()
            previewTask = nil
        }
        .sheet(item: $tipLibraryTarget) { target in
            tipImageLibrarySheet(for: target)
        }
        .sheet(isPresented: $isSaveSheetPresented) {
            CompoundBrushSaveSheet(
                brush: draftBrush,
                library: viewModel.workspace.brushLibrary,
                onSave: saveNamedPreset,
                onCancel: { isSaveSheetPresented = false }
            )
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("笔刷编辑器")
                    .font(.system(size: 17, weight: .bold))
                Text("常用参数、笔触叠加和组合纹理在这里一次完成")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.52))
            }

            Spacer()

            if draftBrush != openingBrush {
                Label("未应用", systemImage: "circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
            }

            Button(action: undo) { Image(systemName: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(undoStack.isEmpty && interactiveAnchor == nil)
                .buttonTooltip("撤销编辑")
            Button(action: redo) { Image(systemName: "arrow.uturn.forward") }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(redoStack.isEmpty)
                .buttonTooltip("重做编辑")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 18)
        .frame(height: 58)
    }

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("实时试笔")
                    .font(.system(size: 13, weight: .bold))
                if draftBrush.compoundBrush.enabled {
                    Picker("预览", selection: $previewChannel) {
                        Text("结果").tag(CompoundBrushPreviewChannel.result)
                        Text("笔尖 A").tag(CompoundBrushPreviewChannel.primary)
                        Text("笔尖 B").tag(CompoundBrushPreviewChannel.secondary)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                } else {
                    Text("普通笔刷")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.58))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.06), in: Capsule())
                }
                Spacer()
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
                }
                .menuStyle(.borderlessButton)
                Button {
                    clearToken &+= 1
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            CompoundBrushDrawingPad(
                brush: drawingPadBrush,
                pressure: previewPressure,
                background: previewBackground,
                clearToken: clearToken,
                paintVariationSeed: previewSeed,
                testPattern: previewPath,
                testPatternToken: previewPathToken
            )
            .frame(minHeight: 240)
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.11), lineWidth: 1))

            HStack(spacing: 6) {
                Text("试笔")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.48))
                ForEach(CompoundBrushPreviewPath.allCases) { path in
                    Button {
                        previewPath = path
                        previewPathToken &+= 1
                    } label: {
                        Image(systemName: path.systemImage)
                            .frame(width: 26, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(previewPath == path ? Color.accentColor : Color.white.opacity(0.68))
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(previewPath == path ? Color.accentColor.opacity(0.14) : Color.white.opacity(0.05))
                    )
                    .buttonTooltip(path.rawValue)
                }
                Spacer()
                Button {
                    previewSeedLocked.toggle()
                } label: {
                    Image(systemName: previewSeedLocked ? "lock.fill" : "lock.open")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(previewSeedLocked ? Color.accentColor : Color.white.opacity(0.6))
                Button(action: randomizePreviewSeed) { Image(systemName: "dice.fill") }
                    .buttonStyle(.borderless)
                    .buttonTooltip("重新随机纹理")
            }

            HStack(spacing: 8) {
                Text("压力")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.5))
                Slider(
                    value: Binding(
                        get: { Double(previewPressure) },
                        set: { previewPressure = Float($0) }
                    ),
                    in: 0.05...1
                )
                .controlSize(.small)
                Text("\(Int((previewPressure * 100).rounded()))%")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .frame(width: 38, alignment: .trailing)
                    .foregroundStyle(Color.white.opacity(0.62))
            }

            editorSlider(
                title: "笔刷大小",
                value: Double(draftBrush.size),
                range: 1...512,
                scale: .logarithmic,
                valueText: { "\(Int($0.rounded())) px" }
            ) { brush, value in
                brush.size = Float(value)
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("轻压 / 中压 / 重压")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.62))
                    Spacer()
                    if previewTask != nil { ProgressView().controlSize(.mini) }
                }
                HStack(spacing: 7) {
                    pressurePreviewCell(image: lightPressurePreviewImage, label: "20%")
                    pressurePreviewCell(image: mediumPressurePreviewImage, label: "50%")
                    pressurePreviewCell(image: heavyPressurePreviewImage, label: "85%")
                }
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color.black.opacity(0.14))
    }

    private var settingsColumn: some View {
        ScrollView(.vertical, showsIndicators: true) {
            settingsContent
                .padding(18)
        }
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            brushStructureSection
            commonBrushSection
            strokeBuildSection
            if draftBrush.compoundBrush.enabled {
                quickStartSection
                combinationSection
                if draftBrush.compoundBrush.mode == .textureBlend {
                    pressureDistributionSection
                }
            }
            tipSection
            if draftBrush.compoundBrush.enabled {
                textureBehaviorSection
            }
            advancedSection
            if draftBrush.compoundBrush.enabled {
                diagnosticsSection
            }
        }
        .frame(maxWidth: 620, alignment: .topLeading)
    }

    private var brushStructureSection: some View {
        editorPanel(title: "笔刷结构", detail: "普通笔刷和组合笔刷共用同一套常用参数与叠加设置") {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("组合笔刷")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.9))
                    Text(draftBrush.compoundBrush.enabled ? "A 与 B 都实际绘制，压力决定两者贡献" : "当前只使用主笔尖 A")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { draftBrush.compoundBrush.enabled },
                        set: { enabled in
                            performEdit { $0.setCompoundBrushEnabledUsingArtistDefault(enabled) }
                            if enabled == false { previewChannel = .result }
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .padding(10)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
    }

    private var commonBrushSection: some View {
        editorPanel(title: "常用参数", detail: "与主界面工具参数使用同一份画笔数据，应用后两边保持一致") {
            editorSlider(
                title: "基础不透明度",
                value: Double(draftBrush.opacity),
                range: 0.01...1,
                valueText: percentText
            ) { $0.opacity = Float($1) }

            editorSlider(
                title: draftBrush.compoundBrush.enabled ? "范围间距" : "间距",
                value: Double(draftBrush.spacingPercent),
                range: 1...1_000,
                scale: .logarithmic,
                valueText: { "\(Int($0.rounded()))%" }
            ) { $0.spacingPercent = Float($1) }

            editorSlider(
                title: draftBrush.compoundBrush.enabled ? "范围尺寸随机" : "尺寸随机",
                value: Double(draftBrush.sizeJitterAmount),
                range: 0...1,
                valueText: percentText
            ) { $0.sizeJitterAmount = Float($1) }

            editorSlider(
                title: draftBrush.compoundBrush.enabled ? "整体尺寸" : "尺寸压感",
                value: Double(displayedPressureSizeAmount),
                range: 0...1,
                valueText: percentText
            ) { brush, value in
                if brush.compoundBrush.enabled {
                    brush.compoundBrush.globalPressureSizeAmount = Float(value)
                } else {
                    brush.pressureSizeAmount = Float(value)
                }
            }

            editorSlider(
                title: draftBrush.compoundBrush.enabled ? "整体透明" : "不透明压感",
                value: Double(displayedPressureOpacityAmount),
                range: 0...1,
                valueText: percentText
            ) { brush, value in
                if brush.compoundBrush.enabled {
                    brush.compoundBrush.globalPressureOpacityAmount = Float(value)
                } else {
                    brush.pressureOpacityAmount = Float(value)
                }
            }

            editorSlider(
                title: "杂色",
                value: Double(draftBrush.effectivePaintJitterAmount),
                range: 0...1,
                valueText: percentText
            ) { brush, value in
                if brush.compoundBrush.enabled {
                    brush.compoundBrush.globalPaintJitterAmount = Float(value)
                } else {
                    brush.paintJitterAmount = Float(value)
                }
                if value <= 0.001 { brush.oilPaint.isEnabled = false }
            }

            Divider().overlay(Color.white.opacity(0.07))

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("仿真油画笔")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(oilPaintIsAvailable ? 0.86 : 0.42))
                    Text(oilPaintIsAvailable ? "保留笔头中的旧颜色" : "先提高杂色后才能启用")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { draftBrush.oilPaint.isEnabled && oilPaintIsAvailable },
                        set: { enabled in
                            performEdit { $0.oilPaint.isEnabled = enabled && oilPaintIsAvailable }
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!oilPaintIsAvailable)
            }

            if draftBrush.oilPaint.isEnabled && oilPaintIsAvailable {
                editorSlider(
                    title: "新色装载",
                    value: Double(draftBrush.oilPaint.newColorLoad),
                    range: 0...1,
                    valueText: percentText
                ) { $0.oilPaint.newColorLoad = Float($1) }

                editorSlider(
                    title: "明度跟随",
                    value: Double(draftBrush.oilPaint.lightnessFollow),
                    range: 0...1,
                    valueText: percentText
                ) { $0.oilPaint.lightnessFollow = Float($1) }
            }
        }
    }

    private var strokeBuildSection: some View {
        editorPanel(title: "笔触叠加", detail: "这项设置会随画笔一起保存，直接决定重复描画时如何累积颜色") {
            Picker(
                "叠加方式",
                selection: Binding(
                    get: { draftBrush.buildMode },
                    set: { mode in performEdit { $0.buildMode = mode } }
                )
            ) {
                Text("自然叠加").tag(BrushBuildMode.buildUp)
                Text("不透明度封顶").tag(BrushBuildMode.opacityCap)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)

            Text(
                draftBrush.buildMode == .buildUp
                    ? "适合大多数画笔：重复经过同一区域时自然加深。"
                    : "特殊模式：单次笔触内部限制在目标不透明度，不适合作为普通默认值。"
            )
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.52))
            .fixedSize(horizontal: false, vertical: true)

            if draftBrush.buildMode == .buildUp {
                editorSlider(
                    title: "叠加补偿",
                    value: Double(draftBrush.buildUpOpacityCompensationAmount),
                    range: 0...1,
                    valueText: percentText
                ) { $0.buildUpOpacityCompensationAmount = Float($1) }
            }
        }
    }

    private var quickStartSection: some View {
        editorPanel(title: "快速起点", detail: "先选接近的质感，再微调；不会改变颜色和普通画笔参数") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 8)], spacing: 8) {
                ForEach(CompoundBrushRecipe.allCases) { recipe in
                    Button {
                        replaceDraft(recipe.applying(to: draftBrush))
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(recipe.displayName)
                                .font(.system(size: 11, weight: .bold))
                            Text(recipe.detail)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.48))
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                        .padding(9)
                        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var combinationSection: some View {
        editorPanel(title: "组合方式", detail: "A、B 都能真实落像素；两者最终限制在独立的笔触范围内") {
            if draftBrush.compoundBrush.mode == .overlay || draftBrush.compoundBrush.mode == .intersect {
                HStack(spacing: 8) {
                    Label("这是旧版特殊模式，数据仍保留。选择下方模式后才会转换。", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                    Spacer()
                }
                .padding(8)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            }

            HStack(spacing: 8) {
                modeButton(.textureBlend, title: "压力双笔尖", detail: "轻压显示 B，重压显示 A，中压同时出现")
                modeButton(.subtract, title: "反向镂空", detail: "B 的空白成为笔触内部质感")
            }

            modeButton(
                .maskedOverlay,
                title: "真实遮罩",
                detail: "A 与 B 按各自间距独立铺设，再用 B 调制 A 的透明度"
            )

            if draftBrush.compoundBrush.mode == .maskedOverlay {
                Label("此模式保留 A 的真实颗粒；B 的透明压感直接控制遮罩，不使用 A/B 强度插值。", systemImage: "square.3.layers.3d")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.46))
            } else {
                editorSlider(
                    title: "纹理笔尖强度",
                    value: Double(draftBrush.compoundBrush.displayedTextureStrength),
                    range: 0...1,
                    valueText: percentText
                ) { brush, value in
                    brush.compoundBrush.setUniformTextureStrength(Float(value))
                }

                if draftBrush.compoundBrush.mode == .textureBlend {
                    HStack(spacing: 8) {
                        Label("当前 A/B 比例由压力曲线控制；此滑块只调整 B 的总体强度。", systemImage: "waveform.path.ecg")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.46))
                        Spacer(minLength: 6)
                        Button("恢复轻 B / 重 A") {
                            performEdit { $0.compoundBrush.restoreLightTextureHeavyPrimaryMix() }
                        }
                        .buttonStyle(CompoundEditorButtonStyle(isProminent: false))
                    }
                } else if draftBrush.compoundBrush.hasVariableTextureStrength {
                    Label("当前 A/B 比例随压力变化。", systemImage: "waveform.path.ecg")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.46))
                }
            }
        }
    }

    private var tipSection: some View {
        editorPanel(
            title: draftBrush.compoundBrush.enabled ? "范围与两个笔尖" : "主笔尖",
            detail: draftBrush.compoundBrush.enabled
                ? "范围只决定笔触外形；A、B 独立盖印并按压力混合"
                : "主笔尖决定普通笔刷的外形"
        ) {
            if draftBrush.compoundBrush.enabled {
                HStack(alignment: .top, spacing: 8) {
                    tipCard(
                        title: "笔触范围",
                        summary: rangeTipSummary,
                        image: rangePreviewImage,
                        target: .range,
                        selectedShape: draftBrush.tipShape
                    ) { shape in
                        performEdit { setRangeTipShape(shape, brush: &$0) }
                    }

                    tipCard(
                        title: "笔尖 A · 重压",
                        summary: primaryTipSummary,
                        image: primaryPreviewImage,
                        target: .primary,
                        selectedShape: draftBrush.resolvedCompoundPrimaryTip.tipShape
                    ) { shape in
                        performEdit { setCompoundTipShape(shape, target: .primary, brush: &$0) }
                    }

                    tipCard(
                        title: "笔尖 B · 轻压",
                        summary: secondaryTipSummary,
                        image: secondaryPreviewImage,
                        target: .secondary,
                        selectedShape: draftBrush.compoundBrush.secondary.tipShape
                    ) { shape in
                        performEdit { setCompoundTipShape(shape, target: .secondary, brush: &$0) }
                    }
                }
            } else {
                tipCard(
                    title: "主笔尖",
                    summary: rangeTipSummary,
                    image: rangePreviewImage,
                    target: .range,
                    selectedShape: draftBrush.tipShape
                ) { shape in
                    performEdit { setRangeTipShape(shape, brush: &$0) }
                }
            }
        }
    }

    private var textureBehaviorSection: some View {
        editorPanel(title: "A / B 独立属性", detail: "两个笔尖各自盖印，不共享间距、尺寸、散布或旋转") {
            VStack(alignment: .leading, spacing: 10) {
                Text("笔尖 A · 重压主体")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.9))
                compoundTipControls(.primary)
            }

            Divider().overlay(Color.white.opacity(0.07))

            VStack(alignment: .leading, spacing: 10) {
                Text("笔尖 B · 轻压肌理")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.9))
                compoundTipControls(.secondary)
            }
        }
    }

    private var pressureDistributionSection: some View {
        editorPanel(
            title: "压力分配器",
            detail: "直接规定轻、中、重压力时 A 与 B 各占多少；三个点和下方滑块都能拖动"
        ) {
            HStack(spacing: 7) {
                ForEach(CompoundTexturePressurePreset.allCases) { preset in
                    Button(preset.displayName) {
                        performEdit { $0.compoundBrush.applyTexturePressurePreset(preset) }
                    }
                    .buttonStyle(CompoundEditorButtonStyle(isProminent: false))
                }
            }

            CompoundTextureStrengthCurveEditor(
                mix: draftBrush.compoundBrush.pressureMix,
                onChange: { mix in previewEdit { $0.compoundBrush.pressureMix = mix } },
                onEditingChanged: handleInteractiveEditing
            )
            .frame(height: 132)

            pressureMixSlider(
                title: "轻压力",
                primaryWeight: draftBrush.compoundBrush.pressureMix.primaryAtLowPressure
            ) { $0.compoundBrush.pressureMix.primaryAtLowPressure = Float($1) }
            pressureMixSlider(
                title: "中压力",
                primaryWeight: draftBrush.compoundBrush.pressureMix.primaryAtMidPressure
            ) { $0.compoundBrush.pressureMix.primaryAtMidPressure = Float($1) }
            pressureMixSlider(
                title: "重压力",
                primaryWeight: draftBrush.compoundBrush.pressureMix.primaryAtHighPressure
            ) { $0.compoundBrush.pressureMix.primaryAtHighPressure = Float($1) }
        }
    }

    private func compoundTipControls(_ target: TipLibraryTarget) -> some View {
        let tip = target == .primary
            ? draftBrush.resolvedCompoundPrimaryTip
            : draftBrush.compoundBrush.secondary
        return VStack(alignment: .leading, spacing: 8) {
            editorSlider(
                title: "相对范围尺寸",
                value: Double(tip.relativeSizeRatio),
                range: 0.05...4,
                valueText: { String(format: "%.2fx", $0) }
            ) { brush, value in
                updateCompoundTip(target, brush: &brush) {
                    $0.sizeMode = .relativeToPrimary
                    $0.relativeSizeRatio = Float(value)
                }
            }

            editorSlider(
                title: "间距",
                value: Double(tip.spacingPercent),
                range: 1...1_000,
                scale: .logarithmic,
                valueText: { "\(Int($0.rounded()))%" }
            ) { brush, value in
                updateCompoundTip(target, brush: &brush) { $0.spacingPercent = Float(value) }
            }

            editorSlider(
                title: "笔尖不透明度",
                value: Double(tip.opacity),
                range: 0...1,
                valueText: percentText
            ) { brush, value in
                updateCompoundTip(target, brush: &brush) { $0.opacity = Float(value) }
            }

            editorSlider(
                title: "位置散布",
                value: Double(tip.scatterAmount),
                range: 0...2,
                valueText: { "\(Int(($0 * 100).rounded()))%" }
            ) { brush, value in
                updateCompoundTip(target, brush: &brush) { $0.scatterAmount = Float(value) }
            }

            editorSlider(
                title: "尺寸随机",
                value: Double(tip.sizeJitterAmount),
                range: 0...1,
                valueText: percentText
            ) { brush, value in
                updateCompoundTip(target, brush: &brush) { $0.sizeJitterAmount = Float(value) }
            }

            editorSlider(
                title: "基础角度",
                value: Double(tip.angleDegrees),
                range: -180...180,
                valueText: { "\(Int($0.rounded()))°" }
            ) { brush, value in
                updateCompoundTip(target, brush: &brush) { $0.angleDegrees = Float(value) }
            }

            editorSlider(
                title: "角度随机",
                value: Double(tip.angleJitterAmount),
                range: 0...1,
                valueText: { "\(Int(($0 * 180).rounded()))°" }
            ) { brush, value in
                updateCompoundTip(target, brush: &brush) { $0.angleJitterAmount = Float(value) }
            }

            editorSlider(
                title: "尺寸压感",
                value: Double(tip.pressureSizeAmount),
                range: 0...1,
                valueText: percentText
            ) { brush, value in
                updateCompoundTip(target, brush: &brush) { $0.pressureSizeAmount = Float(value) }
            }

            HStack(spacing: 10) {
                Text("跟随笔迹方向")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.82))
                    .frame(width: 92, alignment: .leading)
                Toggle(
                    "",
                    isOn: Binding(
                        get: { tip.followsStrokeDirection },
                        set: { follows in
                            performEdit { brush in
                                updateCompoundTip(target, brush: &brush) { $0.followsStrokeDirection = follows }
                            }
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                Spacer()
            }
        }
    }

    private func updateCompoundTip(
        _ target: TipLibraryTarget,
        brush: inout BrushSettings,
        edit: (inout CompoundSecondaryTipSettings) -> Void
    ) {
        brush.materializeCompoundPrimaryTipIfNeeded()
        switch target {
        case .range:
            return
        case .primary:
            guard var tip = brush.compoundBrush.primary else { return }
            edit(&tip)
            brush.compoundBrush.primary = tip
        case .secondary:
            edit(&brush.compoundBrush.secondary)
        }
    }

    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $showsAdvanced) {
            VStack(alignment: .leading, spacing: 13) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("压力响应")
                        .font(.system(size: 11, weight: .bold))

                    HStack(spacing: 8) {
                        curveEditorButton(title: "尺寸曲线", systemImage: "waveform.path.ecg") {
                            showsSizeCurveEditor.toggle()
                        }
                        .popover(isPresented: $showsSizeCurveEditor, arrowEdge: .bottom) {
                            pressureCurvePopover(kind: .size)
                        }

                        curveEditorButton(title: "透明曲线", systemImage: "drop") {
                            showsOpacityCurveEditor.toggle()
                        }
                        .popover(isPresented: $showsOpacityCurveEditor, arrowEdge: .bottom) {
                            pressureCurvePopover(kind: .opacity)
                        }
                    }

                    if draftBrush.compoundBrush.enabled {
                        editorSlider(
                            title: "范围尺寸压感",
                            value: Double(draftBrush.pressureSizeAmount),
                            range: 0...1,
                            valueText: percentText
                        ) { $0.pressureSizeAmount = Float($1) }

                        editorSlider(
                            title: "范围透明响应",
                            value: Double(draftBrush.pressureOpacityAmount),
                            range: 0...1,
                            valueText: percentText
                        ) { $0.pressureOpacityAmount = Float($1) }
                    }

                    editorSlider(
                        title: "最小尺寸",
                        value: Double(draftBrush.sizeLowerBound),
                        range: 0...1,
                        valueText: percentText
                    ) { $0.sizeLowerBound = Float($1) }

                    editorSlider(
                        title: "压感灵敏度",
                        value: Double(draftBrush.pressureSensitivity),
                        range: 0.25...2,
                        valueText: { String(format: "%.2fx", $0) }
                    ) { $0.pressureSensitivity = Float($1) }
                }

                Divider().overlay(Color.white.opacity(0.07))

                VStack(alignment: .leading, spacing: 8) {
                    Text("笔尖排布与随机")
                        .font(.system(size: 11, weight: .bold))

                    editorSlider(
                        title: draftBrush.compoundBrush.enabled ? "范围位置散布" : "位置散布",
                        value: Double(draftBrush.scatterAmount),
                        range: 0...5,
                        valueText: { "\(Int(($0 * 50).rounded()))%" }
                    ) { $0.scatterAmount = Float($1) }

                    editorSlider(
                        title: "抖动",
                        value: Double(draftBrush.jitterAmount),
                        range: 0...1,
                        valueText: percentText
                    ) { $0.jitterAmount = Float($1) }

                    if draftBrush.tipShape.hasVisibleRotation {
                        editorSlider(
                            title: "笔尖角度",
                            value: signedPrimaryRotation,
                            range: -180...180,
                            valueText: { "\(Int($0.rounded()))°" }
                        ) { brush, value in
                            var normalized = Float(value).truncatingRemainder(dividingBy: 360)
                            if normalized < 0 { normalized += 360 }
                            brush.stampRotationDegrees = normalized
                        }

                        HStack(spacing: 10) {
                            Text("跟随笔迹方向")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.82))
                                .frame(width: 92, alignment: .leading)
                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { draftBrush.followsStrokeDirection },
                                    set: { follows in performEdit { $0.followsStrokeDirection = follows } }
                                )
                            )
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            Spacer()
                        }

                        editorSlider(
                            title: "角度随机",
                            value: Double(draftBrush.angleJitterAmount),
                            range: 0...1,
                            valueText: { "\(Int(($0 * 180).rounded()))°" }
                        ) { $0.angleJitterAmount = Float($1) }
                    }

                    editorSlider(
                        title: "颜色随机",
                        value: Double(draftBrush.colorJitterAmount),
                        range: 0...1,
                        valueText: percentText
                    ) { $0.colorJitterAmount = Float($1) }
                }

            }
            .padding(.top, 12)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("更多设置")
                    .font(.system(size: 12, weight: .bold))
                Text("尺寸与透明曲线、排布随机和角度")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.46))
            }
        }
        .padding(13)
        .background(panelBackground)
    }

    @ViewBuilder
    private var diagnosticsSection: some View {
        let diagnostics = CompoundBrushDiagnostics.evaluate(draftBrush)
        if diagnostics.isEmpty == false {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(diagnostics.prefix(3)) { diagnostic in
                    Label(
                        diagnostic.message,
                        systemImage: diagnostic.severity == .warning
                            ? "exclamationmark.triangle.fill"
                            : "info.circle.fill"
                    )
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(diagnostic.severity == .warning ? Color.orange : Color.white.opacity(0.58))
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Button {
                replaceDraft(openingBrush)
            } label: {
                Label("恢复打开状态", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(CompoundEditorButtonStyle(isProminent: false))
            .disabled(draftBrush == openingBrush)

            Spacer()

            Button {
                isSaveSheetPresented = true
            } label: {
                Label("另存为新笔刷…", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(CompoundEditorButtonStyle(isProminent: false))

            Button("取消", action: onClose)
                .buttonStyle(CompoundEditorButtonStyle(isProminent: false))

            Button("应用到当前画笔") {
                applyDraftAndClose()
            }
            .buttonStyle(CompoundEditorButtonStyle(isProminent: true))
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private func editorPanel<Content: View>(
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .bold))
                Text(detail)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.46))
            }
            content()
        }
        .padding(13)
        .background(panelBackground)
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.white.opacity(0.035))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }

    private func modeButton(_ mode: CompoundBrushMode, title: String, detail: String) -> some View {
        let isSelected = draftBrush.compoundBrush.mode == mode
        return Button {
            performEdit { brush in
                let previousMode = brush.compoundBrush.mode
                brush.compoundBrush.mode = mode
                if mode == .textureBlend,
                   previousMode != .textureBlend,
                   brush.compoundBrush.pressureMix.isUniform {
                    brush.compoundBrush.restoreLightTextureHeavyPrimaryMix()
                }
            }
        } label: {
            HStack(spacing: 9) {
                CompoundModeGlyph(mode: mode)
                    .frame(width: 48, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 11, weight: .bold))
                    Text(detail)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.46))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(9)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.white.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.white.opacity(0.07), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func tipCard(
        title: String,
        summary: String,
        image: CGImage?,
        target: TipLibraryTarget,
        selectedShape: BrushTipShape,
        onShape: @escaping (BrushTipShape) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
            ZStack {
                Color.black.opacity(0.3)
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .padding(8)
                }
            }
            .frame(height: 82)
            .clipShape(RoundedRectangle(cornerRadius: 7))

            Text(summary)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.56))
                .lineLimit(1)

            HStack(spacing: 6) {
                Menu {
                    ForEach(BrushTipShape.allCases, id: \.self) { shape in
                        Button(shape.displayName) { onShape(shape) }
                    }
                } label: {
                    Label(selectedShape.displayName, systemImage: "circle.grid.cross")
                        .frame(maxWidth: .infinity)
                }
                .menuStyle(.borderlessButton)

                Button {
                    prepareTipLibrary(target)
                } label: {
                    Image(systemName: "photo.on.rectangle")
                        .frame(width: 25, height: 23)
                }
                .buttonStyle(.plain)
                .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 6))
                .buttonTooltip("从素材库选择")
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private func editorSlider(
        title: String,
        value: Double,
        range: ClosedRange<Double>,
        scale: CompoundEditorSliderScale = .linear,
        valueText: @escaping (Double) -> String,
        update: @escaping (inout BrushSettings, Double) -> Void
    ) -> some View {
        CompoundEditorSlider(
            title: title,
            value: value,
            range: range,
            scale: scale,
            valueText: valueText,
            onPreview: { value in previewEdit { update(&$0, value) } },
            onCommit: { value in previewEdit { update(&$0, value) } },
            onEditingChanged: handleInteractiveEditing
        )
    }

    private func pressureMixSlider(
        title: String,
        primaryWeight: Float,
        update: @escaping (inout BrushSettings, Double) -> Void
    ) -> some View {
        editorSlider(
            title: title,
            value: Double(primaryWeight),
            range: 0...1,
            valueText: { value in
                let a = Int((value * 100).rounded())
                return "A \(a)% · B \(100 - a)%"
            },
            update: update
        )
    }

    private func curveEditorButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.86))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(CompoundEditorButtonStyle(isProminent: false))
    }

    private func pressureCurvePopover(kind: PressureCurveKind) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                ForEach(PressureCurvePreset.allCases, id: \.self) { preset in
                    Button(preset.displayName) {
                        performEdit { brush in
                            switch kind {
                            case .size:
                                brush.setSizePressureCurveState(preset.sizeCurveState)
                            case .opacity:
                                brush.setOpacityPressureCurveState(preset.opacityCurveState)
                            case .secondaryOpacity:
                                brush.compoundBrush.secondary.setOpacityPressureCurveState(
                                    preset.opacityCurveState
                                )
                            }
                        }
                    }
                    .buttonStyle(CompoundEditorButtonStyle(isProminent: false))
                }

                Spacer()

                Button("重置") {
                    performEdit { brush in
                        switch kind {
                        case .size:
                            brush.setSizePressureCurveState(BrushSettings.stageOneDefault.resolvedSizePressureCurveState)
                        case .opacity:
                            brush.setOpacityPressureCurveState(BrushSettings.stageOneDefault.resolvedOpacityPressureCurveState)
                        case .secondaryOpacity:
                            brush.compoundBrush.secondary.setOpacityPressureCurveState(.identity)
                        }
                    }
                }
                .buttonStyle(CompoundEditorButtonStyle(isProminent: false))
            }

            CurveEditorView(
                state: pressureCurveState(for: kind),
                isEnabled: true,
                appearance: .dark,
                allowsEndpointMovement: true,
                allowsPointInsertion: true,
                allowsPointRemoval: true
            ) { nextState in
                previewEdit { brush in
                    switch kind {
                    case .size:
                        brush.setSizePressureCurveState(nextState)
                    case .opacity:
                        brush.setOpacityPressureCurveState(nextState)
                    case .secondaryOpacity:
                        brush.compoundBrush.secondary.setOpacityPressureCurveState(nextState)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 330, height: 270)
        .background(Color(red: 0.10, green: 0.10, blue: 0.11))
        .preferredColorScheme(.dark)
        .onExitCommand {
            dismissPressureCurvePopover(kind)
        }
    }

    private func dismissPressureCurvePopover(_ kind: PressureCurveKind) {
        switch kind {
        case .size:
            showsSizeCurveEditor = false
        case .opacity:
            showsOpacityCurveEditor = false
        case .secondaryOpacity:
            showsSecondaryOpacityCurveEditor = false
        }
    }

    private func pressureCurveState(for kind: PressureCurveKind) -> CurveChannelState {
        switch kind {
        case .size:
            return draftBrush.resolvedSizePressureCurveState
        case .opacity:
            return draftBrush.resolvedOpacityPressureCurveState
        case .secondaryOpacity:
            return draftBrush.compoundBrush.secondary.resolvedOpacityPressureCurveState
        }
    }

    private var orientationBinding: Binding<CompoundTextureOrientation> {
        Binding(
            get: { draftBrush.compoundBrush.textureOrientation },
            set: { orientation in
                performEdit { $0.compoundBrush.setTextureOrientation(orientation) }
            }
        )
    }

    private var textureDensity: Double {
        let spacing = min(max(Double(draftBrush.compoundBrush.secondary.spacingPercent), 4), 140)
        return 1 - ((spacing - 4) / 136)
    }

    private var displayedPressureSizeAmount: Float {
        draftBrush.compoundBrush.enabled
            ? draftBrush.compoundBrush.globalPressureSizeAmount
            : draftBrush.pressureSizeAmount
    }

    private var displayedPressureOpacityAmount: Float {
        draftBrush.compoundBrush.enabled
            ? draftBrush.compoundBrush.globalPressureOpacityAmount
            : draftBrush.pressureOpacityAmount
    }

    private var oilPaintIsAvailable: Bool {
        draftBrush.effectivePaintJitterAmount > 0.001
    }

    private var signedPrimaryRotation: Double {
        let rotation = Double(draftBrush.stampRotationDegrees)
        return rotation > 180 ? rotation - 360 : rotation
    }

    private var drawingPadBrush: BrushSettings {
        switch previewChannel {
        case .result:
            var result = draftBrush
            if result.compoundBrush.enabled {
                result.compoundBrush.mode = result.compoundBrush.mode.editorEquivalent
            }
            return result
        case .primary:
            return compoundTipPreviewBrush(
                from: draftBrush,
                tip: draftBrush.resolvedCompoundPrimaryTip
            )
        case .secondary:
            return compoundTipPreviewBrush(
                from: draftBrush,
                tip: draftBrush.compoundBrush.secondary
            )
        }
    }

    private var rangeTipSummary: String {
        if draftBrush.tipShape == .customRound {
            switch draftBrush.customTipSourceSemantic {
            case .importedImage: return draftBrush.customTipImportedSourceInfo?.sourceLabel ?? "导入图像"
            case .customMask: return "自定义绘制笔尖"
            case .procedural: return "自定义圆形"
            }
        }
        return draftBrush.tipShape.displayName
    }

    private var primaryTipSummary: String {
        compoundTipSummary(draftBrush.resolvedCompoundPrimaryTip, customLabel: "自定义主笔尖")
    }

    private var secondaryTipSummary: String {
        compoundTipSummary(draftBrush.compoundBrush.secondary, customLabel: "自定义纹理笔尖")
    }

    private func compoundTipSummary(
        _ tip: CompoundSecondaryTipSettings,
        customLabel: String
    ) -> String {
        if tip.tipShape == .customRound {
            switch tip.sourceSemantic {
            case .importedImage: return tip.importedSourceInfo?.sourceLabel ?? "导入图像"
            case .customMask: return customLabel
            case .procedural: return "自定义圆形"
            }
        }
        return tip.tipShape.displayName
    }

    private func setRangeTipShape(_ shape: BrushTipShape, brush: inout BrushSettings) {
        brush.tipShape = shape
        brush.customTipSourceSemantic = .procedural
        brush.customTipAssetID = nil
        brush.customTipImportedSourceInfo = nil
        brush.customTipMaskData = nil
        brush.customTipEnvelopeMaskData = nil
    }

    private func setCompoundTipShape(
        _ shape: BrushTipShape,
        target: TipLibraryTarget,
        brush: inout BrushSettings
    ) {
        brush.materializeCompoundPrimaryTipIfNeeded()
        switch target {
        case .range:
            setRangeTipShape(shape, brush: &brush)
        case .primary:
            brush.compoundBrush.primary?.tipShape = shape
            brush.compoundBrush.primary?.sourceSemantic = .procedural
            brush.compoundBrush.primary?.tipAssetID = nil
            brush.compoundBrush.primary?.importedSourceInfo = nil
            brush.compoundBrush.primary?.customTipMaskData = nil
        case .secondary:
            brush.compoundBrush.secondary.tipShape = shape
            brush.compoundBrush.secondary.sourceSemantic = .procedural
            brush.compoundBrush.secondary.tipAssetID = nil
            brush.compoundBrush.secondary.importedSourceInfo = nil
            brush.compoundBrush.secondary.customTipMaskData = nil
        }
    }

    private func pressurePreviewCell(image: CGImage?, label: String) -> some View {
        VStack(spacing: 3) {
            ZStack {
                Color.black.opacity(0.32)
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .padding(4)
                }
            }
            .frame(height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(label)
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
    }

    private func percentText(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func handleInteractiveEditing(_ isEditing: Bool) {
        if isEditing {
            if interactiveAnchor == nil { interactiveAnchor = draftBrush }
        } else {
            finishInteractiveEditing()
        }
    }

    private func previewEdit(_ edit: (inout BrushSettings) -> Void) {
        var updated = draftBrush
        edit(&updated)
        draftBrush = updated
    }

    private func performEdit(_ edit: (inout BrushSettings) -> Void) {
        finishInteractiveEditing()
        var updated = draftBrush
        edit(&updated)
        replaceDraft(updated)
    }

    private func replaceDraft(_ updated: BrushSettings) {
        guard updated != draftBrush else { return }
        undoStack.append(draftBrush)
        trimHistory(&undoStack)
        redoStack.removeAll(keepingCapacity: true)
        draftBrush = updated
    }

    private func finishInteractiveEditing() {
        guard let anchor = interactiveAnchor else { return }
        interactiveAnchor = nil
        guard anchor != draftBrush else { return }
        undoStack.append(anchor)
        trimHistory(&undoStack)
        redoStack.removeAll(keepingCapacity: true)
    }

    private func undo() {
        finishInteractiveEditing()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(draftBrush)
        draftBrush = previous
    }

    private func redo() {
        finishInteractiveEditing()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(draftBrush)
        draftBrush = next
    }

    private func trimHistory(_ stack: inout [BrushSettings]) {
        if stack.count > 60 { stack.removeFirst(stack.count - 60) }
    }

    private func applyDraftAndClose() {
        finishInteractiveEditing()
        viewModel.restoreCompoundBrushEditingSnapshot(draftBrush)
        openingBrush = draftBrush
        onClose()
    }

    private func saveNamedPreset(
        name: String,
        colorTag: BrushColorTag?,
        replacingPresetID: String?,
        allowsDuplicate: Bool
    ) {
        _ = viewModel.saveNamedBrushPreset(
            brush: draftBrush,
            name: name,
            colorTag: colorTag,
            replacingPresetID: replacingPresetID,
            allowsDuplicate: allowsDuplicate
        )
        isSaveSheetPresented = false
        applyDraftAndClose()
    }

    private func randomizePreviewSeed() {
        previewSeed = previewSeed &* 1_664_525 &+ 1_013_904_223
        if previewSeed == 0 { previewSeed = 1 }
    }

    private func schedulePreviews(immediate: Bool = false) {
        previewTask?.cancel()
        previewGeneration &+= 1
        let generation = previewGeneration
        var brush = draftBrush
        if brush.compoundBrush.enabled {
            brush.compoundBrush.mode = brush.compoundBrush.mode.editorEquivalent
        }
        let primary = compoundTipPreviewBrush(
            from: brush,
            tip: brush.resolvedCompoundPrimaryTip
        )
        let secondary = compoundTipPreviewBrush(
            from: brush,
            tip: brush.compoundBrush.secondary
        )
        let seed = previewSeed

        previewTask = Task { @MainActor in
            if immediate == false { try? await Task.sleep(for: .milliseconds(34)) }
            guard Task.isCancelled == false else { return }
            let input = CompoundPreviewInput(range: brush, primary: primary, secondary: secondary)
            let result = await Task.detached(priority: .userInitiated) { [input] in
                CompoundPreviewImages(
                    range: StageOneBrushPreviewRasterizer.stampImage(for: input.range, resolution: 72),
                    primary: StageOneBrushPreviewRasterizer.stampImage(for: input.primary, resolution: 72),
                    secondary: StageOneBrushPreviewRasterizer.stampImage(for: input.secondary, resolution: 72),
                    light: StageOneBrushPreviewRasterizer.compoundStrokePreviewImage(
                        for: input.range, resolution: 72, width: 220, pressure: 0.2, paintVariationSeed: seed
                    ),
                    medium: StageOneBrushPreviewRasterizer.compoundStrokePreviewImage(
                        for: input.range, resolution: 72, width: 220, pressure: 0.5, paintVariationSeed: seed
                    ),
                    heavy: StageOneBrushPreviewRasterizer.compoundStrokePreviewImage(
                        for: input.range, resolution: 72, width: 220, pressure: 0.85, paintVariationSeed: seed
                    )
                )
            }.value
            guard Task.isCancelled == false, generation == previewGeneration else { return }
            rangePreviewImage = result.range
            primaryPreviewImage = result.primary
            secondaryPreviewImage = result.secondary
            lightPressurePreviewImage = result.light
            mediumPressurePreviewImage = result.medium
            heavyPressurePreviewImage = result.heavy
            previewTask = nil
        }
    }

    private func compoundTipPreviewBrush(
        from brush: BrushSettings,
        tip: CompoundSecondaryTipSettings
    ) -> BrushSettings {
        var preview = brush
        preview.compoundBrush.enabled = false
        preview.tipShape = tip.tipShape
        preview.customTipSourceSemantic = tip.sourceSemantic
        preview.customTipAssetID = tip.tipAssetID
        preview.customTipImportedSourceInfo = tip.importedSourceInfo
        preview.customTipMaskData = tip.customTipMaskData
        preview.customTipEnvelopeMaskData = tip.customTipMaskData
        preview.customTipSoftness = tip.softness
        preview.customTipRoundness = tip.roundness
        preview.customTipAngleDegrees = tip.angleDegrees
        preview.followsStrokeDirection = tip.followsStrokeDirection
        preview.size = tip.resolvedBaseSize(for: brush.size)
        preview.spacingPercent = tip.spacingPercent
        preview.opacity = tip.opacity
        preview.scatterAmount = tip.scatterAmount
        preview.sizeJitterAmount = tip.sizeJitterAmount
        preview.angleJitterAmount = tip.angleJitterAmount
        preview.pressureSizeAmount = tip.pressureSizeAmount
        preview.pressureOpacityAmount = tip.pressureOpacityAmount
        preview.sizeCurveLow = tip.sizeCurveLow
        preview.sizeCurveMid = tip.sizeCurveMid
        preview.sizeCurveHigh = tip.sizeCurveHigh
        preview.opacityCurveLow = tip.opacityCurveLow
        preview.opacityCurveMid = tip.opacityCurveMid
        preview.opacityCurveHigh = tip.opacityCurveHigh
        preview.opacityPressureCurve = tip.opacityPressureCurve
        return preview
    }

    private func prepareTipLibrary(_ target: TipLibraryTarget) {
        _ = viewModel.prepareTipImageLibraryForBrowser()
        switch target {
        case .range: rangePendingSelection = draftBrush.customTipAssetID
        case .primary: primaryPendingSelection = draftBrush.resolvedCompoundPrimaryTip.tipAssetID
        case .secondary: secondaryPendingSelection = draftBrush.compoundBrush.secondary.tipAssetID
        }
        tipLibraryTarget = target
    }

    private func pendingSelection(for target: TipLibraryTarget) -> BrushTipImageAssetID? {
        switch target {
        case .range: return rangePendingSelection
        case .primary: return primaryPendingSelection
        case .secondary: return secondaryPendingSelection
        }
    }

    private func setPendingSelection(_ selection: BrushTipImageAssetID?, for target: TipLibraryTarget) {
        switch target {
        case .range: rangePendingSelection = selection
        case .primary: primaryPendingSelection = selection
        case .secondary: secondaryPendingSelection = selection
        }
    }

    @ViewBuilder
    private func tipImageLibrarySheet(for target: TipLibraryTarget) -> some View {
        let items = viewModel.workspace.tipImageLibrary.items
        let selection = pendingSelection(for: target)
        let sheetSize = CompoundBrushTipLibraryLayout.size(fitting: editorViewportSize)

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(target.title).font(.system(size: 19, weight: .bold))
                    Text("选择一个素材作为\(target.detailName)")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.52))
                }
                Spacer()
                Button("导入") {
                    if let ids = viewModel.importTipImageLibraryItemsFromDisk(),
                       ids.count == 1,
                       let first = ids.first {
                        setPendingSelection(first, for: target)
                    }
                }
                Button("取消") { tipLibraryTarget = nil }
                Button("应用") {
                    applyPendingTip(for: target)
                    tipLibraryTarget = nil
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection == nil)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 180), spacing: 10)], spacing: 10) {
                        ForEach(items) { item in
                            Button {
                                setPendingSelection(item.id, for: target)
                            } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    ZStack {
                                        Color.black
                                        if let image = StageOneBrushPreviewRasterizer.importedAssetImage(
                                            from: item.maskData,
                                            resolution: Int(CompoundBrushTipLibraryLayout.thumbnailHeight)
                                        ) {
                                            Image(decorative: image, scale: 1)
                                                .resizable()
                                                .interpolation(.none)
                                                .scaledToFit()
                                                .padding(CompoundBrushTipLibraryLayout.thumbnailInset)
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                    .frame(height: CompoundBrushTipLibraryLayout.thumbnailHeight)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    Text(item.displayName)
                                        .font(.system(size: 11, weight: .semibold))
                                        .lineLimit(1)
                                    Text("\(item.sourceInfo.pixelWidth) × \(item.sourceInfo.pixelHeight)")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7)
                                        .stroke(selection == item.id ? Color.accentColor : Color.white.opacity(0.07), lineWidth: 2)
                                )
                            }
                            .buttonStyle(.plain)
                            .id(item.id)
                        }
                    }
                }
                .onAppear {
                    guard let firstItemID = items.first?.id else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo(firstItemID, anchor: .top)
                    }
                }
            }
        }
        .padding(18)
        .frame(width: sheetSize.width, height: sheetSize.height, alignment: .topLeading)
        .foregroundStyle(.white)
        .background(Color(red: 0.10, green: 0.10, blue: 0.11))
        .preferredColorScheme(.dark)
    }

    private func applyPendingTip(for target: TipLibraryTarget) {
        guard let selection = pendingSelection(for: target) else { return }
        let updated: BrushSettings?
        switch target {
        case .range:
            updated = viewModel.brushDraft(draftBrush, applyingPrimaryTipImageLibraryItem: selection)
        case .primary:
            updated = viewModel.brushDraft(draftBrush, applyingCompoundPrimaryTipImageLibraryItem: selection)
        case .secondary:
            updated = viewModel.brushDraft(draftBrush, applyingCompoundSecondaryTipImageLibraryItem: selection)
        }
        if var updated {
            if target != .range { updated.compoundBrush.enabled = true }
            replaceDraft(updated)
        }
    }
}

private struct CompoundPreviewInput: Sendable {
    let range: BrushSettings
    let primary: BrushSettings
    let secondary: BrushSettings
}

private struct CompoundPreviewImages: @unchecked Sendable {
    let range: CGImage?
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
                let x = bounds.minX + 6 + (CGFloat(index) * 8)
                let stripe = CGRect(x: x, y: bounds.minY + 5, width: 4, height: bounds.height - 10)
                context.fill(
                    Path(roundedRect: stripe, cornerRadius: 2),
                    with: .color(mode == .subtract ? .black.opacity(0.76) : .white.opacity(0.78))
                )
            }
        }
    }
}

private struct CompoundEditorButtonStyle: ButtonStyle {
    let isProminent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.72 : 0.92))
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isProminent ? Color.accentColor.opacity(0.82) : Color.white.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isProminent ? Color.accentColor : Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}

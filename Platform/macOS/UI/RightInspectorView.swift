import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let tipMaskResolution = 256

private struct DualTipPhaseZeroSliderRow: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let onCommit: (Double) -> Void
    let isEnabled: Bool
    let helperText: String?

    @State private var localValue: Double
    @State private var isEditing = false

    private let primaryTextColor = Color(red: 0.12, green: 0.12, blue: 0.13)
    private let secondaryTextColor = Color(red: 0.30, green: 0.30, blue: 0.32)

    init(
        title: String,
        valueText: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        onCommit: @escaping (Double) -> Void,
        isEnabled: Bool = true,
        helperText: String? = nil
    ) {
        self.title = title
        self.valueText = valueText
        self._value = value
        self.range = range
        self.onCommit = onCommit
        self.isEnabled = isEnabled
        self.helperText = helperText
        self._localValue = State(initialValue: value.wrappedValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(primaryTextColor)

                Spacer()

                Text(valueText)
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(secondaryTextColor)
            }

            Slider(
                value: $localValue,
                in: range,
                onEditingChanged: handleEditingChanged
            )
            .tint(.accentColor)
            .disabled(!isEnabled)

            if let helperText {
                Text(helperText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
        .opacity(isEnabled ? 1 : 0.68)
        .onChange(of: value) { _, newValue in
            if !isEditing {
                localValue = newValue
            }
        }
    }

    private func handleEditingChanged(_ editing: Bool) {
        isEditing = editing

        if editing {
            localValue = value
        } else if localValue != value {
            value = localValue
            onCommit(localValue)
        }
    }
}

private struct DualTipPreviewCell<Content: View>: View {
    let title: String
    let caption: String
    let content: Content

    private let primaryTextColor = Color(red: 0.12, green: 0.12, blue: 0.13)
    private let secondaryTextColor = Color(red: 0.32, green: 0.32, blue: 0.34)
    private let previewBackgroundColor = Color(red: 0.08, green: 0.08, blue: 0.09)

    init(
        title: String,
        caption: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.caption = caption
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(primaryTextColor)

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(previewBackgroundColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    )

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(8)
            }
            .frame(height: 84)

            Text(caption)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(secondaryTextColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct RightInspectorView: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    @State private var showsPressureCurveEditor = false
    @State private var showsPressureSizeCurveEditor = false
    @State private var showsDualTipPopover = false
    @State private var tipPaintMode: TipPaintMode = .round
    @State private var tipPaintSoftness: Double = 0.35
    @State private var tipPaintIntensity: Double = 1.0
    @State private var presetShapeIndex = 0
    @State private var sprayPatternIndex = 0
    @State private var draggedBrushPresetID: String?
    @State private var draggedLayerID: LayerID?
    @State private var editingLayerID: LayerID?
    @State private var editingLayerName = ""
    @State private var layerDropInsertionIndex: Int?
    @FocusState private var focusedLayerNameFieldID: LayerID?
    @State private var isTipImageDropTarget = false
    @State private var isColorPaletteDropTarget = false
    @State private var highlightsPrimaryTipEditor = false
    @State private var primaryTipEditorHighlightGeneration = 0
    @State private var showsSecondaryTipEditor = false
    @State private var secondaryTipPaintMode: TipPaintMode = .round
    @State private var secondaryTipPaintSoftness: Double = 0.35
    @State private var secondaryTipPaintIntensity: Double = 1.0
    @State private var secondaryTipUsesImportedPreviewFit = false

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 12) {
                        InspectorPanel(title: "创意图形生成器") {
                            generatorSection
                        }

                        .frame(maxHeight: .infinity, alignment: .top)

                        InspectorPanel(title: "颜色") {
                            ColorSectionView(
                                proxy: viewModel.colorPanelProxy,
                                viewModel: viewModel
                            )
                        }

                        InspectorPanel(title: "画笔库") {
                            brushLibrarySection
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                    VStack(spacing: 12) {
                        InspectorPanel(title: "笔尖形状设计") {
                            tipShapeSection
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(
                                    highlightsPrimaryTipEditor ? Color.accentColor.opacity(0.92) : Color.clear,
                                    lineWidth: 2
                                )
                        }
                        .shadow(
                            color: highlightsPrimaryTipEditor ? Color.accentColor.opacity(0.22) : .clear,
                            radius: 12
                        )

                        InspectorPanel(title: "画笔参数") {
                            brushSection
                        }

                        InspectorPanel(title: "图层") {
                            layersSection
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .frame(width: 560)
        .frame(maxHeight: .infinity)
        .background(Color(red: 0.12, green: 0.12, blue: 0.13))
        .sheet(isPresented: $showsSecondaryTipEditor) {
            secondaryTipEditorSheet
        }
    }

    private var generatorSection: some View {
        Spacer(minLength: 160)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var brushSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                inspectorButton("存为笔刷") {
                    viewModel.saveCurrentBrushPreset()
                }
            }

            // ⚡️ 优化：使用防抖滑块，拖动结束时才更新
            OptimizedCompactSlider(
                title: "间距",
                valueText: "\(Int(viewModel.workspace.toolSession.brush.spacingPercent))%",
                value: Binding(
                    get: { Double(viewModel.workspace.toolSession.brush.spacingPercent) },
                    set: { _ in }  // 通过 onCommit 处理
                ),
                range: 5...150,
                onCommit: { viewModel.setBrushSpacingPercent(Float($0)) }
            )

            OptimizedCompactSlider(
                title: "散布",
                valueText: String(format: "%.1fx", viewModel.workspace.toolSession.brush.scatterAmount),
                value: Binding(
                    get: { Double(viewModel.workspace.toolSession.brush.scatterAmount) },
                    set: { _ in }
                ),
                range: 0...5,
                onCommit: { viewModel.setBrushScatterAmount(Float($0)) }
            )

            OptimizedCompactSlider(
                title: "旋转",
                valueText: "\(Int(viewModel.workspace.toolSession.brush.stampRotationDegrees))°",
                value: Binding(
                    get: { Double(viewModel.workspace.toolSession.brush.stampRotationDegrees) },
                    set: { _ in }
                ),
                range: 0...360,
                onCommit: { viewModel.setBrushStampRotationDegrees(Float($0)) }
            )

            OptimizedCompactSlider(
                title: "抖动",
                valueText: "\(Int(viewModel.workspace.toolSession.brush.jitterAmount * 100))%",
                value: Binding(
                    get: { Double(viewModel.workspace.toolSession.brush.jitterAmount) },
                    set: { _ in }
                ),
                range: 0...1,
                onCommit: { viewModel.setBrushJitterAmount(Float($0)) }
            )

            OptimizedCompactSlider(
                title: "杂色",
                valueText: "\(Int(viewModel.workspace.toolSession.brush.colorJitterAmount * 100))%",
                value: Binding(
                    get: { Double(viewModel.workspace.toolSession.brush.colorJitterAmount) },
                    set: { _ in }
                ),
                range: 0...1,
                onCommit: { viewModel.setBrushColorJitterAmount(Float($0)) }
            )

            OptimizedCompactSlider(
                title: "压感",
                valueText: String(format: "%.1f", viewModel.workspace.toolSession.brush.pressureSensitivity),
                value: Binding(
                    get: { Double(viewModel.workspace.toolSession.brush.pressureSensitivity) },
                    set: { _ in }
                ),
                range: 0...2,
                onCommit: { viewModel.setPressureSensitivity(Float($0)) }
            )

            OptimizedCompactSlider(
                title: "尺寸下限",
                valueText: "\(Int(viewModel.workspace.toolSession.brush.sizeLowerBound * 100))%",
                value: Binding(
                    get: { Double(viewModel.workspace.toolSession.brush.sizeLowerBound) },
                    set: { _ in }
                ),
                range: 0...1,
                onCommit: { viewModel.setSizeLowerBound(Float($0)) }
            )

            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text("不透明度封顶")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.88))

                    Toggle(
                        "",
                        isOn: Binding(
                            get: { viewModel.workspace.toolSession.brush.buildMode == .opacityCap },
                            set: { viewModel.setBrushBuildMode($0 ? .opacityCap : .buildUp) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                }

                compactIconButton(systemImage: "waveform.path.ecg", tooltip: "尺寸压感曲线") {
                    showsPressureSizeCurveEditor.toggle()
                }
                .popover(isPresented: $showsPressureSizeCurveEditor, arrowEdge: .bottom) {
                    pressureSizeCurveEditor
                        .padding(14)
                        .frame(width: 280)
                        .background(Color(nsColor: .windowBackgroundColor))
                }

                compactIconButton(
                    systemImage: "location.north.line.fill",
                    tooltip: viewModel.workspace.toolSession.brush.followsStrokeDirection ? "关闭跟随笔迹方向" : "开启跟随笔迹方向",
                    isSelected: viewModel.workspace.toolSession.brush.followsStrokeDirection
                ) {
                    viewModel.setBrushFollowsStrokeDirection(!viewModel.workspace.toolSession.brush.followsStrokeDirection)
                }

                compactIconButton(systemImage: "drop", tooltip: "透明度压感曲线") {
                    showsPressureCurveEditor.toggle()
                }
                .popover(isPresented: $showsPressureCurveEditor, arrowEdge: .bottom) {
                    pressureCurveEditor
                        .padding(14)
                        .frame(width: 280)
                        .background(Color(nsColor: .windowBackgroundColor))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pressureSizeCurveEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("尺寸压感曲线")
                .font(.system(size: 13, weight: .bold))

            curvePresetRow(
                applyPreset: viewModel.applySizeCurvePreset,
                reset: viewModel.resetSizeCurveToDefault
            )

            PressureCurvePreview(
                low: Double(viewModel.workspace.toolSession.brush.sizeCurveLow),
                mid: Double(viewModel.workspace.toolSession.brush.sizeCurveMid),
                high: Double(viewModel.workspace.toolSession.brush.sizeCurveHigh)
            )
            .frame(height: 88)

            // ⚡️ 优化：使用防抖滑块
            OptimizedLabeledSlider(
                title: "轻压",
                valueText: "\(Int(viewModel.workspace.toolSession.brush.sizeCurveLow * 100))%",
                value: Binding(
                    get: { Double(viewModel.workspace.toolSession.brush.sizeCurveLow) },
                    set: { _ in }
                ),
                range: 0...0.85,
                onCommit: { viewModel.setSizeCurveLow(Float($0)) }
            )

            OptimizedLabeledSlider(
                title: "中压",
                valueText: "\(Int(viewModel.workspace.toolSession.brush.sizeCurveMid * 100))%",
                value: Binding(
                    get: { Double(viewModel.workspace.toolSession.brush.sizeCurveMid) },
                    set: { _ in }
                ),
                range: 0...0.95,
                onCommit: { viewModel.setSizeCurveMid(Float($0)) }
            )

            OptimizedLabeledSlider(
                title: "高压",
                valueText: "\(Int(viewModel.workspace.toolSession.brush.sizeCurveHigh * 100))%",
                value: Binding(
                    get: { Double(viewModel.workspace.toolSession.brush.sizeCurveHigh) },
                    set: { _ in }
                ),
                range: 0...1,
                onCommit: { viewModel.setSizeCurveHigh(Float($0)) }
            )

            Text("轻压控制最细起笔，中压控制中段增长，高压控制笔刷多快接近最大尺寸。")
                .font(.system(size: 11))
                .foregroundStyle(Color.secondary)
        }
    }

    private var pressureCurveEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("透明度压感曲线")
                .font(.system(size: 13, weight: .bold))

            curvePresetRow(
                applyPreset: viewModel.applyOpacityCurvePreset,
                reset: viewModel.resetOpacityCurveToDefault
            )

            PressureCurvePreview(
                low: Double(viewModel.workspace.toolSession.brush.opacityCurveLow),
                mid: Double(viewModel.workspace.toolSession.brush.opacityCurveMid),
                high: Double(viewModel.workspace.toolSession.brush.opacityCurveHigh)
            )
            .frame(height: 88)

            // ⚡️ 优化：使用防抖滑块
            OptimizedLabeledSlider(
                title: "轻压",
                valueText: "\(Int(viewModel.workspace.toolSession.brush.opacityCurveLow * 100))%",
                value: Binding(
                    get: { Double(viewModel.workspace.toolSession.brush.opacityCurveLow) },
                    set: { _ in }
                ),
                range: 0...0.85,
                onCommit: { viewModel.setOpacityCurveLow(Float($0)) }
            )

            OptimizedLabeledSlider(
                title: "中压",
                valueText: "\(Int(viewModel.workspace.toolSession.brush.opacityCurveMid * 100))%",
                value: Binding(
                    get: { Double(viewModel.workspace.toolSession.brush.opacityCurveMid) },
                    set: { _ in }
                ),
                range: 0...0.95,
                onCommit: { viewModel.setOpacityCurveMid(Float($0)) }
            )

            OptimizedLabeledSlider(
                title: "高压",
                valueText: "\(Int(viewModel.workspace.toolSession.brush.opacityCurveHigh * 100))%",
                value: Binding(
                    get: { Double(viewModel.workspace.toolSession.brush.opacityCurveHigh) },
                    set: { _ in }
                ),
                range: 0...1,
                onCommit: { viewModel.setOpacityCurveHigh(Float($0)) }
            )

            Text("轻压保持很淡的起笔，中压控制中段响应，高压控制多早进入更深颜色。")
                .font(.system(size: 11))
                .foregroundStyle(Color.secondary)
        }
    }

    private func curvePresetRow(
        applyPreset: @escaping (PressureCurvePreset) -> Void,
        reset: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("预设")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.secondary)

            HStack(spacing: 6) {
                ForEach(PressureCurvePreset.allCases, id: \.self) { preset in
                    Button(preset.displayName) {
                        applyPreset(preset)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Button("恢复默认") {
                reset()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var brushLibrarySection: some View {
        GeometryReader { geometry in
            let columnCount = 4
            let spacing = 8.0
            let outerInset = 12.0
            let usableWidth = max(0.0, geometry.size.width - outerInset * 2)
            let slotWidth = max(40.0, floor((usableWidth - spacing * Double(columnCount - 1)) / Double(columnCount)))
            let contentWidth = (slotWidth * Double(columnCount)) + (spacing * Double(columnCount - 1))
            let horizontalInset = max(0.0, floor((usableWidth - contentWidth) * 0.5)) + outerInset
            let totalSlotCount = max(
                48,
                (viewModel.workspace.brushLibrary.resolvedSlotMap().values.max() ?? -1) + 1
            )
            let selectedPreset = viewModel.workspace.brushLibrary.selectedPresetID.flatMap {
                viewModel.workspace.brushLibrary.preset(id: $0)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let selectedPreset {
                        Text(selectedPreset.name)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.9))
                            .lineLimit(1)
                    } else {
                        Text("当前未选中预设")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.45))
                    }

                    Spacer(minLength: 0)

                    Text("青色描边 = Dual Tip 示例")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(red: 0.42, green: 0.86, blue: 1.0))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color(red: 0.14, green: 0.24, blue: 0.31))
                        )
                }
                .padding(.horizontal, horizontalInset)

                ScrollView(.vertical, showsIndicators: true) {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(slotWidth), spacing: spacing), count: columnCount),
                        spacing: spacing
                    ) {
                        ForEach(0..<totalSlotCount, id: \.self) { slotIndex in
                            brushLibrarySlotCell(slotIndex: slotIndex)
                        }
                    }
                    .padding(.horizontal, horizontalInset)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contextMenu {
                Button("导出画笔库") {
                    viewModel.exportBrushLibrary()
                }
                Divider()
                Button("导入并替换") {
                    viewModel.importBrushLibraryReplacing()
                }
                Button("导入并追加") {
                    viewModel.importBrushLibraryAppending()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func brushLibrarySlotCell(slotIndex: Int) -> some View {
        let preset = viewModel.workspace.brushLibrary.preset(atSlot: slotIndex)

        if let preset {
            brushPresetCell(preset, slotIndex: slotIndex)
                .onDrag {
                    draggedBrushPresetID = preset.id
                    return NSItemProvider(object: preset.id as NSString)
                }
                .onDrop(of: [UTType.plainText.identifier], isTargeted: nil) { providers in
                    moveBrushPresetFromDrop(providers: providers, toSlot: slotIndex)
                }
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.03))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.05), lineWidth: 1)
                }
                .aspectRatio(1, contentMode: .fit)
                .overlay(alignment: .topLeading) {
                    shortcutSlotLabel(for: slotIndex)
                }
                .onDrop(of: [UTType.plainText.identifier], isTargeted: nil) { providers in
                    moveBrushPresetFromDrop(providers: providers, toSlot: slotIndex)
                }
        }
    }

    private var layersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let activeLayer = activeLayer {
                // ⚡️ 优化：图层透明度需要实时预览，使用专用组件
                OptimizedLabeledSlider(
                    title: "不透明度",
                    valueText: "\(Int(activeLayer.opacity * 100))%",
                    value: Binding(
                        get: { Double(activeLayer.opacity) },
                        set: { _ in }  // 通过 onCommit 处理
                    ),
                    range: 0...1,
                    onCommit: { newOpacity in
                        viewModel.setActiveLayerOpacity(Float(newOpacity))
                        viewModel.endActiveLayerOpacityChange()
                    }
                )
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    layerDropInsertionStrip(at: 0)

                    ForEach(Array(displayLayers.enumerated()), id: \.element.id) { index, layer in
                        layerRow(layer)
                        layerDropInsertionStrip(at: index + 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack(spacing: 8) {
                layerActionButton(systemImage: "plus.square", tooltip: "新建图层") {
                    viewModel.addLayer()
                }

                layerActionButton(systemImage: "doc.on.doc", tooltip: "复制图层") {
                    viewModel.duplicateActiveLayer()
                }

                layerActionButton(systemImage: "trash", tooltip: "删除图层") {
                    viewModel.removeActiveLayer()
                }

                Spacer(minLength: 0)

                layerActionButton(systemImage: "arrow.down.doc", tooltip: "向下合并") {
                    viewModel.mergeActiveLayerDown()
                }
                .disabled(!viewModel.canMergeDown)

                layerActionButton(systemImage: "square.stack.3d.down.right", tooltip: "合并可见图层") {
                    viewModel.mergeVisibleLayers()
                }
                .disabled(!viewModel.canMergeVisible)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var tipShapeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            tipDesignCanvas

            HStack(spacing: 8) {
                compactToolButton(
                    systemImage: "circle.fill",
                    tooltip: "圆形绘制",
                    isSelected: tipPaintMode == .round
                ) {
                    tipPaintMode = .round
                }

                compactToolButton(
                    systemImage: "eraser.fill",
                    tooltip: "擦除笔尖",
                    isSelected: tipPaintMode == .eraser
                ) {
                    tipPaintMode = .eraser
                }

                compactToolButton(
                    systemImage: "photo.badge.plus",
                    tooltip: "从图片导入笔尖",
                    isSelected: false
                ) {
                    viewModel.importBrushTipImageFromDisk()
                }

                compactTextActionButton(
                    title: "组合笔尖…",
                    tooltip: "打开组合笔尖参数"
                ) {
                    showsDualTipPopover.toggle()
                }
                .popover(isPresented: $showsDualTipPopover, arrowEdge: .bottom) {
                    dualTipEditor
                        .padding(14)
                        .frame(width: 320)
                        .background(Color(nsColor: .windowBackgroundColor))
                }
            }

            // ⚡️ 优化：笔尖绘制参数使用本地状态，不需要触发 ViewModel
            // 这些滑块不影响实际笔刷，只影响笔尖编辑器
            OptimizedCompactSlider(
                title: "柔边",
                valueText: "\(Int(tipPaintSoftness * 100))%",
                value: Binding(
                    get: { tipPaintSoftness },
                    set: { _ in }
                ),
                range: 0...1,
                onCommit: { tipPaintSoftness = $0 }
            )

            OptimizedCompactSlider(
                title: "灰度",
                valueText: "\(Int(tipPaintIntensity * 100))%",
                value: Binding(
                    get: { tipPaintIntensity },
                    set: { _ in }
                ),
                range: 0.1...1,
                onCommit: { tipPaintIntensity = $0 }
            )

            HStack(spacing: 8) {
                compactIconButton(systemImage: "square.on.circle", tooltip: "插入形状") {
                    insertNextPresetShape()
                }

                compactIconButton(systemImage: "aqi.medium", tooltip: "喷墨散点") {
                    insertNextSprayPattern()
                }
                compactIconButton(systemImage: "rotate.right", tooltip: "旋转笔尖") {
                    rotateCustomTip()
                }

                compactIconButton(systemImage: "arrow.left.and.right.square", tooltip: "左右翻转") {
                    flipCustomTipHorizontally()
                }

                compactIconButton(systemImage: "arrow.up.and.down.square", tooltip: "上下翻转") {
                    flipCustomTipVertically()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dualTipEditor: some View {
        let brush = viewModel.workspace.toolSession.brush
        let activeTool = viewModel.workspace.toolSession.activeTool
        let phaseOneRealDrawingSupported = brush.supportsPhaseOneDualTipRealDrawing(for: activeTool)
        let phaseTwoSubtractRealDrawingSupported = brush.supportsPhaseTwoDualTipSubtractRealDrawing(for: activeTool)
        let phaseTwoIntersectRealDrawingSupported = brush.supportsPhaseTwoDualTipIntersectRealDrawing(for: activeTool)
        let dualTipRealDrawingSupported =
            phaseOneRealDrawingSupported ||
            phaseTwoSubtractRealDrawingSupported ||
            phaseTwoIntersectRealDrawingSupported
        let primaryTextColor = Color(red: 0.12, green: 0.12, blue: 0.13)
        let secondaryTextColor = Color(red: 0.32, green: 0.32, blue: 0.34)
        let statusAccentColor = dualTipRealDrawingSupported
            ? Color(red: 0.15, green: 0.55, blue: 0.26)
            : Color.orange

        return VStack(alignment: .leading, spacing: 12) {
            Text("组合笔尖")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(primaryTextColor)

            VStack(alignment: .leading, spacing: 8) {
                Text(
                    phaseTwoIntersectRealDrawingSupported
                    ? "Phase 2 intersect 已接入真实绘制"
                    : (phaseTwoSubtractRealDrawingSupported
                    ? "Phase 2 subtract 已接入真实绘制"
                    : (phaseOneRealDrawingSupported ? "Phase 1 已接入最小真实绘制" : "当前为条件式真实接入"))
                )
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(statusAccentColor.opacity(0.92))

                Text(
                    phaseTwoIntersectRealDrawingSupported
                    ? "当前配置会影响真实绘制：工具为画笔/橡皮、主笔尖为圆形或自定义笔尖、次笔尖为圆形或自定义笔尖、组合模式为相交。次笔尖会只保留与主笔尖重叠的覆盖区域；强度越高，越接近纯交集。预览仍是示意，请以实际落笔为准。"
                    : (phaseTwoSubtractRealDrawingSupported
                    ? "当前配置会影响真实绘制：工具为画笔/橡皮、主笔尖为圆形或自定义笔尖、次笔尖为圆形或自定义笔尖、组合模式为减去。次笔尖会从主笔尖里挖掉一部分覆盖区域。预览仍是示意，请以实际落笔为准。"
                    : (phaseOneRealDrawingSupported
                        ? "当前配置会影响真实绘制：工具为画笔/橡皮、主笔尖为圆形或自定义笔尖、次笔尖为圆形或自定义笔尖、组合模式为调制。预览仍是示意，请以实际落笔为准。"
                        : "只有在工具为画笔/橡皮、主笔尖为圆形或自定义笔尖、次笔尖为圆形或自定义笔尖，且组合模式为调制、减去或相交时，组合笔尖才会影响真实绘制。其余情况当前只保存参数，不会改变画布。预览仍是示意。"))
                )
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(statusAccentColor.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(statusAccentColor.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(statusAccentColor.opacity(0.24), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 6) {
                Toggle(
                    "启用组合笔尖",
                    isOn: Binding(
                        get: { brush.dualTipEnabled },
                        set: { viewModel.setDualTipEnabled($0) }
                    )
                )
                .toggleStyle(.switch)
                .foregroundStyle(primaryTextColor)

                Text("启用后只有在“调制、减去或相交 + 圆形/自定义主笔尖 + 圆形/自定义次笔尖 + 画笔/橡皮”这组条件满足时，才会影响真实落笔。")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("主笔尖（真实绘制同源）")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(primaryTextColor)

                HStack(alignment: .top, spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.black.opacity(0.05))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
                            )

                        brushPreviewGlyph(for: brush, maxExtent: 48)
                            .padding(8)
                    }
                    .frame(width: 76, height: 76)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(dualTipPrimaryTipSummaryTitle(for: brush))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(primaryTextColor)

                        Text(dualTipPrimaryTipSummaryDetail(for: brush))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(secondaryTextColor)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("这里显示的始终是当前真实绘制主笔尖；不是第二套独立主笔尖状态。")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(primaryTextColor.opacity(0.84))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.black.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )

                Text("真正修改主笔尖，请使用上方“笔尖形状设计”区域。那里改的是同一个主笔尖，也就是实际绘制正在使用的主笔尖。")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    revealPrimaryTipEditor()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .bold))
                        Text("编辑主笔尖…")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.accentColor.opacity(0.10))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.accentColor.opacity(0.22), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                Text("点击后会关闭当前 popover，并高亮上方已有的“笔尖形状设计”区域；真正编辑仍然只在那里完成。")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("当前真实绘制状态")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(primaryTextColor)

                dualTipStatusLine(
                    title: "主笔尖",
                    value: dualTipPrimaryTipSummaryTitle(for: brush),
                    isSupported: brush.tipShape.supportsDualTipRealDrawingPrimary,
                    supportedText: "当前支持"
                )
                dualTipStatusLine(
                    title: "次笔尖",
                    value: dualTipSecondaryTipSummaryTitle(for: brush.secondaryTipDescriptor),
                    isSupported: brush.secondaryTipDescriptor.supportsPhaseOneDualTipRealDrawing,
                    supportedText: "当前支持"
                )
                dualTipStatusLine(
                    title: "模式",
                    value: brush.dualTipCombineMode.displayName,
                    isSupported: brush.dualTipCombineMode == .multiply || brush.dualTipCombineMode == .subtract || brush.dualTipCombineMode == .intersect,
                    supportedText: brush.dualTipCombineMode == .multiply ? "Phase 1" : "Phase 2"
                )
                dualTipStatusLine(
                    title: "工具",
                    value: activeTool.displayName,
                    isSupported: activeTool == .brush || activeTool == .eraser,
                    supportedText: "当前支持"
                )

                Text(
                    phaseTwoIntersectRealDrawingSupported
                    ? "当前真实 intersect 路径已接通。强度和次笔尖大小比例会直接决定交集收口程度与范围。"
                    : (phaseTwoSubtractRealDrawingSupported
                    ? "当前真实 subtract 路径已接通。强度和次笔尖大小比例会直接决定挖空程度与范围。"
                    : (phaseOneRealDrawingSupported
                        ? "当前真实 Dual Tip 路径已接通。强度和次笔尖大小比例会直接影响落笔。"
                        : "当前仍走旧绘制路径。只有上面 4 项都满足已接入条件时，真实画布才会出现变化。"))
                )
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(dualTipRealDrawingSupported ? statusAccentColor : secondaryTextColor)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 6) {
                Text("组合模式")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(primaryTextColor)

                Picker(
                    "组合模式",
                    selection: Binding(
                        get: { brush.dualTipCombineMode },
                        set: { viewModel.setDualTipCombineMode($0) }
                    )
                ) {
                    ForEach(DualTipCombineMode.allCases, id: \.self) { mode in
                        Text(dualTipModeLabel(for: mode)).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                Text(dualTipModeDescription(for: brush))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Dual Tip 三格示意")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(primaryTextColor)

                HStack(alignment: .top, spacing: 8) {
                    DualTipPreviewCell(
                        title: "主笔尖",
                        caption: "当前作为基底的笔尖形状。"
                    ) {
                        brushPreviewGlyph(for: brush, maxExtent: 44)
                    }

                    DualTipPreviewCell(
                        title: "次笔尖",
                        caption: "用来调制主笔尖；大小会跟随“次笔尖大小比例”。"
                    ) {
                        brushPreviewGlyph(for: dualTipSecondaryPreviewBrush(from: brush), maxExtent: 44)
                    }

                    DualTipPreviewCell(
                        title: "最终笔尖",
                        caption: dualTipCompositePreviewCaption(for: brush, activeTool: activeTool)
                    ) {
                        if let previewImage = dualTipCompositePreviewImage(for: brush) {
                            Image(decorative: previewImage, scale: 1)
                                .resizable()
                                .interpolation(.high)
                                .scaledToFit()
                                .frame(width: 44, height: 44)
                        } else {
                            Text("当前模式或笔尖\n还未接入示意")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.76))
                                .multilineTextAlignment(.center)
                        }
                    }
                }

                Text("这组示意图只帮助理解当前已接入模式下的主/次笔尖关系；真实效果仍以实际落笔为准。")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DualTipPhaseZeroSliderRow(
                title: "强度 Strength",
                valueText: "\(Int(brush.dualTipStrength * 100))%",
                value: Binding(
                    get: { Double(brush.dualTipStrength) },
                    set: { _ in }
                ),
                range: 0...1,
                onCommit: { viewModel.setDualTipStrength(Float($0)) },
                helperText: dualTipStrengthHelperText(for: brush)
            )

            DualTipPhaseZeroSliderRow(
                title: "次笔尖大小比例",
                valueText: String(format: "%.2fx", brush.secondarySizeRatio),
                value: Binding(
                    get: { Double(brush.secondarySizeRatio) },
                    set: { _ in }
                ),
                range: 0.25...0.95,
                onCommit: { viewModel.setSecondarySizeRatio(Float($0)) },
                helperText: dualTipSizeRatioHelperText(for: brush)
            )

            DualTipPhaseZeroSliderRow(
                title: "角度偏移",
                valueText: "\(Int(brush.secondaryAngleOffsetDegrees))°",
                value: Binding(
                    get: { Double(brush.secondaryAngleOffsetDegrees) },
                    set: { _ in }
                ),
                range: -180...180,
                onCommit: { viewModel.setSecondaryAngleOffsetDegrees(Float($0)) },
                isEnabled: false,
                helperText: "Phase 2 后接入真实绘制；当前只保留已保存值。"
            )

            DualTipPhaseZeroSliderRow(
                title: "散布",
                valueText: String(format: "%.1fx", brush.secondaryScatter),
                value: Binding(
                    get: { Double(brush.secondaryScatter) },
                    set: { _ in }
                ),
                range: 0...5,
                onCommit: { viewModel.setSecondaryScatter(Float($0)) },
                isEnabled: false,
                helperText: "Phase 2 后接入真实绘制；当前不会影响落笔。"
            )

            VStack(alignment: .leading, spacing: 6) {
                Toggle(
                    "反相次笔尖",
                    isOn: Binding(
                        get: { brush.secondaryInvert },
                        set: { viewModel.setSecondaryInvert($0) }
                    )
                )
                .toggleStyle(.switch)
                .foregroundStyle(primaryTextColor)
                .disabled(true)

                Text("反相仍保留到 Phase 2；当前不会影响绘制。")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .opacity(0.68)

            VStack(alignment: .leading, spacing: 8) {
                Text("次笔尖来源（独立编辑/保存）")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(primaryTextColor)

                HStack(alignment: .top, spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.black.opacity(0.05))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
                            )

                        brushPreviewGlyph(for: dualTipSecondaryPreviewBrush(from: brush), maxExtent: 48)
                            .padding(8)
                    }
                    .frame(width: 76, height: 76)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(dualTipSecondaryTipSummaryTitle(for: brush.secondaryTipDescriptor))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(primaryTextColor)

                        Text(dualTipSecondaryTipSummaryDetail(for: brush.secondaryTipDescriptor))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(secondaryTextColor)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("这里编辑的是次笔尖来源本身；不会改动主笔尖。")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(primaryTextColor.opacity(0.84))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.black.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )

                Button {
                    showsDualTipPopover = false
                    showsSecondaryTipEditor = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 11, weight: .bold))
                        Text("编辑次笔尖…")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.accentColor.opacity(0.10))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.accentColor.opacity(0.22), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                Text("点击后会打开独立的次笔尖编辑子面板。当前自定义次笔尖已可进入 multiply / subtract / intersect 的真实绘制 gate；方形次笔尖仍只编辑和保存。")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func colorPanelTopButton(
        _ title: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.96))
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isActive ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func importColorPaletteFromDrop(providers: [NSItemProvider]) -> Bool {
        if let imageProvider = providers.first(where: { $0.canLoadObject(ofClass: NSImage.self) }) {
            imageProvider.loadObject(ofClass: NSImage.self) { object, _ in
                guard let image = object as? NSImage else { return }
                DispatchQueue.main.async {
                    _ = viewModel.importColorPanelPalette(from: image)
                }
            }
            return true
        }

        if let fileProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            fileProvider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                switch item {
                case let data as Data:
                    url = URL(dataRepresentation: data, relativeTo: nil)
                case let nsData as NSData:
                    url = URL(dataRepresentation: nsData as Data, relativeTo: nil)
                case let fileURL as URL:
                    url = fileURL
                default:
                    url = nil
                }

                guard let url else { return }
                DispatchQueue.main.async {
                    _ = viewModel.importColorPanelPalette(from: url)
                }
            }
            return true
        }

        return false
    }

    private func swiftUIColor(from color: RGBAColor) -> Color {
        Color(
            red: Double(color.red),
            green: Double(color.green),
            blue: Double(color.blue),
            opacity: Double(color.alpha)
        )
    }

    private func parameterLine(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(Color.white.opacity(0.58))
            Spacer()
            Text(value)
                .foregroundStyle(Color.white.opacity(0.88))
        }
        .font(.system(size: 12, weight: .semibold))
    }

    private func inspectorButton(
        _ title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.96))
                .frame(maxWidth: .infinity, minHeight: 28)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.18))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lineLimit(2)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .opacity(1)
    }

    private var phaseZeroSecondaryTipShapeOptions: [BrushTipShape] {
        [.hardRound, .softRound, .square]
    }

    private func dualTipModeLabel(for mode: DualTipCombineMode) -> String {
        switch mode {
        case .multiply:
            return "\(mode.displayName)（Phase 1）"
        case .subtract:
            return "\(mode.displayName)（Phase 2 已接入）"
        case .intersect:
            return "\(mode.displayName)（Phase 2 已接入）"
        }
    }

    private func dualTipPrimaryTipSummaryTitle(for brush: BrushSettings) -> String {
        switch brush.tipShape {
        case .hardRound, .softRound, .square:
            return brush.tipShape.displayName
        case .customRound:
            if brush.customTipMaskData != nil, viewModel.brushTipUsesImportedPreviewFit {
                return "导入图像笔尖（当前会话）"
            }
            return "自定义笔尖"
        }
    }

    private func dualTipPrimaryTipSummaryDetail(for brush: BrushSettings) -> String {
        switch brush.tipShape {
        case .hardRound:
            return "当前真实主笔尖是硬边圆；实际落笔直接使用它。"
        case .softRound:
            return "当前真实主笔尖是柔边圆；实际落笔直接使用它。"
        case .square:
            return "当前真实主笔尖是方形；当前 Dual Tip 已接入 gate 里仍会回旧路径。"
        case .customRound:
            if brush.customTipMaskData != nil, viewModel.brushTipUsesImportedPreviewFit {
                return "当前会话里的真实主笔尖来自图片导入；在当前 multiply / subtract / intersect gate 下，实际落笔正在直接使用这份导入笔尖。"
            }
            if brush.customTipMaskData != nil {
                return "当前真实主笔尖是自定义笔尖遮罩；在当前 multiply / subtract / intersect gate 下，实际落笔正在直接使用这份自定义笔尖。"
            }
            return "当前真实主笔尖来自自定义笔尖参数（柔边、圆度、角度）；在当前 multiply / subtract / intersect gate 下，实际落笔正在直接使用它。"
        }
    }

    private func dualTipStatusLine(
        title: String,
        value: String,
        isSupported: Bool,
        supportedText: String
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(red: 0.12, green: 0.12, blue: 0.13))

            Spacer(minLength: 8)

            Text(value)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(red: 0.24, green: 0.24, blue: 0.26))

            Text(isSupported ? supportedText : "未接入")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isSupported ? Color.green.opacity(0.86) : Color.orange.opacity(0.88))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill((isSupported ? Color.green : Color.orange).opacity(0.12))
                )
        }
    }

    private func dualTipSecondaryTipLabel(for tipShape: BrushTipShape) -> String {
        switch tipShape {
        case .hardRound, .softRound:
            return "\(tipShape.displayName)（Phase 1）"
        case .square:
            return "\(tipShape.displayName)（Phase 2）"
        case .customRound:
            return "\(tipShape.displayName)（Phase 2）"
        }
    }

    private func dualTipSecondaryTipEditorLabel(for tipShape: BrushTipShape) -> String {
        switch tipShape {
        case .hardRound, .softRound:
            return "\(tipShape.displayName)（当前真实支持）"
        case .square:
            return "\(tipShape.displayName)（仅编辑/保存）"
        case .customRound:
            return "自定义笔尖（当前真实支持）"
        }
    }

    private func dualTipSecondaryTipSummaryTitle(for secondary: SecondaryTipDescriptor) -> String {
        switch secondary.tipShape {
        case .hardRound, .softRound, .square:
            return secondary.tipShape.displayName
        case .customRound:
            return "自定义笔尖"
        }
    }

    private func dualTipSecondaryTipSummaryDetail(for secondary: SecondaryTipDescriptor) -> String {
        switch secondary.tipShape {
        case .hardRound:
            return "当前次笔尖是硬边圆；在当前 multiply / subtract / intersect gate 下可直接参与真实绘制。"
        case .softRound:
            return "当前次笔尖是柔边圆；在当前 multiply / subtract / intersect gate 下可直接参与真实绘制。"
        case .square:
            return "当前次笔尖是方形；现在可以编辑和保存，但真实绘制仍会回旧 gate。"
        case .customRound:
            if secondary.customTipMaskData != nil {
                return "当前次笔尖是自定义遮罩；在当前 multiply / subtract / intersect gate 下已可参与真实绘制。"
            }
            return "当前次笔尖使用自定义参数（柔边、圆度、角度）；在当前 multiply / subtract / intersect gate 下已可参与真实绘制。"
        }
    }

    private func dualTipSecondaryPreviewBrush(from brush: BrushSettings) -> BrushSettings {
        var previewBrush = brush
        let secondary = brush.secondaryTipDescriptor
        previewBrush.tipShape = secondary.tipShape
        previewBrush.size = max(1, brush.size * min(max(brush.secondarySizeRatio, 0.25), 0.95))
        previewBrush.customTipMaskData = secondary.customTipMaskData
        previewBrush.customTipSoftness = secondary.customTipSoftness
        previewBrush.customTipRoundness = secondary.customTipRoundness
        previewBrush.customTipAngleDegrees = secondary.customTipAngleDegrees
        return previewBrush
    }

    private func dualTipModeDescription(for brush: BrushSettings) -> String {
        switch brush.dualTipCombineMode {
        case .multiply:
            return "调制 = 用次笔尖压缩/削弱主笔尖的覆盖区域。次笔尖越小、强度越高，收口越明显。减去和相交都已接入。"
        case .subtract:
            return "减去 = 次笔尖会从主笔尖里挖掉一部分覆盖区域。次笔尖越小、强度越高，挖空越集中也越明显。相交也已接入。"
        case .intersect:
            return "相交 = 只保留主笔尖和次笔尖重叠的覆盖区域。强度越高，结果越接近纯交集；次笔尖越小，收口越明显。"
        }
    }

    private func dualTipStrengthHelperText(for brush: BrushSettings) -> String {
        switch brush.dualTipCombineMode {
        case .multiply:
            return "控制次笔尖削弱主笔尖的程度。越高，最终笔尖越明显被压缩。"
        case .subtract:
            return "控制次笔尖从主笔尖里挖掉的程度。越高，挖空感越明显。"
        case .intersect:
            return "控制相交收口的程度。越高，最终笔尖越接近主笔尖与次笔尖的纯交集。"
        }
    }

    private func dualTipSizeRatioHelperText(for brush: BrushSettings) -> String {
        switch brush.dualTipCombineMode {
        case .multiply:
            return "控制次笔尖相对主笔尖的大小。越小，越容易看到收口和压缩效果。"
        case .subtract:
            return "控制次笔尖相对主笔尖的大小。越小，挖空更集中；越大，削减范围更宽。"
        case .intersect:
            return "控制次笔尖相对主笔尖的大小。越小，交集越集中；越大，保留区域更宽。"
        }
    }

    private func dualTipCompositePreviewCaption(for brush: BrushSettings, activeTool: ToolKind) -> String {
        if brush.supportsPhaseTwoDualTipIntersectRealDrawing(for: activeTool) {
            return "当前真实路径已接通；会按强度和大小比例只保留主/次笔尖的重叠区域。"
        }
        if brush.supportsPhaseTwoDualTipSubtractRealDrawing(for: activeTool) {
            return "当前真实路径已接通；会按强度和大小比例挖掉主笔尖一部分。"
        }
        if brush.supportsPhaseOneDualTipRealDrawing(for: activeTool) {
            return "当前真实路径已接通；会按强度和大小比例收口。"
        }
        if brush.dualTipCombineMode == .intersect {
            return "Phase 2 intersect 目前示意当前已接通的主/次笔尖关系。"
        }
        if brush.dualTipCombineMode == .subtract {
            return "Phase 2 subtract 目前示意当前已接通的主/次笔尖关系。"
        }
        if !brush.tipShape.supportsDualTipRealDrawingPrimary || !brush.secondaryTipDescriptor.supportsPhaseOneDualTipRealDrawing {
            return "当前已接入模式只示意已接通的真实绘制条件。"
        }
        return "图形可示意当前组合关系，但当前工具仍走旧路径。"
    }

    private func dualTipPreviewAlpha(
        tipShape: BrushTipShape,
        normalizedX: Double,
        normalizedY: Double,
        customMaskBytes: [UInt8]?,
        softness: Float,
        roundness: Float,
        angleDegrees: Float
    ) -> Double {
        switch tipShape {
        case .hardRound:
            let distance = hypot(normalizedX, normalizedY)
            return distance < 1.0 ? 1.0 : 0.0
        case .softRound:
            let distance = hypot(normalizedX, normalizedY)
            guard distance < 1.0 else { return 0.0 }
            let feather = max(0.0, 1.0 - distance)
            return feather * feather
        case .square:
            return max(abs(normalizedX), abs(normalizedY)) < 1.0 ? 1.0 : 0.0
        case .customRound:
            let radians = Double(angleDegrees) * .pi / 180.0
            let cosine = cos(radians)
            let sine = sin(radians)
            let rotatedX = (normalizedX * cosine) + (normalizedY * sine)
            let rotatedY = (-normalizedX * sine) + (normalizedY * cosine)
            let clampedRoundness = max(Double(roundness), 0.25)
            let shapedX = rotatedX / clampedRoundness
            let shapedY = rotatedY

            if let customMaskBytes {
                guard max(abs(shapedX), abs(shapedY)) < 1.0 else {
                    return 0.0
                }

                let resolution = Int(Double(customMaskBytes.count).squareRoot())
                guard resolution > 1 else {
                    return 0.0
                }

                let u = min(max((shapedX + 1.0) * 0.5, 0.0), 1.0)
                let v = min(max((shapedY + 1.0) * 0.5, 0.0), 1.0)
                let x = u * Double(resolution - 1)
                let y = v * Double(resolution - 1)
                let x0 = Int(floor(x))
                let y0 = Int(floor(y))
                let x1 = min(x0 + 1, resolution - 1)
                let y1 = min(y0 + 1, resolution - 1)
                let tx = x - Double(x0)
                let ty = y - Double(y0)

                func sample(_ sampleX: Int, _ sampleY: Int) -> Double {
                    let index = (sampleY * resolution) + sampleX
                    return Double(customMaskBytes[index]) / 255.0
                }

                let top = (sample(x0, y0) * (1.0 - tx)) + (sample(x1, y0) * tx)
                let bottom = (sample(x0, y1) * (1.0 - tx)) + (sample(x1, y1) * tx)
                let sampledAlpha = (top * (1.0 - ty)) + (bottom * ty)
                let clampedSoftness = min(max(Double(softness), 0.0), 1.0)
                let exponent = (3.2 * (1.0 - clampedSoftness)) + (0.75 * clampedSoftness)
                return pow(min(max(sampledAlpha, 0.0), 1.0), exponent)
            }

            let hardness = Double(BrushTipShape.customRoundHardness(for: softness))
            let distance = hypot(shapedX, shapedY)
            guard distance < 1.0 else { return 0.0 }
            if hardness >= 0.999 || distance <= hardness {
                return 1.0
            }

            let t = min(max((distance - hardness) / (1.0 - hardness), 0.0), 1.0)
            return 1.0 - (t * t * (3.0 - (2.0 * t)))
        }
    }

    private func dualTipCompositePreviewImage(for brush: BrushSettings, resolution: Int = 80) -> CGImage? {
        guard (brush.dualTipCombineMode == .multiply ||
               brush.dualTipCombineMode == .subtract ||
               brush.dualTipCombineMode == .intersect),
              brush.tipShape.supportsDualTipRealDrawingPrimary,
              brush.secondaryTipDescriptor.supportsPhaseOneDualTipRealDrawing else {
            return nil
        }

        let width = resolution
        let height = resolution
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        let strength = Double(min(max(brush.dualTipStrength, 0), 1))
        let sizeRatio = Double(min(max(brush.secondarySizeRatio, 0.25), 0.95))
        let primaryMaskBytes = resampledMaskData(
            brush.customTipMaskData,
            targetResolution: resolution
        ).map(Array.init)
        let secondaryMaskBytes = resampledMaskData(
            brush.secondaryTipDescriptor.customTipMaskData,
            targetResolution: resolution
        ).map(Array.init)

        for y in 0..<height {
            for x in 0..<width {
                let normalizedX = ((Double(x) + 0.5) / Double(width)) * 2.0 - 1.0
                let normalizedY = ((Double(y) + 0.5) / Double(height)) * 2.0 - 1.0
                let primaryAlpha = dualTipPreviewAlpha(
                    tipShape: brush.tipShape,
                    normalizedX: normalizedX,
                    normalizedY: normalizedY,
                    customMaskBytes: primaryMaskBytes,
                    softness: brush.customTipSoftness,
                    roundness: brush.customTipRoundness,
                    angleDegrees: brush.customTipAngleDegrees
                )
                let secondaryAlpha = dualTipPreviewAlpha(
                    tipShape: brush.secondaryTipDescriptor.tipShape,
                    normalizedX: normalizedX / sizeRatio,
                    normalizedY: normalizedY / sizeRatio,
                    customMaskBytes: secondaryMaskBytes,
                    softness: brush.secondaryTipDescriptor.customTipSoftness,
                    roundness: brush.secondaryTipDescriptor.customTipRoundness,
                    angleDegrees: brush.secondaryTipDescriptor.customTipAngleDegrees
                )
                let combinedAlpha: Double
                switch brush.dualTipCombineMode {
                case .multiply:
                    combinedAlpha = primaryAlpha * ((1.0 - strength) + (secondaryAlpha * strength))
                case .subtract:
                    combinedAlpha = primaryAlpha * (1.0 - min(max(secondaryAlpha * strength, 0.0), 1.0))
                case .intersect:
                    let pureIntersection = min(primaryAlpha, secondaryAlpha)
                    combinedAlpha = primaryAlpha + ((pureIntersection - primaryAlpha) * strength)
                }

                let alpha = UInt8(min(max(combinedAlpha * 255.0, 0), 255))
                let offset = (y * bytesPerRow) + (x * bytesPerPixel)
                pixels[offset] = 255
                pixels[offset + 1] = 255
                pixels[offset + 2] = 255
                pixels[offset + 3] = alpha
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else {
            return nil
        }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private var secondaryTipEditorSheet: some View {
        let brush = viewModel.workspace.toolSession.brush
        let secondary = brush.secondaryTipDescriptor
        let primaryTextColor = Color(red: 0.12, green: 0.12, blue: 0.13)
        let secondaryTextColor = Color(red: 0.32, green: 0.32, blue: 0.34)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("编辑次笔尖")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(primaryTextColor)

                    Text("这里只编辑 SecondaryTipDescriptor。真实绘制当前允许圆形和自定义次笔尖进入 multiply / subtract / intersect gate；方形仍只编辑和保存。")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(secondaryTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button("完成") {
                    showsSecondaryTipEditor = false
                }
                .font(.system(size: 12, weight: .semibold))
            }

            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.black.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.black.opacity(0.08), lineWidth: 1)
                        )

                    brushPreviewGlyph(for: dualTipSecondaryPreviewBrush(from: brush), maxExtent: 54)
                        .padding(8)
                }
                .frame(width: 84, height: 84)

                VStack(alignment: .leading, spacing: 6) {
                    Text(dualTipSecondaryTipSummaryTitle(for: secondary))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(primaryTextColor)

                    Text(dualTipSecondaryTipSummaryDetail(for: secondary))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(secondaryTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 6) {
                Text("次笔尖形状")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(primaryTextColor)

                Picker(
                    "次笔尖形状",
                    selection: Binding(
                        get: { secondary.tipShape },
                        set: { viewModel.setSecondaryTipShape($0) }
                    )
                ) {
                    ForEach(BrushTipShape.allCases, id: \.self) { tipShape in
                        Text(dualTipSecondaryTipEditorLabel(for: tipShape)).tag(tipShape)
                    }
                }
                .pickerStyle(.menu)

                Text("硬边圆 / 柔边圆 / 自定义次笔尖当前可进入真实绘制。方形这轮仍只接编辑与保存，不扩 renderer gate。")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Picker("绘制模式", selection: $secondaryTipPaintMode) {
                        Text("绘制").tag(TipPaintMode.round)
                        Text("擦除").tag(TipPaintMode.eraser)
                    }
                    .pickerStyle(.segmented)

                    Button("导入图片…") {
                        if viewModel.importSecondaryTipImageFromDisk() {
                            secondaryTipUsesImportedPreviewFit = true
                        }
                    }

                    Button("清空自定义") {
                        viewModel.clearSecondaryTipMask()
                        secondaryTipUsesImportedPreviewFit = false
                    }
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.black.opacity(0.08), lineWidth: 1)
                        )

                    TipMaskCanvasView(
                        maskData: secondary.customTipMaskData,
                        fitImportedPreview: secondaryTipUsesImportedPreviewFit,
                        paintMode: secondaryTipPaintMode,
                        softness: Float(secondaryTipPaintSoftness),
                        intensity: Float(secondaryTipPaintIntensity),
                        brushSize: brush.size,
                        onFocusChanged: { _ in },
                        onImportImage: { image in
                            if viewModel.importSecondaryTipImage(from: image) {
                                secondaryTipUsesImportedPreviewFit = true
                            }
                        },
                        onUpdateMask: { data in
                            secondaryTipUsesImportedPreviewFit = false
                            viewModel.updateSecondaryTipMask(data)
                        }
                    )
                    .frame(height: 180)
                }

                Text("在这里绘制或导入，会把次笔尖来源切到“自定义笔尖”；当前 multiply / subtract / intersect 已可使用自定义次笔尖，方形仍会回旧 gate。")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DualTipPhaseZeroSliderRow(
                title: "自定义柔边",
                valueText: "\(Int(secondary.customTipSoftness * 100))%",
                value: Binding(
                    get: { Double(secondary.customTipSoftness) },
                    set: { _ in }
                ),
                range: 0...1,
                onCommit: { viewModel.setSecondaryTipSoftness(Float($0)) },
                helperText: "影响次笔尖自定义来源的柔边特性；当前 multiply / subtract / intersect gate 下已可参与真实绘制。"
            )

            DualTipPhaseZeroSliderRow(
                title: "自定义圆度",
                valueText: "\(Int(secondary.customTipRoundness * 100))%",
                value: Binding(
                    get: { Double(secondary.customTipRoundness) },
                    set: { _ in }
                ),
                range: 0.25...1,
                onCommit: { viewModel.setSecondaryTipRoundness(Float($0)) },
                helperText: "控制次笔尖自定义来源的横向压缩比例。"
            )

            DualTipPhaseZeroSliderRow(
                title: "自定义角度",
                valueText: "\(Int(secondary.customTipAngleDegrees))°",
                value: Binding(
                    get: { Double(secondary.customTipAngleDegrees) },
                    set: { _ in }
                ),
                range: 0...180,
                onCommit: { viewModel.setSecondaryTipSourceAngleDegrees(Float($0)) },
                helperText: "控制次笔尖自定义来源的旋转角度。当前 multiply / subtract / intersect gate 下已可参与真实绘制。"
            )

            DualTipPhaseZeroSliderRow(
                title: "编辑画笔柔边",
                valueText: "\(Int(secondaryTipPaintSoftness * 100))%",
                value: Binding(
                    get: { secondaryTipPaintSoftness },
                    set: { _ in }
                ),
                range: 0...1,
                onCommit: { secondaryTipPaintSoftness = $0 },
                helperText: "只影响当前次笔尖遮罩编辑手感，不会写入真实次笔尖来源参数。"
            )
        }
        .padding(16)
        .frame(width: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func revealPrimaryTipEditor() {
        showsDualTipPopover = false
        primaryTipEditorHighlightGeneration += 1
        let currentGeneration = primaryTipEditorHighlightGeneration

        withAnimation(.easeInOut(duration: 0.18)) {
            highlightsPrimaryTipEditor = true
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard currentGeneration == primaryTipEditorHighlightGeneration else { return }
            withAnimation(.easeInOut(duration: 0.24)) {
                highlightsPrimaryTipEditor = false
            }
        }
    }

    private func compactToolButton(
        systemImage: String,
        tooltip: String,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.95))
                .frame(width: 34, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? Color.accentColor : Color.white.opacity(0.18))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            isSelected ? Color.accentColor.opacity(0.95) : Color.white.opacity(0.16),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(tooltip)
    }

    private func compactTextActionButton(
        title: String,
        tooltip: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.96))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 30)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.18))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(tooltip)
    }

    private func compactIconButton(
        systemImage: String,
        tooltip: String,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.98))
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isSelected ? Color.accentColor : Color.white.opacity(0.18))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(
                            isSelected ? Color.accentColor.opacity(0.95) : Color.white.opacity(0.16),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(tooltip)
    }

    private func inspectorLabeledSlider(
        title: String,
        valueText: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .foregroundStyle(Color.white.opacity(0.58))
                Spacer()
                Text(valueText)
                    .foregroundStyle(Color.white.opacity(0.88))
            }
            .font(.system(size: 11, weight: .semibold))

            Slider(
                value: value,
                in: range,
                onEditingChanged: onEditingChanged
            )
        }
    }

    private func compactParameterSlider(
        title: String,
        valueText: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.58))
                .frame(width: 44, alignment: .leading)

            Slider(
                value: value,
                in: range,
                onEditingChanged: onEditingChanged
            )

            Text(valueText)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.88))
                .frame(width: 48, alignment: .trailing)
        }
    }

    private func layerRow(_ layer: LayerRecord) -> some View {
        let isActive = layer.id == viewModel.workspace.document.activeLayerID
        let isEditing = editingLayerID == layer.id

        return HStack {
            layerThumbnailView(for: layer)

            Circle()
                .fill(isActive ? Color.accentColor : Color.white.opacity(0.25))
                .frame(width: 8, height: 8)

            if isEditing {
                TextField("", text: Binding(
                    get: { editingLayerName },
                    set: { editingLayerName = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))
                .focused($focusedLayerNameFieldID, equals: layer.id)
                .onSubmit {
                    commitLayerRename(for: layer.id)
                }
                .onChange(of: focusedLayerNameFieldID) { _, focusedID in
                    if focusedID != layer.id, editingLayerID == layer.id {
                        commitLayerRename(for: layer.id)
                    }
                }
            } else {
                Text(layer.name)
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(1)
                    .onTapGesture(count: 2) {
                        beginLayerRename(layer)
                    }
            }

            Spacer()

            Button {
                viewModel.setLayerVisibility(layer.id, isVisible: !layer.isVisible)
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(layer.isVisible ? Color.white.opacity(0.72) : Color.accentColor)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help(layer.isVisible ? "隐藏图层" : "显示图层")

            Button {
                viewModel.toggleLayerLock(layer.id)
            } label: {
                Image(systemName: layer.isLocked ? "lock.fill" : "lock.open")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(layer.isLocked ? Color.orange : Color.white.opacity(0.72))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help(layer.isLocked ? "解锁图层" : "锁定图层")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            (isActive ? Color.accentColor.opacity(0.18) : Color.clear),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture {
            viewModel.selectLayer(layer.id)
        }
        .onDrag {
            cancelLayerRename()
            draggedLayerID = layer.id
            return NSItemProvider(object: layer.id.rawValue.uuidString as NSString)
        }
    }

    private func layerDropInsertionStrip(at insertionIndex: Int) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 12)
            .overlay(alignment: .center) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(layerDropInsertionIndex == insertionIndex ? 0.95 : 0))
                    .frame(height: 3)
                    .padding(.horizontal, 6)
            }
            .contentShape(Rectangle())
            .onDrop(
                of: [UTType.plainText.identifier],
                isTargeted: Binding(
                    get: { layerDropInsertionIndex == insertionIndex },
                    set: { isTargeted in
                        if isTargeted {
                            layerDropInsertionIndex = insertionIndex
                        } else if layerDropInsertionIndex == insertionIndex {
                            layerDropInsertionIndex = nil
                        }
                    }
                )
            ) { providers in
                moveLayerFromDrop(providers: providers, toDisplayInsertionIndex: insertionIndex)
            }
    }

    private func layerActionButton(
        systemImage: String,
        tooltip: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    @ViewBuilder
    private func layerThumbnailView(for layer: LayerRecord) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.06))
                .frame(width: 30, height: 30)

            if let image = viewModel.layerThumbnail(for: layer.id, maxDimension: 36) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 18, height: 18)
            }
        }
    }

    private func moveLayerFromDrop(providers: [NSItemProvider], toDisplayInsertionIndex insertionIndex: Int) -> Bool {
        if let draggedLayerID {
            viewModel.moveLayer(draggedLayerID, toDisplayInsertionIndex: insertionIndex)
            self.draggedLayerID = nil
            layerDropInsertionIndex = nil
            return true
        }

        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return false
        }

        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard
                let rawID = object as? NSString,
                let uuid = UUID(uuidString: String(rawID))
            else {
                return
            }

            DispatchQueue.main.async {
                viewModel.moveLayer(LayerID(rawValue: uuid), toDisplayInsertionIndex: insertionIndex)
                layerDropInsertionIndex = nil
            }
        }

        return true
    }

    private func beginLayerRename(_ layer: LayerRecord) {
        viewModel.selectLayer(layer.id)
        editingLayerID = layer.id
        editingLayerName = layer.name
        focusedLayerNameFieldID = layer.id
    }

    private func commitLayerRename(for layerID: LayerID) {
        let trimmedName = editingLayerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let layer = viewModel.workspace.document.layers.first(where: { $0.id == layerID }),
           !trimmedName.isEmpty,
           trimmedName != layer.name {
            viewModel.renameLayer(layerID, to: trimmedName)
        }
        cancelLayerRename()
    }

    private func cancelLayerRename() {
        editingLayerID = nil
        editingLayerName = ""
        focusedLayerNameFieldID = nil
    }

    private var tipDesignCanvas: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white)
                .frame(height: 180)
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            isTipImageDropTarget ? Color.accentColor.opacity(0.9) : Color.clear,
                            lineWidth: 2
                        )
                }

            TipMaskCanvasView(
                maskData: viewModel.workspace.toolSession.brush.customTipMaskData,
                fitImportedPreview: viewModel.brushTipUsesImportedPreviewFit,
                paintMode: tipPaintMode,
                softness: Float(tipPaintSoftness),
                intensity: Float(tipPaintIntensity),
                brushSize: viewModel.workspace.toolSession.brush.size,
                onFocusChanged: { isFocused in
                    viewModel.setBrushTipCanvasFocused(isFocused)
                },
                onImportImage: { image in
                    _ = viewModel.importBrushTipImage(from: image)
                },
                onUpdateMask: { data in
                    viewModel.updateCustomTipMask(data)
                }
            )
            .frame(height: 180)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                viewModel.clearCustomTipMask()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.45))
                    .padding(8)
            }
            .buttonStyle(.plain)
            .help("清空笔尖")
        }
        .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier], isTargeted: $isTipImageDropTarget) { providers in
            importTipImageFromDrop(providers: providers)
        }
    }

    private func importTipImageFromDrop(providers: [NSItemProvider]) -> Bool {
        if let imageProvider = providers.first(where: { $0.canLoadObject(ofClass: NSImage.self) }) {
            imageProvider.loadObject(ofClass: NSImage.self) { object, _ in
                guard let image = object as? NSImage else { return }
                DispatchQueue.main.async {
                    _ = viewModel.importBrushTipImage(from: image)
                }
            }
            return true
        }

        if let fileProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            fileProvider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                switch item {
                case let data as Data:
                    url = URL(dataRepresentation: data, relativeTo: nil)
                case let nsData as NSData:
                    url = URL(dataRepresentation: nsData as Data, relativeTo: nil)
                case let fileURL as URL:
                    url = fileURL
                default:
                    url = nil
                }

                guard let url else { return }
                DispatchQueue.main.async {
                    _ = viewModel.importBrushTipImage(from: url)
                }
            }
            return true
        }

        return false
    }

    private func insertNextPresetShape() {
        let nextIndex = presetShapeIndex % 4
        presetShapeIndex += 1
        viewModel.updateCustomTipMask(makePresetTipMask(for: nextIndex, intensity: UInt8((tipPaintIntensity * 255).rounded())))
    }

    private func insertNextSprayPattern() {
        let nextIndex = sprayPatternIndex % 4
        sprayPatternIndex += 1
        viewModel.updateCustomTipMask(makeSprayTipMask(for: nextIndex, intensity: UInt8((tipPaintIntensity * 255).rounded())))
    }

    private func rotateCustomTip() {
        guard let current = resampledMaskData(viewModel.workspace.toolSession.brush.customTipMaskData, targetResolution: tipMaskResolution) else {
            return
        }

        let source = [UInt8](current)
        var destination = [UInt8](repeating: 0, count: source.count)
        for y in 0..<tipMaskResolution {
            for x in 0..<tipMaskResolution {
                let sourceIndex = (y * tipMaskResolution) + x
                let destinationX = tipMaskResolution - 1 - y
                let destinationY = x
                destination[(destinationY * tipMaskResolution) + destinationX] = source[sourceIndex]
            }
        }
        viewModel.updateCustomTipMask(Data(destination))
    }

    private func flipCustomTipHorizontally() {
        flipCustomTip { x, y in
            (tipMaskResolution - 1 - x, y)
        }
    }

    private func flipCustomTipVertically() {
        flipCustomTip { x, y in
            (x, tipMaskResolution - 1 - y)
        }
    }

    private func flipCustomTip(mapping: (Int, Int) -> (Int, Int)) {
        guard let current = resampledMaskData(viewModel.workspace.toolSession.brush.customTipMaskData, targetResolution: tipMaskResolution) else {
            return
        }

        let source = [UInt8](current)
        var destination = [UInt8](repeating: 0, count: source.count)
        for y in 0..<tipMaskResolution {
            for x in 0..<tipMaskResolution {
                let sourceIndex = (y * tipMaskResolution) + x
                let mapped = mapping(x, y)
                destination[(mapped.1 * tipMaskResolution) + mapped.0] = source[sourceIndex]
            }
        }
        viewModel.updateCustomTipMask(Data(destination))
    }

    private func makePresetTipMask(for index: Int, intensity: UInt8) -> Data {
        var mask = [UInt8](repeating: 0, count: tipMaskResolution * tipMaskResolution)

        func fillCircle(centerX: Double, centerY: Double, radius: Double) {
            let minX = max(0, Int(centerX - radius - 1))
            let maxX = min(tipMaskResolution - 1, Int(centerX + radius + 1))
            let minY = max(0, Int(centerY - radius - 1))
            let maxY = min(tipMaskResolution - 1, Int(centerY + radius + 1))

            guard minX <= maxX, minY <= maxY else { return }
            for y in minY...maxY {
                for x in minX...maxX {
                    let dx = Double(x) - centerX
                    let dy = Double(y) - centerY
                    if sqrt((dx * dx) + (dy * dy)) <= radius {
                        mask[(y * tipMaskResolution) + x] = intensity
                    }
                }
            }
        }

        func fillRect(_ rect: CGRect) {
            let minX = max(0, Int(rect.minX.rounded(.down)))
            let maxX = min(tipMaskResolution - 1, Int(rect.maxX.rounded(.up)))
            let minY = max(0, Int(rect.minY.rounded(.down)))
            let maxY = min(tipMaskResolution - 1, Int(rect.maxY.rounded(.up)))

            guard minX <= maxX, minY <= maxY else { return }
            for y in minY...maxY {
                for x in minX...maxX {
                    mask[(y * tipMaskResolution) + x] = intensity
                }
            }
        }

        switch index {
        case 0:
            fillCircle(centerX: 128, centerY: 128, radius: 62)
        case 1:
            fillRect(CGRect(x: 56, y: 78, width: 144, height: 100))
        case 2:
            for step in 0..<96 {
                let t = Double(step) / 95.0
                let x = 64.0 + (t * 128.0)
                let y = 182.0 - (t * 96.0)
                fillCircle(centerX: x, centerY: y, radius: 21)
            }
        default:
            fillCircle(centerX: 92, centerY: 132, radius: 34)
            fillCircle(centerX: 164, centerY: 112, radius: 26)
            fillCircle(centerX: 144, centerY: 166, radius: 18)
        }

        return Data(mask)
    }

    private func makeSprayTipMask(for index: Int, intensity: UInt8) -> Data {
        var mask = [UInt8](repeating: 0, count: tipMaskResolution * tipMaskResolution)
        let densities = [18, 36, 72, 120]
        let dotCount = densities[index]
        let baseRadii = [11.0, 7.0, 4.5, 2.8]
        let radiusVariance = [5.5, 3.2, 2.0, 1.2]
        let baseRadius = baseRadii[index]

        for dot in 0..<dotCount {
            let seed = Double((index + 1) * 991 + dot * 37)
            let angle = (sin(seed * 0.121) * .pi) + .pi
            let distance = pow(abs(cos(seed * 0.077)), 1.5) * 82.0
            let centerX = 128.0 + (cos(angle) * distance)
            let centerY = 128.0 + (sin(angle) * distance)
            let radius = max(1.2, baseRadius + sin(seed * 0.191) * radiusVariance[index])

            let minX = max(0, Int(centerX - radius - 1))
            let maxX = min(tipMaskResolution - 1, Int(centerX + radius + 1))
            let minY = max(0, Int(centerY - radius - 1))
            let maxY = min(tipMaskResolution - 1, Int(centerY + radius + 1))

            guard minX <= maxX, minY <= maxY else { continue }
            for y in minY...maxY {
                for x in minX...maxX {
                    let dx = Double(x) - centerX
                    let dy = Double(y) - centerY
                    let normalizedDistance = sqrt((dx * dx) + (dy * dy)) / radius
                    guard normalizedDistance <= 1 else { continue }
                    let alpha = UInt8(clamping: Int(((1 - normalizedDistance) * Double(intensity)).rounded()))
                    let offset = (y * tipMaskResolution) + x
                    mask[offset] = max(mask[offset], alpha)
                }
            }
        }

        return Data(mask)
    }

    private func brushPresetCell(_ preset: BrushPreset, slotIndex: Int) -> some View {
        let isSelected = viewModel.workspace.brushLibrary.selectedPresetID == preset.id
        let isDualTipDemo = preset.isDualTipPhaseOneDemoPreset
        let strokeColor: Color = isDualTipDemo
            ? Color(red: 0.42, green: 0.86, blue: 1.0).opacity(isSelected ? 0.98 : 0.8)
            : (isSelected ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.06))
        let strokeWidth: CGFloat = isSelected ? 1.5 : (isDualTipDemo ? 1.35 : 1.0)

        return Button {
            viewModel.applyBrushPreset(preset.id)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.white.opacity(0.03))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                strokeColor,
                                lineWidth: strokeWidth
                            )
                    }
                GeometryReader { geometry in
                    let cellSide = min(geometry.size.width, geometry.size.height)
                    let previewSide = cellSide * 0.56
                    let glyphSide = max(14, cellSide * 0.18)

                    ZStack(alignment: .bottomTrailing) {
                        brushStrokePreview(for: preset.brush)
                            .frame(width: previewSide, height: previewSide)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(.leading, cellSide * 0.10)
                            .padding(.top, cellSide * 0.08)

                        brushPreviewGlyph(for: preset.brush, maxExtent: glyphSide)
                            .frame(width: glyphSide, height: glyphSide, alignment: .center)
                            .padding(.trailing, cellSide * 0.09)
                            .padding(.bottom, cellSide * 0.07)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                }

                shortcutSlotLabel(for: slotIndex)

                if !preset.isBuiltIn {
                    VStack {
                        HStack {
                            Spacer()
                            Button {
                                viewModel.deleteBrushPreset(preset.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Color.white.opacity(0.55))
                            }
                            .buttonStyle(.plain)
                            .help("删除笔刷预设")
                            .padding(6)
                        }
                        Spacer()
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
        }
        .buttonStyle(.plain)
        .help(preset.isDualTipPhaseOneDemoPreset ? "\(preset.name)\nDual Tip Phase 1 示例预设" : preset.name)
        .contextMenu {
            Button("应用") {
                viewModel.applyBrushPreset(preset.id)
            }

            if !preset.isBuiltIn {
                Button("删除") {
                    viewModel.deleteBrushPreset(preset.id)
                }
            }
        }
    }

    @ViewBuilder
    private func shortcutSlotLabel(for slotIndex: Int) -> some View {
        if slotIndex < 4 {
            Text("\(slotIndex + 1)")
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.72))
                .padding(.leading, 8)
                .padding(.top, 7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func moveBrushPresetFromDrop(providers: [NSItemProvider], toSlot slotIndex: Int) -> Bool {
        if let draggedBrushPresetID {
            viewModel.moveBrushPreset(draggedBrushPresetID, toSlot: slotIndex)
            self.draggedBrushPresetID = nil
            return true
        }

        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return false
        }

        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let presetID = object as? NSString else {
                return
            }
            let presetIDString = String(presetID)
            DispatchQueue.main.async {
                viewModel.moveBrushPreset(presetIDString, toSlot: slotIndex)
            }
        }
        return true
    }

    private func brushStrokePreview(for brush: BrushSettings) -> some View {
        Canvas { context, size in
            let start = CGPoint(x: size.width * 0.18, y: size.height * 0.78)
            let end = CGPoint(x: size.width * 0.82, y: size.height * 0.22)
            let dx = end.x - start.x
            let dy = end.y - start.y
            let pathAngle = atan2(dy, dx)

            let spacing = max(0.18, min(Double(brush.spacingPercent) / 100.0, 1.5))
            let scatter = Double(brush.scatterAmount)
            let jitter = Double(brush.jitterAmount)
            let stampCount = max(4, Int(12.0 / spacing))

            let baseWidth = min(size.width, size.height) * 0.42
            let tipImage = customTipPreviewImage(from: brush.customTipMaskData)

            for index in 0..<stampCount {
                let t = stampCount == 1 ? 0.0 : Double(index) / Double(stampCount - 1)
                var point = CGPoint(
                    x: start.x + (dx * t),
                    y: start.y + (dy * t)
                )

                if scatter > 0.001 {
                    let normal = CGPoint(x: -dy, y: dx)
                    let normalLength = max(sqrt((normal.x * normal.x) + (normal.y * normal.y)), 0.001)
                    let normalized = CGPoint(x: normal.x / normalLength, y: normal.y / normalLength)
                    let offset = (previewRandom(seed: index * 17 + 11) * 2.0 - 1.0) * scatter * 2.6
                    point.x += normalized.x * offset
                    point.y += normalized.y * offset
                }

                let sizeScale = 1.0 - (previewRandom(seed: index * 29 + 7) * jitter * 0.45)
                let stampWidth = max(6, baseWidth * sizeScale)
                let rect = CGRect(
                    x: point.x - (stampWidth / 2),
                    y: point.y - (stampWidth / 2),
                    width: stampWidth,
                    height: stampWidth
                )

                var angle = Double(brush.stampRotationDegrees) * .pi / 180.0
                if brush.followsStrokeDirection {
                    angle += pathAngle
                }
                angle += (previewRandom(seed: index * 43 + 19) * 2.0 - 1.0) * jitter * 0.65

                context.drawLayer { layer in
                    layer.translateBy(x: rect.midX, y: rect.midY)
                    layer.rotate(by: Angle(radians: angle))
                    layer.translateBy(x: -rect.midX, y: -rect.midY)

                    switch brush.tipShape {
                    case .hardRound:
                        layer.fill(
                            Path(ellipseIn: rect),
                            with: .color(Color.white.opacity(0.88))
                        )
                    case .softRound:
                        layer.fill(
                            Path(ellipseIn: rect),
                            with: .radialGradient(
                                Gradient(colors: [
                                    Color.white.opacity(0.90),
                                    Color.white.opacity(0.18)
                                ]),
                                center: CGPoint(x: rect.midX, y: rect.midY),
                                startRadius: 0,
                                endRadius: stampWidth * 0.5
                            )
                        )
                    case .square:
                        layer.fill(
                            Path(CGRect(
                                x: rect.midX - stampWidth * 0.42,
                                y: rect.midY - stampWidth * 0.42,
                                width: stampWidth * 0.84,
                                height: stampWidth * 0.84
                            )),
                            with: .color(Color.white.opacity(0.88))
                        )
                    case .customRound:
                        if let tipImage {
                            let resolved = layer.resolve(Image(decorative: tipImage, scale: 1))
                            layer.draw(resolved, in: rect)
                        } else {
                            layer.fill(
                                Path(ellipseIn: rect),
                                with: .radialGradient(
                                    Gradient(colors: [
                                        Color.white.opacity(0.90),
                                        Color.white.opacity(0.12)
                                    ]),
                                    center: CGPoint(x: rect.midX, y: rect.midY),
                                    startRadius: 0,
                                    endRadius: stampWidth * 0.5
                                )
                            )
                        }
                    }
                }
            }
        }
    }

    private func previewRandom(seed: Int) -> Double {
        let x = sin(Double(seed) * 12.9898) * 43758.5453
        return x - floor(x)
    }

    private func tipShapePreview(_ tipShape: BrushTipShape) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.06))
                .frame(width: 32, height: 32)

            switch tipShape {
            case .softRound:
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.white.opacity(0.85), Color.white.opacity(0.15)],
                            center: .center,
                            startRadius: 0,
                            endRadius: 12
                        )
                    )
                    .frame(width: 20, height: 20)
            case .hardRound:
                Circle()
                    .fill(Color.white.opacity(0.8))
                    .frame(width: 20, height: 20)
            case .square:
                Rectangle()
                    .fill(Color.white.opacity(0.8))
                    .frame(width: 18, height: 18)
            case .customRound:
                brushMaskPreview(
                    maskData: viewModel.workspace.toolSession.brush.customTipMaskData,
                    frameWidth: 22,
                    frameHeight: 22,
                    fallbackBrush: viewModel.workspace.toolSession.brush
                )
            }
        }
    }

    private func brushPreviewGlyph(for brush: BrushSettings, maxExtent: Double = 52) -> some View {
        let normalizedSize = min(max(Double(brush.size) / 64.0, 0.22), 1.0)
        let baseExtent = min(maxExtent, 34.0 + (18.0 * normalizedSize))

        return ZStack {
            switch brush.tipShape {
            case .hardRound:
                Circle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: baseExtent, height: baseExtent)
            case .softRound:
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.white.opacity(0.85), Color.white.opacity(0.15)],
                            center: .center,
                            startRadius: 0,
                            endRadius: baseExtent * 0.55
                        )
                    )
                    .frame(width: baseExtent, height: baseExtent)
            case .square:
                Rectangle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: baseExtent * 0.9, height: baseExtent * 0.9)
            case .customRound:
                brushMaskPreview(
                    maskData: brush.customTipMaskData,
                    frameWidth: baseExtent,
                    frameHeight: baseExtent,
                    fallbackBrush: brush
                )
            }
        }
    }

    @ViewBuilder
    private func brushMaskPreview(
        maskData: Data?,
        frameWidth: Double,
        frameHeight: Double,
        fallbackBrush: BrushSettings
    ) -> some View {
        if let image = customTipPreviewImage(from: maskData) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: frameWidth, height: frameHeight)
                .rotationEffect(.degrees(Double(fallbackBrush.customTipAngleDegrees)))
                .scaleEffect(
                    x: CGFloat(max(Double(fallbackBrush.customTipRoundness), 0.25)),
                    y: 1
                )
        } else {
            let softness = Double(fallbackBrush.customTipSoftness)
            let hardness = Double(BrushTipShape.customRoundHardness(for: fallbackBrush.customTipSoftness))
            let roundness = max(Double(fallbackBrush.customTipRoundness), 0.25)
            let angle = Double(fallbackBrush.customTipAngleDegrees)
            Ellipse()
                .fill(
                    RadialGradient(
                        stops: [
                            .init(color: Color.white.opacity(0.85), location: 0),
                            .init(color: Color.white.opacity(0.85), location: max(0.05, hardness)),
                            .init(
                                color: Color.white.opacity(0.10),
                                location: min(1, max(0.12, hardness + max(0.08, softness * 0.4)))
                            ),
                            .init(color: Color.white.opacity(0.02), location: 1)
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: frameWidth * 0.55
                    )
                )
                .frame(width: frameWidth * roundness, height: frameHeight)
                .rotationEffect(.degrees(angle))
        }
    }

    private func customTipPreviewImage(from maskData: Data?) -> CGImage? {
        guard let maskData = resampledMaskData(maskData, targetResolution: tipMaskResolution) else {
            return nil
        }

        let bytesPerPixel = 4
        let bytesPerRow = tipMaskResolution * bytesPerPixel
        var rgba = [UInt8](repeating: 0, count: tipMaskResolution * tipMaskResolution * bytesPerPixel)

        for index in 0..<(tipMaskResolution * tipMaskResolution) {
            let alpha = maskData[index]
            let offset = index * bytesPerPixel
            rgba[offset] = 255
            rgba[offset + 1] = 255
            rgba[offset + 2] = 255
            rgba[offset + 3] = alpha
        }

        guard
            let provider = CGDataProvider(data: Data(rgba) as CFData),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else {
            return nil
        }

        return CGImage(
            width: tipMaskResolution,
            height: tipMaskResolution,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private var activeLayer: LayerRecord? {
        viewModel.workspace.document.layers.first {
            $0.id == viewModel.workspace.document.activeLayerID
        }
    }

    private var displayLayers: [LayerRecord] {
        viewModel.workspace.document.layers.reversed()
    }
}

// 色彩面板独立 View，只订阅 ColorPanelProxy
// 拖动色盘时只有这个 View 重绘，图层列表/画笔库等不受影响
private struct ColorSectionView: View {
    @ObservedObject var proxy: WorkspaceViewModel.ColorPanelProxy
    let viewModel: WorkspaceViewModel
    @State private var isColorPaletteDropTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                compactIconButton(systemImage: "arrow.triangle.2.circlepath", tooltip: "同步当前颜色到色块") {
                    viewModel.syncColorPanelFromSelectedColor()
                }
                compactIconButton(systemImage: "shuffle", tooltip: "刷新色块组合") {
                    viewModel.refreshColorPanelBlocks()
                }
                compactIconButton(systemImage: "photo.badge.plus", tooltip: "从图片提取色块") {
                    viewModel.loadColorPanelPaletteFromImage()
                }
                compactIconButton(systemImage: "arrow.counterclockwise", tooltip: "重置颜色面板") {
                    viewModel.resetColorPanel()
                }
                compactIconButton(
                    systemImage: proxy.colorPanel.mode == .picker ? "square.grid.3x3.fill" : "eyedropper.full",
                    tooltip: proxy.colorPanel.mode == .picker ? "切换到色块模式" : "切换到拾色器模式",
                    isSelected: true
                ) {
                    viewModel.toggleColorPanelMode()
                }
            }

            Group {
                if proxy.colorPanel.mode == .picker {
                    pickerStageSection
                } else {
                    blocksStageSection
                }
            }
            .frame(height: 196)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.05), lineWidth: 1)
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))

            ColorLightingHueBarView(
                hue: proxy.colorPanel.lightingHue,
                onUpdateHue: { hue in
                    var updated = proxy.colorPanel
                    updated.lightingHue = ColorBlocksEngine.wrapHue(hue)
                    proxy.colorPanel = updated
                    if updated.mode == .picker {
                        proxy.selectedColor = ColorBlocksEngine.pickerColor(from: updated)
                    }
                },
                onDragEnded: { viewModel.setColorPanelLightingHue($0) }
            )
            .frame(height: 6)

            bufferedCompactParameterSlider(
                title: "色强度",
                valueText: "\(Int(proxy.colorPanel.lightingStrength))",
                value: Double(proxy.colorPanel.lightingStrength),
                range: 0...100,
                onUpdate: { value in
                    var updated = proxy.colorPanel
                    updated.lightingStrength = Float(value)
                    proxy.colorPanel = updated
                    if updated.mode == .picker {
                        proxy.selectedColor = ColorBlocksEngine.pickerColor(from: updated)
                    }
                },
                onCommit: { viewModel.setColorPanelLightingStrength(Float($0)) }
            )
            bufferedCompactParameterSlider(
                title: "明度",
                valueText: "\(Int(proxy.colorPanel.activeLightness))",
                value: Double(proxy.colorPanel.activeLightness),
                range: 0...100,
                onUpdate: { value in
                    var updated = proxy.colorPanel
                    if updated.mode == .picker {
                        updated.pickerLightness = Float(value)
                        proxy.selectedColor = ColorBlocksEngine.pickerColor(from: updated)
                    } else {
                        updated.blocksLightness = Float(value)
                    }
                    proxy.colorPanel = updated
                },
                onCommit: { viewModel.setColorPanelLightness(Float($0)) }
            )
            bufferedCompactParameterSlider(
                title: "饱和度",
                valueText: "\(Int(proxy.colorPanel.activeSaturation))",
                value: Double(proxy.colorPanel.activeSaturation),
                range: 0...100,
                onUpdate: { value in
                    var updated = proxy.colorPanel
                    if updated.mode == .picker {
                        updated.pickerSaturation = Float(value)
                        proxy.selectedColor = ColorBlocksEngine.pickerColor(from: updated)
                    } else {
                        updated.blocksSaturation = Float(value)
                    }
                    proxy.colorPanel = updated
                },
                onCommit: { viewModel.setColorPanelSaturation(Float($0)) }
            )
            bufferedCompactParameterSlider(
                title: "对比",
                valueText: "\(Int(proxy.colorPanel.contrast))",
                value: Double(proxy.colorPanel.contrast),
                range: 0...100,
                onUpdate: { value in
                    var updated = proxy.colorPanel
                    updated.contrast = Float(value)
                    proxy.colorPanel = updated
                },
                onCommit: { viewModel.setColorPanelContrast(Float($0)) }
            )
            .opacity(proxy.colorPanel.mode == .blocks ? 1 : 0.35)
            .allowsHitTesting(proxy.colorPanel.mode == .blocks)

            bufferedCompactParameterSlider(
                title: "对比色",
                valueText: "\(Int(proxy.colorPanel.contrastHue))",
                value: Double(proxy.colorPanel.contrastHue),
                range: 0...100,
                onUpdate: { value in
                    var updated = proxy.colorPanel
                    updated.contrastHue = Float(value)
                    proxy.colorPanel = updated
                },
                onCommit: { viewModel.setColorPanelContrastHue(Float($0)) }
            )
            .opacity(proxy.colorPanel.mode == .blocks ? 1 : 0.35)
            .allowsHitTesting(proxy.colorPanel.mode == .blocks)
        }
    }

    private var pickerStageSection: some View {
        GeometryReader { geo in
            let inset = 5.0
            let hueStripWidth = 14.0
            let gap = 5.0
            let availableHeight = max(80.0, geo.size.height - inset * 2)
            let squareSize = max(80.0, min(availableHeight, geo.size.width - inset * 2 - hueStripWidth - gap))
            let stripHeight = max(80.0, squareSize - 2.0)

            HStack(spacing: gap) {
                ColorSVPickerView(
                    panel: proxy.colorPanel,
                    onUpdatePoint: { x, y in
                        // ドラッグ中は proxy だけ更新（ViewModel は触らない → 他の View は一切再描画しない）
                        var updated = proxy.colorPanel
                        updated.pickerX = x
                        updated.pickerY = y
                        let color = ColorBlocksEngine.pickerColor(from: updated)
                        proxy.colorPanel = updated
                        proxy.selectedColor = color
                    },
                    onDragEnded: { x, y in
                        // ドラッグ終了時だけ ViewModel に同期
                        viewModel.setColorPickerPoint(x: x, y: y)
                    }
                )
                .frame(width: squareSize, height: squareSize)

                ColorHueStripView(
                    hue: proxy.colorPanel.pickerHue,
                    onUpdateHue: { hue in
                        var updated = proxy.colorPanel
                        updated.pickerHue = ColorBlocksEngine.wrapHue(hue)
                        proxy.colorPanel = updated
                        proxy.selectedColor = ColorBlocksEngine.pickerColor(from: updated)
                    },
                    onDragEnded: { viewModel.setColorPickerHue($0) }
                )
                .frame(width: hueStripWidth, height: stripHeight)
            }
            .frame(width: squareSize + gap + hueStripWidth, height: squareSize, alignment: .center)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .padding(5)
    }

    private var blocksStageSection: some View {
        GeometryReader { geo in
            let inset = 5.0
            let size = max(80.0, min(geo.size.width - inset * 2, geo.size.height - inset * 2))

            ColorBlocksGridView(
                colors: ColorBlocksEngine.renderPalette(for: proxy.colorPanel),
                selectedColor: proxy.selectedColor,
                onTap: { index in
                    viewModel.setColorBlocksPanelFocused(true)
                    viewModel.selectColorBlock(at: index)
                }
            )
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isColorPaletteDropTarget ? Color.accentColor.opacity(0.9) : Color.clear, lineWidth: 2)
            )
            .contentShape(Rectangle())
            .onTapGesture { viewModel.setColorBlocksPanelFocused(true) }
            .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier], isTargeted: $isColorPaletteDropTarget) { providers in
                importColorPaletteFromDrop(providers: providers)
            }
        }
        .padding(5)
    }

    private func importColorPaletteFromDrop(providers: [NSItemProvider]) -> Bool {
        if let imageProvider = providers.first(where: { $0.canLoadObject(ofClass: NSImage.self) }) {
            imageProvider.loadObject(ofClass: NSImage.self) { object, _ in
                guard let image = object as? NSImage else { return }
                Task { @MainActor in
                    _ = viewModel.importColorPanelPalette(from: image)
                }
            }
            return true
        }

        if let fileProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            fileProvider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                switch item {
                case let data as Data:
                    url = URL(dataRepresentation: data, relativeTo: nil)
                case let nsData as NSData:
                    url = URL(dataRepresentation: nsData as Data, relativeTo: nil)
                case let fileURL as URL:
                    url = fileURL
                default:
                    url = nil
                }

                guard let url else { return }
                Task { @MainActor in
                    _ = viewModel.importColorPanelPalette(from: url)
                }
            }
            return true
        }

        return false
    }

    private func compactIconButton(
        systemImage: String,
        tooltip: String,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.98))
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isSelected ? Color.accentColor : Color.white.opacity(0.18))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(
                            isSelected ? Color.accentColor.opacity(0.95) : Color.white.opacity(0.16),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(tooltip)
    }

    private func bufferedCompactParameterSlider(
        title: String,
        valueText: String,
        value: Double,
        range: ClosedRange<Double>,
        onUpdate: @escaping (Double) -> Void,
        onCommit: @escaping (Double) -> Void
    ) -> some View {
        BufferedCompactSlider(
            title: title,
            valueText: valueText,
            value: value,
            range: range,
            onUpdate: onUpdate,
            onCommit: onCommit
        )
    }
}

private struct InspectorPanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.74))

            content
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
    }
}

private struct ColorSVPickerView: NSViewRepresentable {
    let panel: ColorPanelState
    let onUpdatePoint: (Float, Float) -> Void
    let onDragEnded: (Float, Float) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(panel: panel, onUpdatePoint: onUpdatePoint, onDragEnded: onDragEnded)
    }

    func makeNSView(context: Context) -> ColorSVPickerNSView {
        let view = ColorSVPickerNSView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: ColorSVPickerNSView, context: Context) {
        context.coordinator.panel = panel
        context.coordinator.onUpdatePoint = onUpdatePoint
        context.coordinator.onDragEnded = onDragEnded
        nsView.needsDisplay = true
    }

    final class Coordinator {
        var panel: ColorPanelState
        var onUpdatePoint: (Float, Float) -> Void
        var onDragEnded: (Float, Float) -> Void
        init(panel: ColorPanelState, onUpdatePoint: @escaping (Float, Float) -> Void, onDragEnded: @escaping (Float, Float) -> Void) {
            self.panel = panel
            self.onUpdatePoint = onUpdatePoint
            self.onDragEnded = onDragEnded
        }
    }
}

final class ColorSVPickerNSView: NSView {
    fileprivate weak var coordinator: ColorSVPickerView.Coordinator?
    private var localX: Float = 0
    private var localY: Float = 0
    private var isDragging = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        localX = Float(min(max(loc.x / max(bounds.width, 1), 0), 1))
        localY = Float(min(max(loc.y / max(bounds.height, 1), 0), 1))
        isDragging = true
        coordinator?.onUpdatePoint(localX, localY)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        localX = Float(min(max(loc.x / max(bounds.width, 1), 0), 1))
        localY = Float(min(max(loc.y / max(bounds.height, 1), 0), 1))
        coordinator?.onUpdatePoint(localX, localY)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        localX = Float(min(max(loc.x / max(bounds.width, 1), 0), 1))
        localY = Float(min(max(loc.y / max(bounds.height, 1), 0), 1))
        isDragging = false
        coordinator?.onDragEnded(localX, localY)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let coordinator else { return }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let size = max(64, Int(min(bounds.width, bounds.height) * 2))
        let panel = coordinator.panel
        if let image = colorPanelSVImage(size: size, panel: panel) {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: bounds)
            ctx.restoreGState()
        }
        // 指示圆
        let displayX = isDragging ? CGFloat(localX) : CGFloat(panel.pickerX)
        let displayY = isDragging ? CGFloat(localY) : CGFloat(panel.pickerY)
        let cx = displayX * bounds.width
        let cy = displayY * bounds.height
        let r: CGFloat = 11
        let circle = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(3)
        ctx.strokeEllipse(in: circle)
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    }
}

private struct ColorHueStripView: View {
    let hue: Float
    let onUpdateHue: (Float) -> Void
    let onDragEnded: (Float) -> Void

    @State private var localHue: Float = 0
    @State private var isDragging = false

    var body: some View {
        GeometryReader { proxy in
            let width = max(8, Int(proxy.size.width * 2))
            let height = max(64, Int(proxy.size.height * 2))
            let displayHue = isDragging ? localHue : hue

            ZStack {
                if let image = colorPanelHueImage(height: height, width: width) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                } else {
                    Color.clear
                }

                Rectangle()
                    .stroke(Color.white, lineWidth: 3)
                    .frame(width: proxy.size.width - 4, height: 12)
                    .position(
                        x: proxy.size.width / 2,
                        y: min(
                            max(CGFloat(displayHue / 360.0) * proxy.size.height, 6),
                            proxy.size.height - 6
                        )
                    )
                    .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let t = Float(min(max(value.location.y / max(proxy.size.height, 1), 0), 1))
                        let newHue = t * 360
                        isDragging = true
                        localHue = newHue
                        onUpdateHue(newHue)
                    }
                    .onEnded { value in
                        let t = Float(min(max(value.location.y / max(proxy.size.height, 1), 0), 1))
                        onDragEnded(t * 360)
                        isDragging = false
                    }
            )
        }
    }
}

private struct ColorLightingHueBarView: View {
    let hue: Float
    let onUpdateHue: (Float) -> Void
    let onDragEnded: (Float) -> Void

    @State private var localHue: Float = 0
    @State private var isDragging = false

    var body: some View {
        GeometryReader { proxy in
            let width = max(32, Int(proxy.size.width * 2))
            let height = max(4, Int(proxy.size.height * 2))
            let displayHue = isDragging ? localHue : hue

            ZStack {
                if let image = colorPanelHorizontalHueImage(width: width, height: height) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                } else {
                    Color.clear
                }

                Rectangle()
                    .stroke(Color.white, lineWidth: 3)
                    .frame(width: 12, height: max(8, proxy.size.height - 2))
                    .position(
                        x: min(
                            max(CGFloat(displayHue / 360.0) * proxy.size.width, 6),
                            proxy.size.width - 6
                        ),
                        y: proxy.size.height / 2
                    )
                    .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let t = Float(min(max(value.location.x / max(proxy.size.width, 1), 0), 1))
                        let newHue = t * 360
                        isDragging = true
                        localHue = newHue
                        onUpdateHue(newHue)
                    }
                    .onEnded { value in
                        let t = Float(min(max(value.location.x / max(proxy.size.width, 1), 0), 1))
                        onDragEnded(t * 360)
                        isDragging = false
                    }
            )
        }
    }
}

private struct BufferedCompactSlider: View {
    let title: String
    let valueText: String
    let value: Double
    let range: ClosedRange<Double>
    let onUpdate: (Double) -> Void
    let onCommit: (Double) -> Void

    @State private var localValue: Double = 0
    @State private var isEditing = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.58))
                .frame(width: 44, alignment: .leading)
            Slider(
                value: Binding(
                    get: { isEditing ? localValue : value },
                    set: { newValue in
                        localValue = newValue
                        onUpdate(newValue)
                    }
                ),
                in: range,
                onEditingChanged: { editing in
                    isEditing = editing
                    if editing {
                        localValue = value
                    } else {
                        onCommit(localValue)
                    }
                }
            )
            Text(valueText)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.88))
                .frame(width: 48, alignment: .trailing)
        }
    }
}

@MainActor
private final class ColorPanelImageCache {
    static let shared = ColorPanelImageCache()

    struct SVKey: Equatable {
        let size: Int
        let hue: Int
        let lightness: Int
        let saturation: Int
        let lightingHue: Int
        let lightingStrength: Int
    }

    struct HueKey: Equatable {
        let height: Int
        let width: Int
    }

    struct HorizontalHueKey: Equatable {
        let width: Int
        let height: Int
    }

    private var svCache: (key: SVKey, image: CGImage)?
    private var hueCache: (key: HueKey, image: CGImage)?
    private var horizontalHueCache: (key: HorizontalHueKey, image: CGImage)?

    func svImage(size: Int, panel: ColorPanelState, builder: () -> CGImage?) -> CGImage? {
        let key = SVKey(
            size: size,
            hue: Int(panel.pickerHue.rounded()),
            lightness: Int(panel.pickerLightness.rounded()),
            saturation: Int(panel.pickerSaturation.rounded()),
            lightingHue: Int(panel.lightingHue.rounded()),
            lightingStrength: Int(panel.lightingStrength.rounded())
        )
        if let svCache, svCache.key == key {
            return svCache.image
        }
        guard let image = builder() else { return nil }
        svCache = (key, image)
        return image
    }

    func hueImage(height: Int, width: Int, builder: () -> CGImage?) -> CGImage? {
        let key = HueKey(height: height, width: width)
        if let hueCache, hueCache.key == key {
            return hueCache.image
        }
        guard let image = builder() else { return nil }
        hueCache = (key, image)
        return image
    }

    func horizontalHueImage(width: Int, height: Int, builder: () -> CGImage?) -> CGImage? {
        let key = HorizontalHueKey(width: width, height: height)
        if let horizontalHueCache, horizontalHueCache.key == key {
            return horizontalHueCache.image
        }
        guard let image = builder() else { return nil }
        horizontalHueCache = (key, image)
        return image
    }
}

private struct ColorBlocksGridView: View {
    let colors: [RGBAColor]
    let selectedColor: RGBAColor
    let onTap: (Int) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 5)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 0) {
            ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
                Button {
                    onTap(index)
                } label: {
                    Rectangle()
                        .fill(Color(
                            red: Double(color.red),
                            green: Double(color.green),
                            blue: Double(color.blue),
                            opacity: 1
                        ))
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            Rectangle()
                                .stroke(
                                    isSameColor(color, selectedColor) ? Color.white : Color.clear,
                                    lineWidth: 2
                                )
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func isSameColor(_ lhs: RGBAColor, _ rhs: RGBAColor) -> Bool {
        abs(lhs.red - rhs.red) < 0.002 &&
        abs(lhs.green - rhs.green) < 0.002 &&
        abs(lhs.blue - rhs.blue) < 0.002
    }
}

@MainActor
private func colorPanelSVImage(size: Int, panel: ColorPanelState) -> CGImage? {
    ColorPanelImageCache.shared.svImage(size: size, panel: panel) {
        let bytesPerPixel = 4
        let bytesPerRow = size * bytesPerPixel
        var rgba = [UInt8](repeating: 0, count: size * size * bytesPerPixel)

        for y in 0..<size {
            for x in 0..<size {
                let pointX = Float(x) / Float(max(size - 1, 1))
                let pointY = Float(y) / Float(max(size - 1, 1))
                var state = panel
                state.pickerX = pointX
                state.pickerY = pointY
                let color = ColorBlocksEngine.pickerColor(from: state)
                let offset = ((y * size) + x) * bytesPerPixel
                rgba[offset] = UInt8(clamping: Int((color.red * 255).rounded()))
                rgba[offset + 1] = UInt8(clamping: Int((color.green * 255).rounded()))
                rgba[offset + 2] = UInt8(clamping: Int((color.blue * 255).rounded()))
                rgba[offset + 3] = 255
            }
        }

        return makeColorPanelImage(
            rgba: rgba,
            width: size,
            height: size,
            bytesPerRow: bytesPerRow
        )
    }
}

@MainActor
private func colorPanelHueImage(height: Int, width: Int) -> CGImage? {
    ColorPanelImageCache.shared.hueImage(height: height, width: width) {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var rgba = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        for y in 0..<height {
            let hue = (Float(y) / Float(max(height - 1, 1))) * 360
            let color = ColorBlocksEngine.hsvToRgb(HSVColor(h: hue, s: 1, v: 1))
            for x in 0..<width {
                let offset = ((y * width) + x) * bytesPerPixel
                rgba[offset] = UInt8(clamping: Int((color.red * 255).rounded()))
                rgba[offset + 1] = UInt8(clamping: Int((color.green * 255).rounded()))
                rgba[offset + 2] = UInt8(clamping: Int((color.blue * 255).rounded()))
                rgba[offset + 3] = 255
            }
        }

        return makeColorPanelImage(
            rgba: rgba,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        )
    }
}

@MainActor
private func colorPanelHorizontalHueImage(width: Int, height: Int) -> CGImage? {
    ColorPanelImageCache.shared.horizontalHueImage(width: width, height: height) {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var rgba = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        for x in 0..<width {
            let hue = (Float(x) / Float(max(width - 1, 1))) * 360
            let color = ColorBlocksEngine.hsvToRgb(HSVColor(h: hue, s: 1, v: 1))
            for y in 0..<height {
                let offset = ((y * width) + x) * bytesPerPixel
                rgba[offset] = UInt8(clamping: Int((color.red * 255).rounded()))
                rgba[offset + 1] = UInt8(clamping: Int((color.green * 255).rounded()))
                rgba[offset + 2] = UInt8(clamping: Int((color.blue * 255).rounded()))
                rgba[offset + 3] = 255
            }
        }

        return makeColorPanelImage(
            rgba: rgba,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        )
    }
}

private func makeColorPanelImage(
    rgba: [UInt8],
    width: Int,
    height: Int,
    bytesPerRow: Int
) -> CGImage? {
    guard
        let provider = CGDataProvider(data: Data(rgba) as CFData),
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    else {
        return nil
    }

    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: true,
        intent: .defaultIntent
    )
}

private enum TipPaintMode {
    case round
    case square
    case eraser
}

private struct TipMaskCanvasView: NSViewRepresentable {
    let maskData: Data?
    let fitImportedPreview: Bool
    let paintMode: TipPaintMode
    let softness: Float
    let intensity: Float
    let brushSize: Float
    let onFocusChanged: (Bool) -> Void
    let onImportImage: (NSImage) -> Void
    let onUpdateMask: (Data) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFocusChanged: onFocusChanged, onImportImage: onImportImage, onUpdateMask: onUpdateMask)
    }

    func makeNSView(context: Context) -> TipMaskEditorNSView {
        let view = TipMaskEditorNSView()
        view.coordinator = context.coordinator
        view.update(
            maskData: maskData,
            fitImportedPreview: fitImportedPreview,
            paintMode: paintMode,
            softness: softness,
            intensity: intensity,
            brushSize: brushSize
        )
        return view
    }

    func updateNSView(_ nsView: TipMaskEditorNSView, context: Context) {
        nsView.coordinator = context.coordinator
        nsView.update(
            maskData: maskData,
            fitImportedPreview: fitImportedPreview,
            paintMode: paintMode,
            softness: softness,
            intensity: intensity,
            brushSize: brushSize
        )
    }

    final class Coordinator: NSObject {
        let onFocusChanged: (Bool) -> Void
        let onImportImage: (NSImage) -> Void
        let onUpdateMask: (Data) -> Void

        init(
            onFocusChanged: @escaping (Bool) -> Void,
            onImportImage: @escaping (NSImage) -> Void,
            onUpdateMask: @escaping (Data) -> Void
        ) {
            self.onFocusChanged = onFocusChanged
            self.onImportImage = onImportImage
            self.onUpdateMask = onUpdateMask
        }
    }
}

private final class TipMaskEditorNSView: NSView {
    weak var coordinator: TipMaskCanvasView.Coordinator?

    private var maskBytes = [UInt8](repeating: 0, count: tipMaskResolution * tipMaskResolution)
    private var paintMode: TipPaintMode = .round
    private var softness: Float = 0.35
    private var intensity: Float = 1
    private var brushSize: Float = 24
    private var fitImportedPreview = false
    private var lastPaintPoint: CGPoint?
    private var hoverLocation: CGPoint?
    private var hasLocalChanges = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        registerForDraggedTypes([.fileURL, .tiff, .png])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        maskData: Data?,
        fitImportedPreview: Bool,
        paintMode: TipPaintMode,
        softness: Float,
        intensity: Float,
        brushSize: Float
    ) {
        self.paintMode = paintMode
        self.softness = softness
        self.intensity = intensity
        self.brushSize = brushSize

        if !hasLocalChanges {
            self.fitImportedPreview = fitImportedPreview
            let nextMask = normalizedMaskData(maskData)
            if nextMask != maskBytes {
                maskBytes = nextMask
                needsDisplay = true
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if let image = makePreviewImage(from: Data(maskBytes)) {
            let previewImage = fitImportedPreview
                ? (croppedPreviewImage(image, from: maskBytes) ?? image)
                : image
            let drawRect = previewDrawRect(for: previewImage)
            context.saveGState()
            context.interpolationQuality = .high
            context.translateBy(x: drawRect.minX, y: drawRect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(previewImage, in: CGRect(origin: .zero, size: drawRect.size))
            context.restoreGState()
        }

        if let hoverLocation {
            let diameter = indicatorDiameter(in: bounds.size)
            let circleRect = CGRect(
                x: hoverLocation.x - (diameter / 2),
                y: hoverLocation.y - (diameter / 2),
                width: diameter,
                height: diameter
            )
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.28).cgColor)
            context.setLineWidth(1)
            context.strokeEllipse(in: circleRect)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        coordinator?.onFocusChanged(true)
        let point = convert(event.locationInWindow, from: nil)
        hoverLocation = point
        lastPaintPoint = point
        hasLocalChanges = true
        fitImportedPreview = false
        paintSegment(from: point, to: point)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoverLocation = point
        paintSegment(from: lastPaintPoint ?? point, to: point)
        lastPaintPoint = point
    }

    override func mouseUp(with event: NSEvent) {
        hoverLocation = convert(event.locationInWindow, from: nil)
        lastPaintPoint = nil
        if hasLocalChanges {
            coordinator?.onUpdateMask(Data(maskBytes))
            hasLocalChanges = false
        }
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        hoverLocation = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        hoverLocation = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoverLocation = nil
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control])
        if modifiers.isEmpty == false,
           event.charactersIgnoringModifiers?.lowercased() == "v",
           importImageFromPasteboard(NSPasteboard.general) {
            return
        }
        super.keyDown(with: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        importableImage(from: sender.draggingPasteboard) == nil ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        importableImage(from: sender.draggingPasteboard) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let image = importableImage(from: sender.draggingPasteboard) else { return false }
        coordinator?.onImportImage(image)
        return true
    }

    private func paintSegment(from start: CGPoint, to end: CGPoint) {
        let radius = currentRadius()
        let step = max(radius * 0.35, 1)
        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = sqrt((dx * dx) + (dy * dy))
        let steps = max(Int((distance / step).rounded()), 1)

        for index in 0...steps {
            let t = CGFloat(index) / CGFloat(steps)
            let point = CGPoint(
                x: start.x + (dx * t),
                y: start.y + (dy * t)
            )
            paintStamp(at: point, radius: radius)
        }

        needsDisplay = true
    }

    private func paintStamp(at location: CGPoint, radius: Double) {
        let editableRect = previewDrawRect(for: nil)
        guard editableRect.width > 0, editableRect.height > 0 else { return }

        let normalizedX = min(max((location.x - editableRect.minX) / editableRect.width, 0), 1)
        let normalizedY = min(max((location.y - editableRect.minY) / editableRect.height, 0), 1)
        let centerX = Int((normalizedX * CGFloat(tipMaskResolution - 1)).rounded())
        let centerY = Int((normalizedY * CGFloat(tipMaskResolution - 1)).rounded())

        let minX = max(0, Int(Double(centerX) - radius - 1))
        let maxX = min(tipMaskResolution - 1, Int(Double(centerX) + radius + 1))
        let minY = max(0, Int(Double(centerY) - radius - 1))
        let maxY = min(tipMaskResolution - 1, Int(Double(centerY) + radius + 1))

        guard minX <= maxX, minY <= maxY else {
            return
        }

        for y in minY...maxY {
            for x in minX...maxX {
                let dx = Double(x - centerX)
                let dy = Double(y - centerY)

                let alpha: Double
                switch paintMode {
                case .round:
                    let distance = sqrt((dx * dx) + (dy * dy))
                    guard distance <= radius else { continue }
                    let normalized = distance / radius
                    let softnessValue = min(max(Double(softness), 0.0), 1.0)
                    if softnessValue <= 0.01 {
                        alpha = 1
                    } else {
                        let feather = max(0.08, softnessValue)
                        let core = max(0.0, 1.0 - feather)
                        if normalized <= core {
                            alpha = 1
                        } else {
                            let fade = max(0.0, 1.0 - ((normalized - core) / feather))
                            let exponent = 0.9 + ((1.0 - softnessValue) * 1.6)
                            alpha = pow(fade, exponent)
                        }
                    }
                case .square:
                    guard abs(dx) <= radius, abs(dy) <= radius else { continue }
                    alpha = 1
                case .eraser:
                    let distance = sqrt((dx * dx) + (dy * dy))
                    guard distance <= radius else { continue }
                    let normalized = distance / radius
                    let softnessValue = min(max(Double(softness), 0.0), 1.0)
                    if softnessValue <= 0.01 {
                        alpha = 1
                    } else {
                        let feather = max(0.08, softnessValue)
                        let core = max(0.0, 1.0 - feather)
                        if normalized <= core {
                            alpha = 1
                        } else {
                            let fade = max(0.0, 1.0 - ((normalized - core) / feather))
                            let exponent = 0.9 + ((1.0 - softnessValue) * 1.6)
                            alpha = pow(fade, exponent)
                        }
                    }
                }

                let intensityScale = min(max(Double(intensity), 0.0), 1.0)
                let scaledAlpha = alpha * intensityScale
                let index = (y * tipMaskResolution) + x
                let value = UInt8(clamping: Int((scaledAlpha * 255).rounded()))
                switch paintMode {
                case .eraser:
                    maskBytes[index] = UInt8(max(0, Int(maskBytes[index]) - Int(value)))
                default:
                    maskBytes[index] = max(maskBytes[index], value)
                }
            }
        }
    }

    private func currentRadius() -> Double {
        min(max(Double(brushSize) * 0.4, 3.0), 28.0)
    }

    private func indicatorDiameter(in size: CGSize) -> CGFloat {
        let editableRect = previewDrawRect(for: nil)
        return CGFloat(currentRadius() * 2) * (editableRect.width / CGFloat(tipMaskResolution))
    }

    private func normalizedMaskData(_ data: Data?) -> [UInt8] {
        guard let data = resampledMaskData(data, targetResolution: tipMaskResolution) else {
            return [UInt8](repeating: 0, count: tipMaskResolution * tipMaskResolution)
        }
        return [UInt8](data)
    }

    private func makePreviewImage(from mask: Data) -> CGImage? {
        let bytesPerPixel = 4
        let bytesPerRow = tipMaskResolution * bytesPerPixel
        var rgba = [UInt8](repeating: 255, count: tipMaskResolution * tipMaskResolution * bytesPerPixel)

        for index in 0..<(tipMaskResolution * tipMaskResolution) {
            let alpha = 255 - mask[index]
            let offset = index * bytesPerPixel
            rgba[offset] = alpha
            rgba[offset + 1] = alpha
            rgba[offset + 2] = alpha
            rgba[offset + 3] = 255
        }

        guard
            let provider = CGDataProvider(data: Data(rgba) as CFData),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else {
            return nil
        }

        return CGImage(
            width: tipMaskResolution,
            height: tipMaskResolution,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func croppedPreviewImage(_ image: CGImage, from mask: [UInt8]) -> CGImage? {
        guard let bounds = maskContentBounds(mask) else { return image }
        return image.cropping(to: bounds)
    }

    private func maskContentBounds(_ mask: [UInt8]) -> CGRect? {
        var minX = tipMaskResolution
        var minY = tipMaskResolution
        var maxX = -1
        var maxY = -1

        for y in 0..<tipMaskResolution {
            for x in 0..<tipMaskResolution {
                if mask[(y * tipMaskResolution) + x] > 0 {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }

        guard maxX >= minX, maxY >= minY else { return nil }
        let inset = 2
        let originX = max(0, minX - inset)
        let originY = max(0, minY - inset)
        let width = min(tipMaskResolution - originX, (maxX - minX + 1) + (inset * 2))
        let height = min(tipMaskResolution - originY, (maxY - minY + 1) + (inset * 2))
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    private func aspectFitRect(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let fittedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: bounds.midX - (fittedSize.width / 2),
            y: bounds.midY - (fittedSize.height / 2),
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    private func previewDrawRect(for image: CGImage?) -> CGRect {
        let imageRect = bounds.insetBy(dx: 10, dy: 10)
        let imageSize: CGSize
        if let image {
            imageSize = CGSize(width: image.width, height: image.height)
        } else {
            imageSize = CGSize(width: tipMaskResolution, height: tipMaskResolution)
        }
        return aspectFitRect(imageSize: imageSize, in: imageRect)
    }

    private func importImageFromPasteboard(_ pasteboard: NSPasteboard) -> Bool {
        guard let image = importableImage(from: pasteboard) else {
            return false
        }
        coordinator?.onImportImage(image)
        return true
    }

    private func importableImage(from pasteboard: NSPasteboard) -> NSImage? {
        if let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage {
            return image
        }

        if let item = pasteboard.pasteboardItems?.first {
            for type in [NSPasteboard.PasteboardType.png, .tiff] {
                if let data = item.data(forType: type), let image = NSImage(data: data) {
                    return image
                }
            }

            if let data = item.data(forType: .fileURL),
               let url = URL(dataRepresentation: data, relativeTo: nil),
               let image = NSImage(contentsOf: url) {
                return image
            }
        }

        return nil
    }
}

private func resampledMaskData(_ data: Data?, targetResolution: Int) -> Data? {
    guard let data else { return nil }
    let side = Int(Double(data.count).squareRoot())
    guard side > 0, side * side == data.count else { return nil }

    if side == targetResolution {
        return data
    }

    let source = [UInt8](data)
    var destination = [UInt8](repeating: 0, count: targetResolution * targetResolution)

    for y in 0..<targetResolution {
        let sourceY = min(Int((Double(y) / Double(targetResolution)) * Double(side)), side - 1)
        for x in 0..<targetResolution {
            let sourceX = min(Int((Double(x) / Double(targetResolution)) * Double(side)), side - 1)
            destination[(y * targetResolution) + x] = source[(sourceY * side) + sourceX]
        }
    }

    return Data(destination)
}

private struct PressureCurvePreview: View {
    let low: Double
    let mid: Double
    let high: Double

    var body: some View {
        GeometryReader { proxy in
            let rect = proxy.frame(in: .local)

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.06))

                Path { path in
                    path.move(to: CGPoint(x: 10, y: rect.height - 10))
                    path.addLine(to: CGPoint(x: rect.width - 10, y: 10))
                }
                .stroke(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                Path { path in
                    let points = [
                        CGPoint(x: 10, y: rect.height - 10),
                        CGPoint(x: rect.width * 0.25, y: (rect.height - 10) - ((rect.height - 20) * low)),
                        CGPoint(x: rect.width * 0.5, y: (rect.height - 10) - ((rect.height - 20) * mid)),
                        CGPoint(x: rect.width * 0.75, y: (rect.height - 10) - ((rect.height - 20) * high)),
                        CGPoint(x: rect.width - 10, y: 10)
                    ]

                    path.move(to: points[0])
                    path.addCurve(to: points[2], control1: points[1], control2: points[1])
                    path.addCurve(to: points[4], control1: points[3], control2: points[3])
                }
                .stroke(Color.accentColor, lineWidth: 2.5)
            }
        }
    }
}

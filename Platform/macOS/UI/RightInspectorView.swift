import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let tipMaskResolution = 256

struct RightInspectorView: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    @State private var showsPressureCurveEditor = false
    @State private var showsPressureSizeCurveEditor = false
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

            compactParameterSlider(
                title: "间距",
                valueText: "\(Int(viewModel.workspace.toolSession.brush.spacingPercent))%",
                value: Binding(
                    get: { Double(viewModel.workspace.toolSession.brush.spacingPercent) },
                    set: { viewModel.setBrushSpacingPercent(Float($0)) }
                ),
                range: 5...150
            )

            compactParameterSlider(
                title: "散布",
                valueText: String(format: "%.1fx", viewModel.workspace.toolSession.brush.scatterAmount),
                value: Binding(
                    get: { Double(viewModel.workspace.toolSession.brush.scatterAmount) },
                    set: { viewModel.setBrushScatterAmount(Float($0)) }
                ),
                range: 0...5
            )

            compactParameterSlider(
                title: "旋转",
                valueText: "\(Int(viewModel.workspace.toolSession.brush.stampRotationDegrees))°",
                value: Binding(
                    get: { Double(viewModel.workspace.toolSession.brush.stampRotationDegrees) },
                    set: { viewModel.setBrushStampRotationDegrees(Float($0)) }
                ),
                range: 0...360
            )

            compactParameterSlider(
                title: "抖动",
                valueText: "\(Int(viewModel.workspace.toolSession.brush.jitterAmount * 100))%",
                value: Binding(
                    get: { Double(viewModel.workspace.toolSession.brush.jitterAmount) },
                    set: { viewModel.setBrushJitterAmount(Float($0)) }
                ),
                range: 0...1
            )

            compactParameterSlider(
                title: "杂色",
                valueText: "\(Int(viewModel.workspace.toolSession.brush.colorJitterAmount * 100))%",
                value: Binding(
                    get: { Double(viewModel.workspace.toolSession.brush.colorJitterAmount) },
                    set: { viewModel.setBrushColorJitterAmount(Float($0)) }
                ),
                range: 0...1
            )

            compactParameterSlider(
                title: "压感",
                valueText: String(format: "%.1f", viewModel.workspace.toolSession.brush.pressureSensitivity),
                value: Binding(
                    get: { Double(viewModel.workspace.toolSession.brush.pressureSensitivity) },
                    set: { viewModel.setPressureSensitivity(Float($0)) }
                ),
                range: 0...2
            )

            compactParameterSlider(
                title: "尺寸下限",
                valueText: "\(Int(viewModel.workspace.toolSession.brush.sizeLowerBound * 100))%",
                value: Binding(
                    get: { Double(viewModel.workspace.toolSession.brush.sizeLowerBound) },
                    set: { viewModel.setSizeLowerBound(Float($0)) }
                ),
                range: 0...1
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

            inspectorLabeledSlider(
                title: "轻压",
                valueText: "\(Int(viewModel.workspace.toolSession.brush.sizeCurveLow * 100))%",
                value: Binding(
                    get: { Double(viewModel.workspace.toolSession.brush.sizeCurveLow) },
                    set: { viewModel.setSizeCurveLow(Float($0)) }
                ),
                range: 0...0.85
            )

            inspectorLabeledSlider(
                title: "中压",
                valueText: "\(Int(viewModel.workspace.toolSession.brush.sizeCurveMid * 100))%",
                value: Binding(
                    get: { Double(viewModel.workspace.toolSession.brush.sizeCurveMid) },
                    set: { viewModel.setSizeCurveMid(Float($0)) }
                ),
                range: 0...0.95
            )

            inspectorLabeledSlider(
                title: "高压",
                valueText: "\(Int(viewModel.workspace.toolSession.brush.sizeCurveHigh * 100))%",
                value: Binding(
                    get: { Double(viewModel.workspace.toolSession.brush.sizeCurveHigh) },
                    set: { viewModel.setSizeCurveHigh(Float($0)) }
                ),
                range: 0...1
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

            inspectorLabeledSlider(
                title: "轻压",
                valueText: "\(Int(viewModel.workspace.toolSession.brush.opacityCurveLow * 100))%",
                value: Binding(
                    get: { Double(viewModel.workspace.toolSession.brush.opacityCurveLow) },
                    set: { viewModel.setOpacityCurveLow(Float($0)) }
                ),
                range: 0...0.85
            )

            inspectorLabeledSlider(
                title: "中压",
                valueText: "\(Int(viewModel.workspace.toolSession.brush.opacityCurveMid * 100))%",
                value: Binding(
                    get: { Double(viewModel.workspace.toolSession.brush.opacityCurveMid) },
                    set: { viewModel.setOpacityCurveMid(Float($0)) }
                ),
                range: 0...0.95
            )

            inspectorLabeledSlider(
                title: "高压",
                valueText: "\(Int(viewModel.workspace.toolSession.brush.opacityCurveHigh * 100))%",
                value: Binding(
                    get: { Double(viewModel.workspace.toolSession.brush.opacityCurveHigh) },
                    set: { viewModel.setOpacityCurveHigh(Float($0)) }
                ),
                range: 0...1
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
                inspectorLabeledSlider(
                    title: "不透明度",
                    valueText: "\(Int(activeLayer.opacity * 100))%",
                    value: Binding(
                        get: { Double(activeLayer.opacity) },
                        set: { viewModel.setActiveLayerOpacity(Float($0)) }
                    ),
                    range: 0...1,
                    onEditingChanged: { isEditing in
                        if isEditing {
                            viewModel.beginActiveLayerOpacityChange()
                        } else {
                            viewModel.endActiveLayerOpacityChange()
                        }
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
            }

            compactParameterSlider(
                title: "柔边",
                valueText: "\(Int(tipPaintSoftness * 100))%",
                value: Binding(
                    get: { tipPaintSoftness },
                    set: { tipPaintSoftness = $0 }
                ),
                range: 0...1
            )

            compactParameterSlider(
                title: "灰度",
                valueText: "\(Int(tipPaintIntensity * 100))%",
                value: Binding(
                    get: { tipPaintIntensity },
                    set: { tipPaintIntensity = $0 }
                ),
                range: 0.1...1
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

        return Button {
            viewModel.applyBrushPreset(preset.id)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.white.opacity(0.03))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                isSelected ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.06),
                                lineWidth: isSelected ? 1.5 : 1
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

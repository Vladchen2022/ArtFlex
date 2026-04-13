import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let tipMaskResolution = 256
private let topInspectorPanelHeight: CGFloat = 264
private let collapsedReferenceInspectorHeight: CGFloat = 214
private let topInspectorSectionSpacing: CGFloat = 10
private let topInspectorControlSpacing: CGFloat = 6
private let topInspectorControlButtonWidth: CGFloat = 24
private let topInspectorControlButtonHeight: CGFloat = 22
private let topInspectorControlCornerRadius: CGFloat = 7
private let topInspectorControlIconSize: CGFloat = 11.5

private enum TipImageLibrarySheetTarget: String, Identifiable {
    case primary
    case compoundSecondary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .primary:
            return "主笔尖图片资料库"
        case .compoundSecondary:
            return "组合笔刷次笔尖图片资料库"
        }
    }
}

struct RightInspectorView: View {
    private enum LeftInspectorTab: String {
        case generator = "图形生成器"
        case referenceImages = "参考图"
    }

    private enum TopInspectorTab: String {
        case tipShape = "笔尖形状设计"
        case navigator = "导航器"
    }

    @ObservedObject var viewModel: WorkspaceViewModel
    @State private var showsPressureCurveEditor = false
    @State private var showsPressureSizeCurveEditor = false
    @State private var tipPaintMode: TipPaintMode = .round
    @State private var presetShapeIndex = 0
    @State private var sprayPatternIndex = 0
    @State private var draggedBrushPresetID: String?
    @State private var draggedLayerID: LayerID?
    @State private var editingLayerID: LayerID?
    @State private var editingLayerName = ""
    @State private var showsLayerOpacityPopover = false
    @State private var layerDropInsertionIndex: Int?
    @FocusState private var focusedLayerNameFieldID: LayerID?
    @State private var isTipImageDropTarget = false
    @State private var isColorPaletteDropTarget = false
    @State private var highlightsPrimaryTipEditor = false
    @State private var primaryTipEditorHighlightGeneration = 0
    @State private var tipImageLibrarySheetTarget: TipImageLibrarySheetTarget?
    @State private var primaryTipImageLibraryPendingSelection: BrushTipImageAssetID?
    @State private var compoundSecondaryTipImageLibraryPendingSelection: BrushTipImageAssetID?
    @State private var draggedTipImageLibraryAssetID: BrushTipImageAssetID?
    @State private var tipImageLibraryDropTargetID: BrushTipImageAssetID?
    @State private var showsCompoundBrushBuilder = false
    @State private var leftInspectorTab: LeftInspectorTab = .referenceImages
    @State private var topInspectorTab: TopInspectorTab = .navigator
    @State private var navigatorZoomPercentText = "100"
    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 12) {
                        generatorReferencePanel()

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
                        tipNavigatorPanel
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
        .onAppear {
            syncNavigatorZoomPercentText()
        }
        .onChange(of: viewModel.workspace.viewport.zoomScale) { _, _ in
            syncNavigatorZoomPercentText()
        }
        .sheet(item: $tipImageLibrarySheetTarget) { target in
            tipImageLibrarySheet(for: target) {
                tipImageLibrarySheetTarget = nil
            }
        }
        .sheet(isPresented: $showsCompoundBrushBuilder) {
            CompoundBrushBuilderSheet(viewModel: viewModel)
        }
    }

    private var generatorSection: some View {
        let generator = viewModel.workspace.creativeShapeGenerator
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                generatorSourceButton(
                    title: CreativeShapeGeneratorColorSource.currentColor.title,
                    isSelected: generator.selectedSource == .currentColor
                ) {
                    viewModel.selectCreativeShapeGeneratorSource(.currentColor)
                }

                generatorSourceButton(
                    title: CreativeShapeGeneratorColorSource.paletteBlocks.title,
                    isSelected: generator.selectedSource == .paletteBlocks
                ) {
                    viewModel.selectCreativeShapeGeneratorSource(.paletteBlocks)
                }

                creativeShapeGeneratorExternalImageButton
            }

            Divider()
                .overlay(Color.white.opacity(0.08))

            OptimizedCompactSlider(
                title: "羽化概率",
                valueText: "\(Int(generator.featherProbability * 100))%",
                value: Binding(
                    get: { Double(generator.featherProbability) },
                    set: { _ in }
                ),
                range: 0...1,
                onCommit: { viewModel.setCreativeShapeGeneratorFeatherProbability(Float($0)) }
            )

            OptimizedCompactSlider(
                title: "形状特征",
                valueText: "\(Int(generator.shapeCharacteristic * 100))%",
                value: Binding(
                    get: { Double(generator.shapeCharacteristic) },
                    set: { _ in }
                ),
                range: 0...1,
                onCommit: { viewModel.setCreativeShapeGeneratorShapeCharacteristic(Float($0)) }
            )

            OptimizedCompactSlider(
                title: "形状大小",
                valueText: "\(Int(generator.shapeSize * 100))%",
                value: Binding(
                    get: { Double(generator.shapeSize) },
                    set: { _ in }
                ),
                range: 0...1,
                onCommit: { viewModel.setCreativeShapeGeneratorShapeSize(Float($0)) }
            )

            OptimizedCompactSlider(
                title: "形状抖动",
                valueText: "\(Int(generator.shapeJitter * 100))%",
                value: Binding(
                    get: { Double(generator.shapeJitter) },
                    set: { _ in }
                ),
                range: 0...1,
                onCommit: { viewModel.setCreativeShapeGeneratorShapeJitter(Float($0)) }
            )

            OptimizedCompactSlider(
                title: "色彩抖动",
                valueText: "\(Int(generator.colorJitter * 100))%",
                value: Binding(
                    get: { Double(generator.colorJitter) },
                    set: { _ in }
                ),
                range: 0...1,
                onCommit: { viewModel.setCreativeShapeGeneratorColorJitter(Float($0)) }
            )

            HStack(spacing: 8) {
                Text("笔尖图形模式")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.82))

                Spacer(minLength: 8)

                Toggle(
                    "",
                    isOn: Binding(
                        get: { generator.usesTipImageShapes },
                        set: { viewModel.setCreativeShapeGeneratorUsesTipImageShapes($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .scaleEffect(0.82, anchor: .trailing)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func generatorReferencePanel() -> some View {
        let hasLoadedReferenceImage = viewModel.referenceImageSlots.contains { $0.asset != nil }
        let resolvedFixedHeight: CGFloat?
        if leftInspectorTab == .generator {
            resolvedFixedHeight = nil
        } else if !hasLoadedReferenceImage {
            resolvedFixedHeight = collapsedReferenceInspectorHeight
        } else {
            resolvedFixedHeight = topInspectorPanelHeight
        }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                leftInspectorTabButton(.generator)
                leftInspectorTabButton(.referenceImages)
            }

            Group {
                if leftInspectorTab == .generator {
                    generatorSection
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                } else {
                    referenceImageSection
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: resolvedFixedHeight, maxHeight: resolvedFixedHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
    }

    private func leftInspectorTabButton(_ tab: LeftInspectorTab) -> some View {
        let isSelected = leftInspectorTab == tab
        return Button {
            leftInspectorTab = tab
        } label: {
            Text(tab.rawValue)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.white.opacity(isSelected ? 0.96 : 0.72))
                .frame(maxWidth: .infinity, minHeight: 28)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected ? Color.accentColor.opacity(0.24) : Color.white.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            isSelected ? Color.accentColor.opacity(0.86) : Color.white.opacity(0.08),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private var referenceImageSection: some View {
        let hasLoadedReferenceImage = viewModel.referenceImageSlots.contains { $0.asset != nil }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(viewModel.referenceImageSlots) { slot in
                    referenceImageSlotButton(slot)
                }
            }

            referenceImagePreviewArea(hasLoadedReferenceImage: hasLoadedReferenceImage)

            HStack(spacing: 10) {
                Button {
                    viewModel.openReferenceImageFloatingPanel()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.white.opacity(viewModel.selectedReferenceImageSlot?.asset == nil ? 0.42 : 0.92))
                        .frame(width: 30, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white.opacity(0.10))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.selectedReferenceImageSlot?.asset == nil)
                .help("放大参考图")

                Button {
                    viewModel.toggleCanvasLuminosityReference()
                } label: {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.white.opacity(viewModel.isCanvasLuminosityReferenceActive ? 0.98 : 0.86))
                        .frame(width: 30, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(viewModel.isCanvasLuminosityReferenceActive ? Color.accentColor.opacity(0.92) : Color.white.opacity(0.10))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(
                                    viewModel.isCanvasLuminosityReferenceActive ? Color.accentColor.opacity(0.90) : Color.white.opacity(0.08),
                                    lineWidth: 1
                                )
                        )
                }
                .buttonStyle(.plain)
                .help("黑白模式 (LAB L通道)")

                referenceImagePickedColorSwatch

                Button {
                    viewModel.clearSelectedReferenceImage()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.white.opacity(viewModel.selectedReferenceImageSlot?.asset == nil ? 0.42 : 0.92))
                        .frame(width: 30, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white.opacity(0.10))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.selectedReferenceImageSlot?.asset == nil)
                .help("清除当前参考图")
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear {
            viewModel.setReferenceImageInspectorVisible(true)
        }
        .onDisappear {
            viewModel.setReferenceImageInspectorVisible(false)
        }
    }

    private var referenceImagePickedColorSwatch: some View {
        ZStack {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(viewModel.referenceImagePreviousSwiftUIColor)
                Rectangle()
                    .fill(viewModel.referenceImagePreviewSwiftUIColor)
            }

            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 1)
        }
        .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .help("左侧为上一次确认颜色，右侧为当前预览/选择颜色")
    }

    private func referenceImagePreviewArea(hasLoadedReferenceImage: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.20))

            ReferenceImageViewer(
                asset: viewModel.selectedReferenceImageSlot?.asset,
                backgroundColor: NSColor(calibratedWhite: 0.08, alpha: 1),
                onHoverColorChanged: { color in
                    viewModel.updateReferenceImagePreviewColor(color)
                },
                onPickColor: { color in
                    viewModel.confirmReferenceImagePickedColor(color)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if viewModel.selectedReferenceImageSlot?.asset == nil {
                Text(viewModel.referenceImageLoadingSlotID != nil ? "载入中…" : "点击 1 - 5 载入参考图")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.52))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: hasLoadedReferenceImage ? 232 : 56)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func referenceImageSlotButton(_ slot: ReferenceImageSlotState) -> some View {
        let isSelected = viewModel.selectedReferenceImageSlotID == slot.id
        let isLoading = viewModel.referenceImageLoadingSlotID == slot.id
        let isLoaded = slot.asset != nil

        return Button {
            viewModel.activateReferenceImageSlot(slot.id)
        } label: {
            Group {
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white.opacity(0.82))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text(slot.labelText)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.white.opacity(isLoaded ? 0.96 : 0.62))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        isSelected ? Color.accentColor.opacity(0.20) :
                            (isLoaded ? Color.white.opacity(0.10) : Color.white.opacity(0.05))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.90) :
                            (isLoaded ? Color.white.opacity(0.14) : Color.white.opacity(0.08)),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if isLoaded {
                Button("清除") {
                    viewModel.clearReferenceImageSlot(slot.id)
                }
            }
        }
    }

    private var tipNavigatorPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                topInspectorTabButton(.tipShape)
                topInspectorTabButton(.navigator)
            }

            Group {
                if topInspectorTab == .tipShape {
                    tipShapeSection
                } else {
                    navigatorSection
                }
            }
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

    private func topInspectorTabButton(_ tab: TopInspectorTab) -> some View {
        let isSelected = topInspectorTab == tab
        return Button {
            topInspectorTab = tab
        } label: {
            Text(tab.rawValue)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.white.opacity(isSelected ? 0.96 : 0.72))
                .frame(maxWidth: .infinity, minHeight: 28)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected ? Color.accentColor.opacity(0.24) : Color.white.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            isSelected ? Color.accentColor.opacity(0.86) : Color.white.opacity(0.08),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private var navigatorSection: some View {
        VStack(alignment: .leading, spacing: topInspectorSectionSpacing) {
            NavigatorPreviewContainer(
                proxy: viewModel.navigatorPreviewProxy,
                viewModel: viewModel,
                visibleCanvasPolygon: viewModel.navigatorVisibleCanvasPolygon(),
                canvasSize: viewModel.workspace.document.canvasSize
            )
            .onAppear {
                viewModel.setNavigatorPreviewVisible(true)
            }
            .onDisappear {
                viewModel.setNavigatorPreviewVisible(false)
            }

            HStack(spacing: topInspectorControlSpacing) {
                compactToolButton(
                    systemImage: "arrow.clockwise",
                    tooltip: "刷新导航器",
                    width: topInspectorControlButtonWidth,
                    height: topInspectorControlButtonHeight,
                    iconSize: topInspectorControlIconSize,
                    cornerRadius: topInspectorControlCornerRadius
                ) {
                    viewModel.refreshNavigatorPreviewNow()
                }

                compactToolButton(
                    systemImage: "arrow.counterclockwise",
                    tooltip: "恢复 100%",
                    width: topInspectorControlButtonWidth,
                    height: topInspectorControlButtonHeight,
                    iconSize: topInspectorControlIconSize,
                    cornerRadius: topInspectorControlCornerRadius
                ) {
                    viewModel.setNavigatorZoomPercent(100)
                    syncNavigatorZoomPercentText()
                }

                Slider(
                    value: Binding(
                        get: { viewModel.navigatorZoomPercent },
                        set: { viewModel.setNavigatorZoomPercent($0) }
                    ),
                    in: 5...3200
                )
                .frame(maxWidth: .infinity)

                HStack(spacing: 4) {
                    TextField("", text: $navigatorZoomPercentText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 36)
                        .onSubmit {
                            commitNavigatorZoomPercentText()
                        }

                    Text("%")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.66))
                }
                .padding(.horizontal, 7)
                .frame(height: topInspectorControlButtonHeight)
                .background(
                    RoundedRectangle(cornerRadius: topInspectorControlCornerRadius)
                        .fill(Color.black.opacity(0.18))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: topInspectorControlCornerRadius)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func syncNavigatorZoomPercentText() {
        navigatorZoomPercentText = "\(Int(viewModel.navigatorZoomPercent.rounded()))"
    }

    private func commitNavigatorZoomPercentText() {
        let trimmed = navigatorZoomPercentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Double(trimmed), parsed.isFinite else {
            syncNavigatorZoomPercentText()
            return
        }
        viewModel.setNavigatorZoomPercent(parsed)
        syncNavigatorZoomPercentText()
    }

    private var creativeShapeGeneratorExternalImageButton: some View {
        let generator = viewModel.workspace.creativeShapeGenerator
        return generatorSourceButton(
            title: viewModel.isCreativeShapeGeneratorImageLoading ? "分析中…" : CreativeShapeGeneratorColorSource.externalImage.title,
            isSelected: generator.selectedSource == .externalImage,
            isDisabled: viewModel.isCreativeShapeGeneratorImageLoading
        ) {
            viewModel.selectCreativeShapeGeneratorSource(.externalImage)
        }
    }

    private func generatorSourceButton(
        title: String,
        isSelected: Bool,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(isDisabled ? 0.42 : 0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity, minHeight: 30)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.08),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.7 : 1)
        .frame(maxWidth: .infinity)
    }

    private var brushSection: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                valueText: "\(Int(viewModel.workspace.toolSession.brush.paintJitterAmount * 100))%",
                value: Binding(
                    get: { Double(viewModel.workspace.toolSession.brush.paintJitterAmount) },
                    set: { _ in }
                ),
                range: 0...1,
                onCommit: { viewModel.setPaintJitterAmount(Float($0)) }
            )

            OptimizedCompactSlider(
                title: "杂色对比",
                valueText: "\(Int(viewModel.workspace.toolSession.brush.paintContrastAmount * 100))%",
                value: Binding(
                    get: { Double(viewModel.workspace.toolSession.brush.paintContrastAmount) },
                    set: { _ in }
                ),
                range: 0...1,
                onCommit: { viewModel.setPaintContrastAmount(Float($0)) }
            )

            OptimizedCompactSlider(
                title: "大小压感",
                valueText: "\(Int(viewModel.displayedPressureSizeAmount * 100))%",
                value: Binding(
                    get: { Double(viewModel.displayedPressureSizeAmount) },
                    set: { _ in }
                ),
                range: 0...1,
                onCommit: { viewModel.setPressureSizeAmount(Float($0)) }
            )

            OptimizedCompactSlider(
                title: "透明压感",
                valueText: "\(Int(viewModel.displayedPressureOpacityAmount * 100))%",
                value: Binding(
                    get: { Double(viewModel.displayedPressureOpacityAmount) },
                    set: { _ in }
                ),
                range: 0...1,
                onCommit: { viewModel.setPressureOpacityAmount(Float($0)) }
            )

            HStack(spacing: 8) {
                compactIconButton(
                    systemImage: "square.3.layers.3d.top.filled",
                    tooltip: viewModel.workspace.toolSession.brush.buildMode == .opacityCap
                        ? "关闭不透明度封顶"
                        : "开启不透明度封顶",
                    isSelected: viewModel.workspace.toolSession.brush.buildMode == .opacityCap
                ) {
                    viewModel.setBrushBuildMode(
                        viewModel.workspace.toolSession.brush.buildMode == .opacityCap
                            ? .buildUp
                            : .opacityCap
                    )
                }

                compactIconButton(
                    systemImage: "location.north.line.fill",
                    tooltip: viewModel.workspace.toolSession.brush.followsStrokeDirection ? "关闭跟随笔迹方向" : "开启跟随笔迹方向",
                    isSelected: viewModel.workspace.toolSession.brush.followsStrokeDirection
                ) {
                    viewModel.setBrushFollowsStrokeDirection(!viewModel.workspace.toolSession.brush.followsStrokeDirection)
                }

                compactIconButton(systemImage: "waveform.path.ecg", tooltip: "大小压感曲线") {
                    showsPressureSizeCurveEditor.toggle()
                }
                .popover(isPresented: $showsPressureSizeCurveEditor, arrowEdge: .bottom) {
                    pressureSizeCurveEditor
                        .padding(14)
                        .frame(width: 280)
                        .background(Color(nsColor: .windowBackgroundColor))
                }

                compactIconButton(systemImage: "drop", tooltip: "透明压感曲线") {
                    showsPressureCurveEditor.toggle()
                }
                .popover(isPresented: $showsPressureCurveEditor, arrowEdge: .bottom) {
                    pressureCurveEditor
                        .padding(14)
                        .frame(width: 280)
                        .background(Color(nsColor: .windowBackgroundColor))
                }

                Spacer(minLength: 0)

                compactIconButton(systemImage: "square.and.arrow.down", tooltip: "存为笔刷") {
                    viewModel.saveCurrentBrushPreset()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pressureSizeCurveEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("大小压感曲线")
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
            Text("透明压感曲线")
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
            let resolvedSlotMap = viewModel.workspace.brushLibrary.resolvedSlotMap()
            let occupiedSlotCount = max((resolvedSlotMap.values.max() ?? -1) + 1, 0)
            let estimatedRowHeight = max(slotWidth + spacing, 1)
            let visibleRowCount = max(2, Int(ceil(max(geometry.size.height - 4, 0) / estimatedRowHeight)))
            let visibleSlotCapacity = visibleRowCount * columnCount
            let rawSlotCount = max(occupiedSlotCount, visibleSlotCapacity)
            let totalSlotCount = max(
                columnCount * 2,
                ((rawSlotCount + columnCount - 1) / columnCount) * columnCount
            )

            VStack(alignment: .leading, spacing: 0) {
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
                .onDrop(of: [UTType.plainText.identifier], isTargeted: nil) { providers in
                    moveBrushPresetFromDrop(providers: providers, toSlot: slotIndex)
                }
        } else {
            let emptyCell = RoundedRectangle(cornerRadius: 10)
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

            emptyCell
        }
    }

    private var layersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
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

                layerActionButton(systemImage: "trash", tooltip: "删除图层", tint: Color.red.opacity(0.95)) {
                    viewModel.removeActiveLayer()
                }

                Spacer(minLength: 0)

                layerActionButton(
                    systemImage: "circle.lefthalf.filled",
                    tooltip: activeLayerOpacityButtonTooltip
                ) {
                    showsLayerOpacityPopover.toggle()
                }
                .popover(isPresented: $showsLayerOpacityPopover, arrowEdge: .bottom) {
                    layerOpacityPopover
                        .padding(14)
                        .frame(width: 250)
                        .background(Color(nsColor: .windowBackgroundColor))
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
        VStack(alignment: .leading, spacing: topInspectorSectionSpacing) {
            tipDesignCanvas

            HStack(spacing: topInspectorControlSpacing) {
                compactToolButton(
                    systemImage: "checkmark",
                    tooltip: "确认当前笔尖草稿",
                    isSelected: viewModel.hasPendingBrushTipDraft,
                    width: topInspectorControlButtonWidth,
                    height: topInspectorControlButtonHeight,
                    iconSize: topInspectorControlIconSize,
                    cornerRadius: topInspectorControlCornerRadius
                ) {
                    _ = viewModel.applyBrushTipDraft()
                }
                .disabled(!viewModel.hasPendingBrushTipDraft)

                compactToolButton(
                    systemImage: "photo.badge.plus",
                    tooltip: "从图片导入笔尖",
                    isSelected: false,
                    width: topInspectorControlButtonWidth,
                    height: topInspectorControlButtonHeight,
                    iconSize: topInspectorControlIconSize,
                    cornerRadius: topInspectorControlCornerRadius
                ) {
                    viewModel.importBrushTipImageFromDisk()
                }

                compactToolButton(
                    systemImage: "square.grid.3x2",
                    tooltip: "打开笔尖图片资料库",
                    isSelected: false,
                    width: topInspectorControlButtonWidth,
                    height: topInspectorControlButtonHeight,
                    iconSize: topInspectorControlIconSize,
                    cornerRadius: topInspectorControlCornerRadius
                ) {
                    prepareTipImageLibraryPresentation(for: .primary)
                    tipImageLibrarySheetTarget = .primary
                }

                compactToolButton(
                    systemImage: "eraser.fill",
                    tooltip: tipPaintMode == .eraser ? "切回笔刷绘制" : "切换到橡皮",
                    isSelected: tipPaintMode == .eraser,
                    width: topInspectorControlButtonWidth,
                    height: topInspectorControlButtonHeight,
                    iconSize: topInspectorControlIconSize,
                    cornerRadius: topInspectorControlCornerRadius
                ) {
                    tipPaintMode = tipPaintMode == .eraser ? .round : .eraser
                }

                compactTextActionButton(
                    title: "组合笔刷…",
                    tooltip: "打开组合笔刷工作台",
                    minWidth: 82,
                    isProminent: viewModel.workspace.toolSession.brush.compoundBrush.enabled,
                    fillsAvailableWidth: true,
                    height: topInspectorControlButtonHeight,
                    cornerRadius: topInspectorControlCornerRadius,
                    fontSize: 11,
                    horizontalPadding: 6
                ) {
                    let isCompoundEnabled = viewModel.workspace.toolSession.brush.compoundBrush.enabled
                    if isCompoundEnabled {
                        viewModel.setCompoundBrushEnabled(false)
                        showsCompoundBrushBuilder = false
                    } else {
                        viewModel.setCompoundBrushEnabled(true)
                        showsCompoundBrushBuilder = true
                    }
                }
            }

            if let restoreTitle = primaryDormantTipRestoreTitle(for: viewModel.workspace.toolSession.brush) {
                tipSourceRestoreButton(title: restoreTitle) {
                    viewModel.reactivatePrimaryCustomTipSourceIfAvailable()
                }
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func effectivePrimaryTipSourceSemantic(for brush: BrushSettings) -> TipSourceSemantic {
        if brush.tipShape == .customRound {
            return brush.customTipSourceSemantic
        }
        if brush.customTipMaskData != nil || brush.customTipAssetID != nil {
            return brush.customTipSourceSemantic
        }
        return .procedural
    }

    private func compactToolButton(
        systemImage: String,
        tooltip: String,
        isSelected: Bool = false,
        width: CGFloat = 34,
        height: CGFloat = 30,
        iconSize: CGFloat = 13,
        cornerRadius: CGFloat = 8,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: .bold))
                .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.95))
                .frame(width: width, height: height)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(isSelected ? Color.accentColor : Color.white.opacity(0.18))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
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
        minWidth: CGFloat? = nil,
        isProminent: Bool = false,
        fillsAvailableWidth: Bool = false,
        height: CGFloat = 30,
        cornerRadius: CGFloat = 8,
        fontSize: CGFloat = 12,
        horizontalPadding: CGFloat = 10,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.96))
                .lineLimit(1)
                .minimumScaleFactor(0.95)
                .frame(maxWidth: fillsAvailableWidth ? .infinity : nil, minHeight: height)
                .frame(minWidth: minWidth)
                .padding(.horizontal, horizontalPadding)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(isProminent ? Color.accentColor : Color.white.opacity(0.18))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(
                            isProminent ? Color.accentColor.opacity(0.95) : Color.white.opacity(0.16),
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

        return HStack(spacing: 7) {
            layerThumbnailView(for: layer)

            Circle()
                .fill(isActive ? Color.accentColor : Color.white.opacity(0.25))
                .frame(width: 6, height: 6)

            if isEditing {
                TextField("", text: Binding(
                    get: { editingLayerName },
                    set: { editingLayerName = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
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
                    .font(.system(size: 12, weight: .semibold))
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
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(layer.isVisible ? Color.white.opacity(0.72) : Color.accentColor)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help(layer.isVisible ? "隐藏图层" : "显示图层")

            Button {
                viewModel.toggleLayerTransparentPixelLock(layer.id)
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(layer.locksTransparentPixels ? Color.cyan.opacity(0.95) : Color.white.opacity(0.08))
                    Text("α")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(layer.locksTransparentPixels ? Color.black.opacity(0.88) : Color.white.opacity(0.72))
                }
                .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help(layer.locksTransparentPixels ? "解除锁定透明像素" : "锁定透明像素")

            Button {
                viewModel.toggleLayerLock(layer.id)
            } label: {
                Image(systemName: layer.isLocked ? "lock.fill" : "lock.open")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(layer.isLocked ? Color.orange : Color.white.opacity(0.72))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help(layer.isLocked ? "解锁图层" : "锁定图层")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            (isActive ? Color.accentColor.opacity(0.18) : Color.clear),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7))
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
            .frame(height: 8)
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
        tint: Color = Color.white.opacity(0.92),
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
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
    private var layerOpacityPopover: some View {
        if let activeLayer {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("图层不透明度")
                        .font(.system(size: 13, weight: .bold))
                    Spacer()
                    Text("\(Int(activeLayer.opacity * 100))%")
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                        .foregroundStyle(Color.secondary)
                }

                LayerOpacitySlider(
                    layer: activeLayer,
                    onPreview: { newOpacity in
                        viewModel.beginActiveLayerOpacityChange()
                        viewModel.setActiveLayerOpacity(newOpacity)
                    },
                    onCommit: { newOpacity in
                        viewModel.beginActiveLayerOpacityChange()
                        viewModel.setActiveLayerOpacity(newOpacity)
                        viewModel.endActiveLayerOpacityChange()
                    }
                )
            }
        } else {
            Text("没有可调整的不透明度图层")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.secondary)
        }
    }

    private var activeLayerOpacityButtonTooltip: String {
        guard let activeLayer else { return "图层不透明度" }
        return "图层不透明度 \(Int(activeLayer.opacity * 100))%"
    }

    @ViewBuilder
    private func layerThumbnailView(for layer: LayerRecord) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.06))
                .frame(width: 24, height: 24)

            if let image = viewModel.layerThumbnail(for: layer.id, maxDimension: 36) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 14, height: 14)
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
        GeometryReader { proxy in
            let presentation = CanvasPresentationBuilder.makePresentation(
                canvasSize: CanvasSize(width: tipMaskResolution, height: tipMaskResolution),
                viewport: .stageOneDefault,
                availableWidth: proxy.size.width,
                availableHeight: proxy.size.height,
                padding: 10
            )
            let documentCenter = CanvasPoint(
                x: presentation.documentOrigin.x + (presentation.documentDisplaySize.x / 2),
                y: presentation.documentOrigin.y + (presentation.documentDisplaySize.y / 2)
            )
            let editorMaskData =
                viewModel.hasPendingBrushTipDraft
                ? viewModel.brushTipDraftMaskData
                : viewModel.workspace.toolSession.brush.customTipMaskData
            let tipSemantic =
                viewModel.hasPendingBrushTipDraft
                ? TipSourceSemantic.customMask
                : effectivePrimaryTipSourceSemantic(for: viewModel.workspace.toolSession.brush)
            let tipFitPreview = tipSemantic.usesImportedPreviewFit

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.14))

                TipMaskCanvasView(
                    maskData: editorMaskData,
                    syncToken: tipMaskEditorSyncToken(
                        maskData: editorMaskData,
                        sourceSemantic: tipSemantic,
                        assetID: viewModel.hasPendingBrushTipDraft ? nil : viewModel.workspace.toolSession.brush.customTipAssetID,
                        fitImportedPreview: tipFitPreview
                    ),
                    fitImportedPreview: tipFitPreview,
                    paintMode: tipPaintMode,
                    drawingBrush: viewModel.workspace.toolSession.brush,
                    onRequestPaintModeShortcut: { mode in
                        tipPaintMode = mode
                    },
                    onFocusChanged: { isFocused in
                        viewModel.setBrushTipCanvasFocused(isFocused)
                    },
                    onImportImage: { image in
                        _ = viewModel.importBrushTipImage(from: image)
                    },
                    onUpdateMask: { data in
                        viewModel.updateBrushTipDraft(data)
                    }
                )
                .frame(
                    width: presentation.documentDisplaySize.x,
                    height: presentation.documentDisplaySize.y
                )
                .position(
                    x: documentCenter.x,
                    y: documentCenter.y
                )
            }
        }
        .frame(height: 168)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isTipImageDropTarget ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.08),
                    lineWidth: isTipImageDropTarget ? 2 : 1
                )
        )
        .overlay(alignment: .topTrailing) {
            Button {
                viewModel.clearBrushTipDraft()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .frame(width: 28, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.10))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("清空笔尖")
            .padding(8)
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

    private func tipImageLibrarySheet(
        for target: TipImageLibrarySheetTarget,
        dismiss: @escaping () -> Void
    ) -> some View {
        let items = viewModel.workspace.tipImageLibrary.items
        let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 5)
        let pendingSelection = pendingTipImageLibrarySelection(for: target)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(target.title)
                        .font(.system(size: 15, weight: .bold))

                    Text("共享主/次笔尖图片；删除时若仍被当前画笔或预设引用，会阻止删除。")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Text("\(items.count)/\(TipImageLibraryState.suggestedCapacity)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.secondary)
            }

            HStack(spacing: 8) {
                Button("导入图片…") {
                    importTipImageViaLibrarySheet(for: target)
                }
                .buttonStyle(.borderedProminent)

                Spacer(minLength: 0)

                Button("完成") {
                    completeTipImageLibrarySheet(for: target, dismiss: dismiss)
                }
                .buttonStyle(.bordered)
            }

            if items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("资料库为空")
                        .font(.system(size: 13, weight: .semibold))

                    Text("从主笔尖或次笔尖导入图片后，会自动进入这里。也可以直接在这里批量导入，再选一张后点“完成”。")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            tipImageLibraryCell(
                                item,
                                target: target,
                                isSelected: pendingSelection == item.id,
                                isDropTarget: tipImageLibraryDropTargetID == item.id
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                            .onTapGesture {
                                setPendingTipImageLibrarySelection(item.id, for: target)
                            }
                            .onDrag {
                                draggedTipImageLibraryAssetID = item.id
                                return NSItemProvider(object: item.id.rawValue as NSString)
                            }
                            .onDrop(
                                of: [UTType.plainText.identifier],
                                isTargeted: tipImageLibraryDropTargetBinding(for: item.id)
                            ) { providers in
                                moveTipImageLibraryItemFromDrop(providers: providers, to: index)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(16)
        .frame(width: 620, height: 520, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand {
            dismissTipImageLibrarySheet(for: target, dismiss: dismiss)
        }
    }

    private func tipImageLibraryCell(
        _ item: TipImageLibraryItem,
        target: TipImageLibrarySheetTarget,
        isSelected: Bool,
        isDropTarget: Bool
    ) -> some View {
        let referenceSummary = viewModel.tipImageLibraryReferenceSummary(for: item.id)
        return VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.94))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                isDropTarget ? Color.accentColor.opacity(0.96) : (isSelected ? Color.accentColor.opacity(0.92) : Color.white.opacity(0.12)),
                                lineWidth: isDropTarget || isSelected ? 2 : 1
                            )
                    )

                if let image = tipImageLibraryPreviewImage(for: item, target: target, displayExtent: 66) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(10)
                } else {
                    Text("无预览")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.65))
                }

                VStack {
                    HStack {
                        Spacer()
                        Button {
                            if viewModel.deleteTipImageLibraryItem(item.id) {
                                if primaryTipImageLibraryPendingSelection == item.id {
                                    primaryTipImageLibraryPendingSelection = nil
                                }
                                if compoundSecondaryTipImageLibraryPendingSelection == item.id {
                                    compoundSecondaryTipImageLibraryPendingSelection = nil
                                }
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(
                                    referenceSummary.isReferenced
                                        ? Color.white.opacity(0.26)
                                        : Color.white.opacity(0.78)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(referenceSummary.isReferenced)
                        .help(tipImageLibraryDeleteTooltip(for: referenceSummary))
                        .padding(6)
                    }
                    Spacer()
                }
            }
            .frame(height: 86)

            Text(item.displayName)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)

            Text("\(item.sourceInfo.pixelWidth)x\(item.sourceInfo.pixelHeight)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.secondary)
                .lineLimit(1)

            tipImageLibraryReferenceSummaryRow(referenceSummary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.accentColor.opacity(0.24) : Color.black.opacity(0.06), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func tipImageLibraryReferenceSummaryRow(
        _ summary: WorkspaceViewModel.TipImageLibraryReferenceSummary
    ) -> some View {
        HStack(spacing: 6) {
            if summary.currentBrushUsesPrimary {
                tipImageLibraryReferenceChip(
                    title: "当前主笔尖",
                    tint: Color.accentColor,
                    tooltip: "当前主笔尖正在使用这张图片"
                )
            }

            if summary.currentBrushUsesCompoundSecondary {
                tipImageLibraryReferenceChip(
                    title: "组合次笔尖",
                    tint: Color.orange,
                    tooltip: "当前组合笔刷次笔尖正在使用这张图片"
                )
            }

            if summary.presetCount > 0 {
                tipImageLibraryReferenceChip(
                    title: "\(summary.presetCount) 个预设",
                    tint: Color(red: 0.16, green: 0.46, blue: 0.78),
                    tooltip: tipImageLibraryPresetReferenceTooltip(for: summary)
                )
            }

            if summary.isReferenced == false {
                tipImageLibraryReferenceChip(
                    title: "未引用",
                    tint: Color.secondary,
                    tooltip: "当前没有主笔尖、次笔尖或已保存预设引用这张图片"
                )
            }
        }
    }

    private func tipImageLibraryReferenceChip(
        title: String,
        tint: Color,
        tooltip: String? = nil
    ) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(tint.opacity(0.92))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(tint.opacity(0.12))
            )
            .overlay(
                Capsule()
                    .stroke(tint.opacity(0.18), lineWidth: 1)
            )
            .help(tooltip ?? "")
    }

    private func tipImageLibraryPresetReferenceTooltip(
        for summary: WorkspaceViewModel.TipImageLibraryReferenceSummary
    ) -> String {
        guard summary.presetPrimaryNames.isEmpty == false else {
            return "已有预设引用这张图片"
        }
        return "主笔尖预设：\(tipImageLibraryPresetNameSummary(summary.presetPrimaryNames))"
    }

    private func tipImageLibraryPresetNameSummary(_ names: [String]) -> String {
        let previewNames = names.prefix(3)
        let label = previewNames.joined(separator: "、")
        guard names.count > 3 else { return label }
        return "\(label) 等 \(names.count) 个预设"
    }

    private func tipImageLibraryDeleteTooltip(
        for summary: WorkspaceViewModel.TipImageLibraryReferenceSummary
    ) -> String {
        guard summary.isReferenced else {
            return "删除笔尖图片"
        }

        var parts: [String] = []
        if summary.currentBrushUsesPrimary {
            parts.append("当前主笔尖")
        }
        if summary.currentBrushUsesCompoundSecondary {
            parts.append("当前组合笔刷次笔尖")
        }
        if summary.presetPrimaryNames.isEmpty == false {
            parts.append("主笔尖预设：\(tipImageLibraryPresetNameSummary(summary.presetPrimaryNames))")
        }
        if summary.presetCompoundSecondaryNames.isEmpty == false {
            parts.append("组合次笔尖预设：\(tipImageLibraryPresetNameSummary(summary.presetCompoundSecondaryNames))")
        }
        return "该笔尖图片仍被\(parts.joined(separator: "、"))引用，无法删除"
    }

    private func selectedTipImageLibraryAssetID(for target: TipImageLibrarySheetTarget) -> BrushTipImageAssetID? {
        let brush = viewModel.workspace.toolSession.brush
        switch target {
        case .primary:
            guard brush.tipShape == .customRound, effectivePrimaryTipSourceSemantic(for: brush) == .importedImage else {
                return nil
            }
            return brush.customTipAssetID
        case .compoundSecondary:
            guard
                brush.compoundBrush.secondary.tipShape == .customRound,
                brush.compoundBrush.secondary.sourceSemantic == .importedImage
            else {
                return nil
            }
            return brush.compoundBrush.secondary.tipAssetID
        }
    }

    private func pendingTipImageLibrarySelection(for target: TipImageLibrarySheetTarget) -> BrushTipImageAssetID? {
        switch target {
        case .primary:
            return primaryTipImageLibraryPendingSelection
        case .compoundSecondary:
            return compoundSecondaryTipImageLibraryPendingSelection
        }
    }

    private func setPendingTipImageLibrarySelection(
        _ assetID: BrushTipImageAssetID?,
        for target: TipImageLibrarySheetTarget
    ) {
        switch target {
        case .primary:
            primaryTipImageLibraryPendingSelection = assetID
        case .compoundSecondary:
            compoundSecondaryTipImageLibraryPendingSelection = assetID
        }
    }

    private func prepareTipImageLibraryPresentation(for target: TipImageLibrarySheetTarget) {
        viewModel.prepareTipImageLibraryForBrowser()
        setPendingTipImageLibrarySelection(selectedTipImageLibraryAssetID(for: target), for: target)
        draggedTipImageLibraryAssetID = nil
        tipImageLibraryDropTargetID = nil
    }

    private func completeTipImageLibrarySheet(
        for target: TipImageLibrarySheetTarget,
        dismiss: @escaping () -> Void
    ) {
        if let pendingSelection = pendingTipImageLibrarySelection(for: target) {
            applyTipImageLibraryItem(pendingSelection, to: target)
        }
        dismissTipImageLibrarySheet(for: target, dismiss: dismiss)
    }

    private func dismissTipImageLibrarySheet(
        for target: TipImageLibrarySheetTarget,
        dismiss: @escaping () -> Void
    ) {
        setPendingTipImageLibrarySelection(nil, for: target)
        draggedTipImageLibraryAssetID = nil
        tipImageLibraryDropTargetID = nil
        dismiss()
    }

    private func importTipImageViaLibrarySheet(for target: TipImageLibrarySheetTarget) {
        guard let importedIDs = viewModel.importTipImageLibraryItemsFromDisk() else {
            return
        }
        if importedIDs.count == 1, let importedID = importedIDs.first {
            setPendingTipImageLibrarySelection(importedID, for: target)
        }
    }

    private func applyTipImageLibraryItem(_ assetID: BrushTipImageAssetID, to target: TipImageLibrarySheetTarget) {
        switch target {
        case .primary:
            viewModel.applyPrimaryTipImageLibraryItem(assetID)
        case .compoundSecondary:
            viewModel.applyCompoundSecondaryTipImageLibraryItem(assetID)
        }
    }

    private func moveTipImageLibraryItemFromDrop(
        providers: [NSItemProvider],
        to targetIndex: Int
    ) -> Bool {
        if let draggedTipImageLibraryAssetID {
            viewModel.moveTipImageLibraryItem(draggedTipImageLibraryAssetID, to: targetIndex)
            self.draggedTipImageLibraryAssetID = nil
            self.tipImageLibraryDropTargetID = nil
            return true
        }

        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            tipImageLibraryDropTargetID = nil
            return false
        }

        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let rawValue = object as? NSString else {
                return
            }
            let assetID = BrushTipImageAssetID(rawValue: String(rawValue))
            DispatchQueue.main.async {
                viewModel.moveTipImageLibraryItem(assetID, to: targetIndex)
                self.tipImageLibraryDropTargetID = nil
            }
        }
        return true
    }

    private func tipImageLibraryDropTargetBinding(
        for assetID: BrushTipImageAssetID
    ) -> Binding<Bool> {
        Binding(
            get: {
                tipImageLibraryDropTargetID == assetID
            },
            set: { isTargeted in
                if isTargeted {
                    tipImageLibraryDropTargetID = assetID
                } else if tipImageLibraryDropTargetID == assetID {
                    tipImageLibraryDropTargetID = nil
                }
            }
        )
    }

    private func tipMaskEditorSyncToken(
        maskData: Data?,
        sourceSemantic: TipSourceSemantic,
        assetID: BrushTipImageAssetID?,
        fitImportedPreview: Bool
    ) -> String {
        [
            sourceSemantic.rawValue,
            assetID?.rawValue ?? "none",
            StageOneBrushPreviewRasterizer.maskFingerprint(for: maskData) ?? "nil",
            fitImportedPreview ? "fit" : "nofit"
        ]
        .joined(separator: "|")
    }

    private func tipSourceRestoreButton(
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.uturn.backward.circle")
                    .font(.system(size: 11, weight: .bold))
                Text(title)
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
    }

    private func primaryDormantTipRestoreTitle(for brush: BrushSettings) -> String? {
        guard brush.tipShape != .customRound else { return nil }

        if effectivePrimaryTipSourceSemantic(for: brush) == .importedImage,
           brush.customTipMaskData != nil || brush.customTipAssetID != nil {
            return "切回导入图像笔尖"
        }

        if brush.customTipMaskData != nil {
            return "切回自定义笔尖"
        }

        return nil
    }

    private func insertNextPresetShape() {
        let nextIndex = presetShapeIndex % 4
        presetShapeIndex += 1
        viewModel.updateCustomTipMask(makePresetTipMask(for: nextIndex, intensity: 255))
    }

    private func insertNextSprayPattern() {
        let nextIndex = sprayPatternIndex % 4
        sprayPatternIndex += 1
        viewModel.updateCustomTipMask(makeSprayTipMask(for: nextIndex, intensity: 255))
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
        let strokeColor: Color = isSelected ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.06)
        let strokeWidth: CGFloat = isSelected ? 1.5 : 1.0

        return LongPressDraggableCell(
            dragPayload: preset.id,
            onActivate: {
                viewModel.applyBrushPreset(preset.id)
            },
            onDragBegan: {
                draggedBrushPresetID = preset.id
            },
            onDragEnded: {
                draggedBrushPresetID = nil
            }
        ) {
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
                        brushStrokePreview(for: preset.brush, activeTool: .brush)
                            .frame(width: previewSide, height: previewSide)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(.leading, cellSide * 0.10)
                            .padding(.top, cellSide * 0.08)

                        brushPreviewGlyph(for: preset.brush, activeTool: .brush, maxExtent: glyphSide)
                            .frame(width: glyphSide, height: glyphSide, alignment: .center)
                            .padding(.trailing, cellSide * 0.09)
                            .padding(.bottom, cellSide * 0.07)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .allowsHitTesting(false)
                }

                if let tag = preset.colorTag {
                    brushColorTagCorner(tag)
                        .allowsHitTesting(false)
                }

                shortcutSlotLabel(for: slotIndex)
                    .allowsHitTesting(false)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .help(preset.name)
        .contextMenu {
            Button("应用") {
                viewModel.applyBrushPreset(preset.id)
            }

            Divider()

            Menu("色标") {
                ForEach(BrushColorTag.allCases, id: \.self) { tag in
                    Button {
                        viewModel.setBrushPresetColorTag(tag, forPresetID: preset.id)
                    } label: {
                        HStack {
                            Circle()
                                .fill(colorForBrushTag(tag))
                                .frame(width: 10, height: 10)
                            Text(labelForBrushTag(tag))
                        }
                    }
                }

                Divider()

                Button("清除色标") {
                    viewModel.setBrushPresetColorTag(nil, forPresetID: preset.id)
                }
                .disabled(preset.colorTag == nil)
            }

            if !preset.isBuiltIn && isSelected {
                Divider()
                Button("删除") {
                    viewModel.deleteBrushPreset(preset.id)
                }
            }
        }
    }

    private func brushColorTagCorner(_ tag: BrushColorTag) -> some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let dotSize = max(6, side * 0.14)
            Circle()
                .fill(colorForBrushTag(tag))
                .frame(width: dotSize, height: dotSize)
                .position(x: dotSize * 0.5 + side * 0.12, y: side - dotSize * 0.5 - side * 0.10)
        }
    }

    private func colorForBrushTag(_ tag: BrushColorTag) -> Color {
        switch tag {
        case .red: return Color(red: 0.90, green: 0.22, blue: 0.21)
        case .orange: return Color(red: 0.95, green: 0.55, blue: 0.15)
        case .yellow: return Color(red: 0.95, green: 0.85, blue: 0.20)
        case .green: return Color(red: 0.30, green: 0.78, blue: 0.30)
        case .cyan: return Color(red: 0.20, green: 0.78, blue: 0.82)
        case .blue: return Color(red: 0.25, green: 0.45, blue: 0.90)
        case .purple: return Color(red: 0.65, green: 0.30, blue: 0.85)
        }
    }

    private func labelForBrushTag(_ tag: BrushColorTag) -> String {
        switch tag {
        case .red: return "红"
        case .orange: return "橙"
        case .yellow: return "黄"
        case .green: return "绿"
        case .cyan: return "青"
        case .blue: return "蓝"
        case .purple: return "紫"
        }
    }

    @ViewBuilder
    private func shortcutSlotLabel(for slotIndex: Int) -> some View {
        if slotIndex < 4 {
            Text("\(slotIndex + 1)")
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.accentColor.opacity(0.95))
                .padding(.trailing, 5)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
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

    private func brushStrokePreview(for brush: BrushSettings, activeTool: ToolKind) -> some View {
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
            let primaryStampResolution = previewRasterResolution(
                for: baseWidth,
                minimum: 44,
                maximum: 72,
                scale: 1.35
            )
            let primaryStampPreviewImage = bestEffortStampPreviewImage(
                for: brush,
                resolution: primaryStampResolution
            )

            for index in 0..<stampCount {
                let t = stampCount == 1 ? 0.0 : Double(index) / Double(stampCount - 1)
                let pressure = previewStrokePressure(at: t)
                let pressureMetrics = previewBrushStrokeMetrics(for: brush, pressure: pressure)
                var point = CGPoint(
                    x: start.x + (dx * t),
                    y: start.y + (dy * t)
                )

                if scatter > 0.001 {
                    let normal = CGPoint(x: -dy, y: dx)
                    let normalLength = max(sqrt((normal.x * normal.x) + (normal.y * normal.y)), 0.001)
                    let normalized = CGPoint(x: normal.x / normalLength, y: normal.y / normalLength)
                    let offset = (
                        StageOneBrushPreviewRasterizer.stableRandom(
                            x: point.x,
                            y: point.y,
                            index: index,
                            salt: 0x9E37_79B9
                        ) * 2.0 - 1.0
                    ) * scatter * 2.6
                    point.x += normalized.x * offset
                    point.y += normalized.y * offset
                }

                let sizeScale = 1.0 - (
                    StageOneBrushPreviewRasterizer.stableRandom(
                        x: point.x,
                        y: point.y,
                        index: index,
                        salt: 0xC2B2_AE35
                    ) * jitter * 0.45
                )
                let stampWidth = max(4, baseWidth * sizeScale * pressureMetrics.sizeFactor)
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
                angle += (
                    StageOneBrushPreviewRasterizer.stableRandom(
                        x: point.x,
                        y: point.y,
                        index: index,
                        salt: 0x27D4_EB2F
                    ) * 2.0 - 1.0
                ) * jitter * 0.65

                context.drawLayer { layer in
                    layer.opacity = pressureMetrics.opacity
                    layer.translateBy(x: rect.midX, y: rect.midY)
                    layer.rotate(by: Angle(radians: angle))
                    layer.translateBy(x: -rect.midX, y: -rect.midY)

                    if let primaryStampPreviewImage {
                        let resolved = layer.resolve(Image(decorative: primaryStampPreviewImage, scale: 1))
                        layer.draw(resolved, in: rect)
                    }
                }
            }
        }
    }

    private func previewStrokePressure(at progress: Double) -> Double {
        let clamped = min(max(progress, 0), 1)
        // Simulate heavy → light: start at high pressure and ease out to near-zero.
        let inverted = 1.0 - clamped
        let eased = inverted * inverted * (3 - (2 * inverted))
        return 0.05 + (0.90 * eased)
    }

    private func previewBrushStrokeMetrics(
        for brush: BrushSettings,
        pressure: Double
    ) -> (sizeFactor: Double, opacity: Double) {
        let effectivePressure = min(max(pressure, 0), 1)
        let sizePressure = max(effectivePressure, 0.01)
        let opacityPressure = max(effectivePressure, 0.005)
        let sizeResponseSource = brush.compoundBrush.enabled
            ? brush.compoundBrush.globalPressureSizeAmount
            : brush.pressureSizeAmount
        let opacityResponseSource = brush.compoundBrush.enabled
            ? brush.compoundBrush.globalPressureOpacityAmount
            : brush.pressureOpacityAmount
        let sizeResponse = min(max(Double(sizeResponseSource), 0), 1)
        let opacityResponse = min(max(Double(opacityResponseSource), 0), 1)
        let curvedSizePressure = previewSizeCurvePressure(sizePressure, brush: brush)
        let lowerBound = min(max(Double(brush.sizeLowerBound), 0), 1)
        let lowerBoundedPressure = lowerBound + ((1 - lowerBound) * curvedSizePressure)
        let rawSizeFactor = (1 - sizeResponse) + (sizeResponse * lowerBoundedPressure)
        let curvedOpacityPressure = previewOpacityCurvePressure(opacityPressure, brush: brush)
        let rawOpacityFactor = Double(
            BrushSettings.resolvedPressureFactor(
                responseAmount: Float(opacityResponse),
                curvedPressure: Float(curvedOpacityPressure)
            )
        )

        let sizeFactor = rawSizeFactor
        let targetVisibleOpacity = Float(brush.opacity) * Float(rawOpacityFactor)
        let spacingPx = max(Float(Double(brush.size) * Double(brush.spacingPercent) / 100.0), 0.5)
        let stampDiameterPx = max(Float(brush.size) * Float(sizeFactor), 1)
        let compensationAmount = brush.compoundBrush.enabled
            ? max(
                Float(opacityResponse),
                min(max(brush.compoundBrush.secondary.pressureOpacityAmount, 0), 1)
            )
            : Float(opacityResponse)
        let visibleOpacity = brush.buildMode == .buildUp
            ? BrushSettings.resolvedBuildUpVisibleAlpha(
                targetVisibleAlpha: targetVisibleOpacity,
                spacingPx: spacingPx,
                stampDiameterPx: stampDiameterPx,
                compensationAmount: compensationAmount
            )
            : targetVisibleOpacity
        let resolvedOpacity = min(max(Double(visibleOpacity), 0.03), 0.85)
        return (max(sizeFactor, 0.04), resolvedOpacity)
    }

    private func previewPressureResponsePressure(
        _ pressure: Double,
        brush: BrushSettings
    ) -> Double {
        let clamped = min(max(pressure, 0), 1)
        let sensitivity = min(max(Double(brush.pressureSensitivity), 0), 2)
        guard sensitivity > 0.0001 else {
            return 1
        }
        return pow(clamped, sensitivity)
    }

    private func previewSizeCurvePressure(
        _ pressure: Double,
        brush: BrushSettings
    ) -> Double {
        let low = min(max(Double(brush.sizeCurveLow), 0), 0.85)
        let mid = min(max(Double(brush.sizeCurveMid), low), 0.95)
        let high = min(max(Double(brush.sizeCurveHigh), mid), 1)
        return previewSamplePiecewiseCurve(
            pressure: pressure,
            points: [
                (0.0, 0.0),
                (0.2, low),
                (0.5, mid),
                (0.8, high),
                (1.0, 1.0)
            ]
        )
    }

    private func previewOpacityCurvePressure(
        _ pressure: Double,
        brush: BrushSettings
    ) -> Double {
        Double(
            BrushSettings.resolvedOpacityCurvePressure(
                pressure: Float(pressure),
                pressureSensitivity: brush.pressureSensitivity,
                low: brush.opacityCurveLow,
                mid: brush.opacityCurveMid,
                high: brush.opacityCurveHigh
            )
        )
    }

    private func previewSamplePiecewiseCurve(
        pressure: Double,
        points: [(x: Double, y: Double)]
    ) -> Double {
        let clamped = min(max(pressure, 0), 1)

        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            if clamped <= current.x {
                let segmentLength = max(current.x - previous.x, 0.0001)
                let t = min(max((clamped - previous.x) / segmentLength, 0), 1)
                let smoothT = t * t * (3 - (2 * t))
                return previous.y + ((current.y - previous.y) * smoothT)
            }
        }

        return points.last?.y ?? clamped
    }

    private func brushPreviewGlyph(
        for brush: BrushSettings,
        activeTool: ToolKind = .brush,
        maxExtent: Double = 52
    ) -> some View {
        let normalizedSize = min(max(Double(brush.size) / 64.0, 0.22), 1.0)
        let baseExtent = min(maxExtent, 34.0 + (18.0 * normalizedSize))
        let stampResolution = previewRasterResolution(
            for: baseExtent,
            minimum: 40,
            maximum: 96,
            scale: 1.8
        )
        let previewImage = bestEffortStampPreviewImage(
            for: brush,
            resolution: stampResolution
        )

        return ZStack {
            if let previewImage {
                Image(decorative: previewImage, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: baseExtent, height: baseExtent)
            } else {
                RoundedRectangle(cornerRadius: max(8, baseExtent * 0.22))
                    .fill(Color.white.opacity(0.10))
                    .frame(width: baseExtent, height: baseExtent)
            }
        }
    }

    private func previewRasterResolution(
        for displayExtent: Double,
        minimum: Int,
        maximum: Int,
        scale: Double
    ) -> Int {
        let proposed = Int(ceil(max(displayExtent, 1) * scale))
        return min(max(proposed, minimum), maximum)
    }

    nonisolated private func compactPreviewFallbackResolution(for resolution: Int) -> Int? {
        let fallback = max(24, min(resolution / 2, 40))
        return fallback < resolution ? fallback : nil
    }

    nonisolated private func bestEffortStampPreviewImage(
        for brush: BrushSettings,
        resolution: Int
    ) -> CGImage? {
        if let image = StageOneBrushPreviewRasterizer.stampImage(
            for: brush,
            resolution: resolution
        ) {
            return image
        }

        guard let fallbackResolution = compactPreviewFallbackResolution(for: resolution) else {
            return nil
        }

        return StageOneBrushPreviewRasterizer.stampImage(
            for: brush,
            resolution: fallbackResolution
        )
    }

    nonisolated private func bestEffortImportedAssetPreviewImage(
        from maskData: Data?,
        resolution: Int
    ) -> CGImage? {
        if let image = StageOneBrushPreviewRasterizer.importedAssetImage(
            from: maskData,
            resolution: resolution
        ) {
            return image
        }

        guard let fallbackResolution = compactPreviewFallbackResolution(for: resolution) else {
            return nil
        }

        return StageOneBrushPreviewRasterizer.importedAssetImage(
            from: maskData,
            resolution: fallbackResolution
        )
    }

    nonisolated private func bestEffortMaskPreviewImage(
        from maskData: Data?,
        role: StageOneBrushPreviewRasterizer.TipMaskPreviewRole,
        resolution: Int,
        cropToContent: Bool = true
    ) -> CGImage? {
        if let image = StageOneBrushPreviewRasterizer.normalizedMaskPreviewImage(
            from: maskData,
            resolution: resolution,
            role: role,
            cropToContent: cropToContent
        ) {
            return image
        }

        guard let fallbackResolution = compactPreviewFallbackResolution(for: resolution) else {
            return nil
        }

        return StageOneBrushPreviewRasterizer.normalizedMaskPreviewImage(
            from: maskData,
            resolution: fallbackResolution,
            role: role,
            cropToContent: cropToContent
        )
    }

    nonisolated private func bestEffortPrimaryEnvelopePreviewImage(
        for brush: BrushSettings,
        resolution: Int
    ) -> CGImage? {
        guard brush.tipShape == .customRound else {
            return bestEffortStampPreviewImage(for: brush, resolution: resolution)
        }
        return bestEffortMaskPreviewImage(
            from: brush.customTipEnvelopeMaskData ?? brush.customTipMaskData,
            role: .library,
            resolution: resolution,
            cropToContent: true
        )
    }

    @ViewBuilder
    private func brushMaskPreview(
        maskData: Data?,
        sourceSemantic: TipSourceSemantic,
        frameWidth: Double,
        frameHeight: Double,
        fallbackBrush: BrushSettings
    ) -> some View {
        if let image = customTipPreviewImage(
            from: maskData,
            sourceSemantic: sourceSemantic,
            frameWidth: frameWidth,
            frameHeight: frameHeight,
            fallbackBrush: fallbackBrush
        ) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: frameWidth, height: frameHeight)
        } else {
            RoundedRectangle(cornerRadius: max(8, min(frameWidth, frameHeight) * 0.24))
                .fill(Color.white.opacity(0.10))
                .frame(width: frameWidth, height: frameHeight)
        }
    }

    private func customTipPreviewImage(
        from maskData: Data?,
        sourceSemantic: TipSourceSemantic,
        frameWidth: Double,
        frameHeight: Double,
        fallbackBrush: BrushSettings
    ) -> CGImage? {
        if sourceSemantic != .procedural, maskData != nil {
            let displayExtent = max(frameWidth, frameHeight)
            let resolution = previewRasterResolution(
                for: displayExtent,
                minimum: 40,
                maximum: 96,
                scale: 1.9
            )
            return bestEffortMaskPreviewImage(
                from: maskData,
                role: .editor,
                resolution: resolution,
                cropToContent: true
            )
        }

        var previewBrush = fallbackBrush
        previewBrush.tipShape = .customRound
        previewBrush.customTipSourceSemantic = sourceSemantic
        previewBrush.customTipMaskData = maskData
        if sourceSemantic != .importedImage {
            previewBrush.customTipAssetID = nil
            previewBrush.customTipImportedSourceInfo = nil
        }

        let displayExtent = max(frameWidth, frameHeight)
        let resolution = previewRasterResolution(
            for: displayExtent,
            minimum: 40,
            maximum: 96,
            scale: 1.9
        )
        return bestEffortStampPreviewImage(
            for: previewBrush,
            resolution: resolution
        )
    }

    private func tipImageLibraryPreviewImage(
        for item: TipImageLibraryItem,
        target _: TipImageLibrarySheetTarget,
        displayExtent: Double
    ) -> CGImage? {
        let resolution = previewRasterResolution(
            for: displayExtent,
            minimum: 56,
            maximum: 96,
            scale: 1.45
        )
        return bestEffortMaskPreviewImage(
            from: item.maskData,
            role: .library,
            resolution: resolution,
            cropToContent: true
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
    @State private var isAdvancedControlsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                switch proxy.colorPanel.mode {
                case .picker:
                    pickerStageSection
                case .blocks:
                    blocksStageSection
                case .grayscale:
                    grayscaleStageSection
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

            colorPanelCollapseHandle

            if isAdvancedControlsExpanded {
                VStack(alignment: .leading, spacing: 8) {
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
                            systemImage: "circle.lefthalf.filled",
                            tooltip: proxy.colorPanel.mode == .grayscale ? "关闭黑白色块" : "黑白色块",
                            isSelected: proxy.colorPanel.mode == .grayscale
                        ) {
                            viewModel.toggleGrayscaleMode()
                        }
                        compactIconButton(
                            systemImage: proxy.colorPanel.mode == .picker ? "square.grid.3x3.fill" : "eyedropper.full",
                            tooltip: proxy.colorPanel.mode == .picker ? "切换到色块模式" : "切换到拾色器模式",
                            isSelected: proxy.colorPanel.mode == .blocks
                        ) {
                            viewModel.toggleColorPanelMode()
                        }
                    }

                    if proxy.colorPanel.mode == .grayscale {
                        grayscaleCountSlider
                    } else {
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
                            title: "光色",
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
                            title: "纯度",
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
                            title: "补色",
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
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isAdvancedControlsExpanded)
    }

    private var colorPanelCollapseHandle: some View {
        Button {
            isAdvancedControlsExpanded.toggle()
        } label: {
            HStack(spacing: 0) {
                Spacer(minLength: 0)

                VStack(spacing: 4) {
                    Image(systemName: isAdvancedControlsExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.78))

                    Capsule()
                        .fill(Color.white.opacity(0.22))
                        .frame(width: 44, height: 4)
                }

                Spacer(minLength: 0)
            }
            .frame(height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isAdvancedControlsExpanded ? "收起颜色参数" : "展开颜色参数")
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

    private var grayscaleStageSection: some View {
        GeometryReader { geo in
            let inset: CGFloat = 5.0
            let count = proxy.colorPanel.grayscaleBlockCount
            let availableW = geo.size.width - inset * 2
            let availableH = geo.size.height - inset * 2

            let columns: Int = count <= 5 ? count : (count / 2)
            let rows: Int = count <= 5 ? 1 : 2
            let spacing: CGFloat = 4

            let cellW = max(10, (availableW - spacing * CGFloat(columns - 1)) / CGFloat(columns))
            let cellH = max(10, (availableH - spacing * CGFloat(rows - 1)) / CGFloat(rows))
            let cellSize = min(cellW, cellH)

            let gridW = cellSize * CGFloat(columns) + spacing * CGFloat(columns - 1)
            let gridH = cellSize * CGFloat(rows) + spacing * CGFloat(rows - 1)

            VStack(spacing: spacing) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: spacing) {
                        ForEach(0..<columns, id: \.self) { col in
                            let index = row * columns + col
                            if index < count {
                                let t = count > 1 ? Double(index) / Double(count - 1) : 0.0
                                let gray = 1.0 - t
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color(white: gray))
                                    .frame(width: cellSize, height: cellSize)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                                    )
                                    .onTapGesture {
                                        viewModel.selectGrayscaleBlock(at: index, count: count)
                                    }
                            }
                        }
                    }
                }
            }
            .frame(width: gridW, height: gridH)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .padding(5)
    }

    private var grayscaleCountSlider: some View {
        let steps = [2, 3, 4, 5, 6, 8, 10]
        let currentCount = proxy.colorPanel.grayscaleBlockCount
        let currentIndex = Double(steps.firstIndex(of: currentCount) ?? 0)

        return bufferedCompactParameterSlider(
            title: "色阶",
            valueText: "\(currentCount)",
            value: currentIndex,
            range: 0...Double(steps.count - 1),
            onUpdate: { value in
                let idx = min(max(Int(value.rounded()), 0), steps.count - 1)
                let newCount = steps[idx]
                var updated = proxy.colorPanel
                updated.grayscaleBlockCount = newCount
                proxy.colorPanel = updated
            },
            onCommit: { value in
                let idx = min(max(Int(value.rounded()), 0), steps.count - 1)
                viewModel.setGrayscaleBlockCount(steps[idx])
            }
        )
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

private struct NavigatorPreviewContainer: View {
    @ObservedObject var proxy: WorkspaceViewModel.NavigatorPreviewProxy
    let viewModel: WorkspaceViewModel
    let visibleCanvasPolygon: [CanvasPoint]?
    let canvasSize: CanvasSize

    var body: some View {
        NavigatorPreviewPanel(
            sceneSnapshot: proxy.sceneSnapshot,
            redrawRevision: proxy.redrawRevision,
            visibleCanvasPolygon: visibleCanvasPolygon,
            canvasSize: canvasSize,
            viewModel: viewModel
        )
    }
}

private struct NavigatorPreviewPanel: View {
    let sceneSnapshot: CanvasSceneSnapshot
    let redrawRevision: UInt64
    let visibleCanvasPolygon: [CanvasPoint]?
    let canvasSize: CanvasSize
    let viewModel: WorkspaceViewModel

    var body: some View {
        GeometryReader { proxy in
            let presentation = CanvasPresentationBuilder.makePresentation(
                canvasSize: canvasSize,
                viewport: .stageOneDefault,
                availableWidth: proxy.size.width,
                availableHeight: proxy.size.height,
                padding: 10
            )
            let documentCenter = CanvasPoint(
                x: presentation.documentOrigin.x + (presentation.documentDisplaySize.x / 2),
                y: presentation.documentOrigin.y + (presentation.documentDisplaySize.y / 2)
            )

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.14))

                MetalCanvasHost(
                    sceneSnapshot: sceneSnapshot,
                    externalRedrawRevision: redrawRevision,
                    transformSelectionShape: nil,
                    metalContext: viewModel.metalContext,
                    layerSurfaceStore: viewModel.layerSurfaceStore,
                    activeTool: .brush,
                    viewportRotationDegrees: 0,
                    strokeResetToken: 0,
                    brushSize: 1,
                    isPanModeActive: false,
                    isTransformingSelection: false,
                    isFreeTransformDragging: false,
                    activeFreeTransformInteractionMode: nil,
                    transformPreview: .identity,
                    linearGradientPreview: nil,
                    sectorGradientPreview: nil,
                    gradientPreviewColor: .white,
                    gradientPaintJitterAmount: 0,
                    gradientPaintContrastAmount: 0,
                    gradientDistortionAmount: 0,
                    onStrokeBegan: {},
                    onStrokeInput: { _ in },
                    onStrokeEnded: {},
                    onFlushPendingBrushWork: { _ in nil },
                    onDrainPendingBrushCommitsInteractively: { _ in },
                    resolveBrushDisplayTexture: { layerID in
                        viewModel.brushDisplayTexture(for: layerID)
                    },
                    onEyedropperSample: { _ in },
                    onBucketFill: { _ in },
                    onCanvasClick: { _, _, _ in },
                    onCanvasHover: { _ in },
                    onSelectionBegan: { _, _ in },
                    onSelectionChanged: { _, _ in },
                    onSelectionEnded: { _, _ in },
                    onSelectionMouseDown: { _, _ in .idle },
                    onMoveSelectionPreview: { _, _ in },
                    onCommitSelectionMove: {},
                    onTransformBegan: { _, _, _ in },
                    onTransformChanged: { _, _ in },
                    onTransformEnded: { _, _ in },
                    onTransformOffsetChanged: { _ in },
                    onCanvasRotationChanged: { _ in },
                    onPanModeChanged: { _ in },
                    onToolShortcut: { _, _ in },
                    onKeyDown: { _ in false },
                    onKeyUp: { _ in false },
                    onModifierFlagsChanged: { _ in false },
                    onGradientDragBegan: { _, _ in },
                    onGradientDragChanged: { _, _ in },
                    onGradientDragEnded: { _, _ in },
                    onEnterGradientEditing: {},
                    onCancelCanvasTool: {},
                    onApplyGradientSession: {},
                    onClearSelection: {},
                    onApplyTransform: {},
                    onCancelTransform: {},
                    isLuminosityPreviewEnabled: false,
                    onAdjustBrushSize: { _ in }
                )
                .frame(
                    width: presentation.documentDisplaySize.x,
                    height: presentation.documentDisplaySize.y
                )
                .position(
                    x: documentCenter.x,
                    y: documentCenter.y
                )
                .allowsHitTesting(false)

                if let polygon = visibleCanvasPolygon, polygon.count >= 3 {
                    NavigatorVisibleRegionOverlay(
                        polygon: polygon,
                        presentation: presentation,
                        canvasSize: canvasSize
                    )
                    .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 168)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct NavigatorVisibleRegionOverlay: View {
    let polygon: [CanvasPoint]
    let presentation: CanvasPresentation
    let canvasSize: CanvasSize

    var body: some View {
        Path { path in
            guard let first = polygon.first else { return }
            path.move(to: mappedPoint(for: first))
            for point in polygon.dropFirst() {
                path.addLine(to: mappedPoint(for: point))
            }
            path.closeSubpath()
        }
        .stroke(Color.accentColor.opacity(0.96), lineWidth: 1.5)
    }

    private func mappedPoint(for point: CanvasPoint) -> CGPoint {
        let x = presentation.documentOrigin.x + (point.x / Double(canvasSize.width)) * presentation.documentDisplaySize.x
        let y = presentation.documentOrigin.y + (point.y / Double(canvasSize.height)) * presentation.documentDisplaySize.y
        return CGPoint(x: x, y: y)
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
        let previousPanel = context.coordinator.panel
        context.coordinator.panel = panel
        context.coordinator.onUpdatePoint = onUpdatePoint
        context.coordinator.onDragEnded = onDragEnded
        // NSView 拖动期间靠自身 needsDisplay 驱动指示圆移动，
        // 只有影响 SV 渐变图的属性变化时才触发完整重绘（避免拖动 SV 时重算整张图）
        let gradientChanged =
            Int(previousPanel.pickerHue.rounded()) != Int(panel.pickerHue.rounded()) ||
            Int(previousPanel.pickerLightness.rounded()) != Int(panel.pickerLightness.rounded()) ||
            Int(previousPanel.pickerSaturation.rounded()) != Int(panel.pickerSaturation.rounded()) ||
            Int(previousPanel.lightingHue.rounded()) != Int(panel.lightingHue.rounded()) ||
            Int(previousPanel.lightingStrength.rounded()) != Int(panel.lightingStrength.rounded())
        if gradientChanged || !nsView.hasDrawnOnce {
            nsView.needsDisplay = true
        }
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

private struct LongPressDraggableCell<Content: View>: NSViewRepresentable {
    let dragPayload: String
    let onActivate: () -> Void
    let onDragBegan: () -> Void
    let onDragEnded: () -> Void
    let content: Content

    init(
        dragPayload: String,
        onActivate: @escaping () -> Void,
        onDragBegan: @escaping () -> Void,
        onDragEnded: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.dragPayload = dragPayload
        self.onActivate = onActivate
        self.onDragBegan = onDragBegan
        self.onDragEnded = onDragEnded
        self.content = content()
    }

    func makeNSView(context: Context) -> LongPressDraggableCellNSView {
        let view = LongPressDraggableCellNSView()
        view.update(
            rootView: AnyView(content),
            dragPayload: dragPayload,
            onActivate: onActivate,
            onDragBegan: onDragBegan,
            onDragEnded: onDragEnded
        )
        return view
    }

    func updateNSView(_ nsView: LongPressDraggableCellNSView, context: Context) {
        nsView.update(
            rootView: AnyView(content),
            dragPayload: dragPayload,
            onActivate: onActivate,
            onDragBegan: onDragBegan,
            onDragEnded: onDragEnded
        )
    }
}

final class LongPressDraggableCellNSView: NSView, NSDraggingSource {
    private let longPressDuration: TimeInterval = 0.22
    private let dragThreshold: CGFloat = 3

    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private var dragPayload = ""
    private var onActivate: (() -> Void)?
    private var onDragBegan: (() -> Void)?
    private var onDragEnded: (() -> Void)?

    private var pressWorkItem: DispatchWorkItem?
    private var mouseDownLocation: CGPoint?
    private var isMousePressed = false
    private var isLongPressArmed = false
    private var didStartDragging = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        rootView: AnyView,
        dragPayload: String,
        onActivate: @escaping () -> Void,
        onDragBegan: @escaping () -> Void,
        onDragEnded: @escaping () -> Void
    ) {
        hostingView.rootView = rootView
        self.dragPayload = dragPayload
        self.onActivate = onActivate
        self.onDragBegan = onDragBegan
        self.onDragEnded = onDragEnded
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        resetPressState(keepingMousePressed: true)
        isMousePressed = true
        mouseDownLocation = convert(event.locationInWindow, from: nil)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isMousePressed, !self.didStartDragging else { return }
            self.isLongPressArmed = true
        }
        pressWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + longPressDuration, execute: workItem)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isMousePressed, isLongPressArmed, !didStartDragging,
              let mouseDownLocation else {
            return
        }

        let location = convert(event.locationInWindow, from: nil)
        let dx = location.x - mouseDownLocation.x
        let dy = location.y - mouseDownLocation.y
        guard hypot(dx, dy) >= dragThreshold else { return }

        beginDragSession(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let shouldActivate = isMousePressed && !didStartDragging && !isLongPressArmed
        resetPressState()

        if shouldActivate {
            onActivate?()
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        resetPressState()
        onDragEnded?()
    }

    private func beginDragSession(with event: NSEvent) {
        guard !dragPayload.isEmpty else { return }

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(dragPayload, forType: .string)
        pasteboardItem.setString(dragPayload, forType: NSPasteboard.PasteboardType(UTType.plainText.identifier))

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(bounds, contents: dragPreviewImage())

        didStartDragging = true
        onDragBegan?()
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    private func dragPreviewImage() -> NSImage {
        let image = NSImage(size: bounds.size)
        guard let representation = bitmapImageRepForCachingDisplay(in: bounds) else {
            return image
        }

        cacheDisplay(in: bounds, to: representation)
        image.addRepresentation(representation)
        return image
    }

    private func resetPressState(keepingMousePressed: Bool = false) {
        pressWorkItem?.cancel()
        pressWorkItem = nil
        mouseDownLocation = nil
        isLongPressArmed = false
        didStartDragging = false
        if !keepingMousePressed {
            isMousePressed = false
        }
    }
}

final class ColorSVPickerNSView: NSView {
    fileprivate weak var coordinator: ColorSVPickerView.Coordinator?
    fileprivate var hasDrawnOnce = false
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
        hasDrawnOnce = true
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
        let r: CGFloat = 6
        let circle = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(2)
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
                    .stroke(Color.white, lineWidth: 1.5)
                    .frame(width: proxy.size.width - 2, height: 4)
                    .position(
                        x: proxy.size.width / 2,
                        y: min(
                            max(CGFloat(displayHue / 360.0) * proxy.size.height, 2),
                            proxy.size.height - 2
                        )
                    )
                    .shadow(color: .black.opacity(0.35), radius: 1, x: 0, y: 1)
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
    let syncToken: String
    let fitImportedPreview: Bool
    let paintMode: TipPaintMode
    let drawingBrush: BrushSettings
    let onRequestPaintModeShortcut: (TipPaintMode) -> Void
    let onFocusChanged: (Bool) -> Void
    let onImportImage: (NSImage) -> Void
    let onUpdateMask: (Data) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onRequestPaintModeShortcut: onRequestPaintModeShortcut,
            onFocusChanged: onFocusChanged,
            onImportImage: onImportImage,
            onUpdateMask: onUpdateMask
        )
    }

    func makeNSView(context: Context) -> TipMaskEditorNSView {
        let view = TipMaskEditorNSView()
        view.coordinator = context.coordinator
        view.update(
            maskData: maskData,
            syncToken: syncToken,
            fitImportedPreview: fitImportedPreview,
            paintMode: paintMode,
            drawingBrush: drawingBrush
        )
        return view
    }

    func updateNSView(_ nsView: TipMaskEditorNSView, context: Context) {
        nsView.coordinator = context.coordinator
        nsView.update(
            maskData: maskData,
            syncToken: syncToken,
            fitImportedPreview: fitImportedPreview,
            paintMode: paintMode,
            drawingBrush: drawingBrush
        )
    }

    final class Coordinator: NSObject {
        let onRequestPaintModeShortcut: (TipPaintMode) -> Void
        let onFocusChanged: (Bool) -> Void
        let onImportImage: (NSImage) -> Void
        let onUpdateMask: (Data) -> Void

        init(
            onRequestPaintModeShortcut: @escaping (TipPaintMode) -> Void,
            onFocusChanged: @escaping (Bool) -> Void,
            onImportImage: @escaping (NSImage) -> Void,
            onUpdateMask: @escaping (Data) -> Void
        ) {
            self.onRequestPaintModeShortcut = onRequestPaintModeShortcut
            self.onFocusChanged = onFocusChanged
            self.onImportImage = onImportImage
            self.onUpdateMask = onUpdateMask
        }
    }
}

private final class TipMaskEditorNSView: NSView {
    weak var coordinator: TipMaskCanvasView.Coordinator?

    private var maskBytes = [UInt8](repeating: 0, count: tipMaskResolution * tipMaskResolution)
    private var livePreviewRGBAData = Data(
        repeating: 255,
        count: tipMaskResolution * tipMaskResolution * 4
    )
    private var paintMode: TipPaintMode = .round
    private var drawingBrush = BrushSettings.stageOneDefault
    private var fitImportedPreview = false
    private var lastPaintPoint: CGPoint?
    private var hoverLocation: CGPoint?
    private var hasLocalChanges = false
    private var externalSyncToken = ""
    private var livePreviewImage: CGImage?
    private var livePreviewImageDirty = true
    private var accumulatedDirtyRect: CGRect = .null
    private var strokeBaseMaskBytes: [UInt8]?
    private var activeStrokePoints: [StrokePoint] = []
    private var shortcutContextArmed = false
    private var localKeyDownMonitor: Any?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 0
        layer?.masksToBounds = true
        registerForDraggedTypes([.fileURL, .tiff, .png])
        installLocalKeyDownMonitor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        maskData: Data?,
        syncToken: String,
        fitImportedPreview: Bool,
        paintMode: TipPaintMode,
        drawingBrush: BrushSettings
    ) {
        self.paintMode = paintMode
        self.drawingBrush = drawingBrush

        if syncToken != externalSyncToken {
            externalSyncToken = syncToken
            hasLocalChanges = false
            strokeBaseMaskBytes = nil
            activeStrokePoints = []
            self.fitImportedPreview = fitImportedPreview
            let nextMask = normalizedMaskData(maskData)
            if nextMask != maskBytes {
                maskBytes = nextMask
                rebuildLivePreviewRGBADataFromMask()
            }
            livePreviewImageDirty = true
            needsDisplay = true
            return
        }

        if !hasLocalChanges {
            if self.fitImportedPreview != fitImportedPreview {
                self.fitImportedPreview = fitImportedPreview
                livePreviewImageDirty = true
                needsDisplay = true
            }

            if maskData == nil, maskBytes.contains(where: { $0 != 0 }) {
                maskBytes = [UInt8](repeating: 0, count: tipMaskResolution * tipMaskResolution)
                rebuildLivePreviewRGBADataFromMask()
                livePreviewImageDirty = true
                needsDisplay = true
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if let previewImage = resolvedPreviewImage() {
            let drawRect = previewDrawRect(for: previewImage)
            context.saveGState()
            context.interpolationQuality = .none
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
        shortcutContextArmed = true
        coordinator?.onFocusChanged(true)
        let point = convert(event.locationInWindow, from: nil)
        let pressure = Float(event.pressure)
        hoverLocation = point
        lastPaintPoint = point
        hasLocalChanges = true
        fitImportedPreview = false
        livePreviewImageDirty = true
        accumulatedDirtyRect = .null
        strokeBaseMaskBytes = maskBytes
        activeStrokePoints = []
        paintSegment(from: point, to: point, pressure: max(pressure, 0.1))
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let pressure = Float(event.pressure)
        hoverLocation = point
        paintSegment(from: lastPaintPoint ?? point, to: point, pressure: max(pressure, 0.1))
        lastPaintPoint = point
    }

    override func mouseUp(with event: NSEvent) {
        hoverLocation = convert(event.locationInWindow, from: nil)
        lastPaintPoint = nil
        if hasLocalChanges {
            livePreviewImageDirty = true
            needsDisplay = true
            coordinator?.onUpdateMask(Data(maskBytes))
            hasLocalChanges = false
        }
        strokeBaseMaskBytes = nil
        activeStrokePoints = []
        accumulatedDirtyRect = .null
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
        if handleShortcutEvent(event) {
            return
        }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            shortcutContextArmed = true
            coordinator?.onFocusChanged(true)
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            shortcutContextArmed = false
            coordinator?.onFocusChanged(false)
        }
        return resigned
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

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, let localKeyDownMonitor {
            NSEvent.removeMonitor(localKeyDownMonitor)
            self.localKeyDownMonitor = nil
        } else if newWindow != nil, localKeyDownMonitor == nil {
            installLocalKeyDownMonitor()
        }
    }

    private func installLocalKeyDownMonitor() {
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard self.isShortcutContextActive(for: event) else { return event }
            return self.handleShortcutEvent(event) ? nil : event
        }
    }

    private func isShortcutContextActive(for event: NSEvent) -> Bool {
        guard event.window === window else { return false }
        if window?.firstResponder === self {
            return true
        }
        return shortcutContextArmed
    }

    private func handleShortcutEvent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if modifiers.contains(.command) || modifiers.contains(.control) {
            if event.charactersIgnoringModifiers?.lowercased() == "v" {
                return importImageFromPasteboard(NSPasteboard.general)
            }
            return false
        }
        guard modifiers.isEmpty,
              let shortcut = event.charactersIgnoringModifiers?.lowercased()
        else {
            return false
        }
        switch shortcut {
        case "e":
            coordinator?.onRequestPaintModeShortcut(.eraser)
            return true
        case "b":
            coordinator?.onRequestPaintModeShortcut(.round)
            return true
        default:
            return false
        }
    }

    private func paintSegment(from start: CGPoint, to end: CGPoint, pressure: Float) {
        let editableRect = previewDrawRect(for: nil)
        guard editableRect.width > 0, editableRect.height > 0 else { return }

        let startMaskPoint = maskPoint(for: start, in: editableRect)
        let endMaskPoint = maskPoint(for: end, in: editableRect)
        let brush = strokeBrushSettings(for: paintMode)
        let startPoint = StrokePoint(x: Double(startMaskPoint.x), y: Double(startMaskPoint.y), pressure: pressure)
        let endPoint = StrokePoint(x: Double(endMaskPoint.x), y: Double(endMaskPoint.y), pressure: pressure)

        if activeStrokePoints.isEmpty {
            activeStrokePoints = [startPoint]
        }
        activeStrokePoints.append(endPoint)

        var scratchSamplingState: BrushStrokeSamplingState?
        guard let alphaBytes = StageOneBrushPreviewRasterizer.strokeAlphaBytes(
            for: brush,
            tool: paintMode == .eraser ? .eraser : .brush,
            resolution: tipMaskResolution,
            points: activeStrokePoints,
            samplingState: &scratchSamplingState,
            flushPendingSamples: true
        ) else {
            return
        }

        maskBytes = strokeBaseMaskBytes ?? [UInt8](repeating: 0, count: tipMaskResolution * tipMaskResolution)
        mergeRenderedStrokeAlphaBytes(
            alphaBytes,
            paintMode: paintMode,
            buildMode: brush.buildMode
        )
        flushIncrementalDisplayIfNeeded()
    }

    private func currentRadius() -> Double {
        min(max(Double(drawingBrush.size) * 0.4, 3.0), 28.0)
    }

    private func flushIncrementalDisplayIfNeeded() {
        guard !accumulatedDirtyRect.isNull else { return }
        livePreviewImageDirty = true
        setNeedsDisplay(accumulatedDirtyRect.insetBy(dx: -2, dy: -2))
        accumulatedDirtyRect = .null
    }

    private func mergeRenderedStrokeAlphaBytes(
        _ alphaBytes: [UInt8],
        paintMode: TipPaintMode,
        buildMode: BrushBuildMode
    ) {
        guard alphaBytes.count == maskBytes.count else { return }

        var minX = tipMaskResolution
        var minY = tipMaskResolution
        var maxX = -1
        var maxY = -1

        for index in alphaBytes.indices {
            let alpha = alphaBytes[index]
            guard alpha > 0 else { continue }

            let existing = maskBytes[index]
            let updated: UInt8
            switch paintMode {
            case .eraser:
                updated = UInt8(max(0, Int(existing) - Int(alpha)))
            case .round, .square:
                if buildMode == .buildUp {
                    updated = UInt8(min(255, Int(existing) + Int(alpha)))
                } else {
                    updated = max(existing, alpha)
                }
            }

            guard updated != existing else { continue }
            maskBytes[index] = updated

            let x = index % tipMaskResolution
            let y = index / tipMaskResolution
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }

        guard maxX >= minX, maxY >= minY else { return }
        updateLivePreviewRGBAData(minX: minX, maxX: maxX, minY: minY, maxY: maxY)

        let editableRect = previewDrawRect(for: nil)
        let scaleX = editableRect.width / CGFloat(tipMaskResolution)
        let scaleY = editableRect.height / CGFloat(tipMaskResolution)
        let dirtyViewRect = CGRect(
            x: editableRect.minX + CGFloat(minX) * scaleX - 1,
            y: editableRect.minY + CGFloat(minY) * scaleY - 1,
            width: CGFloat(maxX - minX + 1) * scaleX + 2,
            height: CGFloat(maxY - minY + 1) * scaleY + 2
        )
        accumulatedDirtyRect = accumulatedDirtyRect.isNull ? dirtyViewRect : accumulatedDirtyRect.union(dirtyViewRect)
    }

    private func maskPoint(for viewPoint: CGPoint, in editableRect: CGRect) -> CGPoint {
        let normalizedX = min(max((viewPoint.x - editableRect.minX) / editableRect.width, 0), 1)
        let normalizedY = min(max((viewPoint.y - editableRect.minY) / editableRect.height, 0), 1)
        return CGPoint(
            x: normalizedX * CGFloat(tipMaskResolution - 1),
            y: normalizedY * CGFloat(tipMaskResolution - 1)
        )
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

    private func resolvedPreviewImage() -> CGImage? {
        if fitImportedPreview {
            return StageOneBrushPreviewRasterizer.editorMaskImage(
                from: Data(maskBytes),
                resolution: tipMaskResolution,
                cropToContent: true
            )
        }

        if livePreviewImageDirty || livePreviewImage == nil {
            livePreviewImage = makeLivePreviewImage()
            livePreviewImageDirty = false
        }
        return livePreviewImage
    }

    private func rebuildLivePreviewRGBADataFromMask() {
        updateLivePreviewRGBAData(
            minX: 0,
            maxX: tipMaskResolution - 1,
            minY: 0,
            maxY: tipMaskResolution - 1
        )
    }

    private func updateLivePreviewRGBAData(minX: Int, maxX: Int, minY: Int, maxY: Int) {
        guard minX <= maxX, minY <= maxY else { return }

        livePreviewRGBAData.withUnsafeMutableBytes { rawBytes in
            guard let destinationBaseAddress = rawBytes.bindMemory(to: UInt8.self).baseAddress else { return }

            for y in minY...maxY {
                let rowOffset = y * tipMaskResolution
                for x in minX...maxX {
                    let sourceIndex = rowOffset + x
                    let grayscale = 255 - maskBytes[sourceIndex]
                    let destinationIndex = sourceIndex * 4
                    destinationBaseAddress[destinationIndex] = grayscale
                    destinationBaseAddress[destinationIndex + 1] = grayscale
                    destinationBaseAddress[destinationIndex + 2] = grayscale
                    destinationBaseAddress[destinationIndex + 3] = 255
                }
            }
        }
    }

    private func makeLivePreviewImage() -> CGImage? {
        let bytesPerPixel = 4
        let bytesPerRow = tipMaskResolution * bytesPerPixel

        guard
            let provider = CGDataProvider(data: livePreviewRGBAData as CFData),
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

    private func strokeBrushSettings(for paintMode: TipPaintMode) -> BrushSettings {
        var brush = drawingBrush
        switch paintMode {
        case .square:
            brush.tipShape = .square
            brush.customTipSourceSemantic = .procedural
            brush.customTipAssetID = nil
            brush.customTipImportedSourceInfo = nil
            brush.customTipMaskData = nil
            brush.customTipEnvelopeMaskData = nil
        case .round, .eraser:
            break
        }
        return brush
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

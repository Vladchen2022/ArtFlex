import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

private let tipMaskResolution = 256
private let topInspectorPanelHeight: CGFloat = 264
private let topInspectorSectionSpacing: CGFloat = 10
private let topInspectorControlSpacing: CGFloat = 6
private let topInspectorControlButtonWidth: CGFloat = 24
private let topInspectorControlButtonHeight: CGFloat = 22
private let topInspectorControlCornerRadius: CGFloat = 7
private let topInspectorControlIconSize: CGFloat = 11.5
private let topInspectorPanelPadding: CGFloat = 12
private let rightInspectorHorizontalPadding: CGFloat = 12
private let rightInspectorColumnSpacing: CGFloat = 12
private let rightInspectorPanelSpacing: CGFloat = 12
private let inspectorPanelPadding: CGFloat = 12
private let standardInspectorToolMinimumHeight: CGFloat = 200
private let standardInspectorLayerMinimumHeight: CGFloat = 180

private enum BrushParameterSliderScale {
    case linear
    case logarithmic
}

private struct BrushParameterSliderRow: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let scale: BrushParameterSliderScale
    let formatter: (Double) -> String
    let onPreview: (Double) -> Void
    let onCommit: (Double) -> Void

    @State private var sliderPosition: Double
    @State private var valueText: String
    @State private var isDragging = false
    @State private var lastPreviewTime = Date.distantPast
    @FocusState private var isValueFieldFocused: Bool

    private let previewThrottleInterval: TimeInterval = 0.05

    init(
        title: String,
        value: Double,
        range: ClosedRange<Double>,
        scale: BrushParameterSliderScale = .linear,
        formatter: @escaping (Double) -> String,
        onPreview: @escaping (Double) -> Void,
        onCommit: @escaping (Double) -> Void
    ) {
        self.title = title
        self.value = value
        self.range = range
        self.scale = scale
        self.formatter = formatter
        self.onPreview = onPreview
        self.onCommit = onCommit
        _sliderPosition = State(initialValue: Self.sliderPosition(for: value, range: range, scale: scale))
        _valueText = State(initialValue: formatter(value))
    }

    var body: some View {
        HStack(spacing: 7) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.84))
                .frame(width: 58, alignment: .leading)

            Slider(
                value: $sliderPosition,
                in: sliderRange,
                onEditingChanged: handleDraggingChanged
            )
            .onChange(of: sliderPosition) { _, newPosition in
                guard isDragging else { return }
                let newValue = resolvedValue(for: newPosition)
                valueText = formatter(newValue)
                let now = Date()
                guard now.timeIntervalSince(lastPreviewTime) >= previewThrottleInterval else { return }
                lastPreviewTime = now
                onPreview(newValue)
            }

            TextField("", text: $valueText)
                .textFieldStyle(.plain)
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.96))
                .multilineTextAlignment(.trailing)
                .focused($isValueFieldFocused)
                .onSubmit(commitTextValue)
                .frame(width: 48, height: 20)
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.black.opacity(isValueFieldFocused ? 0.28 : 0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(
                            isValueFieldFocused ? Color.accentColor.opacity(0.7) : Color.white.opacity(0.06),
                            lineWidth: 1
                        )
                )
        }
        .onChange(of: value) { _, newValue in
            guard !isDragging, !isValueFieldFocused else { return }
            sliderPosition = Self.sliderPosition(for: newValue, range: range, scale: scale)
            valueText = formatter(newValue)
        }
        .onChange(of: isValueFieldFocused) { wasFocused, focused in
            if wasFocused, !focused {
                commitTextValue()
            }
        }
    }

    private var sliderRange: ClosedRange<Double> {
        scale == .linear ? range : 0...1
    }

    private func handleDraggingChanged(_ dragging: Bool) {
        isDragging = dragging
        if dragging {
            sliderPosition = Self.sliderPosition(for: value, range: range, scale: scale)
            valueText = formatter(value)
        } else {
            let finalValue = resolvedValue(for: sliderPosition)
            valueText = formatter(finalValue)
            onPreview(finalValue)
            onCommit(finalValue)
        }
    }

    private func commitTextValue() {
        let allowed = valueText.filter { "0123456789.-".contains($0) }
        guard let parsed = Double(allowed), parsed.isFinite else {
            valueText = formatter(value)
            return
        }
        let clamped = min(max(parsed, range.lowerBound), range.upperBound)
        sliderPosition = Self.sliderPosition(for: clamped, range: range, scale: scale)
        valueText = formatter(clamped)
        onPreview(clamped)
        onCommit(clamped)
    }

    private func resolvedValue(for position: Double) -> Double {
        switch scale {
        case .linear:
            return min(max(position, range.lowerBound), range.upperBound)
        case .logarithmic:
            let lower = max(range.lowerBound, 0.000_001)
            let upper = max(range.upperBound, lower)
            let exponent = min(max(position, 0), 1)
            return lower * pow(upper / lower, exponent)
        }
    }

    private static func sliderPosition(
        for value: Double,
        range: ClosedRange<Double>,
        scale: BrushParameterSliderScale
    ) -> Double {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        switch scale {
        case .linear:
            return clamped
        case .logarithmic:
            let lower = max(range.lowerBound, 0.000_001)
            let upper = max(range.upperBound, lower)
            guard upper > lower else { return 0 }
            return log(clamped / lower) / log(upper / lower)
        }
    }
}

func rightInspectorColumnWidth(totalWidth: CGFloat) -> CGFloat {
    max(
        0,
        (totalWidth - (rightInspectorHorizontalPadding * 2) - rightInspectorColumnSpacing) / 2
    )
}

func rightInspectorContentHeight(totalHeight: CGFloat) -> CGFloat {
    max(0, totalHeight - (rightInspectorHorizontalPadding * 2))
}

func rightInspectorUsesStructuredBlockReferenceWorkspace(activeTool: ToolKind) -> Bool {
    activeTool == .blockReference
}

func rightInspectorUsesTextureLibrary(activeTool: ToolKind) -> Bool {
    activeTool == .lassoFill
        || activeTool == .textureFill
        || activeTool == .colorVitalization
}

func rightInspectorUsesCompactParameterLayout(
    activeTool: ToolKind,
    isBrushTab: Bool,
    usesTextureFillControls: Bool
) -> Bool {
    guard isBrushTab else { return true }

    switch activeTool {
    case .brightnessAdjust, .colorVitalization, .eyedropper, .perspective, .textureFill:
        return false
    case .brush, .eraser, .smudge, .straightLine:
        return true
    case .lassoFill:
        return !usesTextureFillControls
    default:
        return true
    }
}

func topInspectorPanelContentWidth(panelWidth: CGFloat) -> CGFloat {
    max(0, panelWidth - (topInspectorPanelPadding * 2))
}

private enum TipImageLibrarySheetTarget: String, Identifiable {
    case primary
    case compoundSecondary
    case textureFill

    var id: String { rawValue }

    var title: String {
        switch self {
        case .primary:
            return "主笔尖图片资料库"
        case .compoundSecondary:
            return "组合笔刷次笔尖图片资料库"
        case .textureFill:
            return "纹理填充素材库"
        }
    }
}

private enum BrushTipCanvasDisplayMode {
    case edit
    case strokePreview
}

private struct BrushTipImportCandidate: Identifiable {
    let id = UUID()
    let image: NSImage
    let sourceLabel: String
}

private struct PressAndHoldActionButton: View {
    let title: String
    let isEnabled: Bool
    let isPressed: Bool
    let onPressChanged: (Bool) -> Void

    @State private var localPressActive = false

    var body: some View {
        let active = isPressed || localPressActive

        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.white.opacity(isEnabled ? 0.92 : 0.42))
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(active ? Color.accentColor.opacity(0.22) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        active ? Color.accentColor.opacity(0.88) : Color.white.opacity(0.08),
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard isEnabled, !localPressActive else { return }
                        localPressActive = true
                        onPressChanged(true)
                    }
                    .onEnded { _ in
                        guard localPressActive else { return }
                        localPressActive = false
                        onPressChanged(false)
                    }
            )
            .onChange(of: isEnabled) { _, enabled in
                guard !enabled, localPressActive else { return }
                localPressActive = false
                onPressChanged(false)
            }
            .onDisappear {
                guard localPressActive else { return }
                localPressActive = false
                onPressChanged(false)
            }
            .opacity(isEnabled ? 1 : 0.72)
    }
}

private struct PatternThumbnailTile: View {
    let url: URL?
    let usesCheckerboard: Bool

    @State private var image: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(usesCheckerboard ? 0.08 : 0.04))

            if usesCheckerboard {
                PatternTransparencyBackdrop(squareSize: 8)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(2)
            }

            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: usesCheckerboard ? "circle.lefthalf.filled" : "photo")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.72))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            let loadedImage = await Task.detached(priority: .utility) {
                loadPatternThumbnailImage(from: url)
            }.value
            guard !Task.isCancelled else { return }
            image = loadedImage
        }
    }
}

private struct LayerThumbnailTile: View {
    let layerID: LayerID
    let revision: UInt64
    let load: () async -> CGImage?

    @State private var image: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.06))
                .frame(width: 24, height: 24)

            if let image {
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
        .task(id: revision) {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            guard let loadedImage = await load(), !Task.isCancelled else { return }
            image = loadedImage
        }
        .accessibilityIdentifier("layer-thumbnail-\(layerID.rawValue.uuidString)")
    }
}

private struct TextureFillPreviewRequest: Equatable, Sendable {
    let brush: BrushSettings
    let tipSettings: TextureFillTipSettings
    let color: RGBAColor
}

private struct TextureFillResultPreview: View {
    let request: TextureFillPreviewRequest

    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color.white

            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.black.opacity(0.42))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        }
        .task(id: request) {
            let nextImage = await Task.detached(priority: .userInitiated) {
                StageOneBrushPreviewRasterizer.textureFillPreviewImage(
                    for: request.brush,
                    tipSettings: request.tipSettings,
                    color: request.color
                )
            }.value
            guard !Task.isCancelled else { return }
            image = nextImage
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("纹理填充结果预览")
        .accessibilityValue("实际填充的随机分布和方向会随手势变化")
    }
}

private struct TextureFillLibraryThumbnailTile: View {
    let request: TextureFillPreviewRequest

    @State private var image: CGImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.white

                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.black.opacity(0.42))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .aspectRatio(1, contentMode: .fit)
        .task(id: request) {
            let nextImage = await Task.detached(priority: .utility) {
                StageOneBrushPreviewRasterizer.textureFillPreviewImage(
                    for: request.brush,
                    tipSettings: request.tipSettings,
                    color: request.color
                )
            }.value
            guard !Task.isCancelled else { return }
            image = nextImage
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("纹理预设缩略图")
    }
}

private nonisolated func loadPatternThumbnailImage(from url: URL) -> CGImage? {
    guard
        let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        return nil
    }
    return squareFilledPatternThumbnailImage(from: image, targetDimension: 256) ?? image
}

private func cropVisibleContentIfPossible(_ image: CGImage) -> CGImage? {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else { return nil }

    guard
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else {
        return nil
    }

    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    guard let data = context.data else { return nil }
    let bytes = data.assumingMemoryBound(to: UInt8.self)

    var minX = width
    var minY = height
    var maxX = -1
    var maxY = -1

    for y in 0..<height {
        for x in 0..<width {
            let alphaIndex = ((y * width) + x) * 4 + 3
            if bytes[alphaIndex] > 0 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
    }

    guard maxX >= minX, maxY >= minY else {
        return image
    }

    let cropRect = CGRect(
        x: minX,
        y: minY,
        width: maxX - minX + 1,
        height: maxY - minY + 1
    )

    return image.cropping(to: cropRect) ?? image
}

private func squareFilledPatternThumbnailImage(
    from image: CGImage,
    targetDimension: Int
) -> CGImage? {
    let contentImage = cropVisibleContentIfPossible(image) ?? image
    guard targetDimension > 0,
          let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil,
            width: targetDimension,
            height: targetDimension,
            bitsPerComponent: 8,
            bytesPerRow: targetDimension * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else {
        return nil
    }

    let dimension = CGFloat(targetDimension)
    let sourceWidth = CGFloat(contentImage.width)
    let sourceHeight = CGFloat(contentImage.height)
    let scale = max(dimension / sourceWidth, dimension / sourceHeight)
    let drawWidth = sourceWidth * scale
    let drawHeight = sourceHeight * scale
    let drawRect = CGRect(
        x: (dimension - drawWidth) * 0.5,
        y: (dimension - drawHeight) * 0.5,
        width: drawWidth,
        height: drawHeight
    )

    context.interpolationQuality = .high
    context.clear(CGRect(x: 0, y: 0, width: dimension, height: dimension))
    context.draw(contentImage, in: drawRect)
    return context.makeImage()
}

struct RightInspectorView: View {
    static let standardWidth: CGFloat = 560
    private struct LayerPanelEntry {
        var layer: LayerRecord
        var depth: Int
    }

    private enum LibraryInspectorTab: String {
        case brush = "画笔库"
        case pattern = "图案库"
        case texture = "纹理库"
    }

    private enum LibraryFilter: Equatable {
        case all
        case favorites
        case color(BrushColorTag)
    }

    private enum LibraryRenameTarget: Identifiable {
        case brush(String)
        case pattern(UUID)
        case texture(UUID)

        var id: String {
            switch self {
            case .brush(let id): return "brush-\(id)"
            case .pattern(let id): return "pattern-\(id.uuidString)"
            case .texture(let id): return "texture-\(id.uuidString)"
            }
        }
    }

    private enum LibraryDeleteTarget: Identifiable {
        case brush(String, String)
        case pattern(UUID, String)
        case texture(UUID, String)

        var id: String {
            switch self {
            case .brush(let id, _): return "brush-\(id)"
            case .pattern(let id, _): return "pattern-\(id.uuidString)"
            case .texture(let id, _): return "texture-\(id.uuidString)"
            }
        }

        var displayName: String {
            switch self {
            case .brush(_, let name), .pattern(_, let name), .texture(_, let name):
                return name
            }
        }
    }

    private enum ParameterInspectorTab: String {
        case brush = "工具参数"
        case colorAdjustment = "调色"
        case curves = "曲线"
    }

    private enum TopInspectorTab: String {
        case tipShape = "笔尖形状设计"
        case navigator = "导航器"
    }

    @ObservedObject var viewModel: WorkspaceViewModel
    @State private var tipPaintMode: TipPaintMode = .round
    @State private var brushTipCanvasDisplayMode: BrushTipCanvasDisplayMode = .edit
    @State private var brushTipImportCandidate: BrushTipImportCandidate?
    @State private var presetShapeIndex = 0
    @State private var sprayPatternIndex = 0
    @State private var draggedBrushPresetID: String?
    @State private var draggedPatternLibraryItemID: UUID?
    @State private var draggedTextureFillLibraryItemID: UUID?
    @State private var draggedLayerID: LayerID?
    @State private var editingLayerID: LayerID?
    @State private var editingLayerName = ""
    @State private var showsLayerOpacityPopover = false
    @State private var layerDropInsertionIndex: Int?
    @State private var collapsedLayerGroupIDs: Set<LayerID> = []
    @State private var selectedLayerGroupID: LayerID?
    @FocusState private var focusedLayerNameFieldID: LayerID?
    @State private var isTipImageDropTarget = false
    @State private var isReferenceImageDropTarget = false
    @State private var isColorPaletteDropTarget = false
    @State private var highlightsPrimaryTipEditor = false
    @State private var primaryTipEditorHighlightGeneration = 0
    @State private var tipImageLibrarySheetTarget: TipImageLibrarySheetTarget?
    @State private var primaryTipImageLibraryPendingSelection: BrushTipImageAssetID?
    @State private var compoundSecondaryTipImageLibraryPendingSelection: BrushTipImageAssetID?
    @State private var textureFillTipImageLibraryPendingSelection: BrushTipImageAssetID?
    @State private var draggedTipImageLibraryAssetID: BrushTipImageAssetID?
    @State private var tipImageLibraryDropTargetID: BrushTipImageAssetID?
    @State private var showsCompoundBrushBuilder = false
    @State private var libraryInspectorTab: LibraryInspectorTab = .brush
    @State private var librarySearchText = ""
    @State private var libraryFilter: LibraryFilter = .all
    @State private var libraryRenameTarget: LibraryRenameTarget?
    @State private var libraryRenameText = ""
    @State private var libraryDeleteTarget: LibraryDeleteTarget?
    @State private var parameterInspectorTab: ParameterInspectorTab = .brush
    @State private var lastUsedAdjustmentTab: ParameterInspectorTab = .colorAdjustment
    @State private var parameterInspectorAutoRestoreTab: ParameterInspectorTab?
    @State private var topInspectorTab: TopInspectorTab = .navigator
    @State private var blockReferencePanelTab: BlockReferencePanelTab = .build
    @State private var navigatorZoomPercentText = "100"
    @State private var textureFillPreviewMaterialScale: Float?
    @State private var textureFillPreviewCoverage: Float?
    @State private var textureFillPreviewVariation: Float?
    @State private var textureFillPreviewPaintJitterAmount: Float?
    @State private var activeOilPaintBoundaryIndex: Int?
    var body: some View {
        ZStack {
            GeometryReader { proxy in
                if rightInspectorUsesStructuredBlockReferenceWorkspace(
                    activeTool: viewModel.workspace.toolSession.activeTool
                ) {
                    blockReferenceWorkspaceInspector(size: proxy.size)
                } else {
                    let columnWidth = rightInspectorColumnWidth(totalWidth: proxy.size.width)
                    let contentHeight = rightInspectorContentHeight(totalHeight: proxy.size.height)
                    HStack(alignment: .top, spacing: rightInspectorColumnSpacing) {
                        VStack(spacing: 12) {
                            InspectorPanel(title: "参考图") {
                                referenceImageSection
                            }

                            InspectorPanel(title: "颜色") {
                                ColorSectionView(
                                    proxy: viewModel.colorPanelProxy,
                                    viewModel: viewModel
                                )
                            }

                            InspectorPanel(title: "") {
                                libraryInspectorSection
                            }
                            .frame(maxHeight: .infinity, alignment: .top)
                        }
                        .frame(width: columnWidth)
                        .frame(height: contentHeight, alignment: .top)

                        VStack(spacing: 12) {
                            tipNavigatorPanel(width: columnWidth)
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

                            standardParameterAndLayerPanels
                        }
                        .frame(width: columnWidth)
                        .frame(height: contentHeight, alignment: .top)
                    }
                    .padding(rightInspectorHorizontalPadding)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                }
            }

        }
        .frame(width: Self.standardWidth)
        .frame(maxHeight: .infinity)
        .background(Color(red: 0.12, green: 0.12, blue: 0.13))
        .onAppear {
            syncNavigatorZoomPercentText()
            syncBrightnessAdjustmentEditorModeToTab()
            libraryInspectorTab = rightInspectorUsesTextureLibrary(
                activeTool: viewModel.workspace.toolSession.activeTool
            ) ? .texture : .brush
        }
        .onChange(of: viewModel.navigatorZoomPercent) { _, _ in
            syncNavigatorZoomPercentText()
        }
        .onChange(of: viewModel.canvasViewportMetricsRevision) { _, _ in
            syncNavigatorZoomPercentText()
        }
        .onChange(of: parameterInspectorTab) { _, _ in
            syncBrightnessAdjustmentEditorModeToTab()
        }
        .onChange(of: viewModel.workspace.toolSession.activeTool) { oldTool, newTool in
            guard oldTool != newTool else { return }
            if oldTool == .textureFill || newTool == .textureFill {
                textureFillPreviewMaterialScale = nil
                textureFillPreviewCoverage = nil
                textureFillPreviewVariation = nil
                textureFillPreviewPaintJitterAmount = nil
            }
            handleToolDrivenParameterInspectorTabChange(oldTool: oldTool, newTool: newTool)
            libraryInspectorTab = rightInspectorUsesTextureLibrary(activeTool: newTool)
                ? .texture
                : .brush
        }
        .onChange(of: viewModel.brushLibraryRevealRequestID) { _, _ in
            libraryInspectorTab = .brush
        }
        .sheet(item: $tipImageLibrarySheetTarget) { target in
            tipImageLibrarySheet(for: target) {
                tipImageLibrarySheetTarget = nil
            }
        }
        .sheet(isPresented: $showsCompoundBrushBuilder) {
            CompoundBrushBuilderSheet(viewModel: viewModel) {
                showsCompoundBrushBuilder = false
            }
        }
        .sheet(item: $brushTipImportCandidate) { candidate in
            BrushTipImportSheet(
                candidate: candidate,
                viewModel: viewModel,
                onCancel: { brushTipImportCandidate = nil },
                onApply: { options in
                    if viewModel.stageImportedBrushTipImage(
                        candidate.image,
                        sourceDescription: candidate.sourceLabel,
                        options: options
                    ) {
                        brushTipCanvasDisplayMode = .edit
                        brushTipImportCandidate = nil
                    }
                }
            )
        }
        .alert("重命名资源", isPresented: libraryRenameAlertBinding) {
            TextField("名称", text: $libraryRenameText)
            Button("取消", role: .cancel) {
                libraryRenameTarget = nil
            }
            Button("重命名") {
                commitLibraryRename()
            }
            .disabled(libraryRenameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("删除资源？", isPresented: libraryDeleteAlertBinding) {
            Button("取消", role: .cancel) {
                libraryDeleteTarget = nil
            }
            Button("删除", role: .destructive) {
                commitLibraryDelete()
            }
        } message: {
            Text("“\(libraryDeleteTarget?.displayName ?? "")”会移入最近删除，可在当前库中撤销。")
        }
    }

    private var parameterInspectorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if viewModel.workspace.toolSession.activeTool != .colorVitalization {
                parameterInspectorTabs
            }

            if parameterInspectorTab == .brush && usesFullBrushParameterControls {
                pinnedBrushCommonControls
            }

            ScrollView(.vertical, showsIndicators: true) {
                parameterInspectorContent
                .padding(.trailing, 3)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var compactParameterInspectorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if viewModel.workspace.toolSession.activeTool != .colorVitalization {
                parameterInspectorTabs
            }
            if parameterInspectorTab == .brush && usesFullBrushParameterControls {
                pinnedBrushCommonControls
            }
            parameterInspectorContent
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var parameterInspectorTabs: some View {
        HStack(spacing: 8) {
            parameterInspectorTabButton(.brush)
            parameterInspectorTabButton(.colorAdjustment)
            parameterInspectorTabButton(.curves)
        }
    }

    @ViewBuilder
    private var parameterInspectorContent: some View {
        if viewModel.workspace.toolSession.activeTool == .colorVitalization {
            colorVitalizationControls
        } else if parameterInspectorTab == .colorAdjustment {
            colorAdjustmentSection
        } else if parameterInspectorTab == .curves {
            curveAdjustmentSection
        } else {
            brushSection
        }
    }

    @ViewBuilder
    private var standardParameterAndLayerPanels: some View {
        if usesCompactParameterInspectorLayout {
            VStack(spacing: rightInspectorPanelSpacing) {
                InspectorPanel(title: "") {
                    compactParameterInspectorSection
                }
                .fixedSize(horizontal: false, vertical: true)

                InspectorPanel(title: "图层", fillsAvailableHeight: true) {
                    layersSection
                }
                .frame(
                    minHeight: standardInspectorLayerMinimumHeight,
                    maxHeight: .infinity,
                    alignment: .top
                )
            }
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
            VSplitView {
                InspectorPanel(title: "", fillsAvailableHeight: true) {
                    parameterInspectorSection
                }
                .frame(
                    minHeight: standardInspectorToolMinimumHeight,
                    idealHeight: 390,
                    maxHeight: .infinity,
                    alignment: .top
                )
                .padding(.bottom, rightInspectorPanelSpacing / 2)

                InspectorPanel(title: "图层", fillsAvailableHeight: true) {
                    layersSection
                }
                .frame(
                    minHeight: standardInspectorLayerMinimumHeight,
                    idealHeight: 380,
                    maxHeight: .infinity,
                    alignment: .top
                )
                .padding(.top, rightInspectorPanelSpacing / 2)
            }
        }
    }

    private var usesCompactParameterInspectorLayout: Bool {
        rightInspectorUsesCompactParameterLayout(
            activeTool: viewModel.workspace.toolSession.activeTool,
            isBrushTab: parameterInspectorTab == .brush,
            usesTextureFillControls: isLassoFillToolActive && viewModel.lassoFillMode == .texture
        )
    }

    private func parameterInspectorTabButton(_ tab: ParameterInspectorTab) -> some View {
        let isSelected = parameterInspectorTab == tab
        return inspectorTabButton(title: tab.rawValue, isSelected: isSelected) {
            handleParameterInspectorTabSelection(tab)
        }
    }

    private func handleParameterInspectorTabSelection(_ tab: ParameterInspectorTab) {
        switch tab {
        case .brush:
            parameterInspectorTab = .brush
        case .colorAdjustment:
            guard viewModel.resolveCurveAdjustmentSessionIfNeeded(reason: .panelChange) else {
                return
            }
            parameterInspectorTab = .colorAdjustment
            lastUsedAdjustmentTab = .colorAdjustment
        case .curves:
            guard viewModel.resolveColorAdjustmentSessionIfNeeded(reason: .panelChange) else {
                return
            }
            parameterInspectorTab = .curves
            lastUsedAdjustmentTab = .curves
        }
    }

    private func handleToolDrivenParameterInspectorTabChange(
        oldTool: ToolKind,
        newTool: ToolKind
    ) {
        if newTool == .textureFill || newTool == .colorVitalization || newTool == .smartSelection {
            parameterInspectorTab = .brush
            parameterInspectorAutoRestoreTab = nil
            return
        }

        let oldToolUsesColorAdjustmentPanel = usesColorAdjustmentParameterPanel(oldTool)
        let newToolUsesColorAdjustmentPanel = usesColorAdjustmentParameterPanel(newTool)

        switch (oldToolUsesColorAdjustmentPanel, newToolUsesColorAdjustmentPanel) {
        case (false, true):
            parameterInspectorAutoRestoreTab = parameterInspectorTab
            parameterInspectorTab = lastUsedAdjustmentTab
        case (true, true):
            if parameterInspectorTab != .brush {
                parameterInspectorTab = lastUsedAdjustmentTab
            }
        case (true, false):
            if let restoreTab = parameterInspectorAutoRestoreTab {
                parameterInspectorTab = restoreTab
            }
            parameterInspectorAutoRestoreTab = nil
        case (false, false):
            break
        }
    }

    private func usesColorAdjustmentParameterPanel(_ tool: ToolKind) -> Bool {
        switch tool {
        case .brightnessAdjust, .lassoSelection, .smartSelection, .rectangleSelection, .ellipseSelection:
            return true
        default:
            return false
        }
    }

    private func syncBrightnessAdjustmentEditorModeToTab() {
        switch parameterInspectorTab {
        case .colorAdjustment:
            viewModel.setBrightnessAdjustmentEditorMode(.colorParameters)
        case .curves:
            viewModel.setBrightnessAdjustmentEditorMode(.curves)
        case .brush:
            break
        }
    }

    private var referenceImageSection: some View {
        let selectedReferenceAsset = viewModel.selectedReferenceImageSlot?.asset

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(viewModel.referenceImageSlots) { slot in
                    referenceImageSlotButton(slot)
                }
            }

            referenceImagePreviewArea(selectedAsset: selectedReferenceAsset)

            HStack(spacing: 10) {
                Button {
                    viewModel.openReferenceImageFloatingPanel()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: topInspectorControlIconSize, weight: .bold))
                        .foregroundStyle(Color.white.opacity(viewModel.selectedReferenceImageSlot?.asset == nil ? 0.42 : 0.92))
                        .frame(width: topInspectorControlButtonWidth, height: topInspectorControlButtonHeight)
                        .background(
                            RoundedRectangle(cornerRadius: topInspectorControlCornerRadius)
                                .fill(Color.white.opacity(0.10))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: topInspectorControlCornerRadius)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.selectedReferenceImageSlot?.asset == nil)
                .buttonTooltip("放大参考图")

                Button {
                    viewModel.toggleCanvasLuminosityReference()
                } label: {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: topInspectorControlIconSize, weight: .bold))
                        .foregroundStyle(Color.white.opacity(viewModel.isCanvasLuminosityReferenceActive ? 0.98 : 0.86))
                        .frame(width: topInspectorControlButtonWidth, height: topInspectorControlButtonHeight)
                        .background(
                            RoundedRectangle(cornerRadius: topInspectorControlCornerRadius)
                                .fill(viewModel.isCanvasLuminosityReferenceActive ? Color.accentColor.opacity(0.92) : Color.white.opacity(0.10))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: topInspectorControlCornerRadius)
                                .stroke(
                                    viewModel.isCanvasLuminosityReferenceActive ? Color.accentColor.opacity(0.90) : Color.white.opacity(0.08),
                                    lineWidth: 1
                                )
                        )
                }
                .buttonStyle(.plain)
                .buttonTooltip("参考图黑白模式", help: "黑白模式 (LAB L通道)")

                referenceImagePickedColorSwatch

                Button {
                    viewModel.clearSelectedReferenceImage()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: topInspectorControlIconSize, weight: .bold))
                        .foregroundStyle(Color.white.opacity(viewModel.selectedReferenceImageSlot?.asset == nil ? 0.42 : 0.92))
                        .frame(width: topInspectorControlButtonWidth, height: topInspectorControlButtonHeight)
                        .background(
                            RoundedRectangle(cornerRadius: topInspectorControlCornerRadius)
                                .fill(Color.white.opacity(0.10))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: topInspectorControlCornerRadius)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.selectedReferenceImageSlot?.asset == nil)
                .buttonTooltip("清除当前参考图")
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .overlay {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(isReferenceImageDropTarget ? Color.accentColor.opacity(0.08) : Color.clear)

                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isReferenceImageDropTarget ? Color.accentColor.opacity(0.95) : Color.clear,
                        lineWidth: 2
                    )

                if isReferenceImageDropTarget {
                    Label("松开以载入参考图", systemImage: "photo.badge.plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.96))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.72))
                        )
                }
            }
            .allowsHitTesting(false)
        }
        .onDrop(
            of: [UTType.fileURL.identifier, UTType.image.identifier],
            isTargeted: $isReferenceImageDropTarget
        ) { providers in
            importReferenceImagesFromDrop(providers: providers)
        }
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

    @ViewBuilder
    private func referenceImagePreviewArea(selectedAsset: ReferenceImageAsset?) -> some View {
        let previewShell = ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.20))

            ReferenceImageViewer(
                asset: selectedAsset,
                backgroundColor: NSColor(calibratedWhite: 0.08, alpha: 1),
                onHoverColorChanged: { color in
                    viewModel.updateReferenceImagePreviewColor(color)
                },
                onPickColor: { color in
                    viewModel.confirmReferenceImagePickedColor(color)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if selectedAsset == nil {
                Text(viewModel.referenceImageLoadingSlotIDs.isEmpty ? "点击 1 - 5 或拖入图片" : "载入中…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.52))
            }
        }
        .frame(maxWidth: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )

        if let selectedAsset {
            let previewAspectRatio = CGFloat(max(selectedAsset.width, 1)) / CGFloat(max(selectedAsset.height, 1))
            previewShell
                .aspectRatio(previewAspectRatio, contentMode: .fit)
        } else {
            previewShell
                .frame(height: 56)
        }
    }

    private func referenceImageSlotButton(_ slot: ReferenceImageSlotState) -> some View {
        let isSelected = viewModel.selectedReferenceImageSlotID == slot.id
        let isLoading = viewModel.referenceImageLoadingSlotIDs.contains(slot.id)
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
            .overlay(alignment: .topTrailing) {
                if isLoaded {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                        .overlay {
                            Circle()
                                .stroke(Color.black.opacity(0.58), lineWidth: 1)
                        }
                        .padding(4)
                }
            }
        }
        .buttonStyle(.plain)
        .buttonTooltip("参考图 \(slot.labelText)")
        .accessibilityValue(isLoading ? "载入中" : (isLoaded ? "已载入" : "空"))
        .contextMenu {
            if isLoaded {
                Button("清除") {
                    viewModel.clearReferenceImageSlot(slot.id)
                }
            }
        }
    }

    private func importReferenceImagesFromDrop(providers: [NSItemProvider]) -> Bool {
        var acceptedProvider = false

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            acceptedProvider = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
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
                    _ = viewModel.importDroppedReferenceImages(from: [url])
                }
            }
        }

        for provider in providers
        where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) == false
            && provider.canLoadObject(ofClass: NSImage.self) {
            acceptedProvider = true
            provider.loadObject(ofClass: NSImage.self) { object, _ in
                guard let image = object as? NSImage else { return }
                DispatchQueue.main.async {
                    _ = viewModel.importDroppedReferenceImage(from: image)
                }
            }
        }

        return acceptedProvider
    }

    private func tipNavigatorPanel(width: CGFloat) -> some View {
        let contentWidth = topInspectorPanelContentWidth(panelWidth: width)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                topInspectorTabButton(.tipShape)
                topInspectorTabButton(.navigator)
            }

            Group {
                if topInspectorTab == .tipShape {
                    tipShapeSection
                        .onAppear {
                            viewModel.setBrushTipEditorVisible(true)
                        }
                        .onDisappear {
                            viewModel.setBrushTipEditorVisible(false)
                        }
                } else {
                    navigatorSection
                }
            }
        }
        .frame(
            width: contentWidth,
            height: topInspectorPanelHeight - (topInspectorPanelPadding * 2),
            alignment: .topLeading
        )
        .padding(topInspectorPanelPadding)
        .frame(width: width, height: topInspectorPanelHeight, alignment: .topLeading)
        .clipped()
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
        return inspectorTabButton(title: tab.rawValue, isSelected: isSelected) {
            topInspectorTab = tab
            if tab == .tipShape, parameterInspectorTab == .colorAdjustment {
                parameterInspectorTab = .brush
            }
        }
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

            HStack(spacing: 4) {
                compactToolButton(
                    systemImage: "arrow.down.right.and.arrow.up.left",
                    tooltip: "适合窗口 (Cmd+0)",
                    width: topInspectorControlButtonWidth,
                    height: topInspectorControlButtonHeight,
                    iconSize: topInspectorControlIconSize,
                    cornerRadius: topInspectorControlCornerRadius
                ) {
                    viewModel.fitCanvasToWindow()
                    syncNavigatorZoomPercentText()
                }
                .disabled(viewModel.isCanvasViewportLocked)

                compactToolButton(
                    systemImage: "viewfinder",
                    tooltip: "实际像素 100% (Cmd+1)",
                    width: topInspectorControlButtonWidth,
                    height: topInspectorControlButtonHeight,
                    iconSize: topInspectorControlIconSize,
                    cornerRadius: topInspectorControlCornerRadius
                ) {
                    viewModel.setCanvasToActualPixels()
                    syncNavigatorZoomPercentText()
                }
                .disabled(viewModel.isCanvasViewportLocked)

                compactToolButton(
                    systemImage: "minus",
                    tooltip: "缩小画布",
                    width: topInspectorControlButtonWidth,
                    height: topInspectorControlButtonHeight,
                    iconSize: topInspectorControlIconSize,
                    cornerRadius: topInspectorControlCornerRadius
                ) {
                    viewModel.setNavigatorZoomPercent(viewModel.navigatorZoomPercent / 1.25)
                }
                .disabled(viewModel.isCanvasViewportLocked)

                Slider(
                    value: Binding(
                        get: { NavigatorZoomMapping.sliderPosition(for: viewModel.navigatorZoomPercent) },
                        set: { viewModel.setNavigatorZoomPercent(NavigatorZoomMapping.percent(forSliderPosition: $0)) }
                    ),
                    in: 0...1
                )
                .frame(minWidth: 32, maxWidth: .infinity)
                .disabled(viewModel.isCanvasViewportLocked)

                compactToolButton(
                    systemImage: "plus",
                    tooltip: "放大画布",
                    width: topInspectorControlButtonWidth,
                    height: topInspectorControlButtonHeight,
                    iconSize: topInspectorControlIconSize,
                    cornerRadius: topInspectorControlCornerRadius
                ) {
                    viewModel.setNavigatorZoomPercent(viewModel.navigatorZoomPercent * 1.25)
                }
                .disabled(viewModel.isCanvasViewportLocked)

                HStack(spacing: 4) {
                    TextField("", text: $navigatorZoomPercentText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 34)
                        .onSubmit {
                            commitNavigatorZoomPercentText()
                        }

                    Text("%")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.66))
                }
                .padding(.horizontal, 4)
                .frame(height: topInspectorControlButtonHeight)
                .background(
                    RoundedRectangle(cornerRadius: topInspectorControlCornerRadius)
                        .fill(Color.black.opacity(0.18))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: topInspectorControlCornerRadius)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .disabled(viewModel.isCanvasViewportLocked)

                navigatorOptionsMenu
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var navigatorOptionsMenu: some View {
        Menu {
            Button("刷新导航器", systemImage: "arrow.clockwise") {
                viewModel.refreshNavigatorPreviewNow()
            }
            Button(
                viewModel.showsTransparencyCheckerboard ? "隐藏透明背景" : "显示透明背景",
                systemImage: "checkerboard.rectangle"
            ) {
                viewModel.showsTransparencyCheckerboard.toggle()
            }
            Button(
                viewModel.isPixelGridEnabled ? "隐藏高倍像素网格" : "显示高倍像素网格",
                systemImage: "grid"
            ) {
                viewModel.isPixelGridEnabled.toggle()
            }
            Divider()
            Button("归零画布旋转", systemImage: "rotate.left") {
                viewModel.setViewportRotation(0)
            }
            .disabled(viewModel.isCanvasViewportLocked || abs(viewModel.workspace.viewport.rotationDegrees) < 0.001)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: topInspectorControlIconSize, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.9))
                .frame(width: topInspectorControlButtonWidth, height: topInspectorControlButtonHeight)
                .background(
                    RoundedRectangle(cornerRadius: topInspectorControlCornerRadius)
                        .fill(Color.white.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: topInspectorControlCornerRadius)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        }
        .menuStyle(.borderlessButton)
        .buttonTooltip("导航器显示与画布选项")
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

    private var brushSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.workspace.toolSession.activeTool == .colorVitalization {
                colorVitalizationControls
            } else if viewModel.workspace.toolSession.activeTool == .eyedropper {
                eyedropperParameterControls
            } else if viewModel.workspace.toolSession.activeTool == .perspective {
                perspectiveParameterControls
            } else if viewModel.workspace.toolSession.activeTool == .bucket {
                bucketFillParameterControls
            } else if viewModel.workspace.toolSession.activeTool == .smartSelection {
                smartSelectionParameterControls
            } else if isLassoFillToolActive {
                lassoFillParameterControls
            } else if usesFillParameterControls {
                fillParameterControls
            } else if usesFullBrushParameterControls {
                fullBrushParameterControls
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var eyedropperParameterControls: some View {
        let settings = viewModel.workspace.toolSession.eyedropper
        return VStack(alignment: .leading, spacing: 9) {
            Text("吸管")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))

            VStack(alignment: .leading, spacing: 4) {
                Text("范围")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.68))
                Picker(
                    "范围",
                    selection: Binding(
                        get: { settings.sampleSize },
                        set: { viewModel.setEyedropperSampleSize($0) }
                    )
                ) {
                    Text("单点").tag(EyedropperSampleSize.point)
                    Text("3×3").tag(EyedropperSampleSize.threeByThree)
                    Text("5×5").tag(EyedropperSampleSize.fiveByFive)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("算法")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(settings.sampleSize == .point ? 0.36 : 0.68))
                Picker(
                    "算法",
                    selection: Binding(
                        get: { settings.statistic },
                        set: { viewModel.setEyedropperSampleStatistic($0) }
                    )
                ) {
                    Text("平均").tag(EyedropperSampleStatistic.average)
                    Text("中值").tag(EyedropperSampleStatistic.median)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .disabled(settings.sampleSize == .point)
                .opacity(settings.sampleSize == .point ? 0.45 : 1)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("来源")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.68))
                Picker(
                    "来源",
                    selection: Binding(
                        get: { settings.source },
                        set: { viewModel.setEyedropperSampleSource($0) }
                    )
                ) {
                    Text("当前层").tag(EyedropperSampleSource.currentLayer)
                    Text("可见层").tag(EyedropperSampleSource.allVisibleLayers)
                    Text("显示色").tag(EyedropperSampleSource.displayedColor)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
            }

            Divider()
                .overlay(Color.white.opacity(0.08))
                .padding(.vertical, 1)

            Toggle(
                "保留透明度",
                isOn: Binding(
                    get: { settings.preservesTransparency },
                    set: { viewModel.setEyedropperPreservesTransparency($0) }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.84))

            Toggle(
                "取色后返回上一个工具",
                isOn: Binding(
                    get: { settings.returnsToPreviousTool },
                    set: { viewModel.setEyedropperReturnsToPreviousTool($0) }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.84))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var perspectiveParameterControls: some View {
        if let guide = viewModel.perspectiveGuide {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("透视辅助")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.92))
                    Spacer()
                    Text("\(guide.anchors.count) 条锚点")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.white.opacity(0.5))
                }

                perspectiveGuideMatchControls

                Picker(
                    "透视类型",
                    selection: Binding(
                        get: { guide.mode },
                        set: { viewModel.setPerspectiveGuideMode($0) }
                    )
                ) {
                    ForEach(PerspectiveGuideMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)

                if guide.mode == .threePoint {
                    Picker(
                        "第三消失点",
                        selection: Binding(
                            get: { guide.verticalDirection },
                            set: { viewModel.setPerspectiveVerticalDirection($0) }
                        )
                    ) {
                        ForEach(PerspectiveVerticalDirection.allCases, id: \.self) { direction in
                            Text(direction.displayName).tag(direction)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                }

                HStack(spacing: 12) {
                    Toggle(
                        "显示",
                        isOn: Binding(
                            get: { guide.isVisible },
                            set: { viewModel.setPerspectiveGuideVisibility($0) }
                        )
                    )
                    Toggle(
                        "锁定",
                        isOn: Binding(
                            get: { guide.isLocked },
                            set: { viewModel.setPerspectiveGuideLocked($0) }
                        )
                    )
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.82))

                compactParameterSlider(
                    title: "透明度",
                    valueText: "\(Int((guide.opacity * 100).rounded()))%",
                    value: Binding(
                        get: { Double(guide.opacity) },
                        set: { viewModel.setPerspectiveGuideOpacity(Float($0)) }
                    ),
                    range: 0.05...1,
                    onEditingChanged: viewModel.setPerspectiveGuideStyleEditing
                )

                compactParameterSlider(
                    title: "线宽",
                    valueText: String(format: "%.1f", guide.lineWidth),
                    value: Binding(
                        get: { Double(guide.lineWidth) },
                        set: { viewModel.setPerspectiveGuideLineWidth(Float($0)) }
                    ),
                    range: 0.5...4,
                    onEditingChanged: viewModel.setPerspectiveGuideStyleEditing
                )

                HStack(spacing: 8) {
                    Text("颜色")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.58))
                        .frame(width: 44, alignment: .leading)

                    ForEach(Array(perspectiveGuideColorPresets.enumerated()), id: \.offset) { _, color in
                        let isSelected = guide.color == color
                        Button {
                            viewModel.setPerspectiveGuideColor(color)
                        } label: {
                            Circle()
                                .fill(swiftUIColor(color))
                                .frame(width: 18, height: 18)
                                .overlay(
                                    Circle().stroke(
                                        isSelected ? Color.accentColor : Color.white.opacity(0.3),
                                        lineWidth: isSelected ? 2 : 1
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let selectedAnchor = guide.anchors.first(where: {
                    $0.id == viewModel.selectedPerspectiveAnchorID
                }) {
                    Divider().overlay(Color.white.opacity(0.08))

                    Text("所选锚点连接")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.62))

                    HStack(spacing: 10) {
                        perspectiveConnectionToggle(
                            title: guide.mode == .onePoint ? "主" : "左",
                            isOn: selectedAnchor.connectsLeft,
                            role: .left
                        )
                        if guide.mode != .onePoint {
                            perspectiveConnectionToggle(
                                title: "右",
                                isOn: selectedAnchor.connectsRight,
                                role: .right
                            )
                        }
                        if guide.mode == .threePoint {
                            perspectiveConnectionToggle(
                                title: "纵向",
                                isOn: selectedAnchor.connectsVertical,
                                role: .vertical
                            )
                        }
                    }

                    Button("删除所选锚点", role: .destructive) {
                        viewModel.deleteSelectedPerspectiveGuideAnchor()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Divider().overlay(Color.white.opacity(0.08))

                HStack(spacing: 8) {
                    Button("重置") {
                        viewModel.resetPerspectiveGuide()
                    }
                    Button("完全清除", role: .destructive) {
                        viewModel.clearPerspectiveGuide()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Text(guide.isLocked
                    ? "辅助线已锁定；切换到画笔后可穿透绘画。"
                    : "拖动消失点或地平线；点击画布添加辅助锚点。")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.48))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("透视辅助已清除")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))

                perspectiveGuideMatchControls

                Text("视平线、消失点和辅助锚点均已从当前文档移除。")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.48))
                    .fixedSize(horizontal: false, vertical: true)

                Button("重新创建透视辅助") {
                    viewModel.createPerspectiveGuide()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var perspectiveGuideMatchControls: some View {
        let state = viewModel.perspectiveGuideMatchState
        if state.isActive {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("匹配现有画面")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.9))
                    Spacer()
                    Text(viewModel.perspectiveGuideMatchCandidate == nil ? "描边中" : "已求解")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(viewModel.perspectiveGuideMatchCandidate == nil
                            ? Color.white.opacity(0.48)
                            : Color.cyan)
                }

                Picker("匹配方向", selection: Binding(
                    get: { state.activeRole },
                    set: { viewModel.setPerspectiveGuideMatchRole($0) }
                )) {
                    ForEach(PerspectiveGuideMatchRole.allCases, id: \.self) { role in
                        Text("\(role.displayName) \(state.lineCount(for: role))/2").tag(role)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)

                HStack(spacing: 6) {
                    Button("撤销一条") {
                        viewModel.undoLastPerspectiveGuideMatchLine()
                    }
                    .disabled(!state.hasAnyLines)
                    Button("清当前") {
                        viewModel.clearPerspectiveGuideMatchRole(state.activeRole)
                    }
                    .disabled(state.lineCount(for: state.activeRole) == 0)
                    Button("清空", role: .destructive) {
                        viewModel.clearPerspectiveGuideMatch()
                    }
                    .disabled(!state.hasAnyLines)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                HStack(spacing: 6) {
                    Button("退出匹配") {
                        viewModel.stopPerspectiveGuideMatch()
                    }
                    Button("完成并继续辅助线") {
                        viewModel.applyPerspectiveGuideMatch()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.perspectiveGuideMatchCandidate == nil)
                }
                .controlSize(.small)

                Text(viewModel.perspectiveGuideMatchInstruction)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.cyan.opacity(0.25), lineWidth: 1)
                    )
            )
        } else {
            Button("匹配现有画面…") {
                viewModel.startPerspectiveGuideMatch()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Text("依次描两组左右方向边和一组上/下方向边；只生成二维消失点与视平线，不创建体块或相机。")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.48))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var perspectiveGuideColorPresets: [RGBAColor] {
        [
            RGBAColor(red: 0.12, green: 0.68, blue: 1, alpha: 1),
            RGBAColor(red: 1, green: 0.24, blue: 0.22, alpha: 1),
            RGBAColor(red: 1, green: 0.78, blue: 0.12, alpha: 1),
            RGBAColor.white,
            RGBAColor.black
        ]
    }

    private func blockReferenceWorkspaceInspector(size: CGSize) -> some View {
        let columnWidth = rightInspectorColumnWidth(totalWidth: size.width)
        return ScrollView(.vertical, showsIndicators: true) {
            if viewModel.blockReferenceScene == nil {
                InspectorPanel(title: "体块参考") {
                    BlockReferenceParameterPanel(
                        viewModel: viewModel,
                        presentation: .context,
                        selectedTab: $blockReferencePanelTab
                    )
                    .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
                }
                .padding(rightInspectorHorizontalPadding)
            } else {
                HStack(alignment: .top, spacing: rightInspectorColumnSpacing) {
                    VStack(spacing: 12) {
                        InspectorPanel(title: "参考图") {
                            referenceImageSection
                        }

                        InspectorPanel(title: "", fillsAvailableHeight: true) {
                            BlockReferenceParameterPanel(
                                viewModel: viewModel,
                                presentation: .context,
                                selectedTab: $blockReferencePanelTab
                            )
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .frame(width: columnWidth)
                    .frame(maxHeight: .infinity, alignment: .top)

                    VStack(spacing: 12) {
                        InspectorPanel(title: "") {
                            BlockReferenceParameterPanel(
                                viewModel: viewModel,
                                presentation: .cameraSlots,
                                selectedTab: $blockReferencePanelTab
                            )
                        }

                        InspectorPanel(title: "") {
                            BlockReferenceParameterPanel(
                                viewModel: viewModel,
                                presentation: .library,
                                selectedTab: $blockReferencePanelTab
                            )
                        }

                        InspectorPanel(title: "场景对象", fillsAvailableHeight: true) {
                            BlockReferenceParameterPanel(
                                viewModel: viewModel,
                                presentation: .objects,
                                selectedTab: $blockReferencePanelTab
                            )
                        }
                        .frame(minHeight: 260, maxHeight: .infinity, alignment: .top)
                    }
                    .frame(width: columnWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .padding(rightInspectorHorizontalPadding)
                .frame(maxWidth: .infinity, minHeight: size.height, alignment: .top)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
    }
    private func swiftUIColor(_ color: RGBAColor) -> Color {
        Color(
            red: Double(color.red),
            green: Double(color.green),
            blue: Double(color.blue),
            opacity: Double(color.alpha)
        )
    }

    private func perspectiveConnectionToggle(
        title: String,
        isOn: Bool,
        role: PerspectiveVanishingPointRole
    ) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: { isOn },
                set: { viewModel.setSelectedPerspectiveAnchorConnection($0, role: role) }
            )
        )
        .toggleStyle(.button)
        .controlSize(.small)
    }

    private var usesFullBrushParameterControls: Bool {
        switch viewModel.workspace.toolSession.activeTool {
        case .brush, .eraser, .smudge, .straightLine, .brightnessAdjust, .colorVitalization:
            return true
        default:
            return false
        }
    }

    private var usesFillParameterControls: Bool {
        switch viewModel.workspace.toolSession.activeTool {
        case .linearGradient, .sectorGradient:
            return true
        default:
            return false
        }
    }

    private var isLassoFillToolActive: Bool {
        viewModel.workspace.toolSession.activeTool == .lassoFill
            || viewModel.workspace.toolSession.activeTool == .textureFill
    }

    private var lassoFillParameterControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 4) {
                Text("填充内容")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.68))

                Picker(
                    "填充内容",
                    selection: Binding(
                        get: { viewModel.lassoFillMode },
                        set: { viewModel.setLassoFillMode($0) }
                    )
                ) {
                    ForEach(LassoFillMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
            }

            if viewModel.lassoFillMode == .texture {
                textureFillParameterControls
            } else {
                fillParameterControls
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var textureFillParameterControls: some View {
        let settings = viewModel.workspace.toolSession.textureFillTip
        var previewSettings = settings
        previewSettings.materialScale = textureFillPreviewMaterialScale ?? settings.materialScale
        previewSettings.coverage = textureFillPreviewCoverage ?? settings.coverage
        previewSettings.variation = textureFillPreviewVariation ?? settings.variation
        previewSettings.paintJitterAmount = textureFillPreviewPaintJitterAmount ?? settings.paintJitterAmount
        let previewRequest = TextureFillPreviewRequest(
            brush: viewModel.textureFillPreviewBrush,
            tipSettings: previewSettings,
            color: viewModel.textureFillPreviewColor
        )
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("纹理填充")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))

                Spacer(minLength: 0)

                compactIconButton(
                    systemImage: "square.and.arrow.down",
                    tooltip: "保存纹理到纹理库"
                ) {
                    viewModel.saveCurrentTextureFillPreset()
                    libraryInspectorTab = .texture
                }
            }

            Text(textureFillTipSourceSummary)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.62))

            HStack(spacing: 8) {
                compactTextActionButton(
                    title: "选择纹理…",
                    tooltip: "从共享笔尖图片中选择纹理素材",
                    fillsAvailableWidth: true
                ) {
                    prepareTipImageLibraryPresentation(for: .textureFill)
                    tipImageLibrarySheetTarget = .textureFill
                }

                if viewModel.workspace.toolSession.textureFillTip.sourceSemantic == .importedImage
                    || viewModel.workspace.toolSession.textureFillBrushOverride != nil {
                    compactTextActionButton(
                        title: "使用当前画笔",
                        tooltip: "使用当前画笔生成纹理素材",
                        fillsAvailableWidth: true
                    ) {
                        viewModel.resetTextureFillTipToProcedural()
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("排列")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.68))

                Picker(
                    "排列",
                    selection: Binding(
                        get: { settings.arrangement },
                        set: { viewModel.setTextureFillArrangement($0) }
                    )
                ) {
                    ForEach(TextureFillArrangement.allCases, id: \.self) { arrangement in
                        Text(arrangement.displayName).tag(arrangement)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .help("流向跟随手势；交织叠加正交纹理；环形围绕落笔点；散布按随机块旋转")
            }

            TextureFillResultPreview(request: previewRequest)

            Text("结果示意 · 每次填充的随机分布和方向会变化")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.48))
                .lineLimit(1)

            OptimizedCompactSlider(
                title: "纹理尺寸",
                valueText: "\(Int((settings.materialScale * 100).rounded()))%",
                value: Binding(
                    get: { Double(settings.materialScale * 100) },
                    set: { _ in }
                ),
                range: 25...300,
                liveValueText: { "\(Int($0.rounded()))%" },
                onPreview: { textureFillPreviewMaterialScale = Float($0 / 100) },
                onCommit: {
                    viewModel.setTextureFillMaterialScale(Float($0 / 100))
                    textureFillPreviewMaterialScale = nil
                }
            )

            OptimizedCompactSlider(
                title: "覆盖率",
                valueText: "\(Int((settings.coverage * 100).rounded()))%",
                value: Binding(
                    get: { Double(settings.coverage * 100) },
                    set: { _ in }
                ),
                range: 10...100,
                liveValueText: { "\(Int($0.rounded()))%" },
                onPreview: { textureFillPreviewCoverage = Float($0 / 100) },
                onCommit: {
                    viewModel.setTextureFillCoverage(Float($0 / 100))
                    textureFillPreviewCoverage = nil
                }
            )

            OptimizedCompactSlider(
                title: "变化度",
                valueText: "\(Int((settings.variation * 100).rounded()))%",
                value: Binding(
                    get: { Double(settings.variation * 100) },
                    set: { _ in }
                ),
                range: 0...100,
                liveValueText: { "\(Int($0.rounded()))%" },
                onPreview: { textureFillPreviewVariation = Float($0 / 100) },
                onCommit: {
                    viewModel.setTextureFillVariation(Float($0 / 100))
                    textureFillPreviewVariation = nil
                }
            )

            OptimizedCompactSlider(
                title: "杂色",
                valueText: "\(Int((settings.paintJitterAmount * 100).rounded()))%",
                value: Binding(
                    get: { Double(settings.paintJitterAmount * 100) },
                    set: { _ in }
                ),
                range: 0...100,
                liveValueText: { "\(Int($0.rounded()))%" },
                onPreview: { textureFillPreviewPaintJitterAmount = Float($0 / 100) },
                onCommit: {
                    viewModel.setTextureFillPaintJitterAmount(Float($0 / 100))
                    textureFillPreviewPaintJitterAmount = nil
                }
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fillParameterControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            GradientStopsEditor(
                settings: viewModel.displayedGradientSettings,
                followsCurrentColor: viewModel.gradientFollowsSelectedColor,
                onAdd: viewModel.addGradientStop,
                onUpdate: viewModel.updateGradientStop,
                onRemove: viewModel.removeGradientStop,
                onReset: viewModel.resetGradientSettingsToCurrentColor
            )
            brushJitterSlider
            paintJitterSlider
        }
    }

    private var bucketFillParameterControls: some View {
        let settings = viewModel.fillSettings
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("油漆桶")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                Spacer()
                Button("重置") { viewModel.resetFillSettings() }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
            }

            BrushParameterSliderRow(
                title: "容差",
                value: Double(settings.tolerance * 100),
                range: 0...100,
                formatter: { "\(Int($0.rounded()))%" },
                onPreview: { viewModel.setFillTolerance(Float($0 / 100)) },
                onCommit: { viewModel.setFillTolerance(Float($0 / 100)) }
            )

            Toggle(
                "仅填充相邻区域",
                isOn: Binding(
                    get: { settings.isContiguous },
                    set: viewModel.setFillContiguous
                )
            )
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.8))

            VStack(alignment: .leading, spacing: 4) {
                Text("采样范围")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.68))
                Picker(
                    "采样范围",
                    selection: Binding(
                        get: { settings.sampleSource },
                        set: viewModel.setFillSampleSource
                    )
                ) {
                    Text("自动").tag(FillSampleSource.automatic)
                    Text("当前层").tag(FillSampleSource.currentLayer)
                    Text("可见层").tag(FillSampleSource.allVisibleLayers)
                    Text("参考层").tag(FillSampleSource.markedReferenceLayers)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
            }

            Text(settings.isContiguous ? "从落点向相邻像素扩散" : "替换采样范围内所有相近颜色")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.48))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var smartSelectionParameterControls: some View {
        let settings = viewModel.smartSelectionSettings
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("魔棒选区")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                Spacer()
                Button("重置") { viewModel.resetSmartSelectionSettings() }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
            }

            HStack(spacing: 5) {
                magicWandModeButton("square.dashed", help: "新建选区", mode: .replace, settings: settings)
                magicWandModeButton("square.stack.3d.up", help: "增加到选区", mode: .add, settings: settings)
                magicWandModeButton("square.stack.3d.down.right", help: "从选区减去", mode: .subtract, settings: settings)
                magicWandModeButton("square.intersection.3", help: "与选区相交", mode: .intersect, settings: settings)
            }

            BrushParameterSliderRow(
                title: "容差",
                value: Double(settings.tolerance),
                range: 0...255,
                formatter: { "\(Int($0.rounded()))" },
                onPreview: { viewModel.setSmartSelectionTolerance(Int($0.rounded())) },
                onCommit: { viewModel.setSmartSelectionTolerance(Int($0.rounded())) }
            )

            HStack(spacing: 8) {
                Text("采样")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.68))
                Picker(
                    "采样尺寸",
                    selection: Binding(
                        get: { settings.sampleSize },
                        set: viewModel.setSmartSelectionSampleSize
                    )
                ) {
                    Text("点样本").tag(MagicWandSampleSize.point)
                    Text("3 × 3 平均").tag(MagicWandSampleSize.threeByThree)
                    Text("5 × 5 平均").tag(MagicWandSampleSize.fiveByFive)
                    Text("11 × 11 平均").tag(MagicWandSampleSize.elevenByEleven)
                    Text("31 × 31 平均").tag(MagicWandSampleSize.thirtyOneByThirtyOne)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
            }

            HStack(spacing: 12) {
                Toggle(
                    "抗锯齿",
                    isOn: Binding(
                        get: { settings.isAntiAliased },
                        set: viewModel.setSmartSelectionAntiAliased
                    )
                )
                Toggle(
                    "连续",
                    isOn: Binding(
                        get: { settings.isContiguous },
                        set: viewModel.setSmartSelectionContiguous
                    )
                )
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.75))

            Toggle(
                "所有可见层取样",
                isOn: Binding(
                    get: { settings.sampleSource == .allVisibleLayers },
                    set: { viewModel.setSmartSelectionSampleSource($0 ? .allVisibleLayers : .currentLayer) }
                )
            )
            .toggleStyle(.checkbox)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.75))

            Text("单击颜色建立选区。Shift 增选，Option 减选，Shift+Option 取交集；1–9 设置 10%–90% 容差，0 设置 100%；Enter 切换覆盖/蚂蚁线。")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.52))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func magicWandModeButton(
        _ systemName: String,
        help: String,
        mode: MagicWandSelectionMode,
        settings: SmartSelectionSettings
    ) -> some View {
        Button {
            viewModel.setSmartSelectionMode(mode)
        } label: {
            Image(systemName: systemName)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(settings.selectionMode == mode ? Color.accentColor : Color.white.opacity(0.16))
        .help(help)
    }

    private var pinnedBrushCommonControls: some View {
        let brush = viewModel.workspace.toolSession.brush
        let compoundEnabled = brush.compoundBrush.enabled

        return VStack(alignment: .leading, spacing: 7) {
            Text("常用")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.72))

            BrushParameterSliderRow(
                title: "间距",
                value: Double(brush.spacingPercent),
                range: 1...1_000,
                scale: .logarithmic,
                formatter: { "\(Int($0.rounded()))%" },
                onPreview: { viewModel.setBrushSpacingPercent(Float($0)) },
                onCommit: { viewModel.setBrushSpacingPercent(Float($0)) }
            )

            BrushParameterSliderRow(
                title: "尺寸随机",
                value: Double(brush.sizeJitterAmount * 100),
                range: 0...100,
                formatter: { "\(Int($0.rounded()))%" },
                onPreview: { viewModel.setBrushSizeJitterAmount(Float($0 / 100)) },
                onCommit: { viewModel.setBrushSizeJitterAmount(Float($0 / 100)) }
            )

            BrushParameterSliderRow(
                title: compoundEnabled ? "整体尺寸" : "尺寸压感",
                value: Double(viewModel.displayedPressureSizeAmount * 100),
                range: 0...100,
                formatter: { "\(Int($0.rounded()))%" },
                onPreview: { viewModel.setPressureSizeAmount(Float($0 / 100)) },
                onCommit: { viewModel.setPressureSizeAmount(Float($0 / 100)) }
            )

            BrushParameterSliderRow(
                title: compoundEnabled ? "整体透明" : "不透明压感",
                value: Double(viewModel.displayedPressureOpacityAmount * 100),
                range: 0...100,
                formatter: { "\(Int($0.rounded()))%" },
                onPreview: { viewModel.setPressureOpacityAmount(Float($0 / 100)) },
                onCommit: { viewModel.setPressureOpacityAmount(Float($0 / 100)) }
            )

            BrushParameterSliderRow(
                title: "杂色",
                value: Double(viewModel.displayedPaintJitterAmount * 100),
                range: 0...100,
                formatter: { "\(Int($0.rounded()))%" },
                onPreview: { viewModel.setPaintJitterAmount(Float($0 / 100)) },
                onCommit: { viewModel.setPaintJitterAmount(Float($0 / 100)) }
            )

            if viewModel.workspace.toolSession.activeTool == .brush {
                oilPaintControls(brush: brush)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func oilPaintControls(brush: BrushSettings) -> some View {
        let isAvailable = viewModel.displayedPaintJitterAmount > 0.001
        let isEnabled = brush.oilPaint.isEnabled && isAvailable

        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Toggle(
                    "仿真油画笔",
                    isOn: Binding(
                        get: { isEnabled },
                        set: { viewModel.setOilPaintEnabled($0) }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(isAvailable ? 0.86 : 0.42))
                .disabled(!isAvailable)
                .buttonTooltip("保留笔头中的旧颜色，让后来选择的颜色逐步混入")
            }

            if !isAvailable {
                Text("需先提高“杂色”")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.42))
            } else if isEnabled {
                BrushParameterSliderRow(
                    title: "新色装载",
                    value: Double(brush.oilPaint.newColorLoad * 100),
                    range: 0...100,
                    formatter: { "\(Int($0.rounded()))%" },
                    onPreview: { viewModel.setOilPaintNewColorLoad(Float($0 / 100)) },
                    onCommit: { viewModel.setOilPaintNewColorLoad(Float($0 / 100)) }
                )

                BrushParameterSliderRow(
                    title: "明度跟随",
                    value: Double(brush.oilPaint.lightnessFollow * 100),
                    range: 0...100,
                    formatter: { "\(Int($0.rounded()))%" },
                    onPreview: { viewModel.setOilPaintLightnessFollow(Float($0 / 100)) },
                    onCommit: { viewModel.setOilPaintLightnessFollow(Float($0 / 100)) }
                )

                Picker(
                    "出笔颜色",
                    selection: Binding(
                        get: { viewModel.workspace.toolSession.oilPaintOutputMode },
                        set: { viewModel.setOilPaintOutputMode($0) }
                    )
                ) {
                    Text("笔头含色").tag(OilPaintOutputMode.reservoir)
                    Text("当前色直绘").tag(OilPaintOutputMode.currentColor)
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .buttonTooltip("当前色直绘不会清除笔头中已经装载的颜色")

                HStack(spacing: 6) {
                    Spacer(minLength: 0)

                    Button("沾色 \(viewModel.shortcutSettings.oilPaintLoadShortcut.displayString)") {
                        viewModel.loadSelectedColorIntoOilPaintBrush()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .buttonTooltip("按新色装载比例，把当前选中的颜色加入笔头")

                    Button("洗笔 \(viewModel.shortcutSettings.oilPaintWashShortcut.displayString)") {
                        viewModel.washOilPaintBrush()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .buttonTooltip("清除旧颜色，只保留当前颜色")
                }

                HStack(spacing: 7) {
                    Text("笔头含色")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.58))
                        .frame(width: 58, alignment: .leading)
                    oilPaintPigmentPreview
                }

                Text("模拟笔头残留；不读取画布上的湿色")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.42))
            }
        }
        .padding(.top, 2)
    }

    private var oilPaintPigmentPreview: some View {
        let components = viewModel.oilPaintPigmentPreviewComponents

        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(Array(components.enumerated()), id: \.offset) { _, component in
                        Rectangle()
                            .fill(
                                Color(
                                    red: Double(component.color.red),
                                    green: Double(component.color.green),
                                    blue: Double(component.color.blue),
                                    opacity: Double(component.color.alpha)
                                )
                            )
                            .frame(width: max(geometry.size.width * CGFloat(component.weight), 1))
                            .help("\(Int((component.weight * 100).rounded()))%")
                    }
                }
                .clipShape(Capsule())

                ForEach(Array(components.indices.dropLast()), id: \.self) { index in
                    let cumulativeWeight = components[...index].reduce(Float.zero) { $0 + $1.weight }
                    Capsule()
                        .fill(Color.white.opacity(0.96))
                        .shadow(color: Color.black.opacity(0.55), radius: 1, x: 0, y: 0.5)
                        .frame(width: 3, height: 14)
                        .position(
                            x: geometry.size.width * CGFloat(cumulativeWeight),
                            y: geometry.size.height * 0.5
                        )
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard geometry.size.width > 0, components.count > 1 else { return }
                        let location = min(max(value.location.x, 0), geometry.size.width)
                        if activeOilPaintBoundaryIndex == nil {
                            let boundaries = components.indices.dropLast().map { index in
                                components[...index].reduce(Float.zero) { $0 + $1.weight }
                            }
                            activeOilPaintBoundaryIndex = boundaries.enumerated().min { lhs, rhs in
                                abs(CGFloat(lhs.element) * geometry.size.width - location)
                                    < abs(CGFloat(rhs.element) * geometry.size.width - location)
                            }?.offset
                        }
                        guard let activeOilPaintBoundaryIndex else { return }
                        viewModel.setOilPaintPigmentBoundary(
                            after: activeOilPaintBoundaryIndex,
                            cumulativeWeight: Float(location / geometry.size.width)
                        )
                    }
                    .onEnded { _ in
                        activeOilPaintBoundaryIndex = nil
                    }
            )
        }
        .frame(height: 16)
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        .accessibilityLabel("笔头残留颜色")
    }

    private var fullBrushParameterControls: some View {
        let brush = viewModel.workspace.toolSession.brush
        let compoundEnabled = brush.compoundBrush.enabled

        return HStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("组合笔刷")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.9))

                Spacer(minLength: 0)

                Toggle(
                    "",
                    isOn: Binding(
                        get: { viewModel.workspace.toolSession.brush.compoundBrush.enabled },
                        set: { viewModel.setCompoundBrushEnabled($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .buttonTooltip("启用或停用组合笔刷")
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(compoundEnabled ? Color.accentColor.opacity(0.09) : Color.white.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        compoundEnabled ? Color.accentColor.opacity(0.28) : Color.white.opacity(0.07),
                        lineWidth: 1
                    )
            )

            Button {
                showsCompoundBrushBuilder = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "pencil.and.scribble")
                        .font(.system(size: 10, weight: .semibold))
                    Text("编辑当前画笔")
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .center)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.035))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .buttonTooltip("在同一窗口编辑常用参数、叠加方式和组合笔尖")
        }
    }

    private var brushJitterSlider: some View {
        OptimizedCompactSlider(
            title: "抖动",
            valueText: "\(Int(viewModel.workspace.toolSession.brush.jitterAmount * 100))%",
            value: Binding(
                get: { Double(viewModel.workspace.toolSession.brush.jitterAmount) },
                set: { _ in }
            ),
            range: 0...1,
            liveValueText: { "\(Int($0 * 100))%" },
            onCommit: { viewModel.setBrushJitterAmount(Float($0)) }
        )
    }

    private var paintJitterSlider: some View {
        OptimizedCompactSlider(
            title: "杂色",
            valueText: "\(Int(viewModel.displayedPaintJitterAmount * 100))%",
            value: Binding(
                get: { Double(viewModel.displayedPaintJitterAmount) },
                set: { _ in }
            ),
            range: 0...1,
            liveValueText: { "\(Int($0 * 100))%" },
            onCommit: { viewModel.setPaintJitterAmount(Float($0)) }
        )
    }

    private var textureFillTipSourceSummary: String {
        let source = viewModel.workspace.toolSession.textureFillTip
        switch source.sourceSemantic {
        case .procedural:
            if let savedBrush = viewModel.workspace.toolSession.textureFillBrushOverride {
                return "纹理库画笔素材：\(savedBrush.tipShape.displayName)"
            }
            let brush = viewModel.workspace.toolSession.drawingBrush
            return "当前画笔纹理：\(brush.tipShape.displayName)"
        case .customMask:
            return "当前使用自定义纹理"
        case .importedImage:
            if let sourceInfo = source.importedSourceInfo {
                return "当前素材：\(sourceInfo.formattedSummary)"
            }
            return "当前使用共享图库导入素材"
        }
    }

    private var colorAdjustmentSection: some View {
        let parameters = viewModel.colorAdjustmentParameters
        let canAdjust = viewModel.canEditColorAdjustmentParameters
        let canConfirm = viewModel.canConfirmColorAdjustmentSession
        let wrappedHue = ColorBlocksEngine.wrapHue(parameters.selectedHueDegrees)
        let strengthDisplayValue = parameters.hueStrength * 2

        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("色相")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.84))

                    Circle()
                        .fill(colorAdjustmentHuePreviewColor(for: wrappedHue))
                        .frame(width: 12, height: 12)
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.35), lineWidth: 1)
                        )

                    Spacer(minLength: 8)

                    Text("\(Int(wrappedHue.rounded()))°")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.white.opacity(0.96))
                }

                ColorLightingHueBarView(
                    hue: wrappedHue,
                    onUpdateHue: { hue in
                        viewModel.setColorAdjustmentSelectedHueDegrees(hue)
                    },
                    onDragEnded: { hue in
                        viewModel.setColorAdjustmentSelectedHueDegrees(hue)
                    }
                )
                .frame(height: 6)
                .disabled(!canAdjust)
                .opacity(canAdjust ? 1 : 0.42)
            }

            colorAdjustmentSlider(
                title: "强度",
                valueText: signedPercentText(strengthDisplayValue),
                value: Double(strengthDisplayValue),
                range: -1...1,
                isEnabled: canAdjust
            ) { value in
                viewModel.setColorAdjustmentHueStrength(Float(value) * 0.5)
            }

            colorAdjustmentSlider(
                title: "亮度",
                valueText: signedPercentText(parameters.brightness),
                value: Double(parameters.brightness),
                range: -1...1,
                isEnabled: canAdjust
            ) { value in
                viewModel.setColorAdjustmentBrightness(Float(value))
            }

            colorAdjustmentSlider(
                title: "对比",
                valueText: signedPercentText(parameters.contrast),
                value: Double(parameters.contrast),
                range: -1...1,
                isEnabled: canAdjust
            ) { value in
                viewModel.setColorAdjustmentContrast(Float(value))
            }

            colorAdjustmentSlider(
                title: "纯度",
                valueText: signedPercentText(parameters.purity),
                value: Double(parameters.purity),
                range: -1...1,
                isEnabled: canAdjust
            ) { value in
                viewModel.setColorAdjustmentPurity(Float(value))
            }

            Divider()
                .overlay(Color.white.opacity(0.08))
                .padding(.vertical, 2)

            adjustmentActionStrip(
                canConfirm: canConfirm,
                canReset: canAdjust,
                canHoldPreview: viewModel.canPreviewColorAdjustmentOriginal,
                isHoldingPreview: viewModel.colorAdjustmentOverlayState.showsOriginalPreview,
                onConfirm: { viewModel.confirmColorAdjustmentSession() },
                onReset: { viewModel.resetColorAdjustmentParameters() },
                onSetShowsOriginalPreview: { isPressed in
                    viewModel.setColorAdjustmentShowsOriginalPreview(isPressed)
                }
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var colorVitalizationControls: some View {
        let parameters = viewModel.colorAdjustmentParameters
        let canAdjust = viewModel.canEditColorAdjustmentParameters
        let selectedTextureName = viewModel.workspace.textureFillLibrary.selectedItemID
            .flatMap { viewModel.workspace.textureFillLibrary.item(id: $0)?.displayName }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.rays")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("颜色活化")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.92))
                    Text(selectedTextureName ?? textureFillTipSourceSummary)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.58))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            Text("在目标色块上涂抹；每次抬笔自动写入，Cmd-Z 可直接撤销。下方纹理库决定混色纹理。")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.64))
                .fixedSize(horizontal: false, vertical: true)

            colorAdjustmentSlider(
                title: "活化强度",
                valueText: percentText(parameters.vitalizationStrength),
                value: Double(parameters.vitalizationStrength),
                range: 0...1,
                isEnabled: canAdjust
            ) { value in
                viewModel.setColorVitalizationStrength(Float(value))
            }

            colorAdjustmentSlider(
                title: "纹理尺度",
                valueText: percentText(parameters.vitalizationBandScale),
                value: Double(parameters.vitalizationBandScale),
                range: 0...1,
                isEnabled: canAdjust
            ) { value in
                viewModel.setColorVitalizationBandScale(Float(value))
            }

            colorAdjustmentSlider(
                title: "颜色容差",
                valueText: percentText(parameters.vitalizationColorTolerance),
                value: Double(parameters.vitalizationColorTolerance),
                range: 0...1,
                isEnabled: canAdjust
            ) { value in
                viewModel.setColorVitalizationColorTolerance(Float(value))
            }

            colorAdjustmentSlider(
                title: "扭曲混合",
                valueText: percentText(parameters.vitalizationDistortion),
                value: Double(parameters.vitalizationDistortion),
                range: 0...1,
                isEnabled: canAdjust
            ) { value in
                viewModel.setColorVitalizationDistortion(Float(value))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var curveAdjustmentSection: some View {
        let parameters = viewModel.curveAdjustmentParameters
        let selectedChannel = parameters.selectedChannel
        let canAdjust = viewModel.canStartOrEditCurveAdjustmentFromPanel

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 10) {
                CurveEditorView(
                    state: parameters.state(for: selectedChannel),
                    isEnabled: canAdjust
                ) { nextState in
                    viewModel.updateCurveAdjustmentChannelPoints(nextState.points, channel: selectedChannel)
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .opacity(canAdjust ? 1 : 0.58)
                .layoutPriority(1)

                VStack(spacing: 6) {
                    ForEach(CurveChannel.allCases, id: \.self) { channel in
                        curveChannelButton(
                            channel: channel,
                            isSelected: selectedChannel == channel,
                            isEnabled: canAdjust
                        ) {
                            viewModel.setCurveAdjustmentSelectedChannel(channel)
                        }
                    }
                }
                .frame(width: 54)
            }

            if !canAdjust {
                Text(viewModel.curveAdjustmentStatusMessage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.66))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
                .overlay(Color.white.opacity(0.08))
                .padding(.vertical, 2)

            adjustmentActionStrip(
                canConfirm: viewModel.canConfirmCurveAdjustmentSession,
                canReset: canAdjust,
                canHoldPreview: viewModel.canPreviewCurveAdjustmentOriginal,
                isHoldingPreview: viewModel.curveAdjustmentOverlayState.showsOriginalPreview,
                onConfirm: { viewModel.confirmCurveAdjustmentIfNeeded(showFeedback: true) },
                onReset: { viewModel.resetCurveAdjustmentValues() },
                onSetShowsOriginalPreview: { isPressed in
                    viewModel.setCurveAdjustmentShowingOriginalPreview(isPressed)
                }
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func curveChannelButton(
        channel: CurveChannel,
        isSelected: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(channel.displayName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.white.opacity(isSelected ? 0.96 : 0.72))
                .frame(maxWidth: .infinity, minHeight: 24)
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? Color.accentColor.opacity(0.24) : Color.white.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            isSelected ? Color.accentColor.opacity(0.86) : Color.white.opacity(0.08),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private func adjustmentActionStrip(
        canConfirm: Bool,
        canReset: Bool,
        canHoldPreview: Bool,
        isHoldingPreview: Bool,
        onConfirm: @escaping () -> Void,
        onReset: @escaping () -> Void,
        onSetShowsOriginalPreview: @escaping (Bool) -> Void
    ) -> some View {
        HStack(spacing: 8) {
            compactToolButton(
                systemImage: "checkmark",
                tooltip: "确认应用",
                isSelected: canConfirm,
                width: topInspectorControlButtonWidth,
                height: topInspectorControlButtonHeight,
                iconSize: topInspectorControlIconSize,
                cornerRadius: topInspectorControlCornerRadius
            ) {
                onConfirm()
            }
            .disabled(!canConfirm)

            compactToolButton(
                systemImage: "arrow.counterclockwise",
                tooltip: "恢复默认",
                width: topInspectorControlButtonWidth,
                height: topInspectorControlButtonHeight,
                iconSize: topInspectorControlIconSize,
                cornerRadius: topInspectorControlCornerRadius
            ) {
                onReset()
            }
            .disabled(!canReset)

            PressAndHoldActionButton(
                title: "按住预览",
                isEnabled: canHoldPreview,
                isPressed: isHoldingPreview
            ) { isPressed in
                onSetShowsOriginalPreview(isPressed)
            }
        }
    }

    private func colorAdjustmentSlider(
        title: String,
        valueText: String,
        value: Double,
        range: ClosedRange<Double>,
        isEnabled: Bool,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        ThrottledSlider(
            title: title,
            valueText: { _ in valueText },
            value: Binding(
                get: { value },
                set: { _ in }
            ),
            range: range,
            enableLivePreview: true,
            onValueChanged: onChange
        )
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.42)
    }

    private func signedPercentText(_ value: Float) -> String {
        let rounded = Int((value * 100).rounded())
        if rounded > 0 {
            return "+\(rounded)%"
        }
        return "\(rounded)%"
    }

    private func percentText(_ value: Float) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func colorAdjustmentHuePreviewColor(for hue: Float) -> Color {
        let rgb = ColorBlocksEngine.hsvToRgb(
            HSVColor(h: ColorBlocksEngine.wrapHue(hue), s: 1, v: 1)
        )
        return Color(
            red: Double(rgb.red),
            green: Double(rgb.green),
            blue: Double(rgb.blue),
            opacity: 1
        )
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
            let minimumLibraryRows = max(1, Int(ceil((geometry.size.height + spacing) / (slotWidth + spacing))))
            let visibleSlotCapacity = minimumLibraryRows * columnCount
            let rawSlotCount = max(occupiedSlotCount, visibleSlotCapacity)
            let totalSlotCount = max(
                columnCount,
                ((rawSlotCount + columnCount - 1) / columnCount) * columnCount
            )
            let columns = Array(repeating: GridItem(.fixed(slotWidth), spacing: spacing), count: columnCount)

            VStack(alignment: .leading, spacing: 0) {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 8) {
                        if !libraryFilterIsActive {
                            Text("1–4 为固定快捷画笔")
                                .font(.system(size: 8.5, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.4))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        LazyVGrid(columns: columns, spacing: spacing) {
                            if libraryFilterIsActive {
                                ForEach(filteredBrushPresets) { preset in
                                    brushPresetCell(preset, slotIndex: nil, showsShortcutLabel: false)
                                }
                            } else {
                                ForEach(0..<totalSlotCount, id: \.self) { slotIndex in
                                    brushLibrarySlotCell(slotIndex: slotIndex)
                                }
                            }
                        }

                        if libraryFilterIsActive && filteredBrushPresets.isEmpty {
                            libraryEmptySearchResult
                        }
                    }
                    .padding(.horizontal, horizontalInset)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .environment(\.colorScheme, .dark)
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

    private var libraryInspectorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                libraryInspectorTabButton(.brush)
                libraryInspectorTabButton(.pattern)
                libraryInspectorTabButton(.texture)
            }

            libraryUtilityBar
            librarySelectionSummary

            switch libraryInspectorTab {
            case .brush:
                brushLibrarySection
            case .pattern:
                patternLibrarySection
            case .texture:
                textureFillLibrarySection
            }
        }
    }

    private var libraryUtilityBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.46))
                TextField("搜索当前库", text: $librarySearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                if !librarySearchText.isEmpty {
                    Button {
                        librarySearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .help("清除搜索")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.18)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.07), lineWidth: 1))

            Menu {
                Button("全部资源") { libraryFilter = .all }
                Button("只看收藏") { libraryFilter = .favorites }
                Divider()
                ForEach(BrushColorTag.allCases, id: \.self) { tag in
                    Button("\(labelForBrushTag(tag))色色标") {
                        libraryFilter = .color(tag)
                    }
                }
            } label: {
                Image(systemName: libraryFilter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("筛选资源")

            if canUndoCurrentLibraryDeletion {
                Button(action: undoCurrentLibraryDeletion) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("恢复最近删除")
            }

            Button(action: addCurrentLibraryResource) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .environment(\.colorScheme, .dark)
            .help(addCurrentLibraryResourceTitle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var librarySelectionSummary: some View {
        switch libraryInspectorTab {
        case .brush:
            if let presetID = viewModel.workspace.brushLibrary.selectedPresetID,
               let preset = viewModel.workspace.brushLibrary.preset(id: presetID) {
                let isApplied = preset.brush == viewModel.workspace.toolSession.brush
                librarySummaryCard(
                    title: preset.name,
                    detail: isApplied ? "当前画笔与预设一致" : "当前画笔已基于此预设修改",
                    isModified: !isApplied,
                    actions: {
                        if !isApplied {
                            if !preset.isBuiltIn {
                                summaryActionButton("更新") {
                                    viewModel.updateSelectedBrushPresetFromCurrent()
                                }
                            }
                            summaryActionButton("另存") {
                                viewModel.saveCurrentBrushPresetAsNew()
                            }
                            summaryActionButton("还原") {
                                viewModel.applyBrushPreset(preset.id)
                            }
                        }
                    }
                )
            }

        case .pattern:
            if let itemID = viewModel.workspace.patternLibrary.selectedItemID,
               let item = viewModel.workspace.patternLibrary.item(id: itemID) {
                let stateText: String = {
                    if viewModel.patternPlacementPhase.isAdjusting { return "正在调整，确认后写入图层" }
                    if viewModel.patternPlacementPhase.itemID == item.id { return "已准备放置到画布" }
                    return "已选中，点击格子可重新准备放置"
                }()
                librarySummaryCard(
                    title: item.displayName,
                    detail: "\(item.sourcePixelWidth) × \(item.sourcePixelHeight) · \(stateText)",
                    isModified: false,
                    actions: { EmptyView() }
                )
            }

        case .texture:
            if let itemID = viewModel.workspace.textureFillLibrary.selectedItemID,
               let item = viewModel.workspace.textureFillLibrary.item(id: itemID) {
                let currentSourceBrush = viewModel.workspace.toolSession.textureFillBrushOverride
                    ?? viewModel.workspace.toolSession.drawingBrush
                let isApplied = item.settings == viewModel.workspace.toolSession.textureFillTip
                    && item.sourceBrush == currentSourceBrush
                librarySummaryCard(
                    title: item.displayName,
                    detail: "\(item.settings.arrangement.displayName) · 尺寸 \(Int((item.settings.materialScale * 100).rounded()))% · 覆盖 \(Int((item.settings.coverage * 100).rounded()))%\(isApplied ? "" : " · 已修改")",
                    isModified: !isApplied,
                    actions: {
                        if !isApplied {
                            summaryActionButton("更新") {
                                viewModel.updateSelectedTextureFillPreset()
                            }
                            summaryActionButton("另存") {
                                viewModel.saveCurrentTextureFillPresetAsNew()
                            }
                            summaryActionButton("还原") {
                                viewModel.applyTextureFillLibraryItem(item.id)
                            }
                        }
                    }
                )
            }
        }
    }

    private func librarySummaryCard<Actions: View>(
        title: String,
        detail: String,
        isModified: Bool,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(isModified ? Color.orange : Color.accentColor)
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            actions()
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    private func summaryActionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .font(.system(size: 8.5, weight: .semibold))
    }

    private var addCurrentLibraryResourceTitle: String {
        switch libraryInspectorTab {
        case .brush: return "把当前画笔另存为新画笔"
        case .pattern: return "导入图案"
        case .texture: return "把当前纹理另存为新纹理"
        }
    }

    private func addCurrentLibraryResource() {
        switch libraryInspectorTab {
        case .brush:
            viewModel.saveCurrentBrushPresetAsNew()
        case .pattern:
            viewModel.presentPatternImportSheet()
        case .texture:
            viewModel.saveCurrentTextureFillPresetAsNew()
        }
    }

    private var canUndoCurrentLibraryDeletion: Bool {
        switch libraryInspectorTab {
        case .brush:
            return !viewModel.workspace.brushLibrary.deletedPresets.isEmpty
        case .pattern:
            return !viewModel.workspace.patternLibrary.deletedItems.isEmpty
        case .texture:
            return !viewModel.workspace.textureFillLibrary.deletedItems.isEmpty
        }
    }

    private func undoCurrentLibraryDeletion() {
        switch libraryInspectorTab {
        case .brush:
            viewModel.restoreLastDeletedBrushPreset()
        case .pattern:
            viewModel.restoreLastDeletedPatternLibraryItem()
        case .texture:
            viewModel.restoreLastDeletedTextureFillLibraryItem()
        }
    }

    private var libraryFilterIsActive: Bool {
        !librarySearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || libraryFilter != .all
    }

    private func matchesLibraryFilter(
        name: String,
        isFavorite: Bool,
        colorTag: BrushColorTag?
    ) -> Bool {
        let query = librarySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty,
           name.localizedCaseInsensitiveContains(query) == false {
            return false
        }
        switch libraryFilter {
        case .all:
            return true
        case .favorites:
            return isFavorite
        case .color(let tag):
            return colorTag == tag
        }
    }

    private var filteredBrushPresets: [BrushPreset] {
        viewModel.workspace.brushLibrary.presets
            .filter { matchesLibraryFilter(name: $0.name, isFavorite: $0.isFavorite, colorTag: $0.colorTag) }
            .sorted {
                let left = viewModel.workspace.brushLibrary.resolvedSlotIndex(forPresetID: $0.id) ?? Int.max
                let right = viewModel.workspace.brushLibrary.resolvedSlotIndex(forPresetID: $1.id) ?? Int.max
                return left < right
            }
    }

    private var filteredPatternItems: [PatternLibraryItem] {
        let map = viewModel.workspace.patternLibrary.resolvedSlotMap()
        return map.keys.sorted().compactMap { map[$0] }.filter {
            matchesLibraryFilter(name: $0.displayName, isFavorite: $0.isFavorite, colorTag: $0.colorTag)
        }
    }

    private var filteredTextureItems: [TextureFillLibraryItem] {
        let map = viewModel.workspace.textureFillLibrary.resolvedSlotMap()
        return map.keys.sorted().compactMap { map[$0] }.filter {
            matchesLibraryFilter(name: $0.displayName, isFavorite: $0.isFavorite, colorTag: $0.colorTag)
        }
    }

    private var libraryRenameAlertBinding: Binding<Bool> {
        Binding(
            get: { libraryRenameTarget != nil },
            set: { if !$0 { libraryRenameTarget = nil } }
        )
    }

    private var libraryDeleteAlertBinding: Binding<Bool> {
        Binding(
            get: { libraryDeleteTarget != nil },
            set: { if !$0 { libraryDeleteTarget = nil } }
        )
    }

    private func beginLibraryRename(_ target: LibraryRenameTarget, currentName: String) {
        libraryRenameText = currentName
        libraryRenameTarget = target
    }

    private func commitLibraryRename() {
        guard let target = libraryRenameTarget else { return }
        let name = libraryRenameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        switch target {
        case .brush(let id):
            viewModel.renameBrushPreset(id, to: name)
        case .pattern(let id):
            viewModel.renamePatternLibraryItem(id, to: name)
        case .texture(let id):
            viewModel.renameTextureFillLibraryItem(id, to: name)
        }
        libraryRenameTarget = nil
    }

    private func commitLibraryDelete() {
        guard let target = libraryDeleteTarget else { return }
        switch target {
        case .brush(let id, _):
            viewModel.deleteBrushPreset(id)
        case .pattern(let id, _):
            viewModel.deletePatternLibraryItem(id)
        case .texture(let id, _):
            viewModel.deleteTextureFillLibraryItem(id)
        }
        libraryDeleteTarget = nil
    }

    private var libraryEmptySearchResult: some View {
        VStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
            Text("没有匹配的资源")
                .font(.system(size: 10, weight: .semibold))
            Button("清除筛选") {
                librarySearchText = ""
                libraryFilter = .all
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .foregroundStyle(Color.white.opacity(0.46))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func libraryInspectorTabButton(_ tab: LibraryInspectorTab) -> some View {
        let isSelected = libraryInspectorTab == tab

        return inspectorTabButton(title: tab.rawValue, isSelected: isSelected) {
            libraryInspectorTab = tab
        }
    }

    private func inspectorTabButton(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
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

    private var patternLibrarySection: some View {
        GeometryReader { geometry in
                let columnCount = 4
                let spacing = 8.0
                let outerInset = 12.0
                let usableWidth = max(0.0, geometry.size.width - outerInset * 2)
                let slotWidth = max(40.0, floor((usableWidth - spacing * Double(columnCount - 1)) / Double(columnCount)))
                let contentWidth = (slotWidth * Double(columnCount)) + (spacing * Double(columnCount - 1))
                let horizontalInset = max(0.0, floor((usableWidth - contentWidth) * 0.5)) + outerInset
                let minimumLibraryRows = max(1, Int(ceil((geometry.size.height + spacing) / (slotWidth + spacing))))
                let totalSlotCount = viewModel.workspace.patternLibrary.slotCount(minRows: minimumLibraryRows, columns: columnCount)
                let columns = Array(repeating: GridItem(.fixed(slotWidth), spacing: spacing), count: columnCount)

                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 8) {
                        LazyVGrid(columns: columns, spacing: spacing) {
                            if libraryFilterIsActive {
                                ForEach(filteredPatternItems) { item in
                                    patternLibraryItemCell(item)
                                }
                            } else {
                                ForEach(0..<totalSlotCount, id: \.self) { slotIndex in
                                    patternLibrarySlotCell(slotIndex: slotIndex)
                                }
                            }
                        }

                        if libraryFilterIsActive && filteredPatternItems.isEmpty {
                            libraryEmptySearchResult
                        }
                    }
                    .padding(.horizontal, horizontalInset)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .environment(\.colorScheme, .dark)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .contextMenu {
            Button("导入图片") {
                viewModel.presentPatternImportSheet()
            }

            Divider()

            Button("重建全部缩略图") {
                viewModel.rebuildAllPatternLibraryThumbnails()
            }
            .disabled(viewModel.workspace.patternLibrary.items.isEmpty)
        }
    }

    @ViewBuilder
    private func patternLibrarySlotCell(slotIndex: Int) -> some View {
        let item = viewModel.workspace.patternLibrary.item(atSlot: slotIndex)

        if let item {
            patternLibraryItemCell(item)
                .onDrop(of: [UTType.plainText.identifier], isTargeted: nil) { providers in
                    movePatternLibraryItemFromDrop(providers: providers, toSlot: slotIndex)
                }
        } else {
            patternLibraryEmptyCell()
                .onDrop(of: [UTType.plainText.identifier], isTargeted: nil) { providers in
                    movePatternLibraryItemFromDrop(providers: providers, toSlot: slotIndex)
                }
        }
    }

    @ViewBuilder
    private func recentPatternLibrarySlotCell(item: PatternLibraryItem?) -> some View {
        if let item {
            patternLibraryItemCell(item)
        } else {
            patternLibraryEmptyCell()
        }
    }

    private func patternLibraryItemCell(_ item: PatternLibraryItem) -> some View {
        let isSelected = viewModel.workspace.patternLibrary.selectedItemID == item.id
        let isActive = viewModel.patternPlacementPhase.itemID == item.id
        let strokeColor: Color = isActive
            ? Color.accentColor.opacity(0.9)
            : (isSelected ? Color.white.opacity(0.30) : Color.white.opacity(0.06))
        let strokeWidth: CGFloat = isActive || isSelected ? 1.5 : 1.0
        let thumbnailURL = viewModel.patternLibraryThumbnailURL(for: item)
        let usesCheckerboard = item.importRecipe.mode == .transparentMonochrome

        return LongPressDraggableCell(
            dragPayload: item.id.uuidString,
            onActivate: {
                viewModel.selectPatternLibraryItem(item.id)
            },
            onDragBegan: {
                draggedPatternLibraryItemID = item.id
            },
            onDragEnded: {
                draggedPatternLibraryItemID = nil
            }
        ) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isActive ? Color.accentColor.opacity(0.18) : (isSelected ? Color.white.opacity(0.07) : Color.white.opacity(0.03)))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(strokeColor, lineWidth: strokeWidth)
                    }

                PatternThumbnailTile(
                    url: thumbnailURL,
                    usesCheckerboard: usesCheckerboard
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(1.5)
                .allowsHitTesting(false)

                if let tag = item.colorTag {
                    brushColorTagCorner(tag)
                        .allowsHitTesting(false)
                }


                if item.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.yellow)
                        .padding(5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .allowsHitTesting(false)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .help(item.displayName)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.displayName)
        .accessibilityValue(isActive ? "已准备放置" : (isSelected ? "已选中" : ""))
        .accessibilityHint("激活后在画布拖动放置；右键管理图案")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            viewModel.selectPatternLibraryItem(item.id)
        }
        .contextMenu {
            Button("使用") {
                viewModel.selectPatternLibraryItem(item.id)
            }
            Button(item.isFavorite ? "取消收藏" : "收藏") {
                viewModel.setPatternLibraryItemFavorite(!item.isFavorite, forItemID: item.id)
            }
            Button("复制") {
                viewModel.duplicatePatternLibraryItem(item.id)
            }
            Button("重命名") {
                beginLibraryRename(.pattern(item.id), currentName: item.displayName)
            }
            Button("重建缩略图") {
                viewModel.rebuildPatternLibraryThumbnail(item.id)
            }
            Divider()
            Menu("色标") {
                ForEach(BrushColorTag.allCases, id: \.self) { tag in
                    Button {
                        viewModel.setPatternLibraryItemColorTag(tag, forItemID: item.id)
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
                    viewModel.setPatternLibraryItemColorTag(nil, forItemID: item.id)
                }
                .disabled(item.colorTag == nil)
            }
            Divider()
            Button("在 Finder 中显示") {
                viewModel.revealPatternLibraryItemInFinder(item.id)
            }
            Divider()
            Button("删除", role: .destructive) {
                libraryDeleteTarget = .pattern(item.id, item.displayName)
            }
        }
    }

    private func patternLibraryEmptyCell() -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.white.opacity(0.03))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.05), lineWidth: 1)
            }
            .aspectRatio(1, contentMode: .fit)
    }

    private var textureFillLibrarySection: some View {
        GeometryReader { geometry in
            let columnCount = 4
            let spacing = 8.0
            let outerInset = 12.0
            let usableWidth = max(0.0, geometry.size.width - outerInset * 2)
            let slotWidth = max(40.0, floor((usableWidth - spacing * Double(columnCount - 1)) / Double(columnCount)))
            let contentWidth = (slotWidth * Double(columnCount)) + (spacing * Double(columnCount - 1))
            let horizontalInset = max(0.0, floor((usableWidth - contentWidth) * 0.5)) + outerInset
            let minimumLibraryRows = max(1, Int(ceil((geometry.size.height + spacing) / (slotWidth + spacing))))
            let totalSlotCount = viewModel.workspace.textureFillLibrary.slotCount(
                minRows: minimumLibraryRows,
                columns: columnCount
            )
            let columns = Array(repeating: GridItem(.fixed(slotWidth), spacing: spacing), count: columnCount)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 8) {
                    LazyVGrid(columns: columns, spacing: spacing) {
                        if libraryFilterIsActive {
                            ForEach(filteredTextureItems) { item in
                                textureFillLibraryItemCell(item)
                            }
                        } else {
                            ForEach(0..<totalSlotCount, id: \.self) { slotIndex in
                                textureFillLibrarySlotCell(slotIndex: slotIndex)
                            }
                        }
                    }

                    if libraryFilterIsActive && filteredTextureItems.isEmpty {
                        libraryEmptySearchResult
                    }
                }
                .padding(.horizontal, horizontalInset)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .environment(\.colorScheme, .dark)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func textureFillLibrarySlotCell(slotIndex: Int) -> some View {
        let item = viewModel.workspace.textureFillLibrary.item(atSlot: slotIndex)

        if let item {
            textureFillLibraryItemCell(item)
                .onDrop(of: [UTType.plainText.identifier], isTargeted: nil) { providers in
                    moveTextureFillLibraryItemFromDrop(providers: providers, toSlot: slotIndex)
                }
        } else {
            textureFillLibraryEmptyCell()
                .onDrop(of: [UTType.plainText.identifier], isTargeted: nil) { providers in
                    moveTextureFillLibraryItemFromDrop(providers: providers, toSlot: slotIndex)
                }
        }
    }

    private func textureFillLibraryItemCell(_ item: TextureFillLibraryItem) -> some View {
        let isSelected = viewModel.workspace.textureFillLibrary.selectedItemID == item.id
        let currentSourceBrush = viewModel.workspace.toolSession.textureFillBrushOverride
            ?? viewModel.workspace.toolSession.drawingBrush
        let isApplied = isSelected
            && item.settings == viewModel.workspace.toolSession.textureFillTip
            && item.sourceBrush == currentSourceBrush
        let isModified = isSelected && !isApplied
        let strokeColor: Color = isApplied
            ? Color.accentColor.opacity(0.9)
            : (isModified ? Color.orange.opacity(0.9) : Color.white.opacity(0.06))
        let strokeWidth: CGFloat = isSelected ? 1.5 : 1.0
        let previewRequest = TextureFillPreviewRequest(
            brush: item.sourceBrush ?? .stageOneDefault,
            tipSettings: item.settings,
            color: .black
        )

        return LongPressDraggableCell(
            dragPayload: item.id.uuidString,
            onActivate: {
                viewModel.applyTextureFillLibraryItem(item.id)
            },
            onDragBegan: {
                draggedTextureFillLibraryItemID = item.id
            },
            onDragEnded: {
                draggedTextureFillLibraryItemID = nil
            }
        ) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isApplied ? Color.accentColor.opacity(0.18) : (isModified ? Color.orange.opacity(0.10) : Color.white.opacity(0.03)))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(strokeColor, lineWidth: strokeWidth)
                    }

                TextureFillLibraryThumbnailTile(request: previewRequest)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(2)
                    .allowsHitTesting(false)

                if let tag = item.colorTag {
                    brushColorTagCorner(tag)
                        .allowsHitTesting(false)
                }


                if item.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.yellow)
                        .padding(5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .allowsHitTesting(false)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .help(item.displayName)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.displayName)
        .accessibilityValue(isApplied ? "已应用" : (isModified ? "已修改" : ""))
        .accessibilityHint("激活后应用纹理；右键管理纹理")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            viewModel.applyTextureFillLibraryItem(item.id)
        }
        .contextMenu {
            Button("应用") {
                viewModel.applyTextureFillLibraryItem(item.id)
            }
            Button(item.isFavorite ? "取消收藏" : "收藏") {
                viewModel.setTextureFillLibraryItemFavorite(!item.isFavorite, forItemID: item.id)
            }
            Button("复制") {
                viewModel.duplicateTextureFillLibraryItem(item.id)
            }
            Button("重命名") {
                beginLibraryRename(.texture(item.id), currentName: item.displayName)
            }

            Divider()

            Menu("色标") {
                ForEach(BrushColorTag.allCases, id: \.self) { tag in
                    Button {
                        viewModel.setTextureFillLibraryItemColorTag(tag, forItemID: item.id)
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
                    viewModel.setTextureFillLibraryItemColorTag(nil, forItemID: item.id)
                }
                .disabled(item.colorTag == nil)
            }

            Divider()

            Button("删除", role: .destructive) {
                libraryDeleteTarget = .texture(item.id, item.displayName)
            }
        }
    }

    private func textureFillLibraryEmptyCell() -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.white.opacity(0.03))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.05), lineWidth: 1)
            }
            .aspectRatio(1, contentMode: .fit)
    }

    @ViewBuilder
    private func brushLibrarySlotCell(slotIndex: Int) -> some View {
        let preset = viewModel.workspace.brushLibrary.preset(atSlot: slotIndex)

        if let preset {
            brushPresetCell(preset, slotIndex: slotIndex, showsShortcutLabel: true)
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

    @ViewBuilder
    private func recentBrushLibrarySlotCell(preset: BrushPreset?) -> some View {
        if let preset {
            brushPresetCell(preset, slotIndex: nil, showsShortcutLabel: false)
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.03))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.05), lineWidth: 1)
                }
                .aspectRatio(1, contentMode: .fit)
        }
    }

    private var layersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let activeLayer {
                if !activeLayer.isAdjustmentLayer {
                    HStack(spacing: 8) {
                        Text("混合")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.62))

                        Picker(
                            "",
                            selection: Binding(
                                get: { activeLayer.blendMode },
                                set: { viewModel.setLayerBlendMode(activeLayer.id, blendMode: $0) }
                            )
                        ) {
                            ForEach(LayerBlendMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .environment(\.colorScheme, .dark)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Button {
                            viewModel.toggleLayerClipping(activeLayer.id)
                        } label: {
                            Image(systemName: activeLayer.clipTargetLayerID == nil ? "arrow.down.right.and.arrow.up.left" : "arrow.down.right.and.arrow.up.left.circle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(activeLayer.clipTargetLayerID == nil ? Color.white.opacity(0.66) : Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .buttonTooltip(activeLayer.clipTargetLayerID == nil ? "创建剪贴图层" : "解除剪贴图层")
                    }
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

                if activeLayer.isAdjustmentLayer {
                    activeCurveAdjustmentLayerEditor
                }

                HStack(spacing: 8) {
                    if let mask = activeLayer.mask {
                        Button(viewModel.activeMaskEditingLayerID == activeLayer.id ? "编辑蒙版中" : "编辑蒙版") {
                            if viewModel.activeMaskEditingLayerID == activeLayer.id {
                                viewModel.stopEditingLayerMask()
                            } else {
                                viewModel.beginEditingActiveLayerMask()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button(mask.isEnabled ? "停用" : "启用") {
                            viewModel.toggleActiveLayerMaskEnabled()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("反相") {
                            viewModel.invertActiveLayerMask()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button(role: .destructive) {
                            viewModel.deleteActiveLayerMask()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else {
                        Menu("添加蒙版") {
                            Button("显示全部") { viewModel.addMaskToActiveLayer(revealsAll: true) }
                            Button("隐藏全部") { viewModel.addMaskToActiveLayer(revealsAll: false) }
                        }
                        .controlSize(.small)
                        .environment(\.colorScheme, .dark)
                    }
                    Spacer(minLength: 0)
                }
            }

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if !viewModel.workspace.document.layers.contains(where: \.isGroup) {
                        layerDropInsertionStrip(at: 0)
                    }

                    ForEach(Array(displayLayerEntries.enumerated()), id: \.element.layer.id) { index, entry in
                        layerRow(entry.layer, depth: entry.depth)
                        if !viewModel.workspace.document.layers.contains(where: \.isGroup) {
                            layerDropInsertionStrip(at: index + 1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack(spacing: 8) {
                layerActionButton(systemImage: "plus.square", tooltip: "新建图层") {
                    if let selectedLayerGroupID {
                        viewModel.addLayer(toGroup: selectedLayerGroupID)
                    } else {
                        viewModel.addLayer()
                    }
                }

                layerActionButton(systemImage: "slider.horizontal.3", tooltip: "新建曲线调整层") {
                    viewModel.addCurveAdjustmentLayer()
                }

                layerActionButton(systemImage: "folder.badge.plus", tooltip: "新建图层组") {
                    viewModel.addLayerGroup()
                }

                layerActionButton(systemImage: "doc.on.doc", tooltip: "复制图层") {
                    if selectedLayerGroupID == nil {
                        viewModel.duplicateActiveLayer()
                    }
                }

                layerActionButton(
                    systemImage: selectedLayerGroupID == nil ? "trash" : "folder.badge.minus",
                    tooltip: selectedLayerGroupID == nil ? "删除图层" : "解散图层组",
                    tint: Color.red.opacity(0.95)
                ) {
                    if let selectedLayerGroupID {
                        self.selectedLayerGroupID = nil
                        collapsedLayerGroupIDs.remove(selectedLayerGroupID)
                        viewModel.ungroupLayerGroup(selectedLayerGroupID)
                    } else {
                        viewModel.removeActiveLayer()
                    }
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

    @ViewBuilder
    private var activeCurveAdjustmentLayerEditor: some View {
        if let parameters = viewModel.activeCurveAdjustmentLayerParameters {
            let channel = parameters.selectedChannel
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("曲线调整层", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.88))
                    Spacer()
                    Button("重置") {
                        viewModel.resetActiveCurveAdjustmentLayer()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(parameters.isNeutral)
                }

                CurveEditorView(
                    state: parameters.state(for: channel),
                    isEnabled: true
                ) { state in
                    viewModel.updateActiveCurveAdjustmentLayer(state, channel: channel)
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(1.7, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 5) {
                    ForEach(CurveChannel.allCases, id: \.self) { candidate in
                        Button(candidate.displayName) {
                            viewModel.setActiveCurveAdjustmentLayerChannel(candidate)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white.opacity(candidate == channel ? 0.96 : 0.62))
                        .frame(maxWidth: .infinity, minHeight: 23)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(candidate == channel ? Color.accentColor.opacity(0.3) : Color.white.opacity(0.05))
                        )
                    }
                }
            }
            .padding(9)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.indigo.opacity(0.12))
            )
        }
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
                    systemImage: "arrow.uturn.backward",
                    tooltip: "撤销笔尖编辑 (Cmd+Z)",
                    isSelected: false,
                    width: topInspectorControlButtonWidth,
                    height: topInspectorControlButtonHeight,
                    iconSize: topInspectorControlIconSize,
                    cornerRadius: topInspectorControlCornerRadius
                ) {
                    viewModel.undoBrushTipDraft()
                }
                .disabled(!viewModel.canUndoBrushTipDraft)

                compactToolButton(
                    systemImage: "arrow.uturn.forward",
                    tooltip: "重做笔尖编辑 (Shift+Cmd+Z)",
                    isSelected: false,
                    width: topInspectorControlButtonWidth,
                    height: topInspectorControlButtonHeight,
                    iconSize: topInspectorControlIconSize,
                    cornerRadius: topInspectorControlCornerRadius
                ) {
                    viewModel.redoBrushTipDraft()
                }
                .disabled(!viewModel.canRedoBrushTipDraft)

                compactToolButton(
                    systemImage: brushTipCanvasDisplayMode == .edit ? "scribble.variable" : "pencil.and.outline",
                    tooltip: brushTipCanvasDisplayMode == .edit ? "查看真实笔触预览" : "返回笔尖编辑",
                    isSelected: brushTipCanvasDisplayMode == .strokePreview,
                    width: topInspectorControlButtonWidth,
                    height: topInspectorControlButtonHeight,
                    iconSize: topInspectorControlIconSize,
                    cornerRadius: topInspectorControlCornerRadius
                ) {
                    brushTipCanvasDisplayMode = brushTipCanvasDisplayMode == .edit
                        ? .strokePreview
                        : .edit
                }

                compactToolButton(
                    systemImage: "photo.badge.plus",
                    tooltip: "导入并预处理笔尖图片",
                    isSelected: false,
                    width: topInspectorControlButtonWidth,
                    height: topInspectorControlButtonHeight,
                    iconSize: topInspectorControlIconSize,
                    cornerRadius: topInspectorControlCornerRadius
                ) {
                    guard let url = viewModel.selectBrushTipImageURLFromDisk(),
                          let image = NSImage(contentsOf: url) else {
                        return
                    }
                    brushTipImportCandidate = BrushTipImportCandidate(
                        image: image,
                        sourceLabel: url.deletingPathExtension().lastPathComponent
                    )
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

                brushTipEditingMenu
            }

            if let restoreTitle = primaryDormantTipRestoreTitle(for: viewModel.workspace.toolSession.brush) {
                tipSourceRestoreButton(title: restoreTitle) {
                    viewModel.reactivatePrimaryCustomTipSourceIfAvailable()
                }
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var brushTipEditingMenu: some View {
        Menu {
            Section("编辑工具") {
                Button("圆形画笔 (B)") { tipPaintMode = .round }
                Button("方形画笔 (S)") { tipPaintMode = .square }
                Button("橡皮擦 (E)") { tipPaintMode = .eraser }
            }
            Section("画笔尺寸 · \(Int(viewModel.brushTipEditorBrushSize.rounded())) px") {
                Button("减小画笔 ([)") { adjustTipEditorBrushSize(by: -1) }
                Button("增大画笔 (])") { adjustTipEditorBrushSize(by: 1) }
            }
            Section("变换") {
                Button("顺时针旋转 90°") { rotateCustomTip() }
                Button("水平翻转") { flipCustomTipHorizontally() }
                Button("垂直翻转") { flipCustomTipVertically() }
                Button("居中并适配") { centerAndFitCustomTip() }
            }
            Divider()
            Button("放弃未确认修改", role: .destructive) {
                viewModel.discardBrushTipDraft()
            }
            .disabled(!viewModel.hasPendingBrushTipDraft)
        } label: {
            Image(systemName: tipPaintMode.systemImage)
                .font(.system(size: topInspectorControlIconSize, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.9))
                .frame(width: topInspectorControlButtonWidth, height: topInspectorControlButtonHeight)
                .background(
                    RoundedRectangle(cornerRadius: topInspectorControlCornerRadius)
                        .fill(Color.white.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: topInspectorControlCornerRadius)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        }
        .menuStyle(.borderlessButton)
        .buttonTooltip("笔尖编辑工具与变换 · \(Int(viewModel.brushTipEditorBrushSize.rounded())) px · [ / ] 调整")
    }

    private func adjustTipEditorBrushSize(by delta: Float) {
        viewModel.adjustBrushTipEditorBrushSize(by: delta)
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
        width: CGFloat = topInspectorControlButtonWidth,
        height: CGFloat = topInspectorControlButtonHeight,
        iconSize: CGFloat = topInspectorControlIconSize,
        cornerRadius: CGFloat = topInspectorControlCornerRadius,
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
        .buttonTooltip(tooltip)
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
        .buttonTooltip(tooltip)
    }

    private func compactIconButton(
        systemImage: String,
        tooltip: String,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: topInspectorControlIconSize, weight: .bold))
                .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.98))
                .frame(width: topInspectorControlButtonWidth, height: topInspectorControlButtonHeight)
                .background(
                    RoundedRectangle(cornerRadius: topInspectorControlCornerRadius)
                        .fill(isSelected ? Color.accentColor : Color.white.opacity(0.18))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: topInspectorControlCornerRadius)
                        .stroke(
                            isSelected ? Color.accentColor.opacity(0.95) : Color.white.opacity(0.16),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .buttonTooltip(tooltip)
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

    private func layerRow(_ layer: LayerRecord, depth: Int) -> some View {
        let isActive = layer.isPaintLayer && layer.id == viewModel.workspace.document.activeLayerID
        let isSelectedGroup = layer.isGroup && selectedLayerGroupID == layer.id
        let isEditing = editingLayerID == layer.id

        return HStack(spacing: 7) {
            if layer.isGroup {
                Button {
                    if collapsedLayerGroupIDs.contains(layer.id) {
                        collapsedLayerGroupIDs.remove(layer.id)
                    } else {
                        collapsedLayerGroupIDs.insert(layer.id)
                    }
                } label: {
                    Image(systemName: collapsedLayerGroupIDs.contains(layer.id) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 12, height: 20)
                }
                .buttonStyle(.plain)
                .buttonTooltip(collapsedLayerGroupIDs.contains(layer.id) ? "展开图层组" : "折叠图层组")

                Image(systemName: "folder.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.yellow.opacity(0.82))
                    .frame(width: 28, height: 28)
            } else if layer.isAdjustmentLayer {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.indigo.opacity(0.3))
                    .overlay {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.9))
                    }
                    .frame(width: 28, height: 28)
            } else {
                layerThumbnailView(for: layer)
            }

            Circle()
                .fill((isActive || isSelectedGroup) ? Color.accentColor : Color.white.opacity(0.25))
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
                VStack(alignment: .leading, spacing: 1) {
                    Text(layer.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .lineLimit(1)
                    if layer.isGroup {
                        Text("\(viewModel.workspace.document.childLayers(of: layer.id).count) 个项目")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.42))
                    }
                }
                .onTapGesture(count: 2) {
                    beginLayerRename(layer)
                }
            }

            Spacer()

            if layer.isPaintLayer, !layer.isAdjustmentLayer, layer.isReference {
                Image(systemName: "scope")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.green.opacity(0.9))
                    .help("填充参考图层")
            }

            if layer.isPaintLayer, !layer.isAdjustmentLayer, layer.clipTargetLayerID != nil {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .help("剪贴图层")
            }

            if layer.isPaintLayer, let mask = layer.mask {
                Image(systemName: mask.isEnabled ? "circle.lefthalf.filled" : "circle.dashed")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(viewModel.activeMaskEditingLayerID == layer.id ? Color.accentColor : Color.white.opacity(0.68))
                    .help(mask.isEnabled ? "图层蒙版" : "图层蒙版已停用")
            }

            if layer.isAdjustmentLayer {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.indigo.opacity(0.95))
                    .help("非破坏式曲线调整层")
            }

            Button {
                viewModel.setLayerVisibility(layer.id, isVisible: !layer.isVisible)
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(layer.isVisible ? Color.white.opacity(0.72) : Color.accentColor)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .buttonTooltip(layer.isVisible ? "隐藏图层" : "显示图层")

            if layer.isPaintLayer, !layer.isAdjustmentLayer {
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
                .buttonTooltip(layer.locksTransparentPixels ? "解除锁定透明像素" : "锁定透明像素")
            }

            Button {
                viewModel.toggleLayerLock(layer.id)
            } label: {
                Image(systemName: layer.isLocked ? "lock.fill" : "lock.open")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(layer.isLocked ? Color.orange : Color.white.opacity(0.72))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .buttonTooltip(layer.isLocked ? "解锁图层" : "锁定图层")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .padding(.leading, CGFloat(depth) * 12)
        .background(
            ((isActive || isSelectedGroup) ? Color.accentColor.opacity(0.18) : Color.clear),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onTapGesture {
            if layer.isGroup {
                selectedLayerGroupID = layer.id
            } else {
                selectedLayerGroupID = nil
                viewModel.selectLayer(layer.id)
            }
        }
        .onDrag {
            cancelLayerRename()
            draggedLayerID = layer.id
            return NSItemProvider(object: layer.id.rawValue.uuidString as NSString)
        }
        .contextMenu {
            layerContextMenu(for: layer)
        }
    }

    @ViewBuilder
    private func layerContextMenu(for layer: LayerRecord) -> some View {
        if layer.isGroup {
            Button("在组内新建图层") {
                selectedLayerGroupID = layer.id
                viewModel.addLayer(toGroup: layer.id)
            }
            Button("重命名") { beginLayerRename(layer) }
            Divider()
            Button("解散图层组") {
                selectedLayerGroupID = nil
                collapsedLayerGroupIDs.remove(layer.id)
                viewModel.ungroupLayerGroup(layer.id)
            }
        } else {
            Button("复制图层") {
                viewModel.selectLayer(layer.id)
                viewModel.duplicateActiveLayer()
            }
            Button("重命名") { beginLayerRename(layer) }
            Divider()
            if !layer.isAdjustmentLayer {
                Button(layer.clipTargetLayerID == nil ? "创建剪贴图层" : "解除剪贴图层") {
                    viewModel.toggleLayerClipping(layer.id)
                }
                Button(layer.isReference ? "取消填充参考" : "设为填充参考") {
                    viewModel.toggleLayerReference(layer.id)
                }
            }

            if layer.mask == nil {
                Menu("添加图层蒙版") {
                    Button("显示全部") {
                        viewModel.selectLayer(layer.id)
                        viewModel.addMaskToActiveLayer(revealsAll: true)
                    }
                    Button("隐藏全部") {
                        viewModel.selectLayer(layer.id)
                        viewModel.addMaskToActiveLayer(revealsAll: false)
                    }
                }
            } else {
                Button("编辑图层蒙版") {
                    viewModel.selectLayer(layer.id)
                    viewModel.beginEditingActiveLayerMask()
                }
                Button(layer.mask?.isEnabled == true ? "停用图层蒙版" : "启用图层蒙版") {
                    viewModel.selectLayer(layer.id)
                    viewModel.toggleActiveLayerMaskEnabled()
                }
                Button("反相图层蒙版") {
                    viewModel.selectLayer(layer.id)
                    viewModel.invertActiveLayerMask()
                }
                Button("删除图层蒙版", role: .destructive) {
                    viewModel.selectLayer(layer.id)
                    viewModel.deleteActiveLayerMask()
                }
            }

            let groups = viewModel.workspace.document.layers.filter(\.isGroup)
            if !groups.isEmpty {
                Menu("移入图层组") {
                    ForEach(groups, id: \.id) { group in
                        Button(group.name) {
                            viewModel.moveLayers(Set([layer.id]), toGroup: group.id)
                        }
                    }
                }
            }
            if layer.parentID != nil {
                Button("移出图层组") {
                    viewModel.moveLayers(Set([layer.id]), toGroup: nil)
                }
            }

            Divider()
            Button("向下合并") {
                viewModel.selectLayer(layer.id)
                viewModel.mergeActiveLayerDown()
            }
            Button("删除图层", role: .destructive) {
                viewModel.selectLayer(layer.id)
                viewModel.removeActiveLayer()
            }
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
                .font(.system(size: topInspectorControlIconSize, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: topInspectorControlButtonWidth, height: topInspectorControlButtonHeight)
                .background(
                    RoundedRectangle(cornerRadius: topInspectorControlCornerRadius)
                        .fill(Color.white.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: topInspectorControlCornerRadius)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .buttonTooltip(tooltip)
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
        LayerThumbnailTile(
            layerID: layer.id,
            revision: viewModel.layerThumbnailRevision
        ) {
            await viewModel.loadLayerThumbnail(for: layer.id, maxDimension: 36)
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
        if layer.isGroup {
            selectedLayerGroupID = layer.id
        } else {
            selectedLayerGroupID = nil
            viewModel.selectLayer(layer.id)
        }
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

                Group {
                    if brushTipCanvasDisplayMode == .strokePreview {
                        BrushTipStrokePreview(
                            brush: brushTipPreviewBrush(maskData: editorMaskData),
                            maskData: editorMaskData
                        )
                    } else {
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
                            editorBrushSize: viewModel.brushTipEditorBrushSize,
                            onRequestPaintModeShortcut: { mode in
                                tipPaintMode = mode
                            },
                            onAdjustBrushSizeShortcut: { delta in
                                adjustTipEditorBrushSize(by: delta)
                            },
                            onFocusChanged: { isFocused in
                                viewModel.setBrushTipCanvasFocused(isFocused)
                            },
                            onImportImage: { image in
                                brushTipImportCandidate = BrushTipImportCandidate(
                                    image: image,
                                    sourceLabel: "拖入图片"
                                )
                            },
                            onUndo: { viewModel.undoBrushTipDraft() },
                            onRedo: { viewModel.redoBrushTipDraft() },
                            onUpdateMask: { data in
                                viewModel.updateBrushTipDraft(data)
                            }
                        )
                    }
                }
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
            if brushTipCanvasDisplayMode == .edit {
                Button {
                    viewModel.clearBrushTipDraft()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: topInspectorControlIconSize, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.72))
                        .frame(width: topInspectorControlButtonWidth, height: topInspectorControlButtonHeight)
                        .background(
                            RoundedRectangle(cornerRadius: topInspectorControlCornerRadius)
                                .fill(Color.white.opacity(0.10))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: topInspectorControlCornerRadius)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .buttonTooltip("清空笔尖草稿")
                .padding(8)
            }
        }
        .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier], isTargeted: $isTipImageDropTarget) { providers in
            importTipImageFromDrop(providers: providers)
        }
    }

    private func brushTipPreviewBrush(maskData: Data?) -> BrushSettings {
        var brush = viewModel.workspace.toolSession.brush
        brush.tipShape = .customRound
        brush.customTipSourceSemantic = maskData == nil ? .procedural : .customMask
        brush.customTipAssetID = nil
        brush.customTipImportedSourceInfo = nil
        brush.customTipMaskData = maskData
        brush.customTipEnvelopeMaskData = nil
        brush.compoundBrush.enabled = false
        return brush
    }

    private func importTipImageFromDrop(providers: [NSItemProvider]) -> Bool {
        if let imageProvider = providers.first(where: { $0.canLoadObject(ofClass: NSImage.self) }) {
            imageProvider.loadObject(ofClass: NSImage.self) { object, _ in
                guard let image = object as? NSImage else { return }
                DispatchQueue.main.async {
                    brushTipImportCandidate = BrushTipImportCandidate(
                        image: image,
                        sourceLabel: "拖入图片"
                    )
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
                    guard let image = NSImage(contentsOf: url) else { return }
                    brushTipImportCandidate = BrushTipImportCandidate(
                        image: image,
                        sourceLabel: url.deletingPathExtension().lastPathComponent
                    )
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

            if summary.currentTextureFillUsesImportedTip {
                tipImageLibraryReferenceChip(
                    title: "纹理填充",
                    tint: Color(red: 0.82, green: 0.34, blue: 0.14),
                    tooltip: "当前纹理填充正在使用这张图片"
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
                    tooltip: "当前没有主笔尖、次笔尖、纹理填充或已保存预设引用这张图片"
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
        if summary.currentTextureFillUsesImportedTip {
            parts.append("当前纹理填充素材")
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
        case .textureFill:
            guard viewModel.workspace.toolSession.textureFillTip.sourceSemantic == .importedImage else {
                return nil
            }
            return viewModel.workspace.toolSession.textureFillTip.tipAssetID
        }
    }

    private func pendingTipImageLibrarySelection(for target: TipImageLibrarySheetTarget) -> BrushTipImageAssetID? {
        switch target {
        case .primary:
            return primaryTipImageLibraryPendingSelection
        case .compoundSecondary:
            return compoundSecondaryTipImageLibraryPendingSelection
        case .textureFill:
            return textureFillTipImageLibraryPendingSelection
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
        case .textureFill:
            textureFillTipImageLibraryPendingSelection = assetID
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
        case .textureFill:
            viewModel.applyTextureFillTipImageLibraryItem(assetID)
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
        guard let current = editableBrushTipMaskData else {
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
        viewModel.updateBrushTipDraft(Data(destination))
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
        guard let current = editableBrushTipMaskData else {
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
        viewModel.updateBrushTipDraft(Data(destination))
    }

    private var editableBrushTipMaskData: Data? {
        let source = viewModel.hasPendingBrushTipDraft
            ? viewModel.brushTipDraftMaskData
            : viewModel.workspace.toolSession.brush.customTipMaskData
        return resampledMaskData(source, targetResolution: tipMaskResolution)
    }

    private func centerAndFitCustomTip() {
        guard let current = editableBrushTipMaskData else { return }
        let source = [UInt8](current)
        var minX = tipMaskResolution
        var minY = tipMaskResolution
        var maxX = -1
        var maxY = -1
        for y in 0..<tipMaskResolution {
            for x in 0..<tipMaskResolution where source[(y * tipMaskResolution) + x] > 1 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return }

        let contentWidth = maxX - minX + 1
        let contentHeight = maxY - minY + 1
        let targetSide = Int(Double(tipMaskResolution) * 0.84)
        let scale = min(
            Double(targetSide) / Double(contentWidth),
            Double(targetSide) / Double(contentHeight)
        )
        let drawWidth = max(1, Int((Double(contentWidth) * scale).rounded()))
        let drawHeight = max(1, Int((Double(contentHeight) * scale).rounded()))
        let offsetX = (tipMaskResolution - drawWidth) / 2
        let offsetY = (tipMaskResolution - drawHeight) / 2
        var destination = [UInt8](repeating: 0, count: source.count)
        for y in 0..<drawHeight {
            let sourceY = min(maxY, minY + Int(Double(y) / scale))
            for x in 0..<drawWidth {
                let sourceX = min(maxX, minX + Int(Double(x) / scale))
                destination[((offsetY + y) * tipMaskResolution) + offsetX + x] =
                    source[(sourceY * tipMaskResolution) + sourceX]
            }
        }
        viewModel.updateBrushTipDraft(Data(destination))
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

    private func brushPresetCell(
        _ preset: BrushPreset,
        slotIndex: Int?,
        showsShortcutLabel: Bool
    ) -> some View {
        let isSelected = viewModel.workspace.brushLibrary.selectedPresetID == preset.id
        let isApplied = isSelected && preset.brush == viewModel.workspace.toolSession.brush
        let isModified = isSelected && !isApplied
        let strokeColor: Color = isApplied
            ? Color.accentColor.opacity(0.9)
            : (isModified ? Color.orange.opacity(0.9) : Color.white.opacity(0.06))
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
                    .fill(isApplied ? Color.accentColor.opacity(0.18) : (isModified ? Color.orange.opacity(0.10) : Color.white.opacity(0.03)))
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

                if showsShortcutLabel, let slotIndex {
                    shortcutSlotLabel(for: slotIndex)
                        .allowsHitTesting(false)
                }


                if preset.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.yellow)
                        .padding(5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .allowsHitTesting(false)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .help(preset.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(preset.name)
        .accessibilityValue(isApplied ? "已应用" : (isModified ? "已修改" : ""))
        .accessibilityHint("激活后应用画笔；右键管理画笔")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            viewModel.applyBrushPreset(preset.id)
        }
        .contextMenu {
            Button("应用") {
                viewModel.applyBrushPreset(preset.id)
            }

            Button(preset.isFavorite ? "取消收藏" : "收藏") {
                viewModel.setBrushPresetFavorite(!preset.isFavorite, forPresetID: preset.id)
            }

            Button("复制") {
                viewModel.duplicateBrushPreset(preset.id)
            }

            if !preset.isBuiltIn {
                Button("重命名") {
                    beginLibraryRename(.brush(preset.id), currentName: preset.name)
                }
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

            if !preset.isBuiltIn {
                Divider()
                Button("删除", role: .destructive) {
                    libraryDeleteTarget = .brush(preset.id, preset.name)
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

    private func movePatternLibraryItemFromDrop(providers: [NSItemProvider], toSlot slotIndex: Int) -> Bool {
        if let draggedPatternLibraryItemID {
            viewModel.movePatternLibraryItem(draggedPatternLibraryItemID, toSlot: slotIndex)
            self.draggedPatternLibraryItemID = nil
            return true
        }

        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return false
        }

        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let itemID = object as? NSString,
                  let uuid = UUID(uuidString: String(itemID)) else {
                return
            }
            DispatchQueue.main.async {
                viewModel.movePatternLibraryItem(uuid, toSlot: slotIndex)
            }
        }
        return true
    }

    private func moveTextureFillLibraryItemFromDrop(
        providers: [NSItemProvider],
        toSlot slotIndex: Int
    ) -> Bool {
        if let draggedTextureFillLibraryItemID {
            viewModel.moveTextureFillLibraryItem(draggedTextureFillLibraryItemID, toSlot: slotIndex)
            self.draggedTextureFillLibraryItemID = nil
            return true
        }

        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return false
        }

        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let itemID = object as? NSString,
                  let uuid = UUID(uuidString: String(itemID)) else {
                return
            }
            DispatchQueue.main.async {
                viewModel.moveTextureFillLibraryItem(uuid, toSlot: slotIndex)
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

            let scatter = Double(brush.scatterAmount)
            let jitter = Double(brush.jitterAmount)
            let stampCount = StageOneBrushPreviewRasterizer.libraryStrokePreviewStampCount(
                spacingPercent: brush.spacingPercent
            )

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
        let compensationAmount = BrushSettings.resolvedBuildUpCompensationAmount(
            automaticCompensationAmount: brush.buildMode == .buildUp ? 1 : 0,
            brushCompensationAmount: brush.buildUpOpacityCompensationAmount
        )
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
        Double(
            BrushSettings.samplePressureCurve(
                pressure: Float(pressure),
                state: brush.resolvedSizePressureCurveState
            )
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
                state: brush.resolvedOpacityPressureCurveState
            )
        )
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

    private var displayLayerEntries: [LayerPanelEntry] {
        let layers = viewModel.workspace.document.layers
        var entries: [LayerPanelEntry] = []
        var visited: Set<LayerID> = []

        func append(_ layer: LayerRecord, depth: Int) {
            guard visited.insert(layer.id).inserted else { return }
            entries.append(LayerPanelEntry(layer: layer, depth: depth))
            guard layer.isGroup, !collapsedLayerGroupIDs.contains(layer.id) else { return }
            for child in layers.filter({ $0.parentID == layer.id }).reversed() {
                append(child, depth: depth + 1)
            }
        }

        for layer in layers.filter({ $0.parentID == nil }).reversed() {
            append(layer, depth: 0)
        }
        for orphan in layers.reversed() where !visited.contains(orphan.id) {
            append(orphan, depth: 0)
        }
        return entries
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
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
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
            let diameter = max(100.0, min(geo.size.width, geo.size.height))
            let ringWidth = min(6.0, max(14.0 / 3.0, diameter * (0.0475 * 2.0 / 3.0)))
            let squareSize = max(
                52.0,
                ColorHueWheelGeometry.innerSquareSide(
                    diameter: diameter,
                    ringWidth: ringWidth,
                    gap: 4
                )
            )

            ZStack {
                ColorHueRingPickerView(
                    hue: proxy.colorPanel.pickerHue,
                    ringWidth: ringWidth,
                    onUpdateHue: { hue in
                        var updated = proxy.colorPanel
                        updated.pickerHue = ColorBlocksEngine.wrapHue(hue)
                        proxy.colorPanel = updated
                        proxy.selectedColor = ColorBlocksEngine.pickerColor(from: updated)
                    },
                    onDragEnded: { viewModel.setColorPickerHue($0) }
                )
                .frame(width: diameter, height: diameter)

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
                .overlay(
                    Rectangle()
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        .allowsHitTesting(false)
                )
            }
            .frame(width: diameter, height: diameter, alignment: .center)
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
                .font(.system(size: topInspectorControlIconSize, weight: .bold))
                .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.98))
                .frame(width: topInspectorControlButtonWidth, height: topInspectorControlButtonHeight)
                .background(
                    RoundedRectangle(cornerRadius: topInspectorControlCornerRadius)
                        .fill(isSelected ? Color.accentColor : Color.white.opacity(0.18))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: topInspectorControlCornerRadius)
                        .stroke(
                            isSelected ? Color.accentColor.opacity(0.95) : Color.white.opacity(0.16),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .buttonTooltip(tooltip)
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
    let fillsAvailableHeight: Bool
    let content: Content

    init(
        title: String,
        fillsAvailableHeight: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.fillsAvailableHeight = fillsAvailableHeight
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: title.isEmpty ? 0 : 10) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.74))
            }
            content
        }
        .padding(inspectorPanelPadding)
        .frame(
            maxWidth: .infinity,
            maxHeight: fillsAvailableHeight ? .infinity : nil,
            alignment: .topLeading
        )
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
    @State private var isDraggingViewport = false

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
                    viewportRenderScale: 1,
                    displaySamplingMode: .linear,
                    drawsTransparencyCheckerboard: viewModel.showsTransparencyCheckerboard,
                    isPanModeActive: false,
                    isTransformingSelection: false,
                    isFreeTransformDragging: false,
                    activeFreeTransformInteractionMode: nil,
                    transformPreview: .identity,
                    freeTransformToolMode: .standard,
                    meshWarpGrid: nil,
                    linearGradientPreview: nil,
                    sectorGradientPreview: nil,
                    patternPlacementPhase: .idle,
                    gradientPreviewColor: .white,
                    gradientSettings: .currentColorToTransparent(.white),
                    gradientPaintJitterAmount: 0,
                    gradientPaintContrastAmount: 0,
                    gradientDistortionAmount: 0,
                    onStrokeBegan: {},
                    onStrokeInput: { _ in },
                    onStrokeEnded: {},
                    onFlushPendingBrushWork: { _ in nil },
                    canDrainPendingBrushCommitsInteractively: { _ in false },
                    onDrainPendingBrushCommitsInteractively: { _ in },
                    resolveBrushDisplayTexture: { layerID in
                        viewModel.brushDisplayTexture(for: layerID)
                    },
                    resolvePatternPlacementTexture: { _ in nil },
                    onEyedropperSample: { _ in },
                    onBucketFill: { _ in },
                    onCanvasClick: { _, _, _ in },
                    onCanvasHover: { _ in },
                    onCanvasExited: {},
                    onStraightLineDragBegan: { _ in },
                    onStraightLineDragChanged: { _ in },
                    onStraightLineDragEnded: { _ in },
                    onSelectionBegan: { _, _ in },
                    onSelectionChanged: { _, _ in },
                    onSelectionChangedBatch: { _, _ in },
                    onSelectionEnded: { _, _ in },
                    onSelectionMouseDown: { _, _ in .idle },
                    onMoveSelectionPreview: { _, _ in },
                    onCommitSelectionMove: {},
                    onTransformBegan: { _, _, _ in },
                    onTransformChanged: { _, _ in },
                    onTransformEnded: { _, _ in },
                    onTransformOffsetChanged: { _ in },
                    onCanvasRotationChanged: { _ in },
                    onViewportPan: { _, _ in },
                    onViewportZoom: { _, _ in },
                    onPanModeChanged: { _ in },
                    onToolShortcut: { _, _ in },
                    onKeyDown: { _ in false },
                    onKeyUp: { _ in false },
                    onModifierFlagsChanged: { _ in false },
                    onGradientDragBegan: { _, _ in },
                    onGradientDragChanged: { _, _ in },
                    onGradientDragEnded: { _, _ in },
                    onPatternPlacementBegan: { _, _ in },
                    onPatternPlacementChanged: { _ in },
                    onPatternPlacementEnded: { _ in },
                    onApplyPatternPlacement: {},
                    onEnterGradientEditing: {},
                    onCancelCanvasTool: {},
                    onApplyGradientSession: {},
                    onClearSelection: {},
                    onRequestSelectionRefinement: { _ in },
                    onApplyTransform: {},
                    onCancelTransform: {},
                    isLuminosityPreviewEnabled: false,
                    onAdjustBrushSize: { _ in }
                )
                .id(viewModel.documentRenderGeneration)
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
                        canvasSize: canvasSize,
                        isDragging: isDraggingViewport
                    )
                    .allowsHitTesting(false)
                }

                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if !isDraggingViewport {
                                    isDraggingViewport = true
                                    NSCursor.closedHand.set()
                                }
                                viewModel.centerViewport(
                                    on: navigatorCanvasPoint(
                                        for: value.location,
                                        presentation: presentation
                                    )
                                )
                            }
                            .onEnded { _ in
                                isDraggingViewport = false
                                NSCursor.openHand.set()
                            }
                    )
                    .onHover { hovering in
                        if hovering {
                            NSCursor.openHand.set()
                        } else {
                            NSCursor.arrow.set()
                        }
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

    private func navigatorCanvasPoint(
        for point: CGPoint,
        presentation: CanvasPresentation
    ) -> CanvasPoint {
        let localX = (point.x - presentation.documentOrigin.x) /
            max(presentation.documentDisplaySize.x, 0.000_001)
        let localY = (point.y - presentation.documentOrigin.y) /
            max(presentation.documentDisplaySize.y, 0.000_001)
        return CanvasPoint(
            x: min(max(localX, 0), 1) * Double(canvasSize.width),
            y: min(max(localY, 0), 1) * Double(canvasSize.height)
        )
    }
}

private struct NavigatorVisibleRegionOverlay: View {
    let polygon: [CanvasPoint]
    let presentation: CanvasPresentation
    let canvasSize: CanvasSize
    let isDragging: Bool

    var body: some View {
        let regionPath = Path { path in
            guard let first = polygon.first else { return }
            path.move(to: mappedPoint(for: first))
            for point in polygon.dropFirst() {
                path.addLine(to: mappedPoint(for: point))
            }
            path.closeSubpath()
        }
        regionPath
            .fill(Color.accentColor.opacity(isDragging ? 0.16 : 0.08))
            .overlay(
                regionPath.stroke(Color.black.opacity(0.72), lineWidth: 3)
            )
            .overlay(
                regionPath.stroke(Color.accentColor.opacity(0.98), lineWidth: isDragging ? 2 : 1.5)
            )
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
        let indicatorChanged = previousPanel.pickerX != panel.pickerX
            || previousPanel.pickerY != panel.pickerY
        if gradientChanged || (indicatorChanged && !nsView.isDragging) || !nsView.hasDrawnOnce {
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
    fileprivate var isDragging = false
    private var localX: Float = 0
    private var localY: Float = 0

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
        if let image = sharedColorPickerSVImage(size: size, panel: panel) {
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
        let r: CGFloat = 2
        let circle = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(0.75)
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
                if let image = sharedColorPickerVerticalHueImage(height: height, width: width) {
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
                if let image = sharedColorPickerHorizontalHueImage(width: width, height: height) {
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

private struct BrushTipStrokePreview: View {
    let brush: BrushSettings
    let maskData: Data?

    private let samples: [(String, Float)] = [
        ("轻", 0.2),
        ("中", 0.5),
        ("重", 0.85)
    ]

    var body: some View {
        VStack(spacing: 5) {
            ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
                HStack(spacing: 6) {
                    Text(sample.0)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.58))
                        .frame(width: 14)

                    if let image = StageOneBrushPreviewRasterizer.compoundStrokePreviewImage(
                        for: brush,
                        resolution: 64,
                        width: 360,
                        pressure: sample.1,
                        paintVariationSeed: UInt32(index)
                    ) {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                    } else {
                        Text(maskData == nil ? "当前为程序化圆形笔尖" : "无法生成预览")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.45))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 43, maxHeight: 43)
                .padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.35)))
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.14))
    }
}

private struct BrushTipImportSheet: View {
    let candidate: BrushTipImportCandidate
    @ObservedObject var viewModel: WorkspaceViewModel
    let onCancel: () -> Void
    let onApply: (BrushTipImageImportOptions) -> Void

    @State private var options = BrushTipImageImportOptions()

    private var previewMaskData: Data? {
        viewModel.brushTipImportPreviewMask(from: candidate.image, options: options)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("导入笔尖图片")
                        .font(.system(size: 17, weight: .bold))
                    Text("先确认取样方式；原图不会被修改")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(candidate.sourceLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 12) {
                importPreviewCard(title: "原图") {
                    Image(nsImage: candidate.image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                }
                importPreviewCard(title: "笔尖遮罩") {
                    if let previewMaskData,
                       let image = StageOneBrushPreviewRasterizer.editorMaskImage(
                           from: previewMaskData,
                           resolution: tipMaskResolution,
                           cropToContent: false
                       ) {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                    } else {
                        Text("当前设置没有可用内容")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Picker("取样", selection: $options.interpretation) {
                    ForEach(BrushTipImageInterpretation.allCases, id: \.self) { interpretation in
                        Text(interpretation.displayName).tag(interpretation)
                    }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 18) {
                    Toggle("反相", isOn: $options.isInverted)
                    Toggle("自动裁切内容", isOn: $options.cropsToContent)
                    Toggle("阈值", isOn: $options.usesThreshold)
                }
                .toggleStyle(.checkbox)

                if options.usesThreshold {
                    HStack(spacing: 10) {
                        Text("阈值")
                            .font(.system(size: 11, weight: .semibold))
                        Slider(value: $options.threshold, in: 0.02...0.98)
                        Text("\(Int((options.threshold * 100).rounded()))%")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("载入为草稿") { onApply(options) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(previewMaskData == nil)
            }
        }
        .padding(18)
        .frame(width: 560)
        .interactiveDismissDisabled()
    }

    private func importPreviewCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.black.opacity(0.14))
                content()
                    .padding(8)
            }
            .frame(maxWidth: .infinity, minHeight: 190, maxHeight: 190)
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.10)))
        }
        .frame(maxWidth: .infinity)
    }
}

private enum TipPaintMode {
    case round
    case square
    case eraser

    var systemImage: String {
        switch self {
        case .round: "circle.fill"
        case .square: "square.fill"
        case .eraser: "eraser.fill"
        }
    }
}

private struct TipMaskCanvasView: NSViewRepresentable {
    let maskData: Data?
    let syncToken: String
    let fitImportedPreview: Bool
    let paintMode: TipPaintMode
    let editorBrushSize: Float
    let onRequestPaintModeShortcut: (TipPaintMode) -> Void
    let onAdjustBrushSizeShortcut: (Float) -> Void
    let onFocusChanged: (Bool) -> Void
    let onImportImage: (NSImage) -> Void
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onUpdateMask: (Data) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onRequestPaintModeShortcut: onRequestPaintModeShortcut,
            onAdjustBrushSizeShortcut: onAdjustBrushSizeShortcut,
            onFocusChanged: onFocusChanged,
            onImportImage: onImportImage,
            onUndo: onUndo,
            onRedo: onRedo,
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
            editorBrushSize: editorBrushSize
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
            editorBrushSize: editorBrushSize
        )
    }

    final class Coordinator: NSObject {
        let onRequestPaintModeShortcut: (TipPaintMode) -> Void
        let onAdjustBrushSizeShortcut: (Float) -> Void
        let onFocusChanged: (Bool) -> Void
        let onImportImage: (NSImage) -> Void
        let onUndo: () -> Void
        let onRedo: () -> Void
        let onUpdateMask: (Data) -> Void

        init(
            onRequestPaintModeShortcut: @escaping (TipPaintMode) -> Void,
            onAdjustBrushSizeShortcut: @escaping (Float) -> Void,
            onFocusChanged: @escaping (Bool) -> Void,
            onImportImage: @escaping (NSImage) -> Void,
            onUndo: @escaping () -> Void,
            onRedo: @escaping () -> Void,
            onUpdateMask: @escaping (Data) -> Void
        ) {
            self.onRequestPaintModeShortcut = onRequestPaintModeShortcut
            self.onAdjustBrushSizeShortcut = onAdjustBrushSizeShortcut
            self.onFocusChanged = onFocusChanged
            self.onImportImage = onImportImage
            self.onUndo = onUndo
            self.onRedo = onRedo
            self.onUpdateMask = onUpdateMask
        }
    }
}

private final class TipMaskEditorNSView: NSView, WorkspaceKeyboardFocusOwner {
    weak var coordinator: TipMaskCanvasView.Coordinator?

    private var maskBytes = [UInt8](repeating: 0, count: tipMaskResolution * tipMaskResolution)
    private var livePreviewRGBAData = Data(
        repeating: 255,
        count: tipMaskResolution * tipMaskResolution * 4
    )
    private var paintMode: TipPaintMode = .round
    private var editorBrushSize: Float = 28
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
    private var activeStrokeRenderSession: StageOneBrushPreviewRasterizer.StrokeAlphaSession?
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
        editorBrushSize: Float
    ) {
        self.paintMode = paintMode
        let nextEditorBrushSize = min(max(editorBrushSize, 2), 128)
        if self.editorBrushSize != nextEditorBrushSize {
            self.editorBrushSize = nextEditorBrushSize
            needsDisplay = true
        }

        if syncToken != externalSyncToken {
            externalSyncToken = syncToken
            hasLocalChanges = false
            strokeBaseMaskBytes = nil
            activeStrokePoints = []
            activeStrokeRenderSession = nil
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
        let strokeBrush = strokeBrushSettings(for: paintMode)
        // Paint and erase both need positive coverage; mask subtraction happens during the merge.
        activeStrokeRenderSession = StageOneBrushPreviewRasterizer.makeStrokeAlphaSession(
            for: strokeBrush,
            resolution: tipMaskResolution
        )
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
            if let update = activeStrokeRenderSession?.finish() {
                mergeRenderedStrokeAlphaUpdate(update)
                flushIncrementalDisplayIfNeeded()
            }
            livePreviewImageDirty = true
            needsDisplay = true
            coordinator?.onUpdateMask(Data(maskBytes))
            hasLocalChanges = false
        }
        strokeBaseMaskBytes = nil
        activeStrokePoints = []
        activeStrokeRenderSession = nil
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
        guard let window, NSApp.keyWindow === window else { return false }
        if let eventWindow = event.window, eventWindow !== window {
            return false
        }
        if window.firstResponder === self {
            return true
        }
        return shortcutContextArmed
    }

    private func handleShortcutEvent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if modifiers.contains(.command) || modifiers.contains(.control) {
            let shortcut = event.charactersIgnoringModifiers?.lowercased()
            if shortcut == "v" {
                return importImageFromPasteboard(NSPasteboard.general)
            }
            if shortcut == "z" {
                if event.modifierFlags.contains(.shift) {
                    coordinator?.onRedo()
                } else {
                    coordinator?.onUndo()
                }
                return true
            }
            return false
        }
        if let direction = brushSizeShortcutDirection(for: event) {
            coordinator?.onAdjustBrushSizeShortcut(direction)
            return true
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
        case "s":
            coordinator?.onRequestPaintModeShortcut(.square)
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

        if let activeStrokeRenderSession {
            if let update = activeStrokeRenderSession.append(points: [startPoint, endPoint]) {
                mergeRenderedStrokeAlphaUpdate(update)
            }
            flushIncrementalDisplayIfNeeded()
            return
        }

        var scratchSamplingState: BrushStrokeSamplingState?
        guard let alphaBytes = StageOneBrushPreviewRasterizer.strokeAlphaBytes(
            for: brush,
            tool: .brush,
            resolution: tipMaskResolution,
            points: activeStrokePoints,
            samplingState: &scratchSamplingState,
            flushPendingSamples: true
        ) else {
            return
        }

        mergeRenderedStrokeAlphaBytes(
            alphaBytes,
            bounds: BrushPixelBounds(
                originX: 0,
                originY: 0,
                width: tipMaskResolution,
                height: tipMaskResolution
            ),
            paintMode: paintMode,
            buildMode: brush.buildMode
        )
        flushIncrementalDisplayIfNeeded()
    }

    private func currentRadius() -> Double {
        Double(editorBrushSize) * 0.5
    }

    private func flushIncrementalDisplayIfNeeded() {
        guard !accumulatedDirtyRect.isNull else { return }
        livePreviewImageDirty = true
        setNeedsDisplay(accumulatedDirtyRect.insetBy(dx: -2, dy: -2))
        accumulatedDirtyRect = .null
    }

    private func mergeRenderedStrokeAlphaBytes(
        _ alphaBytes: [UInt8],
        bounds: BrushPixelBounds,
        paintMode: TipPaintMode,
        buildMode: BrushBuildMode
    ) {
        guard
            bounds.originX >= 0,
            bounds.originY >= 0,
            bounds.originX + bounds.width <= tipMaskResolution,
            bounds.originY + bounds.height <= tipMaskResolution,
            alphaBytes.count == bounds.width * bounds.height
        else {
            return
        }

        var minX = tipMaskResolution
        var minY = tipMaskResolution
        var maxX = -1
        var maxY = -1

        for localY in 0..<bounds.height {
            for localX in 0..<bounds.width {
                let localIndex = (localY * bounds.width) + localX
                let alpha = alphaBytes[localIndex]

                let x = bounds.originX + localX
                let y = bounds.originY + localY
                let index = (y * tipMaskResolution) + x
                let existing = strokeBaseMaskBytes?[index] ?? maskBytes[index]
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

                guard updated != maskBytes[index] else { continue }
                maskBytes[index] = updated

                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
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

    private func mergeRenderedStrokeAlphaUpdate(
        _ update: StageOneBrushPreviewRasterizer.StrokeAlphaUpdate
    ) {
        mergeRenderedStrokeAlphaBytes(
            update.alphaBytes,
            bounds: update.bounds,
            paintMode: paintMode,
            buildMode: .buildUp
        )
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
        var brush = BrushSettings.stageOneDefault
        brush.size = editorBrushSize
        brush.opacity = 1
        brush.spacingPercent = 5
        brush.scatterAmount = 0
        brush.jitterAmount = 0
        brush.colorJitterAmount = 0
        brush.paintJitterAmount = 0
        brush.paintContrastAmount = 0
        brush.stampRotationDegrees = 0
        brush.followsStrokeDirection = false
        brush.pressureSizeAmount = 0
        brush.pressureOpacityAmount = 0
        brush.compoundBrush.enabled = false
        switch paintMode {
        case .square:
            brush.tipShape = .square
            brush.customTipSourceSemantic = .procedural
            brush.customTipAssetID = nil
            brush.customTipImportedSourceInfo = nil
            brush.customTipMaskData = nil
            brush.customTipEnvelopeMaskData = nil
        case .round, .eraser:
            brush.tipShape = .hardRound
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

import SwiftUI

struct CompoundBrushBuilderSheet: View {
    private enum TipLibraryTarget: String, Identifiable {
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

    @ObservedObject var viewModel: WorkspaceViewModel

    @Environment(\.dismiss) private var dismiss

    @State private var previewPressure: Double = 0.5
    @State private var primaryPreviewImage: CGImage?
    @State private var secondaryPreviewImage: CGImage?
    @State private var strokePreviewImage: CGImage?
    @State private var tipLibraryTarget: TipLibraryTarget?
    @State private var primaryPendingSelection: BrushTipImageAssetID?
    @State private var compoundPendingSelection: BrushTipImageAssetID?
    @State private var initialPreviewTask: Task<Void, Never>?

    private var brush: BrushSettings { viewModel.workspace.toolSession.brush }

    var body: some View {
        let brush = viewModel.workspace.toolSession.brush
        let isCompoundEnabled = brush.compoundBrush.enabled

        VStack(alignment: .leading, spacing: 14) {
            header(brush: brush)

            HStack(alignment: .top, spacing: 12) {
                // Left column: stroke preview + primary tip
                VStack(alignment: .leading, spacing: 12) {
                    compoundStrokePreviewSection(brush: brush)
                        .disabled(!isCompoundEnabled)
                        .opacity(isCompoundEnabled ? 1 : 0.35)

                    compoundPrimarySection(brush: brush)
                }
                .frame(maxWidth: .infinity)

                // Right column: secondary tip + pressure mix
                VStack(alignment: .leading, spacing: 12) {
                    compoundSecondarySection(brush: brush)
                    compoundPressureMixSection(brush: brush)
                }
                .frame(maxWidth: .infinity)
                .disabled(!isCompoundEnabled)
                .opacity(isCompoundEnabled ? 1 : 0.35)
            }
        }
        .padding(18)
        .frame(
            minWidth: 1100,
            idealWidth: 1180,
            maxWidth: 1240,
            alignment: .topLeading
        )
        .background(Color(red: 0.10, green: 0.10, blue: 0.11))
        .onAppear {
            scheduleInitialPreviews(for: brush)
        }
        .onDisappear {
            initialPreviewTask?.cancel()
            initialPreviewTask = nil
        }
        .sheet(item: $tipLibraryTarget) { target in
            tipImageLibrarySheet(for: target)
        }
    }

    private func header(brush: BrushSettings) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("组合笔刷")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)

                Spacer()

                Button("刷新主次预览") {
                    refreshTipPreviews(for: brush)
                }
                .buttonStyle(CompoundTextButtonStyle())

                Text(brush.compoundBrush.enabled ? "组合模式已启用" : "组合模式未启用")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        Capsule()
                            .fill(brush.compoundBrush.enabled ? Color.accentColor.opacity(0.88) : Color.white.opacity(0.12))
                    )

                Button("完成") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }

            HStack(spacing: 10) {
                Text("混合模式")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.92))

                HStack(spacing: 8) {
                    ForEach(CompoundBrushMode.allCases, id: \.self) { mode in
                        Button(mode.displayName) {
                            viewModel.setCompoundBrushMode(mode)
                            refreshStrokePreview(for: viewModel.workspace.toolSession.brush)
                        }
                        .buttonStyle(CompoundModeButtonStyle(isSelected: brush.compoundBrush.mode == mode))
                    }
                }
            }
            .disabled(!brush.compoundBrush.enabled)
            .opacity(brush.compoundBrush.enabled ? 1 : 0.35)
        }
    }

    private func compoundStrokePreviewSection(brush: BrushSettings) -> some View {
        compoundCard(title: "实时笔迹预览") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    compoundImageFrame(image: strokePreviewImage, height: 100)

                    Button("刷新真实预览") {
                        refreshStrokePreview(for: brush)
                    }
                    .buttonStyle(CompoundTextButtonStyle())
                }

                OptimizedLabeledSlider(
                    title: "预览压力",
                    valueText: "\(Int(previewPressure * 100))%",
                    value: $previewPressure,
                    range: 0...1
                )

                Text("预览直接走真实渲染器的离屏绘制，用来观察轻压偏次笔尖、重压偏主笔尖。")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.62))
            }
        }
    }

    private func compoundPrimarySection(brush: BrushSettings) -> some View {
        compoundCard(title: "主笔尖") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    compoundImageFrame(image: primaryPreviewImage, height: 108)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            compoundIconButton(systemImage: "photo.badge.plus", title: "导入") {
                                viewModel.importBrushTipImageFromDisk()
                                refreshTipPreviews(for: viewModel.workspace.toolSession.brush)
                                refreshStrokePreview(for: viewModel.workspace.toolSession.brush)
                            }

                            compoundIconButton(systemImage: "square.grid.3x2", title: "素材库") {
                                primaryPendingSelection = brush.customTipAssetID
                                tipLibraryTarget = .primary
                            }

                            Spacer(minLength: 0)

                            Button(brush.followsStrokeDirection ? "跟随笔势" : "跟随笔势") {
                                viewModel.setBrushFollowsStrokeDirection(!brush.followsStrokeDirection)
                            }
                            .buttonStyle(
                                CompoundModeButtonStyle(isSelected: brush.followsStrokeDirection)
                            )
                        }

                        Text(primaryTipSummary(for: brush))
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.82))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }

                OptimizedCompactSlider(
                    title: "大小",
                    valueText: "\(Int(brush.size)) px",
                    value: Binding(get: { Double(brush.size) }, set: { _ in }),
                    range: 1...512
                ) {
                    viewModel.setBrushSize(Float($0))
                }

                OptimizedCompactSlider(
                    title: "间距",
                    valueText: "\(Int(brush.spacingPercent))%",
                    value: Binding(get: { Double(brush.spacingPercent) }, set: { _ in }),
                    range: 5...150
                ) {
                    viewModel.setBrushSpacingPercent(Float($0))
                }

                OptimizedCompactSlider(
                    title: "角度",
                    valueText: "\(Int(brush.stampRotationDegrees))°",
                    value: Binding(get: { Double(brush.stampRotationDegrees) }, set: { _ in }),
                    range: 0...360
                ) {
                    viewModel.setBrushStampRotationDegrees(Float($0))
                }

                OptimizedCompactSlider(
                    title: "大小压感",
                    valueText: "\(Int(brush.pressureSizeAmount * 100))%",
                    value: Binding(get: { Double(brush.pressureSizeAmount) }, set: { _ in }),
                    range: 0...1
                ) {
                    viewModel.setCompoundPrimaryPressureSizeAmount(Float($0))
                }

                OptimizedCompactSlider(
                    title: "透明压感",
                    valueText: "\(Int(brush.pressureOpacityAmount * 100))%",
                    value: Binding(get: { Double(brush.pressureOpacityAmount) }, set: { _ in }),
                    range: 0...1
                ) {
                    viewModel.setCompoundPrimaryPressureOpacityAmount(Float($0))
                }
            }
        }
    }

    private func compoundSecondarySection(brush: BrushSettings) -> some View {
        let secondary = brush.compoundBrush.secondary

        return compoundCard(title: "次笔尖") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    compoundImageFrame(image: secondaryPreviewImage, height: 108)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            compoundIconButton(systemImage: "photo.badge.plus", title: "导入") {
                                viewModel.importCompoundSecondaryTipImageFromDisk()
                                refreshTipPreviews(for: viewModel.workspace.toolSession.brush)
                                refreshStrokePreview(for: viewModel.workspace.toolSession.brush)
                            }

                            compoundIconButton(systemImage: "square.grid.3x2", title: "素材库") {
                                compoundPendingSelection = brush.compoundBrush.secondary.tipAssetID
                                tipLibraryTarget = .compoundSecondary
                            }

                            compoundIconButton(systemImage: "trash", title: "清空") {
                                viewModel.clearCompoundSecondaryTipMask()
                                refreshTipPreviews(for: viewModel.workspace.toolSession.brush)
                                refreshStrokePreview(for: viewModel.workspace.toolSession.brush)
                            }

                            Spacer(minLength: 0)

                            Button("跟随笔势") {
                                viewModel.setCompoundSecondaryFollowsStrokeDirection(!secondary.followsStrokeDirection)
                            }
                            .buttonStyle(
                                CompoundModeButtonStyle(isSelected: secondary.followsStrokeDirection)
                            )

                            Button("相对") {
                                viewModel.setCompoundSecondaryUsesRelativeSize(secondary.sizeMode != .relativeToPrimary)
                                let updatedBrush = viewModel.workspace.toolSession.brush
                                refreshTipPreviews(for: updatedBrush)
                                refreshStrokePreview(for: updatedBrush)
                            }
                            .buttonStyle(
                                CompoundModeButtonStyle(
                                    isSelected: secondary.sizeMode == .relativeToPrimary
                                )
                            )
                        }

                        HStack(spacing: 6) {
                            ForEach(
                                [BrushTipShape.hardRound, .softRound, .square, .customRound],
                                id: \.self
                            ) { tipShape in
                                Button(tipShape.displayName) {
                                    viewModel.setCompoundSecondaryTipShape(tipShape)
                                    refreshTipPreviews(for: viewModel.workspace.toolSession.brush)
                                    refreshStrokePreview(for: viewModel.workspace.toolSession.brush)
                                }
                                .buttonStyle(CompoundModeButtonStyle(isSelected: secondary.tipShape == tipShape))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }

                OptimizedCompactSlider(
                    title: "大小",
                    valueText: secondary.sizeMode == .relativeToPrimary
                        ? "\(Int(secondary.relativeSizeRatio * 100))%"
                        : "\(Int(secondary.size)) px",
                    value: Binding(
                        get: {
                            secondary.sizeMode == .relativeToPrimary
                                ? Double(secondary.relativeSizeRatio * 100)
                                : Double(secondary.size)
                        },
                        set: { _ in }
                    ),
                    range: secondary.sizeMode == .relativeToPrimary ? 5...400 : 1...512
                ) {
                    if secondary.sizeMode == .relativeToPrimary {
                        viewModel.setCompoundSecondaryRelativeSizeRatio(Float($0 / 100))
                    } else {
                        viewModel.setCompoundSecondarySize(Float($0))
                    }
                }

                OptimizedCompactSlider(
                    title: "间距",
                    valueText: "\(Int(secondary.spacingPercent))%",
                    value: Binding(get: { Double(secondary.spacingPercent) }, set: { _ in }),
                    range: 1...400
                ) {
                    viewModel.setCompoundSecondarySpacingPercent(Float($0))
                }

                OptimizedCompactSlider(
                    title: "角度",
                    valueText: "\(Int(secondary.angleDegrees))°",
                    value: Binding(get: { Double(secondary.angleDegrees) }, set: { _ in }),
                    range: 0...180
                ) {
                    viewModel.setCompoundSecondaryTipAngleDegrees(Float($0))
                }

                OptimizedCompactSlider(
                    title: "随机旋转",
                    valueText: "\(Int(secondary.tileRandomRotation * 100))%",
                    value: Binding(get: { Double(secondary.tileRandomRotation) }, set: { _ in }),
                    range: 0...1
                ) {
                    viewModel.setCompoundSecondaryTileRandomRotation(Float($0))
                }

                OptimizedCompactSlider(
                    title: "大小压感",
                    valueText: "\(Int(secondary.pressureSizeAmount * 100))%",
                    value: Binding(get: { Double(secondary.pressureSizeAmount) }, set: { _ in }),
                    range: 0...1
                ) {
                    viewModel.setCompoundSecondaryPressureSizeAmount(Float($0))
                }

                OptimizedCompactSlider(
                    title: "透明压感",
                    valueText: "\(Int(secondary.pressureOpacityAmount * 100))%",
                    value: Binding(get: { Double(secondary.pressureOpacityAmount) }, set: { _ in }),
                    range: 0...1
                ) {
                    viewModel.setCompoundSecondaryPressureOpacityAmount(Float($0))
                }
            }
        }
    }

    private func compoundPressureMixSection(brush: BrushSettings) -> some View {
        let mix = brush.compoundBrush.pressureMix

        return compoundCard(title: "主次迁移") {
            HStack(alignment: .top, spacing: 12) {
                CompoundPressureCurvePreview(
                    low: Double(mix.primaryAtLowPressure),
                    mid: Double(mix.primaryAtMidPressure),
                    high: Double(mix.primaryAtHighPressure)
                )
                .frame(maxWidth: .infinity, minHeight: 100, maxHeight: 100)

                VStack(alignment: .leading, spacing: 8) {
                    OptimizedCompactSlider(
                        title: "低压主占",
                        valueText: "\(Int(mix.primaryAtLowPressure * 100))%",
                        value: Binding(get: { Double(mix.primaryAtLowPressure) }, set: { _ in }),
                        range: 0...1
                    ) {
                        viewModel.setCompoundPrimaryMixAtLowPressure(Float($0))
                    }

                    OptimizedCompactSlider(
                        title: "中压主占",
                        valueText: "\(Int(mix.primaryAtMidPressure * 100))%",
                        value: Binding(get: { Double(mix.primaryAtMidPressure) }, set: { _ in }),
                        range: 0...1
                    ) {
                        viewModel.setCompoundPrimaryMixAtMidPressure(Float($0))
                    }

                    OptimizedCompactSlider(
                        title: "高压主占",
                        valueText: "\(Int(mix.primaryAtHighPressure * 100))%",
                        value: Binding(get: { Double(mix.primaryAtHighPressure) }, set: { _ in }),
                        range: 0...1
                    ) {
                        viewModel.setCompoundPrimaryMixAtHighPressure(Float($0))
                    }

                    Text("轻压更偏次笔尖，重压更偏主笔尖；最终边界始终受主笔尖包络约束。")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.62))
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private func refreshTipPreviews(for brush: BrushSettings) {
        let secondaryBrush = secondaryPreviewBrush(from: brush)
        Task.detached(priority: .utility) {
            let primaryImage = StageOneBrushPreviewRasterizer.stampImage(for: brush, resolution: 56)
            let secondaryImage = StageOneBrushPreviewRasterizer.stampImage(
                for: secondaryBrush,
                resolution: 56
            )
            await MainActor.run {
                primaryPreviewImage = primaryImage
                secondaryPreviewImage = secondaryImage
            }
        }
    }

    private func refreshStrokePreview(for brush: BrushSettings) {
        let previewPressure = self.previewPressure
        Task.detached(priority: .utility) {
            let previewImage = StageOneBrushPreviewRasterizer.compoundStrokePreviewImage(
                for: brush,
                resolution: 96,
                width: 480,
                pressure: Float(previewPressure)
            )
            await MainActor.run {
                strokePreviewImage = previewImage
            }
        }
    }

    private func scheduleInitialPreviews(for brush: BrushSettings) {
        initialPreviewTask?.cancel()
        initialPreviewTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }

            if primaryPreviewImage == nil || secondaryPreviewImage == nil {
                refreshTipPreviews(for: brush)
            }

            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }

            if strokePreviewImage == nil {
                refreshStrokePreview(for: brush)
            }
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
                    Text("共享主/次笔尖图片；选择后点击完成应用到当前槽位。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
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
                Button("完成") {
                    if let assetID = selectedPendingAssetID {
                        switch target {
                        case .primary:
                            viewModel.applyPrimaryTipImageLibraryItem(assetID)
                        case .compoundSecondary:
                            viewModel.applyCompoundSecondaryTipImageLibraryItem(assetID)
                        }
                        let updatedBrush = viewModel.workspace.toolSession.brush
                        refreshTipPreviews(for: updatedBrush)
                        refreshStrokePreview(for: updatedBrush)
                    }
                    tipLibraryTarget = nil
                }
                .buttonStyle(.borderedProminent)
            }

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 12) {
                    ForEach(items) { item in
                        Button {
                            setPendingSelection(item.id, for: target)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                ZStack(alignment: .topTrailing) {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.black)
                                        .frame(height: 96)

                                    if let image = StageOneBrushPreviewRasterizer.importedAssetImage(from: item.maskData, resolution: 96) {
                                        Image(decorative: image, scale: 1)
                                            .resizable()
                                            .interpolation(.none)
                                            .scaledToFit()
                                            .padding(10)
                                            .frame(maxWidth: .infinity, minHeight: 96, maxHeight: 96)
                                    }

                                    Button {
                                        _ = viewModel.deleteTipImageLibraryItem(item.id)
                                        if pendingSelection(for: target) == item.id {
                                            setPendingSelection(nil, for: target)
                                        }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 14))
                                            .foregroundStyle(.white.opacity(0.88), .black.opacity(0.72))
                                    }
                                    .buttonStyle(.plain)
                                    .padding(6)
                                }

                                Text(item.displayName)
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1)
                                Text("\(item.sourceInfo.pixelWidth)x\(item.sourceInfo.pixelHeight)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.white)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(selectedPendingAssetID == item.id ? Color.accentColor : Color.black.opacity(0.08), lineWidth: selectedPendingAssetID == item.id ? 2 : 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(18)
        .frame(minWidth: 860, minHeight: 620)
        .background(Color(red: 0.96, green: 0.96, blue: 0.97))
    }
}

private struct CompoundPressureCurvePreview: View {
    let low: Double
    let mid: Double
    let high: Double

    var body: some View {
        GeometryReader { proxy in
            let rect = proxy.frame(in: .local)

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.16))

                Path { path in
                    path.move(to: CGPoint(x: 10, y: rect.height - 10))
                    path.addLine(to: CGPoint(x: rect.width - 10, y: 10))
                }
                .stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                Path { path in
                    let sampleCount = 128
                    for sampleIndex in 0..<sampleCount {
                        let pressure = Double(sampleIndex) / Double(sampleCount - 1)
                        let sampled = Double(
                            BrushSettings.samplePressureCurve(
                                pressure: Float(pressure),
                                low: Float(low),
                                mid: Float(mid),
                                high: Float(high)
                            )
                        )
                        let point = CGPoint(
                            x: 10 + ((rect.width - 20) * pressure),
                            y: (rect.height - 10) - ((rect.height - 20) * sampled)
                        )
                        if sampleIndex == 0 {
                            path.move(to: point)
                        } else {
                            path.addLine(to: point)
                        }
                    }
                }
                .stroke(Color.accentColor, lineWidth: 2.5)
            }
        }
    }
}

private struct CompoundTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.84 : 0.96))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.18 : 0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            )
    }
}

private struct CompoundModeButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(
                isSelected
                    ? Color.white
                    : Color.white.opacity(configuration.isPressed ? 0.84 : 0.92)
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(configuration.isPressed ? 0.82 : 0.96)
                            : Color.white.opacity(configuration.isPressed ? 0.16 : 0.10)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.92) : Color.white.opacity(0.14),
                        lineWidth: 1
                    )
            )
    }
}

private extension CompoundBrushBuilderSheet {
    func compoundCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    func compoundImageFrame(image: CGImage?, height: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.35))

            if let image {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
            } else {
                Text("预览待生成")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
    }

    func compoundIconButton(systemImage: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(width: 30, height: 30)
        }
        .foregroundStyle(Color.white.opacity(0.94))
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.white.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .buttonStyle(.plain)
        .help(title)
    }
}

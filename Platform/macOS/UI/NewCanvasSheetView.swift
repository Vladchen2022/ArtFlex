import SwiftUI

private enum CanvasPresetOrientation: String, CaseIterable {
    case landscape
    case portrait
}

private struct CanvasPresetDefinition: Identifiable, Equatable {
    let id: String
    let title: String
    let ratio: CGSize?

    static let custom = CanvasPresetDefinition(id: "custom", title: "自定义画布", ratio: nil)
    static let oneToOne = CanvasPresetDefinition(id: "1:1", title: "1:1", ratio: CGSize(width: 1, height: 1))
    static let fourToThree = CanvasPresetDefinition(id: "4:3", title: "4:3", ratio: CGSize(width: 4, height: 3))
    static let threeToTwo = CanvasPresetDefinition(id: "3:2", title: "3:2", ratio: CGSize(width: 3, height: 2))
    static let sixteenToNine = CanvasPresetDefinition(id: "16:9", title: "16:9", ratio: CGSize(width: 16, height: 9))
    static let fiveToFour = CanvasPresetDefinition(id: "5:4", title: "5:4", ratio: CGSize(width: 5, height: 4))
    static let twoToOne = CanvasPresetDefinition(id: "2:1", title: "2:1", ratio: CGSize(width: 2, height: 1))

    static let allCases: [CanvasPresetDefinition] = [
        .custom,
        .oneToOne,
        .fourToThree,
        .threeToTwo,
        .sixteenToNine,
        .fiveToFour,
        .twoToOne
    ]
}

struct NewCanvasSheetView: View {
    private var capacityPolicy: CanvasCapacityPolicy { viewModel.canvasCapacityPolicy }
    private static let maxCanvasEdge = CanvasCapacityPolicy.standard.maximumEdge
    private static let defaultResolution = 300

    @ObservedObject var viewModel: WorkspaceViewModel

    @State private var selectedPreset = CanvasPresetDefinition.oneToOne
    @State private var orientation: CanvasPresetOrientation = .landscape
    @State private var widthText = ""
    @State private var heightText = ""
    @State private var resolutionText = "\(defaultResolution)"
    @State private var pixelFormat: ArtPixelFormat = .rgba8

    var body: some View {
        HStack(spacing: 0) {
            presetColumn

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1)
                .padding(.vertical, 34)

            infoColumn
        }
        .frame(width: 980, height: 680)
        .background(Color(red: 0.13, green: 0.13, blue: 0.14))
        .onAppear {
            applyPresetDefaults()
        }
    }

    private var presetColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("自定义与预设画布")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.9))
                .padding(.top, 28)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 20),
                GridItem(.flexible(), spacing: 20),
                GridItem(.flexible(), spacing: 20)
            ], spacing: 18) {
                ForEach(CanvasPresetDefinition.allCases) { preset in
                    presetCard(for: preset)
                }
            }

            VStack(alignment: .center, spacing: 10) {
                Text("横竖画布选择")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.72))

                HStack(spacing: 10) {
                    orientationButton(title: "横", systemImage: "rectangle", orientation: .landscape)
                    orientationButton(title: "竖", systemImage: "rectangle.portrait", orientation: .portrait)
                }
                .opacity(selectedPreset.ratio == nil ? 0.45 : 1)
            }
            .frame(maxWidth: .infinity)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 34)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var infoColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("预设信息")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.9))
                .padding(.top, 28)

            VStack(alignment: .leading, spacing: 18) {
                dimensionRow(
                    title: "宽度",
                    text: Binding(
                        get: { widthText },
                        set: { updateWidthText($0) }
                    ),
                    unit: "像素"
                )

                dimensionRow(
                    title: "高度",
                    text: Binding(
                        get: { heightText },
                        set: { updateHeightText($0) }
                    ),
                    unit: "像素"
                )

                dimensionRow(
                    title: "分辨率",
                    text: Binding(
                        get: { resolutionText },
                        set: { updateResolutionText($0) }
                    ),
                    unit: "像素/英寸"
                )
            }

            previewPanel

            Picker("颜色精度", selection: $pixelFormat) {
                Text("8 位 · 标准").tag(ArtPixelFormat.rgba8)
                Text("16 位浮点 · 柔和渐变").tag(ArtPixelFormat.rgba16Float)
            }
            .foregroundStyle(.white)
            Text(pixelFormat == .rgba16Float ? "图层像素占用约为 8 位的两倍；可导出 16 位 PNG / TIFF。" : "适合常规绘画，保持现有工程的颜色行为。")
                .font(.caption).foregroundStyle(.white.opacity(0.65))

            Spacer(minLength: 0)

            HStack {
                Spacer(minLength: 0)

                Button("取消") {
                    viewModel.dismissNewCanvasSheet()
                }
                .buttonStyle(.plain)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.86))
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color.white.opacity(0.1))
                )

                Button("创建") {
                    viewModel.createNewCanvas(
                        canvasSize: CanvasSize(width: currentWidth, height: currentHeight),
                        resolutionDPI: currentResolution,
                        pixelFormat: pixelFormat
                    )
                }
                .buttonStyle(.plain)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color.white.opacity(isValidCanvasInput ? 0.18 : 0.08))
                )
                .disabled(!isValidCanvasInput)
            }
        }
        .padding(.horizontal, 34)
        .padding(.bottom, 30)
        .frame(width: 370, alignment: .topLeading)
    }

    private func presetCard(for preset: CanvasPresetDefinition) -> some View {
        Button {
            selectedPreset = preset
            if preset.ratio != nil {
                applyPresetDefaults()
            }
        } label: {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.03))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(
                                    selectedPreset == preset ? Color.white.opacity(0.55) : Color.white.opacity(0.16),
                                    lineWidth: selectedPreset == preset ? 1.5 : 1
                                )
                        )

                    aspectPreview(for: previewRatio(for: preset), maxSize: CGSize(width: 118, height: 88))
                }
                .frame(height: 120)

                Text(preset.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.86))
            }
        }
        .buttonStyle(.plain)
    }

    private func orientationButton(title: String, systemImage: String, orientation: CanvasPresetOrientation) -> some View {
        Button {
            guard selectedPreset.ratio != nil else { return }
            self.orientation = orientation
            applyPresetDefaults()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.system(size: 14, weight: .bold))
            }
            .foregroundStyle(self.orientation == orientation ? Color.white.opacity(0.96) : Color.white.opacity(0.76))
            .frame(width: 74, height: 38)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(self.orientation == orientation ? Color.blue.opacity(0.9) : Color.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .disabled(selectedPreset.ratio == nil)
        .help(orientation == .landscape ? "横向画布" : "纵向画布")
    }

    private func dimensionRow(title: String, text: Binding<String>, unit: String) -> some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.82))
                .frame(width: 60, alignment: .leading)

            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 12)
                .frame(width: 126, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(0.14), lineWidth: 1)
                        )
                )

            Text(unit)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.6))
        }
    }

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )

                aspectPreview(
                    for: CGSize(width: CGFloat(max(currentWidth, 1)), height: CGFloat(max(currentHeight, 1))),
                    maxSize: CGSize(width: 220, height: 220)
                )
            }
            .frame(height: 246)

            let assessment = capacityPolicy.assess(
                CanvasSize(width: currentWidth, height: currentHeight)
            )
            HStack(spacing: 7) {
                Image(systemName: assessment.isSupported ? "square.grid.3x3.fill" : "exclamationmark.triangle.fill")
                Text(
                    assessment.isSupported
                        ? "分块传输 \(assessment.transferTileCount) 块 · 预计核心工作集 \(ByteCountFormatter.string(fromByteCount: Int64(assessment.estimatedCoreWorkingSetBytes), countStyle: .memory))"
                        : (assessment.rejectionReason ?? "当前尺寸不可用")
                )
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(assessment.isSupported ? Color.white.opacity(0.58) : Color.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func aspectPreview(for ratio: CGSize, maxSize: CGSize) -> some View {
        let safeRatio = CGSize(width: max(ratio.width, 1), height: max(ratio.height, 1))
        let scale = min(maxSize.width / safeRatio.width, maxSize.height / safeRatio.height)
        let size = CGSize(width: safeRatio.width * scale, height: safeRatio.height * scale)
        return RoundedRectangle(cornerRadius: 10)
            .fill(Color.white)
            .frame(width: size.width, height: size.height)
            .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 5)
    }

    private func previewRatio(for preset: CanvasPresetDefinition) -> CGSize {
        guard let ratio = preset.ratio else {
            return CGSize(width: 4, height: 5)
        }

        if orientation == .landscape {
            return ratio
        }
        return CGSize(width: ratio.height, height: ratio.width)
    }

    private func applyPresetDefaults() {
        guard let ratio = selectedPreset.ratio else {
            widthText = "\(min(currentWidth == 0 ? 2048 : currentWidth, Self.maxCanvasEdge))"
            heightText = "\(min(currentHeight == 0 ? 2048 : currentHeight, Self.maxCanvasEdge))"
            resolutionText = resolutionText.isEmpty ? "\(Self.defaultResolution)" : resolutionText
            return
        }

        let orientedRatio = orientation == .landscape
            ? ratio
            : CGSize(width: ratio.height, height: ratio.width)
        let widthRatio = max(Int(orientedRatio.width.rounded()), 1)
        let heightRatio = max(Int(orientedRatio.height.rounded()), 1)
        let size = capacityPolicy.maximumSupportedSize(
            aspectWidth: widthRatio,
            aspectHeight: heightRatio
        ) ?? CanvasSize(width: 2048, height: 2048)
        widthText = "\(size.width)"
        heightText = "\(size.height)"
        resolutionText = "\(currentResolution == 0 ? Self.defaultResolution : currentResolution)"
    }

    private func updateWidthText(_ newValue: String) {
        let filtered = numericOnly(newValue)
        widthText = filtered
        if selectedPreset.ratio == nil {
            widthText = "\(clampedDimension(from: filtered, fallback: currentWidth == 0 ? 2048 : currentWidth))"
            return
        }

        guard let ratio = activeRatio else { return }
        let width = clampedDimension(from: filtered, fallback: currentWidth == 0 ? Self.maxCanvasEdge : currentWidth)
        let height = max(1, Int((Double(width) * Double(ratio.height / ratio.width)).rounded()))
        widthText = "\(width)"
        heightText = "\(min(height, Self.maxCanvasEdge))"
    }

    private func updateHeightText(_ newValue: String) {
        let filtered = numericOnly(newValue)
        heightText = filtered
        if selectedPreset.ratio == nil {
            heightText = "\(clampedDimension(from: filtered, fallback: currentHeight == 0 ? 2048 : currentHeight))"
            return
        }

        guard let ratio = activeRatio else { return }
        let height = clampedDimension(from: filtered, fallback: currentHeight == 0 ? Self.maxCanvasEdge : currentHeight)
        let width = max(1, Int((Double(height) * Double(ratio.width / ratio.height)).rounded()))
        heightText = "\(height)"
        widthText = "\(min(width, Self.maxCanvasEdge))"
    }

    private func updateResolutionText(_ newValue: String) {
        let filtered = numericOnly(newValue)
        let resolution = max(1, Int(filtered) ?? Self.defaultResolution)
        resolutionText = "\(resolution)"
    }

    private var activeRatio: CGSize? {
        guard let ratio = selectedPreset.ratio else { return nil }
        if orientation == .landscape {
            return ratio
        }
        return CGSize(width: ratio.height, height: ratio.width)
    }

    private var currentWidth: Int {
        clampedDimension(from: widthText, fallback: 2048)
    }

    private var currentHeight: Int {
        clampedDimension(from: heightText, fallback: 2048)
    }

    private var currentResolution: Int {
        max(1, Int(resolutionText) ?? Self.defaultResolution)
    }

    private var isValidCanvasInput: Bool {
        capacityPolicy.assess(
            CanvasSize(width: currentWidth, height: currentHeight)
        ).isSupported
    }

    private func numericOnly(_ text: String) -> String {
        String(text.filter(\.isNumber))
    }

    private func clampedDimension(from text: String, fallback: Int) -> Int {
        min(max(Int(text) ?? fallback, 1), Self.maxCanvasEdge)
    }
}

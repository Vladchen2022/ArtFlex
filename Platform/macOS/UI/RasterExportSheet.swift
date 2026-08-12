import SwiftUI

struct RasterExportSheet: View {
    @ObservedObject var viewModel: WorkspaceViewModel

    @State private var format: RasterExportFormat = .png
    @State private var scope: RasterExportScope = .fullCanvas
    @State private var backgroundChoice = ExportBackgroundChoice.white
    @State private var resizeChoice = ExportResizeChoice.original
    @State private var scale = 1.0
    @State private var width = 1920
    @State private var height = 1080
    @State private var dpi = 300.0
    @State private var jpegQuality = 0.92

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("专业导出")
                .font(.title2.weight(.semibold))

            Form {
                Picker("格式", selection: $format) {
                    Text("PNG").tag(RasterExportFormat.png)
                    Text("JPEG").tag(RasterExportFormat.jpeg)
                    Text("TIFF").tag(RasterExportFormat.tiff)
                }
                .pickerStyle(.segmented)

                Picker("范围", selection: $scope) {
                    Text("完整画布").tag(RasterExportScope.fullCanvas)
                    Text("可见内容边界").tag(RasterExportScope.visibleContent)
                }

                Picker("背景", selection: $backgroundChoice) {
                    if format.supportsAlpha {
                        Text("透明").tag(ExportBackgroundChoice.transparent)
                    }
                    Text("白色").tag(ExportBackgroundChoice.white)
                    Text("当前颜色").tag(ExportBackgroundChoice.currentColor)
                }

                Picker("尺寸", selection: $resizeChoice) {
                    ForEach(ExportResizeChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }

                resizeControls

                HStack {
                    Text("DPI")
                    Spacer()
                    TextField("DPI", value: $dpi, format: .number.precision(.fractionLength(0)))
                        .frame(width: 90)
                }

                if format == .jpeg {
                    HStack {
                        Text("JPEG 质量")
                        Slider(value: $jpegQuality, in: 0.1...1)
                        Text("\(Int((jpegQuality * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(viewModel.isRasterExporting)

            Text(outputSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消") {
                    viewModel.dismissRasterExportSheet()
                }
                .disabled(viewModel.isRasterExporting)
                Button {
                    viewModel.exportRaster(options: resolvedOptions)
                } label: {
                    if viewModel.isRasterExporting {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在导出…")
                        }
                    } else {
                        Text("选择位置并导出")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(validationError != nil || viewModel.isRasterExporting)
            }
        }
        .padding(22)
        .frame(width: 510)
        .interactiveDismissDisabled(viewModel.isRasterExporting)
        .onAppear {
            width = viewModel.workspace.document.canvasSize.width
            height = viewModel.workspace.document.canvasSize.height
        }
        .onChange(of: format) { _, newFormat in
            if !newFormat.supportsAlpha, backgroundChoice == .transparent {
                backgroundChoice = .white
            }
        }
    }

    @ViewBuilder
    private var resizeControls: some View {
        switch resizeChoice {
        case .original:
            EmptyView()
        case .scale:
            HStack {
                Text("缩放")
                Slider(value: $scale, in: 0.1...4)
                Text("\(Int((scale * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
        case .width:
            integerField(title: "宽度", value: $width)
        case .height:
            integerField(title: "高度", value: $height)
        case .exact:
            HStack {
                Text("像素")
                Spacer()
                TextField("宽", value: $width, format: .number)
                    .frame(width: 84)
                Text("×")
                TextField("高", value: $height, format: .number)
                    .frame(width: 84)
            }
        }
    }

    private func integerField(title: String, value: Binding<Int>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: value, format: .number)
                .frame(width: 100)
            Text("px")
                .foregroundStyle(.secondary)
        }
    }

    private var resolvedOptions: RasterExportOptions {
        RasterExportOptions(
            format: format,
            background: resolvedBackground,
            scope: scope,
            resize: resolvedResize,
            dpi: dpi,
            jpegQuality: jpegQuality
        )
    }

    private var resolvedBackground: RasterExportBackground {
        switch backgroundChoice {
        case .transparent:
            return .transparent
        case .white:
            return .white
        case .currentColor:
            var color = viewModel.workspace.toolSession.selectedColor
            color.alpha = 1
            return .custom(color)
        }
    }

    private var resolvedResize: RasterExportResize {
        switch resizeChoice {
        case .original: .original
        case .scale: .scale(scale)
        case .width: .width(width)
        case .height: .height(height)
        case .exact: .exact(width: width, height: height)
        }
    }

    private var validationError: Error? {
        do {
            try resolvedOptions.validate()
            return nil
        } catch {
            return error
        }
    }

    private var outputSummary: String {
        do {
            let sourceWidth: Int
            let sourceHeight: Int
            if scope == .visibleContent, let bounds = viewModel.rasterExportSourceBounds {
                sourceWidth = bounds.width
                sourceHeight = bounds.height
            } else {
                sourceWidth = viewModel.workspace.document.canvasSize.width
                sourceHeight = viewModel.workspace.document.canvasSize.height
            }
            let dimensions = try resolvedOptions.outputDimensions(
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight
            )
            let suffix = scope == .visibleContent && viewModel.rasterExportSourceBounds == nil
                ? " · 正在计算可见边界"
                : ""
            return "输出 \(dimensions.width) × \(dimensions.height) px · \(Int(dpi.rounded())) DPI\(suffix)"
        } catch {
            return error.localizedDescription
        }
    }
}

private enum ExportBackgroundChoice: String, CaseIterable, Identifiable {
    case transparent
    case white
    case currentColor

    var id: String { rawValue }
}

private enum ExportResizeChoice: String, CaseIterable, Identifiable {
    case original
    case scale
    case width
    case height
    case exact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: "原始尺寸"
        case .scale: "按比例"
        case .width: "指定宽度"
        case .height: "指定高度"
        case .exact: "指定宽高"
        }
    }
}

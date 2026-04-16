import AppKit
import SwiftUI

private let patternImportMaskResolution = 256

struct PatternTransparencyBackdrop: View {
    var squareSize: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let columns = Int(ceil(size.width / squareSize))
                let rows = Int(ceil(size.height / squareSize))

                for row in 0..<rows {
                    for column in 0..<columns {
                        let rect = CGRect(
                            x: CGFloat(column) * squareSize,
                            y: CGFloat(row) * squareSize,
                            width: squareSize,
                            height: squareSize
                        )
                        let isDarkCell = ((row + column) % 2) == 0
                        context.fill(
                            Path(rect),
                            with: .color(isDarkCell ? Color.black.opacity(0.08) : Color.black.opacity(0.02))
                        )
                    }
                }
            }
        }
    }
}

struct PatternImportSheet: View {
    @ObservedObject var viewModel: WorkspaceViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                fileListColumn
                Divider()
                previewColumn
                Divider()
                settingsColumn
            }
            .padding(18)

            Divider()

            HStack(spacing: 10) {
                Button("取消") {
                    viewModel.dismissPatternImportSheet()
                }

                Spacer()

                Button("导入") {
                    viewModel.importPatternsFromSheet()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.patternImportSheetState.selectedFileURLs.isEmpty || viewModel.isPatternImporting)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 940, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var fileListColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("待导入文件")
                .font(.system(size: 13, weight: .semibold))

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(viewModel.patternImportSheetState.selectedFileURLs, id: \.self) { url in
                        patternImportFileRow(url)
                    }

                    if viewModel.patternImportSheetState.selectedFileURLs.isEmpty {
                        Text("还没有选择任何图片")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.secondary)
                            .frame(maxWidth: .infinity, minHeight: 140)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.black.opacity(0.03))
                            )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 8) {
                Button("选择文件…") {
                    viewModel.appendPatternImportFilesFromPanel()
                }
                .frame(maxWidth: .infinity)

                Button("从文件夹加入…") {
                    viewModel.appendPatternImportFolderFromPanel()
                }
                .frame(maxWidth: .infinity)

                if !viewModel.patternImportSheetState.selectedFileURLs.isEmpty {
                    Button("清空列表") {
                        viewModel.clearPatternImportFiles()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(width: 220)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func patternImportFileRow(_ url: URL) -> some View {
        let isSelected = viewModel.patternImportSheetState.previewFileURL == url

        return Button {
            viewModel.selectPatternImportPreviewFile(url)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "photo")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.secondary)

                Text(url.lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(isSelected ? 0.96 : 0.78))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.black.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.9) : Color.black.opacity(0.06),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("预览")
                .font(.system(size: 13, weight: .semibold))

            if let preview = viewModel.patternImportPreviewAsset {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        previewCard(
                            title: "原图",
                            image: preview.originalImage,
                            usesCheckerboard: false
                        )
                        processedPreviewCard(preview)
                    }

                    HStack(spacing: 12) {
                        Text("源尺寸：\(preview.sourcePixelWidth) × \(preview.sourcePixelHeight)")
                            .foregroundStyle(Color.secondary)
                        Text("处理后：\(preview.processedPixelWidth) × \(preview.processedPixelHeight)")
                            .foregroundStyle(Color.secondary)
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .overlay(alignment: .topTrailing) {
                    if viewModel.isPatternImportPreviewLoading {
                        ProgressView()
                            .controlSize(.small)
                            .padding(8)
                    }
                }
            } else if viewModel.isPatternImportPreviewLoading {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView()
                    Text("正在生成导入预览…")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Color.secondary.opacity(0.7))
                    Text("选择一张图片后，这里会显示导入前后的预览")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func processedPreviewCard(_ preview: PatternImportPreviewAsset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("导入后")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.8))

                Spacer(minLength: 8)

                Button("恢复擦除") {
                    viewModel.clearPatternImportEraseMask()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor.opacity(viewModel.patternImportCurrentEraseMaskData == nil ? 0.45 : 0.92))
                .disabled(viewModel.patternImportCurrentEraseMaskData == nil)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.04))

                if viewModel.patternImportSheetState.recipe.mode == .transparentMonochrome {
                    PatternTransparencyBackdrop(squareSize: 12)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(8)
                }

                PatternEraseEditorView(
                    previewRGBABytes: preview.processedPreviewRGBABytes,
                    pixelWidth: preview.processedPreviewPixelWidth,
                    pixelHeight: preview.processedPreviewPixelHeight,
                    maskData: viewModel.patternImportCurrentEraseMaskData
                ) { updatedMask in
                    viewModel.updatePatternImportEraseMask(updatedMask)
                }
                .padding(8)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func previewCard(
        title: String,
        image: CGImage,
        usesCheckerboard: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.8))

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.04))

                if usesCheckerboard {
                    PatternTransparencyBackdrop(squareSize: 12)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(8)
                }

                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(8)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var settingsColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导入设置")
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text("导入模式")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.secondary)

                HStack(spacing: 8) {
                    modeButton(.originalColor, title: "原图载入")
                    modeButton(.transparentMonochrome, title: "透明底黑白图")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("对比度")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                    Spacer()
                    Text("\(Int((viewModel.patternImportSheetState.recipe.contrast * 100).rounded()))%")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.secondary)
                }

                Slider(
                    value: Binding(
                        get: { Double(viewModel.patternImportSheetState.recipe.contrast) },
                        set: { viewModel.setPatternImportContrast(Float($0)) }
                    ),
                    in: -1...1
                )
                .disabled(viewModel.patternImportSheetState.recipe.mode != .transparentMonochrome)
                .opacity(viewModel.patternImportSheetState.recipe.mode == .transparentMonochrome ? 1 : 0.45)
            }

            Text("在“导入后”预览里拖拽即可用橡皮擦去不需要的区域。当前这一批文件会共用同一套导入模式和对比度设置。")
                .font(.system(size: 11))
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .frame(width: 240)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func modeButton(_ mode: PatternImportMode, title: String) -> some View {
        let isSelected = viewModel.patternImportSheetState.recipe.mode == mode

        return Button {
            viewModel.setPatternImportMode(mode)
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.76))
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected ? Color.accentColor.opacity(0.92) : Color.black.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            isSelected ? Color.accentColor.opacity(0.98) : Color.black.opacity(0.08),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

private struct PatternEraseEditorView: NSViewRepresentable {
    let previewRGBABytes: Data
    let pixelWidth: Int
    let pixelHeight: Int
    let maskData: Data?
    let onUpdateMask: (Data?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onUpdateMask: onUpdateMask)
    }

    func makeNSView(context: Context) -> PatternEraseEditorNSView {
        let view = PatternEraseEditorNSView()
        view.coordinator = context.coordinator
        view.update(
            previewRGBABytes: previewRGBABytes,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            maskData: maskData
        )
        return view
    }

    func updateNSView(_ nsView: PatternEraseEditorNSView, context: Context) {
        nsView.coordinator = context.coordinator
        nsView.update(
            previewRGBABytes: previewRGBABytes,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            maskData: maskData
        )
    }

    final class Coordinator: NSObject {
        let onUpdateMask: (Data?) -> Void

        init(onUpdateMask: @escaping (Data?) -> Void) {
            self.onUpdateMask = onUpdateMask
        }
    }
}

private final class PatternEraseEditorNSView: NSView {
    weak var coordinator: PatternEraseEditorView.Coordinator?

    private var previewRGBABytes = Data()
    private var pixelWidth = 1
    private var pixelHeight = 1
    private var maskBytes = [UInt8](repeating: 255, count: patternImportMaskResolution * patternImportMaskResolution)
    private var displayImage: CGImage?
    private var displayImageDirty = true
    private var hoverLocation: CGPoint?
    private var lastMaskPoint: CGPoint?
    private let eraserRadius: CGFloat = 14

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        previewRGBABytes: Data,
        pixelWidth: Int,
        pixelHeight: Int,
        maskData: Data?
    ) {
        let normalizedMask = Self.normalizedMaskData(maskData)
        let bytesChanged = self.previewRGBABytes != previewRGBABytes
            || self.pixelWidth != pixelWidth
            || self.pixelHeight != pixelHeight
        if bytesChanged {
            self.previewRGBABytes = previewRGBABytes
            self.pixelWidth = max(1, pixelWidth)
            self.pixelHeight = max(1, pixelHeight)
        }

        if normalizedMask != maskBytes || bytesChanged {
            maskBytes = normalizedMask
            displayImageDirty = true
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if let image = resolvedDisplayImage() {
            let drawRect = aspectFitRect(
                imageSize: CGSize(width: image.width, height: image.height),
                in: bounds
            )
            context.saveGState()
            context.translateBy(x: drawRect.minX, y: drawRect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(origin: .zero, size: drawRect.size))
            context.restoreGState()
        }

        if let hoverLocation {
            let indicatorRect = CGRect(
                x: hoverLocation.x - eraserRadius,
                y: hoverLocation.y - eraserRadius,
                width: eraserRadius * 2,
                height: eraserRadius * 2
            )
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.24).cgColor)
            context.setLineWidth(1)
            context.strokeEllipse(in: indicatorRect)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoverLocation = point
        lastMaskPoint = maskPoint(for: point)
        eraseSegment(from: lastMaskPoint ?? .zero, to: lastMaskPoint ?? .zero)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoverLocation = point
        let nextMaskPoint = maskPoint(for: point)
        eraseSegment(from: lastMaskPoint ?? nextMaskPoint, to: nextMaskPoint)
        lastMaskPoint = nextMaskPoint
    }

    override func mouseUp(with event: NSEvent) {
        hoverLocation = convert(event.locationInWindow, from: nil)
        lastMaskPoint = nil
        commitMaskUpdate()
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
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    private func resolvedDisplayImage() -> CGImage? {
        if displayImageDirty || displayImage == nil {
            displayImage = Self.makeDisplayImage(
                previewRGBABytes: previewRGBABytes,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                maskBytes: maskBytes
            )
            displayImageDirty = false
        }
        return displayImage
    }

    private func maskPoint(for viewPoint: CGPoint) -> CGPoint {
        let drawRect = aspectFitRect(
            imageSize: CGSize(width: pixelWidth, height: pixelHeight),
            in: bounds
        )
        guard drawRect.width > 0, drawRect.height > 0 else { return .zero }

        let normalizedX = min(max((viewPoint.x - drawRect.minX) / drawRect.width, 0), 1)
        let normalizedY = min(max((viewPoint.y - drawRect.minY) / drawRect.height, 0), 1)
        return CGPoint(
            x: normalizedX * CGFloat(patternImportMaskResolution - 1),
            y: normalizedY * CGFloat(patternImportMaskResolution - 1)
        )
    }

    private func eraseSegment(from start: CGPoint, to end: CGPoint) {
        let distance = hypot(end.x - start.x, end.y - start.y)
        let steps = max(1, Int(ceil(distance / 2)))
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let x = start.x + ((end.x - start.x) * t)
            let y = start.y + ((end.y - start.y) * t)
            eraseCircle(centerX: x, centerY: y)
        }
        displayImageDirty = true
        needsDisplay = true
    }

    private func eraseCircle(centerX: CGFloat, centerY: CGFloat) {
        let minX = max(0, Int(floor(centerX - eraserRadius)))
        let maxX = min(patternImportMaskResolution - 1, Int(ceil(centerX + eraserRadius)))
        let minY = max(0, Int(floor(centerY - eraserRadius)))
        let maxY = min(patternImportMaskResolution - 1, Int(ceil(centerY + eraserRadius)))
        let radiusSquared = eraserRadius * eraserRadius

        for y in minY...maxY {
            for x in minX...maxX {
                let dx = CGFloat(x) - centerX
                let dy = CGFloat(y) - centerY
                guard (dx * dx) + (dy * dy) <= radiusSquared else { continue }
                maskBytes[(y * patternImportMaskResolution) + x] = 0
            }
        }
    }

    private func commitMaskUpdate() {
        if maskBytes.allSatisfy({ $0 == 255 }) {
            coordinator?.onUpdateMask(nil)
        } else {
            coordinator?.onUpdateMask(Data(maskBytes))
        }
    }

    private func aspectFitRect(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return .zero
        }

        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: bounds.midX - (drawSize.width / 2),
            y: bounds.midY - (drawSize.height / 2),
            width: drawSize.width,
            height: drawSize.height
        )
    }

    private static func normalizedMaskData(_ data: Data?) -> [UInt8] {
        guard let data else {
            return [UInt8](repeating: 255, count: patternImportMaskResolution * patternImportMaskResolution)
        }
        let bytes = [UInt8](data)
        guard bytes.count == patternImportMaskResolution * patternImportMaskResolution else {
            return [UInt8](repeating: 255, count: patternImportMaskResolution * patternImportMaskResolution)
        }
        return bytes
    }

    private static func makeDisplayImage(
        previewRGBABytes: Data,
        pixelWidth: Int,
        pixelHeight: Int,
        maskBytes: [UInt8]
    ) -> CGImage? {
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        var rgba = [UInt8](previewRGBABytes)
        guard rgba.count == pixelWidth * pixelHeight * 4 else { return nil }

        for y in 0..<pixelHeight {
            let normalizedY = pixelHeight == 1 ? 0 : CGFloat(y) / CGFloat(pixelHeight - 1)
            let sourceY = min(
                patternImportMaskResolution - 1,
                max(0, Int((normalizedY * CGFloat(patternImportMaskResolution - 1)).rounded()))
            )
            for x in 0..<pixelWidth {
                let normalizedX = pixelWidth == 1 ? 0 : CGFloat(x) / CGFloat(pixelWidth - 1)
                let sourceX = min(
                    patternImportMaskResolution - 1,
                    max(0, Int((normalizedX * CGFloat(patternImportMaskResolution - 1)).rounded()))
                )
                let keepAlpha = Float(maskBytes[(sourceY * patternImportMaskResolution) + sourceX]) / 255
                let pixelIndex = ((y * pixelWidth) + x) * 4
                rgba[pixelIndex] = UInt8(clamping: Int((Float(rgba[pixelIndex]) * keepAlpha).rounded()))
                rgba[pixelIndex + 1] = UInt8(clamping: Int((Float(rgba[pixelIndex + 1]) * keepAlpha).rounded()))
                rgba[pixelIndex + 2] = UInt8(clamping: Int((Float(rgba[pixelIndex + 2]) * keepAlpha).rounded()))
                rgba[pixelIndex + 3] = UInt8(clamping: Int((Float(rgba[pixelIndex + 3]) * keepAlpha).rounded()))
            }
        }

        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let provider = CGDataProvider(data: Data(rgba) as CFData)
        else {
            return nil
        }

        return CGImage(
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: pixelWidth * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

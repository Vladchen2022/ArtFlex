import AppKit
import SwiftUI

enum CompoundBrushPreviewChannel: String, CaseIterable, Identifiable {
    case result = "结果"
    case primary = "A 外形"
    case secondary = "B 纹理"

    var id: String { rawValue }
}

enum CompoundBrushPreviewBackground: String, CaseIterable, Identifiable {
    case dark = "深色"
    case light = "浅色"
    case checkerboard = "棋盘"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .dark: return "moon.fill"
        case .light: return "sun.max.fill"
        case .checkerboard: return "checkerboard.rectangle"
        }
    }
}

enum CompoundBrushPreviewPath: String, CaseIterable, Identifiable {
    case straight = "直线"
    case curve = "曲线"
    case pressureRamp = "压感"
    case scribble = "涂写"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .straight: return "line.diagonal"
        case .curve: return "scribble.variable"
        case .pressureRamp: return "arrow.right"
        case .scribble: return "pencil.and.scribble"
        }
    }

    func points(resolution: Int, pressure: Float) -> [StrokePoint] {
        let size = Double(resolution)
        let fixedPressure = min(max(pressure, 0.01), 1)
        switch self {
        case .straight:
            return (0...32).map { index in
                let t = Double(index) / 32
                return StrokePoint(x: size * (0.08 + (0.84 * t)), y: size * 0.5, pressure: fixedPressure)
            }
        case .curve:
            return (0...56).map { index in
                let t = Double(index) / 56
                return StrokePoint(
                    x: size * (0.07 + (0.86 * t)),
                    y: size * (0.5 + (sin(t * .pi * 2) * 0.23)),
                    pressure: fixedPressure
                )
            }
        case .pressureRamp:
            return (0...48).map { index in
                let t = Double(index) / 48
                return StrokePoint(
                    x: size * (0.07 + (0.86 * t)),
                    y: size * 0.5,
                    pressure: Float(0.06 + (0.94 * t))
                )
            }
        case .scribble:
            return (0...88).map { index in
                let t = Double(index) / 88
                let angle = t * .pi * 4
                return StrokePoint(
                    x: size * (0.5 + (cos(angle) * (0.35 - (0.12 * t)))),
                    y: size * (0.5 + (sin(angle * 1.5) * 0.28)),
                    pressure: fixedPressure
                )
            }
        }
    }
}

enum CompoundBrushDrawingPadCoordinateMapper {
    static func rasterPoint(
        forAppKitPoint point: CGPoint,
        in bounds: CGRect,
        resolution: Int
    ) -> CGPoint {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }

        let normalizedX = min(max((point.x - bounds.minX) / bounds.width, 0), 1)
        // AppKit views use a bottom-left origin, while the brush raster stores row zero at the top.
        let normalizedY = min(max((bounds.maxY - point.y) / bounds.height, 0), 1)
        let rasterExtent = CGFloat(max(resolution - 1, 0))
        return CGPoint(x: normalizedX * rasterExtent, y: normalizedY * rasterExtent)
    }
}

struct CompoundBrushDrawingPad: NSViewRepresentable {
    let brush: BrushSettings
    let pressure: Float
    let background: CompoundBrushPreviewBackground
    let clearToken: Int
    let paintVariationSeed: UInt32
    let testPattern: CompoundBrushPreviewPath?
    let testPatternToken: Int

    func makeNSView(context: Context) -> CompoundBrushDrawingPadNSView {
        CompoundBrushDrawingPadNSView(
            brush: brush,
            pressure: pressure,
            background: background,
            clearToken: clearToken,
            paintVariationSeed: paintVariationSeed,
            testPattern: testPattern,
            testPatternToken: testPatternToken
        )
    }

    func updateNSView(_ nsView: CompoundBrushDrawingPadNSView, context: Context) {
        nsView.update(
            brush: brush,
            pressure: pressure,
            background: background,
            clearToken: clearToken,
            paintVariationSeed: paintVariationSeed,
            testPattern: testPattern,
            testPatternToken: testPatternToken
        )
    }
}

final class CompoundBrushDrawingPadNSView: NSView {
    private let resolution = 256
    private var brush: BrushSettings
    private var fixedPressure: Float
    private var previewBackground: CompoundBrushPreviewBackground
    private var clearToken: Int
    private var paintVariationSeed: UInt32
    private var testPattern: CompoundBrushPreviewPath?
    private var testPatternToken: Int
    private var strokes: [[StrokePoint]] = []
    private var activeStroke: [StrokePoint] = []
    private var activeSession: StageOneBrushPreviewRasterizer.StrokeAlphaSession?
    private var strokeBaseAlpha: [UInt8] = []
    private var activeStrokeAlpha: [UInt8]
    private var displayAlpha: [UInt8]
    private var cachedImage: CGImage?
    private var rerenderGeneration = 0

    init(
        brush: BrushSettings,
        pressure: Float,
        background: CompoundBrushPreviewBackground,
        clearToken: Int,
        paintVariationSeed: UInt32,
        testPattern: CompoundBrushPreviewPath?,
        testPatternToken: Int
    ) {
        self.brush = brush
        self.fixedPressure = pressure
        self.previewBackground = background
        self.clearToken = clearToken
        self.paintVariationSeed = paintVariationSeed
        self.testPattern = testPattern
        self.testPatternToken = testPatternToken
        self.activeStrokeAlpha = [UInt8](repeating: 0, count: 256 * 256)
        self.displayAlpha = [UInt8](repeating: 0, count: 256 * 256)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        if testPattern != nil {
            DispatchQueue.main.async { [weak self] in
                self?.loadTestPattern()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    func update(
        brush: BrushSettings,
        pressure: Float,
        background: CompoundBrushPreviewBackground,
        clearToken: Int,
        paintVariationSeed: UInt32,
        testPattern: CompoundBrushPreviewPath?,
        testPatternToken: Int
    ) {
        let clampedPressure = min(max(pressure, 0.01), 1)
        let testPatternPressureChanged = abs(fixedPressure - clampedPressure) > 0.0001
        fixedPressure = clampedPressure

        if previewBackground != background {
            previewBackground = background
            cachedImage = nil
            needsDisplay = true
        }

        if self.clearToken != clearToken {
            self.clearToken = clearToken
            clear()
        }

        var needsRerender = false
        if self.brush != brush {
            self.brush = brush
            needsRerender = true
        }
        if self.paintVariationSeed != paintVariationSeed {
            self.paintVariationSeed = paintVariationSeed
            needsRerender = true
        }
        self.testPattern = testPattern
        if self.testPatternToken != testPatternToken {
            self.testPatternToken = testPatternToken
            loadTestPattern()
            return
        }
        if testPatternPressureChanged, testPattern != nil {
            loadTestPattern()
            return
        }
        if needsRerender {
            rerenderStoredStrokes()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawBackground()

        if cachedImage == nil {
            cachedImage = makeStrokeImage()
        }
        guard let cachedImage, let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .none
        context.draw(cachedImage, in: bounds.insetBy(dx: 4, dy: 4))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = strokePoint(for: convert(event.locationInWindow, from: nil), event: event)
        activeStroke = [point]
        strokeBaseAlpha = displayAlpha
        activeStrokeAlpha = [UInt8](repeating: 0, count: resolution * resolution)
        activeSession = StageOneBrushPreviewRasterizer.makeStrokeAlphaSession(
            for: brush,
            resolution: resolution,
            paintVariationSeed: paintVariationSeed
        )
        if let update = activeSession?.append(points: [point, point]) {
            mergeActiveStroke(update)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = strokePoint(for: convert(event.locationInWindow, from: nil), event: event)
        guard let previous = activeStroke.last else { return }
        let dx = point.x - previous.x
        let dy = point.y - previous.y
        guard (dx * dx) + (dy * dy) >= 0.25 else { return }
        activeStroke.append(point)
        if let update = activeSession?.append(points: [previous, point]) {
            mergeActiveStroke(update)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if activeStroke.count == 1, let onlyPoint = activeStroke.first {
            activeStroke.append(onlyPoint)
        }
        if let update = activeSession?.finish() {
            mergeActiveStroke(update)
        }
        if activeStroke.isEmpty == false {
            strokes.append(activeStroke)
        }
        activeStroke = []
        activeSession = nil
        strokeBaseAlpha = []
        activeStrokeAlpha = [UInt8](repeating: 0, count: resolution * resolution)
    }

    private func clear() {
        rerenderGeneration &+= 1
        strokes.removeAll(keepingCapacity: true)
        activeStroke.removeAll(keepingCapacity: true)
        activeSession = nil
        strokeBaseAlpha.removeAll(keepingCapacity: true)
        activeStrokeAlpha = [UInt8](repeating: 0, count: resolution * resolution)
        displayAlpha = [UInt8](repeating: 0, count: resolution * resolution)
        invalidateStrokeImage()
    }

    private func loadTestPattern() {
        rerenderGeneration &+= 1
        activeStroke.removeAll(keepingCapacity: true)
        activeSession = nil
        strokeBaseAlpha.removeAll(keepingCapacity: true)
        activeStrokeAlpha = [UInt8](repeating: 0, count: resolution * resolution)
        displayAlpha = [UInt8](repeating: 0, count: resolution * resolution)
        if let testPattern {
            strokes = [testPattern.points(resolution: resolution, pressure: fixedPressure)]
            rerenderStoredStrokes()
        } else {
            strokes.removeAll(keepingCapacity: true)
            invalidateStrokeImage()
        }
    }

    private func rerenderStoredStrokes() {
        rerenderGeneration &+= 1
        let generation = rerenderGeneration
        let brush = brush
        let strokes = strokes
        let paintVariationSeed = paintVariationSeed
        guard strokes.isEmpty == false else {
            displayAlpha = [UInt8](repeating: 0, count: resolution * resolution)
            invalidateStrokeImage()
            return
        }

        Task { @MainActor [weak self] in
            let rendered = await Task.detached(priority: .utility) {
                var canvas = [UInt8](repeating: 0, count: 256 * 256)
                for stroke in strokes {
                    var samplingState: BrushStrokeSamplingState?
                    guard let alpha = StageOneBrushPreviewRasterizer.strokeAlphaBytes(
                        for: brush,
                        resolution: 256,
                        points: stroke,
                        samplingState: &samplingState,
                        paintVariationSeed: paintVariationSeed,
                        flushPendingSamples: true
                    ) else { continue }
                    canvas = Self.composited(base: canvas, stroke: alpha, buildMode: brush.buildMode)
                }
                return canvas
            }.value

            guard let self, generation == rerenderGeneration else { return }
            displayAlpha = rendered
            invalidateStrokeImage()
        }
    }

    private func mergeActiveStroke(_ update: StageOneBrushPreviewRasterizer.StrokeAlphaUpdate) {
        let bounds = update.bounds
        guard
            bounds.originX >= 0,
            bounds.originY >= 0,
            bounds.originX + bounds.width <= resolution,
            bounds.originY + bounds.height <= resolution,
            update.alphaBytes.count == bounds.width * bounds.height
        else { return }

        for localY in 0..<bounds.height {
            let sourceStart = localY * bounds.width
            let destinationStart = ((bounds.originY + localY) * resolution) + bounds.originX
            activeStrokeAlpha.replaceSubrange(
                destinationStart..<(destinationStart + bounds.width),
                with: update.alphaBytes[sourceStart..<(sourceStart + bounds.width)]
            )
        }

        let base = strokeBaseAlpha.count == displayAlpha.count ? strokeBaseAlpha : displayAlpha
        displayAlpha = Self.composited(base: base, stroke: activeStrokeAlpha, buildMode: brush.buildMode)
        invalidateStrokeImage()
    }

    nonisolated private static func composited(
        base: [UInt8],
        stroke: [UInt8],
        buildMode: BrushBuildMode
    ) -> [UInt8] {
        guard base.count == stroke.count else { return base }
        var result = base
        for index in result.indices {
            // A completed stroke always composites over earlier strokes.
            // The opacity ceiling applies only within that stroke's session.
            let source = Int(stroke[index])
            let destination = Int(base[index])
            result[index] = UInt8(clamping: source + ((destination * (255 - source) + 127) / 255))
        }
        return result
    }

    private func invalidateStrokeImage() {
        cachedImage = nil
        needsDisplay = true
    }

    private func strokePoint(for point: CGPoint, event: NSEvent) -> StrokePoint {
        let rasterPoint = CompoundBrushDrawingPadCoordinateMapper.rasterPoint(
            forAppKitPoint: point,
            in: bounds,
            resolution: resolution
        )
        let eventPressure = event.pressure
        let isTabletPressureEvent = event.type == .tabletPoint
            || event.type == .pressure
            || event.subtype == .tabletPoint
        let pressure = isTabletPressureEvent && eventPressure > 0.01
            ? eventPressure
            : fixedPressure
        return StrokePoint(
            x: Double(rasterPoint.x),
            y: Double(rasterPoint.y),
            pressure: pressure
        )
    }

    private func drawBackground() {
        switch previewBackground {
        case .dark:
            NSColor(calibratedWhite: 0.055, alpha: 1).setFill()
            bounds.fill()
        case .light:
            NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
            bounds.fill()
        case .checkerboard:
            NSColor(calibratedWhite: 0.18, alpha: 1).setFill()
            bounds.fill()
            let cell: CGFloat = 12
            NSColor(calibratedWhite: 0.27, alpha: 1).setFill()
            var y: CGFloat = 0
            var row = 0
            while y < bounds.height {
                var x: CGFloat = row.isMultiple(of: 2) ? 0 : cell
                while x < bounds.width {
                    NSRect(x: x, y: y, width: cell, height: cell).fill()
                    x += cell * 2
                }
                y += cell
                row += 1
            }
        }
    }

    private func makeStrokeImage() -> CGImage? {
        let drawsDarkStroke = previewBackground == .light
        var rgba = [UInt8](repeating: 0, count: resolution * resolution * 4)
        for index in displayAlpha.indices {
            let color: UInt8 = drawsDarkStroke ? 18 : 245
            let alpha = displayAlpha[index]
            let premultipliedColor = UInt8((Int(color) * Int(alpha) + 127) / 255)
            rgba[(index * 4)] = premultipliedColor
            rgba[(index * 4) + 1] = premultipliedColor
            rgba[(index * 4) + 2] = premultipliedColor
            rgba[(index * 4) + 3] = alpha
        }
        guard
            let provider = CGDataProvider(data: Data(rgba) as CFData),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }

        return CGImage(
            width: resolution,
            height: resolution,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: resolution * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

struct CompoundPressureMixCurveEditor: View {
    let mix: CompoundPressureMixSettings
    let mode: CompoundBrushMode
    let onChange: (CompoundPressureMixSettings) -> Void

    var body: some View {
        GeometryReader { proxy in
            let plot = proxy.frame(in: .local).insetBy(dx: 18, dy: 18)
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.black.opacity(0.22))

                Path { path in
                    for division in 0...4 {
                        let x = plot.minX + (plot.width * CGFloat(division) / 4)
                        path.move(to: CGPoint(x: x, y: plot.minY))
                        path.addLine(to: CGPoint(x: x, y: plot.maxY))
                        let y = plot.minY + (plot.height * CGFloat(division) / 4)
                        path.move(to: CGPoint(x: plot.minX, y: y))
                        path.addLine(to: CGPoint(x: plot.maxX, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.07), lineWidth: 1)

                Path { path in
                    let points = controlPoints(in: plot)
                    path.move(to: points[0])
                    path.addLine(to: points[1])
                    path.addLine(to: points[2])
                }
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))

                ForEach(0..<3, id: \.self) { index in
                    let point = controlPoints(in: plot)[index]
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                        .frame(width: 14, height: 14)
                        .position(point)
                        .contentShape(Circle().inset(by: -8))
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { drag in
                                    updatePoint(index, y: drag.location.y, plot: plot)
                                }
                        )
                        .help(["轻压", "中压", "重压"][index])
                }

                VStack {
                    HStack {
                        Text(mode == .overlay ? "叠加" : "A")
                        Spacer()
                        Text("拖动白点")
                    }
                    Spacer()
                    HStack {
                        Text("B")
                        Spacer()
                        Text("轻压 → 重压")
                    }
                }
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.38))
                .padding(7)
                .allowsHitTesting(false)
            }
        }
    }

    private func controlPoints(in rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.maxY - (rect.height * CGFloat(mix.primaryAtLowPressure))),
            CGPoint(x: rect.midX, y: rect.maxY - (rect.height * CGFloat(mix.primaryAtMidPressure))),
            CGPoint(x: rect.maxX, y: rect.maxY - (rect.height * CGFloat(mix.primaryAtHighPressure)))
        ]
    }

    private func updatePoint(_ index: Int, y: CGFloat, plot: CGRect) {
        let weight = Float(min(max((plot.maxY - y) / max(plot.height, 1), 0), 1))
        var updated = mix
        switch index {
        case 0: updated.primaryAtLowPressure = weight
        case 1: updated.primaryAtMidPressure = weight
        default: updated.primaryAtHighPressure = weight
        }
        onChange(updated)
    }
}

/// Presents the A/B pressure mix in artist-facing terms: the vertical axis is
/// B's share, while the complementary share is painted by A.
struct CompoundTextureStrengthCurveEditor: View {
    let mix: CompoundPressureMixSettings
    let onChange: (CompoundPressureMixSettings) -> Void
    let onEditingChanged: (Bool) -> Void

    @State private var isDragging = false
    @State private var activeControlPoint: Int?

    var body: some View {
        GeometryReader { proxy in
            let plot = proxy.frame(in: .local).insetBy(dx: 20, dy: 20)
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.black.opacity(0.24))

                Path { path in
                    for division in 0...4 {
                        let x = plot.minX + (plot.width * CGFloat(division) / 4)
                        path.move(to: CGPoint(x: x, y: plot.minY))
                        path.addLine(to: CGPoint(x: x, y: plot.maxY))
                        let y = plot.minY + (plot.height * CGFloat(division) / 4)
                        path.move(to: CGPoint(x: plot.minX, y: y))
                        path.addLine(to: CGPoint(x: plot.maxX, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.065), lineWidth: 1)

                Path { path in
                    let points = controlPoints(in: plot)
                    path.move(to: points[0])
                    path.addLine(to: points[1])
                    path.addLine(to: points[2])
                }
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))

                ForEach(0..<3, id: \.self) { index in
                    let point = controlPoints(in: plot)[index]
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                        .frame(width: 15, height: 15)
                        .position(point)
                        .help(["轻压时 B 的比例", "中压时 B 的比例", "重压时 B 的比例"][index])
                }

                VStack {
                    HStack {
                        Text("B 强 / A 弱")
                        Spacer()
                        Text("拖动白点")
                    }
                    Spacer()
                    HStack {
                        Text("B 弱 / A 强")
                        Spacer()
                        Text("轻压 → 重压")
                    }
                }
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.4))
                .padding(8)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { drag in
                        if isDragging == false {
                            isDragging = true
                            activeControlPoint = CompoundPressureMixCurveInteraction.nearestControlPoint(
                                toX: drag.location.x,
                                in: plot
                            )
                            onEditingChanged(true)
                        }
                        guard let activeControlPoint else { return }
                        updatePoint(activeControlPoint, y: drag.location.y, plot: plot)
                    }
                    .onEnded { drag in
                        let index = activeControlPoint ?? CompoundPressureMixCurveInteraction.nearestControlPoint(
                            toX: drag.location.x,
                            in: plot
                        )
                        updatePoint(index, y: drag.location.y, plot: plot)
                        activeControlPoint = nil
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
        }
    }

    private func textureStrengths() -> [Float] {
        [
            1 - min(max(mix.primaryAtLowPressure, 0), 1),
            1 - min(max(mix.primaryAtMidPressure, 0), 1),
            1 - min(max(mix.primaryAtHighPressure, 0), 1)
        ]
    }

    private func controlPoints(in rect: CGRect) -> [CGPoint] {
        let strengths = textureStrengths()
        return [
            CGPoint(x: rect.minX, y: rect.maxY - (rect.height * CGFloat(strengths[0]))),
            CGPoint(x: rect.midX, y: rect.maxY - (rect.height * CGFloat(strengths[1]))),
            CGPoint(x: rect.maxX, y: rect.maxY - (rect.height * CGFloat(strengths[2])))
        ]
    }

    private func updatePoint(_ index: Int, y: CGFloat, plot: CGRect) {
        let strength = CompoundPressureMixCurveInteraction.secondaryStrength(
            atY: y,
            in: plot
        )
        let primaryWeight = 1 - strength
        var updated = mix
        switch index {
        case 0: updated.primaryAtLowPressure = primaryWeight
        case 1: updated.primaryAtMidPressure = primaryWeight
        default: updated.primaryAtHighPressure = primaryWeight
        }
        onChange(updated)
    }
}

enum CompoundPressureMixCurveInteraction {
    static func nearestControlPoint(toX x: CGFloat, in plot: CGRect) -> Int {
        let candidates = [plot.minX, plot.midX, plot.maxX]
        return candidates.enumerated().min { lhs, rhs in
            abs(lhs.element - x) < abs(rhs.element - x)
        }?.offset ?? 1
    }

    static func secondaryStrength(atY y: CGFloat, in plot: CGRect) -> Float {
        Float(min(max((plot.maxY - y) / max(plot.height, 1), 0), 1))
    }
}

enum CompoundEditorSliderScale {
    case linear
    case logarithmic
}

struct CompoundEditorSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let scale: CompoundEditorSliderScale
    let valueText: (Double) -> String
    let onPreview: (Double) -> Void
    let onCommit: (Double) -> Void
    let onEditingChanged: (Bool) -> Void

    @State private var draftValue: Double
    @State private var text: String
    @State private var isSliding = false
    @FocusState private var isTextFocused: Bool

    init(
        title: String,
        value: Double,
        range: ClosedRange<Double>,
        scale: CompoundEditorSliderScale = .linear,
        valueText: @escaping (Double) -> String,
        onPreview: @escaping (Double) -> Void = { _ in },
        onCommit: @escaping (Double) -> Void,
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.title = title
        self.value = value
        self.range = range
        self.scale = scale
        self.valueText = valueText
        self.onPreview = onPreview
        self.onCommit = onCommit
        self.onEditingChanged = onEditingChanged
        _draftValue = State(initialValue: min(max(value, range.lowerBound), range.upperBound))
        _text = State(initialValue: valueText(value))
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.82))
                .frame(width: 92, alignment: .leading)

            Slider(
                value: Binding(
                    get: { sliderPosition(for: draftValue) },
                    set: { position in
                        let updated = resolvedValue(for: position)
                        draftValue = updated
                        onPreview(updated)
                    }
                ),
                in: sliderRange,
                onEditingChanged: { editing in
                    isSliding = editing
                    if editing {
                        onEditingChanged(true)
                    } else {
                        commit(draftValue)
                        onEditingChanged(false)
                    }
                }
            )
            .controlSize(.small)
            .onChange(of: draftValue) { _, updated in
                if isTextFocused == false {
                    text = valueText(updated)
                }
            }

            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.96))
                .multilineTextAlignment(.trailing)
                .frame(width: 68, height: 22)
                .padding(.horizontal, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.black.opacity(isTextFocused ? 0.32 : 0.18))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(
                            isTextFocused ? Color.accentColor.opacity(0.75) : Color.white.opacity(0.08),
                            lineWidth: 1
                        )
                )
                .focused($isTextFocused)
                .onSubmit {
                    commitText()
                    isTextFocused = false
                }
                .onChange(of: isTextFocused) { wasFocused, isFocused in
                    if wasFocused == false, isFocused {
                        onEditingChanged(true)
                    }
                    if wasFocused, isFocused == false {
                        commitText()
                        onEditingChanged(false)
                    }
                }
        }
        .onChange(of: value) { _, updated in
            guard isSliding == false, isTextFocused == false else { return }
            draftValue = min(max(updated, range.lowerBound), range.upperBound)
            text = valueText(draftValue)
        }
    }

    private var sliderRange: ClosedRange<Double> {
        scale == .linear ? range : 0...1
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

    private func sliderPosition(for actualValue: Double) -> Double {
        let clamped = min(max(actualValue, range.lowerBound), range.upperBound)
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

    private func commitText() {
        guard let parsed = parsedValue(from: text) else {
            text = valueText(draftValue)
            return
        }
        let clamped = min(max(parsed, range.lowerBound), range.upperBound)
        draftValue = clamped
        commit(clamped)
    }

    private func commit(_ newValue: Double) {
        let clamped = min(max(newValue, range.lowerBound), range.upperBound)
        draftValue = clamped
        text = valueText(clamped)
        onCommit(clamped)
    }

    private func parsedValue(from source: String) -> Double? {
        let normalized = source.replacingOccurrences(of: ",", with: ".")
        guard let range = normalized.range(
            of: #"[-+]?(?:\d+(?:\.\d*)?|\.\d+)"#,
            options: .regularExpression
        ), let number = Double(normalized[range]) else {
            return nil
        }
        if valueText(value).contains("%"), self.range.upperBound <= 1.0001 {
            return number / 100
        }
        return number
    }
}

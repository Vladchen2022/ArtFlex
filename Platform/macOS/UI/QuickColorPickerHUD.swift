import SwiftUI

func quickColorPickerCanUseSteppedSlider(
    range: ClosedRange<Double>,
    step: Double
) -> Bool {
    guard step.isFinite, step > 0 else {
        return false
    }
    guard range.lowerBound.isFinite, range.upperBound.isFinite else {
        return false
    }
    return range.upperBound > range.lowerBound
}

struct QuickColorPickerHUD: View {
    let state: QuickColorPickerState
    let presentation: CanvasPresentation
    let canvasSize: CanvasSize
    let viewportRotationDegrees: Double
    let isCanvasHorizontallyFlipped: Bool
    let viewportSize: CGSize
    let brushSlots: [BrushPreset?]
    let selectedBrushPresetID: String?
    let onSetPoint: (Float, Float) -> Void
    let onSetHue: (Float) -> Void
    let onSelectBrushSlot: (Int) -> Void
    let onSetRecentBrushSelectionCount: (Int) -> Void
    let onSetRecentBrushOpacity: (Float) -> Void
    let onSetRecentBrushBrightness: (Float) -> Void
    let onSetRecentBrushSaturation: (Float) -> Void
    let onSetRecentBrushSelectionEditing: (Bool) -> Void
    let onSetRecentBrushOpacityEditing: (Bool) -> Void

    @State private var previewPanel: ColorPanelState?

    private var hudSize: CGSize {
        let baseHeight = (hudPadding * 2) + 18 + 8 + squareSize.height
        let selectionSliderHeight: CGFloat = state.recentBrushSelectionLimit > 0 ? 28 : 0
        let adjustmentSliderCount: CGFloat = state.recentBrushSelectionLimit > 0 ? 3 : 0
        let adjustmentSliderHeight: CGFloat = adjustmentSliderCount * 28
        return CGSize(
            width: 198,
            height: baseHeight + selectionSliderHeight + adjustmentSliderHeight
        )
    }
    private let squareSize = CGSize(width: 144, height: 144)
    private let hueStripWidth: CGFloat = 16
    private let hudPadding: CGFloat = 10
    private let viewportInset: CGFloat = 12

    var body: some View {
        let anchor = viewportPoint(for: state.anchorPoint)
        let center = clampedCenter(near: anchor)
        let displayedPanel = previewPanel ?? state.panel

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { slotIndex in
                    let slotPreset = brushSlots[safe: slotIndex] ?? nil
                    QuickColorPickerBrushSlotDot(
                        slotIndex: slotIndex,
                        preset: slotPreset,
                        isSelected: selectedBrushPresetID == slotPreset?.id,
                        onSelect: {
                            onSelectBrushSlot(slotIndex)
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .top, spacing: 10) {
                QuickColorPickerSVSquare(
                    panel: displayedPanel,
                    onSetPoint: updatePreviewPoint
                )
                .frame(width: squareSize.width, height: squareSize.height)

                QuickColorPickerHueStrip(
                    hue: displayedPanel.pickerHue,
                    onSetHue: updatePreviewHue
                )
                .frame(width: hueStripWidth, height: squareSize.height)
            }

            if state.recentBrushSelectionLimit > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    QuickColorPickerMiniSliderRow(
                        title: "最近",
                        valueLabel: "\(state.recentBrushSelectionCount)",
                        value: Double(state.recentBrushSelectionCount),
                        range: 1...Double(max(1, state.recentBrushSelectionLimit)),
                        step: 1,
                        isReversed: true,
                        onEditingChanged: onSetRecentBrushSelectionEditing
                    ) { value in
                        onSetRecentBrushSelectionCount(Int(value.rounded()))
                    }

                    QuickColorPickerMiniSliderRow(
                        title: "透明度",
                        valueLabel: "\(Int((state.recentBrushOpacity * 100).rounded()))%",
                        value: Double(state.recentBrushOpacity),
                        range: 0...1,
                        step: 0.01,
                        onEditingChanged: onSetRecentBrushOpacityEditing
                    ) { value in
                        onSetRecentBrushOpacity(Float(value))
                    }

                    QuickColorPickerMiniSliderRow(
                        title: "明度",
                        valueLabel: signedPercentLabel(for: state.recentBrushBrightness),
                        value: Double(state.recentBrushBrightness),
                        range: -1...1,
                        step: 0.01,
                        onEditingChanged: onSetRecentBrushOpacityEditing
                    ) { value in
                        onSetRecentBrushBrightness(Float(value))
                    }

                    QuickColorPickerMiniSliderRow(
                        title: "饱和",
                        valueLabel: signedPercentLabel(for: state.recentBrushSaturation),
                        value: Double(state.recentBrushSaturation),
                        range: -1...1,
                        step: 0.01,
                        onEditingChanged: onSetRecentBrushOpacityEditing
                    ) { value in
                        onSetRecentBrushSaturation(Float(value))
                    }
                }
            }
        }
        .padding(hudPadding)
        .background(Color.clear)
        .frame(width: hudSize.width, height: hudSize.height)
        .position(x: center.x, y: center.y)
    }

    private func viewportPoint(for point: CanvasPoint) -> CGPoint {
        let scaleX = presentation.documentDisplaySize.x / Double(canvasSize.width)
        let scaleY = presentation.documentDisplaySize.y / Double(canvasSize.height)
        let localX = point.x * scaleX
        let localY = point.y * scaleY
        let centerX = presentation.documentDisplaySize.x / 2
        let centerY = presentation.documentDisplaySize.y / 2
        let translatedX = (localX - centerX) * presentation.documentZoomScale
        let translatedY = (localY - centerY) * presentation.documentZoomScale
        let mirroredX = isCanvasHorizontallyFlipped ? -translatedX : translatedX
        let radians = viewportRotationDegrees * .pi / 180
        let rotatedX = (mirroredX * cos(radians)) - (translatedY * sin(radians))
        let rotatedY = (mirroredX * sin(radians)) + (translatedY * cos(radians))

        return CGPoint(
            x: presentation.documentOrigin.x + centerX + rotatedX,
            y: presentation.documentOrigin.y + centerY + rotatedY
        )
    }

    private func clampedCenter(near anchor: CGPoint) -> CGPoint {
        let halfWidth = hudSize.width / 2
        let halfHeight = hudSize.height / 2
        let minX = halfWidth + viewportInset
        let maxX = max(viewportSize.width - halfWidth - viewportInset, minX)
        let minY = halfHeight + viewportInset
        let maxY = max(viewportSize.height - halfHeight - viewportInset, minY)
        let adjustedX = min(max(anchor.x, minX), maxX)
        let adjustedY = min(max(anchor.y, minY), maxY)
        return CGPoint(x: adjustedX, y: adjustedY)
    }

    private func swiftUIColor(from color: RGBAColor) -> Color {
        Color(
            red: Double(color.red),
            green: Double(color.green),
            blue: Double(color.blue),
            opacity: Double(color.alpha)
        )
    }

    private func signedPercentLabel(for value: Float) -> String {
        let percent = Int((value * 100).rounded())
        return percent > 0 ? "+\(percent)" : "\(percent)"
    }

    private func updatePreviewPoint(_ x: Float, _ y: Float) {
        var panel = previewPanel ?? state.panel
        panel.pickerX = min(max(x, 0), 1)
        panel.pickerY = min(max(y, 0), 1)
        previewPanel = panel
        onSetPoint(panel.pickerX, panel.pickerY)
    }

    private func updatePreviewHue(_ hue: Float) {
        var panel = previewPanel ?? state.panel
        panel.pickerHue = ColorBlocksEngine.wrapHue(hue)
        previewPanel = panel
        onSetHue(panel.pickerHue)
    }
}

private struct QuickColorPickerMiniSliderRow: View {
    let title: String
    let valueLabel: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let isReversed: Bool
    let onEditingChanged: (Bool) -> Void
    let onChange: (Double) -> Void

    init(
        title: String,
        valueLabel: String,
        value: Double,
        range: ClosedRange<Double>,
        step: Double,
        isReversed: Bool = false,
        onEditingChanged: @escaping (Bool) -> Void,
        onChange: @escaping (Double) -> Void
    ) {
        self.title = title
        self.valueLabel = valueLabel
        self.value = value
        self.range = range
        self.step = step
        self.isReversed = isReversed
        self.onEditingChanged = onEditingChanged
        self.onChange = onChange
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.78))
                .frame(width: 32, alignment: .leading)
            if quickColorPickerCanUseSteppedSlider(range: range, step: step) {
                Slider(
                    value: Binding(
                        get: { displayedValue },
                        set: { onChange(resolvedValue(fromDisplayedValue: $0)) }
                    ),
                    in: range,
                    step: step,
                    onEditingChanged: onEditingChanged
                )
                .tint(Color.accentColor)
                .controlSize(.mini)
            } else {
                Capsule()
                    .fill(Color.white.opacity(0.16))
                    .frame(height: 4)
                    .overlay {
                        Capsule()
                            .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    }
                    .padding(.horizontal, 2)
                    .accessibilityHidden(true)
            }

            Text(valueLabel)
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.92))
                .frame(width: 34, alignment: .trailing)
        }
    }

    private var displayedValue: Double {
        guard isReversed else {
            return value
        }
        return range.upperBound - (value - range.lowerBound)
    }

    private func resolvedValue(fromDisplayedValue displayedValue: Double) -> Double {
        guard isReversed else {
            return displayedValue
        }
        return range.upperBound - (displayedValue - range.lowerBound)
    }
}

private struct QuickColorPickerBrushSlotDot: View {
    let slotIndex: Int
    let preset: BrushPreset?
    let isSelected: Bool
    let onSelect: () -> Void

    private let dotSize: CGFloat = 14

    var body: some View {
        Button(action: onSelect) {
            Circle()
                .fill(dotFillColor)
                .overlay {
                    Circle()
                        .strokeBorder(dotStrokeColor, lineWidth: 1.2)
                }
                .frame(width: dotSize, height: dotSize)
        }
        .buttonStyle(.plain)
        .disabled(preset == nil)
        .opacity(preset == nil ? 0.32 : 1)
        .help("快捷画笔 \(slotIndex + 1)")
    }

    private var dotFillColor: Color {
        guard preset != nil else {
            return Color.white.opacity(0.08)
        }
        return isSelected ? Color.accentColor.opacity(0.92) : Color.white.opacity(0.88)
    }

    private var dotStrokeColor: Color {
        guard preset != nil else {
            return Color.black.opacity(0.18)
        }
        return Color.black.opacity(isSelected ? 0.84 : 0.72)
    }
}

private struct QuickColorPickerSVSquare: View {
    let panel: ColorPanelState
    let onSetPoint: (Float, Float) -> Void

    @State private var localX: Float = 0
    @State private var localY: Float = 0
    @State private var isDragging = false
    @State private var displayImage: CGImage?

    var body: some View {
        let displayX = isDragging ? localX : panel.pickerX
        let displayY = isDragging ? localY : panel.pickerY

        GeometryReader { geometry in
            let size = max(64, Int(min(geometry.size.width, geometry.size.height) * 2))
            ZStack(alignment: .topLeading) {
                if let displayImage {
                    Image(decorative: displayImage, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.clear)
                }

                Circle()
                    .strokeBorder(Color.white, lineWidth: 2)
                    .background(Circle().fill(Color.black.opacity(0.18)))
                    .frame(width: 16, height: 16)
                    .position(
                        x: CGFloat(displayX) * geometry.size.width,
                        y: CGFloat(displayY) * geometry.size.height
                    )
                    .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let resolvedX = Float(min(max(value.location.x / geometry.size.width, 0), 1))
                        let resolvedY = Float(min(max(value.location.y / geometry.size.height, 0), 1))
                        isDragging = true
                        localX = resolvedX
                        localY = resolvedY
                        onSetPoint(resolvedX, resolvedY)
                    }
                    .onEnded { value in
                        let resolvedX = Float(min(max(value.location.x / geometry.size.width, 0), 1))
                        let resolvedY = Float(min(max(value.location.y / geometry.size.height, 0), 1))
                        onSetPoint(resolvedX, resolvedY)
                        isDragging = false
                    }
            )
            .task(id: QuickColorPickerSVImageKey(size: size, panel: panel)) {
                await updateDisplayImage(size: size, panel: panel)
            }
        }
    }

    @MainActor
    private func updateDisplayImage(size: Int, panel: ColorPanelState) async {
        let renderTask = Task.detached(priority: .userInitiated) {
            makeColorPickerSVImage(size: size, panel: panel) {
                Task.isCancelled
            }
        }
        let image = await withTaskCancellationHandler {
            await renderTask.value
        } onCancel: {
            renderTask.cancel()
        }
        guard !Task.isCancelled, let image else { return }
        displayImage = image
    }
}

private struct QuickColorPickerSVImageKey: Hashable, Sendable {
    let size: Int
    let hue: Int
    let lightness: Int
    let saturation: Int
    let lightingHue: Int
    let lightingStrength: Int

    init(size: Int, panel: ColorPanelState) {
        self.size = size
        hue = Int(panel.pickerHue.rounded())
        lightness = Int(panel.pickerLightness.rounded())
        saturation = Int(panel.pickerSaturation.rounded())
        lightingHue = Int(panel.lightingHue.rounded())
        lightingStrength = Int(panel.lightingStrength.rounded())
    }
}

private struct QuickColorPickerHueStrip: View {
    let hue: Float
    let onSetHue: (Float) -> Void

    @State private var localHue: Float = 0
    @State private var isDragging = false

    private var gradientStops: [Gradient.Stop] {
        let stopCount = 25
        return (0..<stopCount).map { index in
            let t = Double(index) / Double(max(stopCount - 1, 1))
            let hsv = HSVColor(h: Float(t * 360.0), s: 1, v: 1)
            let rgb = ColorBlocksEngine.hsvToRgb(hsv)
            return Gradient.Stop(
                color: Color(
                    red: Double(rgb.red),
                    green: Double(rgb.green),
                    blue: Double(rgb.blue),
                    opacity: 1
                ),
                location: t
            )
        }
    }

    var body: some View {
        let displayHue = isDragging ? localHue : hue

        GeometryReader { geometry in
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(stops: gradientStops),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                Capsule()
                    .strokeBorder(Color.white, lineWidth: 2)
                    .background(Capsule().fill(Color.black.opacity(0.18)))
                    .frame(width: geometry.size.width + 6, height: 8)
                    .position(
                        x: geometry.size.width / 2,
                        y: CGFloat(min(max(displayHue / 360, 0), 1)) * geometry.size.height
                    )
                    .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let normalizedY = min(max(value.location.y / geometry.size.height, 0), 1)
                        let newHue = Float(normalizedY) * 360
                        isDragging = true
                        localHue = newHue
                        onSetHue(newHue)
                    }
                    .onEnded { value in
                        let normalizedY = min(max(value.location.y / geometry.size.height, 0), 1)
                        onSetHue(Float(normalizedY) * 360)
                        isDragging = false
                    }
            )
        }
    }
}

private struct QuickColorPickerBrushStrokePreview: View {
    let brush: BrushSettings

    var body: some View {
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
            let primaryStampResolution = quickColorPickerPreviewRasterResolution(
                for: baseWidth,
                minimum: 32,
                maximum: 56,
                scale: 1.2
            )
            let primaryStampPreviewImage = quickColorPickerBestEffortStampPreviewImage(
                for: brush,
                resolution: primaryStampResolution
            )

            for index in 0..<stampCount {
                let t = stampCount == 1 ? 0.0 : Double(index) / Double(stampCount - 1)
                let pressure = quickColorPickerPreviewStrokePressure(at: t)
                let pressureMetrics = quickColorPickerPreviewBrushStrokeMetrics(for: brush, pressure: pressure)
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
                    ) * scatter * 2.2
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
                let stampWidth = max(3, baseWidth * sizeScale * pressureMetrics.sizeFactor)
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
}

private struct QuickColorPickerBrushGlyph: View {
    let brush: BrushSettings

    var body: some View {
        let normalizedSize = min(max(Double(brush.size) / 64.0, 0.22), 1.0)
        let baseExtent = 16.0 + (4.0 * normalizedSize)
        let stampResolution = quickColorPickerPreviewRasterResolution(
            for: baseExtent,
            minimum: 24,
            maximum: 40,
            scale: 1.6
        )
        let previewImage = quickColorPickerBestEffortStampPreviewImage(
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
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.10))
                    .frame(width: baseExtent, height: baseExtent)
            }
        }
    }
}

private func quickColorPickerPreviewStrokePressure(at progress: Double) -> Double {
    let clamped = min(max(progress, 0), 1)
    let eased = clamped * clamped * (3 - (2 * clamped))
    return 0.04 + (0.32 * eased)
}

private func quickColorPickerPreviewBrushStrokeMetrics(
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
    let curvedSizePressure = quickColorPickerPreviewSizeCurvePressure(sizePressure, brush: brush)
    let lowerBound = min(max(Double(brush.sizeLowerBound), 0), 1)
    let lowerBoundedPressure = lowerBound + ((1 - lowerBound) * curvedSizePressure)
    let rawSizeFactor = (1 - sizeResponse) + (sizeResponse * lowerBoundedPressure)
    let curvedOpacityPressure = quickColorPickerPreviewOpacityCurvePressure(opacityPressure, brush: brush)
    let rawOpacityFactor = Double(
        BrushSettings.resolvedPressureFactor(
            responseAmount: Float(opacityResponse),
            curvedPressure: Float(curvedOpacityPressure)
        )
    )
    let sizeFactor = rawSizeFactor * 0.72
    let targetVisibleOpacity = Float(brush.opacity) * Float(rawOpacityFactor)
    let spacingPx = max(Float(Double(brush.size) * Double(brush.spacingPercent) / 100.0), 0.5)
    let stampDiameterPx = max(Float(brush.size) * Float(rawSizeFactor), 1)
    let compensationAmount = BrushSettings.resolvedBuildUpCompensationAmount(
        automaticCompensationAmount: Float(opacityResponse),
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
    let resolvedOpacity = min(max(Double(visibleOpacity) * 0.52, 0.05), 0.72)
    return (max(sizeFactor, 0.05), resolvedOpacity)
}

private func quickColorPickerPreviewPressureResponsePressure(
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

private func quickColorPickerPreviewSizeCurvePressure(
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

private func quickColorPickerPreviewOpacityCurvePressure(
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

private func quickColorPickerPreviewRasterResolution(
    for displayExtent: Double,
    minimum: Int,
    maximum: Int,
    scale: Double
) -> Int {
    let proposed = Int(ceil(max(displayExtent, 1) * scale))
    return min(max(proposed, minimum), maximum)
}

private func quickColorPickerCompactPreviewFallbackResolution(for resolution: Int) -> Int? {
    let fallback = max(20, min(resolution / 2, 32))
    return fallback < resolution ? fallback : nil
}

private func quickColorPickerBestEffortStampPreviewImage(
    for brush: BrushSettings,
    resolution: Int
) -> CGImage? {
    if let image = StageOneBrushPreviewRasterizer.stampImage(
        for: brush,
        resolution: resolution
    ) {
        return image
    }

    guard let fallbackResolution = quickColorPickerCompactPreviewFallbackResolution(for: resolution) else {
        return nil
    }

    return StageOneBrushPreviewRasterizer.stampImage(
        for: brush,
        resolution: fallbackResolution
    )
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else {
            return nil
        }
        return self[index]
    }
}

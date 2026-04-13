import SwiftUI

struct QuickColorPickerHUD: View {
    let state: QuickColorPickerState
    let presentation: CanvasPresentation
    let canvasSize: CanvasSize
    let viewportRotationDegrees: Double
    let viewportSize: CGSize
    let brushSlots: [BrushPreset?]
    let selectedBrushPresetID: String?
    let onSetPoint: (Float, Float) -> Void
    let onSetHue: (Float) -> Void
    let onSelectBrushSlot: (Int) -> Void

    private let hudSize = CGSize(width: 198, height: 226)
    private let squareSize = CGSize(width: 144, height: 144)
    private let hueStripWidth: CGFloat = 16
    private let hudPadding: CGFloat = 10
    private let viewportInset: CGFloat = 12

    var body: some View {
        let anchor = viewportPoint(for: state.anchorPoint)
        let center = clampedCenter(near: anchor)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                QuickColorPickerSVSquare(
                    panel: state.panel,
                    onSetPoint: onSetPoint
                )
                .frame(width: squareSize.width, height: squareSize.height)

                QuickColorPickerHueStrip(
                    hue: state.panel.pickerHue,
                    onSetHue: onSetHue
                )
                .frame(width: hueStripWidth, height: squareSize.height)
            }

            HStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { slotIndex in
                    let slotPreset = brushSlots[safe: slotIndex] ?? nil
                    QuickColorPickerBrushSlotCell(
                        slotIndex: slotIndex,
                        preset: slotPreset,
                        isSelected: selectedBrushPresetID == slotPreset?.id,
                        onSelect: {
                            onSelectBrushSlot(slotIndex)
                        }
                    )
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
        let radians = viewportRotationDegrees * .pi / 180
        let rotatedX = (translatedX * cos(radians)) - (translatedY * sin(radians))
        let rotatedY = (translatedX * sin(radians)) + (translatedY * cos(radians))

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
}

private struct QuickColorPickerBrushSlotCell: View {
    let slotIndex: Int
    let preset: BrushPreset?
    let isSelected: Bool
    let onSelect: () -> Void

    private let cellSize: CGFloat = 40

    var body: some View {
        Button(action: onSelect) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.black.opacity(0.75))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(
                                isSelected ? Color.accentColor.opacity(0.92) : Color.white.opacity(0.08),
                                lineWidth: isSelected ? 1.4 : 1
                            )
                    }

                if let preset {
                    ZStack(alignment: .bottomTrailing) {
                        QuickColorPickerBrushStrokePreview(brush: preset.brush)
                            .frame(width: cellSize * 0.72, height: cellSize * 0.72)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(.leading, cellSize * 0.10)
                            .padding(.top, cellSize * 0.08)

                        QuickColorPickerBrushGlyph(brush: preset.brush)
                            .frame(width: cellSize * 0.22, height: cellSize * 0.22)
                            .padding(.trailing, cellSize * 0.09)
                            .padding(.bottom, cellSize * 0.08)
                    }
                }

                Text("\(slotIndex + 1)")
                    .font(.system(size: 8, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.accentColor.opacity(0.95))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.leading, 6)
                    .padding(.bottom, 5)
            }
            .frame(width: cellSize, height: cellSize)
        }
        .buttonStyle(.plain)
        .disabled(preset == nil)
        .opacity(preset == nil ? 0.72 : 1)
    }
}

private struct QuickColorPickerSVSquare: View {
    let panel: ColorPanelState
    let onSetPoint: (Float, Float) -> Void

    @State private var localX: Float = 0
    @State private var localY: Float = 0
    @State private var isDragging = false

    var body: some View {
        let topLeft = colorAt(x: 0, y: 0)
        let topRight = colorAt(x: 1, y: 0)
        let bottomLeft = colorAt(x: 0, y: 1)
        let bottomRight = colorAt(x: 1, y: 1)
        let displayX = isDragging ? localX : panel.pickerX
        let displayY = isDragging ? localY : panel.pickerY

        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [topLeft, bottomLeft],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [topRight, bottomRight],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .mask(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.clear, Color.white],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    )

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
        }
    }

    private func colorAt(x: Float, y: Float) -> Color {
        var updated = panel
        updated.pickerX = x
        updated.pickerY = y
        let color = ColorBlocksEngine.pickerColor(from: updated)
        return Color(
            red: Double(color.red),
            green: Double(color.green),
            blue: Double(color.blue),
            opacity: Double(color.alpha)
        )
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
    let low = min(max(Double(brush.sizeCurveLow), 0), 0.85)
    let mid = min(max(Double(brush.sizeCurveMid), low), 0.95)
    let high = min(max(Double(brush.sizeCurveHigh), mid), 1)
    return quickColorPickerPreviewSamplePiecewiseCurve(
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

private func quickColorPickerPreviewOpacityCurvePressure(
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

private func quickColorPickerPreviewSamplePiecewiseCurve(
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

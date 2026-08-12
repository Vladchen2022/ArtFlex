import AppKit
import SwiftUI

struct GradientStopsEditor: View {
    let settings: GradientSettings
    let followsCurrentColor: Bool
    let onAdd: () -> Void
    let onUpdate: (UUID, Float?, RGBAColor?) -> Void
    let onRemove: (UUID) -> Void
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("颜色节点")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.76))
                Spacer()
                Text("\(settings.stops.count)/8")
                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.46))
                Button("添加") { onAdd() }
                    .disabled(settings.stops.count >= GradientSettings.maximumStopCount)
                Button("当前色渐隐") { onReset() }
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)

            RoundedRectangle(cornerRadius: 5)
                .fill(
                    LinearGradient(
                        gradient: Gradient(stops: settings.stops.map { stop in
                            Gradient.Stop(
                                color: swiftUIColor(stop.color),
                                location: CGFloat(stop.position)
                            )
                        }),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 18)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )

            if followsCurrentColor {
                Text("首节点跟随当前颜色；编辑后转为独立渐变")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.46))
            }

            ForEach(settings.stops) { stop in
                HStack(spacing: 7) {
                    ColorPicker(
                        "",
                        selection: colorBinding(for: stop),
                        supportsOpacity: true
                    )
                    .labelsHidden()
                    .frame(width: 26)

                    Slider(
                        value: positionBinding(for: stop),
                        in: 0...1
                    )

                    Text("\(Int((stop.position * 100).rounded()))%")
                        .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.white.opacity(0.68))
                        .frame(width: 34, alignment: .trailing)

                    Button {
                        onRemove(stop.id)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .disabled(settings.stops.count <= GradientSettings.minimumStopCount)
                    .opacity(settings.stops.count <= GradientSettings.minimumStopCount ? 0.3 : 0.8)
                }
            }
        }
        .padding(8)
        .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
    }

    private func positionBinding(for stop: GradientStop) -> Binding<Double> {
        Binding(
            get: { Double(stop.position) },
            set: { onUpdate(stop.id, Float($0), nil) }
        )
    }

    private func colorBinding(for stop: GradientStop) -> Binding<Color> {
        Binding(
            get: { swiftUIColor(stop.color) },
            set: { newColor in
                guard let srgb = NSColor(newColor).usingColorSpace(.sRGB) else { return }
                onUpdate(
                    stop.id,
                    nil,
                    RGBAColor(
                        red: Float(srgb.redComponent),
                        green: Float(srgb.greenComponent),
                        blue: Float(srgb.blueComponent),
                        alpha: Float(srgb.alphaComponent)
                    )
                )
            }
        )
    }

    private func swiftUIColor(_ color: RGBAColor) -> Color {
        Color(
            red: Double(color.red),
            green: Double(color.green),
            blue: Double(color.blue),
            opacity: Double(color.alpha)
        )
    }
}

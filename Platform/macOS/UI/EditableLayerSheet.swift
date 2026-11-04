import SwiftUI

struct EditableLayerSheet: View {
    @ObservedObject var draft: EditableLayerDraft
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("编辑\(draft.content.displayName)").font(.headline)
            HStack(alignment: .top, spacing: 22) {
                ZStack {
                    Color.white
                    if let image = draft.preview {
                        Image(decorative: image, scale: 1).resizable().scaledToFit()
                    }
                    if draft.isComputing { ProgressView() }
                }.frame(width: 360, height: 360).border(.gray.opacity(0.4))
                Form {
                    switch draft.content.operation {
                    case .image:
                        number("水平位移", imageBinding(\.translation.x), range: -32768...32768)
                        number("垂直位移", imageBinding(\.translation.y), range: -32768...32768)
                        number("水平比例", imageBinding(\.scaleX), range: -100...100)
                        number("垂直比例", imageBinding(\.scaleY), range: -100...100)
                        number("旋转角度", imageBinding(\.rotationDegrees), range: -360...360)
                        Button("还原原始图像") { draft.content.operation = .image(.init()) }
                    case .texture(let fill):
                        floatSlider("纹理大小", textureBinding(\.scale), range: 0.1...8)
                        floatSlider("覆盖", textureBinding(\.coverage), range: 0...1)
                        floatSlider("变化", textureBinding(\.variation), range: 0...1)
                        floatSlider("旋转", textureBinding(\.angle), range: -.pi...Float.pi)
                        ColorPicker("填充颜色", selection: textureColor)
                        Picker("排列", selection: Binding(get: { fill.arrangement }, set: { value in
                            if case .texture(var fill) = draft.content.operation { fill.arrangement = value; draft.content.operation = .texture(fill) }
                        })) {
                            ForEach(TextureFillArrangement.allCases, id: \.self) { value in Text(value.displayName).tag(value) }
                        }
                        Button("变换随机种子") {
                            if case .texture(var fill) = draft.content.operation { fill.seed &+= 1; draft.content.operation = .texture(fill) }
                        }
                    case .gradient(let fill):
                        Text("色标").font(.subheadline)
                        ForEach(fill.settings.stops) { stop in
                            HStack {
                                ColorPicker("颜色", selection: gradientColor(stop.id)).labelsHidden()
                                Slider(value: gradientStopPosition(stop.id), in: 0...1)
                            }
                        }
                        Button("反转渐变") {
                            if case .gradient(var fill) = draft.content.operation {
                                fill.settings = GradientSettings(stops: fill.settings.stops.map { .init(id: $0.id, position: 1 - $0.position, color: $0.color) })
                                draft.content.operation = .gradient(fill)
                            }
                        }
                    }
                }.frame(width: 280)
            }
            Text("原始素材随工程保存；每次修改均从原始素材重新生成。应用可撤销，取消不改动画布。")
                .font(.caption).foregroundStyle(.secondary)
            if let error = draft.error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { draft.cancel(); close() }.keyboardShortcut(.cancelAction)
                Button("应用") { if draft.apply() { close() } }.disabled(!draft.canApply).keyboardShortcut(.defaultAction)
            }
        }.padding(24).onDisappear { draft.cancel() }
    }

    private func number(_ title: String, _ binding: Binding<Double>, range: ClosedRange<Double>) -> some View {
        TextField(title, value: Binding(get: { binding.wrappedValue }, set: { binding.wrappedValue = min(max($0, range.lowerBound), range.upperBound) }), format: .number)
    }
    private func floatSlider(_ title: String, _ binding: Binding<Float>, range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading) { Text(title); Slider(value: binding, in: range) }
    }
    private func imageBinding(_ path: WritableKeyPath<EditableImagePlacement, Double>) -> Binding<Double> {
        Binding(get: { if case .image(let value) = draft.content.operation { return value[keyPath: path] }; return 0 }, set: { value in
            if case .image(var placement) = draft.content.operation { placement[keyPath: path] = value; draft.content.operation = .image(placement) }
        })
    }
    private func textureBinding(_ path: WritableKeyPath<EditableTextureFill, Float>) -> Binding<Float> {
        Binding(get: { if case .texture(let value) = draft.content.operation { return value[keyPath: path] }; return 0 }, set: { value in
            if case .texture(var fill) = draft.content.operation { fill[keyPath: path] = value; draft.content.operation = .texture(fill) }
        })
    }
    private func color(_ rgba: RGBAColor) -> Color { Color(.sRGB, red: Double(rgba.red), green: Double(rgba.green), blue: Double(rgba.blue), opacity: Double(rgba.alpha)) }
    private func rgba(_ color: Color) -> RGBAColor {
        let value = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return .init(red: Float(value.redComponent), green: Float(value.greenComponent), blue: Float(value.blueComponent), alpha: Float(value.alphaComponent))
    }
    private var textureColor: Binding<Color> {
        Binding(get: { if case .texture(let fill) = draft.content.operation { return color(fill.color) }; return .black }, set: { value in
            if case .texture(var fill) = draft.content.operation { fill.color = rgba(value); draft.content.operation = .texture(fill) }
        })
    }
    private func gradientColor(_ id: UUID) -> Binding<Color> {
        Binding(get: { if case .gradient(let fill) = draft.content.operation, let stop = fill.settings.stops.first(where: { $0.id == id }) { return color(stop.color) }; return .black }, set: { value in
            if case .gradient(var fill) = draft.content.operation { fill.settings.updateStop(id: id, color: rgba(value)); draft.content.operation = .gradient(fill) }
        })
    }
    private func gradientStopPosition(_ id: UUID) -> Binding<Float> {
        Binding(get: { if case .gradient(let fill) = draft.content.operation { return fill.settings.stops.first(where: { $0.id == id })?.position ?? 0 }; return 0 }, set: { value in
            if case .gradient(var fill) = draft.content.operation { fill.settings.updateStop(id: id, position: value); draft.content.operation = .gradient(fill) }
        })
    }
}

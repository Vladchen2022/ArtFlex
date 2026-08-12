import SwiftUI

struct PreciseTransformPanel: View {
    let input: PreciseAffineInput
    let onUpdate: (PreciseAffineInput) -> Void

    @State private var draft: PreciseAffineInput

    init(input: PreciseAffineInput, onUpdate: @escaping (PreciseAffineInput) -> Void) {
        self.input = input
        self.onUpdate = onUpdate
        _draft = State(initialValue: input)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("数值变形")
                .font(.system(size: 13, weight: .bold))

            HStack(spacing: 8) {
                numericField("中心 X", value: $draft.centerX)
                numericField("中心 Y", value: $draft.centerY)
            }
            HStack(spacing: 8) {
                numericField("宽度", value: widthBinding)
                numericField("高度", value: heightBinding)
            }
            HStack(spacing: 8) {
                numericField("旋转", value: $draft.rotationDegrees, suffix: "°")
                Toggle("锁定比例", isOn: $draft.locksAspectRatio)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 10.5, weight: .semibold))
            }

            HStack(spacing: 7) {
                Toggle("水平翻转", isOn: $draft.isHorizontallyFlipped)
                Toggle("垂直翻转", isOn: $draft.isVerticallyFlipped)
            }
            .toggleStyle(.button)
            .controlSize(.small)

            HStack {
                Spacer()
                Button("同步当前值") {
                    draft = input
                }
                Button("更新预览") {
                    onUpdate(draft)
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!draft.hasValidFiniteGeometry)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 330)
        .onChange(of: input) { _, newValue in
            guard !fieldsAreFocused else { return }
            draft = newValue
        }
    }

    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case centerX, centerY, width, height, rotation }

    private var fieldsAreFocused: Bool { focusedField != nil }

    private var sourceAspectRatio: Double {
        guard input.height > 0 else { return 1 }
        return input.width / input.height
    }

    private var widthBinding: Binding<Double> {
        Binding(
            get: { draft.width },
            set: { draft.updateWidth($0, sourceAspectRatio: sourceAspectRatio) }
        )
    }

    private var heightBinding: Binding<Double> {
        Binding(
            get: { draft.height },
            set: { draft.updateHeight($0, sourceAspectRatio: sourceAspectRatio) }
        )
    }

    private func numericField(
        _ title: String,
        value: Binding<Double>,
        suffix: String = "px"
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Color.secondary)
            HStack(spacing: 3) {
                TextField(title, value: value, format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                Text(suffix)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Color.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

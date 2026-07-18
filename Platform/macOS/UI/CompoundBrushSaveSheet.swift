import SwiftUI

struct CompoundBrushSaveSheet: View {
    let brush: BrushSettings
    let library: BrushLibraryState
    let onSave: (String, BrushColorTag?, String?, Bool) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var selectedColorTag: BrushColorTag?
    @State private var replacesCurrent: Bool
    @State private var allowsDuplicate = false

    private let replaceCandidate: BrushPreset?

    init(
        brush: BrushSettings,
        library: BrushLibraryState,
        onSave: @escaping (String, BrushColorTag?, String?, Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.brush = brush
        self.library = library
        self.onSave = onSave
        self.onCancel = onCancel
        let selected = library.selectedPresetID.flatMap { library.preset(id: $0) }
        let candidate = selected?.isBuiltIn == false ? selected : nil
        replaceCandidate = candidate
        let nextIndex = library.presets.filter { !$0.isBuiltIn }.count + 1
        _name = State(initialValue: candidate?.name ?? "组合笔刷 \(nextIndex)")
        _selectedColorTag = State(initialValue: candidate?.colorTag)
        _replacesCurrent = State(initialValue: candidate != nil)
    }

    private var duplicatePreset: BrushPreset? {
        library.presets.first {
            !$0.isBuiltIn && $0.brush == brush
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var willSelectExisting: Bool {
        replacesCurrent == false && duplicatePreset != nil && allowsDuplicate == false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("保存组合笔刷")
                    .font(.system(size: 17, weight: .bold))
                Text("命名并保存到画笔库；替换会保留原来的库位置。")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("名称")
                    .font(.system(size: 11, weight: .semibold))
                TextField("组合笔刷名称", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("颜色标记")
                    .font(.system(size: 11, weight: .semibold))
                HStack(spacing: 9) {
                    colorTagButton(nil, color: Color.white.opacity(0.22), label: "无")
                    ForEach(BrushColorTag.allCases, id: \.self) { tag in
                        colorTagButton(tag, color: tag.color, label: tag.displayName)
                    }
                }
            }

            if let replaceCandidate {
                Toggle("替换当前预设“\(replaceCandidate.name)”", isOn: $replacesCurrent)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 11, weight: .semibold))
            }

            if replacesCurrent == false, let duplicatePreset {
                VStack(alignment: .leading, spacing: 7) {
                    Label("画笔参数与“\(duplicatePreset.name)”完全相同。", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                    Toggle("仍保存一个副本", isOn: $allowsDuplicate)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .font(.system(size: 10, weight: .medium))
                }
                .padding(10)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(willSelectExisting ? "使用已有笔刷" : (replacesCurrent ? "替换" : "新建")) {
                    onSave(
                        trimmedName,
                        selectedColorTag,
                        replacesCurrent ? replaceCandidate?.id : nil,
                        allowsDuplicate
                    )
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty && willSelectExisting == false)
            }
        }
        .padding(20)
        .frame(width: 470)
    }

    private func colorTagButton(
        _ tag: BrushColorTag?,
        color: Color,
        label: String
    ) -> some View {
        Button {
            selectedColorTag = tag
        } label: {
            Circle()
                .fill(color)
                .frame(width: 20, height: 20)
                .overlay(
                    Circle().stroke(selectedColorTag == tag ? Color.accentColor : Color.white.opacity(0.16), lineWidth: 2)
                )
                .overlay {
                    if selectedColorTag == tag {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(label)
    }
}

private extension BrushColorTag {
    var displayName: String {
        switch self {
        case .red: return "红"
        case .orange: return "橙"
        case .yellow: return "黄"
        case .green: return "绿"
        case .cyan: return "青"
        case .blue: return "蓝"
        case .purple: return "紫"
        }
    }

    var color: Color {
        switch self {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .cyan: return .cyan
        case .blue: return .blue
        case .purple: return .purple
        }
    }
}

import SwiftUI

struct SettingsSheetView: View {
    @ObservedObject var settings: AppShortcutSettingsStore
    let onClose: () -> Void

    private let toolShortcutColumns = [
        GridItem(.flexible(minimum: 250, maximum: 330), spacing: 10),
        GridItem(.flexible(minimum: 250, maximum: 330), spacing: 10)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    settingsSection(
                        title: "快捷键",
                        subtitle: "可调整工具栏、HUD 拾色器和仿真油画笔快捷键。"
                    ) {
                        HStack(alignment: .top, spacing: 14) {
                            shortcutCard(
                                title: "工具栏快捷键",
                                description: "左侧工具栏当前已有的快捷键都可以在这里改。Shift + 该键仍然用于轮换组内工具。"
                            ) {
                                LazyVGrid(columns: toolShortcutColumns, alignment: .leading, spacing: 10) {
                                    ForEach(settings.configurableToolGroups, id: \.id) { group in
                                        ToolShortcutEditorRow(
                                            title: groupShortcutTitle(group),
                                            shortcutKey: settings.shortcutDisplayTitle(for: group)
                                        ) { key in
                                            settings.setShortcutKey(key, for: group)
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)

                            VStack(alignment: .leading, spacing: 12) {
                                shortcutCard(
                                    title: "HUD 拾色器",
                                    description: "按住快捷键弹出 HUD 拾色器，松开主按键或必需修饰键后确认颜色。"
                                ) {
                                    ShortcutEditorRow(
                                        shortcut: Binding(
                                            get: { settings.quickColorPickerShortcut },
                                            set: {
                                                settings.quickColorPickerShortcut = $0
                                                settings.persist()
                                            }
                                        )
                                    )
                                }

                                shortcutCard(
                                    title: "仿真油画笔",
                                    description: "沾色把当前候选色加入笔头；洗笔清除旧色，只保留当前候选色。"
                                ) {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text("沾色")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(Color.white.opacity(0.72))
                                        ShortcutEditorRow(
                                            shortcut: Binding(
                                                get: { settings.oilPaintLoadShortcut },
                                                set: {
                                                    settings.oilPaintLoadShortcut = $0
                                                    settings.persist()
                                                }
                                            )
                                        )

                                        Divider().overlay(Color.white.opacity(0.08))

                                        Text("洗笔")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(Color.white.opacity(0.72))
                                        ShortcutEditorRow(
                                            shortcut: Binding(
                                                get: { settings.oilPaintWashShortcut },
                                                set: {
                                                    settings.oilPaintWashShortcut = $0
                                                    settings.persist()
                                                }
                                            )
                                        )
                                    }
                                }

                                shortcutHintCard
                            }
                            .frame(width: 264, alignment: .topLeading)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 20)
            }
        }
        .frame(width: 920, height: 620, alignment: .topLeading)
        .background(Color(red: 0.12, green: 0.12, blue: 0.13))
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("设置")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.96))
                Text("当前先提供快捷键设置，后续可继续扩展。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.58))
            }

            Spacer(minLength: 0)

            Button("完成") {
                onClose()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.92))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.92))
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Color.white.opacity(0.04))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
    }

    private var shortcutHintCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("说明")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.9))

            Text("工具组快捷键会自动保持唯一；如果你把某一组改成别人正在使用的键，系统会自动交换这两个分配。")
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private func settingsSection<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.94))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.58))
            }

            content()
        }
    }

    private func shortcutCard<Content: View>(
        title: String,
        description: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.92))
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private func groupShortcutTitle(_ group: ToolSidebarGroup) -> String {
        if group.tools.count == 1 {
            return group.defaultTool.displayName
        }
        return group.tools.map(\.displayName).joined(separator: " / ")
    }
}

private struct ShortcutEditorRow: View {
    @Binding var shortcut: AppKeyboardShortcut

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                modifierChip("Cmd", isOn: shortcut.usesCommand) {
                    shortcut.usesCommand.toggle()
                }
                modifierChip("Shift", isOn: shortcut.usesShift) {
                    shortcut.usesShift.toggle()
                }
                modifierChip("Option", isOn: shortcut.usesOption) {
                    shortcut.usesOption.toggle()
                }
                modifierChip("Control", isOn: shortcut.usesControl) {
                    shortcut.usesControl.toggle()
                }
            }

            HStack(spacing: 10) {
                Text("主按键")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.74))

                Picker("主按键", selection: Binding(
                    get: { shortcut.normalizedKey },
                    set: { shortcut.key = $0 }
                )) {
                    ForEach(AppShortcutSettingsStore.availableShortcutKeys, id: \.self) { key in
                        Text(key).tag(key)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 88)

                Spacer(minLength: 0)

                Text("当前：\(shortcut.displayString)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.88))
            }
        }
    }

    private func modifierChip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(isOn ? 0.98 : 0.72))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isOn ? Color.accentColor.opacity(0.92) : Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isOn ? Color.accentColor.opacity(0.95) : Color.white.opacity(0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct ToolShortcutEditorRow: View {
    let title: String
    let shortcutKey: String
    let onCommit: (String) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.84))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                ForEach(AppShortcutSettingsStore.availableShortcutKeys, id: \.self) { key in
                    Button(key) {
                        onCommit(key)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(shortcutKey)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.92))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
                .padding(.horizontal, 10)
                .frame(width: 76, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.04))
        )
    }
}

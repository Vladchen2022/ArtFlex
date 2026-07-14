import SwiftUI

private let sidebarButtonLabelFontSize: CGFloat = 11
private let sidebarButtonWidth: CGFloat = 132
private let sidebarButtonHeight: CGFloat = 34
private let sidebarButtonCornerRadius: CGFloat = 9
private let sidebarButtonHorizontalPadding: CGFloat = 10
private let sidebarButtonContentSpacing: CGFloat = 6
private let sidebarButtonLeadingIconWidth: CGFloat = 13
private let sidebarButtonTrailingGap: CGFloat = 4
private let sidebarButtonIconFontSize: CGFloat = 11
private let sidebarUtilityButtonSpacing: CGFloat = 8
private let snapshotCountBadgeTrailingPadding: CGFloat = 8
private let snapshotCountBadgeReservedWidth: CGFloat = 28

struct ToolSidebarView: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    @ObservedObject var hostViewModel: WorkspaceViewModel
    @State private var showsSnapshotPopover = false
    @State private var suppressSnapshotPrimaryAction = false
    @State private var showsDrawingStatsPopover = false
    @State private var showsRecorderPopover = false
    @State private var recorderExportFPS = 12.0

    private let groupEntries: [ToolSidebarEntry] = [
        .group("brush"),
        .group("eraser"),
        .group("eyedropper"),
        .group("bucket"),
        .group("selection-l"),
        .group("lasso-fill"),
        .group("selection-m"),
        .group("straight-line"),
        .group("gradient-j"),
        .group("smudge"),
        .group("color-adjust"),
        .group("canvas-rotate"),
        .group("canvas-crop"),
        .group("free-transform"),
        .group("perspective")
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(groupEntries) { entry in
                        switch entry.kind {
                        case .divider:
                            Rectangle()
                                .fill(Color.white.opacity(0.08))
                                .frame(width: 104, height: 1)
                                .padding(.vertical, 8)
                        case .group(let groupID):
                            if let group = ToolSidebarGroup.orderedGroups.first(where: { $0.id == groupID }) {
                                ToolSidebarGroupButton(
                                    group: group,
                                    shortcutSettings: hostViewModel.shortcutSettings,
                                    displayedTool: viewModel.sidebarDisplayedTool(for: group),
                                    isSelected: viewModel.isSelected(group: group),
                                    activateGroup: { viewModel.activateSidebarGroup(group) },
                                    activateTool: { tool in viewModel.selectToolFromUI(tool) }
                                )
                            }
                        }
                    }
                }
                .disabled(hostViewModel.snapshotCompareSession != nil)
            }

            VStack(spacing: sidebarUtilityButtonSpacing) {
                snapshotButton
                ideationButton
                drawingStatsButton
                recorderButton
            }
            .padding(.vertical, 8)
        }
        .padding(.top, 10)
        .padding(.horizontal, 8)
        .frame(width: 152)
        .frame(maxHeight: .infinity)
        .background(Color(red: 0.13, green: 0.13, blue: 0.14))
    }

    private var snapshotButton: some View {
        Button {
            if suppressSnapshotPrimaryAction {
                suppressSnapshotPrimaryAction = false
                return
            }
            showsDrawingStatsPopover = false
            showsRecorderPopover = false
            hostViewModel.requestSnapshotSavePrimaryAction()
        } label: {
            HStack(spacing: sidebarButtonContentSpacing) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: sidebarButtonIconFontSize, weight: .semibold))
                    .frame(width: sidebarButtonLeadingIconWidth)
                    .foregroundStyle(Color.white.opacity(0.9))

                Text("快照保存")
                    .font(.system(size: sidebarButtonLabelFontSize, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(1)
                    .layoutPriority(1)
                    .foregroundStyle(Color.white.opacity(0.9))

                Spacer(minLength: 0)
            }
            .padding(.leading, sidebarButtonHorizontalPadding)
            .padding(
                .trailing,
                sidebarButtonHorizontalPadding + snapshotCountBadgeReservedWidth + sidebarButtonTrailingGap
            )
            .frame(width: sidebarButtonWidth, height: sidebarButtonHeight)
            .background(
                RoundedRectangle(cornerRadius: sidebarButtonCornerRadius)
                    .fill(
                        hostViewModel.snapshotCompareSession == nil
                            ? Color.white.opacity(0.08)
                            : Color.accentColor.opacity(0.22)
                    )
            )
            .overlay(alignment: .trailing) {
                Text("\(hostViewModel.savedSnapshotCount)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(hostViewModel.savedSnapshotCount == 0 ? 0.48 : 0.92))
                    .frame(minWidth: 10)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .fixedSize(horizontal: true, vertical: true)
                    .background(
                        Capsule()
                            .fill(
                                hostViewModel.snapshotCompareSession == nil
                                    ? Color.white.opacity(0.12)
                                    : Color.white.opacity(0.18)
                            )
                    )
                    .padding(.trailing, snapshotCountBadgeTrailingPadding)
            }
        }
        .buttonStyle(.plain)
        .help(snapshotButtonHelpText)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.35)
                .onEnded { _ in
                    guard hostViewModel.ideationSession == nil else { return }
                    guard hostViewModel.snapshotCompareSession == nil else { return }
                    suppressSnapshotPrimaryAction = true
                    showsDrawingStatsPopover = false
                    showsRecorderPopover = false
                    showsSnapshotPopover = true
                }
        )
        .popover(isPresented: $showsSnapshotPopover, arrowEdge: .leading) {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    showsSnapshotPopover = false
                    hostViewModel.requestOpenSnapshotCompare()
                } label: {
                    HStack {
                        Text("快照对比")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer(minLength: 10)
                        Text("\(hostViewModel.savedSnapshotCount)/6")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.65))
                    }
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 10)
                    .frame(width: 188, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)
                .disabled(hostViewModel.savedSnapshotCount == 0)

                Button {
                    showsSnapshotPopover = false
                    hostViewModel.clearSavedSnapshots()
                } label: {
                    HStack {
                        Text("清空快照")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer(minLength: 10)
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 10)
                    .frame(width: 188, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.red.opacity(0.16))
                    )
                }
                .buttonStyle(.plain)
                .disabled(hostViewModel.savedSnapshotCount == 0)
            }
            .padding(8)
            .frame(width: 204)
            .background(Color(red: 0.16, green: 0.16, blue: 0.17))
        }
        .disabled(
            hostViewModel.ideationSession != nil
                || hostViewModel.snapshotCompareSession != nil
                || hostViewModel.isSavingSnapshot
                || hostViewModel.isPreparingSnapshotCompare
        )
    }

    private var ideationButton: some View {
        Button {
            guard hostViewModel.snapshotCompareSession == nil else {
                showsSnapshotPopover = false
                showsRecorderPopover = false
                return
            }
            if hostViewModel.ideationSession == nil {
                showsSnapshotPopover = false
                showsDrawingStatsPopover = false
                showsRecorderPopover = false
                hostViewModel.startIdeationSession()
            } else {
                hostViewModel.cancelIdeationSession()
            }
        } label: {
            HStack(spacing: sidebarButtonContentSpacing) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: sidebarButtonIconFontSize, weight: .semibold))
                    .frame(width: sidebarButtonLeadingIconWidth)
                    .foregroundStyle(Color.white.opacity(0.9))

                Text("方案试探")
                    .font(.system(size: sidebarButtonLabelFontSize, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.95)
                    .foregroundStyle(Color.white.opacity(0.9))

                Spacer(minLength: sidebarButtonTrailingGap)

                Circle()
                    .fill(
                        hostViewModel.snapshotCompareSession != nil
                            ? Color.white.opacity(0.16)
                            : (hostViewModel.ideationSession == nil ? Color.white.opacity(0.25) : Color.accentColor)
                    )
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
            }
            .padding(.horizontal, sidebarButtonHorizontalPadding)
            .frame(width: sidebarButtonWidth, height: sidebarButtonHeight)
            .background(
                RoundedRectangle(cornerRadius: sidebarButtonCornerRadius)
                    .fill(
                        hostViewModel.snapshotCompareSession != nil
                            ? Color.white.opacity(0.05)
                            : (hostViewModel.ideationSession == nil ? Color.white.opacity(0.08) : Color.accentColor.opacity(0.22))
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(
            hostViewModel.snapshotCompareSession != nil
                || hostViewModel.isSavingSnapshot
                || hostViewModel.isPreparingSnapshotCompare
        )
        .help(
            hostViewModel.snapshotCompareSession != nil
                ? "快照对比期间不可进入方案试探"
                : ((hostViewModel.isSavingSnapshot || hostViewModel.isPreparingSnapshotCompare)
                    ? "快照任务完成后再进入方案试探"
                    : (hostViewModel.ideationSession == nil ? "方案试探" : "退出方案试探"))
        )
    }

    private var drawingStatsButton: some View {
        Button {
            showsSnapshotPopover = false
            showsRecorderPopover = false
            showsDrawingStatsPopover.toggle()
        } label: {
            HStack(spacing: sidebarButtonContentSpacing) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: sidebarButtonIconFontSize, weight: .semibold))
                    .frame(width: sidebarButtonLeadingIconWidth)
                    .foregroundStyle(Color.white.opacity(0.9))

                Text("绘画数据")
                    .font(.system(size: sidebarButtonLabelFontSize, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.95)
                    .foregroundStyle(Color.white.opacity(0.9))

                Spacer(minLength: sidebarButtonTrailingGap)
            }
            .padding(.horizontal, sidebarButtonHorizontalPadding)
            .frame(width: sidebarButtonWidth, height: sidebarButtonHeight)
            .background(
                RoundedRectangle(cornerRadius: sidebarButtonCornerRadius)
                    .fill(showsDrawingStatsPopover ? Color.accentColor.opacity(0.22) : Color.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .help("绘画数据")
        .popover(isPresented: $showsDrawingStatsPopover, arrowEdge: .leading) {
            DrawingStatsPanelView(controller: hostViewModel.drawingStatsController)
        }
    }

    private var recorderButton: some View {
        Button {
            guard hostViewModel.ideationSession == nil, hostViewModel.snapshotCompareSession == nil else {
                showsSnapshotPopover = false
                showsDrawingStatsPopover = false
                showsRecorderPopover = false
                return
            }
            showsDrawingStatsPopover = false
            showsRecorderPopover.toggle()
        } label: {
            HStack(spacing: sidebarButtonContentSpacing) {
                Image(systemName: "record.circle")
                    .font(.system(size: sidebarButtonIconFontSize, weight: .semibold))
                    .frame(width: sidebarButtonLeadingIconWidth)
                    .foregroundStyle(Color.white.opacity(0.9))

                Text("录像工具")
                    .font(.system(size: sidebarButtonLabelFontSize, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.95)
                    .foregroundStyle(Color.white.opacity(0.9))

                Spacer(minLength: sidebarButtonTrailingGap)

                Circle()
                    .fill(
                        hostViewModel.ideationSession != nil || hostViewModel.snapshotCompareSession != nil
                            ? Color.orange
                            : (hostViewModel.timelapseRecorder.isRecording ? Color.red : Color.green)
                    )
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
            }
            .padding(.horizontal, sidebarButtonHorizontalPadding)
            .frame(width: sidebarButtonWidth, height: sidebarButtonHeight)
            .background(
                RoundedRectangle(cornerRadius: sidebarButtonCornerRadius)
                    .fill(
                        hostViewModel.ideationSession != nil || hostViewModel.snapshotCompareSession != nil
                            ? Color.orange.opacity(0.16)
                            : Color.white.opacity(0.08)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(hostViewModel.ideationSession != nil || hostViewModel.snapshotCompareSession != nil)
        .help(
            hostViewModel.snapshotCompareSession != nil
                ? "快照对比期间录像已暂停"
                : (hostViewModel.ideationSession != nil
                    ? "方案试探期间录像已暂停"
                    : (hostViewModel.timelapseRecorder.isRecording ? "录像工具（录制中）" : "录像工具（未录制）"))
        )
        .popover(isPresented: $showsRecorderPopover, arrowEdge: .leading) {
            RecorderSectionView(
                viewModel: hostViewModel,
                recorder: hostViewModel.timelapseRecorder,
                exportFPS: $recorderExportFPS
            )
            .padding(12)
            .frame(width: 320)
            .background(Color(red: 0.16, green: 0.16, blue: 0.17))
        }
    }

    private var snapshotButtonHelpText: String {
        if hostViewModel.snapshotCompareSession != nil {
            return "快照对比中"
        }
        if hostViewModel.ideationSession != nil {
            return "方案试探期间不可使用快照保存"
        }
        if hostViewModel.isSavingSnapshot {
            return "正在保存快照"
        }
        if hostViewModel.isPreparingSnapshotCompare {
            return "正在准备快照对比"
        }
        if hostViewModel.savedSnapshotCount >= 6 {
            return "已达到 6 张快照上限，再点会直接进入快照对比"
        }
        return "快照保存（长按可打开快照对比 / 清空快照）"
    }
}

private struct ToolSidebarGroupButton: View {
    let group: ToolSidebarGroup
    @ObservedObject var shortcutSettings: AppShortcutSettingsStore
    let displayedTool: ToolKind
    let isSelected: Bool
    let activateGroup: () -> Void
    let activateTool: (ToolKind) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: activateGroup) {
                HStack(spacing: sidebarButtonContentSpacing) {
                    Image(systemName: displayedTool.sidebarIconName)
                        .font(.system(size: sidebarButtonIconFontSize, weight: .semibold))
                        .frame(width: sidebarButtonLeadingIconWidth)
                        .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.85))

                    Text(displayLabel)
                        .font(.system(size: sidebarButtonLabelFontSize, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(group.isGrouped ? 0.82 : 0.95)
                        .layoutPriority(1)
                        .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.9))

                    Spacer(minLength: sidebarButtonTrailingGap)
                }
                .padding(.leading, sidebarButtonHorizontalPadding)
                .padding(.trailing, group.isGrouped ? 4 : sidebarButtonHorizontalPadding)
                .frame(
                    width: group.isGrouped ? sidebarButtonWidth - 28 : sidebarButtonWidth,
                    height: sidebarButtonHeight
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(helpText)

            if group.isGrouped {
                Menu {
                    ForEach(group.tools, id: \.self) { tool in
                        Button {
                            activateTool(tool)
                        } label: {
                            Label(tool.displayName, systemImage: tool.sidebarIconName)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.white.opacity(0.58))
                        .frame(width: 28, height: sidebarButtonHeight)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("切换\(group.defaultTool.displayName)组工具")
            }
        }
        .frame(width: sidebarButtonWidth, height: sidebarButtonHeight)
        .background(
            RoundedRectangle(cornerRadius: sidebarButtonCornerRadius)
                .fill(isSelected ? Color.accentColor : Color.white.opacity(0.08))
        )
        .padding(.vertical, 4)
    }

    private var helpText: String {
        if group.isGrouped, let shortcut = shortcutSettings.shortcutKey(for: group) {
            return "\(displayedTool.displayName) (\(shortcut))，右侧箭头可切换组内工具，Shift+\(shortcut) 轮换"
        }
        if let shortcut = shortcutSettings.shortcutKey(for: group) {
            return "\(displayedTool.displayName) (\(shortcut))"
        }
        return displayedTool.displayName
    }

    private var displayLabel: String {
        guard let shortcut = shortcutSettings.shortcutKey(for: group) else {
            return displayedTool.displayName
        }
        return "\(displayedTool.displayName)(\(shortcut))"
    }
}

private struct ToolSidebarEntry: Identifiable {
    enum Kind {
        case group(String)
        case divider
    }

    let id: String
    let kind: Kind

    static func group(_ id: String) -> ToolSidebarEntry {
        .init(id: id, kind: .group(id))
    }

    static func divider(_ id: String) -> ToolSidebarEntry {
        .init(id: id, kind: .divider)
    }
}

import SwiftUI

struct ToolSidebarView: View {
    @ObservedObject var viewModel: WorkspaceViewModel
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
        .group("canvas-rotate"),
        .group("free-transform")
    ]

    var body: some View {
        VStack(spacing: 0) {
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
                            displayedTool: viewModel.displayedTool(for: group),
                            isSelected: viewModel.isSelected(group: group),
                            activateGroup: { viewModel.activateSidebarGroup(group) },
                            activateTool: { tool in viewModel.selectTool(tool) }
                        )
                    }
                }
            }

            Spacer()

            recorderButton
        }
        .padding(.top, 10)
        .padding(.horizontal, 8)
        .frame(width: 136)
        .frame(maxHeight: .infinity)
        .background(Color(red: 0.13, green: 0.13, blue: 0.14))
    }

    private var recorderButton: some View {
        Button {
            showsRecorderPopover.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "record.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 13)
                    .foregroundStyle(Color.white.opacity(0.9))

                Text("录像工具")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.95)
                    .foregroundStyle(Color.white.opacity(0.9))

                Spacer(minLength: 4)

                Circle()
                    .fill(viewModel.timelapseRecorder.isRecording ? Color.red : Color.green)
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
            }
            .padding(.horizontal, 10)
            .frame(width: 116, height: 34)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .help(viewModel.timelapseRecorder.isRecording ? "录像工具（录制中）" : "录像工具（未录制）")
        .padding(.vertical, 8)
        .popover(isPresented: $showsRecorderPopover, arrowEdge: .leading) {
            RecorderSectionView(
                viewModel: viewModel,
                recorder: viewModel.timelapseRecorder,
                exportFPS: $recorderExportFPS
            )
            .padding(12)
            .frame(width: 320)
            .background(Color(red: 0.16, green: 0.16, blue: 0.17))
        }
    }
}

private struct ToolSidebarGroupButton: View {
    let group: ToolSidebarGroup
    let displayedTool: ToolKind
    let isSelected: Bool
    let activateGroup: () -> Void
    let activateTool: (ToolKind) -> Void

    @State private var showsPopover = false

    var body: some View {
        Button(action: activateGroup) {
            HStack(spacing: 6) {
                Image(systemName: displayedTool.sidebarIconName)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 13)
                    .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.85))

                Text(displayedTool.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.95)
                    .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.9))

                Spacer(minLength: 4)

                if group.isGrouped {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.88) : Color.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 10)
            .frame(width: 116, height: 34)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(isSelected ? Color.accentColor : Color.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .help(helpText)
        .padding(.vertical, 4)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.35)
                .onEnded { _ in
                    guard group.isGrouped else { return }
                    showsPopover = true
                }
        )
        .popover(isPresented: $showsPopover, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(group.tools, id: \.self) { tool in
                    Button {
                        activateTool(tool)
                        showsPopover = false
                    } label: {
                        HStack(spacing: 8) {
                            Text(tool.displayName)
                                .font(.system(size: 13, weight: tool == displayedTool ? .bold : .medium))
                                .foregroundStyle(Color.white)
                            Spacer(minLength: 12)
                            if let shortcut = tool.shortcutKey {
                                Text(shortcut)
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.white.opacity(0.7))
                            }
                        }
                        .padding(.horizontal, 10)
                        .frame(width: 170, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(tool == displayedTool ? Color.white.opacity(0.12) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .frame(width: 186)
            .background(Color(red: 0.16, green: 0.16, blue: 0.17))
        }
    }

    private var helpText: String {
        if group.isGrouped, let shortcut = group.shortcutKey {
            return "\(displayedTool.displayName) (\(shortcut))，长按可切换组内工具，Shift+\(shortcut) 轮换"
        }
        if let shortcut = group.shortcutKey {
            return "\(displayedTool.displayName) (\(shortcut))"
        }
        return displayedTool.displayName
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

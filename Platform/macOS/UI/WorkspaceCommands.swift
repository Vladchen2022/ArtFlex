import SwiftUI

struct WorkspaceCommand: Identifiable {
    let id: String
    let title: String
    let category: String
    var shortcut = ""
    var unavailableReason: String?
    let action: () -> Void
}

extension WorkspaceViewModel {
    var isWorkflowAdjustmentActive: Bool { selectionRefinementDraft != nil || textureAdjustmentSettings != nil }

    var searchableCommands: [WorkspaceCommand] {
        let selected = workspace.selection.committedShape != nil
        let draftBlocked = selectionRefinementDraft != nil || textureAdjustmentSettings != nil
        let noSelection: String? = isTransformingSelection ? "请先结束变形" : (!selected ? "需要先建立选区" : nil)
        let persistenceBlock: String? = draftBlocked ? "请先应用或取消调整" : (isProjectSaving ? "正在保存" : nil)
        let commands: [WorkspaceCommand] = [
            .init(id: "new", title: "新建画布", category: "文件", shortcut: "⌘N", unavailableReason: persistenceBlock, action: presentNewCanvasSheet),
            .init(id: "open", title: "打开工程", category: "文件", shortcut: "⌘O", unavailableReason: persistenceBlock, action: openProject),
            .init(id: "save", title: "保存工程", category: "文件", shortcut: "⌘S", unavailableReason: persistenceBlock, action: { self.saveProject() }),
            .init(id: "saveAs", title: "另存为…", category: "文件", shortcut: "⇧⌘S", unavailableReason: persistenceBlock, action: { self.saveProject(asNewFile: true) }),
            .init(id: "export", title: "导出图像", category: "文件", shortcut: "⌘E", unavailableReason: persistenceBlock, action: presentRasterExportSheet),
            .init(id: "undo", title: "撤销", category: "编辑", shortcut: "⌘Z", unavailableReason: canUndo ? nil : "没有可撤销操作", action: undo),
            .init(id: "redo", title: "重做", category: "编辑", shortcut: "⇧⌘Z", unavailableReason: canRedo ? nil : "没有可重做操作", action: redo),
            .init(id: "transform", title: "移动与自由变形", category: "编辑", shortcut: "V", action: { self.selectTool(.freeTransform) }),
            .init(id: "newLayer", title: "新建绘画图层", category: "图层", action: { self.addLayer() }),
            .init(id: "duplicate", title: "复制当前图层", category: "图层", action: duplicateActiveLayer),
            .init(id: "mergeDown", title: "向下合并", category: "图层", unavailableReason: canMergeDown ? nil : "需要下方可合并图层", action: mergeActiveLayerDown),
            .init(id: "mergeVisible", title: "合并可见图层", category: "图层", unavailableReason: canMergeVisible ? nil : "需要多个可合并图层", action: mergeVisibleLayers),
            .init(id: "mask", title: "添加显示全部蒙版", category: "图层", unavailableReason: workspace.document.layer(workspace.document.activeLayerID)?.mask == nil ? nil : "当前图层已有蒙版", action: { self.addMaskToActiveLayer() }),
            .init(id: "maskEdit", title: "编辑图层蒙版", category: "图层", unavailableReason: workspace.document.layer(workspace.document.activeLayerID)?.mask == nil ? "当前图层没有蒙版" : nil, action: beginEditingActiveLayerMask),
            .init(id: "content", title: "编辑图层内容", category: "图层", action: stopEditingLayerMask),
            .init(id: "clearSelection", title: "取消选区", category: "选区", shortcut: "⌘D", unavailableReason: noSelection, action: clearSelection),
            .init(id: "invert", title: "反选", category: "选区", unavailableReason: noSelection, action: invertSelection),
            .init(id: "feather", title: "羽化选区", category: "选区", unavailableReason: noSelection, action: { self.beginSelectionRefinementPreview(.feather) }),
            .init(id: "expand", title: "扩展选区", category: "选区", unavailableReason: noSelection, action: { self.beginSelectionRefinementPreview(.expand) }),
            .init(id: "contract", title: "收缩选区", category: "选区", unavailableReason: noSelection, action: { self.beginSelectionRefinementPreview(.contract) }),
            .init(id: "fill", title: "填充选区", category: "选区", shortcut: "⇧⌘F", unavailableReason: noSelection, action: fillSelectionContents),
            .init(id: "fit", title: "适合窗口", category: "视图", shortcut: "⌘0", action: resetViewport),
            .init(id: "zoomIn", title: "放大画布", category: "视图", action: zoomIn),
            .init(id: "zoomOut", title: "缩小画布", category: "视图", action: zoomOut),
            .init(id: "snapshot", title: "保存画布快照", category: "视图", action: requestSnapshotSavePrimaryAction),
            .init(id: "compare", title: "快照对比", category: "视图", unavailableReason: savedSnapshotCount == 0 ? "需要先保存快照" : nil, action: requestOpenSnapshotCompare)
        ]
        return commands.map { command in
            var result = command
            if draftBlocked && !["undo", "redo"].contains(command.id) { result.unavailableReason = "请先应用或取消调整" }
            return result
        }
    }
}

struct CommandSearchSheet: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    @State private var query = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    private var matches: [WorkspaceCommand] {
        viewModel.searchableCommands.filter { query.isEmpty || ($0.title + $0.category).localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("搜索命令，例如羽化、合并、蒙版", text: $query)
                    .textFieldStyle(.roundedBorder).focused($focused)
                    .onSubmit { if let command = matches.first(where: { $0.unavailableReason == nil }) { run(command) } }
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(matches) { command in
                        Button { run(command) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(command.title).fontWeight(.medium)
                                    Text(command.unavailableReason ?? command.category).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(command.shortcut).foregroundStyle(.secondary)
                            }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain).disabled(command.unavailableReason != nil)
                    }
                    if matches.isEmpty { Text("没有匹配的命令").padding() }
                }
            }.frame(height: 350)
        }.padding(20).frame(width: 480).preferredColorScheme(.dark)
            .onAppear { focused = true }
    }
    private func run(_ command: WorkspaceCommand) {
        guard command.unavailableReason == nil else { return }
        dismiss()
        // Finish dismissal before opening another sheet or native file panel.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            command.action()
        }
    }
}

struct ArtFlexWorkspaceCommands: Commands {
    @ObservedObject var host: WorkspaceViewModel
    var editor: WorkspaceViewModel { host.ideationActiveBranchViewModel ?? host }
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建画布") { host.presentNewCanvasSheet() }.keyboardShortcut("n")
            Button("打开工程…") { host.openProject() }.keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) {
            Button("保存工程") { host.saveProject() }.keyboardShortcut("s")
            Button("另存为…") { host.saveProject(asNewFile: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button("导出图像…") { host.presentRasterExportSheet() }.keyboardShortcut("e")
        }
        CommandGroup(replacing: .undoRedo) {
            Button("撤销") { editor.undo() }.keyboardShortcut("z").disabled(!editor.canUndo)
            Button("重做") { editor.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!editor.canRedo)
        }
        CommandGroup(after: .pasteboard) {
            Button("合并拷贝") { editor.copyMergedPixels() }.keyboardShortcut("c", modifiers: [.command, .shift])
            Button("删除选区内容") { editor.deleteSelectionOrActiveLayer() }.keyboardShortcut(.delete, modifiers: [])
                .disabled(editor.isTransformingSelection || editor.isWorkflowAdjustmentActive)
            Divider()
            Button("应用变形") { editor.applySelectionTransform() }.disabled(!editor.isTransformingSelection)
            Button("取消变形") { editor.cancelSelectionTransform() }.disabled(!editor.isTransformingSelection)
            Button("搜索命令…") { editor.isCommandSearchPresented = true }.keyboardShortcut("p", modifiers: [.command, .shift])
        }
        CommandMenu("图层") {
            category("图层")
            Button("盖印图层") { editor.stampVisibleLayers() }.keyboardShortcut("e", modifiers: [.command, .option, .shift]).disabled(editor.isWorkflowAdjustmentActive)
        }
        CommandMenu("选区") {
            Button("取消选区") { editor.clearSelection() }.keyboardShortcut("d").disabled(editor.isTransformingSelection || editor.isWorkflowAdjustmentActive)
            Button("填充选区内容") { editor.fillSelectionContents() }.keyboardShortcut("f", modifiers: [.command, .shift]).disabled(editor.isWorkflowAdjustmentActive || editor.workspace.selection.committedShape == nil)
            ForEach(editor.searchableCommands.filter { $0.category == "选区" && $0.id != "clearSelection" && $0.id != "fill" }) { command in
                Button(command.title, action: command.action).disabled(command.unavailableReason != nil)
            }
            Button("填充套索内容") { editor.fillLassoContents() }.disabled(editor.isWorkflowAdjustmentActive)
            Button("擦除套索内容") { editor.eraseLassoContents() }.disabled(editor.isWorkflowAdjustmentActive)
        }
        CommandGroup(after: .toolbar) {
            Button("适合窗口") { editor.resetViewport() }.keyboardShortcut("0")
            Button("放大画布") { editor.zoomIn() }
            Button("缩小画布") { editor.zoomOut() }
        }
    }
    @ViewBuilder private func category(_ category: String) -> some View {
        ForEach(editor.searchableCommands.filter { $0.category == category }) { command in
            Button(command.title, action: command.action).disabled(command.unavailableReason != nil)
        }
    }
}

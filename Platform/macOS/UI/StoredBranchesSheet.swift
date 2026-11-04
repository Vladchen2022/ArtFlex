import SwiftUI

struct StoredBranchesSheet: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    @State private var name = "新方案"
    @State private var selection: UUID?
    private var selected: StoredIdeationBranch? { (viewModel.workspace.document.storedBranches ?? []).first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("保存的方案").font(.headline)
            Text("随当前工程保存，最多 8 个。保留完整图层与源素材；载入后继续编辑，或只选择部分图层加入主稿。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("方案名称", text: $name)
                Button(viewModel.ideationSession == nil ? "保存当前画稿" : "保存选中方案") { viewModel.branches.storeCurrent(name: name) }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.branches.isBusy || (viewModel.workspace.document.storedBranches?.count ?? 0) >= 8)
            }
            List(selection: $selection) {
                ForEach(viewModel.workspace.document.storedBranches ?? []) { branch in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(branch.name)
                            Text("\(branch.canvasSize.width) × \(branch.canvasSize.height) · \(branch.layerCount) 层").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(branch.savedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                    }.tag(branch.id)
                }
            }.frame(height: 240)
            if viewModel.branches.isBusy { HStack { ProgressView().controlSize(.small); Text("正在处理方案…") } }
            if let message = viewModel.branches.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("重命名") { if let selected { viewModel.branches.rename(selected.id, name: name) } }.disabled(selected == nil || name.isEmpty)
                Button("删除") { if let selected { viewModel.branches.delete(selected.id); selection = nil } }.disabled(selected == nil)
                Spacer()
                Button("选层合入") { if let selected { viewModel.branches.load(selected, forEditing: false) } }.disabled(selected == nil)
                Button("继续编辑") { if let selected { viewModel.branches.load(selected, forEditing: true) } }.disabled(selected == nil)
            }.disabled(viewModel.branches.isBusy)
            HStack { Spacer(); Button("关闭") { viewModel.branches.isPresented = false }.keyboardShortcut(.cancelAction) }
        }.padding(22).frame(width: 620)
            .onChange(of: selection) { _, _ in if let selected { name = selected.name } }
    }
}

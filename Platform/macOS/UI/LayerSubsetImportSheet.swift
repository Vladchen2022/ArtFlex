import SwiftUI

@MainActor
final class LayerSubsetImportDraft: ObservableObject, Identifiable {
    let id = UUID()
    let payload: ProjectArchivePayload
    let name: String
    @Published var selected: Set<LayerID>
    let apply: (Set<LayerID>) -> Bool
    init(payload: ProjectArchivePayload, name: String, apply: @escaping (Set<LayerID>) -> Bool) {
        self.payload = payload; self.name = name; self.apply = apply
        selected = Set(payload.package.document.paintLayers.map(\.id))
    }
}

struct LayerSubsetImportSheet: View {
    @ObservedObject var draft: LayerSubsetImportDraft
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("从“\(draft.name)”选择图层").font(.headline)
            Text("加入主稿的新图层组；保留蒙版、混合模式及可编辑参数。组、剪贴底层和调整层所依赖的内容会一并加入。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("全选") { draft.selected = Set(draft.payload.package.document.paintLayers.map(\.id)) }
                Button("清空选择") { draft.selected = [] }
            }
            List(draft.payload.package.document.layers.reversed(), id: \.id) { layer in
                let members = selectionMembers(for: layer)
                Toggle(isOn: Binding(get: { members.isSubset(of: draft.selected) }, set: { value in
                    if value { draft.selected.formUnion(members) } else { draft.selected.subtract(members) }
                })) { Label(layer.name, systemImage: layer.isGroup ? "folder" : "square.3.layers.3d") }
            }.frame(minHeight: 260)
            let included = LayerSubsetImport.includedLayerIDs(in: draft.payload.package.document, selected: draft.selected)
            Text("包含依赖共 \(included.count) 个图层或组").font(.caption)
            HStack {
                Spacer()
                Button("取消", action: close).keyboardShortcut(.cancelAction)
                Button("作为图层组合入") { if draft.apply(draft.selected) { close() } }
                    .disabled(included.isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 480, height: 440)
    }

    private func selectionMembers(for layer: LayerRecord) -> Set<LayerID> {
        guard layer.isGroup else { return [layer.id] }
        let document = draft.payload.package.document
        let descendants = document.descendantLayerIDs(of: layer.id)
        let paint = Set(document.paintLayers.filter { descendants.contains($0.id) }.map(\.id))
        return paint.isEmpty ? [layer.id] : paint
    }
}

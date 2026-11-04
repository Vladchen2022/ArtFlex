import SwiftUI

struct RecentProjectsMenu: View {
    @ObservedObject var model: WorkspaceViewModel
    @ObservedObject private var access: ProjectAccessController
    init(model: WorkspaceViewModel) { self.model = model; self.access = model.projectAccess }
    var body: some View {
        Group {
            if let first = access.recentURLs.first {
                Button("继续上次工程：\(first.deletingPathExtension().lastPathComponent)") { model.openProjectFromExternalURL(first) }
                    .disabled(!FileManager.default.fileExists(atPath: first.path))
                Divider()
            }
            ForEach(access.recentURLs, id: \.self) { url in
                Button(url.deletingPathExtension().lastPathComponent) { model.openProjectFromExternalURL(url) }
                    .help(url.path).disabled(!FileManager.default.fileExists(atPath: url.path))
            }
            if access.recentURLs.isEmpty { Text("暂无最近工程") }
            else { Divider(); Button("清除最近工程列表") { access.clearRecent() } }
        }
        .disabled(model.documentPersistenceBlockReason(action: "打开工程") != nil)
        .onAppear { access.refreshRecent() }
    }
}

struct RecoveryProjectPopover: View {
    @ObservedObject var model: WorkspaceViewModel
    @ObservedObject private var access: ProjectAccessController
    @Environment(\.dismiss) private var dismiss
    init(model: WorkspaceViewModel) { self.model = model; self.access = model.projectAccess }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("自动恢复副本").font(.headline)
            if access.inspecting { ProgressView("正在读取恢复信息…") }
            else if let summary = access.recovery {
                Text(summary.name).fontWeight(.medium)
                if let date = summary.modified { Text(date, format: .dateTime.year().month().day().hour().minute()).foregroundStyle(.secondary) }
                Text("\(summary.canvasSize.width) × \(summary.canvasSize.height)")
                if let data = summary.previewPNGData, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 260, height: 170).background(.white)
                } else { Text("此恢复副本没有预览图").foregroundStyle(.secondary) }
                Text("恢复后仍需另存为正式工程。当前画稿有改动时会先询问保存。").font(.caption).fixedSize(horizontal: false, vertical: true)
            } else { Text(access.recoveryError ?? "暂无恢复信息").foregroundStyle(.orange) }
            HStack {
                Button("恢复") { dismiss(); model.recoverAutosavedProject() }.disabled(access.inspecting || access.recovery == nil)
                Spacer()
                Button("丢弃恢复副本", role: .destructive) { dismiss(); model.discardAutosavedProject() }
            }
        }.padding(18).frame(width: 300).onAppear { model.inspectRecoveryProject() }
    }
}

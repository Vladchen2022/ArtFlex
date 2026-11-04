import ImageIO
import SwiftUI

struct ProjectLoadingView: View {
    let progress: ProjectReadProgress
    var isSaving = false
    let cancel: () -> Void
    @State private var preview: CGImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(progress.phase.rawValue).font(.headline)
                Spacer()
                Button(isSaving ? "取消保存" : "取消打开", action: cancel)
                    .disabled(progress.phase == .cancelling || progress.phase == .committing)
            }
            if let preview {
                Image(decorative: preview, scale: 1).resizable().scaledToFit().frame(maxHeight: 160)
                    .frame(maxWidth: .infinity).background(Color.gray.opacity(0.15))
            }
            if let total = progress.total, total > 0 {
                ProgressView(value: Double(progress.completed), total: Double(total))
                Text("\(progress.completed) / \(total)").font(.caption).monospacedDigit()
            } else {
                HStack { ProgressView().controlSize(.small); if progress.completed > 0 { Text("已处理 \(progress.completed) 个条目").font(.caption) } }
            }
            Text(isSaving ? "准备完成后才替换正式文件；取消会保留原工程。" : "新工程准备完成后才替换画布；取消会保留当前画稿。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(18).frame(width: 360).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.18)))
            .shadow(radius: 12)
            .task(id: progress.previewPNGData != nil) {
                guard let data = progress.previewPNGData else { preview = nil; return }
                let image = await Task.detached(priority: .utility) {
                    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return WorkspaceUncheckedBox<CGImage?>(nil) }
                    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 320, kCGImageSourceCreateThumbnailWithTransform: true]
                    return WorkspaceUncheckedBox(CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary))
                }.value
                guard !Task.isCancelled else { return }
                preview = image.value
            }
    }
}

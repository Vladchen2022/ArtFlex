import AppKit
import SwiftUI

@MainActor
final class CanvasLayerPickerModel: ObservableObject {
    @Published private(set) var candidates: [CanvasLayerPickCandidate] = []
    @Published private(set) var images: [LayerID: CGImage] = [:]
    @Published private(set) var isLoading = true
    @Published private(set) var error: String?
    @Published var hoveredID: LayerID?
    private weak var viewModel: WorkspaceViewModel?
    private let point: CanvasPoint
    private let requestID = UUID()
    private var isCancelled = false
    var close: (() -> Void)?

    init(viewModel: WorkspaceViewModel, point: CanvasPoint) {
        self.viewModel = viewModel; self.point = point
    }

    func load() async {
        do {
            guard let viewModel else { return }
            let result = try await viewModel.canvasLayerPickCandidates(at: point, requestID: requestID)
            guard !isCancelled, !Task.isCancelled else { return }
            candidates = result; hoveredID = result.first?.id
        } catch is CancellationError { close?() }
        catch { self.error = error.localizedDescription }
        isLoading = false
    }

    func loadPreview(_ id: LayerID) async {
        guard images[id] == nil, !isCancelled else { return }
        do {
            let image = try await viewModel?.canvasLayerPickPreview(id, requestID: requestID)
            guard !isCancelled, !Task.isCancelled else { return }
            images[id] = image
        } catch is CancellationError { }
        catch { self.error = "图层预览读取失败：\(error.localizedDescription)" }
    }

    func choose(_ id: LayerID) {
        guard viewModel?.selectCanvasPickedLayer(id, requestID: requestID) == true else {
            error = "画稿已经变化，请关闭后重新点击画布查找"; return
        }
        close?()
    }

    func cancel() {
        isCancelled = true
        viewModel?.cancelCanvasLayerPick(requestID)
        images = [:]
    }
}

private struct CanvasLayerPickerContent: View {
    @ObservedObject var model: CanvasLayerPickerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("此处的图层").font(.headline)
                Spacer()
                Button("关闭") { model.close?() }.keyboardShortcut(.cancelAction)
            }
            Text("从上到下排列 · 悬停预览，点击选择").font(.caption).foregroundStyle(.secondary)
            if model.isLoading { ProgressView("正在查找…").frame(maxWidth: .infinity) }
            else if model.candidates.isEmpty && model.error == nil { Text("此处没有可见图层内容").foregroundStyle(.secondary) }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if !model.candidates.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(model.candidates) { candidate in
                            Button { model.choose(candidate.id) } label: {
                                HStack(spacing: 8) {
                                    preview(candidate.id).frame(width: 44, height: 44)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(candidate.name).lineLimit(1)
                                        if !candidate.groupPath.isEmpty { Text(candidate.groupPath).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                        if candidate.isEditableFill { Text("可编辑填充").font(.caption2).foregroundStyle(.secondary) }
                                    }
                                    Spacer(minLength: 2)
                                    if candidate.isLocked { Image(systemName: "lock.fill").help("图层已锁定，选择不会自动解锁") }
                                }.padding(5).contentShape(Rectangle())
                                    .background(model.hoveredID == candidate.id ? Color.accentColor.opacity(0.18) : .clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                            }.buttonStyle(.plain)
                                .accessibilityLabel("选择图层 \(candidate.name)\(candidate.isLocked ? "，已锁定" : "")")
                                .onHover { if $0 { model.hoveredID = candidate.id } }
                                .task { await model.loadPreview(candidate.id) }
                        }
                    }
                }.frame(height: min(250, CGFloat(model.candidates.count) * 58))
                if let id = model.hoveredID {
                    Divider()
                    preview(id).frame(maxWidth: .infinity).frame(height: 150)
                    Text("单层内容预览").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }.padding(12).frame(width: 310)
            .task { await model.load() }
    }

    private func preview(_ id: LayerID) -> some View {
        ZStack {
            Color.white
            if let image = model.images[id] {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else { Image(systemName: "square.3.layers.3d").foregroundStyle(.gray) }
        }.clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

@MainActor
final class CanvasLayerPickerPopover: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let model: CanvasLayerPickerModel

    init(model: CanvasLayerPickerModel) {
        self.model = model
        super.init()
        popover.behavior = .transient; popover.animates = false; popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: CanvasLayerPickerContent(model: model))
        model.close = { [weak self] in self?.close() }
    }

    func show(at point: CGPoint, in view: NSView) {
        guard view.window != nil else { model.cancel(); return }
        popover.show(relativeTo: NSRect(origin: point, size: .init(width: 1, height: 1)), of: view, preferredEdge: .maxX)
    }
    func close() { model.cancel(); popover.performClose(nil) }
    func popoverDidClose(_ notification: Notification) { model.cancel() }
}

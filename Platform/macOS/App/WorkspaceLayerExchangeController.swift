import Combine
import Foundation

@MainActor
final class WorkspaceLayerExchangeController: ObservableObject {
    enum Mode { case importing, exporting }
    @Published var isPresented = false
    @Published var mode = Mode.importing
    @Published var flattened = false
    @Published private(set) var isBusy = false
    @Published private(set) var progress: ProjectReadProgress?
    @Published private(set) var message: String?
    private weak var owner: WorkspaceViewModel?
    private let bootstrap: AppBootstrap
    private var context: ProjectReadContext?
    private var relay: AnyCancellable?
    var unsupported: [String] { owner.map { OpenRasterCodec.unsupportedLayers($0.workspace.document) } ?? [] }

    init(owner: WorkspaceViewModel, bootstrap: AppBootstrap) {
        self.owner = owner; self.bootstrap = bootstrap
        relay = objectWillChange.sink { [weak owner] _ in owner?.objectWillChange.send() }
    }
    func present(_ mode: Mode) {
        guard !isBusy else { return }
        self.mode = mode; flattened = false; message = nil; isPresented = true
    }
    func cancel() { context?.cancellation.cancel(); message = "正在取消，等待安全边界…" }
    func chooseFile() {
        guard let owner, !isBusy else { return }
        bootstrap.filePanelService.presentOpenRasterPanel(exporting: mode == .exporting,
            defaultName: owner.workspace.document.metadata.name) { [weak self] url in
                guard let self, let url else { return }
                if self.mode == .exporting { self.export(to: url) } else { self.load(from: url) }
            }
    }
    private func begin() -> ProjectReadContext {
        isBusy = true; message = nil
        let context = ProjectReadContext { [weak self] value in
            Task { @MainActor in guard self?.isBusy == true else { return }; self?.progress = value }
        }
        self.context = context
        return context
    }
    private func finish(_ error: Error?) {
        isBusy = false; context = nil; progress = nil
        if let error { message = error is CancellationError ? "已取消，原文件和画稿未改变" : error.localizedDescription }
    }
    func export(to url: URL) {
        guard let owner, !isBusy else { return }
        do {
            let capture = try owner.captureForBranch()
            let context = begin(), flattened = flattened
            let persistence = WorkspaceUncheckedBox(bootstrap.persistenceController)
            let metal = WorkspaceUncheckedBox(bootstrap.metalContext)
            Task { [weak self] in
                let result = await Task.detached(priority: .userInitiated) { Result<Void, Error> {
                    let frozen = try capture.waitUntilReady()
                    guard let composite = frozen.previewTexture else { throw OpenRasterError.invalid("无法冻结合并图像") }
                    let payload = try persistence.value.materializeProjectPayload(from: frozen, context: context)
                    let merged = try LayerTextureSerializer(metalContext: metal.value).snapshot(texture: composite)
                    try OpenRasterCodec.write(payload, merged: merged, to: url, flattened: flattened, context: context)
                } }.value
                guard let self else { return }
                switch result {
                case .success: self.finish(nil); self.message = "已导出 \(url.lastPathComponent)；原生工程和历史保持完整"
                case .failure(let error): self.finish(error)
                }
            }
        } catch { message = error.localizedDescription }
    }
    func load(from url: URL) {
        guard let owner, !isBusy, owner.prepareForDocumentTabSwitch() else { return }
        let context = begin(), flattened = flattened, limits = bootstrap.archiveReadLimits
        let policy = bootstrap.documentResourceBudgetPolicy
        let stager = ProjectOpenTextureStager(metal: bootstrap.metalContext, serializer: bootstrap.textureSerializer)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result<OpenProjectResult, Error> {
                var opened = try OpenRasterCodec.read(from: url, flattened: flattened, limits: limits, context: context)
                let document = opened.workspace.document
                let assessment = policy.assess(canvasSize: document.canvasSize, paintLayerCount: document.paintLayers.count, maskCount: 0, savedSnapshotCount: 0,
                    pixelFormat: document.colorStandard.pixelFormat)
                guard assessment.isSupported else { throw OpenRasterError.invalid(assessment.rejectionReason ?? "超过设备预算") }
                opened.preparedTextures = try stager.prepare(opened, context: context)
                opened.layerSnapshots = []
                try context.check()
                return opened
            } }.value
            guard let self else { return }
            switch result {
            case .success(let opened):
                guard !context.cancellation.isCancelled else { self.finish(CancellationError()); return }
                self.finish(nil)
                self.isPresented = false
                self.owner?.importExchangeInNewSession?(opened, url)
            case .failure(let error): self.finish(error)
            }
        }
    }
}

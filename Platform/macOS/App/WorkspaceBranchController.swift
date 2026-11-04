import Combine
import Foundation

@MainActor
final class WorkspaceBranchController: ObservableObject {
    @Published var isPresented = false
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    @Published var importDraft: LayerSubsetImportDraft?
    private var pendingImport: LayerSubsetImportDraft?
    private weak var owner: WorkspaceViewModel?
    private let bootstrap: AppBootstrap
    private var relay: AnyCancellable?

    init(owner: WorkspaceViewModel, bootstrap: AppBootstrap) {
        self.owner = owner; self.bootstrap = bootstrap
        relay = objectWillChange.sink { [weak owner] _ in owner?.objectWillChange.send() }
    }

    func storeCurrent(name: String) {
        guard let owner, !isBusy else { return }
        guard (owner.workspace.document.storedBranches?.count ?? 0) < 8 else { message = "已达到 8 个方案，请先删除不需要的方案"; return }
        let source = owner.ideationSession?.activeBranchViewModel ?? owner
        capture(from: source) { [weak self] payload in
            guard let self, let owner = self.owner else { return }
            let generation = owner.documentRenderGeneration
            self.isBusy = true; self.message = "正在封装完整方案…"
            let limits = self.bootstrap.archiveReadLimits
            Task { [weak self] in
                let result = await Task.detached(priority: .userInitiated) { Result { try IdeationBranchArchive.encode(payload, name: name, limits: limits) } }.value
                guard let self else { return }
                self.isBusy = false
                guard let owner = self.owner, owner.documentRenderGeneration == generation else { self.message = "画稿已切换，方案未加入当前工程"; return }
                switch result {
                case .success(let branch):
                    if owner.commitBranchShelfChange(adding: branch) { self.message = "已保留“\(branch.name)”；保存工程后可跨启动继续使用" }
                case .failure(let error): self.message = error.localizedDescription
                }
            }
        }
    }

    func rename(_ id: UUID, name: String) {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
        guard !name.isEmpty, !isBusy else { return }
        _ = owner?.commitBranchShelfChange { branches in
            if let index = branches.firstIndex(where: { $0.id == id }) { branches[index].name = name }
        }
    }

    func delete(_ id: UUID) {
        guard !isBusy else { return }
        _ = owner?.commitBranchShelfChange { $0.removeAll { $0.id == id } }
    }

    func importSelectedVariant() {
        guard let owner, let session = owner.ideationSession else { return }
        let name = session.branches[session.selectedBranchIndex].title
        capture(from: session.activeBranchViewModel) { [weak self] payload in self?.presentImport(payload, name: name) }
    }

    func load(_ branch: StoredIdeationBranch, forEditing: Bool) {
        guard let owner, !isBusy else { return }
        if forEditing, owner.ideationSession != nil { message = "请先保存并退出当前方案试探，再载入其他方案"; return }
        let generation = owner.documentRenderGeneration, limits = bootstrap.archiveReadLimits
        isBusy = true; message = "正在校验并载入方案…"
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result { try IdeationBranchArchive.decode(branch, limits: limits) } }.value
            guard let self else { return }
            self.isBusy = false
            guard let owner = self.owner, owner.documentRenderGeneration == generation else { self.message = "画稿已切换，本次载入已取消"; return }
            do {
                let payload = try result.get()
                if forEditing {
                    try owner.beginStoredBranchEditing(payload)
                    self.isPresented = false
                } else { self.presentImport(payload, name: branch.name) }
            } catch { self.message = error.localizedDescription }
        }
    }

    func didDismissShelf() { if let pendingImport { self.pendingImport = nil; importDraft = pendingImport } }

    private func capture(from source: WorkspaceViewModel, completion: @escaping (ProjectArchivePayload) -> Void) {
        guard let owner, !isBusy else { return }
        do {
            let capture = try source.captureForBranch()
            let generation = owner.documentRenderGeneration
            let persistence = WorkspaceUncheckedBox(bootstrap.persistenceController)
            isBusy = true; message = "正在冻结方案图层…"
            Task { [weak self] in
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try persistence.value.materializeProjectPayload(from: capture.waitUntilReady()) }
                }.value
                guard let self else { return }
                self.isBusy = false
                guard let owner = self.owner, owner.documentRenderGeneration == generation else { self.message = "画稿已切换，本次采集已取消"; return }
                switch result {
                case .success(let payload): completion(payload)
                case .failure(let error): self.message = error.localizedDescription
                }
            }
        } catch { message = error.localizedDescription }
    }

    private func presentImport(_ payload: ProjectArchivePayload, name: String) {
        guard let owner else { return }
        let revision = owner.branchDocumentVersion
        let draft = LayerSubsetImportDraft(payload: payload, name: name) { [weak owner] selected in
            owner?.importBranchLayers(payload, selected: selected, name: name, expectedVersion: revision) ?? false
        }
        if isPresented { pendingImport = draft; isPresented = false } else { importDraft = draft }
    }
}

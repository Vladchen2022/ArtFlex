import Combine
import Foundation

/// A document owns its editing/history/recovery services. Only immutable libraries and Metal
/// services are shared; switching tabs never replaces another document's workspace.
@MainActor
final class DocumentSessionController: ObservableObject {
    struct Session: Identifiable {
        let id: UUID
        let model: WorkspaceViewModel
        let bootstrap: AppBootstrap
    }
    struct Recoverable: Identifiable {
        let id: URL
        let name: String
    }
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var activeID: UUID
    @Published private(set) var isTransferring = false
    @Published private(set) var recoverable: [Recoverable] = []
    var onActiveChange: ((WorkspaceViewModel) -> Void)?
    var active: WorkspaceViewModel { sessions.first { $0.id == activeID }!.model }
    private let services: AppBootstrap
    private let documentsRoot: URL
    private var relays: [UUID: AnyCancellable] = [:]
    private var isClosing = false
    private var pendingQuitCompletion: ((Bool) -> Void)?
    private var recoverySources: [UUID: URL] = [:]

    init(bootstrap: AppBootstrap, model: WorkspaceViewModel, recoveryCatalogRoot: URL? = nil) {
        services = bootstrap
        documentsRoot = (recoveryCatalogRoot ?? bootstrap.persistenceController.recoveryProjectURL.deletingLastPathComponent())
            .appendingPathComponent("Documents", isDirectory: true)
        let id = UUID(); activeID = id
        attach(.init(id: id, model: model, bootstrap: bootstrap))
        refreshRecoverable()
    }

    private func attach(_ session: Session) {
        sessions.append(session)
        session.model.createDocumentInNewSession = { [weak self] name, size, dpi, format, colorSpace in
            self?.create(name: name, size: size, dpi: dpi, format: format, colorSpace: colorSpace)
        }
        session.model.importExchangeInNewSession = { [weak self] opened, url in self?.importExchange(opened, from: url) }
        session.model.openDocumentInNewSession = { [weak self] url in self?.open(url) }
        session.model.recoverDocumentInNewSession = { [weak self] root in
            self?.recover(.init(id: root, name: "恢复画稿"))
        }
        relays[session.id] = session.model.objectWillChange.sink { [weak self] _ in
            // Forward after the model has published its new values, including dirty/title changes.
            Task { @MainActor [weak self] in self?.objectWillChange.send() }
        }
    }

    @discardableResult
    func activate(_ id: UUID) -> Bool {
        guard id != activeID else { return true }
        guard sessions.contains(where: { $0.id == id }), active.prepareForDocumentTabSwitch() else { return false }
        active.isSessionActive = false
        active.pauseDrawingStatsTracking()
        active.closeReferenceImageFloatingPanel()
        activeID = id
        active.isSessionActive = true
        active.projectAccess.refreshRecent()
        onActiveChange?(active)
        return true
    }

    private func makeSession(recoveryRoot: URL? = nil) throws -> Session {
        let id = UUID()
        var state = active.workspace
        state.document = .stageOneDefault()
        state.document.canvasSize = .init(width: 16, height: 16)
        state.selection = .empty; state.viewport = .stageOneDefault
        let bootstrap = try AppBootstrap(workspaceStore: .init(state: state), metalContext: services.metalContext,
            brushLibraryPersistenceController: services.brushLibraryPersistenceController,
            patternLibraryPersistenceController: services.patternLibraryPersistenceController,
            textureFillLibraryPersistenceController: services.textureFillLibraryPersistenceController,
            blockReferenceModuleLibraryPersistenceController: services.blockReferenceModuleLibraryPersistenceController,
            sharedMetalServices: services.sharedMetalServices,
            libraryServices: services.libraryServices,
            documentFiles: services.documentFiles,
            persistenceRecoveryRootURL: recoveryRoot ?? documentsRoot.appendingPathComponent(id.uuidString, isDirectory: true))
        let model = WorkspaceViewModel(bootstrap: bootstrap)
        bootstrap.drawingStatsController.milestoneHandler = { [weak model] in model?.showDrawingStatsMilestone($0) }
        model.isSessionActive = false
        return .init(id: id, model: model, bootstrap: bootstrap)
    }

    func create(name: String, size: CanvasSize, dpi: Int, format: ArtPixelFormat, colorSpace: ArtColorSpace = .sRGB) {
        guard active.prepareForDocumentTabSwitch(), !isClosing else { return }
        do {
            active.refreshProcessResourceUsage()
            let reservation = try services.metalContext.workingResourceBudget.reserve(
                bytes: size.width * size.height * format.encoding.bytesPerPixel * 2,
                residentBytes: services.metalContext.device.currentAllocatedSize)
            defer { withExtendedLifetime(reservation) {} }
            let session = try makeSession()
            session.model.createNewCanvasDiscardingUnsavedChanges(name: name, canvasSize: size, resolutionDPI: dpi, pixelFormat: format, colorSpace: colorSpace)
            guard session.model.workspace.document.canvasSize == size else { return }
            active.dismissNewCanvasSheet()
            attach(session)
            _ = activate(session.id)
        } catch { active.presentWorkspaceStatus(kind: .error, message: error.localizedDescription) }
    }

    func open(_ url: URL) {
        if let owner = services.documentFiles.owner(of: url), let existing = sessions.first(where: { $0.model === owner }) {
            _ = activate(existing.id); return
        }
        guard active.prepareForDocumentTabSwitch(), !isClosing else { return }
        do {
            let previousID = activeID
            let session = try makeSession()
            attach(session)
            guard activate(session.id) else { remove(session.id); return }
            session.model.loadProjectForDocumentSession(from: url) { [weak self, weak model = session.model] status in
                guard let self, self.sessions.contains(where: { $0.id == session.id }) else { return }
                let wasActive = self.activeID == session.id
                model?.finishDocumentSessionClose()
                self.remove(session.id)
                if wasActive { _ = self.activate(previousID) }
                self.active.presentWorkspaceStatus(kind: status.kind, message: status.message)
            }
        } catch { active.presentWorkspaceStatus(kind: .error, message: error.localizedDescription) }
    }

    func importExchange(_ opened: OpenProjectResult, from url: URL) {
        guard active.prepareForDocumentTabSwitch(), !isClosing else { return }
        do {
            let session = try makeSession()
            try session.model.applyImportedExchange(opened, sourceURL: url)
            attach(session)
            _ = activate(session.id)
        } catch { active.presentWorkspaceStatus(kind: .error, message: error.localizedDescription) }
    }

    func close(_ id: UUID) {
        guard !isClosing, activate(id), let session = sessions.first(where: { $0.id == id }) else { return }
        isClosing = true
        session.model.confirmCloseOrQuitIfNeeded { [weak self] allowed in
            guard let self else { return }
            self.isClosing = false
            guard allowed else { return }
            do {
                // Keep one empty workspace so the established app shell remains available.
                if self.sessions.count == 1 {
                    let replacement = try self.makeSession()
                    replacement.model.createNewCanvasDiscardingUnsavedChanges(name: "未命名", canvasSize: .stageOneDefault,
                        resolutionDPI: 300, pixelFormat: .rgba8)
                    self.attach(replacement)
                }
                session.model.finishDocumentSessionClose()
                self.remove(id)
            } catch { session.model.presentWorkspaceStatus(kind: .error, message: error.localizedDescription) }
        }
    }

    private func remove(_ id: UUID) {
        sessions.removeAll { $0.id == id }; relays[id] = nil
        recoverySources[id] = nil
        if activeID == id, let first = sessions.first {
            activeID = first.id; first.model.isSessionActive = true
            first.model.projectAccess.refreshRecent()
            onActiveChange?(first.model)
        }
        refreshRecoverable()
    }

    func confirmCloseAll(completion: @escaping (Bool) -> Void) {
        guard !isClosing else { completion(false); return }
        isClosing = true
        pendingQuitCompletion = completion
        let ids = sessions.map(\.id)
        func next(_ index: Int) {
            guard index < ids.count else {
                self.services.libraryServices.writes.drain { failure in
                    Task { @MainActor in
                        self.isClosing = false
                        if let failure {
                            self.active.presentWorkspaceStatus(kind: .error, message: "素材库尚未保存，退出已取消：\(failure)")
                            self.pendingQuitCompletion?(false)
                        } else {
                            self.sessions.forEach { $0.model.finishDocumentSessionClose() }
                            self.pendingQuitCompletion?(true)
                        }
                        self.pendingQuitCompletion = nil
                    }
                }
                return
            }
            guard self.activate(ids[index]) else { self.isClosing = false; completion(false); return }
            self.active.confirmCloseOrQuitIfNeeded { allowed in
                guard allowed else { self.isClosing = false; completion(false); return }
                next(index + 1)
            }
        }
        next(0)
    }

    /// Full structural transfer uses the existing selective import transaction. It never mutates
    /// the source; mismatched canvas/working-space cases are rejected by the shared import policy.
    func copyActiveLayer(to destinationID: UUID) {
        guard !isTransferring, let destination = sessions.first(where: { $0.id == destinationID }), destinationID != activeID else { return }
        let source = active
        let selected = source.workspace.document.activeLayerID
        let version = destination.model.branchDocumentVersion
        do {
            let capture = try source.captureForBranch()
            let persistence = WorkspaceUncheckedBox(services.persistenceController)
            isTransferring = true
            Task { [weak self, weak source] in
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try persistence.value.materializeProjectPayload(from: capture.waitUntilReady()) }
                }.value
                guard let self else { return }
                self.isTransferring = false
                do {
                    let payload = try result.get()
                    guard self.sessions.contains(where: { $0.id == destinationID }) else { return }
                    if destination.model.importBranchLayers(payload, selected: [selected], name: "来自 \(payload.package.document.metadata.name)", expectedVersion: version) {
                        source?.presentWorkspaceStatus(kind: .success, message: "已复制图层到 \(destination.model.workspace.document.metadata.name)")
                    } else {
                        source?.presentWorkspaceStatus(kind: .error, message: destination.model.status?.message ?? "图层复制未完成，目标文档保持不变")
                    }
                } catch { source?.presentWorkspaceStatus(kind: .error, message: error.localizedDescription) }
            }
        } catch { source.presentWorkspaceStatus(kind: .error, message: error.localizedDescription) }
    }

    func refreshRecoverable() {
        let roots = RecoveryCatalog.roots(in: documentsRoot.deletingLastPathComponent())
        recoverable = roots.compactMap { root in
            let key = RecoveryCatalog.identity(root)
            guard !sessions.contains(where: { RecoveryCatalog.identity($0.bootstrap.persistenceController.recoveryProjectURL.deletingLastPathComponent()) == key }),
                  !recoverySources.values.contains(where: { RecoveryCatalog.identity($0) == key }) else { return nil }
            let name = RecoveryCatalog.candidates(in: root).lazy.compactMap {
                try? self.services.persistenceController.inspectProject(from: $0).workspace.document.metadata.name
            }.first ?? "未完成的画稿"
            return Recoverable(id: root, name: name)
        }
    }

    func recover(_ entry: Recoverable) {
        guard active.prepareForDocumentTabSwitch(), !isClosing else { return }
        do {
            let previousID = activeID
            let session = try makeSession()
            attach(session)
            guard activate(session.id) else { remove(session.id); return }
            session.model.loadRecoveryForDocumentSession(from: entry.id) { [weak self] in
                self?.recoverySources[session.id] = entry.id
                self?.refreshRecoverable()
            } onFailure: { [weak self, weak model = session.model] status in
                guard let self else { return }
                model?.finishDocumentSessionClose()
                self.remove(session.id)
                _ = self.activate(previousID)
                self.active.presentWorkspaceStatus(kind: status.kind, message: status.message)
            }
        } catch { active.presentWorkspaceStatus(kind: .error, message: error.localizedDescription) }
    }
}

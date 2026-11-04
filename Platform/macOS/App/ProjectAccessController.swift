import AppKit
import Combine

/// Owns platform recent-document integration and read-only recovery inspection.
@MainActor
final class ProjectAccessController: ObservableObject {
    @Published private(set) var recentURLs: [URL] = NSDocumentController.shared.recentDocumentURLs
    @Published private(set) var recovery: RecoveryProjectSummary?
    @Published private(set) var recoveryError: String?
    @Published private(set) var inspecting = false
    private var request = UUID()

    func record(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        refreshRecent()
    }
    func refreshRecent() { recentURLs = NSDocumentController.shared.recentDocumentURLs }
    func clearRecent() { NSDocumentController.shared.clearRecentDocuments(nil); refreshRecent() }

    func inspectRecovery(using persistence: PersistenceController) {
        guard !inspecting else { return }
        inspecting = true
        recovery = nil
        recoveryError = nil
        let id = UUID()
        request = id
        let worker = WorkspaceUncheckedBox(persistence)
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { Result { try worker.value.recoverySummary() } }.value
            guard let self, self.request == id else { return }
            self.inspecting = false
            switch result {
            case .success(let summary): self.recovery = summary
            case .failure(let error): self.recoveryError = error.localizedDescription
            }
        }
    }
}

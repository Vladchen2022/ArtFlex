import Foundation
import ArtFlexLifecycle

enum ProjectOpenCompletion {
    case loaded(URL, OpenProjectResult)
    case documentChanged
    case failed(Error)
}

/// Owns background validation and suppresses results from replaced or edited documents.
@MainActor
final class ProjectOpenCoordinator {
    private var task: Task<Void, Never>?
    var isOpening: Bool { task != nil }
    var onStateChange: (() -> Void)?
    deinit { task?.cancel() }

    @discardableResult
    func start(from url: URL?, isRecovery: Bool, persistence: PersistenceController,
               policy: DocumentResourceBudgetPolicy, currentResidentBytes: Int,
               lifecycle: DocumentLifecycleCoordinator,
               completion: @escaping (ProjectOpenCompletion) -> Void) -> Bool {
        guard task == nil else { return false }
        let expected = lifecycle.version
        let reader = ProjectOpenReader(controller: persistence)
        task = Task { [weak self, weak lifecycle] in
            let result = await Task.detached(priority: .userInitiated) {
                Result<(URL, OpenProjectResult), Error> {
                    let preflight: (ProjectOpenInspection) throws -> Void = { inspection in
                        let assessment = policy.assess(canvasSize: inspection.workspace.document.canvasSize,
                            paintLayerCount: inspection.workspace.document.paintLayers.count,
                            maskCount: inspection.workspace.document.paintLayers.filter { $0.mask != nil }.count,
                            savedSnapshotCount: inspection.savedSnapshotCount,
                            referenceImageBytes: inspection.referenceArchiveBytes,
                            referenceImageResidentBytes: inspection.estimatedReferenceResidentBytes,
                            pixelFormat: inspection.workspace.document.colorStandard.pixelFormat)
                        guard assessment.isSupported else {
                            throw PersistenceError.invalidProject(assessment.rejectionReason ?? "工程超出当前设备的安全资源范围")
                        }
                        let (peak, overflow) = assessment.footprint.estimatedSavePeakBytes.addingReportingOverflow(currentResidentBytes)
                        guard !overflow, peak <= policy.maximumSavePeakBytes else {
                            throw PersistenceError.invalidProject("打开工程时，新旧文档同时驻留会超过安全内存峰值")
                        }
                    }
                    if isRecovery {
                        let opened = try reader.controller.openBestAvailableRecoveryProject(preflight: preflight)
                        return (opened.url, opened.result)
                    }
                    guard let url else { throw CocoaError(.fileNoSuchFile) }
                    return (url, try reader.controller.openProject(from: url, preflight: preflight))
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.task = nil
            self.onStateChange?()
            guard let lifecycle, lifecycle.version == expected else { completion(.documentChanged); return }
            switch result {
            case .success(let opened): completion(.loaded(opened.0, opened.1))
            case .failure(let error): completion(.failed(error))
            }
        }
        onStateChange?()
        return true
    }
}

private final class ProjectOpenReader: @unchecked Sendable {
    let controller: PersistenceController
    init(controller: PersistenceController) { self.controller = controller }
}

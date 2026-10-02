import Foundation
import ArtFlexLifecycle

/// Owns recovery scheduling, staging writes and installation validity. Pixel capture stays
/// at the main-actor editing boundary; this worker only receives frozen resources.
@MainActor
final class RecoveryAutosaveCoordinator {
    let schedule = RecoveryAutosaveSchedule()
    private let persistence: RecoveryPersistenceWorker
    private let lifecycle: DocumentLifecycleCoordinator
    private var writeTask: Task<Void, Never>?
    private var invalidationGeneration: UInt64 = 0
    var isWriting: Bool { writeTask != nil }
    var suppressScheduling = false
    var waitingForTimelapse = false
    var manualSaveAfterWrite = false
    var manualSaveAfterTimelapse = false
    var onWriteFinished: ((Result<Bool, Error>) -> Void)?
#if DEBUG
    var beforeInstall: (() -> Void)?
#endif

    init(persistence: PersistenceController, lifecycle: DocumentLifecycleCoordinator) {
        self.persistence = RecoveryPersistenceWorker(controller: persistence)
        self.lifecycle = lifecycle
    }

    func invalidate(resetDeadline: Bool = true) {
        invalidationGeneration &+= 1
        schedule.cancel(resetDeadline: resetDeadline)
    }

    func dirtyStateChanged(_ dirty: Bool) {
        if !dirty { invalidate() }
        else if !suppressScheduling { schedule.schedule() }
    }

    @discardableResult
    func write(_ capture: FrozenRecoveryCapture, scheduleGeneration: UInt64) throws -> Bool {
        guard !isWriting else { return false }
        let stagingURL = try persistence.controller.makeRecoveryStagingURL()
        let persistence = persistence
        let expectedInvalidation = invalidationGeneration
        let documentGeneration = lifecycle.version.generation
        writeTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { try persistence.controller.writeIncrementalRecovery(capture, to: stagingURL) }
            }.value
            guard let self else {
                persistence.controller.discardRecoveryStagingProject(at: stagingURL)
                return
            }
            self.writeTask = nil
#if DEBUG
            self.beforeInstall?()
#endif
            guard self.lifecycle.isDirty,
                  self.lifecycle.version.generation == documentGeneration,
                  self.invalidationGeneration == expectedInvalidation else {
                persistence.controller.discardRecoveryStagingProject(at: stagingURL)
                self.onWriteFinished?(.success(false))
                return
            }
            do {
                try result.get()
                try persistence.controller.installRecoveryProject(from: stagingURL)
                self.schedule.didInstallCapture()
                if self.schedule.generation != scheduleGeneration { self.schedule.schedule() }
                self.onWriteFinished?(.success(true))
            } catch {
                persistence.controller.discardRecoveryStagingProject(at: stagingURL)
                persistence.controller.invalidateIncrementalRecoveryBase()
                self.schedule.schedule()
                self.onWriteFinished?(.failure(error))
            }
        }
        return true
    }
}

private final class RecoveryPersistenceWorker: @unchecked Sendable {
    let controller: PersistenceController
    init(controller: PersistenceController) { self.controller = controller }
}

import ArtFlexLifecycle
import Foundation
import Testing

@MainActor
struct DocumentLifecycleCoordinatorTests {
    @Test func oldSaveCannotClearNewEditsOrChangeAnotherDocumentPath() {
        let lifecycle = DocumentLifecycleCoordinator()
        lifecycle.setDirty(true)
        let captured = lifecycle.version
        lifecycle.setDirty(true)
        let url = URL(fileURLWithPath: "/tmp/captured.artflex")
        #expect(!lifecycle.acceptSave(of: captured, to: url))
        #expect(lifecycle.isDirty && lifecycle.projectURL == url)
        lifecycle.didReplaceDocument()
        lifecycle.projectURL = nil
        #expect(!lifecycle.acceptSave(of: captured, to: url))
        #expect(lifecycle.projectURL == nil && lifecycle.isDirty)
    }

    @Test func editDuringDiscardConfirmationRejectsTheOldDecision() {
        let lifecycle = DocumentLifecycleCoordinator()
        lifecycle.setDirty(true)
        var reply: ((DocumentTransitionDecision) -> Void)?
        var results: [Bool] = []
        lifecycle.confirmTransition(hasPendingEdits: false, isBusy: false,
            presentDecision: { reply = $0 }, save: { _ in Issue.record("Unexpected save") },
            completion: { results.append($0) })
        lifecycle.setDirty(true)
        reply?(.discard)
        reply?(.discard)
        #expect(results == [false])
        #expect(!lifecycle.isTransitionPending && lifecycle.isDirty)
    }

    @Test func repeatedPromptsAndSaveCallbacksFinishOnlyOnceAndPermitRetry() {
        let lifecycle = DocumentLifecycleCoordinator()
        lifecycle.setDirty(true)
        var reply: ((DocumentTransitionDecision) -> Void)?
        var saved: ((Bool) -> Void)?
        var results: [Bool] = []
        lifecycle.confirmTransition(hasPendingEdits: false, isBusy: false,
            presentDecision: { reply = $0 }, save: { saved = $0 }, completion: { results.append($0) })
        var duplicate: Bool?
        lifecycle.confirmTransition(hasPendingEdits: false, isBusy: false,
            presentDecision: { _ in Issue.record("Duplicate prompt") }, save: { _ in }, completion: { duplicate = $0 })
        #expect(duplicate == false)
        reply?(.save)
        reply?(.discard)
        saved?(false)
        saved?(true)
        #expect(results == [false])
        #expect(!lifecycle.isTransitionPending)
        lifecycle.confirmTransition(hasPendingEdits: false, isBusy: false,
            presentDecision: { $0(.save) }, save: { finish in lifecycle.setDirty(false); finish(true) },
            completion: { results.append($0) })
        #expect(results == [false, true])
    }

    @Test func ownerReleaseStillRejectsTransitionExactlyOnce() {
        var lifecycle: DocumentLifecycleCoordinator? = .init()
        lifecycle?.setDirty(true)
        var saved: ((Bool) -> Void)?
        var results: [Bool] = []
        lifecycle?.confirmTransition(hasPendingEdits: false, isBusy: false,
            presentDecision: { $0(.save) }, save: { saved = $0 }, completion: { results.append($0) })
        lifecycle = nil
        saved?(true)
        saved?(true)
        #expect(results == [false])
    }

    @Test func cancelledRecoveryScheduleCannotDeliverAnOldDeadline() async throws {
        let schedule = RecoveryAutosaveSchedule(maximumDeferral: .seconds(1))
        var fired: [UInt64] = []
        schedule.onDeadline = { fired.append($0) }
        schedule.schedule(delay: .milliseconds(10))
        schedule.cancel()
        try await Task.sleep(for: .milliseconds(25))
        #expect(fired.isEmpty && !schedule.isScheduled)
        schedule.schedule(delay: .zero)
        let current = schedule.generation
        for _ in 0..<500 {
            if !fired.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fired == [current])
    }
}

import Foundation
import Testing
@testable import ArtFlex

@MainActor
struct ProjectSaveCoordinatorTests {
    private func request() -> ProjectSaveRequest {
        .init(url: URL(fileURLWithPath: "/unused/test.artflex"),
              capture: .init(workspace: .stageOneDefault, layerDescriptors: [], referenceImages: [], savedSnapshots: [], hasPreviewTexture: false, textureBatch: .init(textures: [])),
              savedDocumentName: "test", editRevision: 3, documentGeneration: 2)
    }

    @Test func duplicateIsRejectedAndFailureAllowsRetryFromCompletion() async throws {
        let coordinator = ProjectSaveCoordinator { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        var completions = 0
        var rejectedCompletion = false
        let request = request()
        let accepted = coordinator.start(request) { result in
            #expect(!coordinator.isSaving)
            #expect(throws: (any Error).self) { try result.get() }
            completions += 1
            #expect(coordinator.start(request) { _ in completions += 1 })
        }
        #expect(accepted)
        #expect(coordinator.isSaving)
        #expect(!coordinator.start(request) { _ in rejectedCompletion = true })
        for _ in 0..<500 where completions != 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(completions == 2)
        #expect(!rejectedCompletion)
        #expect(!coordinator.isSaving)
    }

    @Test func acceptedWriteReportsCompletionEvenWhenOwnerIsReleased() async throws {
        var coordinator: ProjectSaveCoordinator? = .init { _, _ in
            .init(previewPNGData: nil, versionBackupURL: nil, versionBackupWarning: nil)
        }
        var completed = false
        let accepted = coordinator?.start(request()) { result in
            if case let .success(outcome) = result { #expect(outcome.versionBackupWarning == nil) }
            else { Issue.record("Expected completed write") }
            completed = true
        }
        #expect(accepted == true)
        coordinator = nil
        for _ in 0..<500 where !completed { try await Task.sleep(for: .milliseconds(10)) }
        #expect(completed)
    }
}

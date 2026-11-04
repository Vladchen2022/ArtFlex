import Foundation
import Testing
@testable import ArtFlex

@MainActor
struct LatestPreviewCoordinatorTests {
    @Test func cancellationStopsRunningWorkAndOnlyLatestPublishes() async throws {
        let coordinator = LatestPreviewCoordinator<Int>()
        let started = WorkCancellation()
        let stopped = WorkCancellation()
        var published: [Int] = []
        coordinator.submit(delay: .zero) { token in
            started.cancel()
            defer { stopped.cancel() }
            while !token.isCancelled { Thread.sleep(forTimeInterval: 0.001) }
            try token.check()
            return 1
        } completion: { if case .success(let value) = $0 { published.append(value) } }
        for _ in 0..<500 where !started.isCancelled { try await Task.sleep(for: .milliseconds(5)) }
        try #require(started.isCancelled)
        coordinator.submit(delay: .zero) { _ in 2 } completion: { if case .success(let value) = $0 { published.append(value) } }
        for _ in 0..<500 where published.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(stopped.isCancelled)
        #expect(published == [2])
    }

    @Test func cancellingQueuedWorkPreventsPublication() async throws {
        let coordinator = LatestPreviewCoordinator<Int>()
        var published = false
        coordinator.submit { _ in 7 } completion: { _ in published = true }
        coordinator.cancel()
        try await Task.sleep(for: .milliseconds(120))
        #expect(!published)
    }
}

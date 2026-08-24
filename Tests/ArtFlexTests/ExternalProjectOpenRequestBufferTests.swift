import Foundation
import Testing
@testable import ArtFlex

@Suite("External project open requests")
struct ExternalProjectOpenRequestBufferTests {
    @Test
    func buffersFinderRequestUntilWorkspaceIsReady() {
        let projectURL = URL(fileURLWithPath: "/tmp/ColdLaunch.artflex")
        var buffer = ExternalProjectOpenRequestBuffer()

        #expect(buffer.receive([projectURL], isHandlerReady: false) == nil)
        #expect(buffer.pendingURL == projectURL.standardizedFileURL)
        #expect(buffer.takePendingURL() == projectURL.standardizedFileURL)
        #expect(buffer.takePendingURL() == nil)
    }

    @Test
    func returnsProjectImmediatelyAfterWorkspaceIsReady() {
        let projectURL = URL(fileURLWithPath: "/tmp/AlreadyRunning.artflex")
        var buffer = ExternalProjectOpenRequestBuffer()

        #expect(buffer.receive([projectURL], isHandlerReady: true) == projectURL.standardizedFileURL)
        #expect(buffer.pendingURL == nil)
    }

    @Test
    func rejectsUnrelatedFilesAndNormalizesLegacyPackageDescendants() {
        var buffer = ExternalProjectOpenRequestBuffer()
        let unrelatedURL = URL(fileURLWithPath: "/tmp/Image.png")
        let manifestURL = URL(fileURLWithPath: "/tmp/Legacy.artflex/manifest.json")

        #expect(buffer.receive([unrelatedURL], isHandlerReady: true) == nil)
        #expect(
            buffer.receive([manifestURL], isHandlerReady: true)
                == URL(fileURLWithPath: "/tmp/Legacy.artflex", isDirectory: true).standardizedFileURL
        )
    }
}

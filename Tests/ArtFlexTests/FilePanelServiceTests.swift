import Foundation
import Testing
@testable import ArtFlex

@Suite("Project open URL normalization")
struct FilePanelServiceTests {
    @Test("accepts a project package root")
    func acceptsProjectPackageRoot() {
        let root = URL(fileURLWithPath: "/tmp/Example.artflex", isDirectory: true)
        #expect(FilePanelService.normalizedProjectOpenURL(root) == root.standardizedFileURL)
    }

    @Test("recovers the package root after entering its contents")
    func recoversPackageRootFromChild() {
        let manifest = URL(fileURLWithPath: "/tmp/Example.artflex/manifest.json")
        let layers = URL(fileURLWithPath: "/tmp/Example.artflex/layers", isDirectory: true)
        let expected = URL(fileURLWithPath: "/tmp/Example.artflex", isDirectory: true).standardizedFileURL

        #expect(FilePanelService.normalizedProjectOpenURL(manifest) == expected)
        #expect(FilePanelService.normalizedProjectOpenURL(layers) == expected)
    }

    @Test("keeps legacy JSON files and rejects unrelated directories")
    func handlesLegacyAndUnrelatedURLs() {
        let legacy = URL(fileURLWithPath: "/tmp/Legacy.artflex.json")
        let unrelated = URL(fileURLWithPath: "/tmp/OrdinaryFolder", isDirectory: true)

        #expect(FilePanelService.normalizedProjectOpenURL(legacy) == legacy.standardizedFileURL)
        #expect(FilePanelService.normalizedProjectOpenURL(unrelated) == nil)
    }
}

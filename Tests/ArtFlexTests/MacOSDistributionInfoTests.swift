import Foundation
import Testing
@testable import ArtFlex

@Suite("macOS distribution metadata")
struct MacOSDistributionInfoTests {
    @Test
    func declaresArtFlexDocumentsAsOwnedEditableFiles() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoURL = projectRoot.appendingPathComponent("Platform/macOS/Distribution/Info.plist")
        let data = try Data(contentsOf: infoURL)
        let propertyList = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let documentTypes = try #require(propertyList["CFBundleDocumentTypes"] as? [[String: Any]])
        let projectDocument = try #require(documentTypes.first)
        let exportedTypes = try #require(propertyList["UTExportedTypeDeclarations"] as? [[String: Any]])
        let projectType = try #require(exportedTypes.first)
        let tags = try #require(projectType["UTTypeTagSpecification"] as? [String: Any])

        #expect(projectDocument["CFBundleTypeRole"] as? String == "Editor")
        #expect(projectDocument["LSHandlerRank"] as? String == "Owner")
        #expect(
            (projectDocument["LSItemContentTypes"] as? [String])?
                .contains("com.vladchen.artflex.project") == true
        )
        #expect(projectType["UTTypeIdentifier"] as? String == "com.vladchen.artflex.project")
        #expect((projectType["UTTypeConformsTo"] as? [String])?.contains("public.data") == true)
        #expect((tags["public.filename-extension"] as? [String]) == ["artflex"])
    }
}

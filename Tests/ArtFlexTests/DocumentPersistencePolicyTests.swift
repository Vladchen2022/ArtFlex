import ArtFlexPolicies
import Testing

struct DocumentPersistencePolicyTests {
    @Test func unfinishedPreviewsBlockBothSaveEntrances() {
        let cases: [(PersistenceEditingActivity, PersistenceEditingBlocker)] = [
            (.historyPreview, .historyPreview), (.pixelCommit, .pixelCommit), (.transform, .transform),
            (.snapshotOrExport, .snapshotOrExport), (.pattern, .pattern), (.gradient, .gradient),
            (.gesture, .gesture)
        ]
        for (activity, reason) in cases {
            #expect(DocumentPersistencePolicy.manualBlocker(for: activity) == reason)
            #expect(DocumentPersistencePolicy.blocksAutomaticCapture(activity))
        }
    }

    @Test func automaticCaptureDoesNotResolveToolsButManualSaveCan() {
        for activity: PersistenceEditingActivity in [.adjustment, .pendingLine, .brushInput] {
            #expect(DocumentPersistencePolicy.manualBlocker(for: activity) == nil)
            #expect(DocumentPersistencePolicy.blocksAutomaticCapture(activity))
        }
        #expect(DocumentPersistencePolicy.manualBlocker(for: []) == nil)
        #expect(!DocumentPersistencePolicy.blocksAutomaticCapture([]))
        #expect(DocumentPersistencePolicy.manualBlocker(for: [.crop, .gradient, .historyPreview]) == .historyPreview)
        #expect(DocumentPersistencePolicy.manualBlocker(for: .crop) == .crop)
        #expect(!DocumentPersistencePolicy.blocksAutomaticCapture(.crop))
    }
}

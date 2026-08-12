import Foundation
import Testing
@testable import ArtFlex

struct VisibleHistoryMetadataTests {
    @Test
    func metadataDeduplicatesAffectedLayersWithoutReordering() {
        let first = LayerID()
        let second = LayerID()
        let metadata = VisibleHistoryEntryMetadata(
            actionKey: "brush.commit",
            affectedLayerIDs: [first, second, first]
        )

        #expect(metadata.affectedLayerIDs == [first, second])
    }

    @Test
    func timelinePlansSequentialUndoAndRedoNavigation() throws {
        let actionA = VisibleHistoryEntryMetadata(actionKey: "a")
        let actionB = VisibleHistoryEntryMetadata(actionKey: "b")
        let actionC = VisibleHistoryEntryMetadata(actionKey: "c")
        let actionD = VisibleHistoryEntryMetadata(actionKey: "d")
        let actionE = VisibleHistoryEntryMetadata(actionKey: "e")
        let timeline = VisibleHistoryTimeline(
            appliedEntries: [actionA, actionB, actionC],
            redoEntries: [actionD, actionE]
        )

        let toA = try #require(timeline.navigationPlan(to: actionA.id))
        #expect(toA.undoStepCount == 2)
        #expect(toA.redoStepCount == 0)
        #expect(toA.direction == .undo)

        let toC = try #require(timeline.navigationPlan(to: actionC.id))
        #expect(toC.totalStepCount == 0)
        #expect(toC.direction == .none)

        let toD = try #require(timeline.navigationPlan(to: actionD.id))
        #expect(toD.undoStepCount == 0)
        #expect(toD.redoStepCount == 1)
        #expect(toD.direction == .redo)

        let toE = try #require(timeline.navigationPlan(to: actionE.id))
        #expect(toE.redoStepCount == 2)
        #expect(timeline.navigationPlan(to: UUID()) == nil)
    }

    @Test
    func navigationPlanRejectsAmbiguousOrNegativeCounts() {
        let targetID = UUID()
        #expect(VisibleHistoryNavigationPlan(
            targetEntryID: targetID,
            undoStepCount: 1,
            redoStepCount: 1
        ) == nil)
        #expect(VisibleHistoryNavigationPlan(
            targetEntryID: targetID,
            undoStepCount: -1,
            redoStepCount: 0
        ) == nil)
    }

    @Test
    func timelineAndMetadataRoundTripThroughCodable() throws {
        let layerID = LayerID()
        let timestamp = Date(timeIntervalSince1970: 1_725_000_000)
        let entry = VisibleHistoryEntryMetadata(
            id: UUID(),
            actionKey: "curveAdjustment.commit",
            createdAt: timestamp,
            affectedLayerIDs: [layerID]
        )
        let timeline = VisibleHistoryTimeline(appliedEntries: [entry])

        let data = try JSONEncoder().encode(timeline)
        #expect(try JSONDecoder().decode(VisibleHistoryTimeline.self, from: data) == timeline)
    }

    @Test
    func timelineExposesNewestFirstDisplayAndScrubbingPlans() throws {
        let actionA = VisibleHistoryEntryMetadata(actionKey: "a")
        let actionB = VisibleHistoryEntryMetadata(actionKey: "b")
        let actionC = VisibleHistoryEntryMetadata(actionKey: "c")
        let actionD = VisibleHistoryEntryMetadata(actionKey: "d")
        let timeline = VisibleHistoryTimeline(
            appliedEntries: [actionA, actionB],
            redoEntries: [actionC, actionD]
        )

        #expect(timeline.newestFirstEntries.map(\.id) == [actionD.id, actionC.id, actionB.id, actionA.id])
        #expect(timeline.currentAppliedEntryCount == 2)
        #expect(timeline.totalEntryCount == 4)

        let toInitial = try #require(timeline.navigationPlan(toAppliedEntryCount: 0))
        #expect(toInitial.undoStepCount == 2)
        let toLatest = try #require(timeline.navigationPlan(toAppliedEntryCount: 4))
        #expect(toLatest.redoStepCount == 2)
        #expect(timeline.navigationPlan(toAppliedEntryCount: 5) == nil)
    }
}

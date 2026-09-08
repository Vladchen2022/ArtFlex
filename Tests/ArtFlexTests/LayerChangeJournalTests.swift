import Testing
@testable import ArtFlex

struct LayerChangeJournalTests {
    @Test func independentConsumersAndLateWritesNeverLoseChanges() {
        let size = CanvasSize(width: 1200, height: 1000)
        var journal = LayerChangeJournal()
        let first = journal.cursor
        #expect(journal.changedRegions(since: nil, canvasSize: size).count == 6)
        journal.mark(.init(originX: 510, originY: 2, width: 6, height: 5), canvasSize: size)
        let second = journal.cursor
        #expect(journal.changedRegions(since: first, canvasSize: size).count == 2)
        journal.mark(.init(originX: 1190, originY: 990, width: 20, height: 20), canvasSize: size)
        #expect(journal.changedRegions(since: second, canvasSize: size) == [.init(originX: 1024, originY: 512, width: 176, height: 488)])
        #expect(journal.changedRegions(since: first, canvasSize: size).count == 3)
        journal.markAll()
        #expect(journal.changedRegions(since: second, canvasSize: size).count == 6)
        #expect(journal.changedRegions(since: journal.cursor, canvasSize: size).isEmpty)
    }
}

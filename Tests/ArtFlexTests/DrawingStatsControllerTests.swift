import Foundation
import Testing
@testable import ArtFlex

struct DrawingStatsControllerTests {
    @Test
    @MainActor
    func gracePeriodExtendsActivePaintingSession() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let controller = DrawingStatsController(
            persistenceController: DrawingStatsPersistenceController(baseDirectoryURL: tempDirectory),
            gracePeriod: 60,
            enablesLiveTimer: false
        )
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        controller.syncCurrentDocument(id: UUID(), name: "未命名", accumulatedPaintingTime: 0, now: start)
        controller.recordPaintingActivity(at: start)
        controller.recordPaintingActivity(at: start.addingTimeInterval(10))

        controller.flushIfGraceExpired(at: start.addingTimeInterval(69))
        #expect(abs(controller.snapshot.currentDocumentTime - 69) < 0.001)

        controller.flushIfGraceExpired(at: start.addingTimeInterval(70))
        #expect(abs(controller.snapshot.totalPaintingTime - 70) < 0.001)
        #expect(abs(controller.snapshot.currentDocumentTime - 70) < 0.001)
        #expect(abs(controller.snapshot.todayPaintingTime - 70) < 0.001)
        #expect(controller.snapshot.hasActivityToday)
    }

    @Test
    @MainActor
    func pauseTrackingStopsImmediatelyWithoutExtraGrace() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let controller = DrawingStatsController(
            persistenceController: DrawingStatsPersistenceController(baseDirectoryURL: tempDirectory),
            gracePeriod: 60,
            enablesLiveTimer: false
        )
        let start = Date(timeIntervalSince1970: 1_710_000_000)

        controller.syncCurrentDocument(id: UUID(), name: "作品 A", accumulatedPaintingTime: 0, now: start)
        controller.recordPaintingActivity(at: start)
        controller.pauseTracking(at: start.addingTimeInterval(20))

        #expect(abs(controller.snapshot.totalPaintingTime - 20) < 0.001)
        #expect(abs(controller.snapshot.currentDocumentTime - 20) < 0.001)
        #expect(controller.snapshot.isActiveSessionRunning == false)
    }

    @Test
    @MainActor
    func repeatedPaintingActivityDefersSnapshotRefreshToTimerOrFlush() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let controller = DrawingStatsController(
            persistenceController: DrawingStatsPersistenceController(baseDirectoryURL: tempDirectory),
            gracePeriod: 60,
            enablesLiveTimer: false
        )
        let start = Date(timeIntervalSince1970: 1_715_000_000)

        controller.syncCurrentDocument(id: UUID(), name: "作品", accumulatedPaintingTime: 0, now: start)
        controller.recordPaintingActivity(at: start)
        controller.recordPaintingActivity(at: start.addingTimeInterval(10))

        #expect(controller.snapshot.currentDocumentTime == 0)
        controller.flushIfGraceExpired(at: start.addingTimeInterval(10))
        #expect(abs(controller.snapshot.currentDocumentTime - 10) < 0.001)
    }

    @Test
    @MainActor
    func firstHourMilestoneIsRecordedAndPersisted() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let persistenceController = DrawingStatsPersistenceController(baseDirectoryURL: tempDirectory)
        let controller = DrawingStatsController(
            persistenceController: persistenceController,
            gracePeriod: 60,
            enablesLiveTimer: false
        )
        var achievedMilestones: [String] = []
        controller.milestoneHandler = { achievedMilestone in
            achievedMilestones.append(achievedMilestone.id)
        }

        let start = Date(timeIntervalSince1970: 1_720_000_000)
        controller.syncCurrentDocument(id: UUID(), name: "作品 B", accumulatedPaintingTime: 0, now: start)
        controller.recordPaintingActivity(at: start)
        controller.pauseTracking(at: start.addingTimeInterval(3600))

        #expect(achievedMilestones.contains("total:1"))
        #expect(controller.snapshot.latestMilestone?.id == "total:1")

        let restored = DrawingStatsController(
            persistenceController: persistenceController,
            gracePeriod: 60,
            enablesLiveTimer: false
        )
        #expect(restored.snapshot.latestMilestone?.id == "total:1")
    }
}

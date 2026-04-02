import Foundation

struct DrawingStatsArchive: Codable, Sendable, Equatable {
    var totalPaintingTime: TimeInterval
    var dailyRecords: [String: TimeInterval]
    var lastActiveDate: String?
    var currentStreak: Int
    var milestones: [String]

    static let empty = DrawingStatsArchive(
        totalPaintingTime: 0,
        dailyRecords: [:],
        lastActiveDate: nil,
        currentStreak: 0,
        milestones: []
    )
}

struct DrawingStatsMilestone: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case totalHours(Int)
        case streakDays(Int)
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String

    static let all: [DrawingStatsMilestone] = (
        [1, 5, 10, 50, 100, 500].map {
            DrawingStatsMilestone(
                id: "total:\($0)",
                kind: .totalHours($0),
                title: "总绘画时长达到 \($0) 小时",
                detail: "累计创作已达到 \($0) 小时"
            )
        } +
        [3, 7, 30, 100].map {
            DrawingStatsMilestone(
                id: "streak:\($0)",
                kind: .streakDays($0),
                title: "连续创作达到 \($0) 天",
                detail: "连续创作 streak 已达到 \($0) 天"
            )
        }
    )

    static func resolve(id: String) -> DrawingStatsMilestone? {
        all.first(where: { $0.id == id })
    }
}

struct DrawingStatsSnapshot: Equatable, Sendable {
    var totalPaintingTime: TimeInterval
    var currentDocumentTime: TimeInterval
    var todayPaintingTime: TimeInterval
    var dailyRecords: [String: TimeInterval]
    var currentStreak: Int
    var hasActivityToday: Bool
    var latestMilestone: DrawingStatsMilestone?
    var currentDocumentName: String
    var isActiveSessionRunning: Bool

    static let empty = DrawingStatsSnapshot(
        totalPaintingTime: 0,
        currentDocumentTime: 0,
        todayPaintingTime: 0,
        dailyRecords: [:],
        currentStreak: 0,
        hasActivityToday: false,
        latestMilestone: nil,
        currentDocumentName: "未命名",
        isActiveSessionRunning: false
    )
}

final class DrawingStatsPersistenceController {
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let baseDirectoryURL: URL?

    init(fileManager: FileManager = .default, baseDirectoryURL: URL? = nil) {
        self.fileManager = fileManager
        self.baseDirectoryURL = baseDirectoryURL
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func loadArchive() -> DrawingStatsArchive {
        guard let url = persistentArchiveURL() else { return .empty }
        guard let data = try? Data(contentsOf: url) else { return .empty }
        return (try? decoder.decode(DrawingStatsArchive.self, from: data)) ?? .empty
    }

    func saveArchive(_ archive: DrawingStatsArchive) throws {
        guard let url = persistentArchiveURL(createDirectories: true) else {
            throw NSError(domain: "ArtFlex.DrawingStatsPersistence", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "无法创建绘画数据目录"
            ])
        }
        let data = try encoder.encode(archive)
        try data.write(to: url, options: .atomic)
    }

    private func persistentArchiveURL(createDirectories: Bool = false) -> URL? {
        let appSupport = baseDirectoryURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let appSupport else { return nil }
        let directory = appSupport.appendingPathComponent("ArtFlex", isDirectory: true)
        if createDirectories {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent("drawing-stats.json")
    }
}

@MainActor
final class DrawingStatsController: ObservableObject {
    static let defaultGracePeriod: TimeInterval = 60

    @Published private(set) var snapshot: DrawingStatsSnapshot

    var milestoneHandler: ((DrawingStatsMilestone) -> Void)?

    private let persistenceController: DrawingStatsPersistenceController
    private let calendar: Calendar
    private let gracePeriod: TimeInterval
    private let enablesLiveTimer: Bool

    private var archive: DrawingStatsArchive
    private var activeSessionStartedAt: Date?
    private var lastPaintingActivityAt: Date?
    private var activeTimer: Timer?
    private var currentDocumentID: UUID?
    private var currentDocumentName = "未命名"
    private var committedCurrentDocumentTime: TimeInterval = 0

    init(
        persistenceController: DrawingStatsPersistenceController = DrawingStatsPersistenceController(),
        calendar: Calendar = DrawingStatsController.defaultCalendar,
        gracePeriod: TimeInterval = DrawingStatsController.defaultGracePeriod,
        enablesLiveTimer: Bool = true
    ) {
        self.persistenceController = persistenceController
        self.calendar = calendar
        self.gracePeriod = gracePeriod
        self.enablesLiveTimer = enablesLiveTimer
        let archive = persistenceController.loadArchive()
        self.archive = archive
        self.snapshot = DrawingStatsSnapshot(
            totalPaintingTime: archive.totalPaintingTime,
            currentDocumentTime: 0,
            todayPaintingTime: archive.dailyRecords[Self.dateKey(for: Date(), calendar: calendar)] ?? 0,
            dailyRecords: archive.dailyRecords,
            currentStreak: archive.currentStreak,
            hasActivityToday: (archive.dailyRecords[Self.dateKey(for: Date(), calendar: calendar)] ?? 0) > 0,
            latestMilestone: archive.milestones.last.flatMap(DrawingStatsMilestone.resolve(id:)),
            currentDocumentName: "未命名",
            isActiveSessionRunning: false
        )
    }

    var currentDocumentAccumulatedPaintingTime: TimeInterval {
        committedCurrentDocumentTime
    }

    func syncCurrentDocument(
        id: UUID,
        name: String,
        accumulatedPaintingTime: TimeInterval,
        now: Date = Date()
    ) {
        if currentDocumentID != id {
            committedCurrentDocumentTime = accumulatedPaintingTime
        } else {
            committedCurrentDocumentTime = max(committedCurrentDocumentTime, accumulatedPaintingTime)
        }
        currentDocumentID = id
        currentDocumentName = name
        if snapshot.currentDocumentName != name {
            snapshot.currentDocumentName = name
        }
        refreshSnapshot(now: now)
    }

    func recordPaintingActivity(at now: Date = Date()) {
        if activeSessionStartedAt == nil {
            activeSessionStartedAt = now
        }
        lastPaintingActivityAt = now
        scheduleActiveTimerIfNeeded()
        refreshSnapshot(now: now)
    }

    func pauseTracking(at now: Date = Date()) {
        commitActiveSession(endingAt: now)
        persistArchiveIfNeeded()
        invalidateActiveTimer()
        refreshSnapshot(now: now)
    }

    func flushIfGraceExpired(at now: Date = Date()) {
        guard let graceDeadline = graceDeadline else {
            refreshSnapshot(now: now)
            return
        }

        if now >= graceDeadline {
            commitActiveSession(endingAt: graceDeadline)
            persistArchiveIfNeeded()
        }

        refreshSnapshot(now: now)
    }

    private func scheduleActiveTimerIfNeeded() {
        guard enablesLiveTimer else { return }
        guard activeTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.flushIfGraceExpired()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        activeTimer = timer
    }

    private func invalidateActiveTimer() {
        activeTimer?.invalidate()
        activeTimer = nil
    }

    private func commitActiveSession(endingAt requestedEnd: Date) {
        guard let sessionStart = activeSessionStartedAt else { return }
        let sessionEnd = max(sessionStart, requestedEnd)
        let delta = sessionEnd.timeIntervalSince(sessionStart)
        guard delta > 0 else {
            activeSessionStartedAt = nil
            lastPaintingActivityAt = nil
            invalidateActiveTimer()
            return
        }

        archive.totalPaintingTime += delta
        committedCurrentDocumentTime += delta
        accumulateDailyRecords(from: sessionStart, to: sessionEnd, into: &archive.dailyRecords)
        archive.lastActiveDate = Self.dateKey(for: sessionEnd, calendar: calendar)
        archive.currentStreak = Self.calculateCurrentStreak(
            from: archive.dailyRecords,
            calendar: calendar,
            today: sessionEnd
        )
        evaluateMilestones()

        activeSessionStartedAt = nil
        lastPaintingActivityAt = nil
        invalidateActiveTimer()
    }

    private func persistArchiveIfNeeded() {
        try? persistenceController.saveArchive(archive)
    }

    private func evaluateMilestones() {
        for milestone in DrawingStatsMilestone.all where !archive.milestones.contains(milestone.id) {
            let isReached: Bool
            switch milestone.kind {
            case .totalHours(let hours):
                isReached = archive.totalPaintingTime >= Double(hours) * 3600
            case .streakDays(let days):
                isReached = archive.currentStreak >= days
            }

            guard isReached else { continue }
            archive.milestones.append(milestone.id)
            milestoneHandler?(milestone)
        }
    }

    private func refreshSnapshot(now: Date) {
        let previewDailyRecords = mergedDailyRecordsIncludingLive(at: now)
        let todayKey = Self.dateKey(for: now, calendar: calendar)
        let todayDuration = previewDailyRecords[todayKey] ?? 0

        snapshot = DrawingStatsSnapshot(
            totalPaintingTime: archive.totalPaintingTime + liveSessionDuration(at: now),
            currentDocumentTime: committedCurrentDocumentTime + liveSessionDuration(at: now),
            todayPaintingTime: todayDuration,
            dailyRecords: previewDailyRecords,
            currentStreak: Self.calculateCurrentStreak(from: previewDailyRecords, calendar: calendar, today: now),
            hasActivityToday: todayDuration > 0,
            latestMilestone: archive.milestones.last.flatMap(DrawingStatsMilestone.resolve(id:)),
            currentDocumentName: currentDocumentName,
            isActiveSessionRunning: activeSessionStartedAt != nil
        )
    }

    private func mergedDailyRecordsIncludingLive(at now: Date) -> [String: TimeInterval] {
        guard let liveInterval = liveSessionInterval(at: now) else { return archive.dailyRecords }
        var records = archive.dailyRecords
        accumulateDailyRecords(from: liveInterval.start, to: liveInterval.end, into: &records)
        return records
    }

    private func liveSessionDuration(at now: Date) -> TimeInterval {
        guard let interval = liveSessionInterval(at: now) else { return 0 }
        return interval.duration
    }

    private func liveSessionInterval(at now: Date) -> DateInterval? {
        guard let sessionStart = activeSessionStartedAt else { return nil }
        let effectiveEnd = min(now, graceDeadline ?? now)
        guard effectiveEnd > sessionStart else { return nil }
        return DateInterval(start: sessionStart, end: effectiveEnd)
    }

    private var graceDeadline: Date? {
        guard let lastPaintingActivityAt else { return nil }
        return lastPaintingActivityAt.addingTimeInterval(gracePeriod)
    }

    private func accumulateDailyRecords(
        from start: Date,
        to end: Date,
        into records: inout [String: TimeInterval]
    ) {
        guard end > start else { return }
        var cursor = start
        while cursor < end {
            let dayStart = calendar.startOfDay(for: cursor)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
            let segmentEnd = min(end, nextDay)
            let key = Self.dateKey(for: cursor, calendar: calendar)
            records[key, default: 0] += segmentEnd.timeIntervalSince(cursor)
            cursor = segmentEnd
        }
    }

    private static var defaultCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.firstWeekday = 2
        return calendar
    }

    static func dateKey(for date: Date, calendar: Calendar = DrawingStatsController.defaultCalendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func calculateCurrentStreak(
        from dailyRecords: [String: TimeInterval],
        calendar: Calendar = DrawingStatsController.defaultCalendar,
        today: Date
    ) -> Int {
        let todayKey = dateKey(for: today, calendar: calendar)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let yesterdayKey = dateKey(for: yesterday, calendar: calendar)

        let anchorDate: Date
        if (dailyRecords[todayKey] ?? 0) > 0 {
            anchorDate = today
        } else if (dailyRecords[yesterdayKey] ?? 0) > 0 {
            anchorDate = yesterday
        } else {
            return 0
        }

        var streak = 0
        var cursor = calendar.startOfDay(for: anchorDate)
        while (dailyRecords[dateKey(for: cursor, calendar: calendar)] ?? 0) > 0 {
            streak += 1
            guard let previousDay = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previousDay
        }
        return streak
    }
}

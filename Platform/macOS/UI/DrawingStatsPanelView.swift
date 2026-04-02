import Foundation
import SwiftUI

struct DrawingStatsPanelView: View {
    @ObservedObject var controller: DrawingStatsController

    var body: some View {
        let snapshot = controller.snapshot

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("绘画数据")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color.white)
                    Text(snapshot.currentDocumentName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .lineLimit(1)
                }

                VStack(spacing: 8) {
                    statsCard(
                        title: "总绘画时长",
                        value: Self.formattedLongDuration(snapshot.totalPaintingTime)
                    )
                    statsCard(
                        title: "当前作品用时",
                        value: Self.formattedLongDuration(snapshot.currentDocumentTime)
                    )
                    statsCard(
                        title: "今日绘画时长",
                        value: Self.formattedTodayDuration(snapshot.todayPaintingTime)
                    )
                }

                streakSection(snapshot: snapshot)
                milestoneSection(snapshot: snapshot)
                heatmapSection(snapshot: snapshot)
            }
            .padding(14)
        }
        .scrollIndicators(.hidden)
        .frame(width: 416, height: 618)
        .background(Color(red: 0.16, green: 0.16, blue: 0.17))
    }

    private func statsCard(title: String, value: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.62))
                Text(value)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.07))
        )
    }

    private func streakSection(snapshot: DrawingStatsSnapshot) -> some View {
        HStack(spacing: 10) {
            Text("🔥")
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: 2) {
                Text("连续创作 \(snapshot.currentStreak) 天")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(snapshot.hasActivityToday ? Color.orange : Color.white)
                Text(snapshot.hasActivityToday ? "今日已有有效绘画记录" : "今日尚未记录到有效绘画活动")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.6))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(snapshot.hasActivityToday ? Color.orange.opacity(0.16) : Color.white.opacity(0.07))
        )
    }

    private func milestoneSection(snapshot: DrawingStatsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("最近里程碑")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.62))
            if let milestone = snapshot.latestMilestone {
                Text(milestone.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.white)
                Text(milestone.detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.68))
            } else {
                Text("继续创作，第一条里程碑会在这里显示。")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.68))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.07))
        )
    }

    private func heatmapSection(snapshot: DrawingStatsSnapshot) -> some View {
        let weeks = Self.makeHeatmapWeeks(records: snapshot.dailyRecords)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("过去 12 周")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.62))
                Spacer(minLength: 0)
                Text("热力图")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.45))
            }

            HStack(alignment: .top, spacing: 4) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: 4) {
                        ForEach(week) { entry in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Self.heatmapColor(for: entry.duration))
                                .frame(width: 14, height: 14)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3)
                                        .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                                )
                                .help("\(Self.formattedDate(entry.date))：\(Self.formattedHeatmapDuration(entry.duration))")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.07))
        )
    }

    private static func formattedLongDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 {
            return "\(hours) 小时 \(minutes) 分"
        }
        let secs = totalSeconds % 60
        return "\(minutes) 分 \(secs) 秒"
    }

    private static func formattedTodayDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return "\(hours) 小时 \(minutes) 分"
        }
        return "\(minutes) 分 \(secs) 秒"
    }

    private static func formattedHeatmapDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds.rounded())
        if totalSeconds <= 0 {
            return "0 分钟"
        }
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 {
            return "\(hours) 小时 \(minutes) 分"
        }
        return "\(minutes) 分钟"
    }

    private static func formattedDate(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return "\(year)-\(String(format: "%02d", month))-\(String(format: "%02d", day))"
    }

    private static func heatmapColor(for duration: TimeInterval) -> Color {
        switch duration {
        case ..<1:
            return Color.white.opacity(0.05)
        case ..<1800:
            return Color.accentColor.opacity(0.22)
        case ..<3600:
            return Color.accentColor.opacity(0.38)
        case ..<7200:
            return Color.accentColor.opacity(0.58)
        default:
            return Color.accentColor.opacity(0.82)
        }
    }

    private static func makeHeatmapWeeks(records: [String: TimeInterval]) -> [[DrawingStatsHeatmapEntry]] {
        let today = Date()
        let currentWeekStart = startOfWeek(for: today)
        guard let firstWeekStart = calendar.date(byAdding: .weekOfYear, value: -11, to: currentWeekStart) else {
            return []
        }

        return (0..<12).compactMap { weekOffset in
            guard let weekStart = calendar.date(byAdding: .weekOfYear, value: weekOffset, to: firstWeekStart) else {
                return nil
            }
            return (0..<7).compactMap { dayOffset -> DrawingStatsHeatmapEntry? in
                guard let date = calendar.date(byAdding: .day, value: dayOffset, to: weekStart) else {
                    return nil
                }
                let key = DrawingStatsController.dateKey(for: date, calendar: calendar)
                return DrawingStatsHeatmapEntry(date: date, duration: records[key] ?? 0)
            }
        }
    }

    private static func startOfWeek(for date: Date) -> Date {
        let dayStart = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: dayStart)
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -offset, to: dayStart) ?? dayStart
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.firstWeekday = 2
        return calendar
    }
}

private struct DrawingStatsHeatmapEntry: Identifiable {
    let date: Date
    let duration: TimeInterval

    var id: Date { date }
}

import Foundation
import SwiftUI
import Testing
import RagdollCore
@testable import Ragdoll

@Test func recentSessionsUseLocalCalendarPeriodsAndUpdatedTime() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
    calendar.firstWeekday = 2
    let now = calendar.date(from: DateComponents(year: 2027, month: 1, day: 1, hour: 12))!
    let times = ["2026-11-30T16:00:00Z", "2026-12-27T16:00:00Z", "2026-12-30T16:00:00Z", "2026-12-31T15:59:59Z", "2026-12-31T16:00:00Z", "2027-01-01T04:00:00Z", "2027-01-01T04:00:01Z"]
    let sessions = times.reversed().map { time in
        Session(id: time, source: "codex", title: time, created: 0, updated: ISO8601DateFormatter().date(from: time)!.timeIntervalSince1970 * 1000)
    }
    #expect(RecentSessionPeriod.today.sessions(sessions, now: now, calendar: calendar).map(\.id) == [times[5], times[4]])
    #expect(RecentSessionPeriod.yesterday.sessions(sessions, now: now, calendar: calendar).map(\.id) == [times[3], times[2]])
    #expect(RecentSessionPeriod.week.sessions(sessions, now: now, calendar: calendar).map(\.id) == [times[5], times[4], times[3], times[2], times[1]])
    #expect(RecentSessionPeriod.month.sessions(sessions, now: now, calendar: calendar).map(\.id) == [times[5], times[4]])
    #expect(RecentSessionPeriod.today.sessions([], now: now, calendar: calendar).isEmpty)
}

@Test func recentYesterdayIncludesEntireDayAcrossDaylightSaving() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let now = ISO8601DateFormatter().date(from: "2026-11-02T20:00:00Z")!
    let times = ["2026-11-01T06:59:59Z", "2026-11-01T07:00:00Z", "2026-11-02T07:59:59Z", "2026-11-02T08:00:00Z"]
    let sessions = times.map { time in
        Session(id: time, source: "codex", title: time, updated: ISO8601DateFormatter().date(from: time)!.timeIntervalSince1970 * 1000)
    }
    #expect(RecentSessionPeriod.yesterday.sessions(sessions, now: now, calendar: calendar).map(\.id) == [times[1], times[2]])
}

@Test @MainActor func activityGreensGetLighterInBothThemes() {
    let view = DashboardView(showSessions: {})
    for scheme in [ColorScheme.light, .dark] {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        let colors = (1...4).map { view.activityColor($0).resolve(in: environment) }
        #expect(abs(colors[0].red - 33.0 / 255) < 0.001)
        #expect(abs(colors[0].green - 110.0 / 255) < 0.001)
        #expect(abs(colors[0].blue - 57.0 / 255) < 0.001)
        #expect(abs(colors[3].red - 155.0 / 255) < 0.001)
        #expect(abs(colors[3].green - 233.0 / 255) < 0.001)
        #expect(abs(colors[3].blue - 168.0 / 255) < 0.001)
        for (lower, higher) in zip(colors, colors.dropFirst()) {
            #expect(lower.red < higher.red)
            #expect(lower.green < higher.green)
            #expect(lower.blue < higher.blue)
        }
    }
}

@Test @MainActor func activityTooltipUsesLocalDateAndCompactTokens() {
    let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 29))!
    let tooltip = ActivityTooltip(date: date, tokens: 170_000_000)
    #expect(tooltip.dateText == "10月29日")
    #expect(tooltip.tokenText == "1.7亿 个 Token")
    #expect(ActivityTooltip(date: date, tokens: 0).tokenText == "0 个 Token")
}

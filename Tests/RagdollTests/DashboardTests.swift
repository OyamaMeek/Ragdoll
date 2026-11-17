import Foundation
import SwiftUI
import Testing
@testable import Ragdoll

@Test func recentSessionDatesShowCalendarLabelsInsteadOfElapsedTime() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
    calendar.firstWeekday = 2
    let now = ISO8601DateFormatter().date(from: "2026-11-19T04:00:00Z")!
    let cases = [
        ("2026-11-19T03:59:45Z", "今天"),
        ("2026-11-18T16:00:00Z", "今天"),
        ("2026-11-18T15:59:59Z", "昨日"),
        ("2026-11-17T16:00:00Z", "昨日"),
        ("2026-11-15T16:00:00Z", "本周"),
        ("2026-11-15T15:59:59Z", "本月")
    ]
    for (time, label) in cases {
        #expect(recentSessionDateLabel(ISO8601DateFormatter().date(from: time)!, now: now, calendar: calendar) == label)
    }
    calendar.locale = Locale(identifier: "en_US_POSIX")
    let older = ISO8601DateFormatter().date(from: "2026-10-31T15:59:59Z")!
    #expect(recentSessionDateLabel(older, now: now, calendar: calendar) == "10/31/2026")
}

@Test func recentSessionDateLabelsHandleCrossYearWeeksAndDaylightSaving() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.firstWeekday = 2
    calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
    let newYear = ISO8601DateFormatter().date(from: "2027-01-01T04:00:00Z")!
    #expect(recentSessionDateLabel(ISO8601DateFormatter().date(from: "2026-12-31T04:00:00Z")!, now: newYear, calendar: calendar) == "昨日")
    #expect(recentSessionDateLabel(ISO8601DateFormatter().date(from: "2026-12-30T04:00:00Z")!, now: newYear, calendar: calendar) == "本周")
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let now = ISO8601DateFormatter().date(from: "2026-11-02T20:00:00Z")!
    #expect(recentSessionDateLabel(ISO8601DateFormatter().date(from: "2026-11-01T07:00:00Z")!, now: now, calendar: calendar) == "昨日")
    #expect(recentSessionDateLabel(ISO8601DateFormatter().date(from: "2026-11-02T07:59:59Z")!, now: now, calendar: calendar) == "昨日")
    #expect(recentSessionDateLabel(ISO8601DateFormatter().date(from: "2026-11-02T08:00:00Z")!, now: now, calendar: calendar) == "今天")
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

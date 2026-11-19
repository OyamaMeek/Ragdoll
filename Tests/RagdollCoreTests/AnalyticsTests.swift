import Foundation
import Testing
@testable import RagdollCore

@Test func costsAndBudgetUseKnownUsageOnly() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let usage = Usage(time: now.timeIntervalSince1970 * 1000, model: "known", input: 1_000_000, output: 500_000, cacheRead: 1_000_000)
    let unknown = Usage(time: usage.time, model: "unknown", input: 200, output: 50)
    let sessions = [Session(id: "a", source: "codex", title: "A", usage: [usage, unknown]), Session(id: "b", source: "desktop", title: "B")]
    let result = Analytics.summarize(sessions, prices: ["known": Price(input: 2, output: 10, cacheRead: 0.1)], budget: 8, now: now)
    #expect(result.tokens == 2_500_250)
    #expect(abs(result.cost - 7.1) < 0.00001)
    #expect(result.pricedEvents == 1)
    #expect(result.missingUsageSessions == 1)
    #expect(result.alert == "warning")
}

@Test func deepSeekFlashPeakEstimateUsesAllRecordedTokenCategories() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let time = now.timeIntervalSince1970 * 1000
    let historical = Usage(id: "resp_peak", time: time - 30 * 86_400_000, model: "unknown", input: 1_000_000,
                           output: 1_000_000, cacheRead: 1_000_000, cacheWrite: 1_000_000)
    let current = Usage(time: time, model: "known", input: 500_000, output: 0)
    let future = Usage(time: time + 1000, model: "known", input: 1_000_000, output: 0)
    let sessions = [Session(id: "a", source: "codex", title: "Usage", usage: [historical, current, future]),
                    Session(id: "b", source: "codex", title: "Duplicate", usage: [historical])]
    let prices = ["known": Price(input: 10, output: 0)]
    let result = Analytics.summarize(sessions, prices: prices, budget: 10, now: now)
    #expect(abs(result.deepSeekFlashPeakCostCNY - 13.04) < 0.00001)
    #expect(result.events == 2)
    #expect(result.cost == 5)
    #expect(result.weeklyCost == 5)
    let empty = Analytics.summarize([], prices: prices, budget: nil, now: now)
    #expect(empty.events == 0)
    #expect(empty.deepSeekFlashPeakCostCNY == 0)
}

@Test func heatmapUsesLocalCalendarAcrossDST() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    let now = ISO8601DateFormatter().date(from: "2026-11-02T12:00:00Z")!
    let times = ["2026-11-01T05:30:00Z", "2026-11-01T06:30:00Z", "2026-10-25T12:00:00Z", "2026-11-03T12:00:00Z"]
    let usages = times.map { Usage(time: ISO8601DateFormatter().date(from: $0)!.timeIntervalSince1970 * 1000, model: "x", input: 10, output: 0) }
    let result = Analytics.summarize([Session(id: "s", source: "codex", title: "DST", usage: usages)], prices: [:], budget: nil, now: now, calendar: calendar)
    let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
    #expect(result.dailyTokens[day] == 20)
    #expect(result.dailyTokens.values.reduce(0, +) == 30)
    #expect(result.dailyTokens.count == 2)
}

@Test func heatmapWeeksCoverThePastYearWithoutFutureDays() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
    calendar.firstWeekday = 2
    let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 12))!
    let weeks = Analytics.heatmapWeeks(year: 2026, now: now, calendar: calendar)
    let dates = weeks.flatMap { $0 }.compactMap { $0 }
    #expect(weeks.count == 53)
    #expect(weeks.allSatisfy { $0.count == 7 })
    #expect(dates.count == 365)
    #expect(Set(dates).count == 365)
    #expect(dates.first == calendar.date(from: DateComponents(year: 2025, month: 11, day: 18)))
    #expect(dates.last == calendar.date(from: DateComponents(year: 2026, month: 11, day: 17)))
    #expect(weeks[0][0] == nil)
    #expect(weeks[0][1] == nil)
    #expect(weeks[0][2] == dates.first)
    #expect(weeks.last?[3] == nil)
    #expect(Analytics.heatmapWeeks(year: 2027, now: now, calendar: calendar).isEmpty)
}

@Test func historicalHeatmapIncludesLeapDayAndPadsPartialWeeks() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 17))!
    let weeks = Analytics.heatmapWeeks(year: 2024, now: now, calendar: calendar)
    let dates = weeks.flatMap { $0 }.compactMap { $0 }
    #expect(dates.count == 366)
    #expect(Set(dates).count == 366)
    #expect(weeks[0][0] == nil)
    #expect(weeks[0][1] == calendar.date(from: DateComponents(year: 2024, month: 1, day: 1)))
    #expect(weeks.last?[2] == calendar.date(from: DateComponents(year: 2024, month: 12, day: 31)))
    #expect(weeks.last?[3] == nil)
    #expect(dates.contains(calendar.date(from: DateComponents(year: 2024, month: 2, day: 29))!))
    for week in weeks {
        for (row, date) in week.enumerated() {
            if let date { #expect(calendar.component(.weekday, from: date) == row + 1) }
        }
    }
    let empty = Analytics.summarize([], prices: [:], budget: nil, now: now, calendar: calendar)
    #expect(dates.allSatisfy { empty.dailyTokens[$0, default: 0] == 0 })
}

@Test func inheritedProviderResponsesAreCountedOnce() {
    let usage = Usage(id: "resp_same", time: 1_700_000_000_000, model: "known", input: 100, output: 20)
    let parent = Session(id: "parent", source: "codex", title: "Parent", created: 1, usage: [usage])
    var child = Session(id: "child", source: "codex", title: "Child", created: 2, usage: [usage])
    child.parentID = "parent"
    let result = Analytics.summarize([child, parent], prices: [:], budget: nil)
    #expect(result.tokens == 120)
    #expect(result.events == 1)
    #expect(result.sessions == 2)
    #expect(result.dailyTokens.values.reduce(0, +) == 120)
}

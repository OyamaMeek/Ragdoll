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

@Test func heatmapUsesLocalCalendarAcrossDST() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    let now = ISO8601DateFormatter().date(from: "2026-11-02T12:00:00Z")!
    let times = ["2026-11-01T05:30:00Z", "2026-11-01T06:30:00Z", "2026-10-25T12:00:00Z"]
    let usages = times.map { Usage(time: ISO8601DateFormatter().date(from: $0)!.timeIntervalSince1970 * 1000, model: "x", input: 10, output: 0) }
    let result = Analytics.summarize([Session(id: "s", source: "claude", title: "DST", usage: usages)], prices: [:], budget: nil, now: now, calendar: calendar)
    #expect(result.heatmap[0][1] == 20)
    #expect(result.heatmap.flatMap { $0 }.reduce(0, +) == 20)
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
}

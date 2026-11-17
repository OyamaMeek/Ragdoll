import Foundation

public struct Dashboard: Sendable {
    public var tokens = 0
    public var cost = 0.0
    public var recentCost = 0.0
    public var weeklyCost = 0.0
    public var pricedEvents = 0
    public var events = 0
    public var sessions = 0
    public var missingUsageSessions = 0
    public var dailyTokens: [Date: Int] = [:]
    public var projects: [ProjectTotal] = []
    public var alert: String = "none"
}

public struct ProjectTotal: Identifiable, Sendable {
    public var id: String
    public var tokens: Int
    public var cost: Double
    public var sessions: Int
    public var pricedEvents = 0
}

public enum Analytics {
    public static func summarize(_ sessions: [Session], prices: [String: Price], budget: Double?, now: Date = Date(), calendar: Calendar = .current) -> Dashboard {
        var result = Dashboard()
        result.sessions = sessions.count
        let today = calendar.startOfDay(for: now)
        let previousWeek = calendar.date(byAdding: .day, value: -7, to: today)!
        let rollingStart = now.addingTimeInterval(-168 * 3600)
        var projects: [String: ProjectTotal] = [:]
        var providerRequests = Set<String>()
        for session in sessions.sorted(by: { ($0.parentID == nil ? 0 : 1, $0.created) < ($1.parentID == nil ? 0 : 1, $1.created) }) {
            if session.usage.isEmpty { result.missingUsageSessions += 1 }
            var project = projects[session.project] ?? ProjectTotal(id: session.project, tokens: 0, cost: 0, sessions: 0)
            project.sessions += 1
            for usage in session.usage {
                if usage.id.hasPrefix("resp_") || usage.id.hasPrefix("msg_") {
                    let key = "\(session.nativeSource ?? session.source):\(session.home):\(usage.id)"
                    guard providerRequests.insert(key).inserted else { continue }
                }
                let date = Date(timeIntervalSince1970: usage.time / 1000)
                guard date <= now else { continue }
                result.events += 1
                result.tokens += usage.tokens
                project.tokens += usage.tokens
                if let price = prices[usage.model] {
                    let cost = price.cost(usage)
                    result.cost += cost; result.pricedEvents += 1; project.cost += cost; project.pricedEvents += 1
                    if date >= rollingStart { result.weeklyCost += cost }
                    if date >= previousWeek && date < today { result.recentCost += cost }
                }
                result.dailyTokens[calendar.startOfDay(for: date), default: 0] += usage.tokens
            }
            projects[session.project] = project
        }
        result.projects = projects.values.sorted { $0.tokens > $1.tokens }
        if let budget, budget > 0 {
            result.alert = result.weeklyCost >= budget ? "exceeded" : result.weeklyCost >= budget * 0.8 ? "warning" : "none"
        }
        return result
    }

    public static func heatmapWeeks(year: Int, now: Date = Date(), calendar: Calendar = .current) -> [[Date?]] {
        let currentYear = calendar.component(.year, from: now)
        guard year <= currentYear else { return [] }
        let today = calendar.startOfDay(for: now)
        let yearStart = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
        let start = year == currentYear
            ? calendar.date(byAdding: .day, value: 1, to: calendar.date(byAdding: .year, value: -1, to: today)!)!
            : yearStart
        let end = year == currentYear
            ? today
            : calendar.date(byAdding: .day, value: -1, to: calendar.date(byAdding: .year, value: 1, to: yearStart)!)!
        let gridStart = calendar.date(byAdding: .day, value: 1 - calendar.component(.weekday, from: start), to: start)!
        let count = calendar.dateComponents([.day], from: gridStart, to: end).day! + 1
        return stride(from: 0, to: count, by: 7).map { week in
            (0..<7).map { day in
                let date = calendar.date(byAdding: .day, value: week + day, to: gridStart)!
                return date >= start && date <= end ? date : nil
            }
        }
    }
}

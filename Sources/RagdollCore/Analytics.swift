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
    public var heatmap = Array(repeating: Array(repeating: 0, count: 24), count: 7)
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
        let start = calendar.date(byAdding: .day, value: -6, to: today)!
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
                if date >= start {
                    let weekday = calendar.component(.weekday, from: date) - 1
                    let hour = calendar.component(.hour, from: date)
                    result.heatmap[weekday][hour] += usage.tokens
                }
            }
            projects[session.project] = project
        }
        result.projects = projects.values.sorted { $0.tokens > $1.tokens }
        if let budget, budget > 0 {
            result.alert = result.weeklyCost >= budget ? "exceeded" : result.weeklyCost >= budget * 0.8 ? "warning" : "none"
        }
        return result
    }
}

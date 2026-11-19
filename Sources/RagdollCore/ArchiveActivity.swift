import Foundation

enum ArchiveActivity {
    static let readmePath = "README.md"
    static let chartPath = "ragdoll-token-activity.svg"
    static let manifestPath = ".ragdoll-activity.json"
    static let sectionKey = "readmeSection"
    static let paths = Set([readmePath, chartPath])
    private static let start = Data("<!-- ragdoll:activity:start -->\n".utf8)
    private static let end = Data("<!-- ragdoll:activity:end -->\n".utf8)
    private static let locale = Locale(identifier: "en_US")

    static func sectionRange(in readme: Data) -> Range<Data.Index>? {
        guard let start = readme.range(of: start),
              let end = readme.range(of: end, in: start.upperBound..<readme.endIndex) else { return nil }
        return start.lowerBound..<end.upperBound
    }

    static func render(_ sessions: [Session], prices: [String: Price], now: Date = .now, calendar: Calendar = .current) -> (section: Data, chart: Data) {
        let recent = sessions.sorted { $0.updated == $1.updated ? $0.id < $1.id : $0.updated > $1.updated }
        let stats = Analytics.summarize(recent, prices: prices, budget: nil, now: now, calendar: calendar)
        let weeks = Analytics.heatmapWeeks(year: calendar.component(.year, from: now), now: now, calendar: calendar)
        let dates = weeks.flatMap { $0.compactMap { $0 } }
        let day = Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day().dateSeparator(.dash)
        let cost = stats.pricedEvents > 0 ? money(stats.cost) : "未知"
        let projects = stats.projects.sorted { $0.tokens == $1.tokens ? $0.id < $1.id : $0.tokens > $1.tokens }
        let projectRows = projects.prefix(8).map { project in
            let name = project.id.isEmpty ? "未关联项目" : URL(fileURLWithPath: project.id).lastPathComponent
            let cost = project.pricedEvents > 0 ? money(project.cost) : "未知"
            return "| \(escape(name)) | \(count(project.tokens)) | \(count(project.sessions)) | \(cost) |"
        }
        let sessionRows = recent.prefix(6).map { session in
            let path = Archive.sessionPath(session)
            let href = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            let title = escape(session.title)
            let updated = Date(timeIntervalSince1970: session.updated / 1000).formatted(day)
            return "| [\(title.isEmpty ? "未命名会话" : title)](\(href)/transcript.md) | \(escape(session.source)) | \(escape(session.projectName)) | \(updated) |"
        }

        let markdown = """

        ## Ragdoll 活动概览

        | 指标 | 数值 | 说明 |
        | --- | ---: | --- |
        | 估算总成本 | \(cost) | \(count(stats.pricedEvents))/\(count(stats.events)) 条用量已定价 |
        | 总 Token | \(count(stats.tokens)) | \(count(stats.missingUsageSessions)) 个会话缺少用量 |
        | 会话 | \(count(stats.sessions)) | 当前归档范围 |

        ### Token 活跃度

        \(dates.first?.formatted(day) ?? "") 至 \(dates.last?.formatted(day) ?? "") · 按本地日期统计，绿色越浅表示用量越高。

        ![过去一年每日 Token 用量热力图](\(chartPath))

        ### 项目活动

        \(table(["| 项目 | Token | 会话 | 估算成本 |", "| --- | ---: | ---: | ---: |"], rows: projectRows, empty: "暂无项目记录。"))

        ### 最近会话

        \(table(["| 会话 | 来源 | 项目 | 更新日期 |", "| --- | --- | --- | --- |"], rows: sessionRows, empty: "暂无会话。"))

        成本按当前价格表以美元估算，实际账单以服务商为准。


        """
        return (start + Data(markdown.utf8) + end, Data(heatmap(weeks, tokens: stats.dailyTokens, calendar: calendar, day: day).utf8))
    }

    private static func heatmap(_ weeks: [[Date?]], tokens: [Date: Int], calendar: Calendar, day: Date.ISO8601FormatStyle) -> String {
        let colors = ["#7d859055", "#216e39", "#38964b", "#65be67", "#9be9a8"]
        let maximum = max(weeks.flatMap { $0.compactMap { $0 } }.map { tokens[$0, default: 0] }.max() ?? 0, 1)
        let width = 34 + 14 * weeks.count
        var rows = ["""
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(width) 148" width="\(width)" height="148" fill="#777" font-family="sans-serif" font-size="10">
        <title>过去一年每日 Token 用量</title>
        <text x="0" y="45">周一</text>
        <text x="0" y="73">周三</text>
        <text x="0" y="101">周五</text>
        """]
        for (week, days) in weeks.enumerated() {
            let x = 30 + week * 14
            if let date = days.compactMap({ $0 }).first(where: { calendar.component(.day, from: $0) == 1 }) {
                rows.append("<text x=\"\(x)\" y=\"14\">\(calendar.component(.month, from: date))月</text>")
            }
            for (weekday, date) in days.enumerated() {
                guard let date else { continue }
                let value = tokens[date, default: 0]
                let level = value <= 0 ? 0 : min(4, Int(ceil(4 * Double(value) / Double(maximum))))
                let y = 24 + weekday * 14
                rows.append("<rect x=\"\(x)\" y=\"\(y)\" width=\"11\" height=\"11\" rx=\"2\" fill=\"\(colors[level])\"><title>\(date.formatted(day)) · \(count(value)) Token</title></rect>")
            }
        }
        rows.append("<text x=\"\(width - 110)\" y=\"141\">少</text>")
        for (level, color) in colors.enumerated() {
            rows.append("<rect x=\"\(width - 96 + level * 14)\" y=\"132\" width=\"11\" height=\"11\" rx=\"2\" fill=\"\(color)\"/>")
        }
        rows.append("<text x=\"\(width - 24)\" y=\"141\">多</text>")
        return (rows + ["</svg>", ""]).joined(separator: "\n")
    }

    private static func table(_ header: [String], rows: [String], empty: String) -> String {
        rows.isEmpty ? empty : (header + rows).joined(separator: "\n")
    }

    private static func count(_ value: Int) -> String { value.formatted(.number.locale(locale)) }
    private static func money(_ value: Double) -> String { value.formatted(.currency(code: "USD").locale(locale)) }

    private static func escape(_ value: String) -> String {
        let text = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let entities: [Unicode.Scalar: String] = ["&": "&amp;", "<": "&lt;", ">": "&gt;"]
        return text.unicodeScalars.map { scalar in
            if let entity = entities[scalar] { return entity }
            if "\\`*_[]!|~$".unicodeScalars.contains(scalar) { return "&#\(scalar.value);" }
            return String(scalar)
        }.joined()
    }
}

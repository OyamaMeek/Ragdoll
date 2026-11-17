import SwiftUI
import RagdollCore

struct DashboardView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    var showSessions: () -> Void
    @State private var budget = ""
    @State private var heatmapYear = Calendar.current.component(.year, from: Date())
    @State private var hoveredDay: Date?
    var body: some View {
        let stats = model.dashboard
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("WORKSPACE INSIGHTS").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(.blue)
                        Text("活动概览").font(.system(size: 30, weight: .bold))
                        Text(Date.now.formatted(.dateTime.year().month().day().weekday())).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("项目", selection: $model.project) { Text("全部项目").tag(""); ForEach(model.projects, id: \.self) { Text(URL(fileURLWithPath: $0).lastPathComponent).tag($0) } }.frame(width: 160)
                    Picker("来源", selection: $model.source) {
                        Text("全部来源").tag("all")
                        ForEach(["codex", "claude", "dsh", "desktop", "acp"], id: \.self) { Text(sourceName($0)).tag($0) }
                    }.frame(width: 180)
                }
                HStack(spacing: 14) {
                    metric("估算总成本", value: stats.pricedEvents > 0 ? money(stats.cost) : "未知", note: "\(stats.pricedEvents)/\(stats.events) 条用量已定价", icon: "dollarsign.circle")
                    metric("前 7 个完整自然日", value: stats.pricedEvents > 0 ? money(stats.recentCost) : "未知", note: "按本地日期统计", icon: "calendar")
                    metric("总 Token", value: compact(stats.tokens), note: "\(stats.missingUsageSessions) 个会话缺少用量", icon: "chart.bar.xaxis")
                    metric("会话", value: "\(stats.sessions)", note: "本地日志与导入记录", icon: "bubble.left.and.bubble.right")
                }
                if model.settings.showWeeklyBudget == true {
                    Card {
                        HStack(spacing: 20) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("每周预算").font(.headline)
                                Text(model.settings.weeklyBudget.map { "\(money(stats.weeklyCost)) / \(money($0))" } ?? "尚未设置预算").font(.title3.bold()).monospacedDigit()
                                Text("滚动 168 小时 · 仅计可定价用量 · 80% 和 100% 提醒").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let total = model.settings.weeklyBudget, total > 0 {
                                VStack(alignment: .leading) {
                                    ProgressView(value: min(stats.weeklyCost / total, 1)).tint(stats.alert == "none" ? .blue : .orange)
                                    if stats.alert != "none" { Text(stats.alert == "exceeded" ? "已达到预算" : "已使用超过 80% 预算").font(.caption).foregroundStyle(.orange) }
                                }.frame(maxWidth: 220)
                            }
                            TextField("预算 USD", text: $budget).textFieldStyle(.roundedBorder).frame(width: 110)
                            Button("保存") { saveBudget() }
                            if model.settings.weeklyBudget != nil { Button("清除") { model.settings.weeklyBudget = nil; budget = ""; model.persistSettings() } }
                        }
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    Card {
                        VStack(alignment: .leading, spacing: 18) {
                            HStack {
                                Text("Token 活跃度").font(.headline)
                                Spacer()
                                Text(heatmapYear == Calendar.current.component(.year, from: Date()) ? "过去一年" : "\(String(heatmapYear)) 年").font(.caption).foregroundStyle(.secondary)
                            }
                            heatmap(stats).zIndex(1)
                            HStack {
                                Text("按本地日期统计 · 点击方格查看当天会话").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                HStack(spacing: 4) {
                                    Text("少")
                                    ForEach(0..<5) { level in RoundedRectangle(cornerRadius: 3).fill(activityColor(level)).frame(width: 12, height: 12) }
                                    Text("多")
                                }.font(.caption).foregroundStyle(.secondary).accessibilityElement(children: .ignore).accessibilityLabel("Token 用量由少到多，共五级")
                            }
                        }
                    }
                    VStack(spacing: 6) {
                        ForEach(activityYears(stats), id: \.self) { year in
                            Button { heatmapYear = year } label: {
                                Text(String(year)).font(.system(size: 14, weight: .medium)).frame(width: 88, height: 36)
                                    .background(heatmapYear == year ? Color.blue : .clear, in: RoundedRectangle(cornerRadius: 8))
                                    .foregroundStyle(heatmapYear == year ? Color.white : .secondary)
                            }.buttonStyle(.plain).accessibilityLabel("\(String(year)) 年热力图").accessibilityAddTraits(heatmapYear == year ? .isSelected : [])
                        }
                    }
                }
                HStack(alignment: .top, spacing: 18) {
                    Card {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("项目活动").font(.headline)
                            if stats.projects.isEmpty { empty("尚无项目记录", icon: "folder") }
                            ForEach(Array(stats.projects.prefix(8))) { project in
                                Button {
                                    model.project = project.id; showSessions()
                                } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack { Image(systemName: "folder").foregroundStyle(.blue); Text(project.id.isEmpty ? "未关联项目" : URL(fileURLWithPath: project.id).lastPathComponent).fontWeight(.medium); Spacer(); Text(compact(project.tokens)).monospacedDigit() }
                                        GeometryReader { geometry in Capsule().fill(.blue.opacity(0.12)).overlay(alignment: .leading) { Capsule().fill(.blue).frame(width: geometry.size.width * Double(project.tokens) / Double(max(stats.projects.first?.tokens ?? 1, 1))) } }.frame(height: 4)
                                        HStack { Text("\(project.sessions) 个会话"); Spacer(); Text(project.pricedEvents > 0 ? money(project.cost) : "费用未知") }.font(.caption).foregroundStyle(.secondary)
                                    }
                                }.buttonStyle(.plain)
                                if project.id != stats.projects.prefix(8).last?.id { Divider() }
                            }
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack { Text("最近会话").font(.headline); Spacer(); Button("全部") { showSessions() }.buttonStyle(.plain).foregroundStyle(.blue) }
                            if model.filtered.isEmpty { empty("等待本地会话", icon: "bubble.left") }
                            ForEach(Array(model.filtered.prefix(6))) { session in
                                Button { model.select(session.id); showSessions() } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: "bubble.left").foregroundStyle(.secondary).padding(.top, 2)
                                        VStack(alignment: .leading, spacing: 5) { Text(session.title).lineLimit(1); Text("\(sourceName(session.source)) · \(session.projectName)").font(.caption).foregroundStyle(.secondary) }
                                        Spacer()
                                        Text(Date(timeIntervalSince1970: session.updated / 1000), style: .relative).font(.caption2).foregroundStyle(.tertiary)
                                    }
                                }.buttonStyle(.plain)
                                Divider()
                            }
                            HStack { Image(systemName: "externaldrive.badge.checkmark"); Text(model.archiveStatus).lineLimit(2) }.font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("成本按当前价格表估算，不代表实际账单。未知价格、不同服务层级、长上下文和缓存时长可能影响结果。").font(.caption).foregroundStyle(.tertiary)
            }.padding(28).frame(maxWidth: 1500)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { budget = model.settings.weeklyBudget.map { String($0) } ?? ""; model.heatmapFilter = nil; model.query = ""; do { try model.reload() } catch { model.error = error.localizedDescription } }
        .onChange(of: heatmapYear) { hoveredDay = nil }
        .onChange(of: model.project) { hoveredDay = nil }
        .onChange(of: model.source) { hoveredDay = nil }
        .onDisappear { hoveredDay = nil }
        .navigationTitle("首页")
    }
    func saveBudget() {
        guard let value = Double(budget), value.isFinite, value > 0 else { model.error = "请输入大于零的预算金额"; return }
        model.settings.weeklyBudget = value; model.persistSettings()
    }
    func metric(_ title: String, value: String, note: String, icon: String) -> some View {
        Card { VStack(alignment: .leading, spacing: 12) {
            HStack { Text(title).font(.caption).foregroundStyle(.secondary); Spacer(); Image(systemName: icon).foregroundStyle(.tertiary) }
            Text(value).font(.system(size: 27, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(note).font(.caption2).foregroundStyle(.secondary)
        } }
    }
    func heatmap(_ stats: Dashboard) -> some View {
        let weeks = Analytics.heatmapWeeks(year: heatmapYear)
        let maximum = max(weeks.flatMap { $0 }.compactMap { $0 }.map { stats.dailyTokens[$0, default: 0] }.max() ?? 0, 1)
        return GeometryReader { geometry in
            let size = max(10, min(18, (geometry.size.width - 40) / CGFloat(weeks.count) - 4))
            ScrollView(.horizontal) {
                Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                    GridRow {
                        Color.clear.frame(width: 32, height: 18)
                        ForEach(weeks.indices, id: \.self) { week in
                            let dates = weeks[week].compactMap { $0 }
                            let month = dates.first { Calendar.current.component(.day, from: $0) == 1 } ?? (week == 0 ? dates.first : nil)
                            Text(month.map { $0.formatted(.dateTime.month(.abbreviated)) } ?? "")
                                .font(.caption).foregroundStyle(.secondary).fixedSize().frame(width: size, alignment: .leading)
                        }
                    }
                    ForEach(0..<7) { day in
                        GridRow {
                            Text([1: "周一", 3: "周三", 5: "周五"][day] ?? "").font(.caption2).foregroundStyle(.secondary).frame(width: 32, height: size, alignment: .leading)
                            ForEach(weeks.indices, id: \.self) { week in
                                if let date = weeks[week][day] {
                                    let value = stats.dailyTokens[date, default: 0]
                                    let level = value == 0 ? 0 : min(4, Int(ceil(4 * Double(value) / Double(maximum))))
                                    Button { model.heatmapFilter = date; showSessions() } label: {
                                        RoundedRectangle(cornerRadius: 3).fill(activityColor(level)).frame(width: size, height: size)
                                    }.buttonStyle(.plain)
                                        .onHover { hovering in
                                            if hovering { hoveredDay = date }
                                            else if hoveredDay == date { hoveredDay = nil }
                                        }
                                        .anchorPreference(key: ActivityCellAnchor.self, value: .bounds) { hoveredDay == date ? $0 : nil }
                                        .accessibilityLabel("\(date.formatted(date: .complete, time: .omitted))，\(value) Token，查看当天会话")
                                } else {
                                    Color.clear.frame(width: size, height: size).accessibilityHidden(true)
                                }
                            }
                        }
                    }
                }
            }
            .onScrollPhaseChange { _, _ in hoveredDay = nil }
            .overlayPreferenceValue(ActivityCellAnchor.self) { anchor in
                GeometryReader { proxy in
                    if let anchor, let date = hoveredDay {
                        let cell = proxy[anchor]
                        ActivityTooltip(date: date, tokens: stats.dailyTokens[date, default: 0])
                            .fixedSize()
                            .offset(x: min(max(cell.midX - 100, 0), max(proxy.size.width - 200, 0)), y: cell.maxY + 8)
                    }
                }.allowsHitTesting(false)
            }
        }.frame(height: 180)
    }
    func activityYears(_ stats: Dashboard) -> [Int] {
        Array(Set(stats.dailyTokens.keys.map { Calendar.current.component(.year, from: $0) } + [Calendar.current.component(.year, from: Date()), heatmapYear])).sorted(by: >)
    }
    func activityColor(_ level: Int) -> Color {
        if level == 0 { return Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.05) }
        let greens = [Color(red: 33 / 255, green: 110 / 255, blue: 57 / 255), Color(red: 56 / 255, green: 150 / 255, blue: 75 / 255), Color(red: 101 / 255, green: 190 / 255, blue: 103 / 255), Color(red: 155 / 255, green: 233 / 255, blue: 168 / 255)]
        return greens[level - 1]
    }
    func empty(_ title: String, icon: String) -> some View { HStack { Image(systemName: icon); Text(title) }.foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100) }
}

private struct ActivityCellAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = nextValue() ?? value }
}

struct ActivityTooltip: View {
    let date: Date
    let tokens: Int
    var dateText: String { date.formatted(.dateTime.month().day().locale(Locale(identifier: "zh_CN"))) }
    var tokenText: String { "\(tokens.formatted(.number.notation(.compactName).locale(Locale(identifier: "zh_CN")))) 个 Token" }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(dateText)
            Text(tokenText).monospacedDigit()
        }
        .font(.callout).frame(width: 176, alignment: .leading).padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

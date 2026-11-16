import SwiftUI
import RagdollCore

struct DashboardView: View {
    @EnvironmentObject var model: AppModel
    var showSessions: () -> Void
    @State private var budget = ""
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
                Card {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) { Text("7 日热力图").font(.headline); Text("按本地星期和小时显示 Token 活跃度").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            HStack(spacing: 4) { Text("少").font(.caption2).foregroundStyle(.secondary); ForEach(0..<5) { i in RoundedRectangle(cornerRadius: 3).fill(.blue.opacity(i == 0 ? 0.06 : Double(i) / 4)).frame(width: 12, height: 12) }; Text("多").font(.caption2).foregroundStyle(.secondary) }
                        }
                        heatmap(stats)
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
        let maximum = max(stats.heatmap.flatMap { $0 }.max() ?? 0, 1)
        let days = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return Grid(horizontalSpacing: 5, verticalSpacing: 5) {
            GridRow { Text("").frame(width: 35); ForEach(0..<24) { hour in Text(hour % 6 == 0 ? "\(hour):00" : "").font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.secondary).frame(maxWidth: .infinity) } }
            ForEach(0..<7) { day in
                GridRow {
                    Text(days[day]).font(.caption2).foregroundStyle(.secondary).frame(width: 35, alignment: .leading)
                    ForEach(0..<24) { hour in
                        let value = stats.heatmap[day][hour]
                        let intensity = value == 0 ? 0.055 : 0.18 + 0.82 * log1p(9 * Double(value) / Double(maximum)) / log(10)
                        Button { model.heatmapFilter = [day, hour]; showSessions() } label: {
                            RoundedRectangle(cornerRadius: 4).fill(.blue.opacity(intensity)).frame(maxWidth: .infinity).frame(height: 25)
                        }.buttonStyle(.plain).help("\(days[day]) \(hour):00 · \(value.formatted()) Token").accessibilityLabel("\(days[day]) \(hour) 点，\(value) Token")
                    }
                }
            }
        }
    }
    func empty(_ title: String, icon: String) -> some View { HStack { Image(systemName: icon); Text(title) }.foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100) }
}

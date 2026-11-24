import SwiftUI
import RagdollCore

enum Page: String, CaseIterable, Identifiable {
    case home = "首页", sessions = "会话用量", accounts = "Codex 账号", settings = "设置"
    var id: String { rawValue }
    var icon: String {
        switch self { case .home: "square.grid.2x2"; case .sessions: "chart.bar.doc.horizontal"; case .accounts: "person.2"; case .settings: "slider.horizontal.3" }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var page: Page? = .home
    var body: some View {
        Group {
            if model.needsArchiveSetup {
                VStack(spacing: 20) {
                    Image(systemName: "externaldrive.badge.checkmark").font(.system(size: 42)).foregroundStyle(.blue)
                    Text("设置 Git 用量仓库").font(.largeTitle.bold())
                    Text("请选择保存会话 Token 用量的专用 Git 仓库，也可以选择空目录创建仓库。\n应用先读取历史用量，再扫描本机新增记录。").multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("选择或创建 Git 仓库…") { model.chooseArchive() }.buttonStyle(.borderedProminent).disabled(model.loadingArchive)
                    Text("本地提交需要 Git 已配置姓名与邮箱；远端自动推送可在设置中配置。").font(.caption).foregroundStyle(.secondary)
                }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NavigationSplitView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 10) {
                            Image(systemName: "chart.bar.xaxis").font(.title2).foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Ragdoll").font(.title3.bold())
                                Text("TOKEN USAGE").font(.system(size: 8, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary).tracking(1)
                            }
                        }.padding(.horizontal, 16).padding(.top, 20)
                        List(Page.allCases, selection: $page) { item in Label(item.rawValue, systemImage: item.icon).tag(item).padding(.vertical, 5) }.listStyle(.sidebar)
                        VStack(alignment: .leading, spacing: 8) {
                            Label(model.loadingArchive ? "正在读取" : model.ready ? "本地运行" : "未连接", systemImage: "circle.fill").font(.caption).foregroundStyle(model.ready ? .green : .orange)
                            Text(model.status).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                            if !model.archiveLoaded && !model.loadingArchive { Button("重新读取仓库") { Task { await model.launch() } }.font(.caption2).buttonStyle(.link) }
                            Text("\(model.sessions.count) 个会话").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }.padding(16)
                    }.navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
                } detail: {
                    Group {
                        switch page ?? .home {
                        case .home: DashboardView { page = .sessions }
                        case .sessions: SessionUsageView()
                        case .accounts: CodexAccountsView()
                        case .settings: SettingsView()
                        }
                    }.toolbar {
                        ToolbarItem {
                            if page == .accounts { EmptyView() }
                            else if model.scanning { ProgressView().controlSize(.small) }
                            else { Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("刷新本地用量").disabled(!model.ready) }
                        }
                    }
                }
            }
        }.alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { content.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.07))) }
}

func sourceName(_ source: String) -> String {
    switch source { case "codex": "Codex"; case "claude": "Claude Code"; case "dsh": "DeepSeek Harness"; case "antigravity": "Antigravity"; case "desktop": "历史聊天用量"; case "acp": "历史 ACP 用量"; default: source }
}

func compact(_ value: Int) -> String { value.formatted(.number.notation(.compactName)) }
func money(_ value: Double) -> String { value.formatted(.currency(code: "USD")) }

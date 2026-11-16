import SwiftUI
import RagdollCore

enum Page: String, CaseIterable, Identifiable {
    case home = "首页", sessions = "会话", chat = "对话", settings = "设置"
    var id: String { rawValue }
    var icon: String {
        switch self { case .home: "square.grid.2x2"; case .sessions: "clock.arrow.circlepath"; case .chat: "bubble.left.and.bubble.right"; case .settings: "slider.horizontal.3" }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var page: Page? = .home
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up.fill").font(.title2).foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) { Text("Ragdoll").font(.title3.bold()); Text("LOCAL CONVERSATIONS").font(.system(size: 8, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary).tracking(1) }
                }.padding(.horizontal, 16).padding(.top, 20)
                List(Page.allCases, selection: $page) { item in Label(item.rawValue, systemImage: item.icon).tag(item).padding(.vertical, 5) }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Circle().fill(model.ready ? .green : .orange).frame(width: 6, height: 6); Text(model.ready ? "本地运行" : "未连接").font(.caption) }
                    Text(model.status).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                    Text("\(model.sessions.count) 个会话").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }.padding(16)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } detail: {
            Group {
                switch page ?? .home {
                case .home: DashboardView { page = .sessions }
                case .sessions: ConversationView(canCreate: false)
                case .chat: ConversationView(canCreate: true)
                case .settings: SettingsView()
                }
            }
            .toolbar {
                ToolbarItem { if model.scanning { ProgressView().controlSize(.small) } else { Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("刷新本地会话") } }
                ToolbarItem { Button { model.importDesktop() } label: { Image(systemName: "square.and.arrow.down") }.help("导入 Claude 官方导出包") }
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .sheet(item: Binding(get: { model.approvals.first }, set: { _ in })) { request in ApprovalView(request: request).environmentObject(model) }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { content.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.07))) }
}

func sourceName(_ source: String) -> String {
    switch source { case "codex": "Codex"; case "claude": "Claude Code"; case "dsh": "DeepSeek Harness"; case "desktop": "Claude 聊天"; case "acp": "ACP"; default: source }
}

func compact(_ value: Int) -> String { value.formatted(.number.notation(.compactName)) }
func money(_ value: Double) -> String { value.formatted(.currency(code: "USD")) }

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
    @State private var showingStatus = false
    var body: some View {
        Group {
            if model.needsArchiveSetup {
                VStack(spacing: 20) {
                    Image(systemName: "externaldrive.badge.checkmark").font(.system(size: 42)).foregroundStyle(.blue)
                    Text("设置 Git 数据仓库").font(.largeTitle.bold())
                    Text("请选择保存会话的专用 Git 仓库，也可以选择空目录创建仓库。\n每次打开会先读取仓库历史，再检查本机新增数据并自动归档。").multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("选择或创建 Git 仓库…") { model.chooseArchive() }.buttonStyle(.borderedProminent).disabled(model.loadingArchive)
                    Text("本地提交需要 Git 已配置姓名与邮箱；远端自动推送可在设置中配置。").font(.caption).foregroundStyle(.secondary)
                }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { content }
        }
        .alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .sheet(item: Binding(get: { model.approvals.first }, set: { _ in })) { request in ApprovalView(request: request).environmentObject(model) }
    }
    private var content: some View {
        let chat = page == .chat
        return NavigationSplitView {
            Group {
                if chat {
                    VStack(spacing: 6) {
                        ForEach(Page.allCases) { item in
                            Button { page = item } label: {
                                Image(systemName: item.icon).font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(page == item ? Color.accentColor : Color.secondary)
                                    .frame(width: 36, height: 34)
                                    .background(page == item ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).help(item.rawValue).accessibilityLabel(item.rawValue)
                            .accessibilityAddTraits(page == item ? .isSelected : [])
                        }
                        Spacer()
                        Button { showingStatus.toggle() } label: {
                            Circle().fill(model.ready ? .green : .orange).frame(width: 7, height: 7)
                                .frame(width: 36, height: 34).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("本地状态").help(model.status)
                        .popover(isPresented: $showingStatus, arrowEdge: .trailing) {
                            statusDetails.frame(width: 200, alignment: .leading).padding(16)
                        }
                    }.padding(.vertical, 12).frame(maxWidth: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 10) {
                            Image(systemName: "square.stack.3d.up.fill").font(.title2).foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 2) { Text("Ragdoll").font(.title3.bold()); Text("LOCAL CONVERSATIONS").font(.system(size: 8, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary).tracking(1) }
                        }.padding(.horizontal, 16).padding(.top, 20)
                        List(Page.allCases, selection: $page) { item in Label(item.rawValue, systemImage: item.icon).tag(item).padding(.vertical, 5) }.listStyle(.sidebar)
                        statusDetails.padding(16)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: chat ? 56 : 180, ideal: chat ? 56 : 210, max: chat ? 56 : 260)
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
                ToolbarItem { if model.scanning { ProgressView().controlSize(.small) } else { Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("刷新本地会话").disabled(!model.ready) } }
                ToolbarItem { Button { model.importDesktop() } label: { Image(systemName: "square.and.arrow.down") }.help("导入 Claude 官方导出包").disabled(!model.ready) }
            }
        }
    }
    private var statusDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(model.ready ? .green : .orange).frame(width: 6, height: 6)
                Text(model.loadingArchive ? "正在读取" : model.ready ? "本地运行" : "未连接").font(.caption)
            }
            Text(model.status).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            if !model.archiveLoaded && !model.loadingArchive {
                Button("重新读取仓库") { Task { await model.launch() } }.font(.caption2).buttonStyle(.link)
            }
            Text("\(model.sessions.count) 个会话").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
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

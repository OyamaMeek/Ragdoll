import SwiftUI
import RagdollCore

struct CodexAccountsView: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedID: String?
    private var selected: CodexAccount? {
        model.codexAccounts.first { $0.id == selectedID } ?? model.codexAccounts.first { $0.isCurrent } ?? model.codexAccounts.first
    }
    private var busy: Bool { model.codexAccountsBusy || model.warmingCodexHome != nil }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Codex 账号").font(.largeTitle.bold())
                            Text("切换本机账号，分别查看额度与激活 5h 窗口。").foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.codexAccountsBusy { ProgressView().controlSize(.small).accessibilityLabel("正在处理账号") }
                        Button { Task { await model.manageCodexAccounts("refresh") } } label: { Label("刷新额度", systemImage: "arrow.clockwise") }.disabled(busy)
                    }
                    HStack(spacing: 12) {
                        summary("账号数", value: model.codexAccounts.count, icon: "person.2", color: .blue)
                        summary("可用账号", value: model.codexAccounts.filter { $0.usageError == nil && !$0.exhausted && $0.fiveHour != nil }.count, icon: "checkmark.circle", color: .green)
                        summary("额度耗尽", value: model.codexAccounts.filter(\.exhausted).count, icon: "clock", color: .orange)
                        summary("需处理", value: model.codexAccounts.filter { $0.usageError != nil }.count, icon: "exclamationmark.circle", color: .red)
                    }
                    if let error = model.codexAccountsError {
                        Label(error + " 当前显示的数据可能尚未更新，请刷新检查。", systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    if let message = model.codexAccountsMessage { Text(message).font(.callout).textSelection(.enabled) }
                    if model.codexAccounts.isEmpty {
                        Card { Text(model.codexAccountsBusy ? "正在读取账号…" : "暂无可显示的账号。请先在已安装的 Codex Tools 中添加 ChatGPT 账号，然后刷新。 ").foregroundStyle(.secondary) }
                    } else if geometry.size.width >= 1000 {
                        HStack(alignment: .top, spacing: 18) { accountList; detail.frame(width: 300) }
                    } else {
                        accountList
                        detail
                    }
                    Text("自动激活会在当前窗口刷新后发送一次 hello，消耗少量额度。保持 Ragdoll 运行，或启用独立后台服务以便退出后继续；休眠期间不发送，恢复后检查。推理失败或进程中断后暂停，检查结果后关闭再开启。").font(.caption).foregroundStyle(.secondary)
                    Text("账号来自本机 Codex Tools。切换更新本机登录，已打开的 Codex 或 CLI 进程需重新打开后使用新账号。").font(.caption).foregroundStyle(.secondary)
                }.padding(28)
            }
        }
        .navigationTitle("Codex 账号")
        .task {
            await model.manageCodexAccounts("list")
            if model.codexAccountsError == nil { await model.manageCodexAccounts("refresh") }
        }
    }

    private func summary(_ title: String, value: Int, icon: String, color: Color) -> some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title2).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Text(value, format: .number).font(.title2.bold().monospacedDigit())
                }
            }
        }
    }

    private var accountList: some View {
        VStack(spacing: 14) {
            ForEach(model.codexAccounts) { account in
                Card {
                    VStack(alignment: .leading, spacing: 18) {
                        Button { selectedID = account.id } label: { identity(account) }.buttonStyle(.plain).accessibilityLabel("查看 \(account.displayName) 的额度")
                        HStack(alignment: .top, spacing: 24) {
                            quota("5 小时使用率", window: account.fiveHour, stale: account.usageError != nil)
                            quota("周使用率", window: account.oneWeek, stale: account.usageError != nil)
                        }
                        HStack {
                            Text(account.isCurrent ? "当前账号" : "已保存登录").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("切换") { Task { await model.manageCodexAccounts("switch", id: account.id) } }.disabled(busy || account.isCurrent)
                            Button { Task { await model.manageCodexAccounts("warmup", id: account.id) } } label: { Label("激活 5h 窗口", systemImage: "flame") }.disabled(busy)
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            Toggle("窗口刷新后自动激活", isOn: Binding(
                                get: { model.codexAutoStates[account.id]?.enabled == true },
                                set: { model.setCodexAutoActivation(account.id, enabled: $0) }
                            )).toggleStyle(.switch).controlSize(.small)
                            if let state = model.codexAutoStates[account.id], state.enabled {
                                Text(state.message).font(.caption).foregroundStyle(state.nextCheck == nil ? Color.orange : .secondary).textSelection(.enabled)
                                if let next = state.nextCheck {
                                    Text("下次检查：\(next.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }.overlay(RoundedRectangle(cornerRadius: 16).stroke(selected?.id == account.id ? Color.accentColor : .clear, lineWidth: 1.5))
            }
        }.frame(maxWidth: .infinity)
    }

    @ViewBuilder private var detail: some View {
        if let account = selected {
            Card {
                VStack(alignment: .leading, spacing: 24) {
                    Text("账号详情").font(.headline)
                    identity(account)
                    Divider()
                    quota("5 小时使用率", window: account.fiveHour, stale: account.usageError != nil)
                    quota("周使用率", window: account.oneWeek, stale: account.usageError != nil)
                    if let error = account.usageError { Text(error).font(.caption).foregroundStyle(.orange) }
                    if let time = account.fetchedAt {
                        Text("额度更新时间：\(Date(timeIntervalSince1970: time).formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func identity(_ account: CodexAccount) -> some View {
        HStack(spacing: 12) {
            Text(String(account.displayName.prefix(1)).uppercased()).font(.title2.bold()).foregroundStyle(.tint)
                .frame(width: 46, height: 46).background(Color.accentColor.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(account.planType.isEmpty ? "套餐未知" : account.planType.uppercased()).font(.caption.bold()).foregroundStyle(.tint)
                    Text(account.state).font(.caption).foregroundStyle(account.usageError != nil ? Color.orange : account.exhausted ? .orange : account.isCurrent ? .blue : .green)
                }
                Text(account.displayName).font(.headline).lineLimit(2).textSelection(.enabled)
            }
            Spacer(minLength: 0)
            if account.isCurrent { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue).accessibilityLabel("当前账号") }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func quota(_ title: String, window: CodexAccount.Window?, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(window.map { "\($0.usedPercent.formatted(.number.precision(.fractionLength(0...1))))%" } ?? "未知").font(.callout.bold().monospacedDigit())
            }
            if let window {
                ProgressView(value: window.usedPercent, total: 100).tint(window.exhausted ? .orange : .accentColor)
                Text("剩余 \((100 - window.usedPercent).formatted(.number.precision(.fractionLength(0...1))))%\(stale ? " · 尚未更新" : "")").font(.caption).foregroundStyle(.secondary)
                if let reset = window.resetAt, reset > Date().timeIntervalSince1970 {
                    Text("重置：\(Date(timeIntervalSince1970: reset).formatted(date: .numeric, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                } else { Text("等待服务端更新窗口").font(.caption).foregroundStyle(.secondary) }
            } else { Text("尚未取得额度").font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

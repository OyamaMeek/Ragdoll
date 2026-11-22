import SwiftUI
import RagdollCore

struct CodexMessageScheduleView: View {
    @EnvironmentObject var model: AppModel
    let account: CodexAccount
    @State private var project = ""
    @State private var sessionID = ""
    @State private var text = ""

    private var state: CodexScheduledMessage.State? { model.codexMessageStates[account.id] }
    private var waiting: Bool { state?.enabled == true }
    private var sessions: [Session] { model.codexMessageSessions.filter { $0.project == project } }
    private var projects: [String] { model.codexMessageProjects }
    private var canSchedule: Bool {
        !model.codexAccountsBusy && model.warmingCodexHome == nil && account.isCurrent && account.usageError == nil &&
        (account.fiveHour?.resetAt ?? 0) > Date().timeIntervalSince1970 &&
        sessions.contains(where: { $0.id == sessionID }) && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("下次额度刷新后发送一次").font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                Picker("项目", selection: $project) {
                    Text("选择项目").tag("")
                    ForEach(projects, id: \.self) { path in Text(path).tag(path) }
                }
                Picker("会话", selection: $sessionID) {
                    Text("选择会话").tag("")
                    ForEach(sessions) { session in Text("\(session.title) · \(session.nativeID.prefix(8))").tag(session.id) }
                }
                Text("发送内容").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $text).font(.body).frame(minHeight: 70, maxHeight: 110)
                    .padding(5).background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    .accessibilityLabel("额度刷新后发送的消息")
            }.disabled(waiting)
            HStack {
                if waiting {
                    Button("取消计划") { model.cancelCodexMessage(account.id) }
                } else {
                    Button("设置一次性发送") { model.scheduleCodexMessage(account.id, sessionID: sessionID, text: text) }
                        .disabled(!canSchedule)
                }
                Spacer()
            }
            if let state {
                if waiting {
                    Text("目标：\(state.target.title)\n\(state.target.project)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text(state.message).font(.caption).foregroundStyle(waiting && state.nextCheck == nil ? Color.orange : .secondary).textSelection(.enabled)
                if let next = state.nextCheck {
                    Text("预计检查：\(next.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !account.isCurrent {
                Text("请先切换到此账号。发送时仍需保持为桌面端当前登录。").font(.caption).foregroundStyle(.secondary)
            }
            if projects.isEmpty {
                Text("尚无可选的桌面端 Codex 会话，请先完成本机用量扫描。").font(.caption).foregroundStyle(.secondary)
            }
            Text("只发送一次，由桌面端原会话按原设置继续执行；消息会消耗额度。保持 Ragdoll 运行或启用后台服务，电脑休眠时会延后。结果不明时先查看原会话，再取消并重新设置。").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { restoreSelection() }
        .onChange(of: state?.generation) { _, _ in restoreSelection() }
        .onChange(of: project) { _, _ in
            if !sessions.contains(where: { $0.id == sessionID }) { sessionID = "" }
        }
    }

    private func restoreSelection() {
        guard let target = state?.target else { return }
        project = target.project
        sessionID = model.codexMessageSessions.first(where: { $0.nativeID == target.nativeID && $0.home == target.home })?.id ?? ""
        text = target.text
    }
}

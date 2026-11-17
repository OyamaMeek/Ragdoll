import SwiftUI
import RagdollCore

struct MigrationView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let session: Session
    @State private var targetID = ""
    @State private var cwd = ""
    @State private var migrating = false
    @State private var authorizedAttachments: [URL] = []
    var targets: [AgentConfig] { model.settings.agents.filter { ["codex", "claude", "dsh"].contains($0.kind) && $0.kind != session.source } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("迁移到其他工具").font(.title2.bold())
            Text(session.title).font(.headline).lineLimit(2)
            Text("在目标工具创建新的原生历史，保留原会话。目标不支持的推理和工具记录将以带来源标记的全文历史展示，旧用量仍归属原会话。").font(.callout).foregroundStyle(.secondary)
            Form {
                Picker("目标工具", selection: $targetID) { ForEach(targets) { Text($0.name).tag($0.id) } }
                HStack { TextField("目标项目目录", text: $cwd); Button("选择…") { if let path = model.chooseProject() { cwd = path } } }
                Text("来源：\(sourceName(session.source)) · \(session.messages.count) 条已索引消息；转换将读取完整原始记录和附件。").font(.caption)
                HStack {
                    Button("授权项目外附件…") { authorizedAttachments += model.chooseAttachments().filter { !authorizedAttachments.contains($0) } }
                    Text("已选择 \(authorizedAttachments.count) 个文件").font(.caption)
                }
                if session.source == "claude" || targets.first(where: { $0.id == targetID })?.kind == "claude" { Text("Claude 原生迁移未验证").foregroundStyle(.orange) }
            }
            HStack {
                Button("取消") { dismiss() }.disabled(migrating)
                Spacer()
                if migrating { ProgressView().controlSize(.small) }
                Button("迁移") {
                    guard let agent = targets.first(where: { $0.id == targetID }) else { return }
                    migrating = true
                    Task { let success = await model.migrateSelected(agent: agent, cwd: cwd, authorizedAttachments: authorizedAttachments); migrating = false; if success { dismiss() } }
                }.buttonStyle(.borderedProminent).disabled(migrating || targetID.isEmpty || cwd.isEmpty || !model.ready)
            }
        }.padding(28).frame(width: 600)
        .onAppear { targetID = targets.first?.id ?? ""; cwd = session.project.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : session.project }
        .interactiveDismissDisabled(migrating)
    }
}

import SwiftUI
import RagdollCore

struct AgentOptionsView: View {
    @EnvironmentObject var model: AppModel
    let session: Session
    @Binding var prompt: String
    var info: JSONValue { model.conversationInfo[session.id] ?? .object([:]) }
    var body: some View {
        HStack(spacing: 10) {
            if session.source != "acp" {
                TextField("默认模型", text: $model.composerModel).textFieldStyle(.plain).font(.caption).frame(width: 120)
                if !info["models"]["data"].array.isEmpty {
                    Menu { ForEach(Array(info["models"]["data"].array.enumerated()), id: \.offset) { _, entry in Button(entry["displayName"].string) { model.composerModel = entry["model"].string } } } label: { Image(systemName: "chevron.down") }.menuStyle(.borderlessButton).fixedSize()
                }
            } else {
                Menu("模型与权限") {
                    ForEach(Array(info["configOptions"].array.enumerated()), id: \.offset) { _, option in
                        if option["type"].string == "boolean" {
                            Toggle(option["name"].string, isOn: Binding(get: { option["currentValue"] == .bool(true) }, set: { value in Task { await model.configure(configID(option), value: String(value)) } }))
                        } else {
                            Menu(option["name"].string) {
                                ForEach(Array(values(option).enumerated()), id: \.offset) { _, value in Button(value["name"].string) { Task { await model.configure(configID(option), value: value["value"].string.isEmpty ? value["id"].string : value["value"].string) } } }
                            }
                        }
                    }
                    ForEach(Array(info["models"]["availableModels"].array.enumerated()), id: \.offset) { _, value in Button(value["name"].string) { Task { await model.configure("__legacy_model", value: value["modelId"].string) } } }
                    ForEach(Array(info["modes"]["availableModes"].array.enumerated()), id: \.offset) { _, value in Button(value["name"].string) { Task { await model.configure("__legacy_mode", value: value["id"].string) } } }
                    if info["configOptions"].array.isEmpty && info["models"]["availableModels"].array.isEmpty && info["modes"]["availableModes"].array.isEmpty { Text("Agent 未提供可选配置") }
                }.font(.caption).disabled(model.running.contains(session.id))
                if !info["availableCommands"].array.isEmpty {
                    Menu("命令") { ForEach(Array(info["availableCommands"].array.enumerated()), id: \.offset) { _, command in Button(command["name"].string) { prompt = "/\(command["name"].string) " } } }.font(.caption)
                }
            }
        }
    }
    func configID(_ option: JSONValue) -> String { option["configId"].string.isEmpty ? option["id"].string : option["configId"].string }
    func values(_ option: JSONValue) -> [JSONValue] { option["options"].array.flatMap { value in value["options"].array.isEmpty ? [value] : value["options"].array } }
}

struct NativeHistoryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let agent: AgentConfig
    @State private var importing: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("导入 \(agent.name) 历史会话").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            Text(model.nativeHistoryProject).font(.caption).foregroundStyle(.secondary)
            List(Array(model.nativeHistory.enumerated()), id: \.offset) { _, entry in
                HStack {
                    VStack(alignment: .leading, spacing: 6) { Text(entry["title"].string.isEmpty ? entry["sessionId"].string : entry["title"].string); Text(entry["cwd"].string).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if importing == entry["sessionId"].string { ProgressView().controlSize(.small) }
                    Button("导入") { importing = entry["sessionId"].string; Task { if await model.importNative(agent, record: entry) { dismiss() }; importing = nil } }.disabled(importing != nil)
                }.padding(.vertical, 8)
            }
            if !model.nativeCursor.isEmpty { Button("加载更多") { Task { await model.listNative(agent, project: model.nativeHistoryProject, more: true) } } }
        }.padding(24).frame(width: 760, height: 560)
    }
}

import SwiftUI
import RagdollCore

struct AgentOptionsView: View {
    @EnvironmentObject var model: AppModel
    let session: Session
    @Binding var prompt: String
    var info: JSONValue { model.conversationInfo[session.id] ?? .object([:]) }
    private var selection: Binding<ComposerSelection> {
        Binding(
            get: { model.composerSelections[session.id] ?? ComposerSelection() },
            set: { model.composerSelections[session.id] = $0 }
        )
    }
    var body: some View {
        HStack(spacing: 10) {
            if session.source == "codex" {
                CodexModelPicker(session: session, info: info, selection: selection)
                    .disabled(!model.ready || model.running.contains(session.id))
            } else if session.source != "acp" {
                TextField("默认模型", text: selection.model).textFieldStyle(.plain).font(.caption).frame(width: 120)
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

private struct CodexModelPicker: View {
    @EnvironmentObject var model: AppModel
    let session: Session
    let info: JSONValue
    @Binding var selection: ComposerSelection
    @State private var showing = false
    @State private var loadError: String?

    private var models: [JSONValue] { info["models"]["data"].array.filter { !$0["model"].string.isEmpty } }
    private var activeModel: JSONValue? {
        let id = selection.model.isEmpty ? info["model"].string : selection.model
        return id.isEmpty ? models.first { $0["isDefault"] == .bool(true) } : models.first { $0["model"].string == id }
    }
    private var supportedEfforts: [String] {
        activeModel?["supportedReasoningEfforts"].array.map { $0["reasoningEffort"].string }.filter { !$0.isEmpty } ?? []
    }
    private var defaultEffort: String {
        let configured = info["reasoningEffort"].string
        if (selection.model.isEmpty || selection.model == info["model"].string), supportedEfforts.contains(configured) {
            return configured
        }
        return activeModel?["defaultReasoningEffort"].string ?? ""
    }
    private var modelLabel: String {
        if selection.model.isEmpty { return "默认模型" }
        let name = activeModel?["displayName"].string ?? ""
        return name.isEmpty ? selection.model : name
    }

    var body: some View {
        let effort = selection.effort.isEmpty ? defaultEffort : selection.effort
        Button { showing.toggle() } label: {
            HStack(spacing: 5) {
                Text(modelLabel).lineLimit(1)
                if supportedEfforts.contains(effort) { Text(effortLabel(effort)).foregroundStyle(.secondary) }
                Image(systemName: "chevron.down").imageScale(.small).foregroundStyle(.secondary)
            }.font(.caption)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .accessibilityLabel("选择模型")
        .accessibilityValue(supportedEfforts.contains(effort) ? "\(modelLabel)，\(effortLabel(effort))" : modelLabel)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("选择模型").font(.headline)
                modelRow("默认模型", id: "")
                if let loadError {
                    Text(loadError).font(.caption).foregroundStyle(.secondary)
                } else if info["models"] == .null {
                    ProgressView("正在加载模型…").controlSize(.small)
                } else if models.isEmpty {
                    Text("Codex 未提供可选模型").font(.caption).foregroundStyle(.secondary)
                } else {
                    let entries = models
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(entries.indices, id: \.self) { index in
                                let entry = entries[index]
                                let id = entry["model"].string
                                let name = entry["displayName"].string
                                modelRow(name.isEmpty ? id : name, id: id)
                            }
                        }
                    }.frame(height: min(CGFloat(entries.count * 31), 260))
                }
                if !supportedEfforts.isEmpty {
                    Divider()
                    Picker("推理强度", selection: $selection.effort) {
                        Text(defaultEffort.isEmpty ? "默认" : "默认（\(effortLabel(defaultEffort))）").tag("")
                        ForEach(supportedEfforts, id: \.self) { Text(effortLabel($0)).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
            }
            .padding(14)
            .frame(width: 284)
            .task {
                loadError = nil
                do { try await model.loadCodexModels(for: session) }
                catch { loadError = error.localizedDescription }
            }
        }
    }

    private func modelRow(_ name: String, id: String) -> some View {
        Button { selection.model = id } label: {
            HStack {
                Text(name)
                Spacer()
                if selection.model == id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selection.model == id ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection.model == id ? .isSelected : [])
    }

    private func effortLabel(_ effort: String) -> String {
        switch effort {
        case "none": "关闭"
        case "minimal": "最低"
        case "low": "低"
        case "medium": "中"
        case "high": "高"
        case "xhigh": "极高"
        case "max": "最高"
        case "ultra": "超高"
        default: effort
        }
    }
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

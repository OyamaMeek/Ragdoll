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
                let catalog = ACPModelOptions(info: info)
                let options = info["configOptions"].array.filter { $0 != catalog.modelOption && !catalog.relatedOptions.contains($0) }
                let modes = info["modes"]["availableModes"].array
                let disabled = model.running.contains(session.id) || model.configuringChats.contains(session.id)
                ACPModelPicker(session: session, catalog: catalog, connected: info["protocolVersion"] != .null)
                    .disabled(!model.ready || disabled)
                if !options.isEmpty || !modes.isEmpty {
                    Menu("会话选项") {
                        ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                            ACPConfigControl(sessionID: session.id, option: option)
                        }
                        ForEach(Array(modes.enumerated()), id: \.offset) { _, mode in
                            Button(mode["name"].string) { Task { await model.configure(session.id, configID: "__legacy_mode", value: mode["id"]) } }
                        }
                    }.font(.caption).disabled(disabled)
                }
                if !info["availableCommands"].array.isEmpty {
                    Menu("命令") { ForEach(Array(info["availableCommands"].array.enumerated()), id: \.offset) { _, command in Button(command["name"].string) { prompt = "/\(command["name"].string) " } } }.font(.caption)
                }
            }
        }
    }
}

struct ModelChoice: Identifiable {
    let id: String
    let name: String
    var group: String? = nil
}

struct ACPModelOptions {
    let modelOption: JSONValue?
    let configID: String
    let current: String
    let choices: [ModelChoice]
    let relatedOptions: [JSONValue]

    init(info: JSONValue) {
        let options = info["configOptions"].array
        let selectors = options.filter { $0["type"].string == "select" && !Self.id($0).isEmpty }
        modelOption = selectors.first { $0["category"].string == "model" }
            ?? selectors.first { $0["category"] == .null && Self.id($0) == "model" }
        if let modelOption {
            configID = Self.id(modelOption)
            current = modelOption["currentValue"].string
            choices = Self.choices(modelOption)
        } else {
            let models = info["models"]
            configID = "__legacy_model"
            current = models["currentModelId"].string
            choices = models["availableModels"].array.compactMap { Self.choice($0["modelId"].string, name: $0["name"].string) }
        }
        relatedOptions = options.filter { ["model_config", "thought_level"].contains($0["category"].string) }
    }

    static func id(_ option: JSONValue) -> String {
        option["configId"].string.isEmpty ? option["id"].string : option["configId"].string
    }

    static func choices(_ option: JSONValue) -> [ModelChoice] {
        option["options"].array.flatMap { entry in
            if entry["options"] != .null {
                return entry["options"].array.compactMap { selectChoice($0, group: entry["name"].string) }
            }
            return selectChoice(entry).map { [$0] } ?? []
        }
    }

    private static func selectChoice(_ option: JSONValue, group: String? = nil) -> ModelChoice? {
        choice(option["value"].string.isEmpty ? option["id"].string : option["value"].string, name: option["name"].string, group: group)
    }

    private static func choice(_ id: String, name: String, group: String? = nil) -> ModelChoice? {
        guard !id.isEmpty else { return nil }
        return ModelChoice(id: id, name: name.isEmpty ? id : name, group: group)
    }
}

private struct ACPConfigControl: View {
    @EnvironmentObject var model: AppModel
    let sessionID: String
    let option: JSONValue

    var body: some View {
        let id = ACPModelOptions.id(option)
        let name = option["name"].string
        if !id.isEmpty {
            switch option["type"].string {
            case "boolean":
                Toggle(name, isOn: Binding(get: { option["currentValue"] == .bool(true) }, set: { value in
                    Task { await model.configure(sessionID, configID: id, value: .bool(value)) }
                }))
            case "select":
                Picker(name, selection: Binding(get: { option["currentValue"].string }, set: { value in
                    Task { await model.configure(sessionID, configID: id, value: .string(value)) }
                })) {
                    ForEach(ACPModelOptions.choices(option)) { Text($0.name).tag($0.id) }
                }.pickerStyle(.menu)
            default:
                EmptyView()
            }
        }
    }
}

private struct ACPModelPicker: View {
    @EnvironmentObject var model: AppModel
    let session: Session
    let catalog: ACPModelOptions
    let connected: Bool
    @State private var loadFailed = false

    var body: some View {
        let active = catalog.choices.first { $0.id == catalog.current }
        let name = active?.name ?? (catalog.current.isEmpty ? "选择模型" : catalog.current)
        let reasoning = catalog.relatedOptions.first { $0["category"].string == "thought_level" && $0["type"].string == "select" }
        let level = reasoning.flatMap { option in ACPModelOptions.choices(option).first { $0.id == option["currentValue"].string }?.name }
        ComposerModelPicker(name: name, detail: level) {
            Group {
                if !connected {
                    if loadFailed { Text("无法读取 ACP 会话模型").font(.caption).foregroundStyle(.secondary) }
                    else { ProgressView("正在连接 Agent…").controlSize(.small) }
                } else if catalog.choices.isEmpty {
                    Text("此 Agent 未提供可选模型").font(.caption).foregroundStyle(.secondary)
                } else {
                    ModelChoiceList(choices: catalog.choices, current: catalog.current) { id in
                        Task { await model.configure(session.id, configID: catalog.configID, value: .string(id)) }
                    }
                }
                if !catalog.relatedOptions.isEmpty {
                    Divider()
                    ForEach(Array(catalog.relatedOptions.enumerated()), id: \.offset) { _, option in
                        ACPConfigControl(sessionID: session.id, option: option)
                    }
                }
            }.disabled(model.configuringChats.contains(session.id))
                .task {
                    loadFailed = false
                    loadFailed = !(await model.loadACPModels(for: session))
                }
        }
    }
}

private struct ComposerModelPicker<Content: View>: View {
    let name: String
    let detail: String?
    @ViewBuilder let content: () -> Content
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 5) {
                Text(name).lineLimit(1)
                if let detail { Text(detail).foregroundStyle(.secondary) }
                Image(systemName: "chevron.down").imageScale(.small).foregroundStyle(.secondary)
            }.font(.caption)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .accessibilityLabel("选择模型")
        .accessibilityValue(detail.map { "\(name)，\($0)" } ?? name)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("选择模型").font(.headline)
                content()
            }
            .padding(14)
            .frame(width: 284)
        }
    }
}

private struct ModelChoiceList: View {
    let choices: [ModelChoice]
    let current: String
    let choose: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(choices) { choice in
                    ModelChoiceRow(choice: choice, selected: choice.id == current) { choose(choice.id) }
                }
            }
        }.frame(height: min(CGFloat(choices.count * 31), 260))
    }
}

private struct ModelChoiceRow: View {
    let choice: ModelChoice
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack {
                Text(choice.name).lineLimit(1)
                Spacer()
                if let group = choice.group, !group.isEmpty { Text(group).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct CodexModelPicker: View {
    @EnvironmentObject var model: AppModel
    let session: Session
    let info: JSONValue
    @Binding var selection: ComposerSelection
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
        ComposerModelPicker(name: modelLabel, detail: supportedEfforts.contains(effort) ? effortLabel(effort) : nil) {
            Group {
                ModelChoiceRow(choice: ModelChoice(id: "", name: "默认模型"), selected: selection.model.isEmpty) {
                    selection.model = ""
                }
                if let loadError {
                    Text(loadError).font(.caption).foregroundStyle(.secondary)
                } else if info["models"] == .null {
                    ProgressView("正在加载模型…").controlSize(.small)
                } else if models.isEmpty {
                    Text("Codex 未提供可选模型").font(.caption).foregroundStyle(.secondary)
                } else {
                    ModelChoiceList(choices: models.map { entry in
                        let id = entry["model"].string
                        let name = entry["displayName"].string
                        return ModelChoice(id: id, name: name.isEmpty ? id : name)
                    }, current: selection.model) { selection.model = $0 }
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
            .task {
                loadError = nil
                do { try await model.loadCodexModels(for: session) }
                catch { loadError = error.localizedDescription }
            }
        }
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

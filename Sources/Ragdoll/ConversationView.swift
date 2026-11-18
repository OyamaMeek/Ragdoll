import SwiftUI
import RagdollCore

struct ConversationView: View {
    private struct NewChatRequest: Identifiable {
        let project: String
        var id: String { project }
    }

    @EnvironmentObject var model: AppModel
    var canCreate: Bool
    @State private var newChat: NewChatRequest?
    @State private var migrating = false
    @State private var prompt = ""
    @State private var messageLimit = 100
    @State private var sending = false
    @State private var attachments: [URL] = []
    var body: some View {
        let sessions = model.filtered
        let selection = Binding(get: { model.selectedID }, set: { id in
            DispatchQueue.main.async { model.select(id) }
        })
        HSplitView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    if canCreate {
                        Button { createChat(in: model.project) } label: {
                            Label("新建对话", systemImage: "square.and.pencil")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Text("历史会话").font(.headline)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                        TextField("搜索标题与消息", text: $model.query).textFieldStyle(.plain)
                        if !model.query.isEmpty {
                            Button("清除搜索", systemImage: "xmark.circle.fill") { model.query = "" }
                                .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
                    .onChange(of: model.query) { _, _ in do { try model.reload() } catch { model.error = error.localizedDescription } }
                    HStack {
                        if canCreate {
                            Text(model.query.isEmpty ? "项目" : "搜索结果").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .accessibilityAddTraits(.isHeader)
                        }
                        Picker("来源", selection: $model.source) {
                            Text("全部来源").tag("all")
                            ForEach(["codex", "claude", "dsh", "desktop", "acp"], id: \.self) { Text(sourceName($0)).tag($0) }
                        }.labelsHidden().pickerStyle(.menu).controlSize(.small)
                        if !model.project.isEmpty || model.heatmapFilter != nil {
                            Button("清除筛选") { model.project = ""; model.heatmapFilter = nil }.font(.caption)
                        }
                    }
                }.padding(12)
                if canCreate {
                    ConversationProjectList(
                        sessions: sessions, selection: selection, selectedProject: model.selected?.project,
                        running: model.running, searching: !model.query.isEmpty, createChat: createChat(in:)
                    )
                } else {
                    historyList(sessions, selection: selection)
                }
                Divider()
                Text("\(sessions.count) 个会话").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 9)
            }
            .frame(minWidth: 245, idealWidth: 270, maxWidth: 340, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            if let session = model.selected {
                let groups = session.conversationGroups
                VStack(spacing: 0) {
                    header(session)
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 24) {
                                if groups.count > messageLimit { Button("加载更早的消息（剩余 \(groups.count - messageLimit) 项）") { messageLimit += 100 }.frame(maxWidth: .infinity) }
                                ForEach(Array(groups.suffix(messageLimit))) { group in ConversationGroupView(group: group) }
                                if groups.isEmpty { ContentUnavailableView("尚无消息", systemImage: "bubble.left", description: Text("恢复会话后可在下方输入消息。")) }
                                Color.clear.frame(height: 1).id("bottom")
                            }.padding(28).frame(maxWidth: 880).frame(maxWidth: .infinity)
                        }
                        .defaultScrollAnchor(.bottom, for: .initialOffset)
                        .onChange(of: model.selected?.messages.last?.text) { _, _ in if sending { proxy.scrollTo("bottom", anchor: .bottom) } }
                    }
                    .id(session.id)
                    if !session.warnings.isEmpty { Text(session.warnings.joined(separator: " · ")).font(.caption2).foregroundStyle(.orange).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 8) }
                    if session.source == "desktop" {
                        HStack { Text("官方导出记录 · 更新时需重新导入").foregroundStyle(.secondary); Spacer(); Button("打开原聊天") { model.openDesktop(session) } }.padding(20)
                    } else { composer(session) }
                }.frame(minWidth: 550).background(Color(nsColor: .textBackgroundColor))
            } else {
                ContentUnavailableView {
                    Label(canCreate ? "开始一段对话" : "选择一个历史会话", systemImage: "bubble.left.and.bubble.right")
                } actions: {
                    if canCreate {
                        Button("新建对话") { createChat(in: model.project) }.buttonStyle(.borderedProminent)
                    } else {
                        Button("导入 Claude 聊天…") { model.importDesktop() }
                    }
                }
                .frame(minWidth: 550, maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .navigationTitle(canCreate ? "对话" : "会话")
        .onChange(of: model.selectedID) { _, _ in messageLimit = 100 }
        .sheet(item: $newChat) { request in NewChatView(project: request.project).environmentObject(model) }
        .sheet(isPresented: $migrating) { if let session = model.selected { MigrationView(session: session).environmentObject(model) } }
    }
    private func createChat(in project: String) {
        newChat = NewChatRequest(project: project)
    }
    private func historyList(_ sessions: [Session], selection: Binding<String?>) -> some View {
        List(selection: selection) {
            ForEach(sessions) { session in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .top) {
                        Text(session.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                        Spacer(minLength: 0)
                        if model.running.contains(session.id) { ProgressView().controlSize(.mini) }
                    }
                    HStack { Text(sourceName(session.source)); Spacer(); Text(session.usage.isEmpty ? "用量未知" : compact(session.tokens)) }.font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(session.projectName).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                }.padding(.vertical, 7).tag(session.id)
            }
        }.listStyle(.sidebar).scrollContentBackground(.hidden)
    }
    func header(_ session: Session) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(session.title).font(.system(size: 15, weight: .semibold)).lineLimit(1).help(session.title)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 8) {
                    Text(sourceName(session.source))
                    Label(session.projectName, systemImage: "folder")
                        .help(session.project.isEmpty ? session.projectName : session.project)
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
            }
            Spacer()
            Button("迁移…", systemImage: "arrow.left.arrow.right") { migrating = true }
                .buttonStyle(.borderless).disabled(model.running.contains(session.id) || !model.ready)
            if session.source != "desktop" {
                Button("恢复会话", systemImage: "arrow.counterclockwise") { Task { await model.resumeSelected() } }
                    .disabled(sending || model.running.contains(session.id))
            }
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }
    func composer(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !attachments.isEmpty {
                HStack { ForEach(attachments, id: \.self) { url in Button { attachments.removeAll { $0 == url } } label: { Label(url.lastPathComponent, systemImage: "xmark.circle").lineLimit(1) }.font(.caption) } }
            }
            ZStack(alignment: .topLeading) {
                if prompt.isEmpty { Text("输入消息，继续此会话…").foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false) }
                TextEditor(text: $prompt).font(.body).scrollContentBackground(.hidden).accessibilityLabel("消息")
            }.frame(height: 64)
            HStack {
                Button { attachments += model.chooseAttachments().filter { !attachments.contains($0) } } label: { Image(systemName: "paperclip") }.buttonStyle(.plain).help("添加附件，图片能力由 Agent 决定")
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(session.projectName).font(.caption).foregroundStyle(.secondary)
                Spacer()
                AgentOptionsView(session: session, prompt: $prompt)
                    .id(session.id)
                    .disabled(sending)
                if sending || model.running.contains(session.id) {
                    Button { Task { await model.stop(); sending = false } } label: {
                        Image(systemName: "stop.fill").frame(width: 22, height: 22)
                    }.buttonStyle(.bordered).buttonBorderShape(.circle)
                        .accessibilityLabel("停止当前执行").help("停止当前执行")
                } else {
                    Button {
                        let text = prompt, files = attachments; prompt = ""; attachments = []; sending = true
                        Task { if !(await model.send(text, attachments: files)) { if prompt.isEmpty { prompt = text }; if attachments.isEmpty { attachments = files } }; sending = false }
                    } label: {
                        Image(systemName: "arrow.up").fontWeight(.semibold).frame(width: 22, height: 22)
                    }.buttonStyle(.borderedProminent).buttonBorderShape(.circle)
                        .accessibilityLabel("发送").help("发送（⌘↩）").keyboardShortcut(.return, modifiers: .command)
                        .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.ready)
                }
            }
        }
        .padding(14)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.10)).allowsHitTesting(false) }
        .padding(.horizontal, 28).frame(maxWidth: 880).frame(maxWidth: .infinity)
        .padding(.top, 10).padding(.bottom, 20)
    }
}

extension Session {
    var conversationMessages: [Message] { messages.filter { $0.role != "tool" && $0.role != "function" && $0.kind != "tool" } }

    var conversationGroups: [ConversationGroup] {
        var groups: [ConversationGroup] = []
        for message in conversationMessages {
            if message.isSystemPrompt, let last = groups.indices.last, groups[last].messages.last?.isSystemPrompt == true {
                groups[last].messages.append(message)
            } else {
                groups.append(ConversationGroup(id: message.id, messages: [message]))
            }
        }
        return groups
    }
}

struct ConversationGroup: Identifiable {
    let id: String
    var messages: [Message]
}

extension Message {
    var isSystemPrompt: Bool {
        if role == "system" || role == "developer" { return true }
        guard role == "user", !text.contains("## My request:") else { return false }
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["# AGENTS.md instructions for ", "<environment_context>", "<permissions instructions>", "<INSTRUCTIONS>"].contains { prompt.hasPrefix($0) }
    }
}

struct ConversationGroupView: View {
    let group: ConversationGroup
    var body: some View {
        if group.messages.first?.isSystemPrompt == true {
            DisclosureGroup {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(group.messages) { message in MessageView(message: message) }
                }.padding(.top, 10)
            } label: {
                Label("system prompt", systemImage: "text.alignleft").font(.callout.weight(.medium)).foregroundStyle(.secondary)
            }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        } else {
            ForEach(group.messages) { message in MessageView(message: message) }
        }
    }
}

struct MessageView: View {
    let message: Message
    @State private var expanded = false
    var body: some View {
        if message.isSystemPrompt {
            DisclosureGroup(isExpanded: $expanded) {
                Text(message.text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
            } label: {
                Label("系统提示词", systemImage: "text.alignleft").font(.caption).foregroundStyle(.secondary)
            }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        } else if message.role == "user" {
            HStack(alignment: .top, spacing: 12) {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(message.text).font(.body).lineSpacing(5).textSelection(.enabled)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                    timestamp
                }.frame(maxWidth: 620, alignment: .trailing)
                avatar("person.fill", label: "你")
            }.frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            HStack(alignment: .top, spacing: 12) {
                avatar("sparkles", label: "助手")
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text("助手").font(.caption.weight(.semibold))
                        timestamp
                    }.frame(height: 28)
                    Text(.init(message.text)).textSelection(.enabled).font(.body).lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
    var timestamp: some View {
        Text(Date(timeIntervalSince1970: message.time / 1000), style: .time).font(.caption2).foregroundStyle(.tertiary)
    }
    func avatar(_ symbol: String, label: String) -> some View {
        Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(.tint).frame(width: 28, height: 28)
            .background(.tint.opacity(0.12), in: Circle()).accessibilityLabel(label)
    }
}

struct NewChatView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let project: String
    @State private var agentID = ""
    @State private var cwd = ""
    @State private var initialModel = ""
    @State private var starting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("新建对话").font(.title2.bold())
            Text("选择原生工具或 ACP Agent，在本地项目中开始对话。").foregroundStyle(.secondary)
            Form {
                Picker("Agent", selection: $agentID) {
                    ForEach(model.settings.agents) { agent in Text("\(agent.name) · \(agent.kind == "acp" ? "ACP" : "原生")").tag(agent.id) }
                }
                HStack { TextField("工作目录", text: $cwd); Button("选择…") { if let path = model.chooseProject() { cwd = path } } }
                if model.settings.agents.first(where: { $0.id == agentID })?.kind != "acp" { TextField("模型（留空使用默认值）", text: $initialModel) }
                else { Text("创建后可选择 Agent 提供的模型与权限选项").font(.caption).foregroundStyle(.secondary) }
            }
            HStack { Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); if starting { ProgressView().controlSize(.small) }; Button("创建对话") {
                guard let agent = model.settings.agents.first(where: { $0.id == agentID }) else { return }
                starting = true
                Task { let created = await model.startChat(agent: agent, cwd: cwd, model: initialModel); starting = false; if created { dismiss() } }
            }.buttonStyle(.borderedProminent).disabled(starting || cwd.isEmpty || agentID.isEmpty) }
        }.padding(28).frame(width: 540).onAppear {
            agentID = model.settings.agents.first?.id ?? ""
            cwd = project.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : project
        }
        .onChange(of: agentID) { _, _ in initialModel = "" }
    }
}

struct ApprovalView: View {
    @EnvironmentObject var model: AppModel
    let request: Approval
    @State private var response = "{}"
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Agent 请求你的确认", systemImage: "hand.raised").font(.title3.bold())
            Text(request.method).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            ScrollView { Text(request.params.text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 300)
            if request.method.contains("question") || request.method.contains("UserInput") || request.method.contains("AskUserQuestion") || request.method.contains("elicitation") {
                Text("结构化回答（JSON）").font(.caption)
                TextEditor(text: $response).font(.system(size: 11, design: .monospaced)).frame(height: 100).border(.quaternary)
            }
            HStack {
                Button("拒绝", role: .cancel) { Task { await model.answer(request, allowed: false) } }
                Spacer()
                ForEach(Array(request.params["options"].array.enumerated()), id: \.offset) { _, option in
                    Button(option["name"].string) { Task { await model.answer(request, allowed: option["kind"].string.hasPrefix("allow"), optionID: option["optionId"].string) } }
                }
                if request.params["options"].array.isEmpty { Button("允许一次 / 提交回答") {
                    do { let value = try JSONDecoder().decode(JSONValue.self, from: Data(response.utf8)); Task { await model.answer(request, allowed: true, content: value) } }
                    catch { model.error = "回答不是有效 JSON：\(error.localizedDescription)" }
                }.buttonStyle(.borderedProminent) }
            }
        }.padding(24).frame(width: 650).interactiveDismissDisabled()
    }
}

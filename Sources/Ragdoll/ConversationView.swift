import SwiftUI
import RagdollCore

struct ConversationView: View {
    @EnvironmentObject var model: AppModel
    var canCreate: Bool
    @State private var newChat = false
    @State private var prompt = ""
    @State private var messageLimit = 100
    @State private var sending = false
    @State private var showEvents = false
    @State private var attachments: [URL] = []
    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text(canCreate ? "对话" : "历史会话").font(.headline)
                    Spacer()
                    if canCreate { Button { newChat = true } label: { Image(systemName: "square.and.pencil") }.buttonStyle(.plain).help("新建对话") }
                }.padding(16)
                TextField("搜索标题与消息", text: $model.query).textFieldStyle(.roundedBorder).padding(.horizontal, 12).padding(.bottom, 10)
                    .onChange(of: model.query) { _, _ in do { try model.reload() } catch { model.error = error.localizedDescription } }
                HStack {
                    Picker("来源", selection: $model.source) {
                        Text("全部").tag("all")
                        ForEach(["codex", "claude", "dsh", "desktop", "acp"], id: \.self) { Text(sourceName($0)).tag($0) }
                    }.labelsHidden()
                    if !model.project.isEmpty || model.heatmapFilter != nil {
                        Button("清除筛选") { model.project = ""; model.heatmapFilter = nil }.font(.caption)
                    }
                }.padding(.horizontal, 12).padding(.bottom, 8)
                List(selection: Binding(get: { model.selectedID }, set: { id in DispatchQueue.main.async { model.select(id); messageLimit = 100 } })) {
                    ForEach(model.filtered) { session in
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
                }.listStyle(.sidebar)
                Text("\(model.filtered.count) 个会话").font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }.frame(minWidth: 245, idealWidth: 285, maxWidth: 340)
            if let session = model.selected {
                VStack(spacing: 0) {
                    header(session)
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 22) {
                                if session.messages.count > messageLimit { Button("加载更早的消息（剩余 \(session.messages.count - messageLimit) 条）") { messageLimit += 100 }.frame(maxWidth: .infinity) }
                                ForEach(Array(session.messages.suffix(messageLimit))) { message in MessageView(message: message).id(message.id) }
                                if session.messages.isEmpty { ContentUnavailableView("尚无消息", systemImage: "bubble.left", description: Text("恢复会话后可在下方输入消息。")) }
                                Color.clear.frame(height: 1).id("bottom")
                            }.padding(26).frame(maxWidth: 1000).frame(maxWidth: .infinity)
                        }
                        .onChange(of: model.selected?.messages.last?.text) { _, _ in if sending { proxy.scrollTo("bottom", anchor: .bottom) } }
                        .onChange(of: model.selectedID) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    if showEvents {
                        DisclosureGroup("最近运行事件", isExpanded: .constant(true)) {
                            ScrollView { Text((model.toolEvents[session.id] ?? []).suffix(15).map(\.text).joined(separator: "\n\n")).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 160)
                        }.padding(.horizontal, 20)
                    }
                    if !session.warnings.isEmpty { Text(session.warnings.joined(separator: " · ")).font(.caption2).foregroundStyle(.orange).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 8) }
                    if session.source == "desktop" {
                        HStack { Text("官方导出记录 · 更新时需重新导入").foregroundStyle(.secondary); Spacer(); Button("打开原聊天") { model.openDesktop(session) } }.padding(20)
                    } else { composer(session) }
                }.frame(minWidth: 550)
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 40, weight: .ultraLight)).foregroundStyle(.secondary)
                    Text(canCreate ? "开始一段对话" : "选择一个历史会话").font(.title2.weight(.medium))
                    Text(canCreate ? "选择项目和 Agent，使用原生接口或 ACP 开始工作。" : "浏览本地记录，或导入 Claude 官方导出包。").font(.callout).foregroundStyle(.secondary)
                    if canCreate { Button("新建对话") { newChat = true }.buttonStyle(.borderedProminent) }
                    else { Button("导入 Claude 聊天…") { model.importDesktop() } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(canCreate ? "对话" : "会话")
        .sheet(isPresented: $newChat) { NewChatView().environmentObject(model) }
    }
    func header(_ session: Session) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title).font(.headline).lineLimit(1)
                Text("\(sourceName(session.source)) / \(session.project.isEmpty ? "未关联项目" : session.project)").font(.caption).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
            }
            Spacer()
            Button { showEvents.toggle() } label: { Image(systemName: "list.bullet.rectangle") }.help("显示运行事件")
            if session.source != "desktop" { Button("恢复会话") { Task { await model.resumeSelected() } }.disabled(model.running.contains(session.id)) }
        }.padding(16)
    }
    func composer(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !attachments.isEmpty {
                HStack { ForEach(attachments, id: \.self) { url in Button { attachments.removeAll { $0 == url } } label: { Label(url.lastPathComponent, systemImage: "xmark.circle").lineLimit(1) }.font(.caption) } }
            }
            ZStack(alignment: .topLeading) {
                if prompt.isEmpty { Text("输入消息，继续此会话…").foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false) }
                TextEditor(text: $prompt).font(.body).scrollContentBackground(.hidden).frame(minHeight: 65, maxHeight: 150)
            }
            HStack {
                Button { attachments += model.chooseAttachments().filter { !attachments.contains($0) } } label: { Image(systemName: "paperclip") }.buttonStyle(.plain).help("添加附件，图片能力由 Agent 决定")
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(session.projectName).font(.caption).foregroundStyle(.secondary)
                Spacer()
                AgentOptionsView(session: session, prompt: $prompt)
                if sending || model.running.contains(session.id) {
                    Button { Task { await model.stop(); sending = false } } label: { Image(systemName: "stop.fill") }.help("停止当前执行")
                } else {
                    Button {
                        let text = prompt, files = attachments; prompt = ""; attachments = []; sending = true
                        Task { if !(await model.send(text, attachments: files)) { if prompt.isEmpty { prompt = text }; if attachments.isEmpty { attachments = files } }; sending = false }
                    } label: { Image(systemName: "arrow.up").fontWeight(.semibold).frame(width: 22, height: 22) }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command).disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.ready)
                }
            }
        }.padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.08))).padding(18)
    }
}

struct MessageView: View {
    let message: Message
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: message.role == "user" ? "person.circle" : message.role == "tool" ? "terminal" : "sparkle").foregroundStyle(message.role == "user" ? .blue : .secondary)
                Text(message.role == "user" ? "你" : message.role == "tool" ? "工具" : "助手").font(.caption.weight(.semibold))
                Spacer()
                Text(Date(timeIntervalSince1970: message.time / 1000), style: .time).font(.caption2).foregroundStyle(.tertiary)
            }
            if message.kind == "tool" {
                DisclosureGroup(isExpanded: $expanded) { Text(message.text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } label: { Text(message.text.components(separatedBy: "\n").first ?? "工具输出").lineLimit(1).font(.caption) }
            } else { Text(.init(message.text)).textSelection(.enabled).font(.system(size: 13)).lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading) }
        }.padding(message.role == "user" ? 16 : 0).background(message.role == "user" ? Color.blue.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct NewChatView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var agentID = ""
    @State private var cwd = ""
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
                if model.settings.agents.first(where: { $0.id == agentID })?.kind != "acp" { TextField("模型（留空使用默认值）", text: $model.composerModel) }
                else { Text("创建后可选择 Agent 提供的模型与权限选项").font(.caption).foregroundStyle(.secondary) }
            }
            HStack { Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); if starting { ProgressView().controlSize(.small) }; Button("创建对话") {
                guard let agent = model.settings.agents.first(where: { $0.id == agentID }) else { return }
                starting = true
                Task { let created = await model.startChat(agent: agent, cwd: cwd); starting = false; if created { dismiss() } }
            }.buttonStyle(.borderedProminent).disabled(starting || cwd.isEmpty || agentID.isEmpty) }
        }.padding(28).frame(width: 540).onAppear { agentID = model.settings.agents.first?.id ?? ""; cwd = model.project.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : model.project }
        .onChange(of: agentID) { _, _ in model.composerModel = "" }
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

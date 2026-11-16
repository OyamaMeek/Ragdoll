import SwiftUI
import AppKit
import RagdollCore

struct Approval: Identifiable {
    var id: String
    var method: String
    var params: JSONValue
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings = Settings()
    @Published var sessions: [Session] = []
    @Published var selected: Session?
    @Published var query = ""
    @Published var source = "all"
    @Published var project = ""
    @Published var heatmapFilter: [Int]?
    @Published var selectedID: String?
    @Published var running: Set<String> = []
    @Published var scanning = false
    @Published var archiving = false
    @Published var ready = false
    @Published var status = "正在启动…"
    @Published var error: String?
    @Published var warnings: [String] = []
    @Published var approvals: [Approval] = []
    @Published var registry: [JSONValue] = []
    @Published var agentInfo: [String: JSONValue] = [:]
    @Published var conversationInfo: [String: JSONValue] = [:]
    @Published var loginLinks: [URL] = []
    @Published var nativeHistory: [JSONValue] = []
    @Published var nativeCursor = ""
    @Published var nativeHistoryProject = ""
    @Published var registryLoading = false
    @Published var busyAgents: Set<String> = []
    @Published var archiveStatus = "尚未选择归档仓库"
    @Published var lastArchive: Date?
    @Published var composerModel = ""
    @Published var toolEvents: [String: [JSONValue]] = [:]
    let bridge = RuntimeBridge()
    let root: URL
    private let store: Store?
    private var reloadTask: Task<Void, Never>?
    private var archiveTask: Task<Void, Never>?
    private var dirtySince: Date?
    private var dirtyGeneration = 0
    private var initialized = false

    init() {
        root = ProcessInfo.processInfo.environment["RAGDOLL_DATA_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Ragdoll")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let store = try Store(path: root.appendingPathComponent("index.sqlite").path)
            let settings = try store.settings(), sessions = try store.list()
            self.store = store; self.settings = settings; self.sessions = sessions
        } catch { store = nil; self.error = error.localizedDescription }
    }
    var filtered: [Session] { sessions.filter { session in
        guard (source == "all" || session.source == source || session.nativeSource == source) && (project.isEmpty || session.project == project) else { return false }
        guard let bucket = heatmapFilter else { return true }
        let start = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date()))!
        return session.usage.contains { usage in
            let date = Date(timeIntervalSince1970: usage.time / 1000)
            return date >= start && Calendar.current.component(.weekday, from: date) - 1 == bucket[0] && Calendar.current.component(.hour, from: date) == bucket[1]
        }
    } }
    var dashboard: Dashboard { Analytics.summarize(filtered, prices: settings.prices, budget: settings.weeklyBudget) }
    var projects: [String] { Array(Set(sessions.map(\.project).filter { !$0.isEmpty })).sorted() }

    func launch() async {
        guard !initialized else { return }; initialized = true
        await bridge.setHandler { [weak self] event, data in await self?.receive(event, data) }
        do {
            try await bridge.start(dataDirectory: root)
            let initial = try await bridge.request("initialize")
            if settings.locations.isEmpty { settings.locations = try initial["locations"].decode([Location].self) }
            let defaults = try initial["agents"].decode([AgentConfig].self)
            for agent in defaults where !settings.agents.contains(where: { $0.id == agent.id }) { settings.agents.append(agent) }
            try saveSettings(); ready = true; await refresh()
            Task { [weak self] in
                while !Task.isCancelled { try? await Task.sleep(for: .seconds(60)); guard let self else { return }; await self.refresh() }
            }
        } catch { self.error = error.localizedDescription; status = "启动失败" }
    }
    func receive(_ event: String, _ data: JSONValue) {
        do {
            switch event {
            case "session":
                let session = try data.decode(Session.self)
                if try store?.save(session) == true {
                    if selectedID == session.id { selected = session }
                    scheduleReload(); scheduleArchive()
                }
            case "delta":
                if data["conversationID"].string == selectedID, let message = try? data["message"].decode(Message.self) {
                    if let index = selected?.messages.firstIndex(where: { $0.id == message.id }) { selected?.messages[index] = message }
                    else { selected?.messages.append(message) }
                }
            case "state":
                let id = data["conversationID"].string
                if data["state"].string == "running" { running.insert(id) } else { running.remove(id) }
                if !data["message"].string.isEmpty { error = data["message"].string }
                if data["state"].string == "idle" { Task { await refresh() } }
            case "chat":
                let id = data["conversationID"].string
                var events = toolEvents[id] ?? []; events.append(data)
                toolEvents[id] = Array(events.suffix(100))
            case "approval": approvals.append(Approval(id: data["requestID"].string, method: data["method"].string, params: data["params"]))
            case "approvalCancelled": approvals.removeAll { $0.id == data["requestID"].string }
            case "sourceChanged": if !scanning { Task { await refresh() } }
            case "warning": warnings.append(data.string); warnings = Array(warnings.suffix(100))
            case "agentEvent":
                let text = data.text
                warnings.append(text)
                collectLoginLinks(data)
            case "agentConfiguration":
                let id = data["conversationID"].string.isEmpty ? selectedID ?? "" : data["conversationID"].string
                var info = (conversationInfo[id] ?? .object([:])).dictionary
                let update = data["update"]
                if update["configOptions"] != .null { info["configOptions"] = update["configOptions"] }
                if update["availableCommands"] != .null { info["availableCommands"] = update["availableCommands"] }
                conversationInfo[id] = .object(info)
            case "disconnected": ready = false; running.removeAll(); error = data.string
            default: break
            }
        } catch { self.error = error.localizedDescription }
    }
    func refresh() async {
        guard ready, !scanning else { return }; scanning = true; status = "正在读取会话…"
        do {
            let result = try await bridge.request("scan", ["locations": try .encode(settings.locations)], timeout: 600)
            try reload(); status = "索引已更新 · 本次处理 \(result["count"].text) 个变更会话"
        } catch { self.error = error.localizedDescription; status = "扫描失败，可重试" }
        scanning = false; scheduleArchive(markDirty: false)
    }
    private func scheduleReload() {
        guard reloadTask == nil else { return }
        reloadTask = Task { try? await Task.sleep(for: .milliseconds(300)); do { try reload() } catch { self.error = error.localizedDescription }; reloadTask = nil }
    }
    func reload() throws { sessions = try store?.list(query: query) ?? [] }
    func select(_ id: String?) {
        selectedID = id
        do { selected = try id.flatMap { try store?.session($0) } }
        catch { self.error = error.localizedDescription }
    }
    func saveSettings() throws { try store?.saveSettings(settings) }
    func persistSettings() { do { try saveSettings() } catch { self.error = error.localizedDescription } }
    private func hydrated(_ config: AgentConfig) throws -> AgentConfig {
        var config = config; config.env = try Secrets.load(config.id).merging(config.env) { secret, _ in secret }; return config
    }
    func saveAgent(_ agent: AgentConfig) throws {
        try Secrets.save(agent.env, for: agent.id)
        var safe = agent; safe.env = [:]
        if let i = settings.agents.firstIndex(where: { $0.id == agent.id }) { settings.agents[i] = safe } else { settings.agents.append(safe) }
        try saveSettings()
    }
    @discardableResult func startChat(agent: AgentConfig, cwd: String, resume: Session? = nil) async -> Bool {
        do {
            var params: [String: JSONValue] = ["agent": try .encode(hydrated(agent)), "cwd": .string(cwd)]
            if let resume { params["session"] = try .encode(resume) }
            if agent.kind != "acp" && !composerModel.isEmpty { params["model"] = .string(composerModel) }
            let result = try await bridge.request("chat.start", params)
            let session = try result["session"].decode(Session.self)
            _ = try store?.save(session); try reload(); select(session.id)
            if result["info"] != .null { agentInfo[agent.id] = result["info"]; conversationInfo[session.id] = result["info"] }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func resumeSelected() async {
        guard let selected else { return }
        if selected.source == "desktop" { openDesktop(selected); return }
        let agent = settings.agents.first { $0.id == selected.instanceID } ?? settings.agents.first { $0.kind == selected.source }
        guard let agent else { error = "请先配置此会话使用的 Agent"; return }
        await startChat(agent: agent, cwd: selected.project.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : selected.project, resume: selected)
    }
    func send(_ text: String, attachments: [URL] = []) async -> Bool {
        guard let selected else { return false }
        if selected.source == "desktop" { openDesktop(selected); return false }
        if !running.contains(selected.id) { await resumeSelected() }
        guard let id = self.selected?.id else { return false }
        do { _ = try await bridge.request("chat.send", ["id": .string(id), "text": .string(text), "model": .string(selected.source == "acp" ? "" : composerModel), "attachments": try .encode(attachments.map(\.path))], timeout: 0); return true }
        catch { self.error = error.localizedDescription; running.remove(id); return false }
    }
    func stop() async {
        guard let id = selectedID else { return }
        do { _ = try await bridge.request("chat.stop", ["id": .string(id)]) } catch { self.error = error.localizedDescription }
    }
    func answer(_ request: Approval, allowed: Bool, optionID: String? = nil, content: JSONValue? = nil) async {
        var answer: [String: JSONValue] = ["allowed": .bool(allowed)]
        if let optionID { answer["optionId"] = .string(optionID) }
        if let content { answer.merge(content.dictionary) { _, new in new }; answer["content"] = content }
        do {
            _ = try await bridge.request("approval", ["requestID": .string(request.id), "answer": .object(answer)])
            approvals.removeAll { $0.id == request.id }
        } catch { self.error = error.localizedDescription }
    }
    func probe(_ agent: AgentConfig) async {
        busyAgents.insert(agent.id); defer { busyAgents.remove(agent.id) }
        do { agentInfo[agent.id] = try await bridge.request("probe", ["agent": try .encode(hydrated(agent)), "cwd": .string(FileManager.default.homeDirectoryForCurrentUser.path)]) }
        catch { self.error = error.localizedDescription }
    }
    func loadRegistry() async {
        registryLoading = true; defer { registryLoading = false }
        do { registry = try await bridge.request("registry").array } catch { self.error = error.localizedDescription }
    }
    func installAgent(_ entry: JSONValue) async {
        let id = entry["id"].string; busyAgents.insert(id); defer { busyAgents.remove(id) }
        do {
            let value = try await bridge.request("install", ["agent": entry], timeout: 600)
            var config = try value.decode(AgentConfig.self)
            config.env = try Secrets.load(config.id).merging(config.env) { existing, _ in existing }
            config.protocol = settings.agents.first(where: { $0.id == config.id })?.protocol ?? config.protocol
            try saveAgent(config); status = "已安装 \(entry["name"].string)"
        } catch { self.error = error.localizedDescription }
    }
    func removeAgent(_ agent: AgentConfig) async {
        do {
            guard !running.contains(where: { id in sessions.first(where: { $0.id == id })?.instanceID == agent.id }) else { error = "请先停止此 Agent 的运行会话"; return }
            _ = try await bridge.request("uninstall", ["agent": try .encode(agent)])
            settings.agents.removeAll { $0.id == agent.id }; try Secrets.save([:], for: agent.id); try saveSettings()
        } catch { self.error = error.localizedDescription }
    }
    func authenticate(_ agent: AgentConfig, methodID: String) async {
        busyAgents.insert(agent.id); defer { busyAgents.remove(agent.id) }
        do {
            let result = try await bridge.request("authenticate", ["agent": try .encode(hydrated(agent)), "methodID": .string(methodID), "cwd": .string(FileManager.default.homeDirectoryForCurrentUser.path)], timeout: 600)
            if !result["terminalScript"].string.isEmpty { NSWorkspace.shared.open(URL(fileURLWithPath: result["terminalScript"].string)); status = "在终端完成登录后，请检测连接" }
            else { await probe(agent) }
        } catch { self.error = error.localizedDescription }
    }
    func importDesktop() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.zip, .json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { do { _ = try await bridge.request("import", ["path": .string(url.path)]); try reload(); scheduleArchive() } catch { self.error = error.localizedDescription } }
    }
    func chooseArchive() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.prompt = "选择归档仓库"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.archivePath = url.path; persistSettings(); scheduleArchive(); Task { await archiveNow() }
    }
    func chooseProject() -> String? {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "选择项目"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
    func chooseAttachments() -> [URL] {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls : []
    }
    private func scheduleArchive(markDirty: Bool = true) {
        guard !settings.archivePath.isEmpty else { return }
        if markDirty { dirtySince = dirtySince ?? Date(); dirtyGeneration += 1 }
        guard dirtySince != nil else { return }
        guard !scanning else { return }
        archiveTask?.cancel()
        let delay = max(0, min(30, 300 - Date().timeIntervalSince(dirtySince!)))
        archiveTask = Task { do { try await Task.sleep(for: .seconds(delay)); await archiveNow() } catch {} }
    }
    func archiveNow() async {
        guard let store, !settings.archivePath.isEmpty, !archiving, !scanning else { return }
        archiving = true; archiveStatus = "正在保存并提交…"
        let generation = dirtyGeneration
        let path = settings.archivePath, excluded = settings.excludedProjects, roots = settings.locations.map(\.path)
        do {
            let result = try await Task.detached(priority: .utility) {
                let sessions = try store.list().filter { !excluded.contains($0.project) }.compactMap { try store.session($0.id) }
                return try Archive.save(sessions, to: URL(fileURLWithPath: path), sourceRoots: roots)
            }.value
            archiveStatus = result.commit.map { "已保存并提交 · \($0) · \(result.files) 个文件" } ?? "归档已是最新，无需提交"
            lastArchive = Date(); if generation == dirtyGeneration { dirtySince = nil }
        } catch { archiveStatus = "归档未完成：\(error.localizedDescription)"; self.error = error.localizedDescription }
        archiving = false
        if generation != dirtyGeneration { scheduleArchive(markDirty: false) }
    }
    func openDesktop(_ session: Session) { if let url = URL(string: "https://claude.ai/chat/\(session.nativeID)") { NSWorkspace.shared.open(url) } }
    private func collectLoginLinks(_ value: JSONValue) {
        if let url = URL(string: value.string), ["https", "http"].contains(url.scheme ?? ""), !loginLinks.contains(url) { loginLinks.append(url) }
        for item in value.array { collectLoginLinks(item) }
        for item in value.dictionary.values { collectLoginLinks(item) }
    }
    func nativeLogin(_ agent: AgentConfig) async {
        do {
            let result = try await bridge.request("native.login", ["agent": try .encode(agent)])
            NSWorkspace.shared.open(URL(fileURLWithPath: result["terminalScript"].string))
        } catch { self.error = error.localizedDescription }
    }
    func configure(_ configID: String, value: String) async {
        guard let id = selectedID else { return }
        do {
            let result = try await bridge.request("chat.configure", ["id": .string(id), "configID": .string(configID), "value": .string(value)])
            if result["configOptions"] != .null {
                var info = (conversationInfo[id] ?? .object([:])).dictionary; info["configOptions"] = result["configOptions"]; conversationInfo[id] = .object(info)
            }
        } catch { self.error = error.localizedDescription }
    }
    func listNative(_ agent: AgentConfig, project: String, more: Bool = false) async {
        do {
            let result = try await bridge.request("chat.list", ["agent": try .encode(hydrated(agent)), "cwd": .string(project), "cursor": .string(more ? nativeCursor : "")])
            nativeHistory = (more ? nativeHistory : []) + result["sessions"].array
            nativeCursor = result["nextCursor"].string; nativeHistoryProject = project
        } catch { self.error = error.localizedDescription }
    }
    func importNative(_ agent: AgentConfig, record: JSONValue) async -> Bool {
        do {
            let result = try await bridge.request("chat.import", ["agent": try .encode(hydrated(agent)), "cwd": .string(nativeHistoryProject), "session": record])
            let session = try result["session"].decode(Session.self)
            _ = try store?.save(session); try reload(); select(session.id); conversationInfo[session.id] = result["info"]; scheduleArchive(); return true
        } catch { self.error = error.localizedDescription; return false }
    }
}

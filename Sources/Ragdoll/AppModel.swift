import SwiftUI
import AppKit
import RagdollCore
import ServiceManagement
import Darwin

struct Approval: Identifiable {
    var id: String
    var method: String
    var params: JSONValue
}

struct ComposerSelection {
    var model = "" {
        didSet { if model != oldValue { effort = "" } }
    }
    var effort = ""
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings = Settings()
    @Published var sessions: [Session] = []
    @Published var selected: Session?
    @Published var query = ""
    @Published var source = "all"
    @Published var project = ""
    @Published var heatmapFilter: Date?
    @Published var selectedID: String?
    @Published var running: Set<String> = []
    @Published var scanning = false
    @Published var archiving = false
    @Published var ready = false
    @Published var loadingArchive = false
    @Published private(set) var archiveLoaded = false
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
    @Published var composerSelections: [String: ComposerSelection] = [:]
    @Published var toolEvents: [String: [JSONValue]] = [:]
    @Published var backgroundStatus = "未启用后台服务"
    @Published var syncStatus = "未启用远端推送"
    let bridge = RuntimeBridge()
    let root: URL
    private let store: Store?
    private var reloadTask: Task<Void, Never>?
    private var archiveTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var dirtySince: Date?
    private var dirtyGeneration = 0
    private var initialized = false
    private var lastRefresh = Date.distantPast

    init(root: URL? = nil) {
        self.root = root ?? ProcessInfo.processInfo.environment["RAGDOLL_DATA_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Ragdoll")
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            let store = try Store(path: self.root.appendingPathComponent("index.sqlite").path)
            let settings = try store.settings(), sessions = try store.list()
            self.store = store; self.settings = settings; self.sessions = sessions
        } catch { store = nil; self.error = error.localizedDescription }
    }
    deinit { monitorTask?.cancel(); archiveTask?.cancel(); reloadTask?.cancel() }
    var needsArchiveSetup: Bool { settings.archivePath.isEmpty }
    var filtered: [Session] { sessions.filter { session in
        guard (source == "all" || session.source == source || session.nativeSource == source) && (project.isEmpty || session.project == project) else { return false }
        guard let day = heatmapFilter else { return true }
        return session.usage.contains { usage in
            let date = Date(timeIntervalSince1970: usage.time / 1000)
            return date <= Date() && Calendar.current.isDate(date, inSameDayAs: day)
        }
    } }
    var dashboard: Dashboard { Analytics.summarize(filtered, prices: settings.prices, budget: settings.weeklyBudget) }
    var projects: [String] { Array(Set(sessions.map(\.project).filter { !$0.isEmpty })).sorted() }

    func launch() async {
        guard !initialized, let store else { return }
        guard !settings.archivePath.isEmpty else { status = "请先设置 Git 仓库"; return }
        initialized = true; loadingArchive = true
        defer { loadingArchive = false }
        await bridge.setHandler { [weak self] event, data in await self?.receive(event, data) }
        do {
            try await bridge.start(dataDirectory: root)
            status = "正在读取 Git 仓库…"
            let archive = URL(fileURLWithPath: settings.archivePath), bridge = self.bridge
            let count = try await Task.detached(priority: .utility) { try await Archive.restore(from: archive, into: store, bridge: bridge) }.value
            try reload(); archiveLoaded = true; archiveStatus = "已读取 Git 仓库 · \(count) 个会话"
            let initial = try await bridge.request("initialize")
            if settings.locations.isEmpty { settings.locations = try initial["locations"].decode([Location].self) }
            let defaults = try initial["agents"].decode([AgentConfig].self)
            for agent in defaults where !settings.agents.contains(where: { $0.id == agent.id }) { settings.agents.append(agent) }
            try saveSettings(); ready = true
            if settings.backgroundEnabled == true { await setBackground(true) }
            await refresh()
            scheduleArchive()
            monitorTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2)); guard let self else { return }
                    self.pollBackground()
                    do {
                        let background = try BackgroundService.isRunning(root: self.root)
                        if !background, Date().timeIntervalSince(self.lastRefresh) >= 60 { await self.refresh() }
                        if self.settings.archiveRemote != nil, !background, !self.archiving, FileManager.default.fileExists(atPath: self.root.appendingPathComponent("sync-pending").path), Date().timeIntervalSince(self.lastPushAttempt) >= 60 { await self.retryPush() }
                    } catch { self.error = error.localizedDescription }
                }
            }
        } catch { initialized = false; archiveLoaded = false; ready = false; self.error = error.localizedDescription; status = "仓库读取失败，请重试或重新选择" }
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
        guard ready, !scanning, !archiving else { return }
        do { if try BackgroundService.isRunning(root: root) { try BackgroundService.request(root: root); pollBackground(); return } }
        catch { self.error = error.localizedDescription; return }
        scanning = true; status = "正在读取会话…"
        lastRefresh = Date()
        do {
            let lease = try ServiceLease(root: root)
            defer { withExtendedLifetime(lease) {} }
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
    @discardableResult func startChat(agent: AgentConfig, cwd: String, resume: Session? = nil, model: String = "") async -> Bool {
        guard ready else { return false }
        do {
            var params: [String: JSONValue] = ["agent": try .encode(hydrated(agent)), "cwd": .string(cwd)]
            if let resume { params["session"] = try .encode(resume) }
            if agent.kind != "acp" && !model.isEmpty { params["model"] = .string(model) }
            let result = try await bridge.request("chat.start", params)
            let session = try result["session"].decode(Session.self)
            _ = try store?.save(session); try reload()
            if resume == nil && agent.kind != "acp" && !model.isEmpty {
                composerSelections[session.id] = ComposerSelection(model: model)
            }
            if resume == nil || selectedID == resume?.id { select(session.id) }
            if result["info"] != .null { agentInfo[agent.id] = result["info"]; conversationInfo[session.id] = result["info"] }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func resumeSelected() async {
        guard let selected else { return }
        if selected.source == "desktop" { openDesktop(selected); return }
        await resume(selected, model: composerSelections[selected.id]?.model ?? "")
    }
    private func agent(for session: Session) -> AgentConfig? {
        settings.agents.first { $0.id == session.instanceID } ?? settings.agents.first { $0.kind == session.source }
    }
    private func directory(for session: Session) -> String {
        session.project.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : session.project
    }
    @discardableResult private func resume(_ session: Session, model: String) async -> Bool {
        guard let agent = agent(for: session) else { error = "请先配置此会话使用的 Agent"; return false }
        return await startChat(agent: agent, cwd: directory(for: session), resume: session, model: agent.kind == "codex" ? "" : model)
    }
    func loadCodexModels(for session: Session) async throws {
        if conversationInfo[session.id]?["models"].dictionary["data"] != nil { return }
        guard let config = agent(for: session), config.kind == "codex" else {
            throw NSError(domain: "Ragdoll.Codex", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先配置此会话使用的 Codex Agent"])
        }
        var configWithHome = try hydrated(config)
        if !session.home.isEmpty { configWithHome.env["CODEX_HOME"] = session.home }
        let result = try await bridge.request("probe", ["agent": try .encode(configWithHome), "cwd": .string(directory(for: session))])
        if conversationInfo[session.id]?["models"].dictionary["data"] == nil { conversationInfo[session.id] = result }
    }
    func send(_ text: String, attachments: [URL] = []) async -> Bool {
        guard let selected else { return false }
        if selected.source == "desktop" { openDesktop(selected); return false }
        let selection = composerSelections[selected.id] ?? ComposerSelection()
        if !running.contains(selected.id), !(await resume(selected, model: selection.model)) { return false }
        do {
            var params: [String: JSONValue] = ["id": .string(selected.id), "text": .string(text), "attachments": try .encode(attachments.map(\.path))]
            if selected.source != "acp" && !selection.model.isEmpty { params["model"] = .string(selection.model) }
            if selected.source == "codex" && !selection.effort.isEmpty { params["effort"] = .string(selection.effort) }
            _ = try await bridge.request("chat.send", params, timeout: 0)
            return true
        } catch { self.error = error.localizedDescription; running.remove(selected.id); return false }
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
        guard ready else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.zip, .json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { do { _ = try await bridge.request("import", ["path": .string(url.path)]); try reload(); scheduleArchive() } catch { self.error = error.localizedDescription } }
    }
    func chooseArchive() {
        guard !scanning, !archiving, !loadingArchive, running.isEmpty else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.prompt = "选择归档仓库"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await configureArchive(url) }
    }
    func configureArchive(_ url: URL) async {
        guard !scanning, !archiving, !loadingArchive, running.isEmpty else { return }
        do {
            let roots = settings.locations.map(\.path)
            try await Task.detached(priority: .utility) { try Archive.prepare(url, sourceRoots: roots) }.value
            archiveTask?.cancel(); monitorTask?.cancel()
            if settings.archivePath != url.path { settings.archiveRemote = nil; syncStatus = "未启用远端推送" }
            settings.archivePath = url.path
            try saveSettings()
            initialized = false; ready = false; archiveLoaded = false
            await launch()
        } catch { self.error = error.localizedDescription }
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
        do { if !scanning && !archiving { if try BackgroundService.isRunning(root: root) { archiveTask?.cancel(); return } } }
        catch { self.error = error.localizedDescription; return }
        guard archiveLoaded, !settings.archivePath.isEmpty else { return }
        if markDirty { dirtySince = dirtySince ?? Date(); dirtyGeneration += 1 }
        guard dirtySince != nil else { return }
        guard !scanning else { return }
        archiveTask?.cancel()
        let delay = max(0, min(30, 300 - Date().timeIntervalSince(dirtySince!)))
        archiveTask = Task { do { try await Task.sleep(for: .seconds(delay)); await archiveNow() } catch {} }
    }
    func archiveNow() async {
        guard archiveLoaded, let store, !settings.archivePath.isEmpty, !archiving, !scanning else { return }
        do { if try BackgroundService.isRunning(root: root) { try BackgroundService.request(root: root); archiveStatus = "已请求后台归档"; return } }
        catch { self.error = error.localizedDescription; return }
        archiving = true; archiveStatus = "正在保存并提交…"
        let generation = dirtyGeneration
        let path = settings.archivePath, excluded = settings.excludedProjects, roots = settings.locations.map(\.path), remote = settings.archiveRemote
        do {
            let lease = try ServiceLease(root: root)
            defer { withExtendedLifetime(lease) {} }
            let result = try await Task.detached(priority: .utility) {
                let sessions = try store.list().filter { !excluded.contains($0.project) }.compactMap { try store.session($0.id) }
                return try Archive.save(sessions, to: URL(fileURLWithPath: path), sourceRoots: roots)
            }.value
            archiveStatus = result.commit.map { "已保存并提交 · \($0) · \(result.files) 个文件" } ?? "归档已是最新，无需提交"
            lastArchive = Date(); if generation == dirtyGeneration { dirtySince = nil }
            if let remote, settings.archivePath == path, settings.archiveRemote == remote {
                try Data("pending".utf8).write(to: root.appendingPathComponent("sync-pending"), options: .atomic)
                lastPushAttempt = Date(); syncStatus = "正在推送"
                do {
                    _ = try await Task.detached(priority: .utility) { try ArchiveSync.push(root: URL(fileURLWithPath: path), remote: remote.remote, branch: remote.branch) }.value
                    if settings.archivePath == path && settings.archiveRemote == remote {
                        try FileManager.default.removeItem(at: root.appendingPathComponent("sync-pending"))
                        syncStatus = "已推送到 \(remote.remote)/\(remote.branch)"
                    }
                } catch { syncStatus = "推送待重试：\(error.localizedDescription)" }
            } else { syncStatus = settings.archiveRemote == nil ? "未启用远端推送" : "配置已变化，等待按当前配置推送" }
        } catch { archiveStatus = "归档未完成：\(error.localizedDescription)"; self.error = error.localizedDescription }
        archiving = false
        if generation != dirtyGeneration { scheduleArchive(markDirty: false) }
    }
    private var lastPushAttempt = Date.distantPast
    func configureArchiveRemote(_ remote: ArchiveRemote?) {
        settings.archiveRemote = remote; persistSettings()
        if remote != nil { scheduleArchive(); Task { await archiveNow() } }
        else { syncStatus = "未启用远端推送" }
    }
    func retryPush() async {
        guard archiveLoaded, let remote = settings.archiveRemote, !settings.archivePath.isEmpty, !scanning, !archiving else { return }
        let path = settings.archivePath
        do {
            if try BackgroundService.isRunning(root: root) { try BackgroundService.requestPush(root: root); return }
            archiving = true; defer { archiving = false }
            let lease = try ServiceLease(root: root); defer { withExtendedLifetime(lease) {} }
            try Data("pending".utf8).write(to: root.appendingPathComponent("sync-pending"), options: .atomic)
            lastPushAttempt = Date(); syncStatus = "正在重试推送"
            _ = try await Task.detached(priority: .utility) { try ArchiveSync.push(root: URL(fileURLWithPath: path), remote: remote.remote, branch: remote.branch) }.value
            if settings.archivePath == path && settings.archiveRemote == remote {
                try FileManager.default.removeItem(at: root.appendingPathComponent("sync-pending"))
                syncStatus = "已推送到 \(remote.remote)/\(remote.branch)"
            }
        } catch { syncStatus = "推送待重试：\(error.localizedDescription)" }
    }
    func pollBackground() {
        guard !scanning, !archiving else { return }
        do {
            let running = try BackgroundService.isRunning(root: root)
            if running, let state = try BackgroundService.status(root: root), state.pid == (try BackgroundService.ownerPID(root: root)), kill(state.pid, 0) == 0, Date().timeIntervalSince(state.updated) < 120 {
                backgroundStatus = "后台服务正在运行 · PID \(state.pid)"
                status = state.scan; archiveStatus = state.archive; syncStatus = state.sync; lastArchive = state.lastArchive
                try reload()
                if let id = selectedID, !self.running.contains(id) { selected = try store?.session(id) }
            } else if running {
                backgroundStatus = "目录由后台任务占用，等待新的状态报告"
            } else {
                let service = SMAppService.agent(plistName: "com.oyamameek.ragdoll.service.plist")
                backgroundStatus = service.status == .requiresApproval ? "请在系统登录项中允许后台服务" : settings.backgroundEnabled == true ? "后台服务尚未运行" : "未启用后台服务"
            }
        } catch { backgroundStatus = "后台状态检查失败：\(error.localizedDescription)"; self.error = error.localizedDescription }
    }
    func setBackground(_ enabled: Bool) async {
        guard Bundle.main.bundleURL.pathExtension == "app" else { error = "后台服务需要运行打包后的 Ragdoll.app"; return }
        let service = SMAppService.agent(plistName: "com.oyamameek.ragdoll.service.plist")
        do {
            while scanning || archiving { try await Task.sleep(for: .milliseconds(100)) }
            settings.backgroundEnabled = enabled; try saveSettings()
            if enabled {
                archiveTask?.cancel()
                if service.status != .enabled { try service.register() }
            } else { try await service.unregister() }
            pollBackground()
        } catch { self.error = error.localizedDescription; pollBackground() }
    }
    func migrateSelected(agent: AgentConfig, cwd: String, authorizedAttachments: [URL] = []) async -> Bool {
        guard let session = selected else { return false }
        do {
            let config = try hydrated(agent)
            let key = agent.kind == "codex" ? "CODEX_HOME" : agent.kind == "claude" ? "CLAUDE_CONFIG_DIR" : "DSH_HOME"
            guard let home = config.env[key] ?? settings.locations.first(where: { $0.source == agent.kind })?.path else { throw NSError(domain: "Ragdoll.Migration", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先设置目标工具的历史目录"]) }
            let actual = URL(fileURLWithPath: home).standardizedFileURL.resolvingSymlinksInPath()
            let identityHome = settings.locations.first { $0.source == agent.kind && URL(fileURLWithPath: $0.path).standardizedFileURL.resolvingSymlinksInPath() == actual }?.path ?? home
            let result = try await bridge.request("migrate", ["session": try .encode(session), "target": try .encode(config), "home": .string(identityHome), "cwd": .string(cwd), "authorizedAttachments": try .encode(authorizedAttachments.map(\.path))], timeout: 600)
            let migrated = try result["session"].decode(Session.self)
            _ = try store?.save(migrated); try reload(); select(migrated.id); scheduleArchive()
            return true
        } catch { self.error = error.localizedDescription; return false }
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

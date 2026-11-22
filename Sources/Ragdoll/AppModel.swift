import SwiftUI
import AppKit
import RagdollCore
import ServiceManagement
import Darwin

@MainActor
final class AppModel: ObservableObject {
    @Published var settings = Settings()
    @Published var sessions: [Session] = []
    @Published var selectedID: String?
    @Published var query = ""
    @Published var source = "all"
    @Published var project = ""
    @Published var heatmapFilter: Date?
    @Published var scanning = false
    @Published var archiving = false
    @Published var ready = false
    @Published var loadingArchive = false
    @Published private(set) var archiveLoaded = false
    @Published var status = "正在启动…"
    @Published var error: String?
    @Published var warnings: [String] = []
    @Published var archiveStatus = "尚未选择归档仓库"
    @Published var lastArchive: Date?
    @Published var backgroundStatus = "未启用后台服务"
    @Published var syncStatus = "未启用远端推送"
    @Published private(set) var warmingCodexHome: String?
    @Published private(set) var codexWarmupResults: [String: String] = [:]
    @Published private(set) var codexAccounts: [CodexAccount] = []
    @Published private(set) var codexAccountsBusy = false
    @Published private(set) var codexAccountsMessage: String?
    @Published private(set) var codexAccountsError: String?
    @Published private(set) var codexAutoStates: [String: CodexAutoActivation.State] = [:]
    @Published private(set) var codexMessageStates: [String: CodexScheduledMessage.State] = [:]
    @Published private(set) var codexMessageSessions: [Session] = []
    let bridge = RuntimeBridge()
    let root: URL
    private let store: Store?
    private var reloadTask: Task<Void, Never>?
    private var archiveTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var autoActivationTask: Task<Void, Never>?
    private var dirtySince: Date?
    private var dirtyGeneration = 0
    private var initialized = false
    private var lastRefresh = Date.distantPast
    private var lastPushAttempt = Date.distantPast

    init(root: URL? = nil) {
        self.root = root ?? ProcessInfo.processInfo.environment["RAGDOLL_DATA_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Ragdoll")
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            let store = try Store(path: self.root.appendingPathComponent("index.sqlite").path)
            let settings = try store.settings(), sessions = try store.list()
            self.store = store; self.settings = settings; self.sessions = sessions
            codexMessageSessions = CodexScheduledMessage.eligibleSessions(sessions)
        } catch { store = nil; self.error = error.localizedDescription }
        do { codexAutoStates = try CodexAutoActivation.load(root: self.root) }
        catch { codexAccountsError = error.localizedDescription }
        do { codexMessageStates = try CodexScheduledMessage.load(root: self.root) }
        catch { codexAccountsError = error.localizedDescription }
        autoActivationTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkCodexAutoActivation()
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }
    deinit { monitorTask?.cancel(); archiveTask?.cancel(); reloadTask?.cancel(); autoActivationTask?.cancel() }
    var needsArchiveSetup: Bool { settings.archivePath.isEmpty }
    var selected: Session? { sessions.first { $0.id == selectedID } }
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

    func warmupCodex(_ home: String) async {
        guard ready, warmingCodexHome == nil, !codexAccountsBusy, settings.locations.contains(where: { $0.source == "codex" && $0.path == home }) else { return }
        warmingCodexHome = home
        codexWarmupResults[home] = nil
        defer { warmingCodexHome = nil }
        do {
            let lease = try ServiceLease(root: root, name: "codex-account-lock")
            defer { withExtendedLifetime(lease) {} }
            let result = try await bridge.request("codex.warmup", ["home": .string(home)], timeout: 90)
            codexWarmupResults[home] = try result["message"].decode(String.self)
        } catch { codexWarmupResults[home] = error.localizedDescription }
    }

    func manageCodexAccounts(_ action: String, id: String = "") async {
        guard !codexAccountsBusy, warmingCodexHome == nil else { return }
        codexAccountsBusy = true
        codexAccountsError = nil; codexAccountsMessage = nil
        let name = codexAccounts.first(where: { $0.id == id })?.displayName
        defer { codexAccountsBusy = false }
        do {
            let lease = try ServiceLease(root: root, name: "codex-account-lock")
            defer { withExtendedLifetime(lease) {} }
            try await bridge.start(dataDirectory: root)
            let value = try await bridge.request("codex.accounts", ["action": .string(action), "id": .string(id)], timeout: 360)
            let result = try value.decode(CodexAccountsResponse.self)
            codexAccounts = result.accounts
            if let message = result.message {
                let text = name.map { "\($0)：\(message)" } ?? message
                if result.status == "attention" { codexAccountsError = text }
                else { codexAccountsMessage = text }
            }
            if action == "switch", result.status == "switched" {
                codexAccountsMessage = "本机登录已切换，正在重新打开 ChatGPT…"
                do {
                    try await CodexDesktop.reopen()
                    codexAccountsMessage = "\(name.map { "\($0)：" } ?? "")已切换本机登录并重新打开 ChatGPT。独立 CLI 进程请手动重新打开。"
                } catch {
                    codexAccountsMessage = nil
                    codexAccountsError = "本机登录已切换。\(error.localizedDescription)"
                }
            }
            if action == "warmup" {
                try CodexAutoActivation.noteManualResult(root: root, id: id, result: result)
                codexAutoStates = try CodexAutoActivation.load(root: root)
            }
        } catch ServiceLeaseError.occupied {
            codexAccountsError = "后台正在处理账号，请稍后重试"
        } catch {
            codexAccountsError = error.localizedDescription
            if action == "warmup" {
                do {
                    try CodexAutoActivation.noteManualResult(root: root, id: id, result: nil)
                    codexAutoStates = try CodexAutoActivation.load(root: root)
                } catch { codexAccountsError = "无法保存自动激活状态：\(error.localizedDescription)" }
            }
            if action == "switch" { codexAccounts = [] }
        }
    }

    func setCodexAutoActivation(_ id: String, enabled: Bool) {
        guard codexAccounts.contains(where: { $0.id == id }) || codexAutoStates[id] != nil else { return }
        do {
            try CodexAutoActivation.configure(root: root, id: id, enabled: enabled)
            codexAutoStates = try CodexAutoActivation.load(root: root)
        } catch { codexAccountsError = error.localizedDescription }
    }

    func checkCodexAutoActivation() async {
        do {
            codexAutoStates = try CodexAutoActivation.load(root: root)
            codexMessageStates = try CodexScheduledMessage.load(root: root)
            guard !codexAccountsBusy, warmingCodexHome == nil,
                  codexAutoStates.values.contains(where: { $0.enabled && ($0.nextCheck.map { $0 <= Date() } ?? false) }) ||
                  codexMessageStates.values.contains(where: { $0.enabled && ($0.nextCheck.map { $0 <= Date() } ?? false) }) else { return }
            codexAccountsBusy = true
            defer { codexAccountsBusy = false }
            try await bridge.start(dataDirectory: root)
            if let accounts = try await CodexScheduledMessage.runDue(root: root, bridge: bridge) { codexAccounts = accounts }
            if let accounts = try await CodexAutoActivation.runDue(root: root, bridge: bridge) { codexAccounts = accounts }
            codexAutoStates = try CodexAutoActivation.load(root: root)
            codexMessageStates = try CodexScheduledMessage.load(root: root)
        } catch { codexAccountsError = error.localizedDescription }
    }

    func scheduleCodexMessage(_ id: String, sessionID: String, text: String) {
        guard let account = codexAccounts.first(where: { $0.id == id }), let session = codexMessageSessions.first(where: { $0.id == sessionID }) else {
            codexAccountsError = "请选择有效的账号、项目和 Codex 会话"; return
        }
        do {
            try CodexScheduledMessage.configure(root: root, account: account, session: session, text: text)
            codexMessageStates = try CodexScheduledMessage.load(root: root)
            codexAccountsError = nil
        } catch { codexAccountsError = error.localizedDescription }
    }

    func cancelCodexMessage(_ id: String) {
        do {
            try CodexScheduledMessage.cancel(root: root, id: id)
            codexMessageStates = try CodexScheduledMessage.load(root: root)
            codexAccountsError = nil
        } catch { codexAccountsError = error.localizedDescription }
    }

    func launch() async {
        guard !initialized, let store else { return }
        guard !settings.archivePath.isEmpty else { status = "请先设置 Git 用量仓库"; return }
        initialized = true; loadingArchive = true
        defer { loadingArchive = false }
        await bridge.setHandler { [weak self] event, data in await self?.receive(event, data) }
        do {
            try await bridge.start(dataDirectory: root)
            status = "正在读取 Git 用量仓库…"
            let archive = URL(fileURLWithPath: settings.archivePath)
            let count = try await Task.detached(priority: .utility) { try Archive.restore(from: archive, into: store) }.value
            try reload(); archiveLoaded = true; archiveStatus = "已读取 Git 仓库 · \(count) 个会话"
            let initial = try await bridge.request("initialize")
            if settings.locations.isEmpty { settings.locations = try initial["locations"].decode([Location].self) }
            try saveSettings(); ready = true
            if settings.backgroundEnabled == true { await setBackground(true) }
            await refresh(); scheduleArchive()
            monitorTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard let self else { return }
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
                if try store?.save(data.decode(Session.self)) == true { scheduleReload(); scheduleArchive() }
            case "sourceChanged": if !scanning { Task { await refresh() } }
            case "warning": warnings.append(data.string); warnings = Array(warnings.suffix(100))
            case "disconnected": ready = false; error = data.string
            default: break
            }
        } catch { self.error = error.localizedDescription }
    }
    func refresh() async {
        guard ready, !scanning, !archiving else { return }
        do { if try BackgroundService.isRunning(root: root) { try BackgroundService.request(root: root); pollBackground(); return } }
        catch { self.error = error.localizedDescription; return }
        scanning = true; status = "正在读取会话用量…"; lastRefresh = Date()
        do {
            let lease = try ServiceLease(root: root)
            defer { withExtendedLifetime(lease) {} }
            let result = try await bridge.request("scan", ["locations": try .encode(settings.locations)], timeout: 600)
            try reload(); status = "用量已更新 · 本次处理 \(result["count"].text) 个变更会话"
        } catch { self.error = error.localizedDescription; status = "扫描失败，可重试" }
        scanning = false; scheduleArchive(markDirty: false)
    }
    private func scheduleReload() {
        guard reloadTask == nil else { return }
        reloadTask = Task { try? await Task.sleep(for: .milliseconds(300)); do { try reload() } catch { self.error = error.localizedDescription }; reloadTask = nil }
    }
    func reload() throws {
        sessions = try store?.list(query: query) ?? []
        codexMessageSessions = CodexScheduledMessage.eligibleSessions(try store?.list() ?? [])
    }
    func select(_ id: String?) { selectedID = id }
    func saveSettings() throws { try store?.saveSettings(settings) }
    func persistSettings(refreshArchive: Bool = false) {
        do { try saveSettings(); if refreshArchive { scheduleArchive() } }
        catch { self.error = error.localizedDescription }
    }
    func chooseArchive() {
        guard !scanning, !archiving, !loadingArchive else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.prompt = "选择用量仓库"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await configureArchive(url) }
    }
    func configureArchive(_ url: URL) async {
        guard !scanning, !archiving, !loadingArchive else { return }
        do {
            let roots = settings.locations.map(\.path)
            try await Task.detached(priority: .utility) { try Archive.prepare(url, sourceRoots: roots) }.value
            archiveTask?.cancel(); monitorTask?.cancel()
            if settings.archivePath != url.path { settings.archiveRemote = nil; syncStatus = "未启用远端推送" }
            settings.archivePath = url.path; try saveSettings()
            initialized = false; ready = false; archiveLoaded = false
            await launch()
        } catch { self.error = error.localizedDescription }
    }
    func chooseProject() -> String? {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "选择目录"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
    private func scheduleArchive(markDirty: Bool = true) {
        do { if !scanning && !archiving { if try BackgroundService.isRunning(root: root) { archiveTask?.cancel(); return } } }
        catch { self.error = error.localizedDescription; return }
        guard archiveLoaded, !settings.archivePath.isEmpty else { return }
        if markDirty { dirtySince = dirtySince ?? Date(); dirtyGeneration += 1 }
        guard let dirtySince, !scanning else { return }
        archiveTask?.cancel()
        let delay = max(0, min(30, 300 - Date().timeIntervalSince(dirtySince)))
        archiveTask = Task { do { try await Task.sleep(for: .seconds(delay)); await archiveNow() } catch {} }
    }
    func archiveNow() async {
        guard archiveLoaded, let store, !settings.archivePath.isEmpty, !archiving, !scanning else { return }
        do { if try BackgroundService.isRunning(root: root) { try BackgroundService.request(root: root); archiveStatus = "已请求后台归档"; return } }
        catch { self.error = error.localizedDescription; return }
        archiving = true; archiveStatus = "正在保存用量并提交…"
        let generation = dirtyGeneration
        let path = settings.archivePath, excluded = settings.excludedProjects, roots = settings.locations.map(\.path), remote = settings.archiveRemote, prices = settings.prices
        do {
            let lease = try ServiceLease(root: root)
            defer { withExtendedLifetime(lease) {} }
            let result = try await Task.detached(priority: .utility) {
                try Archive.save(store.list().filter { !excluded.contains($0.project) }, to: URL(fileURLWithPath: path), sourceRoots: roots, prices: prices)
            }.value
            archiveStatus = result.commit.map { "已保存并提交 · \($0) · \(result.files) 个文件" } ?? "用量归档已是最新，无需提交"
            lastArchive = Date(); if generation == dirtyGeneration { dirtySince = nil }
            if let remote, settings.archivePath == path, settings.archiveRemote == remote {
                try Data("pending".utf8).write(to: root.appendingPathComponent("sync-pending"), options: .atomic)
                lastPushAttempt = Date(); syncStatus = "正在推送"
                do {
                    _ = try await Task.detached(priority: .utility) { try ArchiveSync.push(root: URL(fileURLWithPath: path), remote: remote.remote, branch: remote.branch) }.value
                    if settings.archivePath == path && settings.archiveRemote == remote {
                        try FileManager.default.removeItem(at: root.appendingPathComponent("sync-pending")); syncStatus = "已推送到 \(remote.remote)/\(remote.branch)"
                    }
                } catch { syncStatus = "推送待重试：\(error.localizedDescription)" }
            } else { syncStatus = settings.archiveRemote == nil ? "未启用远端推送" : "配置已变化，等待按当前配置推送" }
        } catch { archiveStatus = "归档未完成：\(error.localizedDescription)"; self.error = error.localizedDescription }
        archiving = false
        if generation != dirtyGeneration { scheduleArchive(markDirty: false) }
    }
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
                try FileManager.default.removeItem(at: root.appendingPathComponent("sync-pending")); syncStatus = "已推送到 \(remote.remote)/\(remote.branch)"
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
            } else if running { backgroundStatus = "目录由后台任务占用，等待新的状态报告" }
            else {
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
            if enabled { archiveTask?.cancel(); if service.status != .enabled { try service.register() } }
            else { try await service.unregister() }
            pollBackground()
        } catch { self.error = error.localizedDescription; pollBackground() }
    }
}

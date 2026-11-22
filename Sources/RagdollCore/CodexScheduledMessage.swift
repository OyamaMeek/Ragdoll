import Foundation

public enum CodexScheduledMessage {
    public static var desktopHome: URL {
        ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    public static func eligibleSessions(_ sessions: [Session]) -> [Session] {
        sessions.filter { $0.source == "codex" && UUID(uuidString: $0.nativeID) != nil &&
            !$0.project.isEmpty && URL(fileURLWithPath: $0.home).resolvingSymlinksInPath() == desktopHome.resolvingSymlinksInPath() }
    }

    public struct Target: Codable, Sendable, Equatable {
        public let nativeID: String
        public let home: String
        public let project: String
        public let title: String
        public let text: String

        public init(session: Session, text: String) throws {
            nativeID = session.nativeID; home = session.home; project = session.project; title = session.title; self.text = text
            guard session.source == "codex", valid else { throw failure("请选择本地 Codex 会话、有效项目并输入消息") }
        }

        var valid: Bool {
            UUID(uuidString: nativeID) != nil && home.hasPrefix("/") && project.hasPrefix("/") && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public struct State: Codable, Sendable {
        public let target: Target
        public let targetReset: Double
        public var enabled = true
        public var generation = UUID().uuidString
        public var nextCheck: Date?
        public var lastAttempt: Date?
        public var attemptID: String?
        public var queuedSubmissionID: String?
        public var message = "等待下一次 5h 额度刷新后发送一次"

        init(target: Target, resetAt: Double) {
            self.target = target; targetReset = resetAt
            nextCheck = Date(timeIntervalSince1970: resetAt + 30)
        }

        mutating func observe(_ account: CodexAccount, now: Date) -> Bool {
            guard enabled, let nextCheck, nextCheck <= now else { return false }
            guard account.isCurrent else { pause("本机当前登录已改变，请切换回计划账号后重新设置"); return false }
            guard account.usageError == nil, let window = account.fiveHour else { pause("无法确认账号额度，请刷新并检查登录后重新设置"); return false }
            let exhausted = [window, account.oneWeek].compactMap { $0 }.filter { $0.usedPercent >= 100 }
            if !exhausted.isEmpty {
                let reset = exhausted.compactMap(\.resetAt).max() ?? 0
                self.nextCheck = Date(timeIntervalSince1970: max(reset + 30, now.timeIntervalSince1970 + 300))
                message = "额度耗尽，等待服务端重置后发送一次"
                return false
            }
            if now.timeIntervalSince1970 < targetReset + 30 {
                self.nextCheck = Date(timeIntervalSince1970: targetReset + 30)
                return false
            }
            return true
        }

        mutating func beginAttempt(now: Date) -> String {
            let id = UUID().uuidString
            attemptID = id; lastAttempt = now; nextCheck = nil
            message = "正在交给桌面端；若结果不明，请先检查原会话，不要重复设置"
            return id
        }

        mutating func pause(_ message: String) {
            nextCheck = nil; attemptID = nil; self.message = message
        }

        mutating func complete(message: String, queuedSubmissionID: String) {
            enabled = false; nextCheck = nil; attemptID = nil
            self.queuedSubmissionID = queuedSubmissionID; self.message = message
        }
    }

    public static func load(root: URL) throws -> [String: State] {
        let path = root.appendingPathComponent("codex-scheduled-message.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return [:] }
        let states = try JSONDecoder().decode([String: State].self, from: Data(contentsOf: path))
        guard states.allSatisfy({ id, state in
            !id.isEmpty && !id.hasPrefix("-") && !state.generation.isEmpty && state.target.valid &&
            state.targetReset.isFinite && state.targetReset >= 0 &&
            [state.nextCheck, state.lastAttempt].compactMap { $0 }.allSatisfy { $0.timeIntervalSince1970.isFinite }
        }) else { throw failure("定时消息计划无效，已停止发送，请检查本地状态文件") }
        return states
    }

    private static func update(root: URL, _ body: (inout [String: State]) throws -> Void) throws {
        let lease = try ServiceLease(root: root, name: "codex-message-state-lock")
        defer { withExtendedLifetime(lease) {} }
        var states = try load(root: root)
        try body(&states)
        let path = root.appendingPathComponent("codex-scheduled-message.json")
        try JSONEncoder().encode(states).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    public static func configure(root: URL, account: CodexAccount, session: Session, text: String) throws {
        guard !account.id.isEmpty, !account.id.hasPrefix("-"), account.isCurrent, account.usageError == nil,
              let reset = account.fiveHour?.resetAt, reset.isFinite, reset > Date().timeIntervalSince1970 else {
            throw failure("请切换到此账号并刷新额度，取得下一次 5h 重置时间后再设置")
        }
        let target = try Target(session: session, text: text)
        guard eligibleSessions([session]).count == 1 else { throw failure("请选择桌面端当前数据目录中的 Codex 会话") }
        try update(root: root) { $0[account.id] = State(target: target, resetAt: reset) }
    }

    public static func cancel(root: URL, id: String) throws {
        try update(root: root) { states in
            guard var state = states[id] else { return }
            state.enabled = false; state.generation = UUID().uuidString
            state.pause("计划已取消；已经交给桌面端的消息请在原会话检查")
            states[id] = state
        }
    }

    public static func runDue(root: URL, bridge: RuntimeBridge) async throws -> [CodexAccount]? {
        guard try load(root: root).values.contains(where: { $0.enabled && ($0.nextCheck.map { $0 <= Date() } ?? false) }) else { return nil }
        let lease: ServiceLease
        do { lease = try ServiceLease(root: root, name: "codex-account-lock") }
        catch ServiceLeaseError.occupied { return nil }
        defer { withExtendedLifetime(lease) {} }
        let due = try load(root: root).filter { $0.value.enabled && ($0.value.nextCheck.map { $0 <= Date() } ?? false) }
        guard !due.isEmpty else { return nil }
        let accounts: [CodexAccount]
        do {
            accounts = try await bridge.request("codex.accounts", ["action": .string("refresh")], timeout: 120).decode(CodexAccountsResponse.self).accounts
        } catch {
            try update(root: root) { states in
                for (id, expected) in due where states[id]?.generation == expected.generation {
                    states[id]?.nextCheck = Date().addingTimeInterval(300)
                    states[id]?.message = "额度读取失败，5 分钟后重新检查：\(error.localizedDescription)"
                }
            }
            return nil
        }
        var latest = accounts
        for (id, expected) in due.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            var attempt: String?
            try update(root: root) { states in
                guard var state = states[id], state.enabled, state.generation == expected.generation else { return }
                if let account = accounts.first(where: { $0.id == id }) {
                    if state.observe(account, now: Date()) { attempt = state.beginAttempt(now: Date()) }
                } else { state.pause("账号已不存在，请检查 Codex Tools 后重新设置") }
                states[id] = state
            }
            guard let attempt else { continue }
            do {
                let value = try await bridge.request("codex.sendScheduledMessage", ["id": .string(id), "attemptID": .string(attempt)], timeout: 180)
                let result = try value.decode(CodexAccountsResponse.self)
                guard let message = result.message, result.status == "queued" && !value["queuedSubmissionID"].string.isEmpty || result.status == "exhausted" else {
                    throw failure("无法确认桌面端收到消息，请先检查原会话")
                }
                latest = result.accounts
                try update(root: root) { states in
                    guard var state = states[id], state.generation == expected.generation, state.attemptID == attempt else { return }
                    if result.status == "queued" {
                        state.complete(message: message, queuedSubmissionID: value["queuedSubmissionID"].string)
                    } else {
                        state.attemptID = nil; state.nextCheck = Date()
                        if let account = result.accounts.first(where: { $0.id == id }) {
                            if state.observe(account, now: Date()) { state.pause("额度返回状态不一致，请刷新并重新设置") }
                        } else { state.pause("无法读取账号额度，请刷新并重新设置") }
                    }
                    states[id] = state
                }
            } catch {
                try update(root: root) { states in
                    guard states[id]?.generation == expected.generation, states[id]?.attemptID == attempt else { return }
                    states[id]?.pause("消息计划已暂停，请先检查原会话再重新设置：\(error.localizedDescription)")
                }
            }
        }
        return latest
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Ragdoll.CodexScheduledMessage", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

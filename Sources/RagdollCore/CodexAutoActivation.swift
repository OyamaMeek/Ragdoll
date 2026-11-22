import Foundation

public enum CodexAutoActivation {
    public struct State: Codable, Sendable {
        public var enabled: Bool
        public var generation = UUID().uuidString
        public var targetReset: Double?
        public var nextCheck: Date?
        public var lastAttempt: Date?
        public var attemptID: String?
        public var message = "等待读取窗口重置时间"

        public init(enabled: Bool = false, now: Date = Date()) {
            self.enabled = enabled
            nextCheck = enabled ? now : nil
        }

        mutating func observe(_ account: CodexAccount, now: Date) -> Bool {
            guard enabled, let nextCheck, nextCheck <= now else { return false }
            guard account.usageError == nil, let window = account.fiveHour else {
                pause("无法确认账号额度，请检查登录后关闭再开启自动激活")
                return false
            }
            let exhausted = [window, account.oneWeek].compactMap { $0 }.filter { $0.usedPercent >= 100 }
            if !exhausted.isEmpty {
                let reset = exhausted.compactMap(\.resetAt).max() ?? 0
                self.nextCheck = Date(timeIntervalSince1970: max(reset + 30, now.timeIntervalSince1970 + 300))
                message = "额度耗尽，等待服务端重置后再检查"
                return false
            }
            if targetReset == nil || (window.usedPercent > 0 && (window.resetAt ?? 0) > now.timeIntervalSince1970) {
                guard let reset = window.resetAt, reset > now.timeIntervalSince1970 else {
                    pause("服务端未提供未来的窗口重置时间，请刷新后重新开启")
                    return false
                }
                targetReset = reset
                self.nextCheck = Date(timeIntervalSince1970: reset + 30)
                message = "等待当前 5h 窗口刷新"
                return false
            }
            if let targetReset, now.timeIntervalSince1970 < targetReset + 30 {
                self.nextCheck = Date(timeIntervalSince1970: targetReset + 30)
                return false
            }
            return true
        }

        mutating func beginAttempt(now: Date) -> String {
            let id = UUID().uuidString
            attemptID = id; lastAttempt = now; nextCheck = nil
            message = "自动请求已登记；若进程中断未收到结果，请关闭再开启自动激活"
            return id
        }

        mutating func pause(_ message: String) {
            nextCheck = nil; attemptID = nil; self.message = message
        }

        mutating func complete(status: String, message: String, account: CodexAccount?, previousAttempt: Date?, now: Date) {
            attemptID = nil
            if status == "alreadyActive" || status == "exhausted" {
                lastAttempt = previousAttempt; targetReset = nil; nextCheck = now
                if let account { _ = observe(account, now: now) }
                else { pause("请求未发送，但窗口状态缺失，请重新开启") }
            } else if status == "activated", let reset = account?.fiveHour?.resetAt, reset > now.timeIntervalSince1970 {
                targetReset = reset
                nextCheck = Date(timeIntervalSince1970: reset + 30)
            } else {
                let earliest = (lastAttempt ?? now).addingTimeInterval(18000)
                let reset = max(account?.fiveHour?.resetAt ?? 0, earliest.timeIntervalSince1970)
                targetReset = reset
                nextCheck = Date(timeIntervalSince1970: reset + 30)
            }
            self.message = message
        }
    }

    public static func load(root: URL) throws -> [String: State] {
        let path = root.appendingPathComponent("codex-auto-activation.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return [:] }
        let states = try JSONDecoder().decode([String: State].self, from: Data(contentsOf: path))
        guard states.allSatisfy({ id, state in
            !id.isEmpty && !id.hasPrefix("-") && !state.generation.isEmpty &&
            (state.targetReset.map { $0.isFinite && $0 >= 0 } ?? true) &&
            [state.nextCheck, state.lastAttempt].compactMap { $0 }.allSatisfy { $0.timeIntervalSince1970.isFinite }
        }) else { throw failure("自动激活状态无效，请检查本地状态文件") }
        return states
    }

    private static func update(root: URL, _ body: (inout [String: State]) throws -> Void) throws {
        let lease = try ServiceLease(root: root, name: "codex-auto-state-lock")
        defer { withExtendedLifetime(lease) {} }
        var states = try load(root: root)
        try body(&states)
        let path = root.appendingPathComponent("codex-auto-activation.json")
        try JSONEncoder().encode(states).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    public static func configure(root: URL, id: String, enabled: Bool) throws {
        guard !id.isEmpty, !id.hasPrefix("-") else { throw failure("请选择有效的 Codex 账号") }
        try update(root: root) { states in
            let previous = states[id]
            var state = State(enabled: enabled)
            state.lastAttempt = previous?.lastAttempt
            if !enabled { state.message = "自动激活已关闭" }
            states[id] = state
        }
    }

    public static func noteManualResult(root: URL, id: String, result: CodexAccountsResponse?) throws {
        guard try load(root: root)[id]?.enabled == true else { return }
        try update(root: root) { states in
            guard var state = states[id], state.enabled else { return }
            let previous = state.lastAttempt
            if let result, let status = result.status, let message = result.message {
                if status == "activated" || status == "requestSent" { _ = state.beginAttempt(now: Date()) }
                state.complete(status: status, message: message, account: result.accounts.first(where: { $0.id == id }), previousAttempt: previous, now: Date())
            } else {
                _ = state.beginAttempt(now: Date())
                state.pause("手动请求结果未确认，自动激活已暂停；检查后关闭再开启")
            }
            states[id] = state
        }
    }

    public static func runDue(root: URL, bridge: RuntimeBridge) async throws -> [CodexAccount]? {
        let initial = try load(root: root)
        guard initial.values.contains(where: { $0.enabled && ($0.nextCheck.map { $0 <= Date() } ?? false) }) else { return nil }
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
            var attempt: String?, previousAttempt: Date?
            try update(root: root) { states in
                guard var state = states[id], state.enabled, state.generation == expected.generation else { return }
                guard let account = accounts.first(where: { $0.id == id }) else {
                    state.pause("账号已不存在，请关闭自动激活并检查账号列表"); states[id] = state; return
                }
                if state.observe(account, now: Date()) {
                    previousAttempt = state.lastAttempt
                    attempt = state.beginAttempt(now: Date())
                }
                states[id] = state
            }
            guard let attempt else { continue }
            do {
                let value = try await bridge.request("codex.autoWarmup", ["id": .string(id), "attemptID": .string(attempt)], timeout: 360)
                let result = try value.decode(CodexAccountsResponse.self)
                guard let status = result.status, ["activated", "requestSent", "alreadyActive", "exhausted"].contains(status), let message = result.message else {
                    throw failure("自动请求返回的完成状态无效")
                }
                latest = result.accounts
                try update(root: root) { states in
                    guard states[id]?.generation == expected.generation, states[id]?.attemptID == attempt else { return }
                    states[id]?.complete(status: status, message: message, account: result.accounts.first(where: { $0.id == id }), previousAttempt: previousAttempt, now: Date())
                }
            } catch {
                try update(root: root) { states in
                    guard states[id]?.generation == expected.generation, states[id]?.attemptID == attempt else { return }
                    states[id]?.pause("自动激活已暂停，请检查结果后关闭再开启：\(error.localizedDescription)")
                }
            }
        }
        return latest
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Ragdoll.CodexAutoActivation", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

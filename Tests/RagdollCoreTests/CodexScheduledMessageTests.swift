import Foundation
import Testing
@testable import RagdollCore

private func messageAccount(current: Bool = true, used: Double = 10, reset: Double, weekly: Double = 10) throws -> CodexAccount {
    let value: [String: Any] = ["id": "a", "label": "A", "email": "", "planType": "plus", "isCurrent": current,
        "fiveHour": ["usedPercent": used, "resetAt": reset], "oneWeek": ["usedPercent": weekly, "resetAt": reset + 604800]]
    return try JSONDecoder().decode(CodexAccount.self, from: JSONSerialization.data(withJSONObject: value))
}

private func messageSession(home: String = CodexScheduledMessage.desktopHome.path) -> Session {
    Session(id: "codex:one", nativeID: "019ab102-1234-7123-8123-123456789abc", source: "codex", title: "原会话", project: "/project", home: home)
}

@Test func scheduledMessageWaitsForNextResetAndSendsEvenWhenTheNewWindowIsAlreadyActive() throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let target = try CodexScheduledMessage.Target(session: messageSession(), text: "继续\n保持原样")
    var state = CodexScheduledMessage.State(target: target, resetAt: now.timeIntervalSince1970 + 100)
    #expect(!state.observe(try messageAccount(reset: now.timeIntervalSince1970 + 100), now: now))
    #expect(!state.observe(try messageAccount(reset: now.timeIntervalSince1970 + 18100), now: now.addingTimeInterval(129)))
    #expect(state.observe(try messageAccount(used: 15, reset: now.timeIntervalSince1970 + 18100), now: now.addingTimeInterval(130)))
    let attempt = state.beginAttempt(now: now.addingTimeInterval(130))
    #expect(!attempt.isEmpty)
    #expect(state.nextCheck == nil)
    let restored = try JSONDecoder().decode(CodexScheduledMessage.State.self, from: JSONEncoder().encode(state))
    #expect(restored.attemptID == attempt)
    #expect(restored.nextCheck == nil)
    state.complete(message: "已入队", queuedSubmissionID: "native-item")
    #expect(!state.enabled)
    #expect(state.queuedSubmissionID == "native-item")
    #expect(!state.observe(try messageAccount(reset: now.timeIntervalSince1970 + 36100), now: now.addingTimeInterval(20000)))
}

@Test func scheduledMessagePausesChangedAccountsAndWaitsForExhaustedQuota() throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let target = try CodexScheduledMessage.Target(session: messageSession(), text: "继续")
    var changed = CodexScheduledMessage.State(target: target, resetAt: now.timeIntervalSince1970 - 100)
    #expect(!changed.observe(try messageAccount(current: false, reset: now.timeIntervalSince1970 + 100), now: now))
    #expect(changed.nextCheck == nil)
    #expect(changed.lastAttempt == nil)
    var exhausted = CodexScheduledMessage.State(target: target, resetAt: now.timeIntervalSince1970 - 100)
    #expect(!exhausted.observe(try messageAccount(reset: now.timeIntervalSince1970 + 100, weekly: 100), now: now))
    #expect(exhausted.nextCheck == now.addingTimeInterval(604930))
    _ = exhausted.beginAttempt(now: now)
    exhausted.pause("结果不明")
    #expect(exhausted.nextCheck == nil)
    #expect(!exhausted.observe(try messageAccount(reset: now.timeIntervalSince1970 + 100), now: now.addingTimeInterval(999999)))
}

@Test func scheduledMessagePersistsPrivatePlansAndCancellationInvalidatesOldAttempts() throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let reset = Date().addingTimeInterval(500).timeIntervalSince1970
    #expect(try CodexScheduledMessage.load(root: root).isEmpty)
    try CodexScheduledMessage.configure(root: root, account: messageAccount(reset: reset), session: messageSession(), text: "  自定义\n消息  ")
    let before = try #require(CodexScheduledMessage.load(root: root)["a"])
    #expect(before.enabled)
    #expect(before.target.text == "  自定义\n消息  ")
    #expect(before.nextCheck == Date(timeIntervalSince1970: reset + 30))
    let mode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("codex-scheduled-message.json").path)[.posixPermissions] as? NSNumber
    #expect(mode?.intValue == 0o600)
    try CodexScheduledMessage.cancel(root: root, id: "a")
    let canceled = try #require(CodexScheduledMessage.load(root: root)["a"])
    #expect(!canceled.enabled)
    #expect(canceled.nextCheck == nil)
    #expect(canceled.generation != before.generation)
    try CodexScheduledMessage.configure(root: root, account: messageAccount(reset: reset), session: messageSession(), text: "新消息")
    #expect(try CodexScheduledMessage.load(root: root)["a"]?.generation != canceled.generation)
    #expect(throws: (any Error).self) { try CodexScheduledMessage.configure(root: root, account: messageAccount(current: false, reset: reset), session: messageSession(), text: "继续") }
    #expect(throws: (any Error).self) { try CodexScheduledMessage.configure(root: root, account: messageAccount(reset: 0), session: messageSession(), text: "继续") }
    #expect(throws: (any Error).self) { try CodexScheduledMessage.Target(session: messageSession(), text: " \n ") }
    var invalid = messageSession(); invalid.nativeID = "--last"
    #expect(throws: (any Error).self) { try CodexScheduledMessage.Target(session: invalid, text: "继续") }
    try Data("broken".utf8).write(to: root.appendingPathComponent("codex-scheduled-message.json"))
    #expect(throws: (any Error).self) { try CodexScheduledMessage.load(root: root) }
}

@Test func scheduledMessageSharesAccountLeaseAndOnlyOffersDesktopCodexSessions() async throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    try CodexScheduledMessage.configure(root: root, account: messageAccount(reset: Date().addingTimeInterval(500).timeIntervalSince1970), session: messageSession(), text: "继续")
    var states = try CodexScheduledMessage.load(root: root)
    states["a"]?.nextCheck = .distantPast
    try JSONEncoder().encode(states).write(to: root.appendingPathComponent("codex-scheduled-message.json"), options: .atomic)
    let lease = try ServiceLease(root: root, name: "codex-account-lock")
    #expect(try await CodexScheduledMessage.runDue(root: root, bridge: RuntimeBridge()) == nil)
    #expect(try CodexScheduledMessage.load(root: root)["a"]?.lastAttempt == nil)
    var otherSource = messageSession(); otherSource.source = "desktop"
    #expect(CodexScheduledMessage.eligibleSessions([messageSession(), messageSession(home: "/other-home"), otherSource]).map(\.id) == ["codex:one"])
    withExtendedLifetime(lease) {}
}

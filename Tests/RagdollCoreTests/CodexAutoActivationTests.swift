import Foundation
import Testing
@testable import RagdollCore

private func autoAccount(used: Double = 0, reset: Double, weekly: Double = 10) throws -> CodexAccount {
    let value: [String: Any] = ["id": "a", "label": "A", "email": "", "planType": "plus", "isCurrent": false,
        "fiveHour": ["usedPercent": used, "resetAt": reset], "oneWeek": ["usedPercent": weekly, "resetAt": reset + 604800]]
    return try JSONDecoder().decode(CodexAccount.self, from: JSONSerialization.data(withJSONObject: value))
}

@Test func autoActivationWaitsForResetAndSkipsAnAlreadyActiveWindow() throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    var state = CodexAutoActivation.State(enabled: true, now: now)
    #expect(!state.observe(try autoAccount(reset: now.timeIntervalSince1970 + 100), now: now))
    #expect(state.nextCheck == now.addingTimeInterval(130))
    #expect(!state.observe(try autoAccount(reset: now.timeIntervalSince1970 + 100), now: now.addingTimeInterval(129)))
    #expect(state.observe(try autoAccount(reset: now.timeIntervalSince1970 + 18130), now: now.addingTimeInterval(130)))
    var active = CodexAutoActivation.State(enabled: true, now: now)
    #expect(!active.observe(try autoAccount(used: 20, reset: now.timeIntervalSince1970 + 500), now: now))
    #expect(active.nextCheck == now.addingTimeInterval(530))
}

@Test func autoActivationPersistsAnAttemptBeforeSendingAndCoolsDownUnconfirmedResults() throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    var state = CodexAutoActivation.State(enabled: true, now: now)
    let attempt = state.beginAttempt(now: now)
    #expect(state.lastAttempt == now)
    #expect(state.nextCheck == nil)
    #expect(state.attemptID == attempt)
    let restored = try JSONDecoder().decode(CodexAutoActivation.State.self, from: JSONEncoder().encode(state))
    #expect(restored.nextCheck == nil)
    state.complete(status: "requestSent", message: "尚未确认", account: try autoAccount(reset: now.timeIntervalSince1970 + 100), previousAttempt: nil, now: now)
    #expect(state.nextCheck! >= now.addingTimeInterval(18000))
    #expect(!state.observe(try autoAccount(reset: now.timeIntervalSince1970 + 100), now: now.addingTimeInterval(60)))
}

@Test func autoActivationSkipsExhaustedQuotaAndKeepsFailedInferencePaused() throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    var state = CodexAutoActivation.State(enabled: true, now: now)
    #expect(!state.observe(try autoAccount(reset: now.timeIntervalSince1970 + 100, weekly: 100), now: now))
    #expect(state.nextCheck! > now.addingTimeInterval(604800))
    _ = state.beginAttempt(now: now)
    state.pause("请求结果未知，请重新开启")
    #expect(state.nextCheck == nil)
    #expect(state.lastAttempt == now)
    #expect(!state.observe(try autoAccount(reset: now.timeIntervalSince1970 + 1), now: now.addingTimeInterval(18001)))
}

@Test func autoActivationUsesConfirmedServerResetEvenWhenItIsLessThanFiveHoursAway() throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    var state = CodexAutoActivation.State(enabled: true, now: now)
    _ = state.beginAttempt(now: now)
    state.complete(status: "activated", message: "已确认", account: try autoAccount(used: 1, reset: now.timeIntervalSince1970 + 100), previousAttempt: nil, now: now)
    #expect(state.nextCheck == now.addingTimeInterval(130))
    #expect(state.observe(try autoAccount(reset: now.timeIntervalSince1970 + 18130), now: now.addingTimeInterval(130)))
}

@Test func autoActivationConfigurationSurvivesReloadAndInvalidatesOldAttempts() throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    #expect(try CodexAutoActivation.load(root: root).isEmpty)
    try CodexAutoActivation.configure(root: root, id: "a", enabled: true)
    let before = try #require(CodexAutoActivation.load(root: root)["a"])
    #expect(before.enabled)
    try CodexAutoActivation.configure(root: root, id: "a", enabled: false)
    let after = try #require(CodexAutoActivation.load(root: root)["a"])
    #expect(!after.enabled)
    #expect(after.nextCheck == nil)
    #expect(before.generation != after.generation)
    try Data("broken".utf8).write(to: root.appendingPathComponent("codex-auto-activation.json"))
    #expect(throws: (any Error).self) { try CodexAutoActivation.load(root: root) }
}

@Test func autoActivationSharesTheAccountOperationLeaseAcrossWorkers() async throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    try CodexAutoActivation.configure(root: root, id: "a", enabled: true)
    let lease = try ServiceLease(root: root, name: "codex-account-lock")
    let result = try await CodexAutoActivation.runDue(root: root, bridge: RuntimeBridge())
    #expect(result == nil)
    #expect(try CodexAutoActivation.load(root: root)["a"]?.lastAttempt == nil)
    withExtendedLifetime(lease) {}
}

@Test func autoActivationAlsoObservesManualRequestsAndPausesUnknownManualResults() throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    try CodexAutoActivation.configure(root: root, id: "a", enabled: true)
    let result = try JSONDecoder().decode(CodexAccountsResponse.self, from: Data(#"{"accounts":[],"status":"requestSent","message":"已完成但未确认"}"#.utf8))
    try CodexAutoActivation.noteManualResult(root: root, id: "a", result: result)
    let sent = try #require(CodexAutoActivation.load(root: root)["a"])
    #expect(sent.nextCheck! >= sent.lastAttempt!.addingTimeInterval(18000))
    try CodexAutoActivation.noteManualResult(root: root, id: "a", result: nil)
    #expect(try CodexAutoActivation.load(root: root)["a"]?.nextCheck == nil)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["RAGDOLL_CODEX_AUTO_LIVE"] == "1"))
func realAutoActivationRegistersBothAccountsAndTheBackgroundWorkerWaitsWithoutSending() async throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let bridge = RuntimeBridge()
    try await bridge.start(dataDirectory: root)
    let accounts = try await bridge.request("codex.accounts", ["action": .string("list")]).decode(CodexAccountsResponse.self).accounts
    #expect(accounts.count == 2)
    let current = accounts.first(where: \.isCurrent)?.id
    for account in accounts { try CodexAutoActivation.configure(root: root, id: account.id, enabled: true) }
    let refreshed = try #require(await CodexAutoActivation.runDue(root: root, bridge: bridge))
    #expect(refreshed.first(where: \.isCurrent)?.id == current)
    for state in try CodexAutoActivation.load(root: root).values {
        #expect(state.lastAttempt == nil)
        #expect(state.nextCheck! > Date())
    }
    #expect(try await CodexAutoActivation.runDue(root: root, bridge: bridge) == nil)
    await bridge.close()
    for account in accounts { try CodexAutoActivation.configure(root: root, id: account.id, enabled: true) }
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let process = Process(); process.executableURL = project.appendingPathComponent(".build/debug/RagdollService")
    process.arguments = ["--data-dir", root.path, "--once"]
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try process.run()
    defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
    let deadline = Date().addingTimeInterval(60)
    while process.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    #expect(!process.isRunning)
    guard !process.isRunning else { return }
    #expect(process.terminationStatus == 0)
    for state in try CodexAutoActivation.load(root: root).values {
        #expect(state.lastAttempt == nil)
        #expect(state.nextCheck! > Date())
    }
}

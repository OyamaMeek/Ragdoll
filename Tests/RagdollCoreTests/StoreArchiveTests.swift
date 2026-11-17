import Foundation
import Testing
@testable import RagdollCore

func testDirectory() throws -> URL {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".agent/tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@discardableResult func git(_ root: URL, _ args: [String]) throws -> String {
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = ["-C", root.path] + args
    let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
    try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NSError(domain: String(decoding: data, as: UTF8.self), code: Int(process.terminationStatus)) }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

@Test func storePersistsAndSearchesActualMessages() throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try Store(path: root.appendingPathComponent("index.sqlite").path)
    let session = Session(id: "one", source: "claude", title: "Build", messages: [Message(role: "user", text: "unique searchable text")])
    #expect(try store.save(session))
    #expect(try !store.save(session))
    #expect(try store.list(query: "searchable").count == 1)
    #expect(try store.list(query: "%").isEmpty)
    #expect(try store.session("one")?.messages.first?.text == "unique searchable text")
}

@Test func olderSourceDataCannotReplaceNewerRepositoryHistory() throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try Store(path: root.appendingPathComponent("index.sqlite").path)
    let archived = Session(id: "one", source: "codex", title: "Newer in Git", updated: 20, messages: [Message(role: "user", text: "NEWER_GIT_HISTORY")])
    try store.save(archived)
    let stale = Session(id: "one", source: "codex", title: "Old source", updated: 10)
    #expect(try !store.save(stale))
    #expect(try store.session("one") == archived)
    var fresh = archived; fresh.updated = 30; fresh.messages.append(Message(role: "assistant", text: "NEW_LOCAL_DATA"))
    #expect(try store.save(fresh))
    #expect(try store.session("one") == fresh)
}

@Test func weeklyBudgetVisibilityDefaultsOffAndPersistsWithoutClearingAmount() throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("index.sqlite").path
    #expect(try JSONValue.encode(Store(path: path).settings())["showWeeklyBudget"] != .bool(true))
    var record = try JSONValue.encode(Settings()).dictionary
    record.removeValue(forKey: "showWeeklyBudget")
    record["weeklyBudget"] = .number(100)
    let legacy = try JSONValue.object(record).decode(Settings.self)
    #expect(try JSONValue.encode(legacy)["showWeeklyBudget"] != .bool(true))
    for enabled in [true, false] {
        record["showWeeklyBudget"] = .bool(enabled)
        try Store(path: path).saveSettings(JSONValue.object(record).decode(Settings.self))
        let restored = try Store(path: path).settings()
        #expect(try JSONValue.encode(restored)["showWeeklyBudget"] == .bool(enabled))
        #expect(restored.weeklyBudget == 100)
    }
}

@Test func archiveCommitsOnlyManagedChangesAndProtectsEdits() throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    try git(root, ["init"]); try git(root, ["config", "user.name", "Ragdoll Tests"]); try git(root, ["config", "user.email", "tests@localhost"])
    try Data("outside".utf8).write(to: root.appendingPathComponent("unrelated.txt"))
    try git(root, ["add", "unrelated.txt"])
    let session = Session(id: "codex:one", source: "codex", title: "Hello", messages: [Message(role: "user", text: "save me")])
    let first = try Archive.save([session], to: root)
    #expect(first.commit != nil)
    #expect(try !git(root, ["ls-tree", "--name-only", "HEAD"]).contains("unrelated.txt"))
    #expect(try git(root, ["diff", "--cached", "--name-only"]) == "unrelated.txt")
    #expect(try Archive.save([session], to: root).commit == nil)
    let transcript = root.appendingPathComponent("sessions/codex/codex_one/transcript.md")
    try Data("hand edited".utf8).write(to: transcript)
    #expect(throws: (any Error).self) { try Archive.save([session], to: root) }
    #expect(try String(contentsOf: transcript, encoding: .utf8) == "hand edited")
}

@Test func archiveCannotLiveInsideSourceHome() throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: (any Error).self) { try Archive.save([], to: root.appendingPathComponent("archive"), sourceRoots: [root.path]) }
}

@Test func provenACPAliasesCountOnceAndPreserveRawSources() throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try Store(path: root.appendingPathComponent("index.sqlite").path)
    let usage = Usage(id: "request-1", time: 1_800_000_000_000, model: "test", input: 100, output: 10)
    let native = Session(id: "native", nativeID: "same-id", source: "codex", title: "Native", home: "/source", usage: [usage], files: ["/source/rollout.jsonl"])
    var alias = Session(id: "acp", nativeID: "same-id", source: "acp", title: "ACP", home: "/source", files: ["/app/events.jsonl"])
    alias.nativeSource = "codex"
    try store.save(alias); try store.save(native)
    #expect(try store.list().count == 1)
    #expect(try store.list().first?.tokens == 110)
    #expect(try store.session("acp")?.files.count == 2)
    #expect(try store.session("acp")?.canonicalID == "native")
}

@Test func archivePreservesAnExternallyStagedManagedVersion() throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    try git(root, ["init"]); try git(root, ["config", "user.name", "Ragdoll Tests"]); try git(root, ["config", "user.email", "tests@localhost"])
    let session = Session(id: "one", source: "codex", title: "One")
    _ = try Archive.save([session], to: root)
    let path = "sessions/codex/one/transcript.md", url = root.appendingPathComponent(path)
    let original = try Data(contentsOf: url)
    try Data("external staged edit".utf8).write(to: url); try git(root, ["add", "--", path]); try original.write(to: url)
    #expect(throws: (any Error).self) { try Archive.save([session], to: root) }
    #expect(try git(root, ["show", ":\(path)"]) == "external staged edit")
    #expect(try Data(contentsOf: url) == original)
}

@Test func archiveDoesNotStageExcludedProjects() throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    try git(root, ["init"]); try git(root, ["config", "user.name", "Ragdoll Tests"]); try git(root, ["config", "user.email", "tests@localhost"])
    var active = Session(id: "active", source: "codex", title: "Active")
    let excluded = Session(id: "excluded", source: "codex", title: "Excluded")
    _ = try Archive.save([active, excluded], to: root)
    let path = "sessions/codex/excluded/transcript.md"
    try Data("keep staged".utf8).write(to: root.appendingPathComponent(path)); try git(root, ["add", "--", path])
    active.messages.append(Message(role: "user", text: "new active work"))
    _ = try Archive.save([active], to: root)
    #expect(try git(root, ["diff", "--cached", "--name-only"]) == path)
    #expect(try git(root, ["show", ":\(path)"]) == "keep staged")
}

@Test func archiveHandlesPathListsBeyondSystemArgumentLimits() throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    try git(root, ["init"]); try git(root, ["config", "user.name", "Ragdoll Tests"]); try git(root, ["config", "user.email", "tests@localhost"])
    let sessions = (0..<1500).map { Session(id: String(repeating: "a", count: 180) + String($0), source: "codex", title: "History \($0)") }
    #expect(try Archive.save(sessions, to: root).commit != nil)
    #expect(try git(root, ["ls-tree", "-r", "--name-only", "HEAD"]).components(separatedBy: .newlines).count == 4501)
}

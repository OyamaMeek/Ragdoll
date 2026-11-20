import Foundation
import GRDB
import Testing
@testable import RagdollCore

private func legacyUsageRecord() throws -> Data {
    let session = Session(id: "legacy", nativeID: "native", source: "codex", title: "Saved name", project: "/work", created: 1000, updated: 2000, usage: [Usage(id: "resp_1", time: 1500, model: "model", input: 17, output: 29, cacheRead: 3, cacheWrite: 5)])
    var record = try JSONValue.encode(session).dictionary
    record["messages"] = .array([.object(["id": .string("message"), "role": .string("user"), "text": .string(String(repeating: "PRIVATE_BODY", count: 100_000)), "time": .number(1000), "kind": .string("text")])])
    record["files"] = .array([.string("/private/attachment.png")])
    record["migration"] = .object(["sourceID": .string("private"), "source": .string("codex"), "sourceNativeID": .string("native"), "created": .number(1000)])
    return try JSONEncoder().encode(JSONValue.object(record))
}

@Test func legacySessionEncodingRetainsUsageWithoutBodyOrAttachmentReferences() throws {
    let session = try JSONDecoder().decode(Session.self, from: legacyUsageRecord())
    let encoded = try JSONValue.encode(session)
    #expect(encoded["messages"] == .null)
    #expect(encoded["files"] == .null)
    #expect(encoded["migration"] == .null)
    #expect(session.tokens == 54)
    #expect(session.title == "Saved name")
}

@Test func legacyDatabaseMigrationPreservesUsageAndCreatesRecoveryCopy() throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("index.sqlite").path
    let legacy = try DatabaseQueue(path: path), body = try legacyUsageRecord()
    var summary = try JSONDecoder().decode(JSONValue.self, from: body).dictionary
    summary["messages"] = .array([])
    try legacy.write { db in
        try db.execute(sql: "CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT NOT NULL, native_id TEXT NOT NULL, title TEXT NOT NULL, project TEXT NOT NULL, updated REAL NOT NULL, body BLOB NOT NULL, summary BLOB NOT NULL, search TEXT NOT NULL, canonical_id TEXT)")
        try db.execute(sql: "INSERT INTO sessions VALUES ('legacy','codex','native','Saved name','/work',2000,?,?,?,NULL)", arguments: [body, try JSONEncoder().encode(JSONValue.object(summary)), String(repeating: "PRIVATE_SEARCH", count: 100_000)])
        try db.execute(sql: "CREATE TABLE settings (id INTEGER PRIMARY KEY, body BLOB NOT NULL)")
        var settings = Settings(); settings.weeklyBudget = 123
        try db.execute(sql: "INSERT INTO settings VALUES (1,?)", arguments: [try JSONEncoder().encode(settings)])
    }
    try legacy.close()
    let before = try FileManager.default.attributesOfItem(atPath: path)[.size] as! UInt64
    let store = try Store(path: path)
    #expect(try store.list().count == 1)
    #expect(try store.session("legacy")?.tokens == 54)
    #expect(try store.settings().weeklyBudget == 123)
    #expect(try store.list(query: "PRIVATE_SEARCH").isEmpty)
    #expect(try store.list(query: "/work").count == 1)
    let database = try DatabaseQueue(path: path)
    let columns = try database.read { try $0.columns(in: "sessions").map(\.name) }
    #expect(!columns.contains("summary"))
    #expect(!columns.contains("search"))
    let after = try FileManager.default.attributesOfItem(atPath: path)[.size] as! UInt64
    #expect(after < before / 10)
    let backup = root.appendingPathComponent("index.sqlite.before-usage")
    #expect(FileManager.default.fileExists(atPath: backup.path))
    if FileManager.default.fileExists(atPath: backup.path) {
        let recovery = try DatabaseQueue(path: backup.path)
        #expect(try recovery.read { try Data.fetchOne($0, sql: "SELECT body FROM sessions WHERE id='legacy'") } == body)
    }
    #expect(try Store(path: path).list().first?.tokens == 54)
}

@Test func usageArchiveOmitsBodiesRawLogsAndAttachments() throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    try Archive.prepare(root)
    try git(root, ["config", "user.name", "Usage"]); try git(root, ["config", "user.email", "usage@localhost"])
    let session = try JSONDecoder().decode(Session.self, from: legacyUsageRecord())
    _ = try Archive.save([session], to: root)
    let paths = try git(root, ["ls-tree", "-r", "--name-only", "HEAD"])
    #expect(!paths.contains("transcript.md"))
    #expect(!paths.contains("events.json"))
    #expect(!paths.contains("/raw/"))
    #expect(paths.contains("usage/codex/legacy.json"))
    if paths.contains("usage/codex/legacy.json") {
        let record = try git(root, ["show", "HEAD:usage/codex/legacy.json"])
        #expect(!record.contains("PRIVATE_BODY"))
        #expect(!record.contains("attachment.png"))
        #expect(try JSONDecoder().decode(Session.self, from: Data(record.utf8)).tokens == 54)
    }
}

@Test func invalidLegacySummaryLeavesOriginalDatabaseRecoverable() throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("index.sqlite").path
    let original = try DatabaseQueue(path: path)
    try original.write { db in
        try db.execute(sql: "CREATE TABLE sessions (id TEXT PRIMARY KEY, body BLOB NOT NULL, summary BLOB NOT NULL)")
        try db.execute(sql: "INSERT INTO sessions VALUES ('invalid',?,?)", arguments: [Data("original body".utf8), Data("invalid JSON".utf8)])
    }
    try original.close()
    #expect(throws: (any Error).self) { try Store(path: path) }
    let preserved = try DatabaseQueue(path: path)
    #expect(try preserved.read { try Data.fetchOne($0, sql: "SELECT body FROM sessions") } == Data("original body".utf8))
    #expect(try preserved.read { try $0.columns(in: "sessions").map(\.name) } == ["id", "body", "summary"])
    #expect(FileManager.default.fileExists(atPath: path + ".before-usage"))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["RAGDOLL_VERIFY_DATABASE"] != nil))
func realDatabaseCopyPreservesEverySessionAndUsageDuringMigration() throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let sourcePath = try #require(ProcessInfo.processInfo.environment["RAGDOLL_VERIFY_DATABASE"])
    var configuration = Configuration(); configuration.readonly = true
    let source = try DatabaseQueue(path: sourcePath, configuration: configuration)
    let path = root.appendingPathComponent("index.sqlite").path, copy = try DatabaseQueue(path: path)
    try source.backup(to: copy)
    let originals = try copy.read { try Data.fetchAll($0, sql: "SELECT summary FROM sessions").map { try JSONDecoder().decode(Session.self, from: $0) } }
    let settings = try copy.read { db in
        let data = try #require(try Data.fetchOne(db, sql: "SELECT body FROM settings WHERE id=1"))
        return try JSONDecoder().decode(Settings.self, from: data)
    }
    try copy.close(); try source.close()
    let before = try FileManager.default.attributesOfItem(atPath: path)[.size] as! UInt64
    let store = try Store(path: path)
    for session in originals { #expect(try store.session(session.id) == session) }
    #expect(try JSONValue.encode(store.settings()) == JSONValue.encode(settings))
    let after = try FileManager.default.attributesOfItem(atPath: path)[.size] as! UInt64
    #expect(after < before / 10)
    print("真实旧库迁移：\(originals.count) 个会话逐条一致，\(before) → \(after) 字节")
}

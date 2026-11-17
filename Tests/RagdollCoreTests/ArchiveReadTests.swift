import Foundation
import Testing
@testable import RagdollCore

private func removeSnapshot(_ repo: URL, source: String, id: String) throws {
    let path = "sessions/\(source)/\(id)/events.json", manifestURL = repo.appendingPathComponent(".ragdoll-manifest.json")
    var manifest = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifestURL))
    manifest.removeValue(forKey: path)
    try FileManager.default.removeItem(at: repo.appendingPathComponent(path))
    try JSONEncoder().encode(manifest).write(to: manifestURL)
}

@Test func archiveSavesCompleteSnapshotEvenWhenSourceFilesExist() throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("repo"), source = root.appendingPathComponent("source.jsonl")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try git(repo, ["init"]); try git(repo, ["config", "user.name", "Read"]); try git(repo, ["config", "user.email", "read@localhost"])
    try Data("original source".utf8).write(to: source)
    let session = Session(id: "history", source: "codex", title: "History", messages: [Message(role: "user", text: "RESTORE_1729")], usage: [Usage(time: 1, model: "test", input: 17, output: 29)], files: [source.path])
    _ = try Archive.save([session], to: repo)
    let snapshot = repo.appendingPathComponent("sessions/codex/history/events.json")
    #expect(FileManager.default.fileExists(atPath: snapshot.path))
    if FileManager.default.fileExists(atPath: snapshot.path) {
        #expect(try JSONDecoder().decode(Session.self, from: Data(contentsOf: snapshot)) == session)
    }
}

@Test func archiveRestoresWithoutSourcesAndKeepsNewerLocalChanges() async throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("repo")
    try Archive.prepare(repo)
    try git(repo, ["config", "user.name", "Read"]); try git(repo, ["config", "user.email", "read@localhost"])
    let original = Session(id: "history", source: "codex", title: "History", updated: 10, messages: [Message(role: "user", text: "RESTORE_1729")], usage: [Usage(time: 1, model: "test", input: 17, output: 29)], files: [root.appendingPathComponent("missing.jsonl").path])
    _ = try Archive.save([original], to: repo)
    let store = try Store(path: root.appendingPathComponent("index.sqlite").path), bridge = RuntimeBridge()
    #expect(try await Archive.restore(from: repo, into: store, bridge: bridge) == 1)
    #expect(try store.session("history") == original)
    #expect(try store.list(query: "RESTORE_1729").first?.tokens == 46)
    var newer = original; newer.updated = 20; newer.messages.append(Message(role: "assistant", text: "UNARCHIVED"))
    try store.save(newer)
    #expect(try await Archive.restore(from: repo, into: store, bridge: bridge) == 1)
    #expect(try store.session("history") == newer)
    #expect(try Archive.save([original], to: repo).commit == nil)
    let snapshot = repo.appendingPathComponent("sessions/codex/history/events.json")
    try Data("broken".utf8).write(to: snapshot)
    await #expect(throws: (any Error).self) { try await Archive.restore(from: repo, into: store, bridge: bridge) }
    #expect(try store.session("history") == newer)
}

@Test func archiveRestoreRejectsMissingRepositoryAndUnsafeManifestPaths() async throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("repo"), store = try Store(path: root.appendingPathComponent("index.sqlite").path), bridge = RuntimeBridge()
    await #expect(throws: (any Error).self) { try await Archive.restore(from: repo, into: store, bridge: bridge) }
    #expect(!FileManager.default.fileExists(atPath: repo.path))
    #expect(throws: (any Error).self) { try Archive.prepare(repo, sourceRoots: [root.path]) }
    try Archive.prepare(repo)
    #expect(try await Archive.restore(from: repo, into: store, bridge: bridge) == 0)
    try Data("{}".utf8).write(to: root.appendingPathComponent("outside.json"))
    try JSONEncoder().encode(["../metadata.json": "digest"]).write(to: repo.appendingPathComponent(".ragdoll-manifest.json"))
    await #expect(throws: (any Error).self) { try await Archive.restore(from: repo, into: store, bridge: bridge) }
    #expect(try store.list().isEmpty)
}

@Test(arguments: [false, true]) func archiveRestoresLegacyRawLogsIncludingGzip(_ compressed: Bool) async throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("repo"), source = root.appendingPathComponent(compressed ? "source.jsonl.gz" : "source.jsonl")
    try Archive.prepare(repo)
    try git(repo, ["config", "user.name", "Legacy"]); try git(repo, ["config", "user.email", "legacy@localhost"])
    let raw = Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"legacy\"}}\n{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"LEGACY_RESTORE_1729\"}]}}\n".utf8)
    if compressed {
        let plain = root.appendingPathComponent("plain.jsonl"); try raw.write(to: plain)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip"); process.arguments = ["-n", "-c", plain.path]
        let output = Pipe(); process.standardOutput = output
        try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        #expect(process.terminationStatus == 0); try data.write(to: source)
    } else { try raw.write(to: source) }
    let session = Session(id: "legacy", source: "codex", title: "Saved title", home: "/original-home", messages: [Message(role: "user", text: "LEGACY_RESTORE_1729")], files: [source.path])
    _ = try Archive.save([session], to: repo)
    try removeSnapshot(repo, source: "codex", id: "legacy")
    try FileManager.default.removeItem(at: source)
    let store = try Store(path: root.appendingPathComponent("index.sqlite").path), bridge = RuntimeBridge()
    try await bridge.start(dataDirectory: root.appendingPathComponent("runtime"))
    do {
        #expect(try await Archive.restore(from: repo, into: store, bridge: bridge) == 1)
        let restored = try #require(try store.session("legacy"))
        #expect(restored.title == "Saved title")
        #expect(restored.home == "/original-home")
        #expect(restored.messages.map(\.text) == ["LEGACY_RESTORE_1729"])
        #expect(restored.messages.first?.role == "user")
    } catch { await bridge.close(); throw error }
    await bridge.close()
}

@Test func archiveRetainsCompleteLegacyTranscriptWithoutInventingMessageBoundaries() async throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("repo")
    try Archive.prepare(repo)
    try git(repo, ["config", "user.name", "Legacy"]); try git(repo, ["config", "user.email", "legacy@localhost"])
    let session = Session(id: "legacy", source: "acp", title: "Legacy", messages: [Message(role: "user", text: "## assistant · code example\n完整原文")])
    _ = try Archive.save([session], to: repo)
    try removeSnapshot(repo, source: "acp", id: "legacy")
    let transcript = try String(contentsOf: repo.appendingPathComponent("sessions/acp/legacy/transcript.md"), encoding: .utf8)
    let store = try Store(path: root.appendingPathComponent("index.sqlite").path), bridge = RuntimeBridge()
    #expect(try await Archive.restore(from: repo, into: store, bridge: bridge) == 1)
    #expect(try store.session("legacy")?.messages.first?.text == transcript)
    #expect(try store.session("legacy")?.warnings.count == 1)
}

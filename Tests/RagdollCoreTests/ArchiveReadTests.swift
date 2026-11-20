import Foundation
import CryptoKit
import Testing
@testable import RagdollCore

@Test func usageArchiveRestoresWithoutSourcesAndKeepsNewerLocalChanges() throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("repo")
    try Archive.prepare(repo)
    try git(repo, ["config", "user.name", "Read"]); try git(repo, ["config", "user.email", "read@localhost"])
    let original = Session(id: "history", source: "codex", title: "History", updated: 10, usage: [Usage(time: 1, model: "test", input: 17, output: 29)])
    _ = try Archive.save([original], to: repo)
    let store = try Store(path: root.appendingPathComponent("index.sqlite").path)
    #expect(try Archive.restore(from: repo, into: store) == 1)
    #expect(try store.session("history") == original)
    var newer = original; newer.updated = 20; newer.usage.append(Usage(time: 2, model: "test", input: 3, output: 4))
    try store.save(newer)
    #expect(try Archive.restore(from: repo, into: store) == 1)
    #expect(try store.session("history") == newer)
    #expect(try Archive.save([original], to: repo).commit == nil)
    try Data("broken".utf8).write(to: repo.appendingPathComponent("usage/codex/history.json"))
    #expect(throws: (any Error).self) { try Archive.restore(from: repo, into: store) }
    #expect(try store.session("history") == newer)
}

@Test func usageArchiveRestoreRejectsMissingRepositoryAndUnsafeManifestPaths() throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("repo"), store = try Store(path: root.appendingPathComponent("index.sqlite").path)
    #expect(throws: (any Error).self) { try Archive.restore(from: repo, into: store) }
    #expect(!FileManager.default.fileExists(atPath: repo.path))
    #expect(throws: (any Error).self) { try Archive.prepare(repo, sourceRoots: [root.path]) }
    try Archive.prepare(repo)
    #expect(try Archive.restore(from: repo, into: store) == 0)
    try JSONEncoder().encode(["../outside.json": "digest"]).write(to: repo.appendingPathComponent(".ragdoll-usage-manifest.json"))
    #expect(throws: (any Error).self) { try Archive.restore(from: repo, into: store) }
    #expect(try store.list().isEmpty)
}

@Test func legacyArchiveRestoresUsageFromMetadataWithoutOpeningBodiesOrMissingRawFiles() throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("repo")
    try Archive.prepare(repo)
    let base = "sessions/codex/legacy/", directory = repo.appendingPathComponent(base)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let original = Session(id: "legacy", source: "codex", title: "Saved title", usage: [Usage(time: 1, model: "model", input: 17, output: 29)])
    var record = try JSONValue.encode(original).dictionary
    record["messages"] = .array([])
    record["files"] = .array([.string("/missing/private.log")])
    let metadata = try JSONEncoder().encode(JSONValue.object(record))
    try metadata.write(to: directory.appendingPathComponent("metadata.json"))
    let digest = SHA256.hash(data: metadata).map { String(format: "%02x", $0) }.joined()
    let manifest = [base + "metadata.json": digest, base + "events.json": "missing", base + "raw/private.jsonl": "missing"]
    try JSONEncoder().encode(manifest).write(to: repo.appendingPathComponent(".ragdoll-manifest.json"))
    let store = try Store(path: root.appendingPathComponent("index.sqlite").path)
    #expect(try Archive.restore(from: repo, into: store) == 1)
    #expect(try store.session("legacy") == original)
    #expect(try JSONValue.encode(store.session("legacy"))["files"] == .null)
}

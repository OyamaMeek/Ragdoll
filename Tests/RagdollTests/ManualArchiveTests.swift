import Foundation
import Testing
import RagdollCore
@testable import Ragdoll

@discardableResult private func archiveGit(_ root: URL, _ arguments: [String]) throws -> String {
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root.path] + arguments
    let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NSError(domain: String(decoding: data, as: UTF8.self), code: Int(process.terminationStatus)) }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

@Test @MainActor func foregroundAutomaticArchiveNeverPublishesPendingChanges() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".agent/tests/\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("repo"), remote = root.appendingPathComponent("remote.git")
    try Archive.prepare(repo)
    try archiveGit(repo, ["config", "user.name", "Manual"]); try archiveGit(repo, ["config", "user.email", "manual@localhost"])
    var session = Session(id: "manual", source: "codex", title: "Original", updated: 1)
    _ = try Archive.save([session], to: repo, commit: true)
    let head = try archiveGit(repo, ["rev-parse", "HEAD"])
    try archiveGit(root, ["init", "--bare", remote.path]); try archiveGit(repo, ["remote", "add", "origin", remote.path])
    _ = try ArchiveSync.push(root: repo, remote: "origin", branch: "archive")
    let store = try Store(path: root.appendingPathComponent("index.sqlite").path)
    session.title = "Latest"; session.updated = 2; try store.save(session)
    var settings = Settings(); settings.archivePath = repo.path
    settings.locations = [Location(source: "codex", path: root.appendingPathComponent("empty-source").path)]
    settings.archiveRemote = ArchiveRemote(remote: "origin", branch: "archive"); try store.saveSettings(settings)
    try Data("pending".utf8).write(to: root.appendingPathComponent("sync-pending"))
    let model = AppModel(root: root)
    await model.launch()
    await model.archiveNow()
    #expect(model.error == nil)
    #expect(try String(contentsOf: repo.appendingPathComponent("usage/codex/manual.json"), encoding: .utf8).contains("Latest"))
    #expect(try archiveGit(repo, ["rev-parse", "HEAD"]) == head)
    #expect(try archiveGit(repo, ["diff", "--cached", "--name-only"]).isEmpty)
    #expect(try archiveGit(remote, ["rev-parse", "refs/heads/archive"]) == head)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("sync-pending").path))
    await model.archiveNow(commitAndPush: true)
    let published = try archiveGit(repo, ["rev-parse", "HEAD"])
    #expect(published != head)
    #expect(try archiveGit(repo, ["rev-list", "--count", "HEAD"]) == "2")
    #expect(try archiveGit(remote, ["rev-parse", "refs/heads/archive"]) == published)
    #expect(try archiveGit(remote, ["show", "refs/heads/archive:usage/codex/manual.json"]).contains("Latest"))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("sync-pending").path))
    await model.archiveNow(commitAndPush: true)
    #expect(try archiveGit(repo, ["rev-parse", "HEAD"]) == published)
    try archiveGit(repo, ["remote", "set-url", "origin", root.appendingPathComponent("missing.git").path])
    session.title = "Not yet pushed"; session.updated = 3; try store.save(session)
    await model.archiveNow(commitAndPush: true)
    let failedHead = try archiveGit(repo, ["rev-parse", "HEAD"])
    #expect(failedHead != published)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("sync-pending").path))
    try archiveGit(repo, ["remote", "set-url", "origin", remote.path])
    model.configureArchiveRemote(settings.archiveRemote)
    await model.archiveNow()
    #expect(try archiveGit(remote, ["rev-parse", "refs/heads/archive"]) == published)
    await model.archiveNow(commitAndPush: true)
    #expect(try archiveGit(repo, ["rev-parse", "HEAD"]) == failedHead)
    #expect(try archiveGit(remote, ["rev-parse", "refs/heads/archive"]) == failedHead)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("sync-pending").path))
    await model.bridge.close()
}

@Test @MainActor func foregroundManualArchiveCommitsWithoutARemoteAndDelegatesToBackground() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".agent/tests/\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("repo")
    try Archive.prepare(repo)
    try archiveGit(repo, ["config", "user.name", "Manual"]); try archiveGit(repo, ["config", "user.email", "manual@localhost"])
    let store = try Store(path: root.appendingPathComponent("index.sqlite").path)
    try store.save(Session(id: "first", source: "codex", title: "First"))
    var settings = Settings(); settings.archivePath = repo.path
    settings.locations = [Location(source: "codex", path: root.appendingPathComponent("empty-source").path)]
    try store.saveSettings(settings)
    let model = AppModel(root: root)
    await model.launch(); await model.archiveNow()
    #expect(throws: (any Error).self) { try archiveGit(repo, ["rev-parse", "--verify", "HEAD"]) }
    await model.archiveNow(commitAndPush: true)
    #expect(try archiveGit(repo, ["rev-list", "--count", "HEAD"]) == "1")
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("sync-pending").path))
    let lease = try ServiceLease(root: root)
    await model.archiveNow(commitAndPush: true)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("service-publish-request.json").path))
    withExtendedLifetime(lease) {}
    await model.bridge.close()
}

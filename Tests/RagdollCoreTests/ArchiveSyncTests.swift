import Foundation
import Testing
@testable import RagdollCore

@Test func archiveSyncRefusesMultiplePushDestinationsBeforeUploading() throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let local = root.appendingPathComponent("local"), first = root.appendingPathComponent("first.git"), second = root.appendingPathComponent("second.git")
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    try git(root, ["init", "--bare", first.path]); try git(root, ["init", "--bare", second.path]); try git(local, ["init"])
    try git(local, ["config", "user.name", "Scope"]); try git(local, ["config", "user.email", "scope@localhost"])
    _ = try Archive.save([Session(id: "one", source: "codex", title: "One")], to: local, commit: true)
    try git(local, ["remote", "add", "origin", first.path])
    try git(local, ["config", "--add", "remote.origin.pushurl", first.path]); try git(local, ["config", "--add", "remote.origin.pushurl", second.path])
    #expect(throws: (any Error).self) { try ArchiveSync.preview(root: local, remote: "origin", branch: "archive") }
    #expect(throws: (any Error).self) { try ArchiveSync.push(root: local, remote: "origin", branch: "archive") }
    #expect(throws: (any Error).self) { try git(first, ["rev-parse", "refs/heads/archive"]) }
    #expect(throws: (any Error).self) { try git(second, ["rev-parse", "refs/heads/archive"]) }
}

@Test func archiveSyncPreviewShowsTheDestinationWithoutCredentials() throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    try git(root, ["init"]); try git(root, ["config", "user.name", "Preview"]); try git(root, ["config", "user.email", "preview@localhost"])
    _ = try Archive.save([Session(id: "preview", source: "codex", title: "Preview")], to: root)
    try git(root, ["remote", "add", "origin", "https://username:secret-value@example.com/archive.git?token=private"])
    let preview = try ArchiveSync.preview(root: root, remote: "origin", branch: "archive")
    #expect(preview.contains("example.com/archive.git"))
    #expect(!preview.contains("secret-value")); #expect(!preview.contains("private")); #expect(!preview.contains("username"))
}

@Test func archiveSyncStopsAHangingPushAndPreservesItsLocalCommit() throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let local = root.appendingPathComponent("local"), remote = root.appendingPathComponent("remote.git")
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    try git(root, ["init", "--bare", remote.path]); try git(local, ["init"])
    try git(local, ["config", "user.name", "Timeout"]); try git(local, ["config", "user.email", "timeout@localhost"])
    _ = try Archive.save([Session(id: "one", source: "codex", title: "One")], to: local, commit: true)
    try git(local, ["remote", "add", "origin", remote.path])
    let hook = local.appendingPathComponent(".git/hooks/pre-push")
    try Data("#!/bin/sh\nsleep 10\n".utf8).write(to: hook)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    let before = try git(local, ["rev-parse", "HEAD"]), start = Date()
    #expect(throws: (any Error).self) { try ArchiveSync.push(root: local, remote: "origin", branch: "archive", timeout: 0.2) }
    #expect(Date().timeIntervalSince(start) < 3)
    #expect(try git(local, ["rev-parse", "HEAD"]) == before)
}

@Test func archiveSyncRetriesWithoutANewCommitAndRejectsDivergence() throws {
    let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let local = directory.appendingPathComponent("local"), remote = directory.appendingPathComponent("remote.git")
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    try git(local, ["init"]); try git(local, ["config", "user.name", "Test"]); try git(local, ["config", "user.email", "test@localhost"])
    let session = Session(id: "one", source: "codex", title: "One")
    _ = try Archive.save([session], to: local, commit: true)
    let head = try git(local, ["rev-parse", "HEAD"])
    try git(local, ["remote", "add", "origin", remote.path])
    #expect(throws: (any Error).self) { try ArchiveSync.push(root: local, remote: "origin", branch: "archive") }
    #expect(try git(local, ["rev-parse", "HEAD"]) == head)
    try git(directory, ["init", "--bare", remote.path])
    _ = try ArchiveSync.push(root: local, remote: "origin", branch: "archive")
    #expect(try git(remote, ["rev-parse", "refs/heads/archive"]) == head)
    #expect(try Archive.save([session], to: local).commit == nil)
    _ = try ArchiveSync.push(root: local, remote: "origin", branch: "archive")
    let other = directory.appendingPathComponent("other")
    try git(directory, ["clone", "--branch", "archive", remote.path, other.path])
    try git(other, ["config", "user.name", "Other"]); try git(other, ["config", "user.email", "other@localhost"])
    try Data("remote work".utf8).write(to: other.appendingPathComponent("remote.txt"))
    try git(other, ["add", "remote.txt"]); try git(other, ["commit", "-m", "remote work"]); try git(other, ["push"])
    #expect(throws: (any Error).self) { try ArchiveSync.push(root: local, remote: "origin", branch: "archive") }
    #expect(try git(local, ["rev-parse", "HEAD"]) == head)
    #expect(throws: (any Error).self) { try ArchiveSync.push(root: local, remote: "--all", branch: "archive") }
}

@Test func archiveSyncSettingsDecodeOlderRecords() throws {
    let old = try JSONEncoder().encode(Settings())
    var data = try JSONSerialization.jsonObject(with: old) as! [String: Any]
    data.removeValue(forKey: "archiveRemote"); data.removeValue(forKey: "backgroundEnabled")
    let settings = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: data))
    #expect(settings.archiveRemote == nil)
}

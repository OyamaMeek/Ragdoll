import Foundation
import Testing
import Darwin
@testable import RagdollCore

@Test(arguments: ["missing", "history", "corrupt"]) func backgroundServiceRequiresAndLoadsRepositoryBeforeScanning(_ kind: String) async throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try Store(path: root.appendingPathComponent("index.sqlite").path), archive = root.appendingPathComponent("archive")
    let source = root.appendingPathComponent("source/sessions")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"local-new\"}}\n".utf8).write(to: source.appendingPathComponent("new.jsonl"))
    var settings = Settings(); settings.locations = [Location(source: "codex", path: source.deletingLastPathComponent().path)]
    if kind != "missing" {
        try Archive.prepare(archive)
        try git(archive, ["config", "user.name", "First"]); try git(archive, ["config", "user.email", "first@localhost"])
        _ = try Archive.save([Session(id: "archived-only", source: "codex", title: "ARCHIVED_ONLY_1729", usage: [Usage(time: 1, model: "model", input: 17, output: 29)])], to: archive)
        settings.archivePath = archive.path
        if kind == "corrupt" { try Data("broken".utf8).write(to: archive.appendingPathComponent(".ragdoll-usage-manifest.json")) }
    }
    try store.saveSettings(settings)
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let process = Process(); process.executableURL = project.appendingPathComponent(".build/debug/RagdollService"); process.arguments = ["--data-dir", root.path, "--once"]
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try process.run(); defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
    let deadline = Date().addingTimeInterval(20)
    while process.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    #expect(!process.isRunning)
    if !process.isRunning { #expect(process.terminationStatus == (kind == "corrupt" ? 1 : 0)) }
    if kind == "history" {
        #expect(try store.list(query: "ARCHIVED_ONLY_1729").count == 1)
        #expect(try store.list().count == 2)
        let restored = try Store(path: root.appendingPathComponent("restored.sqlite").path)
        #expect(try Archive.restore(from: archive, into: restored) == 2)
    } else { #expect(try store.list().isEmpty) }
    if kind == "corrupt" { #expect(try String(contentsOf: archive.appendingPathComponent(".ragdoll-usage-manifest.json"), encoding: .utf8) == "broken") }
}

@Test func backgroundServiceReportsAnInvalidLockInsteadOfClaimingItIsRunning() throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let other = root.appendingPathComponent("other")
    try Data("unrelated file".utf8).write(to: other)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("service-lock"), withDestinationURL: other)
    #expect(throws: (any Error).self) { try BackgroundService.isRunning(root: root) }
}

@Test func backgroundServiceOwnsOneDataDirectoryAndPreservesNewRequests() throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    var first: ServiceLease? = try ServiceLease(root: root)
    #expect(try BackgroundService.isRunning(root: root))
    #expect(throws: (any Error).self) { try ServiceLease(root: root) }
    try BackgroundService.request(root: root)
    let old = try Data(contentsOf: root.appendingPathComponent("service-request"))
    try BackgroundService.request(root: root)
    #expect(try Data(contentsOf: root.appendingPathComponent("service-request")) != old)
    first = nil
    #expect(try !BackgroundService.isRunning(root: root))
    let second = try ServiceLease(root: root)
    let occupied = try BackgroundService.isRunning(root: root)
    withExtendedLifetime(second) { #expect(occupied) }
    _ = first
}

@Test func backgroundServiceArchivesFromItsOwnProcess() async throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source/sessions"), archive = root.appendingPathComponent("archive")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    try git(archive, ["init"]); try git(archive, ["config", "user.name", "Background"]); try git(archive, ["config", "user.email", "background@localhost"])
    let raw = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"background-check\"}}\n{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"SERVICE_NATIVE_1729\"}]}}\n"
    try Data(raw.utf8).write(to: source.appendingPathComponent("session.jsonl"))
    let store = try Store(path: root.appendingPathComponent("index.sqlite").path)
    let remote = root.appendingPathComponent("remote.git")
    try git(archive, ["remote", "add", "origin", remote.path])
    var settings = Settings(); settings.locations = [Location(source: "codex", path: source.deletingLastPathComponent().path)]; settings.archivePath = archive.path; settings.archiveRemote = ArchiveRemote(remote: "origin", branch: "archive")
    try store.saveSettings(settings)
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let executable = project.appendingPathComponent(".build/debug/RagdollService")
    let process = Process(); process.executableURL = executable; process.arguments = ["--data-dir", root.path, "--once"]
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try process.run()
    let deadline = Date().addingTimeInterval(20)
    while process.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    if process.isRunning { process.terminate(); Issue.record("独立服务未在期限内完成"); return }
    #expect(process.terminationStatus == 0)
    #expect(try store.list(query: "SERVICE_NATIVE_1729").count == 1)
    let restoredStore = try Store(path: root.appendingPathComponent("restored.sqlite").path)
    #expect(try Archive.restore(from: archive, into: restoredStore) == 1)
    #expect(try restoredStore.list(query: "SERVICE_NATIVE_1729").count == 1)
    #expect(try git(archive, ["log", "-1", "--format=%s"]) == "chore(archive): sync session usage")
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("sync-pending").path))
    let head = try git(archive, ["rev-parse", "HEAD"])
    let transcript = archive.appendingPathComponent("README.md")
    try Data("hand edited".utf8).write(to: transcript)
    try git(root, ["init", "--bare", remote.path])
    let retry = Process(); retry.executableURL = executable; retry.arguments = ["--data-dir", root.path, "--once"]
    retry.standardOutput = FileHandle.nullDevice; retry.standardError = FileHandle.nullDevice
    try retry.run()
    let retryDeadline = Date().addingTimeInterval(20)
    while retry.isRunning && Date() < retryDeadline { try await Task.sleep(for: .milliseconds(50)) }
    if retry.isRunning { retry.terminate(); Issue.record("服务重启未完成"); return }
    #expect(retry.terminationStatus == 1)
    #expect(try git(archive, ["rev-parse", "HEAD"]) == head)
    #expect(try git(remote, ["rev-parse", "refs/heads/archive"]) == head)
    #expect(try git(remote, ["show", "refs/heads/archive:README.md"]).contains("Ragdoll 活动概览"))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("sync-pending").path))
    #expect(try String(contentsOf: transcript, encoding: .utf8) == "hand edited")
}

@Test(arguments: ["runtime", "index"]) func backgroundServiceExitsOnFatalDependencyFailure(_ kind: String) async throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try Store(path: root.appendingPathComponent("index.sqlite").path)
    let source = root.appendingPathComponent("source/sessions")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let archive = root.appendingPathComponent("archive")
    try Archive.prepare(archive)
    var settings = Settings(); settings.backgroundEnabled = true; settings.archivePath = archive.path; settings.locations = [Location(source: "codex", path: source.deletingLastPathComponent().path)]; try store.saveSettings(settings)
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let process = Process(); process.executableURL = project.appendingPathComponent(".build/debug/RagdollService"); process.arguments = ["--data-dir", root.path]
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try process.run(); defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
    let deadline = Date().addingTimeInterval(10)
    while try BackgroundService.status(root: root) == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    if kind == "runtime" {
        let children = Process(); children.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); children.arguments = ["-P", String(process.processIdentifier)]
        let output = Pipe(); children.standardOutput = output
        try children.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); children.waitUntilExit()
        let pid = try #require(Int32(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        kill(pid, SIGKILL)
    } else {
        let sqlite = Process(); sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3"); sqlite.arguments = [root.appendingPathComponent("index.sqlite").path, "DROP TABLE sessions"]
        try sqlite.run(); sqlite.waitUntilExit(); #expect(sqlite.terminationStatus == 0)
        try Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"index-failure\"}}\n".utf8).write(to: source.appendingPathComponent("one.jsonl"))
        try BackgroundService.request(root: root)
    }
    while process.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    #expect(!process.isRunning)
    if !process.isRunning { #expect(process.terminationStatus != 0); #expect(try !BackgroundService.isRunning(root: root)) }
}

@Test func backgroundServiceContinuesAfterItsLauncherReturns() async throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source/sessions"), archive = root.appendingPathComponent("archive")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    try git(archive, ["init"]); try git(archive, ["config", "user.name", "Service"]); try git(archive, ["config", "user.email", "service@localhost"])
    let store = try Store(path: root.appendingPathComponent("index.sqlite").path)
    var settings = Settings(); settings.locations = [Location(source: "codex", path: source.deletingLastPathComponent().path)]; settings.archivePath = archive.path; settings.backgroundEnabled = true
    try store.saveSettings(settings); try BackgroundService.request(root: root)
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let process = Process(); process.executableURL = project.appendingPathComponent(".build/debug/RagdollService"); process.arguments = ["--data-dir", root.path]
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try process.run(); defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    let deadline = Date().addingTimeInterval(20)
    while (try BackgroundService.status(root: root)?.lastArchive) == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    #expect(try BackgroundService.isRunning(root: root))
    let raw = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"late\"}}\n{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"AFTER_LAUNCH_1729\"}]}}\n"
    try Data(raw.utf8).write(to: source.appendingPathComponent("late.jsonl")); try BackgroundService.request(root: root)
    while try store.list(query: "AFTER_LAUNCH_1729").isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    #expect(try store.list(query: "AFTER_LAUNCH_1729").count == 1)
    let newRecord = archive.appendingPathComponent("usage/codex")
    while !FileManager.default.fileExists(atPath: newRecord.path) && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    #expect(FileManager.default.fileExists(atPath: newRecord.path))
    #expect(process.isRunning)
    settings.backgroundEnabled = false; try store.saveSettings(settings)
    let stopDeadline = Date().addingTimeInterval(10)
    while process.isRunning && Date() < stopDeadline { try await Task.sleep(for: .milliseconds(50)) }
    #expect(!process.isRunning)
    if !process.isRunning { #expect(process.terminationStatus == 0) }
}

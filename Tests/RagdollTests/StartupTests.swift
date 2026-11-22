import Foundation
import Testing
import RagdollCore
@testable import Ragdoll

@Test @MainActor func codexWarmupUsesRuntimeAndReleasesBusyStateAfterFailure() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".agent/tests/\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(root: root)
    let home = root.appendingPathComponent("missing-codex").path
    model.settings.locations = [Location(source: "codex", path: home)]
    await model.warmupCodex(home)
    #expect(model.codexWarmupResults.isEmpty)
    try await model.bridge.start(dataDirectory: root)
    model.ready = true
    await model.warmupCodex(home)
    #expect(model.warmingCodexHome == nil)
    #expect(model.codexWarmupResults[home]?.contains("登录") == true)
    #expect(!FileManager.default.fileExists(atPath: home))
    #expect(model.sessions.isEmpty)
    await model.bridge.close()
}

@Test @MainActor func configuredRepositoryShowsCachedInterfaceDuringLoadingAndAfterFailure() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".agent/tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try Store(path: root.appendingPathComponent("index.sqlite").path)
    var settings = Settings(); settings.archivePath = root.appendingPathComponent("missing-repo").path
    try store.saveSettings(settings)
    let cached = Session(id: "cached", source: "codex", title: "Cached history")
    try store.save(cached)
    let model = AppModel(root: root)
    #expect(!model.needsArchiveSetup)
    #expect(model.sessions.map(\.id) == ["cached"])
    model.loadingArchive = true
    #expect(!model.needsArchiveSetup)
    model.loadingArchive = false
    await model.launch()
    #expect(!model.needsArchiveSetup)
    #expect(model.sessions.map(\.id) == ["cached"])
    #expect(!model.ready)
    #expect(!model.archiveLoaded)
    #expect(model.error != nil)
    await model.refresh(); await model.archiveNow()
    #expect(!FileManager.default.fileExists(atPath: settings.archivePath))
    await model.bridge.close()
}

@Test @MainActor func firstLaunchRequiresRepositoryBeforeScanningOrImporting() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".agent/tests/\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(root: root)
    await model.launch()
    #expect(model.needsArchiveSetup)
    #expect(!model.ready)
    #expect(!model.scanning)
    #expect(model.settings.locations.isEmpty)
    #expect(model.sessions.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("conversations").path))
    await model.refresh()
    #expect(!model.scanning)
    await model.bridge.close()
}

@Test @MainActor func startupRestoresRepositoryBeforeScanningAndFailsClosed() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".agent/tests/\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("repo")
    try Archive.prepare(repo)
    let config = Process(); config.executableURL = URL(fileURLWithPath: "/usr/bin/git"); config.arguments = ["-C", repo.path, "config", "user.name", "Startup"]
    try config.run(); config.waitUntilExit()
    let email = Process(); email.executableURL = URL(fileURLWithPath: "/usr/bin/git"); email.arguments = ["-C", repo.path, "config", "user.email", "startup@localhost"]; try email.run(); email.waitUntilExit()
    let archived = Session(id: "only-in-git", source: "codex", title: "Git history", usage: [Usage(time: 1, model: "model", input: 17, output: 29)])
    _ = try Archive.save([archived], to: repo)
    let model = AppModel(root: root)
    model.settings.locations = [Location(source: "codex", path: root.appendingPathComponent("empty-source").path)]
    model.persistSettings()
    await model.launch()
    #expect(model.needsArchiveSetup)
    await model.configureArchive(repo)
    #expect(model.ready)
    #expect(!model.needsArchiveSetup)
    #expect(model.sessions.map(\.id) == ["only-in-git"])
    model.select("only-in-git")
    #expect(model.selectedID == archived.id)
    #expect(model.sessions.first?.tokens == 46)
    await model.archiveNow()
    #expect(!model.archiving)
    await model.bridge.close()
    try Data("broken".utf8).write(to: repo.appendingPathComponent(".ragdoll-usage-manifest.json"))
    let failed = AppModel(root: root)
    await failed.launch()
    #expect(!failed.ready)
    #expect(!failed.needsArchiveSetup)
    #expect(failed.error != nil)
    await failed.refresh(); await failed.archiveNow()
    #expect(try String(contentsOf: repo.appendingPathComponent(".ragdoll-usage-manifest.json"), encoding: .utf8) == "broken")
    await failed.bridge.close()
}

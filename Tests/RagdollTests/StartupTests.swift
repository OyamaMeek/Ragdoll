import Foundation
import Testing
import RagdollCore
@testable import Ragdoll

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
    let archived = Session(id: "only-in-git", source: "codex", title: "Git history", messages: [Message(role: "user", text: "GIT_FIRST_1729")])
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
    #expect(model.selected?.messages == archived.messages)
    await model.archiveNow()
    #expect(!model.archiving)
    await model.bridge.close()
    try Data("broken".utf8).write(to: repo.appendingPathComponent(".ragdoll-manifest.json"))
    let failed = AppModel(root: root)
    await failed.launch()
    #expect(!failed.ready)
    #expect(failed.needsArchiveSetup)
    #expect(failed.error != nil)
    await failed.refresh(); await failed.archiveNow()
    #expect(try String(contentsOf: repo.appendingPathComponent(".ragdoll-manifest.json"), encoding: .utf8) == "broken")
    await failed.bridge.close()
}

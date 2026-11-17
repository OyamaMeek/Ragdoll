import Foundation
import Testing
@testable import RagdollCore

@Test func archiveExtractsInlineImagesAndReusesRelativeFiles() throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    try git(root, ["init"]); try git(root, ["config", "user.name", "Images"]); try git(root, ["config", "user.email", "images@localhost"])
    let encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="
    let image = try #require(Data(base64Encoded: encoded))
    let url = "data:image/png;base64,\(encoded)"
    let session = Session(id: "images", source: "codex", title: "Images", messages: [
        Message(role: "user", text: "Before ![one](\(url)) after"),
        Message(role: "tool", text: "{\"image_url\":\"\(url)\",\"text\":\"keep this\"}")
    ])
    _ = try Archive.save([session], to: root)
    let base = root.appendingPathComponent("sessions/codex/images")
    let images = try FileManager.default.contentsOfDirectory(at: base.appendingPathComponent("images"), includingPropertiesForKeys: nil)
    let saved = try #require(images.first)
    #expect(images.count == 1)
    #expect(saved.pathExtension == "png")
    #expect(try Data(contentsOf: saved) == image)
    let transcript = try String(contentsOf: base.appendingPathComponent("transcript.md"), encoding: .utf8)
    #expect(!transcript.contains("base64,"))
    #expect(transcript.contains("Before ![one](images/\(saved.lastPathComponent)) after"))
    #expect(transcript.contains("keep this"))
    let events = try JSONDecoder().decode(Session.self, from: Data(contentsOf: base.appendingPathComponent("events.json")))
    #expect(!events.messages[1].text.contains("base64,"))
    #expect(events.messages[1].text.contains("images/\(saved.lastPathComponent)"))
    #expect(session.messages[0].text.contains(url))
    #expect(try Archive.save([session], to: root).commit == nil)
    try Data("manual image edit".utf8).write(to: saved)
    #expect(throws: (any Error).self) { try Archive.save([session], to: root) }
    #expect(try String(contentsOf: saved, encoding: .utf8) == "manual image edit")
}

@Test func archivePreservesMalformedImageExamplesAsOriginalText() throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    try git(root, ["init"]); try git(root, ["config", "user.name", "Invalid"]); try git(root, ["config", "user.email", "invalid@localhost"])
    let session = Session(id: "invalid", source: "codex", title: "Invalid", messages: [Message(role: "user", text: "![image](data:image/png;base64,%%%)")])
    _ = try Archive.save([session], to: root)
    let transcript = try String(contentsOf: root.appendingPathComponent("sessions/codex/invalid/transcript.md"), encoding: .utf8)
    #expect(transcript.contains(session.messages[0].text))
    #expect(try Archive.save([session], to: root).commit == nil)
}

@Test func archiveCompressesLargeRawFilesLosslesslyAndReplacesOnlyManagedCopies() throws {
    let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appendingPathComponent("archive"), source = directory.appendingPathComponent("source.log")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try git(root, ["init"]); try git(root, ["config", "user.name", "Raw"]); try git(root, ["config", "user.email", "raw@localhost"])
    try Data("original".utf8).write(to: source)
    let session = Session(id: "large", source: "codex", title: "Large", messages: [Message(role: "user", text: "See \(source.absoluteString)")], files: [source.path])
    _ = try Archive.save([session], to: root)
    let original = Data(repeating: 0x61, count: 50 * 1024 * 1024 + 1)
    try original.write(to: source)
    let base = root.appendingPathComponent("sessions/codex/large")
    let raw = base.appendingPathComponent("raw/0-source.log")
    try Data("hand edited raw".utf8).write(to: raw)
    #expect(throws: (any Error).self) { try Archive.save([session], to: root) }
    #expect(try String(contentsOf: raw, encoding: .utf8) == "hand edited raw")
    try Data("original".utf8).write(to: raw)
    _ = try Archive.save([session], to: root)
    let compressed = base.appendingPathComponent("raw/0-source.log.gz")
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip"); process.arguments = ["-d", "-c", compressed.path]
    let output = Pipe(); process.standardOutput = output
    try process.run(); let restored = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    try #require(process.terminationStatus == 0)
    #expect(restored.elementsEqual(original))
    #expect(try Data(contentsOf: source).elementsEqual(original))
    #expect(!FileManager.default.fileExists(atPath: raw.path))
    let transcript = try String(contentsOf: base.appendingPathComponent("transcript.md"), encoding: .utf8)
    #expect(transcript.contains("raw/0-source.log.gz"))
    let manifest = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appendingPathComponent(".ragdoll-manifest.json")))
    #expect(manifest["sessions/codex/large/raw/0-source.log"] == nil)
    #expect(manifest["sessions/codex/large/raw/0-source.log.gz"] != nil)
    #expect(try Archive.save([session], to: root).commit == nil)
    #expect(try !git(root, ["ls-tree", "-r", "--name-only", "HEAD"]).split(separator: "\n").contains("sessions/codex/large/raw/0-source.log"))
}

import Foundation
import CryptoKit

public struct ArchiveResult: Sendable { public var files: Int; public var commit: String? }
public enum Archive {
    public static func save(_ sessions: [Session], to root: URL, sourceRoots: [String] = []) throws -> ArchiveResult {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        for path in sourceRoots where !path.isEmpty {
            let source = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            guard root.path != source && !root.path.hasPrefix(source + "/") else { throw failure("归档目录不能放在源日志目录中") }
        }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let lease = try ServiceLease(root: root, name: ".ragdoll-archive-lock")
        defer { withExtendedLifetime(lease) {} }
        if !fm.fileExists(atPath: root.appendingPathComponent(".git").path) { _ = try git(root, ["init"]) }
        guard try git(root, ["rev-parse", "--show-toplevel"]) == root.path else { throw failure("请选择 Git 仓库的根目录") }
        let manifestURL = root.appendingPathComponent(".ragdoll-manifest.json")
        guard manifestURL.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw failure("归档清单不能指向仓库外部") }
        let old = fm.fileExists(atPath: manifestURL.path) ? try JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifestURL)) : [:]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var desired: [String: Data] = [:]
        for session in sessions {
            let base = "sessions/\(safeName(session.source))/\(safeName(session.id))"
            var metadata = session; metadata.messages = []
            desired[base + "/metadata.json"] = try encoder.encode(metadata)
            let transcript = "# \(session.title)\n\n来源：\(session.source)\n\n项目：\(session.project)\n\n" + session.messages.map { "## \($0.role) · \(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0.time / 1000)))\n\n\($0.text)\n" }.joined(separator: "\n")
            let portable = session.files.enumerated().reduce(transcript) { text, entry in
                text.replacingOccurrences(of: URL(fileURLWithPath: entry.element).absoluteString, with: "raw/\(entry.offset)-\(safeName(URL(fileURLWithPath: entry.element).lastPathComponent))")
            }
            desired[base + "/transcript.md"] = Data(portable.utf8)
            for (index, path) in session.files.enumerated() {
                let file = URL(fileURLWithPath: path)
                guard fm.fileExists(atPath: file.path) else { continue }
                let values = try file.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { throw failure("无法归档非普通文件：\(path)") }
                desired[base + "/raw/\(index)-\(safeName(file.lastPathComponent))"] = try Data(contentsOf: file)
            }
            if session.files.isEmpty { desired[base + "/events.json"] = try encoder.encode(session) }
        }
        for (path, _) in desired {
            let destination = root.appendingPathComponent(path)
            guard !destination.resolvingSymlinksInPath().path.hasPrefix(root.path + "/.git/") && destination.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw failure("归档路径越界") }
            if fm.fileExists(atPath: destination.path) {
                let digest = hash(try Data(contentsOf: destination))
                guard old[path] == digest else { throw failure("归档文件已被手动修改或不属于应用：\(path)。请保留修改后选择其他归档目录，或恢复文件后重试。") }
            } else if old[path] != nil { throw failure("归档文件已被手动删除：\(path)。请处理该删除后重试。") }
        }
        let managed = Array(desired.keys) + [".ragdoll-manifest.json"]
        let managedSet = Set(managed)
        let staged = try gitData(root, ["diff", "--cached", "--name-only", "-z"]).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        for path in staged where managedSet.contains(path) {
            let data = try gitData(root, ["show", ":\(path)"])
            let expected = path == ".ragdoll-manifest.json" ? (fm.fileExists(atPath: manifestURL.path) ? hash(try Data(contentsOf: manifestURL)) : nil) : old[path]
            guard expected == hash(data) else { throw failure("归档文件存在外部暂存修改，已保留：\(path)。请先处理该暂存修改后重试。") }
        }
        var manifest = old
        var changed: [String] = []
        for (path, data) in desired {
            let digest = hash(data), destination = root.appendingPathComponent(path)
            if old[path] == digest && fm.fileExists(atPath: destination.path) { continue }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            manifest[path] = digest; changed.append(path)
        }
        let manifestData = try encoder.encode(manifest)
        let previousManifest = fm.fileExists(atPath: manifestURL.path) ? try Data(contentsOf: manifestURL) : nil
        if previousManifest != manifestData {
            try manifestData.write(to: manifestURL, options: .atomic); changed.append(".ragdoll-manifest.json")
        }
        let gitDirectory = try git(root, ["rev-parse", "--absolute-git-dir"])
        let pathspec = URL(fileURLWithPath: gitDirectory).appendingPathComponent("ragdoll-pathspec-\(UUID().uuidString)")
        try Data((managed.joined(separator: "\0") + "\0").utf8).write(to: pathspec)
        defer { try? fm.removeItem(at: pathspec) }
        _ = try git(root, ["add", "--pathspec-from-file=\(pathspec.path)", "--pathspec-file-nul"])
        let pending = try gitData(root, ["diff", "--cached", "--name-only", "-z"]).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        guard pending.contains(where: { managedSet.contains($0) }) else { return ArchiveResult(files: 0, commit: nil) }
        _ = try git(root, ["commit", "--only", "-m", "chore(archive): sync conversations", "--pathspec-from-file=\(pathspec.path)", "--pathspec-file-nul"])
        return ArchiveResult(files: changed.count, commit: try git(root, ["rev-parse", "--short", "HEAD"]))
    }

    private static func safeName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let name = value.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
        return name.isEmpty || name == "." || name == ".." ? "session" : name
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func failure(_ message: String) -> NSError { NSError(domain: "Ragdoll.Archive", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private static func git(_ root: URL, _ args: [String]) throws -> String {
        String(decoding: try gitData(root, args), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func gitData(_ root: URL, _ args: [String]) throws -> Data {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = ["-C", root.path] + args
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        process.environment = ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0"]) { _, new in new }
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else { throw failure("文件已保留；Git 操作失败：\(text)") }
        return data
    }
}

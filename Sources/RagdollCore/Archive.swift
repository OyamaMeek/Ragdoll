import Foundation
import CryptoKit

public struct ArchiveResult: Sendable { public var files: Int; public var commit: String? }
public enum Archive {
    public static func prepare(_ root: URL, sourceRoots: [String] = []) throws {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        for path in sourceRoots where !path.isEmpty {
            let source = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            guard root.path != source && !root.path.hasPrefix(source + "/") else { throw failure("归档目录不能放在源日志目录中") }
        }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: root.appendingPathComponent(".git").path) {
            _ = try git(root, ["init"])
        }
        guard try git(root, ["rev-parse", "--show-toplevel"]) == root.path else { throw failure("请选择 Git 仓库的根目录") }
    }

    public static func restore(from root: URL, into store: Store) throws -> Int {
        let root = root.standardizedFileURL.resolvingSymlinksInPath(), fm = FileManager.default
        guard fm.fileExists(atPath: root.appendingPathComponent(".git").path),
              try git(root, ["rev-parse", "--show-toplevel"]) == root.path else { throw failure("归档仓库不存在或路径无效，请重新选择 Git 仓库") }
        let lease = try ServiceLease(root: root, name: ".ragdoll-archive-lock")
        defer { withExtendedLifetime(lease) {} }
        let usageManifest = root.appendingPathComponent(".ragdoll-usage-manifest.json")
        let legacy = !fm.fileExists(atPath: usageManifest.path)
        let manifestURL = legacy ? root.appendingPathComponent(".ragdoll-manifest.json") : usageManifest
        guard manifestURL.resolvingSymlinksInPath().path == manifestURL.path else { throw failure("归档清单路径无效") }
        guard fm.fileExists(atPath: manifestURL.path) else {
            guard !["sessions", "usage"].contains(where: { fm.fileExists(atPath: root.appendingPathComponent($0).path) }) else { throw failure("归档缺少清单，已停止读取和写入") }
            return 0
        }
        let manifest = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifestURL))
        let prefix = legacy ? "sessions/" : "usage/"
        for path in manifest.keys {
            guard path.hasPrefix(prefix), !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }),
                  root.appendingPathComponent(path).resolvingSymlinksInPath().path.hasPrefix(root.path + "/" + prefix) else { throw failure("归档清单路径越界：\(path)") }
        }
        func read(_ path: String) throws -> Data {
            let data = try Data(contentsOf: root.appendingPathComponent(path))
            guard manifest[path] == hash(data) else { throw failure("归档文件已变化，已停止读取和写入：\(path)") }
            return data
        }
        let paths = manifest.keys.sorted().filter { legacy ? $0.hasSuffix("/metadata.json") : $0.hasSuffix(".json") }
        for path in paths {
            let session = try JSONDecoder().decode(Session.self, from: read(path))
            _ = try store.save(session)
        }
        return paths.count
    }

    public static func save(_ sessions: [Session], to root: URL, sourceRoots: [String] = [], prices: [String: Price] = Settings().prices, commit: Bool = false) throws -> ArchiveResult {
        let root = root.standardizedFileURL.resolvingSymlinksInPath(), fm = FileManager.default
        try prepare(root, sourceRoots: sourceRoots)
        let lease = try ServiceLease(root: root, name: ".ragdoll-archive-lock")
        defer { withExtendedLifetime(lease) {} }
        let manifestURL = root.appendingPathComponent(".ragdoll-usage-manifest.json")
        guard manifestURL.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw failure("归档清单不能指向仓库外部") }
        let previousManifest = fm.fileExists(atPath: manifestURL.path) ? try Data(contentsOf: manifestURL) : nil
        var old = try previousManifest.map { try JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let activity = ArchiveActivity.render(sessions, prices: prices)
        let activityFiles = try prepareActivity(root, section: activity.section)
        old[ArchiveActivity.readmePath] = activityFiles.previousReadme.map(hash)
        old[ArchiveActivity.chartPath] = activityFiles.chartHash
        var desired = [ArchiveActivity.readmePath: activityFiles.readme, ArchiveActivity.chartPath: activity.chart]
        for session in sessions {
            desired[sessionPath(session)] = try encoder.encode(session)
        }
        for (path, data) in desired where data.count > 100 * 1024 * 1024 { throw failure("归档文件超过 100 MiB，已保留本地数据：\(path)") }
        for path in desired.keys {
            let destination = root.appendingPathComponent(path)
            guard !destination.resolvingSymlinksInPath().path.hasPrefix(root.path + "/.git/") && destination.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw failure("归档路径越界") }
            if fm.fileExists(atPath: destination.path) {
                let digest = hash(try Data(contentsOf: destination))
                guard old[path] == digest else { throw failure("归档文件已被手动修改或不属于应用：\(path)。请保留修改后选择其他归档目录，或恢复文件后重试。") }
            } else if old[path] != nil { throw failure("归档文件已被手动删除：\(path)。请处理该删除后重试。") }
        }
        let managed = Array(desired.keys) + [manifestURL.lastPathComponent, ArchiveActivity.manifestPath]
        let managedSet = Set(managed)
        let staged = commit ? try gitData(root, ["diff", "--cached", "--no-renames", "--name-only", "-z"]).split(separator: 0).map { String(decoding: $0, as: UTF8.self) } : []
        for path in staged where managedSet.contains(path) {
            let data = try gitData(root, ["show", ":\(path)"])
            let expected = switch path {
            case manifestURL.lastPathComponent: previousManifest.map(hash)
            case ArchiveActivity.manifestPath: activityFiles.manifest.map(hash)
            default: old[path]
            }
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
        var activityManifest = manifest.filter { ArchiveActivity.paths.contains($0.key) }
        activityManifest[ArchiveActivity.sectionKey] = hash(activity.section)
        for (path, values, previous) in [
            (manifestURL.lastPathComponent, manifest.filter { !ArchiveActivity.paths.contains($0.key) }, previousManifest),
            (ArchiveActivity.manifestPath, activityManifest, activityFiles.manifest)
        ] {
            let data = try encoder.encode(values)
            if previous != data { try data.write(to: root.appendingPathComponent(path), options: .atomic); changed.append(path) }
        }
        guard commit else { return ArchiveResult(files: changed.count, commit: nil) }
        let gitDirectory = try git(root, ["rev-parse", "--absolute-git-dir"])
        let pathspec = URL(fileURLWithPath: gitDirectory).appendingPathComponent("ragdoll-pathspec-\(UUID().uuidString)")
        try Data((managed.joined(separator: "\0") + "\0").utf8).write(to: pathspec)
        defer { try? fm.removeItem(at: pathspec) }
        _ = try git(root, ["add", "--pathspec-from-file=\(pathspec.path)", "--pathspec-file-nul"])
        let pending = try gitData(root, ["diff", "--cached", "--name-only", "-z"]).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        guard pending.contains(where: { managedSet.contains($0) }) else { return ArchiveResult(files: 0, commit: nil) }
        _ = try git(root, ["commit", "--only", "-m", "chore(archive): sync session usage", "--pathspec-from-file=\(pathspec.path)", "--pathspec-file-nul"])
        return ArchiveResult(files: changed.count, commit: try git(root, ["rev-parse", "--short", "HEAD"]))
    }

    private static func prepareActivity(_ root: URL, section: Data) throws -> (readme: Data, previousReadme: Data?, chartHash: String?, manifest: Data?) {
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        func file(_ name: String) throws -> URL? {
            guard let entry = entries.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
            let url = root.appendingPathComponent(entry)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard entry == name, values.isRegularFile == true, values.isSymbolicLink == false else { throw failure("归档报告需要同名普通文件：\(name)") }
            return url
        }
        let readmePath = ArchiveActivity.readmePath
        let manifest = try file(ArchiveActivity.manifestPath).map { try Data(contentsOf: $0) }
        let previous = try file(readmePath).map { try Data(contentsOf: $0) }
        _ = try file(ArchiveActivity.chartPath)
        var readme = previous ?? Data()
        let hashes = try manifest.map { try JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        let ownedSection = ArchiveActivity.sectionRange(in: readme)
        if manifest != nil {
            guard hashes[readmePath] != nil, hashes[ArchiveActivity.chartPath] != nil,
                  let ownedSection, hashes[ArchiveActivity.sectionKey] == hash(readme.subdata(in: ownedSection)) else {
                throw failure("README.md 的 Ragdoll 活动区块缺失或已修改，请恢复该区块后重试")
            }
        } else if ownedSection != nil {
            throw failure("README.md 已包含活动区块，但缺少归档报告清单")
        }
        var checkPaths = previous == nil || previous.map(hash) != hashes[readmePath] ? [readmePath] : []
        if manifest == nil { checkPaths += [ArchiveActivity.chartPath, ArchiveActivity.manifestPath] }
        if !checkPaths.isEmpty {
            let pathspecs = checkPaths.map { ":(top,icase,literal)\($0)" }
            let status = try git(root, ["status", "--porcelain=v1", "--untracked-files=all", "--ignored=matching", "--"] + pathspecs)
            guard status.isEmpty else { throw failure("归档报告文件存在未提交的改动，请先处理后重试：\(status)") }
        }
        if let ownedSection {
            readme.replaceSubrange(ownedSection, with: section)
        } else {
            if !readme.isEmpty { readme.append(contentsOf: "\n\n".utf8) }
            readme.append(section)
        }
        return (readme, previous, hashes[ArchiveActivity.chartPath], manifest)
    }

    static func sessionPath(_ session: Session) -> String {
        "usage/\(safeName(session.source))/\(safeName(session.id)).json"
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

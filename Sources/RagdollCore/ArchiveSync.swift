import Foundation
import Darwin

public enum ArchiveSync {
    public static func preview(root: URL, remote: String, branch: String) throws -> String {
        try validate(remote: remote, branch: branch)
        _ = try run(root, ["check-ref-format", "refs/heads/\(branch)"], timeout: 10)
        let destination = try redacted(pushDestination(root: root, remote: remote, timeout: 10))
        let files = try run(root, ["ls-tree", "-r", "--name-only", "HEAD"], timeout: 10).split(separator: "\n").count
        return "目标：\(destination)\n分支：\(branch)\n将上传当前分支的完整历史，最新提交包含 \(files) 个文件。"
    }
    @discardableResult public static func push(root: URL, remote: String, branch: String, timeout: Double = 90) throws -> String {
        try validate(remote: remote, branch: branch)
        guard timeout > 0 else { throw failure("Git 超时时间无效") }
        _ = try run(root, ["check-ref-format", "refs/heads/\(branch)"], timeout: timeout)
        let destination = try pushDestination(root: root, remote: remote, timeout: timeout)
        let temporaryRemote = "ragdoll-" + UUID().uuidString.lowercased()
        // shortcut: 固定单一 URL，需支持远端专属 pushOption/receivepack 时扩展。
        return try redacted(run(root, ["--config-env=remote.\(temporaryRemote).url=RAGDOLL_ARCHIVE_PUSH_URL", "push", "--porcelain", temporaryRemote, "HEAD:refs/heads/\(branch)"], timeout: timeout, environment: ["RAGDOLL_ARCHIVE_PUSH_URL": destination]))
    }
    private static func pushDestination(root: URL, remote: String, timeout: Double) throws -> String {
        let destinations = try run(root, ["remote", "get-url", "--push", "--all", remote], timeout: timeout).split(separator: "\n")
        guard destinations.count == 1, let destination = destinations.first else { throw failure("远端必须只有一个推送地址；请为归档配置专用远端后重新检查") }
        return String(destination)
    }
    private static func validate(remote: String, branch: String) throws {
        guard remote.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil,
              !branch.isEmpty, !branch.hasPrefix("-"), !branch.contains(":"), !branch.contains("\0") else { throw failure("请指定有效的 Git 远端名称和分支") }
    }
    private static func run(_ root: URL, _ args: [String], timeout: Double, environment: [String: String] = [:]) throws -> String {
        let directory = root.appendingPathComponent(".ragdoll-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("output")
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw failure("无法创建 Git 输出文件") }
        let handle = try FileHandle(forWritingTo: output); defer { try? handle.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = ["-C", root.path] + args
        process.standardInput = FileHandle.nullDevice; process.standardOutput = handle; process.standardError = handle
        process.environment = ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0", "GCM_INTERACTIVE": "never", "SSH_ASKPASS_REQUIRE": "never", "SSH_ASKPASS": "/usr/bin/false", "GIT_ASKPASS": "/usr/bin/false"]) { _, new in new }.merging(environment) { _, new in new }
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        if ended.wait(timeout: .now() + timeout) == .timedOut {
            let pid = process.processIdentifier
            let target = getpgid(pid) == pid ? -pid : pid
            kill(target, SIGTERM)
            if ended.wait(timeout: .now() + 1) == .timedOut { kill(target, SIGKILL); process.waitUntilExit() }
            throw failure("远端推送超时；本地归档已保留，可重试")
        }
        let text = String(decoding: try Data(contentsOf: output), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else { throw failure("本地归档已保留，Git 操作失败：\(try redacted(text))") }
        return text
    }
    private static func redacted(_ value: String) throws -> String {
        var text = value
        let pattern = try NSRegularExpression(pattern: "(?:https?|ssh)://[^\\s'\"<>]+")
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: text) else { continue }
            var url = URLComponents(string: String(text[range]))
            url?.user = nil; url?.password = nil; url?.query = nil; url?.fragment = nil
            text.replaceSubrange(range, with: url?.string ?? "<远端地址>")
        }
        return text
    }
    private static func failure(_ text: String) -> NSError { NSError(domain: "Ragdoll.ArchiveSync", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}

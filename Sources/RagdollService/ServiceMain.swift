import Foundation
import RagdollCore

@main
struct ServiceMain {
    static func main() async {
        let arguments = ProcessInfo.processInfo.arguments
        let root: URL
        if let index = arguments.firstIndex(of: "--data-dir") {
            guard arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--") else {
                FileHandle.standardError.write(Data("--data-dir 缺少目录参数\n".utf8)); exit(2)
            }
            root = URL(fileURLWithPath: arguments[index + 1])
        } else {
            root = ProcessInfo.processInfo.environment["RAGDOLL_DATA_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Ragdoll")
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try await BackgroundWorker(root: root).run(once: arguments.contains("--once"))
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
        }
    }
}

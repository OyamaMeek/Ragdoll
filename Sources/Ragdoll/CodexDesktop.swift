import AppKit

@MainActor
enum CodexDesktop {
    static func reopen(_ appURL: URL? = nil) async throws {
        guard let url = appURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex"),
              let identifier = Bundle(url: url)?.bundleIdentifier else {
            throw failure("未找到 ChatGPT（Codex 桌面端），请安装后手动打开。")
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        for app in running where !app.isTerminated {
            guard app.terminate() else { throw failure("ChatGPT 未能正常退出，请结束运行中的任务后手动重新打开。") }
        }
        let deadline = Date().addingTimeInterval(15)
        while running.contains(where: { !$0.isTerminated }) {
            guard Date() < deadline else { throw failure("等待 ChatGPT 退出超时，请结束运行中的任务后手动重新打开。") }
            try await Task.sleep(for: .milliseconds(100))
        }
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            throw failure("ChatGPT 未能重新打开，请手动打开应用。")
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Ragdoll.CodexDesktop", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

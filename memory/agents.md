# 开发环境

- 当前任务（2026-11-22）：切换账号后自动重新打开 ChatGPT（com.openai.codex）；复用账号切换和锁，采用 AppKit 正常退出/启动，单代理、Ponytail、TDD 与完成前验证。独立真实应用验证进程，不退出当前对话客户端、不截图、不运行 Claude 测试。

- 当前代理：Codex；单代理执行，详见 `memory/progress.md`。
- Swift 6.1、SwiftUI、macOS 15+、GRDB；TypeScript 助手使用 Node。
- 用量助手使用 Node 标准库；Codex 激活响应使用 eventsource-parser 解析 SSE。保留 SwiftUI 与 GRDB，不恢复聊天功能。
- 参考目录仅供读取，不纳入应用提交。

# 开发环境

- 当前任务（2026-11-22）：Codex 账号按 5h 窗口重置自动发送 hello；复用 RuntimeBridge、Codex Tools、ServiceLease 和既有后台服务，单代理、Ponytail 与回归测试，不截图、不运行 Claude 测试。

- 当前代理：Codex；单代理执行，详见 `memory/progress.md`。
- Swift 6.1、SwiftUI、macOS 15+、GRDB；TypeScript 助手使用 Node。
- 用量助手使用 Node 标准库；Codex 激活响应使用 eventsource-parser 解析 SSE。保留 SwiftUI 与 GRDB，不恢复聊天功能。
- 参考目录仅供读取，不纳入应用提交。

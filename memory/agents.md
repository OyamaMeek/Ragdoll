# 开发环境

- 当前任务（2026-11-22）：集成手动激活 Codex 5h 窗口；使用 Ponytail、Node test 与 Swift Testing，单代理执行，不截图、不运行 Claude 测试。参考 `references/codex-tools` 的预热流程。

- 当前代理：Codex；单代理执行，详见 `memory/progress.md`。
- Swift 6.1、SwiftUI、macOS 15+、GRDB；TypeScript 助手使用 Node。
- 用量助手使用 Node 标准库；Codex 激活响应使用 eventsource-parser 解析 SSE。保留 SwiftUI 与 GRDB，不恢复聊天功能。
- 参考目录仅供读取，不纳入应用提交。

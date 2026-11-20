# 开发环境

- 当前任务（2026-11-20）：移除对话，仅保留每会话 Token 用量；使用 Ponytail 与 TDD，单代理执行，不截图、不运行 Claude 接入测试。CLI、apply_patch、Swift Testing、Node test、SQLite 和真实 Git 仓库用于实施及验证。

- 当前代理：Codex；单代理执行，详见 `memory/progress.md`。
- Swift 6.1、SwiftUI、macOS 15+、GRDB；TypeScript 助手使用 Node。
- 用量助手仅使用 Node 标准库；移除 ACP、Claude Agent SDK、聊天导入、迁移及其专属依赖，保留 SwiftUI 与 GRDB。
- 参考目录仅供读取，不纳入应用提交。

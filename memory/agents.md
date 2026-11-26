# 开发环境

- 当前任务（2026-11-26）：已清理 `Ragdoll_sync` 非 Token 用量文件及旧历史，并压缩 SQLite、移出旧迁移恢复副本；使用隔离 Git 克隆、git-filter-repo、标准 SQLite backup/VACUUM、文件摘要与真实归档恢复验证。只调整归档、应用数据库和记录，不修改原始工具会话，不新增截图或运行 Claude 测试。

- 当前代理：Codex；单代理执行，详见 `memory/progress.md`。
- Swift 6.1、SwiftUI、macOS 15+、GRDB；TypeScript 助手使用 Node。
- 用量助手使用 Node 标准库；Codex 激活响应使用 eventsource-parser 解析 SSE。保留 SwiftUI 与 GRDB，定时消息交给原生桌面会话，不新增聊天界面。
- 参考目录仅供读取，不纳入应用提交。

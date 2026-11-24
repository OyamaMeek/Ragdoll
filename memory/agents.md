# 开发环境

- 当前任务（2026-11-24）：支持识别 Antigravity（桌面端、Insiders 与 CLI）的本地会话与 Token 用量；复用 Node 26 标准库 `node:sqlite` 只读解析 SQLite WAL 数据库与 `transcript_full.jsonl`，为已有用户自动补充默认来源目录。单代理、TDD 与完成前验证；不新增截图或运行 Claude 测试。

- 当前代理：Antigravity；单代理执行，详见 `memory/progress.md`。
- Swift 6.1、SwiftUI、macOS 15+、GRDB；TypeScript 助手使用 Node。
- 用量助手使用 Node 标准库；Codex 激活响应使用 eventsource-parser 解析 SSE。保留 SwiftUI 与 GRDB，定时消息交给原生桌面会话，不新增聊天界面。
- 参考目录仅供读取，不纳入应用提交。

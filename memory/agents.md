# 开发环境

- 当前任务（2026-11-22）：在 Codex 账号页选择项目与会话，自定义消息在下一次 5h 额度刷新后只发送一次，由桌面端原会话继续。使用桌面内置 Codex 0.171.0-alpha.13 的原生队列和唤醒深链接；单代理、Ponytail、TDD 与完成前验证。不截图、不运行 Claude 测试，不向真实会话发送任意测试消息。

- 当前代理：Codex；单代理执行，详见 `memory/progress.md`。
- Swift 6.1、SwiftUI、macOS 15+、GRDB；TypeScript 助手使用 Node。
- 用量助手使用 Node 标准库；Codex 激活响应使用 eventsource-parser 解析 SSE。保留 SwiftUI 与 GRDB，定时消息交给原生桌面会话，不新增聊天界面。
- 参考目录仅供读取，不纳入应用提交。

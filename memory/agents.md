# 开发环境

- 当前任务（2026-11-22）：一次性消息的项目选择列表优先显示最近使用的项目；复用 Store.list 按会话 updated 倒序的已有结果，保留首次出现的项目顺序。单代理、Ponytail、TDD 与完成前验证；不新增截图或运行 Claude 测试。

- 当前代理：Codex；单代理执行，详见 `memory/progress.md`。
- Swift 6.1、SwiftUI、macOS 15+、GRDB；TypeScript 助手使用 Node。
- 用量助手使用 Node 标准库；Codex 激活响应使用 eventsource-parser 解析 SSE。保留 SwiftUI 与 GRDB，定时消息交给原生桌面会话，不新增聊天界面。
- 参考目录仅供读取，不纳入应用提交。

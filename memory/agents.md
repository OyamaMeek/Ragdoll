# 开发环境

- 当前任务（2026-11-27）：用量归档继续自动写文件，改为用户手动触发 commit 和 push；检查 Swift 归档、AppModel、后台服务与设置，使用真实 Git 仓库及独立进程回归，不新增截图或运行 Claude 测试。源码仓库开发提交规则不变。

- 当前代理：Codex；单代理执行，详见 `memory/progress.md`。
- Swift 6.1、SwiftUI、macOS 15+、GRDB；TypeScript 助手使用 Node。
- 用量助手使用 Node 标准库；Codex 激活响应使用 eventsource-parser 解析 SSE。保留 SwiftUI 与 GRDB，定时消息交给原生桌面会话，不新增聊天界面。
- 参考目录仅供读取，不纳入应用提交。

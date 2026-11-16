# Ragdoll 实施计划

## 已确认需求

- macOS 原生 SwiftUI 应用，Apple Silicon，中文、系统主题。
- 首页：7×24 Token 热力图、成本、项目统计、滚动 168 小时预算及 80%/100% 提醒。
- 全量及增量读取 Codex、Claude Code、dsh；搜索、分页浏览，原生协议续聊。
- 独立“对话”入口，保留原生接入并加入本地 ACP 命令与官方 Registry 的安装、认证、更新、卸载。
- Claude 普通聊天导入官方导出包，续聊打开原聊天。
- 自动归档原始记录、Markdown、元数据及可取得的附件；30 秒防抖、最长 5 分钟，本地 Git 提交，不推送归档。
- 缺失用量/价格显示未知；凭据不进入归档；源日志只读，用户主动对话通过原生工具持久化。

## 结构

- Swift Package：RagdollCore（模型、GRDB、统计、归档）、Ragdoll（SwiftUI 入口及交互）。
- runtime：TypeScript（日志、Codex/Claude/dsh、ACP、Registry）；NDJSON 子进程通信。
- scripts：构建、打包和验证。通过 Swift Package 构建原生 .app，避免依赖额外工程生成器。
- Tests、runtime/test：真实格式样本和真实 Git 仓库验证。

## 执行次序

1. 模型、日志读取、持久索引与浏览。
2. 统计、热力图、预算。
3. 自动 Git 归档及冲突保护。
4. 原生会话恢复、流式输出、权限、停止。
5. ACP 本地与 Registry、安装和认证。
6. Claude 导出包导入、打包、实际运行与最终检查。

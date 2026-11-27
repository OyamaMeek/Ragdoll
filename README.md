<p align="center">
  <img src="docs/assets/ragdoll.svg" alt="Ragdoll 猫咪标识" width="128" height="128">
</p>

<h1 align="center">Ragdoll</h1>

<p align="center">
  <strong>在 Mac 上统计每个 AI 编程会话的 Token 用量。</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-15%2B-24292f?logo=apple&amp;logoColor=white" alt="macOS 15 及以上">
  <img src="https://img.shields.io/badge/Apple_Silicon-arm64-0071e3" alt="Apple Silicon arm64">
  <img src="https://img.shields.io/badge/Swift-SwiftUI-f05138?logo=swift&amp;logoColor=white" alt="Swift 与 SwiftUI">
  <a href="https://github.com/OyamaMeek/Ragdoll/actions/workflows/release.yml"><img src="https://github.com/OyamaMeek/Ragdoll/actions/workflows/release.yml/badge.svg" alt="macOS 构建状态"></a>
</p>

<p align="center">
  <a href="#功能">功能</a> ·
  <a href="#安装">安装</a> ·
  <a href="docs/USAGE.md">使用指南</a> ·
  <a href="docs/DEVELOPMENT.md">开发文档</a> ·
  <a href="https://github.com/OyamaMeek/Ragdoll/issues">反馈问题</a>
</p>

---

Ragdoll 是一款原生 SwiftUI macOS 应用，读取 Codex、Claude Code、DeepSeek Harness 和 Antigravity 的本地日志与会话数据库，保存每个会话的 Token 明细。按来源、项目或日期查看用量与估算成本，并将用量数据自动备份到你选择的 Git 仓库。

## 功能

| 分类 | 功能 |
| --- | --- |
| 会话用量 | 搜索名称、项目和会话 ID，按来源、项目和日期筛选，查看模型、时间及输入/输出/缓存 Token 明细 |
| 用量统计 | 年度 Token 热力图、历史年份切换、悬停查看用量、点击日期筛选会话，以及项目统计与估算成本 |
| 成本预算 | 可选的每周预算卡片，统计滚动 168 小时消费，在 80% 和 100% 时提醒 |
| Git 用量备份 | 自动写入每会话 JSON、仓库首页活动报告与热力图，手动提交并推送 |
| 后台服务 | 可选的用户级登录项，退出应用后继续扫描与保存文件，提交和推送由手动请求触发 |
| Codex 账号 | 复用已安装的 Codex Tools，查看多账号额度、切换本机登录，手动或在窗口刷新后自动激活 5h 窗口 |

## 支持的来源

| 来源 | 用量接入 |
| --- | --- |
| Codex | 本地历史与归档会话，保留缓存明细及请求去重 |
| DeepSeek Harness | 本地日志及压缩日志，选择最新版本并排除继承用量 |
| Claude Code | 读取本地日志中的模型与用量，按请求去重 |
| Antigravity | 读取桌面端、Insiders 与 CLI 的会话数据库和步骤日志，保留缓存明细并去重 |

旧版本已索引的其他来源会话保留其用量；缺少用量的会话显示未知。

## 安装

**系统要求：macOS 15 或更新版本，Apple Silicon。**

当前尚未发布正式 Release，请从源码构建。构建需要 Xcode 16.4+、Swift 6.1 和 Node 26。

```sh
git clone https://github.com/OyamaMeek/Ragdoll.git
cd Ragdoll
bash scripts/build.sh
open dist/Ragdoll.app
```

构建完成后，可将 `dist/Ragdoll.app` 移入“应用程序”。安装包内包含 Node 和用量读取助手，运行打包后的应用无需另装 Node；首次构建会下载并校验 Node 官方发行包。

构建默认使用本地临时签名，未经 Apple 公证。首次打开可能受到 Gatekeeper 限制；独立后台服务需要有效 Apple 签名，详见[签名与后台服务](docs/DEVELOPMENT.md#签名与后台服务)。正式版本与构建记录见 [Releases](https://github.com/OyamaMeek/Ragdoll/releases) 和 [Actions](https://github.com/OyamaMeek/Ragdoll/actions/workflows/release.yml)。

## 开始使用

1. **选择用量仓库。** 首次启动选择本地专用 Git 仓库，或选择空目录创建仓库；Git 需要配置 `user.name` 和 `user.email`。
2. **查看会话用量。** 应用先读取历史用量，再扫描本机日志。在“会话用量”中查看每条记录，在首页查看年度热力图与项目统计。
3. **按需调整设置。** 配置来源目录、模型价格、每周预算、远端推送或独立后台服务。
4. **手动提交与推送。** 在“设置 → Git 用量备份”点击“提交并推送”；未设置远端时显示“提交用量”，只创建本地提交。日常自动保存只写文件。

具体操作与恢复说明见[使用指南](docs/USAGE.md)。

## 数据与隐私

- 数据与索引位于 `~/Library/Application Support/Ragdoll`，归档保存在你选择的 Git 仓库。
- 新索引与备份仅保存会话信息和 Token 明细。会话名称和项目路径仍可能含有敏感信息。
- 旧索引迁移前自动保存 `index.sqlite.before-usage` 恢复副本，该副本仍含正文并占用空间；确认用量完整后可手动移走或删除。
- 旧归档与 Git 历史保留。**远端推送包含该分支的完整历史，沿用旧仓库时仍可能上传原有正文与附件。** 源工具日志保持只读。
- 推送失败时保留本地提交，再次点击“提交并推送”手动重试；远端分歧需要手动处理，应用不自动拉取、合并或强制推送。
- 成本为估算值，缺失价格或用量时显示未知。

## 文档

- [使用指南](docs/USAGE.md)：会话用量、来源目录、Git 备份、后台服务与恢复方式。
- [开发文档](docs/DEVELOPMENT.md)：本地开发、检查命令、签名与自动发布。
- [验证记录](docs/VALIDATION.md)：实际测试结果及尚未完成的验证。
- [开发记录](docs/CHANGELOG.md) · [第三方参考与出处](docs/THIRD_PARTY.md)。

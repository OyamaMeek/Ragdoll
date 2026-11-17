# 开发记录

## [2026-11-16 23:47] Ragdoll 原生应用与 ACP 对话

- **需求/问题描述**：实现已确认的历史读取、热力图、成本预算、Git 归档、原生续聊及 ACP 对话方案。
- **实际实现的功能与改动**：
  - SwiftUI 首页、7×24 热力图、项目统计、成本与预算，SQLite 历史索引和消息搜索。
  - Codex、Claude Code、dsh 原生接入；ACP 本地命令、官方目录安装与更新、认证、动态配置和历史导入。
  - Claude 普通聊天官方导出包导入；原始记录、附件和 Markdown 的自动 Git 归档，保留手工编辑与外部暂存。
  - 内置 Node 的 `.app` 打包、独立静态审查、真实启动与源码验证；具体执行结果见 `docs/VALIDATION.md`。
  - Claude 按用户要求仅完成后续代码，不继续运行测试；其真实续聊验证未完成。
- **涉及文件**：`Package.swift`、`Sources/`、`Tests/`、`runtime/`、`scripts/`、`packaging/`、`memory/`、`docs/`、`README.md` 与依赖锁定文件。
- **Git 提交**：`f762527 feat(macos): add session analytics, git archive and ACP chat`，已普通推送至 `origin/main`。提交哈希与最终验证说明由后续记录提交补记。

## [2026-11-16 23:59] 第一版新增范围设计

- **需求/问题描述**：
  > 第一版同时加入跨工具原生历史迁移、指定 Git 远端自动推送及失败重试、独立后台常驻服务。
- **实际实现的功能与改动**：
  - 记录用户确认的三项范围，编写迁移完整性、推送状态与后台调度所有权设计，并更新实施和验收记录。
  - 独立设计审阅后明确迁移最低成功范围；用户允许将不兼容的推理或工具记录完整转换为带来源标记的历史文本。
  - 产品代码尚未修改；具体实现设计待用户审阅。
  - 文档变更执行 `git diff --check`；未运行功能测试。
- **涉及文件**：`docs/superpowers/specs/2026-11-16-v1-expansion-design.md`、`memory/agents.md`、`memory/plan.md`、`memory/progress.md`、`memory/verify.md`、`docs/CHANGELOG.md`。
- **Git 提交**：`016967d docs(v1): define migration sync and background service scope`，已普通推送至 `origin/main`；本条由后续文档提交补记。新增功能尚未实施。

---

## [2026-11-17 07:46] 修复大消息导致会话扫描卡住

- **需求/问题描述**：
  > 首页持续显示“正在读取会话…”，应用卡住。
- **实际实现的功能与改动**：
  - `RuntimeBridge` 只在新收到的数据中查找换行，按顺序拼接完整消息，避免反复扫描大消息缓冲区。
  - 新增真实助手传输回归，验证约 16 MB Unicode 正文、相邻短消息及后续响应；修复前扫描超时，修复后通过。
  - 全部 11 项 Swift 测试、release 打包、签名校验及助手自检通过。
  - 本机完整扫描 701 个 Codex 会话用时 15.6 秒，最大会话正文约 145 MB，无扫描警告；新版应用已运行，采样 CPU 约 2%。
- **涉及文件**：`Sources/RagdollCore/RuntimeBridge.swift`、`Tests/RagdollCoreTests/RuntimeBridgeTests.swift`、`README.md`、`memory/agents.md`、`memory/plan.md`、`memory/progress.md`、`memory/verify.md`、`docs/VALIDATION.md`、`docs/CHANGELOG.md`。
- **Git 提交**：`98348dd fix(runtime): prevent scans stalling on large messages`，已普通推送至 `origin/main`；本条由后续文档提交补记。

---

## [2026-11-17 08:35] 跨工具原生历史迁移运行时

- **需求/问题描述**：
  > 第一版支持将完整旧会话转换成目标原生历史；不兼容的工具或推理记录允许按来源保留全文。
- **实际实现的功能与改动**：
  - 增加迁移运行时入口、Codex/Claude Code/dsh 写入器、原始记录与附件保留、非覆盖发布、路径边界和来源清单。
  - Codex 与 dsh 目标通过真实恢复和续聊检查，均返回旧历史中的校验码；Claude 写入代码保留未验证状态，不运行其原生检查。
  - 修复 dsh 以错误原因结束轮次时仍返回成功的问题；真实缺失凭据检查先失败、修复后通过。
  - TypeScript 严格检查通过；明确排除 Claude 后，允许的 Node 回归 15 项通过、6 项集成检查跳过。另有两项迁移后的实际续聊检查分别通过。
  - 早先反向测试筛选意外运行一项 Claude 日志解析测试，未启动 Claude 原生对话；后续改为显式跳过规则，已记录注意事项。
- **涉及文件**：`runtime/src/migration.ts`、`runtime/src/main.ts`、`runtime/src/logs.ts`、`runtime/src/types.ts`、`runtime/src/agents.ts`、`runtime/test/migration.test.ts`、`docs/CHANGELOG.md`。
- **Git 提交**：`c82ebeb feat(migration): write native conversation history across tools`，已普通推送至 `origin/main`。

---

## [2026-11-17 09:47] 完整迁移与附件边界修正

- **需求/问题描述**：
  > 原生迁移需完整保留历史，支持再次迁移并保护源文件和已有目标。
- **实际实现的功能与改动**：
  - 附件仅从已知用户附件块和可信清单读取；项目外新引用需要文件选择器授权，工具输出中的任意 URI 不触发文件复制。
  - JSON 附件独立复制，二次迁移重新映射附件；普通消息去除协议镜像，原始审计文件单独保留。
  - 原生来源缺失原始日志时明确失败；保留已有目标与 sidecar，保持配置目录身份及迁移来源。
  - 审阅问题用真实文件回归确认 RED→GREEN；最终允许的 Node 测试 18 项通过、6 项跳过，TypeScript 检查通过。Codex/dsh 迁移后真实续聊各通过一项。
- **涉及文件**：`runtime/src/migration.ts`、`runtime/src/logs.ts`、`runtime/src/types.ts`、`runtime/test/migration.test.ts`、`docs/CHANGELOG.md`。
- **Git 提交**：`2ffdfc5 fix(migration): preserve attachments and constrain source reads`，已普通推送至 `origin/main`。

---

## [2026-11-17 09:54] 远端归档与独立后台核心

- **需求/问题描述**：
  > 自动推送指定 Git 远端，失败保留本地归档并重试；独立后台服务在 GUI 退出后继续工作。
- **实际实现的功能与改动**：
  - 普通 Git 推送、唯一目标预览、非交互认证、90 秒超时及地址脱敏；持久待推送状态允许无新提交重试。
  - 新增用户级 RagdollService、进程锁、设置重载、持久变更标记、扫描/归档/推送调度；Node 或索引故障触发非零退出及所有权释放。
  - SQLite 锁等待及迁移来源保留；打包 helper/LaunchAgent 并支持指定 `CODE_SIGN_IDENTITY`。
  - Swift 21 项测试函数通过；独立打包 helper 使用包内 Node 完成实际扫描、归档和推送。系统注册、实际启动及注销成功；外置 SSD 的系统托管完整流程受 TCC 授权限制，未记为通过。
- **涉及文件**：`Package.swift`、`Sources/RagdollCore/ArchiveSync.swift`、`Sources/RagdollCore/BackgroundService.swift`、`Sources/RagdollCore/Archive.swift`、`Sources/RagdollCore/Models.swift`、`Sources/RagdollCore/Store.swift`、`Sources/RagdollService/ServiceMain.swift`、`Tests/RagdollCoreTests/ArchiveSyncTests.swift`、`Tests/RagdollCoreTests/BackgroundServiceTests.swift`、`scripts/build.sh`、`packaging/com.oyamameek.ragdoll.service.plist`、`docs/CHANGELOG.md`。
- **Git 提交**：`17e2a9a feat(background): sync git archives from a persistent service`，已普通推送至 `origin/main`。

---

## [2026-11-17 09:57] 迁移与后台设置交付

- **需求/问题描述**：
  > 在第一版应用中提供跨工具原生迁移、远端推送与独立后台服务的完整操作入口。
- **实际实现的功能与改动**：
  - 会话迁移面板支持目标工具、项目和外部附件授权；Claude 方向标注未验证，错误在现有入口展示。
  - 远端地址及分支检查后启用，独立显示本地归档和推送结果；切换仓库停用旧目标，配置快照避免混用。
  - 系统登录项启停与状态展示，GUI/服务通过进程锁协调调度；新鲜心跳及所有者检查避免显示陈旧状态。
  - README、设计、实施及验证记录已更新；最终 Apple Development 签名 release 构建、深度签名校验、helper/内置 Node 自检通过。未执行视觉检查；系统托管下访问外置 SSD 的完整流程受 TCC 限制。
- **涉及文件**：`Sources/Ragdoll/AppModel.swift`、`Sources/Ragdoll/ConversationView.swift`、`Sources/Ragdoll/SettingsView.swift`、`Sources/Ragdoll/MigrationView.swift`、`README.md`、`docs/VALIDATION.md`、`docs/superpowers/`、`memory/`、`docs/CHANGELOG.md`。
- **Git 提交**：`4891b75 feat(app): expose native migration and background archive controls`，已普通推送至 `origin/main`；本条由后续文档提交补记。

---

## [2026-11-17 12:56] 年度贡献式热力图

- **需求/问题描述**：
  > 按用户参考图调整热力图的呈现方式。
- **实际实现的功能与改动**：
  - 每日绿色方格按周排列为七行，显示月份、周一/三/五、五级图例与右侧年份选择，适配系统浅色和深色主题。
  - 当前年份显示截至今天的近一年，历史年份显示完整自然年；本地自然日聚合 Token，范围外日期留空，点击方格筛选当天会话。
  - 历史日期回归先因旧七日统计遗漏数据失败；修复后全部 23 项 Swift 测试通过，覆盖 DST、跨年、闰日、空数据、未来日期和用量去重。
  - release 打包、Apple Development 深度签名和助手自检通过，新版应用已重新启动。未执行截图、视觉核对或窗口交互测试。
- **涉及文件**：`Sources/Ragdoll/DashboardView.swift`、`Sources/Ragdoll/AppModel.swift`、`Sources/RagdollCore/Analytics.swift`、`Tests/RagdollCoreTests/AnalyticsTests.swift`、`memory/agents.md`、`memory/plan.md`、`memory/progress.md`、`memory/verify.md`、`docs/VALIDATION.md`、`docs/CHANGELOG.md`。
- **Git 提交**：`557d871 feat(dashboard): show annual contribution heatmap`，已普通推送至 `origin/main`；本条由后续文档提交补记。

---

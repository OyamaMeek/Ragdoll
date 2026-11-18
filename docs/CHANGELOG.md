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

## [2026-11-17 13:03] 每周预算显示开关

- **需求/问题描述**：
  > 在设置中增加开关控制首页每周预算区域是否显示，默认不显示。
- **实际实现的功能与改动**：
  - 设置新增“首页”分类与“显示每周预算”开关，切换立即保存；首页仅在显式开启时显示完整预算卡片。
  - 新配置与缺少字段的旧配置均默认隐藏；关闭后保留预算金额及原有统计逻辑。
  - 配置持久化测试先因字段丢失失败，修改后全部 24 项 Swift 测试通过，覆盖旧配置兼容、SQLite 重新打开后保持开启/关闭及预算金额保留。
  - release 打包、Apple Development 深度签名与助手自检通过，新版应用已启动；未执行截图、视觉核对或窗口交互测试。
- **涉及文件**：`Sources/Ragdoll/DashboardView.swift`、`Sources/Ragdoll/SettingsView.swift`、`Sources/RagdollCore/Models.swift`、`Tests/RagdollCoreTests/StoreArchiveTests.swift`、`memory/agents.md`、`memory/plan.md`、`memory/progress.md`、`memory/verify.md`、`docs/CHANGELOG.md`。
- **Git 提交**：`afc5245 feat(settings): toggle weekly budget visibility`，已普通推送至 `origin/main`；本条由后续文档提交补记。

---

## [2026-11-17 13:13] 热力图绿色梯度与悬停用量

- **需求/问题描述**：
  > 调浅热力图最深绿色，Token 越多绿色越浅；鼠标悬停显示当天 Token 量，参照用户提供的浮层样式。
- **实际实现的功能与改动**：
  - 浅色和深色主题统一使用 `#216e39`、`#38964b`、`#65be67`、`#9be9a8` 四档绿色，图例同步；零用量保持中性色。
  - 悬停方格显示日期与中文紧凑格式 Token，例如“10月29日 / 1.7亿 个 Token”；浮层忽略鼠标事件，保留点击筛选和可访问性。
  - 浮层位置跟随方格并限制左右边界；切换年份、项目、来源、横向滚动或离开首页时清除悬停。
  - 色板回归先失败，修改后全部 26 项 Swift 测试通过；release 打包、Apple Development 深度签名与助手自检通过，新版应用已启动。未执行截图、实际鼠标悬停或边缘定位验证。
- **涉及文件**：`Package.swift`、`Sources/Ragdoll/DashboardView.swift`、`Tests/RagdollTests/DashboardTests.swift`、`memory/agents.md`、`memory/plan.md`、`memory/progress.md`、`memory/verify.md`、`memory/gotchas.md`、`docs/CHANGELOG.md`。
- **Git 提交**：`e8fa96a fix(dashboard): lighten heatmap and show hover usage`，已普通推送至 `origin/main`；本条由后续文档提交补记。

---

## [2026-11-17 13:24] 读取 Codex 会话小标题

- **需求/问题描述**：
  > 最近会话显示已有的小标题，避免显示 AGENTS.md 等前置指令。
- **实际实现的功能与改动**：
  - 每个 Codex home 扫描一次 `session_index.jsonl`，通过会话 ID 读取保存名称，首页、会话列表、搜索及归档共用；支持归档会话和不同 home。
  - 单独改名、清空名称或移除索引会更新对应会话；其他会话沿用增量指纹。缺少名称时跳过 AGENTS.md 和环境上下文，从实际提问提取摘要，保留完整消息原文。
  - 索引缺失兼容，损坏或无效记录通过既有 warning 通道报告并保留有效名称；不增加依赖或修改源日志。
  - 四项新增回归先失败，修复后 Node 测试 22 项通过、6 项跳过，TypeScript 检查通过；本机 711 个 Codex 会话中 582 个保存名称全部匹配，指令标题和 warning 均为零。
  - release 打包、Apple Development 深度签名和助手自检通过，新版应用已启动；未执行截图或窗口交互验证，未运行 Claude 测试。
  - 应用 SQLite 索引中的 555 个保存名称全部匹配；仅剩 1 条旧指令标题，其源日志均已删除且无保存名称，保留历史记录。
- **涉及文件**：`runtime/src/logs.ts`、`runtime/test/logs.test.ts`、`memory/agents.md`、`memory/plan.md`、`memory/progress.md`、`memory/verify.md`、`docs/CHANGELOG.md`。
- **Git 提交**：`9e48ec8 fix(logs): read saved Codex session titles`，已普通推送至 `origin/main`；本条由后续文档提交补记。

---

## [2026-11-17 13:34] 最近会话日期筛选

- **需求/问题描述**：
  > 将首页最近会话“全部”改为今天、昨日、本周、本月。
- **实际实现的功能与改动**：
  - 右上角菜单默认今天，按本地自然日、周、月和会话最后更新时间筛选，排除未来记录；无结果显示“该时段暂无会话”。
  - 先筛选后显示最近六条，保留项目、来源筛选及点击详情；日期菜单仅影响最近会话卡片。
  - 日期限制移除的反例运行中，两项回归的五个断言失败；恢复后全部 28 项 Swift 测试通过，覆盖跨月、跨年、周首、无用量会话、未来记录和 DST。
  - release 打包、Apple Development 深度签名与助手自检通过，新版应用已启动并确认进程；未执行截图或窗口交互验证。
- **涉及文件**：`Sources/Ragdoll/DashboardView.swift`、`Tests/RagdollTests/DashboardTests.swift`、`memory/agents.md`、`memory/plan.md`、`memory/progress.md`、`memory/verify.md`、`docs/CHANGELOG.md`。
- **Git 提交**：`621d8b0 feat(dashboard): filter recent sessions by calendar period`，已普通推送至 `origin/main`；本条由后续文档提交补记。

---

## [2026-11-17 14:46] 图片独立归档与远端推送

- **需求/问题描述**：
  > 归档没有上传；用户确认公开上传，并要求由应用把 Markdown 中的图片剥离为独立文件上传。
- **实际实现的功能与改动**：
  - GUI 与后台共用归档逻辑，将可解码的内嵌图片保存为按 SHA-256 命名的独立图片，通过相对路径引用；同一会话的重复图片复用文件，正文及图片字节保留。
  - 无源文件的 events.json 同样使用图片引用；代码示例中的无效图片 URL 保留原文。图片继续受目录边界、清单摘要和手工修改保护约束。
  - 超过 50 MiB 的原始日志以确定性 gzip 无损保存，更新正文中的源文件链接，仅替换未被手工修改或外部暂存的受管理副本；源文件不变，归档文件超过 100 MiB 时明确失败。
  - 新增回归先因图片未抽离和日志未压缩失败；实现后全部 31 项 Swift 测试通过，release 打包、Apple Development 深度签名与助手自检通过。
  - 新版打包 helper 完成本机 812 个会话扫描与归档；全量校验 3,776 个受管理文件摘要，包含 1,394 个独立图片与 785 份 Markdown。原超限 Markdown 从 144,583,047 字节缩小至 1,616,677 字节；原日志 gzip 为 104,436,682 字节，解压后 SHA-256 与源文件一致。
  - 旧归档历史和数据库已建立本地恢复备份；公开归档已普通推送至 `OyamaMeek/Ragdoll_sync`，首次远端提交与本地 `c75b3ed` 一致。应用保存 `origin/main` 自动推送设置并启动新版；经纯文本辅助功能调用既有“立即归档”入口，应用归档提交 `0b25b2b4fe5128a101aaa03d4b6b8273c6d87dca` 同样自动推送成功，远端 main 完全一致且待重试标记已清除。未运行截图、视觉或 Claude 测试。
- **涉及文件**：`Sources/RagdollCore/Archive.swift`、`Sources/Ragdoll/SettingsView.swift`、`Tests/RagdollCoreTests/ArchiveImagesTests.swift`、`memory/agents.md`、`memory/plan.md`、`memory/progress.md`、`memory/verify.md`、`memory/gotchas.md`、`docs/CHANGELOG.md`。
- **Git 提交**：`287eec3 feat(archive): extract inline images into separate files`，已普通推送至 `origin/main`；本条由后续文档提交补记。

---

## [2026-11-17 16:14] 首次 Git 设置与仓库优先启动

- **需求/问题描述**：
  > 第一次打开应用就要求设置 Git 仓库，后续打开优先读取仓库的数据，再检查新增数据并放入仓库。
- **实际实现的功能与改动**：
  - 首次必需选择或创建本地专用 Git 仓库；未设置时不扫描、导入或归档。已配置的仓库读取失败时可重选或重试，并停止扫描和归档。
  - GUI 和后台先从仓库恢复历史，再扫描本机新增内容并自动归档；共享 Store 拒绝较旧记录覆盖较新历史，保留尚未归档的本机数据。
  - 所有会话写入完整 events.json；旧 JSONL/gzip 复用原生日志解析，其他旧归档完整保留 Markdown 并提示消息结构限制。保留手工修改保护及既有自动推送。
  - 完整快照和旧源覆盖回归先失败、修复后通过；全部 40 项 Swift 测试通过，Node 22 项通过、6 项跳过，TypeScript 检查通过。release 打包、Apple Development 深度签名及助手自检通过。
  - 隔离应用实际读取所选仓库并自动保存，归档树核对有 787 份完整 events.json；验证实例结束后，已用原有正式数据目录和远端设置重新启动新版应用。未运行 Claude、截图或视觉检查。
- **涉及文件**：`Sources/Ragdoll/AppModel.swift`、`Sources/Ragdoll/RootView.swift`、`Sources/Ragdoll/SettingsView.swift`、`Sources/RagdollCore/Archive.swift`、`Sources/RagdollCore/Store.swift`、`Sources/RagdollCore/BackgroundService.swift`、`runtime/src/main.ts`、`runtime/src/logs.ts`、`Tests/RagdollCoreTests/ArchiveReadTests.swift`、`Tests/RagdollCoreTests/StoreArchiveTests.swift`、`Tests/RagdollCoreTests/BackgroundServiceTests.swift`、`Tests/RagdollTests/StartupTests.swift`、`README.md`、`docs/VALIDATION.md`、`memory/agents.md`、`memory/plan.md`、`memory/progress.md`、`memory/verify.md`。
- **Git 提交**：`7e60a35 feat(startup): require git setup and restore archive before scanning`，已普通推送至 `origin/main`；本条由后续文档提交补记。

---

## [2026-11-17 16:26] 启动时立即显示主界面

- **需求/问题描述**：
  > 打开应用先显示界面，仓库读取状态可以在角落用小字显示。
- **实际实现的功能与改动**：
  - 已配置仓库时直接显示主界面和已有会话摘要，正在读取的状态显示在侧栏底部；首次尚未配置仓库时保留设置页。
  - 读取失败时保留界面与缓存，侧栏提供重试入口；读取完成前禁用刷新和导入按钮，继续保留禁止扫描和写入的保护。
  - 新回归先出现五个失败断言，修复后全部 41 项 Swift 测试通过；release 打包、Apple Development 深度签名及助手自检通过，已在原数据目录重新启动新版。未新增截图或视觉检查，未运行 Claude 实测。
- **涉及文件**：`Sources/Ragdoll/AppModel.swift`、`Sources/Ragdoll/RootView.swift`、`Tests/RagdollTests/StartupTests.swift`、`README.md`、`memory/agents.md`、`memory/plan.md`、`memory/progress.md`、`memory/verify.md`、`memory/gotchas.md`、`docs/VALIDATION.md`、`docs/CHANGELOG.md`。
- **Git 提交**：`8f9280c fix(startup): show cached interface while reading archive`，已普通推送至 `origin/main`；本条由后续文档提交补记。

---

## [2026-11-17 16:34] 最近会话显示日期文字

- **需求/问题描述**：
  > 每条最近会话右侧不显示几分几秒，改为今天、昨日、本周、本月。
- **实际实现的功能与改动**：
  - 按本地自然日、周、月依次显示日期文字；更早记录显示具体日期，省略时间。
  - 右上角为“全部”导航，保留最近六条、来源和项目筛选以及点击详情。
  - 两项回归先出现 11 个失败断言，修复后全部 41 项 Swift 测试通过，覆盖午夜、跨年周、夏令时及更早日期。
  - release 打包、Apple Development 深度签名及助手自检通过，已启动新版并确认进程；未新增截图或视觉检查。
- **涉及文件**：`Sources/Ragdoll/DashboardView.swift`、`Tests/RagdollTests/DashboardTests.swift`、`memory/agents.md`、`memory/plan.md`、`memory/progress.md`、`memory/verify.md`、`memory/gotchas.md`、`docs/CHANGELOG.md`。
- **Git 提交**：`0fe88f7 fix(dashboard): show calendar labels for session dates`，已普通推送至 `origin/main`；本条由后续文档提交补记。

---

## [2026-11-17 20:50] GitHub Actions 自动编译发布

- **需求/问题描述**：
  > 设置一个 action 自动编译发布到 GitHub Release。
- **实际实现的功能与改动**：
  - 推送 `vX.Y.Z` 标签后，在 macOS 15 ARM64 runner 复用现有脚本生成应用，写入版本与构建编号，通过检查后发布 ZIP 和 SHA-256 校验文件。
  - 手动分支运行只保存 Actions artifact，手动标签运行发布 Release；使用内置 GITHUB_TOKEN，不覆盖已有 Release，无需新增密钥。
  - README 和发布说明明确 macOS 15+、Apple Silicon、临时签名、未公证及独立后台服务的有效签名要求。Node 校验使用系统 grep，避免依赖 CI 未安装的 rg。
  - 本机 actionlint、workflow shell 语法与四种版本准备场景通过；TypeScript 检查通过，默认 Node 21 项通过/8 项跳过，Swift 41 项通过；release 打包、ZIP 解压后的权限/架构/深度签名/内置助手及 SHA-256 校验通过。改用 grep 后官方 Node 下载包校验通过。
  - 需要本机 DeepSeek Harness 的迁移恢复与附件二次迁移测试沿用 RAGDOLL_MIGRATION_LIVE=dsh 开关，二次迁移独立为子测试，保留其他附件断言。云端默认跳过，本机显式开启后真实测试 3 项通过（含父测试）。
  - CI 单独安装固定版本 Codex 0.147.0，供迁移测试调用真实 app-server，不加入发布包。
  - CI 显式串行运行全部 Swift 测试，避免在 3 核 runner 同时启动多组后台 helper；本机串行命令 41 项测试在 20.038 秒内通过。
  - 云端 [手动构建 44085972714](https://github.com/OyamaMeek/Ragdoll/actions/runs/44085972714) 整体成功：TypeScript、Node 21 项通过/8 项跳过、Swift 41 项通过（50.844 秒），ZIP 解压后的签名/助手/SHA-256 校验和 artifact 上传通过。构建产物 14328654532 实际为 78,091,772 字节。
  - 本机 dist 应用已恢复为原证书签名版本并通过深度校验。未运行 Claude 测试、截图或 Apple 公证；分支验证按条件跳过发布步骤，未创建版本标签，正式标签发布尚未实测。
- **涉及文件**：`.github/workflows/release.yml`、`scripts/build.sh`、`runtime/test/migration.test.ts`、`README.md`、`memory/agents.md`、`memory/plan.md`、`memory/progress.md`、`memory/verify.md`、`docs/CHANGELOG.md`。
- **Git 提交**：`87fcafa chore(release): build macOS app and publish tagged releases`、`695e547 fix(build): use system grep for Node checksum verification`、`d6b1dbc test(migration): gate local dsh restore behind integration flag`、`127cf11 fix(release): install Codex for real migration tests`、`b57b930 test(migration): isolate dsh attachment integration subtest`、`2aa2f07 fix(release): serialize Swift tests on hosted runners`，均已普通推送至 `origin/main`；本条由后续文档提交补记验证结果和实际哈希。

---

## [2026-11-17 21:04] README 项目首页与文档整理

- **需求/问题描述**：
  > 参照用户提供的 GitHub README 截图，改善项目介绍的排版与阅读体验。
- **实际实现的功能与改动**：
  - 添加 README 专用猫咪 SVG、居中标题、简介、平台/技术/构建徽章与导航，使用表格展示功能和支持来源。
  - 优先介绍功能、源码安装与首次使用；详细操作及开发/签名/测试/发布说明分别整理到使用指南和开发文档。
  - 修正年度热力图与可选预算说明；通过 GitHub API 确认暂无正式 Release，保留签名、隐私和未验证能力的限制。
  - SVG XML、9 个引用文件及 3 个章节目标、Git diff 格式检查通过；7 个外部入口与徽章均返回 HTTP 200。仅文档与标识资源变更，未执行应用测试、构建或截图/视觉检查。
- **涉及文件**：`README.md`、`docs/assets/ragdoll.svg`、`docs/USAGE.md`、`docs/DEVELOPMENT.md`、`memory/agents.md`、`memory/plan.md`、`memory/progress.md`、`memory/verify.md`、`docs/CHANGELOG.md`。
- **Git 提交**：`be4d3eb docs(readme): present project features and getting started`，已普通推送至 `origin/main`；本条由后续文档提交补记。

---

## [2026-11-17 21:13] 将猫咪标识设置为应用图标

- **需求/问题描述**：
  > 将 README 中的猫咪标识设置为 Ragdoll 应用图标。
- **实际实现的功能与改动**：
  - 复用现有 SVG，通过 AppKit 与 iconutil 生成标准多尺寸 `Ragdoll.icns`；设置 `CFBundleIconFile`，共享打包脚本复制图标到应用 Resources，本地和 CI 打包均使用该资源。
  - 10 个资源覆盖 16–1024 像素，透明圆角与 alpha 检查通过；8 项解包像素完全一致，16/32 像素传统资源仅半透明边缘颜色有系统转换差异，非透明主体一致。打包图标与源 ICNS 字节一致。
  - 实际 release 构建、有效 Apple Development 签名、深度签名和内置助手自检通过；Bash、plist 及 Git diff 检查通过，LaunchServices 注册新版元数据成功。
  - 未修改应用业务逻辑，未执行应用业务测试、Claude 测试或截图/视觉检查；Finder/Dock 实际显示未验证。
- **涉及文件**：`packaging/Ragdoll.icns`、`packaging/Info.plist`、`scripts/build.sh`、`memory/agents.md`、`memory/plan.md`、`memory/progress.md`、`memory/verify.md`、`docs/CHANGELOG.md`。
- **Git 提交**：`0ed9a13 feat(macos): use Ragdoll cat as application icon`，已普通推送至 `origin/main`；本条由后续文档提交补记。

---

## [2026-11-17 21:27] 系统提示词折叠与对话布局

- **需求/问题描述**：
  > 系统提示词默认折叠、点击展开，隐藏工具调用，对话界面参考用户提供的第三张图。
- **实际实现的功能与改动**：
  - system/developer 及独立注入上下文使用默认收起的系统提示词栏，展开保留完整可选择正文；包含实际用户请求的消息正常显示。
  - 对话界面隐藏工具消息及运行事件入口，过滤后按 100 条分页；原始消息、索引、搜索、归档和执行记录保留。
  - 用户消息改为右侧气泡和头像，助手使用左侧头像与无背景正文，时间靠近身份信息；输入框采用紧凑固定高度，保留附件、模型、发送和停止。
  - 新增 3 项分类/分页回归先因缺失展示入口编译失败，实现后通过；全部 44 项 Swift 测试通过（24.872 秒）。release 编译、临时签名预览构建、深度签名完整性和内置助手自检通过，Git diff 格式检查通过。
  - 开发证书签名返回 CSSMERR_TP_CERT_REVOKED；新版保存为 dist/Ragdoll.preview.app，原 dist/Ragdoll.app 已恢复，原可执行文件 SHA-256 不变且签名完整性校验通过。预览包不用于独立后台服务；未截图、验证实际点击或运行 Claude 测试。
- **涉及文件**：`Sources/Ragdoll/ConversationView.swift`、`Tests/RagdollTests/ConversationTests.swift`、`docs/USAGE.md`、`memory/agents.md`、`memory/plan.md`、`memory/progress.md`、`memory/verify.md`、`memory/gotchas.md`、`docs/CHANGELOG.md`。
- **Git 提交**：`29f1352 fix(chat): fold system prompts and hide tool calls`，已普通推送至 `origin/main`，远端 SHA 与本地一致；本条由后续文档提交补记。

---

## [2026-11-17 21:38] 添加 system prompt 总折叠项

- **需求/问题描述**：
  > 在会话详情中为系统提示词再增加一个名为 system prompt 的总折叠项。
- **实际实现的功能与改动**：
  - 连续的系统提示词归入默认收起的 `system prompt`，展开后保留各条系统提示词的独立折叠与全文选择；用户和助手消息顺序保留。
  - 隐藏工具后先分组、再按 100 项分页，避免截断提示词组；原始消息与存储保留，历史会话和对话共用实现。
  - 新增两项分组/分页回归先因缺少分组入口编译失败；实现后全部 46 项 Swift 测试通过（21.670 秒），release 构建及 Git diff 检查通过。
  - 更新 `dist/Ragdoll.preview.app`，临时签名完整性和内置助手自检通过；原正式包可执行文件 SHA-256 不变且签名完整性通过。预览包不用于独立后台服务；未验证实际点击或视觉效果，未执行 Claude 测试。
- **涉及文件**：`Sources/Ragdoll/ConversationView.swift`、`Tests/RagdollTests/ConversationTests.swift`、`docs/USAGE.md`、`memory/agents.md`、`memory/plan.md`、`memory/progress.md`、`memory/verify.md`、`docs/CHANGELOG.md`。
- **Git 提交**：`c40424f feat(chat): group system prompts under a parent disclosure`，已普通推送至 `origin/main`，远端 SHA 与本地一致；本条由后续文档提交补记。

---

## [2026-11-17 21:52] 核查台前调度图标并刷新应用登记

- **需求/问题描述**：
  > 台前调度中显示默认图标，没有显示 Ragdoll 猫咪图标。
- **实际实现的功能与改动**：
  - 核查当前预览包的 Info.plist、ICNS 和 LaunchServices 登记，均已包含猫咪图标；系统返回的运行中应用图标与资源一致。
  - 隔离 AppKit 应用正常启动后返回 256 像素快照，在相同尺寸下与包内图标摘要一致；未发现需要修改应用代码的图标加载缺陷。
  - 刷新预览包登记并正常重启，新进程完成启动且图标数据与资源一致；清理隔离复现应用及其登记。
  - 最终源码全部 46 项 Swift 测试通过（20.269 秒），正式包与预览包深度签名完整性通过，Git diff 格式检查通过。未重新打包、运行 Claude 测试或截图；台前调度实际显示是否恢复尚未确认。
- **涉及文件**：`memory/agents.md`、`memory/plan.md`、`memory/progress.md`、`memory/verify.md`、`memory/gotchas.md`、`docs/CHANGELOG.md`。
- **Git 提交**：`efdd80e docs(macos): record Stage Manager icon diagnostics`，已普通推送至 origin/main，远端 SHA 与本地一致；本条由后续文档提交补记。

---

## [2026-11-18 11:08] 改版对话工作区

- **需求/问题描述**：
  > 参考 Cherry Studio 的对话界面，左侧采用 Codex 的项目与子对话结构。
- **实际实现的功能与改动**：
  - 对话页使用紧凑导航，按完整工作目录组织对话。项目可折叠，搜索时展开命中项目，项目加号打开预填路径的新建表单。
  - 聊天区使用紧凑标题、居中消息列、原生主题色和独立输入框，保留迁移、恢复、附件、Agent 选项、发送与停止。历史会话保留平铺列表。
  - 49 项 Swift 测试、release 构建、临时签名、助手自检和隔离启动通过。使用 macOS 辅助功能验证项目展开折叠、打开子会话、搜索空结果、清除搜索及打开新建表单。未截图或调用原生 Agent 发送消息。
- **涉及文件**：`Sources/Ragdoll/RootView.swift`、`Sources/Ragdoll/ConversationView.swift`、`Sources/Ragdoll/ConversationProjectList.swift`、`Tests/RagdollTests/ConversationProjectTests.swift`、`docs/USAGE.md`、`docs/CHANGELOG.md`、`memory/plan.md`、`memory/progress.md`、`memory/verify.md`。
- **Git 提交**：待提交。

---

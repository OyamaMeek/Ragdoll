# 第一版新增功能实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现跨工具原生历史迁移、归档普通推送与重试、退出 GUI 后继续工作的用户级后台服务。

**Architecture:** 迁移由 TypeScript 读取完整原始记录并发布目标原生历史。Swift 核心层复用归档并增加推送和进程所有权；独立 Swift helper 运行扫描/归档循环，GUI 保留交互对话。

**Tech Stack:** Swift 6.1、SwiftUI、GRDB、ServiceManagement、Node 26、TypeScript、Git。

**Spec:** `docs/superpowers/specs/2026-11-16-v1-expansion-design.md`

**Status:** 实施及核心验证已完成；系统登录项已注册、实际启动及注销，外置 SSD 上的系统全流程受 TCC 授权限制。最终提交状态见 `memory/progress.md`。

## Global Constraints

- macOS 15+、Apple Silicon，中文，保留现有原生接入及 ACP。
- 不再运行 Claude 测试；不执行截图和视觉检查。
- 不覆盖目标历史，不修改或删除源记录；不兼容记录按用户授权转为全文历史文本。
- 不强制推送，不自动拉取或合并；失败保留本地提交。
- 保留工作区已有扫描修复及其测试，不纳入本任务提交。
- 用户“继续”授权本会话直接完成实施，不重复询问相同授权。

## Review Focus

- 多文件或压缩源、未知记录和附件不得在迁移时丢失；Task 1 验证未知块全文和源文件不变。
- 源会话在迁移时变化或目标冲突必须保留原数据；Task 1 验证拒绝覆盖和损坏输入。
- 没有新提交也应重试失败的推送；Task 2 验证 bare 远端重试及非快进拒绝。
- GUI 与后台竞争及服务异常退出不能同时归档；Task 3 验证进程锁释放、独立进程和请求恢复。
- 旧设置与迁移来源关联必须跨重启/扫描保留；Task 2/4 验证旧设置解码、来源元数据及用量不重复。

### Task 1: 原生历史迁移与运行时入口

**Files:** 新建 `runtime/src/migration.ts`、`runtime/test/migration.test.ts`；修改 `runtime/src/main.ts`、`runtime/src/types.ts`、`runtime/src/logs.ts`。

**Interfaces:** `migrateSession(value: unknown): Promise<Session>` 接收源 Session、目标 AgentConfig、目标 home 和 cwd；发布新会话及迁移来源清单，返回可供现有 `chat.start` 恢复的 Session。`migration` 可选元数据保留原 ID 和历史消费。

- [x] 真实文件测试先失败，再验证多轮消息、工具/推理全文、压缩历史、附件、目标不覆盖及损坏源拒绝。
- [x] 迁移测试使用明确文件及 `--test-skip-pattern='[Cc]laude'`，不执行 Claude 来源或目标测试。
- [x] 核实原生格式和目录注册，完成 JSON/JSONL/zstd 转换及来源清单；Codex/dsh 真实恢复及续聊通过。
- [x] 运行目标测试及 `npm run typecheck`，通过。
- [x] 初始运行时 `c82ebeb` 和审阅修正 `2ffdfc5` 已提交并普通推送。

### Task 2: 归档推送、失败保留与旧设置

**Files:** 新建 `Sources/RagdollCore/ArchiveSync.swift`、`Tests/RagdollCoreTests/ArchiveSyncTests.swift`；修改 `Models.swift`、`Store.swift`。

**Interfaces:** `ArchiveSync.push(root: URL, remote: String, branch: String) throws -> String` 执行指定目标的有限时普通推送。设置增加可选同步配置以兼容旧记录。来源元数据由 Store 保留，迁入的旧消费不重新计费。

- [x] 真实 bare 仓库覆盖失败后无新提交重试、明确分支、非快进拒绝及本地 HEAD 保留；旧设置解码通过。
- [x] 新接口及审阅回归已先确认失败，再修正为通过。
- [x] Git 参数校验、非交互认证、超时清理、错误脱敏和 migration 来源保留已实现。
- [x] Swift 相关测试通过，远端 HEAD 与本地匹配，拒绝时数据不变。
- [x] 归档推送核心随 `17e2a9a` 提交并普通推送。

### Task 3: 独立扫描归档服务与打包

**Files:** 新建 `Sources/RagdollCore/BackgroundService.swift`、`Sources/RagdollService/ServiceMain.swift`、`packaging/com.oyamameek.ragdoll.service.plist`、服务测试；修改 `Package.swift`、`scripts/build.sh`。

**Interfaces:** 核心层提供服务状态、原子刷新/归档请求和数据目录进程锁；helper 接受 `--data-dir`、`--once`，复用 RuntimeBridge、Store、Archive 和 ArchiveSync。服务状态包含 heartbeat、PID、本地归档及推送结果。

- [x] 真实锁和独立进程覆盖重复服务拒绝、退出释放锁、GUI 外扫描/归档及推送失败保留。
- [x] 相关 Swift 测试先确认目标问题失败，再验证修正；Node/索引故障均非零退出。
- [x] 用户级服务、单一所有者、设置重载、持久脏标记和推送重试已实现；使用 30 秒/最长 5 分钟归档调度。
- [x] 原子请求文件传递刷新/归档/重推，GUI 每两秒轮询状态，不增加通用 IPC 服务。
- [x] helper 与 LaunchAgent 已打包；独立进程在 GUI 未运行时索引/归档及推送成功。系统托管验证范围见最终验证记录。
- [x] 独立服务及打包随 `17e2a9a` 提交并普通推送。

### Task 4: GUI 入口与工作流

**Files:** 新建 `Sources/Ragdoll/MigrationView.swift`；修改 `AppModel.swift`、`ConversationView.swift`、`SettingsView.swift`、`RagdollApp.swift`。

**Interfaces:** `AppModel.migrateSelected(agent:cwd:authorizedAttachments:)` 调运行时迁移；后台启用时扫描/归档请求交给服务，GUI 重载索引和显示状态，未启用时保留原路径。

- [x] 复用真实核心回归验证迁移、旧设置及服务所有权。
- [x] 迁移目标/项目选择、附件授权、转换说明和 Claude 未验证标记已接入；设置包含推送预览、重试及后台状态。
- [x] SMAppService 注册与错误展示已接入；配置变化及交互聊天保存发出请求。
- [x] Swift 构建及核心测试通过；未执行视觉检查。
- [x] GUI 入口随 `4891b75` 提交并普通推送。

### Task 5: 完整检查与交付

**Files:** `README.md`、`docs/VALIDATION.md`、`docs/CHANGELOG.md`、`memory/`。

**Interfaces:** 使用上述真实入口，无替代实现或虚假成功。

- [x] TypeScript 检查通过；允许的 Node 测试 18 项通过、6 项跳过。
- [x] Swift 21 项测试函数、release 打包、签名校验及 helper 自检通过。
- [x] Codex/dsh 原生恢复及续聊通过；系统登录项注册、实际启动和注销通过，外置卷数据访问受 TCC 限制，未声称系统全流程成功。
- [x] 完成一次最终独立只读代码审阅，有效问题已在同一轮修复并验证。
- [x] 文档已记录实际结果与系统权限限制，功能及验证记录均已精确提交并普通推送。

# 验证记录

- 原生 SwiftUI 应用 debug/release 构建通过；已生成 `dist/Ragdoll.app`，官方 Node 26.13.0 下载校验与本地临时签名检查通过。
- 9 项 Swift 核心测试及新增继承历史去重检查通过：成本预算、夏令时热力图、真实数据库搜索、Git 提交隔离、外部暂存和手工修改保护、源目录隔离、ACP 别名去重，以及 1500 个会话/4501 个文件的大批归档。
- TypeScript 严格类型检查通过；日志、导入边界、ACP 状态及安装边界测试通过。
- Codex 0.147.0 app-server 真实握手及模型列表通过；使用目录中的默认可用模型，真实新建、保存、恢复同一 ID 与上下文续聊通过。用户全局配置的 gpt-6.1-sol 在当前 ChatGPT 账号下不可用，应用保留配置并提供模型选择，不自动替换。
- DeepSeek Harness 0.2.1-rc.5 真实新建、发送、停止、恢复同一 ID 与上下文续聊通过。
- 官方 Registry 的 Claude ACP 0.107.2 真实下载安装、校验与协议协商通过。
- dsh ACP 真实新建、v1 自动协商、停止、恢复同一 ID 与上下文续聊通过；v2 的消息替换和聚合终态按当前官方 schema 实现并完成静态审查。
- 真实终端进程忽略 SIGTERM 时，客户端清理升级 SIGKILL 的检查通过；Codex 缓存写入不重复计数检查通过。
- Claude Code 真实对话未通过，原始错误为未登录。用户随后要求后续只完成 Claude 代码，不继续运行 Claude 测试。
- 官方 Claude 导出包仅完成格式边界验证，未取得用户导出包进行实测。
- 未进行截图或视觉检查，未验证 Intel、Windows、Linux。
- 已实际启动打包应用，隔离数据目录成功索引至少 267 个本机 Codex 会话；未通过截图或窗口自动化检查视觉效果。
- 独立静态审查发现的归档并发、暂存隔离、大批路径、进程退出、ACP 状态及配置保留问题已修正。
- 未实测 Registry Python 分发、用户登录交互和图片附件；Claude 按用户要求仅完成后续代码和静态修正，不再运行测试。

## 2026-11-17 会话扫描卡住修复

- 修复前采样确认 `RuntimeBridge` 反复搜索完整大消息缓冲区，持续占用一个 CPU 核心。
- 真实助手传输约 16 MB Unicode 正文的回归先因 8 秒扫描超时失败；修复后验证完整正文、相邻短消息与后续响应，测试用时小于 1 秒。
- 全部 11 项 Swift 测试通过；`bash scripts/build.sh` 完成 release 构建、打包、本地签名校验及助手自检。
- 修复后的真实 Swift 通信代码完整扫描本机 701 个 Codex 会话，用时 15.6 秒，最大单会话正文共 144,558,178 字节，扫描警告为零。
- 已直接启动新版 `.app`；应用采样 CPU 约 2%，主线程及通信读取线程均处于等待状态。未执行截图、窗口自动化和 Claude 接入测试。

## 2026-11-17 原生迁移、远端推送与后台服务

- 允许的 Node 测试 18 项通过、6 项跳过；TypeScript 严格检查通过。命令从 `runtime` 运行：`node --test --test-skip-pattern='[Cc]laude' test/acp-state.test.ts test/integration.test.ts test/logs.test.ts test/registry.test.ts test/migration.test.ts`，随后 `npm run typecheck`。不运行 Claude 导出测试文件。
- Codex 0.147.0 与 dsh 0.2.1-rc.5 均实际恢复迁移后的原生历史，并在续聊中返回旧历史的校验码；这两项以 `RAGDOLL_MIGRATION_LIVE=codex` / `dsh` 单独运行。dsh 使用当前 v4 zstd 历史格式。
- 真实文件回归覆盖多轮消息、工具/推理全文、压缩历史、JSON/图片附件、外部附件授权、二次迁移重新复制及映射附件、源文件不变、损坏/缺失原始历史拒绝、目标与旧 sidecar 不覆盖、home 身份及旧用量保留。工具输出中的任意文件 URI 不会被当成附件读取。
- Swift 测试 21 项函数通过（其中依赖故障测试有两组参数）：真实数据库、旧设置、ACP 来源关联、进程锁、独立服务、Git 多地址拒绝、普通推送、无新提交重试、非快进拒绝、有限超时与预览脱敏。
- 独立 helper 在 GUI 未运行时完成扫描和本地归档，随后新增日志仍被索引及归档；重启后即使手工编辑阻止新的归档，仍能单独推送已有提交。强制终止 Node 或破坏索引表时，服务以失败码退出并释放所有权。
- 完整变更经过独立只读代码审阅；有效问题在同一修复轮次中用 RED→GREEN 回归修正，未重复派发审阅。
- release 构建、helper 打包、内置 Node 自检及深度签名校验通过；最终 `dist/Ragdoll.app` 使用本机 Apple Development 身份签名，未公证。隔离的打包 helper 实际使用包内 Node 完成扫描、归档和推送。
- 系统登录项测试使用独立应用标识和项目内数据，不修改用户的 Ragdoll 设置。`SMAppService` 注册及注销成功；Apple Development 签名且使用产品相同的无 stderr 文件配置时，`launchctl` 确认 helper 已由 launchd 启动。默认临时签名曾被系统签名校验拒绝，构建脚本因此支持 `CODE_SIGN_IDENTITY`。
- **系统托管下的完整归档流程未通过**：本项目位于外置 SSD，隔离 helper 在打开其 SQLite 文件时等待；系统 TCC 日志显示对该测试应用的目录访问请求未获授权。未更改隐私权限。独立进程完整流程已通过，系统托管流程仅确认注册、实际启动及注销，不能视为扫描/归档/推送已完成。所有测试登录项已注销。
- 按用户限制，涉及 Claude 的迁移方向仅实现代码并在产品标注未验证；未执行截图和视觉检查。没有验证注销后重新登录、Intel、Windows、Linux 或 Developer ID 公证分发。

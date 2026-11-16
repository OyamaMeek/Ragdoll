# 实施进度

- [x] 初始化工程、真实格式样本与历史读取。
- [x] Swift 索引与会话浏览；完整 SwiftUI 应用已编译。
- [x] 首页、成本和预算；9 项 Swift 核心测试及新增继承历史去重检查通过。
- [x] Git 全量/增量归档与提交；已验证不带入外部暂存、无空提交、手工修改保护。
- [x] 三种原生接入代码：Codex 与 dsh 真实新建/恢复/上下文续聊通过；Claude 未登录，按用户要求停止测试并完成代码。
- [x] ACP 协议、本地与 Registry、历史导入、动态配置及认证入口；官方 Claude ACP 安装协商、dsh ACP 真实对话恢复通过。
- [x] Claude 导出包导入及格式边界；尚无用户官方导出包实测。
- [x] debug/release 打包、签名及助手检查；实际启动索引至少267个本机Codex会话；独立静态审查问题已修正。
- [x] 功能提交 `f762527 feat(macos): add session analytics, git archive and ACP chat` 已推送至 `origin/main`；最终验证与提交记录随补记提交保存。

## 用户最新要求

- Claude 接入完成代码即可，后续不再运行 Claude 测试。真实续聊验证保留未完成状态；不要求用户代为测试。

## 环境事实

- 初始提交 18e3793；main 跟踪 origin/main；仓库原本只有 AGENTS.md。
- macOS 15.7.7，Swift 6.1.2，Xcode 16.4；Node 26.13.0。
- Codex 0.147.0、Claude Code 2.1.268；DeepSeek Harness.app 0.2.1-rc.5，dsh 不在 PATH，但应用包内包含运行入口。
- 没有既存测试、项目技能或构建脚本。

## 实施决定

- 使用 Swift Package 与打包脚本生成 .app；无需用户安装工程生成工具。
- npm 发布的 dsh SDK 客户端早于当前协议；通过 dsh 官方 SDK JSON-RPC 接口直接连接，已用安装的 dsh 验证恢复，删除未使用的旧客户端依赖。
- Swift 和真实 Codex 测试需要沙箱外构建/状态目录写入权限，已通过自动审批运行；普通沙箱失败不能判定为实现不兼容。
- ACP v2 按聚合状态等待完成，不能把 prompt 的入队响应当作对话完成；不将上下文占用量当作消费 Token。
- 使用 generation 保留归档运行期间到达的变更；Git 路径清单写入受管理的临时 pathspec 文件，避免 ARG_MAX；保留外部暂存和排除项目修改。
- 原生会话与已确认来源的 ACP 会话按来源、home、会话 ID 关联，统计一次，保留两类原始记录。
- 未执行视觉检查、Registry Python/登录交互/图片附件实测；详见 docs/VALIDATION.md。

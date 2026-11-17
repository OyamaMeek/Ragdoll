# Ragdoll

原生 macOS 会话管理应用：读取 Codex、Claude Code、DeepSeek Harness 历史，查看 Token 热力图与成本预算，迁移原生历史，自动归档并推送 Git 远端。支持原生续聊、通用 ACP 命令、官方 ACP Registry 及独立后台服务。

## 运行

需要 macOS 15+、Apple Silicon。开发环境需要 Xcode 16.4+、Swift 6.1 和 Node 26。

```sh
bash scripts/build.sh
open dist/Ragdoll.app
```

安装包内包含 Node 和 SDK 助手，运行应用无需另装 Node。首次构建下载并校验 Node 官方发行包。默认使用本地临时签名；系统后台服务需要应用和 helper 使用同一个有效 Apple 签名身份，可用 `CODE_SIGN_IDENTITY` 指定后构建。构建脚本不进行 Apple 公证。

开发运行：先在 `runtime` 执行 `npm ci`，再运行 `bash scripts/dev.sh`。

## 发布

推送 `vX.Y.Z` 版本标签后，[Release macOS workflow](https://github.com/OyamaMeek/Ragdoll/actions/workflows/release.yml) 自动编译、检查并发布到 [GitHub Releases](https://github.com/OyamaMeek/Ragdoll/releases)。例如：

```sh
git tag v0.1.0
git push origin v0.1.0
```

每个版本附带 `Ragdoll-macos-arm64.zip` 和 `.zip.sha256` 校验文件，应用版本与标签一致。下载后在同一目录运行 `shasum -a 256 -c Ragdoll-macos-arm64.zip.sha256`，解压并将 `Ragdoll.app` 移入“应用程序”。只支持 macOS 15+、Apple Silicon。

在 Actions 中选择 **Release macOS → Run workflow** 可手动验证；选择分支时只保存构建产物，选择 `vX.Y.Z` 标签时发布 Release。已有 Release 不会被覆盖。发布使用自动提供的 `GITHUB_TOKEN`，无需新增仓库密钥。

CI 构建使用临时签名，未经 Apple 公证，首次打开可能受到 Gatekeeper 限制；独立后台服务需要有效 Apple 签名。TypeScript 检查、允许的 Node 测试、Swift 测试、解压后的签名校验及内置助手自检全部通过后才发布，Claude 测试继续按项目约定排除。

## 使用

- **首页**：最近 7 个本地自然日的小时热力图、项目用量、估算成本及滚动 168 小时预算。
- **会话**：自动读取 `CODEX_HOME`、`CLAUDE_CONFIG_DIR`、`DSH_HOME` 或默认目录，支持正文搜索和历史分页。
- **对话**：选择项目与原生 Agent 或 ACP Agent。各工具保留自己的登录和会话，恢复失败时显示具体原因。
- **会话 → 迁移**：选择目标原生工具及项目目录，生成新的目标原生会话。普通消息保留原生格式；推理、工具及不兼容记录按来源完整显示为历史文本。原始日志和复制的附件另行保留，源会话不变；项目外附件需用文件选择器明确授权。Codex 与 dsh 已实测恢复及续聊，涉及 Claude 的方向在界面标为未验证。
- **设置 → Agent 与 ACP**：添加本地命令，或浏览官方目录安装 Agent。环境变量存入钥匙串；目录安装固定版本，更新由用户触发。Python Agent 需要 `uv`。
- **首次启动**：必须选择本地专用 Git 仓库，也可选择空目录创建仓库；完成前不扫描或导入会话。已配置后打开直接显示主界面和已有会话缓存，仓库读取状态显示在侧栏底部；读取完成后再检查本机新增数据并自动保存、提交。仓库路径失效或读取失败时保留主界面，可在侧栏重试或通过设置重选，期间不会写入归档。
- **设置 → Git 归档**：可更换专用仓库。完整会话快照、原始记录和 Markdown 一起保存；SQLite 用于索引，较旧的本机记录不会覆盖较新的历史。旧归档优先复用原生日志恢复；无法恢复原始消息结构时完整展示 Markdown 并提示。需要 Git 已配置 `user.name` 和 `user.email`。可显式开启远端推送，检查实际地址、分支及已跟踪范围后启用；推送会上传该分支的完整 Git 历史。失败保留本地归档，自动重试，也可单独重试已有提交；远端分歧需要自行处理，不自动拉取、合并或强制推送。多个 push URL 会被拒绝；暂不支持远端专属的 `pushOption`、`receivepack` 配置。
- **设置 → Git 归档 → 独立后台服务**：在打包应用中开启用户级登录项，退出 GUI 后仍扫描、归档和重试推送；注销时停止，下次登录恢复。系统要求时在“登录项与扩展”中允许；外置磁盘及受保护目录还需系统授予访问权限。后台不执行交互聊天或代为批准工具权限。未开启时使用应用内调度。
- **Claude 普通聊天**：导入官方 ZIP 或 `conversations.json`，更新时重新导入；续聊打开原聊天。

数据与索引保存于 `~/Library/Application Support/Ragdoll`。归档包含对话正文及工具输出，可能包含敏感信息；应用不导出登录凭据。推送复用系统 Git 凭据和 SSH 配置，以非交互方式执行，单次最长 90 秒。

成本是按当前模型单价计算的估算值，缺失价格和用量显示未知。缓存时长、长上下文、服务层级及历史调价会影响准确度。ACP 的上下文占用量不计入消费 Token。

## 验证

Swift 验证包含真实助手的大消息传输回归；先安装 runtime 依赖并运行 `npm --prefix runtime run build`，再运行 `swift test`。助手检查使用 `npm --prefix runtime run typecheck`。真实连接和对话检查需要对应工具已经登录；需要本机 DeepSeek Harness 的迁移恢复测试与续聊测试统一通过 `RAGDOLL_MIGRATION_LIVE=dsh` 开启，云端构建默认跳过。实际执行记录见 [docs/VALIDATION.md](docs/VALIDATION.md)。按照用户要求，Claude 接入后续仅完成代码，不继续运行 Claude 测试。

本项目读取 `references` 中的格式与实现思路。参考项目不随应用源码提交，样本出处见 [docs/THIRD_PARTY.md](docs/THIRD_PARTY.md)。

# Ragdoll

原生 macOS 会话管理应用：读取 Codex、Claude Code、DeepSeek Harness 历史，查看 Token 热力图与成本预算，自动归档到本地 Git 仓库。支持原生续聊、通用 ACP 命令及官方 ACP Registry。

## 运行

需要 macOS 15+、Apple Silicon。开发环境需要 Xcode 16.4+、Swift 6.1 和 Node 26。

```sh
bash scripts/build.sh
open dist/Ragdoll.app
```

安装包内包含 Node 和 SDK 助手，运行应用无需另装 Node。首次构建下载并校验 Node 官方发行包。构建产物为本地临时签名，尚未进行开发者签名与 Apple 公证。

开发运行：先在 `runtime` 执行 `npm ci`，再运行 `bash scripts/dev.sh`。

## 使用

- **首页**：最近 7 个本地自然日的小时热力图、项目用量、估算成本及滚动 168 小时预算。
- **会话**：自动读取 `CODEX_HOME`、`CLAUDE_CONFIG_DIR`、`DSH_HOME` 或默认目录，支持正文搜索和历史分页。
- **对话**：选择项目与原生 Agent 或 ACP Agent。各工具保留自己的登录和会话，恢复失败时显示具体原因。
- **设置 → Agent 与 ACP**：添加本地命令，或浏览官方目录安装 Agent。环境变量存入钥匙串；目录安装固定版本，更新由用户触发。Python Agent 需要 `uv`。
- **设置 → Git 归档**：选择专用仓库；初次保存全部历史，后续自动合并变化并本地提交。需要 Git 已配置 `user.name` 和 `user.email`，不推送远端。
- **Claude 普通聊天**：导入官方 ZIP 或 `conversations.json`，更新时重新导入；续聊打开原聊天。

数据与索引保存于 `~/Library/Application Support/Ragdoll`。应用退出后停止扫描和自动归档。归档包含对话正文及工具输出，可能包含敏感信息；应用不导出登录凭据。

成本是按当前模型单价计算的估算值，缺失价格和用量显示未知。缓存时长、长上下文、服务层级及历史调价会影响准确度。ACP 的上下文占用量不计入消费 Token。

## 验证

Swift 验证包含真实助手的大消息传输回归；先安装 runtime 依赖并运行 `npm --prefix runtime run build`，再运行 `swift test`。助手检查使用 `npm --prefix runtime run typecheck`。真实连接和对话检查需要对应工具已经登录。实际执行记录见 [docs/VALIDATION.md](docs/VALIDATION.md)。按照用户要求，Claude 接入后续仅完成代码，不继续运行 Claude 测试。

本项目读取 `references` 中的格式与实现思路。参考项目不随应用源码提交，样本出处见 [docs/THIRD_PARTY.md](docs/THIRD_PARTY.md)。

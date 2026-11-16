# 第三方依赖与样本

- GRDB.swift 7.6.1：MIT，https://github.com/groue/GRDB.swift
- ACP TypeScript SDK 2.7.0：Apache-2.0，https://github.com/agentclientprotocol/typescript-sdk
- Claude Agent SDK：遵循 npm 包内 LICENSE，https://github.com/anthropics/claude-agent-sdk-typescript
- fflate：MIT；node-tar：ISC。安装包保留依赖目录内的许可证。
- Node.js 官方 macOS arm64 发行包：包内包含 LICENSE、第三方声明及 npm。
- ACP Registry：Apache-2.0；从官方 CDN 获取条目，各 Agent 遵循其自身许可证。
- `runtime/test/fixtures` 中的 Claude/Codex 原生格式样本和 dsh 目录来自 `references/magpie/internal/sessions/testdata`。magpie 采用 MIT，https://github.com/yetone/magpie 。完整声明见 `runtime/test/fixtures/LICENSE.magpie`。`codex-cache-write.jsonl` 是 Ragdoll 自身的计数边界样本。
- 设计与实现参考 codex-tools（https://github.com/170-carry/codex-tools）、magpie 和 t3code（https://github.com/pingdotgg/t3code）。未复制这些项目的应用界面代码。

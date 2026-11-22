# 第三方依赖与样本

- GRDB.swift 7.6.1：MIT，https://github.com/groue/GRDB.swift
- Node.js 官方 macOS arm64 发行包：包内包含 LICENSE、第三方声明及 npm。
- eventsource-parser 4.1.3：MIT，https://github.com/rexxars/eventsource-parser 。用于解析 Codex 激活请求的 SSE 响应，许可随运行依赖打包。
- `runtime/test/fixtures` 中的 Claude/Codex 原生格式样本和 dsh 目录来自 `references/magpie/internal/sessions/testdata`。magpie 采用 MIT，https://github.com/yetone/magpie 。完整声明见 `runtime/test/fixtures/LICENSE.magpie`。`codex-cache-write.jsonl` 是 Ragdoll 自身的计数边界样本。
- 设计与实现参考 codex-tools（https://github.com/170-carry/codex-tools）、magpie 和 t3code（https://github.com/pingdotgg/t3code）。未复制这些项目的应用界面代码。

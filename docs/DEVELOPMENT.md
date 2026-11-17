# 开发文档

[返回 README](../README.md) · [使用指南](USAGE.md)

## 环境要求

- macOS 15+、Apple Silicon。
- Xcode 16.4+、Swift 6.1、Node 26。
- Git；真实连接和对话检查需要对应原生工具已安装并登录。

## 构建与运行

在仓库根目录执行：

```sh
bash scripts/build.sh
open dist/Ragdoll.app
```

脚本安装 runtime 依赖、构建 release 应用，并下载、校验和打包 Node 官方发行包。安装包内包含 Node 和 SDK 助手，运行打包应用无需另装 Node。

开发运行：

```sh
npm --prefix runtime ci
bash scripts/dev.sh
```

## 签名与后台服务

默认构建使用本地临时签名，不进行 Apple 公证，首次打开可能受到 Gatekeeper 限制。

系统后台服务需要应用与 helper 使用同一个有效 Apple 签名身份。可在构建时指定本机已有身份：

```sh
CODE_SIGN_IDENTITY="你的有效 Apple 签名身份" bash scripts/build.sh
```

签名不替代系统目录访问权限。外置磁盘及受保护目录仍需授权，后台服务的验证限制见[验证记录](VALIDATION.md)。

## 检查

从仓库根目录执行：

```sh
npm --prefix runtime ci
npm --prefix runtime run build
npm --prefix runtime run typecheck
swift test --disable-sandbox --no-parallel
```

Swift 验证包含真实助手的大消息传输回归，需要先构建 runtime。迁移测试还需要可用的 `codex` 命令；CI 安装固定版本 `@openai/codex@0.147.0`。

从 `runtime` 目录运行允许的 Node 测试：

```sh
node --test --test-skip-pattern='[Cc]laude' test/acp-state.test.ts test/integration.test.ts test/logs.test.ts test/migration.test.ts test/registry.test.ts
```

需要本机 DeepSeek Harness 的迁移恢复及续聊测试通过 `RAGDOLL_MIGRATION_LIVE=dsh` 开启，云端构建默认跳过。Claude 的真实对话与相关迁移方向尚未验证；当前检查范围排除 Claude 测试及导出包测试文件。实际执行结果见[验证记录](VALIDATION.md)。

## 自动发布

推送 `vX.Y.Z` 版本标签后，[Release macOS workflow](https://github.com/OyamaMeek/Ragdoll/actions/workflows/release.yml) 自动编译、检查并发布到 [GitHub Releases](https://github.com/OyamaMeek/Ragdoll/releases)。例如：

```sh
git tag v0.1.0
git push origin v0.1.0
```

每个版本附带 `Ragdoll-macos-arm64.zip` 和 `.zip.sha256` 校验文件，应用版本与标签一致。下载后在同一目录运行：

```sh
shasum -a 256 -c Ragdoll-macos-arm64.zip.sha256
```

校验后解压并将 `Ragdoll.app` 移入“应用程序”。发布构建只支持 macOS 15+、Apple Silicon。

在 Actions 中选择 **Release macOS → Run workflow** 可手动验证；选择分支时只保存构建产物，选择 `vX.Y.Z` 标签时发布 Release。已有 Release 不会被覆盖。发布使用自动提供的 `GITHUB_TOKEN`，无需新增仓库密钥。

CI 构建使用临时签名，未经 Apple 公证；独立后台服务需要有效 Apple 签名。TypeScript 检查、允许的 Node 测试、Swift 测试、解压后的签名校验与内置助手自检全部通过后才发布。

## 第三方参考

本项目读取 `references` 中的格式与实现思路。参考项目不随应用源码提交，样本出处见[第三方参考与出处](THIRD_PARTY.md)。

# 实施进度

## 台前调度图标（2026-11-17）

- [x] 确认当前预览包的 ICNS 与源资源一致、LaunchServices 登记正确；运行中应用图标与包内资源一致。
- [x] 隔离 AppKit 启动返回 256 像素快照；统一到 256 像素后，原有 applicationIconImage 与包内资源摘要完全一致，无需应用代码改动。最终源码全部 46 项 Swift 测试通过（20.269 秒）。
- [x] 刷新预览包的 LaunchServices 登记并正常重启，旧进程已退出，新进程 64318 完成启动，图标摘要与资源一致；正式包和预览包深度签名完整性通过。台前调度实际显示未截图验证，尚不能确认用户所见异常已消失。
- [x] `efdd80e docs(macos): record Stage Manager icon diagnostics` 已普通推送至 origin/main，远端 SHA 与本地一致；本条和开发记录由后续文档提交补记。

## system prompt 总折叠项（2026-11-17）

- [x] 确认共用 ConversationView 当前逐条折叠；调用和测试均在该视图与 ConversationTests，没有项目测试技能目录。
- [x] 记录连续分组、总折叠项与先分组后分页的范围和验证标准。
- [x] 新增两项回归先因 conversationGroups 缺失编译失败；接入默认收起的 system prompt，保留内部逐条折叠，过滤工具后先分组再分页。
- [x] 全部 46 项 Swift 测试通过（21.670 秒），release 构建通过；更新 dist/Ragdoll.preview.app，临时签名完整性及内置助手自检通过。原正式包签名完整性通过且可执行文件 SHA-256 不变。未验证实际点击或视觉效果，未运行 Claude 测试。
- [x] `c40424f feat(chat): group system prompts under a parent disclosure` 已普通推送至 origin/main，远端 SHA 与本地一致；本条及开发记录由后续文档提交补记。

## 会话消息展示（2026-11-17）

- [x] 确认日志和存储保留消息 role/kind；问题位于共用 ConversationView 的角色标记、工具渲染和分页。
- [x] 记录系统提示词折叠、工具隐藏、参考图布局与数据保留范围。
- [x] 分类和分页回归先因展示入口缺失编译失败；实现后 3 项通过。系统提示词默认收起、工具过滤后分页、右侧用户气泡/左侧助手正文及紧凑输入框已接入共用视图。
- [x] 全部 44 项 Swift 测试通过（24.872 秒），release 编译通过。开发证书返回 CSSMERR_TP_CERT_REVOKED；临时签名预览构建、深度签名完整性及内置助手自检通过，保存为 dist/Ragdoll.preview.app。原 dist/Ragdoll.app 已恢复，可执行文件 SHA-256 与构建前一致且签名完整性校验通过。未截图、验证实际点击或运行 Claude 测试，预览包不用于独立后台服务。
- [x] `29f1352 fix(chat): fold system prompts and hide tool calls` 已普通推送至 origin/main，远端 SHA 与本地一致；本条和开发记录由后续文档提交补记。

## macOS 应用图标（2026-11-17）

- [x] 读取 SVG、Info.plist、本地与 CI 打包入口；PlistBuddy 查询 CFBundleIconFile 因字段不存在失败，确认当前未配置图标。
- [x] 确定将现有猫咪标识转为多尺寸 ICNS，提交静态资源并由共享打包脚本复制，无需应用逻辑或依赖改动。
- [x] 使用 AppKit 渲染 SVG 并以 iconutil 生成 149,203 字节 ICNS；配置 CFBundleIconFile 与打包复制，不改变 SVG。
- [x] 检查 10 个图标资源/7 种尺寸、透明度及应用包内资源一致性；Bash、两份 plist 与 Git diff 检查通过。有效 Apple Development 签名 release 构建、深度签名和内置助手自检通过，已注册新版应用元数据。未执行应用业务测试、Claude 测试或截图。
- [x] `0ed9a13 feat(macos): use Ragdoll cat as application icon` 已普通推送至 `origin/main`；本条及开发记录由后续文档提交补记。

## README 项目首页（2026-11-17）

- [x] 读取现有 README、功能源码、构建/发布流程和验证记录；GitHub API 确认当前暂无正式 Release，仓库没有图标及项目许可证文件。
- [x] 确定按参考图使用居中标识、徽章、功能表格和导航，保留中文，细节分入使用与开发文档；记录范围及验证标准。
- [x] 重写 README，添加居中猫咪 SVG、平台与 CI 徽章、导航及功能/来源表格，整理使用与开发文档；明确暂无 Release，保留签名、隐私和未验证能力说明。
- [x] `xmllint --noout`、9 个引用文件/3 个章节目标检查及 `git diff --check` 通过；7 个外部入口与徽章均返回 HTTP 200，功能文案与源码及已有验证记录一致。追加开发记录，未执行应用测试、构建或视觉检查。
- [x] `be4d3eb docs(readme): present project features and getting started` 已普通推送到 `origin/main`；实际提交哈希与结果通过后续文档提交补记。

## GitHub Actions 自动发布（2026-11-17）

- [x] 确认现有 ARM64 打包脚本、Node 26.13.0、macOS 15 最低版本，以及 main 跟踪 origin/main；仓库没有既有 workflow 或版本标签。
- [x] 添加标签发布与手动构建 workflow，补充版本号、下载校验、签名限制和手动运行说明。
- [x] actionlint 与全部 workflow shell 语法检查通过；实际执行版本准备步骤，验证有效标签、分支、无效标签和注入文本四种情况。
- [x] 本机 TypeScript 检查通过、默认 Node 测试 21 项通过/8 项跳过、Swift 41 项通过；本机显式开启 DeepSeek Harness 的附件二次迁移与恢复测试共 3 项通过（含父测试）。临时签名 release 打包、ZIP 解压后的权限/架构/深度签名/内置助手检查及 SHA-256 校验通过。
- [x] 配置提交 `87fcafa chore(release): build macOS app and publish tagged releases` 已普通推送至 origin/main；GitHub 已识别 workflow，并通过 API 触发手动构建。
- [x] 首次云端运行 `44080690086` 在 Node 校验步骤因缺少 rg 退出（127）；改用系统 grep 后，官方 Node 下载包的 SHA-256 校验通过。修正提交 `695e547 fix(build): use system grep for Node checksum verification` 已普通推送。
- [x] 本机专属 DeepSeek Harness 测试沿用现有 RAGDOLL_MIGRATION_LIVE 开关，默认跳过，显式开启的真实恢复与缺少凭据断言仍通过。
- [x] 测试环境约束提交 `d6b1dbc test(migration): gate local dsh restore behind integration flag` 已普通推送；云端运行 `44081815064` 的应用打包通过，迁移测试因缺少 codex 命令失败。
- [x] `127cf11 fix(release): install Codex for real migration tests` 已普通推送；云端运行 `44082707141` 的工具安装、打包和 Codex 断言通过，附件测试中的 dsh 二次迁移因 runner 未安装该应用失败。
- [x] 完整复查测试入口，将附件测试中的 dsh 二次迁移独立为受现有开关控制的子测试，保留云端附件、符号链接及缺失文件断言；本机默认与显式开启两种测试均通过。
- [x] `b57b930 test(migration): isolate dsh attachment integration subtest` 已普通推送；云端运行 `44083771421` 的构建与 Node 检查通过。Swift 测试编译 48 秒完成，执行阶段长时间未结束，取消后日志确认多组 helper 存活。
- [x] 本机显式串行运行全部 41 项 Swift 测试，20.038 秒通过；workflow 语法检查通过。
- [x] `2aa2f07 fix(release): serialize Swift tests on hosted runners` 已普通推送；云端运行 [44085972714](https://github.com/OyamaMeek/Ragdoll/actions/runs/44085972714) 整体成功。TypeScript、Node 21 项通过/8 项跳过、Swift 41 项通过（50.844 秒）、ZIP 解压签名/助手/SHA-256 校验和 artifact 上传通过。
- [x] 核对 artifact `14328654532`，名称 Ragdoll-macos-arm64，78,091,772 字节且未过期；分支运行的 Publish release 按条件跳过，未创建标签或发布版本。正式标签发布尚未实测。
- [x] 本机 dist/Ragdoll.app 已恢复为原证书签名版本并通过深度校验；CI 临时签名测试产物单独保存在被忽略的 .agent 目录。最终验证和提交哈希随本次文档补记保存。

## 启动时立即显示主界面（2026-11-17）

- [x] 确认设置页使用 !archiveLoaded 判定，导致已配置仓库仍被全屏读取页遮挡；侧栏已经有状态小字。
- [x] 新回归先出现五个失败断言，覆盖首帧、加载期、失败后的页面判定和缓存保留。
- [x] 仅未配置时显示设置页，复用侧栏小字及错误重试；保持读取优先与失败后禁止扫描/写入。全部 41 项 Swift 测试通过。
- [x] release 打包、Apple Development 深度签名及助手自检通过；已在原数据目录重新启动新版。未新增截图、窗口交互或视觉检查。
- [x] 功能提交 `8f9280c fix(startup): show cached interface while reading archive` 已普通推送至 `origin/main`；实际哈希由本次文档提交补记。

## 首次设置与仓库优先启动（2026-11-17）

- [x] 确认 GUI 启动读取本机索引后直接扫描，选择仓库立即写入；后台也没有恢复仓库入口。
- [x] 完整快照回归先因有源文件时没有 events.json 失败；新增启动/恢复接口回归先因入口缺失失败；旧日志覆盖较新历史回归先出现两个失败断言。
- [x] 实现完整快照、旧原始 JSONL/gzip 读取及安全恢复；保留完整旧 Markdown，验证身份、消息和用量，以及较新的本机记录不被覆盖。
- [x] 接入首次设置页、启动/切换门槛和后台读取顺序；真实 AppModel 设置和独立后台进程验证未设置不扫描、坏仓库不写入、历史与新增会话同时保留。
- [x] 全部 40 项 Swift 测试通过；允许的 Node 测试 22 项通过、6 项跳过，TypeScript 检查通过。
- [x] release 打包、Apple Development 深度签名及内置助手自检通过；隔离启动后实际读取所选仓库，核对 787 份完整会话快照。已结束验证实例，并以原正式数据目录重新启动新版应用。
- [x] 功能提交 `7e60a35 feat(startup): require git setup and restore archive before scanning` 已普通推送至源码 `origin/main`；实际哈希随本次文档补记保存。

## 图片独立归档与实际推送（2026-11-17）

- [x] 确认应用 archiveRemote 为空，远端为空；用户明确同意公开上传。
- [x] 两个超限文件来自同一会话：原始 JSONL 153,308,643 字节，Markdown 144,583,047 字节；工具返回内嵌 base64 图片。
- [x] 图片剥离、去重、相对引用、events.json 及大文件压缩回归先失败，已实现共享归档逻辑；无效图片示例保留原文。
- [x] 图片和源日志完整、手工修改保护与重复归档回归通过；全部 31 项 Swift 测试、release 打包、Apple Development 签名和助手自检通过。
- [x] 未上传历史完整备份到 `.agent/archive-before-images.bundle` 并通过 bundle verify，应用数据库备份到 `.agent/archive-settings-before-images.sqlite`。新版打包 helper 完成 812 个会话扫描及实际归档。
- [x] 全量核对 3,776 个受管理文件摘要、1,394 个独立图片和 785 份 Markdown；原超限 Markdown 降至 1,616,677 字节，源日志 gzip 为 104,436,682 字节，解压后 SHA-256 与源文件一致。最新树没有超限文件。
- [x] 归档旧历史保留在本地 `archive-before-publish` 分支与 bundle；相同树创建首次上传提交 `c75b3ed`，已普通推送至公开 `origin/main`，远端 SHA 完全一致。
- [x] 已在备份后保存应用 archiveRemote 为 origin/main，并启动新版 Ragdoll。
- [x] 新版应用实际归档及按设置自动推送成功；通过纯文本辅助功能调用 File → 立即归档，远端 main 与应用提交 `0b25b2b4fe5128a101aaa03d4b6b8273c6d87dca` 完全一致，sync-pending 已清除。未截图或检查视觉效果。
- [x] 开发记录已更新；功能提交 `287eec3 feat(archive): extract inline images into separate files` 已普通推送源码 origin/main，实际哈希随文档补记保存。

## 最近会话日期文字（2026-11-17）

- [x] 用户明确要求替换每条会话右侧的时分秒；右上角恢复“全部”导航，列表不按日期筛选。
- [x] 两项日期标签回归先出现 11 个失败断言；实现今天、昨日、本周、本月及更早具体日期，恢复“全部”入口与未按日期筛选的列表。
- [x] 全部 41 项 Swift 测试通过；release 打包、Apple Development 深度签名及助手自检通过。未新增截图或视觉检查。
- [x] 已启动新版并确认进程。
- [x] 功能提交 `0fe88f7 fix(dashboard): show calendar labels for session dates` 已普通推送至 `origin/main`；实际哈希随本次开发记录补记保存。

## Codex 会话小标题（2026-11-17）

- [x] 确认首页及列表共用 Session.title，在共享扫描层读取 Codex 已有小标题。
- [x] 四项新增回归先因旧实现显示 AGENTS.md 指令失败，覆盖索引、多 home、归档、独立改名、名称清空/删除、损坏记录及正文摘要。
- [x] 采用每会话名称与文件联合指纹，改名只更新对应会话；无名称时提取实际提问，完整消息保持不变。
- [x] Node 测试 22 项通过、6 项跳过，TypeScript 检查通过；本机 711 个 Codex 会话中 582 个保存名称全部匹配，指令标题和 warning 均为零，二次扫描只发送 1 个正在变化的会话。
- [x] release 打包、Apple Development 深度签名及助手自检通过，新版应用进程已启动；实际 SQLite 索引中 555 个保存名称全部一致。剩余 1 条指令标题对应的源日志已删除且无保存名称，保留历史记录；未截图或执行窗口交互验证。
- [x] 功能提交 `9e48ec8 fix(logs): read saved Codex session titles` 已普通推送至 `origin/main`；实际哈希随开发记录补记保存。

## 热力图颜色与悬停（2026-11-17）

- [x] 读取参考图、日汇总、界面、图例、点击入口与构建流程。
- [x] 新增 UI 测试入口；浮层类型缺失先编译失败，接入文本后旧色板因颜色与亮度断言失败。
- [x] 实现两种主题递增亮度与悬停浮层；全部 26 项 Swift 测试通过。
- [x] release 打包、Apple Development 深度签名与助手自检通过；新版应用进程已启动。未执行窗口悬停或截图验证。
- [x] 功能提交 `e8fa96a fix(dashboard): lighten heatmap and show hover usage` 已普通推送至 `origin/main`；实际哈希随开发记录补记保存。

## 每周预算显示开关（2026-11-17）

- [x] 确认预算卡片、设置分类与 SQLite 配置机制；默认隐藏，保留已有金额。
- [x] 配置保存测试先因字段丢失失败；接入设置“首页”分类与首页整卡显示条件，旧配置默认隐藏。
- [x] 全部 24 项 Swift 测试通过；release 打包、Apple Development 深度签名和助手自检通过，新版应用已启动。未执行截图或窗口交互测试。
- [x] 功能提交 `afc5245 feat(settings): toggle weekly budget visibility` 已普通推送至 `origin/main`；实际哈希随开发记录补记保存。

## 年度热力图调整（2026-11-17）

- [x] 确认参考图、现有小时统计、点击筛选及清除入口。
- [x] 历史日期回归先失败（20/30 Token），改为本地日汇总；年度网格覆盖跨年、闰日、DST、范围外空格和未来日期。
- [x] 界面采用每日绿色方格、月份与星期标签、五级图例和右侧年份选择；点击筛选当天会话，保留清除入口。
- [x] 全部 23 项 Swift 测试通过；release 打包、Apple Development 签名、深度校验和助手自检通过，新版应用已重新启动且进程持续运行；未执行截图或视觉核对。
- [x] 功能提交 `557d871 feat(dashboard): show annual contribution heatmap` 已普通推送至 `origin/main`；实际哈希由后续文档提交补记。

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

- [x] 修复“正在读取会话…”持续占用 CPU：`RuntimeBridge` 仅搜索新收到的数据，避免重复扫描大消息缓冲区。
- [x] 真实助手大消息回归先因请求超时失败，修复后大段 Unicode 正文、相邻短消息与后续响应均通过；11 项 Swift 测试通过。
- [x] release 打包、签名及助手检查通过；本机 Codex 完整扫描 701 个会话耗时 15.6 秒，最大会话正文约 145 MB，警告为零；新版应用已运行，采样 CPU 约 2%，读取线程等待新数据。
- [x] 扫描修复提交 `98348dd fix(runtime): prevent scans stalling on large messages` 已普通推送至 `origin/main`，实际哈希由后续文档提交补记。

- 三项全部纳入第一版：跨工具迁移、远端归档同步、独立后台常驻服务。
- 迁移必须生成目标工具的原生历史，可在目标工具直接打开完整旧会话。
- 用户允许将目标无法原生表示的推理或工具记录完整转换为带来源标记的历史文本，其他消息仍按目标原生格式保存。
- 同步采用自动推送指定 Git 远端，失败保留本地归档并支持重试。
- Claude 接入完成代码即可，后续不再运行 Claude 测试。真实续聊验证保留未完成状态；不要求用户代为测试。

## 新增范围进度

- [x] 读取现有模型、归档、运行时、调度、打包及测试，明确用户选择。
- [x] 独立设计审阅已完成；补充迁移最低成功标准、用户授权的全文文本转换，以及产品中的 Claude 未验证标记。
- [x] 用户“继续”授权实施；已写实施计划并添加产品代码。
- [x] Codex/dsh 原生迁移和来源/用量关联已实现，两种目标均已真实恢复旧历史并在续聊中返回历史校验码；Claude 按既有限制不测试。
- [x] Git 普通推送、无新提交重试、非快进拒绝、有限超时和脱敏预览核心测试通过。
- [x] 独立服务、调度所有权、打包及 GUI 未运行时的扫描/归档/推送已验证；系统注册和启动已验证，外置 SSD 上的系统全流程受 TCC 限制。
- [x] 完成检查、文档、功能提交和普通推送；系统权限造成的验证限制已记录。

### 本轮验证与交付

- 允许的 Node 测试 18 项通过、6 项跳过，TypeScript 检查通过；Codex/dsh 迁移后真实续聊各通过一项，dsh 缺失凭据回归已 RED→GREEN。
- Swift 21 项测试函数通过，含持续后台处理、重启后独立重推、Node/索引故障非零退出、坏锁、唯一推送地址和超时保护。GUI 及 release 打包通过。
- 独立审阅提出的附件来源、多 pushurl、二次迁移、消息重复、旧 sidecar、home 身份、配置快照、Node 退出、独立重推及锁错误均已在同一轮修复并验证，不重复派审阅者。
- 隔离打包 helper 使用包内 Node 完成扫描/归档/推送；系统登录项注册、launchd 实际启动、注销成功。外置 SSD 数据的 TCC 请求未获授权，系统全流程未通过；未更改隐私权限。
- 迁移初次提交 `c82ebeb`、修正提交 `2ffdfc5` 已普通推送至 `origin/main`。
- `CODE_SIGN_IDENTITY` 最终 release 构建、深度签名校验及助手自检通过；产物使用 Apple Development 签名，未公证。后台核心 `17e2a9a` 已普通推送。
- GUI 及最终文档 `4891b75` 已普通推送，实际功能提交哈希均已补记；无剩余产品代码修改。系统托管完整流程仍受既述 TCC 授权限制，Claude 与视觉检查保持未验证。

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

## 对话工作区（2026-11-18）

- [x] 确认主导航及共用 ConversationView 调用、索引搜索和按更新时间排序行为，读取本地 Cherry Studio 的设计说明。
- [x] 项目分组回归先因缺少分组入口编译失败，实现后通过真实 SQLite 索引检索。
- [x] 项目侧栏、紧凑导航和聊天区已接入。49 项 Swift 测试、release 构建、预览签名、助手自检和隔离启动通过。
- [x] 隔离预览用 macOS 辅助功能检查了 56 点导航、项目展开折叠、选择会话、搜索空结果和清除搜索。确认从项目首次打开新建表单时预填完整路径，取消后可进入历史会话页。
- [x] 独立编译暂存内容并通过项目分组回归。本轮代码提交为 `6bbd748` 和 `7a576f8`，保留既有头像改动的待提交状态。

## 输入框模型选择（2026-11-18）

- [x] 确认两页共用 AgentOptionsView，现有清单只在恢复后可用，模型值由所有会话共享。读取本机 Codex 生成的模型清单、配置读取和逐轮推理强度定义。
- [x] Swift 先因缺少按会话选择而编译失败，真实 Codex 回归先因读取结果缺少有效模型设置而失败。已接入选择与逐轮请求。
- [x] TypeScript 类型检查、允许的 Node 测试（22 项通过，7 项跳过）、release 构建、预览签名和助手自检通过。
- [x] 50 项 Swift 测试通过。隔离预览通过辅助功能验证在历史会话恢复前打开真实模型清单、选择模型、设置推理强度和切回默认。
- [x] `0b52738 feat(chat): add Codex model and reasoning picker` 已普通推送至 `origin/main`，并核对远端提交。

## 读取 ACP 会话模型（2026-11-18）

- [x] 核查 ACP v1/v2 文档、固定 SDK 和实际 DeepSeek Harness 的分组模型及强度选项。
- [x] Swift 回归先因缺少模型解析而失败，真实 ACP 回归先因未转发 Agent 的确认响应而失败。现已接入会话清单、选择和更新。
- [x] 51 项 Swift 测试、23 项 Node 测试、TypeScript 检查、发布构建、签名与助手自检通过。隔离预览从已保存的 DeepSeek ACP 会话自动发现模型，并在 Agent 确认后更新推理强度。
- [x] `a1bdcd1 feat(acp): discover models from active sessions` 已普通推送至 `origin/main`，并核对远端提交。

## 原生 Codex 模型目录（2026-11-19）

- [x] 在同一 Codex home 和项目目录实测，PATH 中的 0.147.0 返回三个模型，桌面随附 CLI 返回十个，包含配置的 `gpt-6.2-sol`。
- [x] 真实 app-server 回归先因默认版本不符而失败。统一进程入口后，默认查询、桌面 CLI 和新建会话的模型目录一致。
- [x] 51 项 Swift 测试、21 项常规 Node 测试、1 项真实 Codex 回归和 TypeScript 检查通过。发布编译通过，原开发证书被系统判定已撤销，单独生成临时签名预览包。包内助手查询到 10 个模型，并确认显式命令和 PATH 仍生效。
- [x] `12cff7f fix(codex): use desktop model catalog` 已普通推送至 `origin/main`。

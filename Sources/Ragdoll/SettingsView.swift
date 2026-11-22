import SwiftUI
import RagdollCore
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab = 0
    @State private var prices = ""
    @State private var remoteName = "origin"
    @State private var remoteBranch = "main"
    @State private var remotePreview = ""
    @State private var checkedRemote: ArchiveRemote?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("设置").font(.largeTitle.bold())
            Picker("设置分类", selection: $tab) {
                Text("数据来源").tag(0); Text("Git 用量备份").tag(1); Text("模型价格").tag(2); Text("首页").tag(3)
            }.pickerStyle(.segmented).frame(maxWidth: 600)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch tab {
                    case 0: sources
                    case 1: archive
                    case 2: pricing
                    default:
                        Card { Toggle("显示每周预算", isOn: Binding(get: { model.settings.showWeeklyBudget == true }, set: { model.settings.showWeeklyBudget = $0; model.persistSettings() })).toggleStyle(.switch) }
                    }
                }.frame(maxWidth: 1050, alignment: .leading).padding(.vertical, 10)
            }
        }.padding(28).navigationTitle("设置")
        .onAppear {
            do { prices = try JSONValue.encode(model.settings.prices).text } catch { model.error = error.localizedDescription }
            remoteName = model.settings.archiveRemote?.remote ?? "origin"; remoteBranch = model.settings.archiveRemote?.branch ?? "main"
            model.pollBackground()
        }
        .onChange(of: model.settings.archivePath) { _, _ in checkedRemote = nil; remotePreview = "" }
    }
    private var sources: some View {
        Group {
            Card {
                VStack(alignment: .leading, spacing: 18) {
                    Text("本地会话目录").font(.headline)
                    Text("首次读取历史用量，之后自动扫描变化。仅保存会话信息和 Token 明细；源日志保持只读。").font(.callout).foregroundStyle(.secondary)
                    ForEach(Array(model.settings.locations.enumerated()), id: \.offset) { i, location in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(sourceName(location.source)).frame(width: 140, alignment: .leading)
                                TextField("目录", text: Binding(get: { model.settings.locations[i].path }, set: { model.settings.locations[i].path = $0 })).textFieldStyle(.roundedBorder).disabled(model.warmingCodexHome != nil)
                                Button("选择…") { if let path = model.chooseProject() { model.settings.locations[i].path = path } }.disabled(model.warmingCodexHome != nil)
                                if location.source == "codex" {
                                    Button { Task { await model.warmupCodex(location.path) } } label: {
                                        Label(model.warmingCodexHome == location.path ? "正在激活…" : "激活 5h 窗口", systemImage: "flame")
                                    }.disabled(!model.ready || model.warmingCodexHome != nil || model.codexAccountsBusy || location.path.isEmpty)
                                }
                            }
                            if location.source == "codex", let result = model.codexWarmupResults[location.path] {
                                Text(result).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                    Text("激活使用对应 Codex 目录的 ChatGPT 登录，发送一次 hello，会消耗少量额度。已激活或额度耗尽时跳过；不会重置已有窗口，结果以服务端为准。").font(.caption).foregroundStyle(.secondary)
                    HStack { Spacer(); Button("保存并扫描") { model.persistSettings(); Task { await model.refresh() } }.buttonStyle(.borderedProminent).disabled(model.scanning) }
                }
            }
            if !model.warnings.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("最近读取提示").font(.headline)
                        ForEach(Array(model.warnings.suffix(15).enumerated()), id: \.offset) { _, warning in Text(warning).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }
    private var archive: some View {
        Group {
            Card {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Git 用量自动备份").font(.headline)
                    Text("启动时先读取仓库中的历史用量，再检查本机新增记录。保存每个会话的 Token 明细和活动报告，自动创建本地提交。").foregroundStyle(.secondary)
                    HStack {
                        Text(model.settings.archivePath.isEmpty ? "尚未选择目录" : model.settings.archivePath).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Spacer(); Button("选择专用仓库…") { model.chooseArchive() }.disabled(model.scanning || model.archiving || model.loadingArchive)
                    }
                    Text(model.archiveStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack {
                        if let date = model.lastArchive { Text("上次完成：\(date.formatted())").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if model.archiving { ProgressView().controlSize(.small) }
                        Button("立即备份用量") { Task { await model.archiveNow() } }.buttonStyle(.borderedProminent).disabled(model.archiving || model.settings.archivePath.isEmpty)
                    }
                    Text("自动保存采用 30 秒防抖，最长合并 5 分钟；手工修改会阻止覆盖。旧版本的会话归档及 Git 历史继续保留。首次迁移旧索引会生成 index.sqlite.before-usage 恢复副本，该副本仍包含正文并占用空间，确认用量完整后可手动移走或删除。").font(.caption).foregroundStyle(.secondary)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("远端推送").font(.headline)
                    Text("推送包含所选分支的全部历史；沿用旧仓库时，历史可能含正文及附件。认证沿用系统 Git，失败保留本地提交并自动重试。").font(.caption).foregroundStyle(.secondary)
                    HStack { TextField("远端名称", text: $remoteName); TextField("目标分支", text: $remoteBranch) }.textFieldStyle(.roundedBorder)
                    if !remotePreview.isEmpty { Text(remotePreview).font(.caption).textSelection(.enabled) }
                    Text(model.syncStatus).font(.caption).textSelection(.enabled)
                    HStack {
                        Button("检查推送目标") {
                            let draft = ArchiveRemote(remote: remoteName, branch: remoteBranch), path = model.settings.archivePath
                            Task { do {
                                let preview = try await Task.detached { try ArchiveSync.preview(root: URL(fileURLWithPath: path), remote: draft.remote, branch: draft.branch) }.value
                                guard model.settings.archivePath == path, remoteName == draft.remote, remoteBranch == draft.branch else { return }
                                remotePreview = preview; checkedRemote = draft
                            } catch { checkedRemote = nil; model.error = error.localizedDescription } }
                        }.disabled(model.settings.archivePath.isEmpty)
                        Button("保存并启用自动推送") { model.configureArchiveRemote(ArchiveRemote(remote: remoteName, branch: remoteBranch)) }.disabled(checkedRemote != ArchiveRemote(remote: remoteName, branch: remoteBranch))
                        if model.settings.archiveRemote != nil { Button("停用推送") { model.configureArchiveRemote(nil) }; Button("立即重试") { Task { await model.retryPush() } } }
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("独立后台服务").font(.headline)
                    Text("当前用户登录期间持续扫描、备份和推送用量，退出 Ragdoll 后继续运行。需要有效的 Apple 签名及相关目录访问权限。").font(.caption).foregroundStyle(.secondary)
                    Text(model.backgroundStatus).font(.caption)
                    HStack {
                        Button(model.settings.backgroundEnabled == true ? "停用后台服务" : "启用后台服务") { Task { await model.setBackground(model.settings.backgroundEnabled != true) } }
                        Button("打开系统登录项") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("备份范围").font(.headline)
                    Text("取消选择的项目仍可统计用量，其后续变化不写入备份；已有备份保留。").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.projects, id: \.self) { project in
                        Toggle(project, isOn: Binding(get: { !model.settings.excludedProjects.contains(project) }, set: { include in
                            model.settings.excludedProjects.removeAll { $0 == project }; if !include { model.settings.excludedProjects.append(project) }; model.persistSettings(refreshArchive: true)
                        })).toggleStyle(.checkbox).font(.caption)
                    }
                }
            }
        }
    }
    private var pricing: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text("模型价格（USD / 百万 Token）").font(.headline)
                Text("可按实际提供方修正；没有匹配价格的模型显示未知。缓存、上下文长度、服务层级和历史调价可能影响估算。").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $prices).font(.system(size: 11, design: .monospaced)).frame(minHeight: 400).border(.quaternary)
                HStack { Spacer(); Button("保存价格表") {
                    do {
                        let result = try JSONDecoder().decode([String: Price].self, from: Data(prices.utf8))
                        guard result.values.allSatisfy({ [$0.input, $0.output, $0.cacheRead, $0.cacheWrite].allSatisfy { $0.isFinite && $0 >= 0 } }) else { model.error = "价格必须是非负有限数字"; return }
                        model.settings.prices = result; model.persistSettings(refreshArchive: true)
                    } catch { model.error = "价格表无效：\(error.localizedDescription)" }
                }.buttonStyle(.borderedProminent) }
            }
        }
    }
}

import SwiftUI
import AppKit
import RagdollCore
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab = 0
    @State private var editor: AgentConfig?
    @State private var showRegistry = false
    @State private var historyAgent: AgentConfig?
    @State private var prices = ""
    @State private var remoteName = "origin"
    @State private var remoteBranch = "main"
    @State private var remotePreview = ""
    @State private var checkedRemote: ArchiveRemote?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("设置").font(.largeTitle.bold())
            Picker("设置分类", selection: $tab) {
                Text("数据来源").tag(0); Text("Agent 与 ACP").tag(1); Text("Git 归档").tag(2); Text("模型价格").tag(3); Text("首页").tag(4)
            }.pickerStyle(.segmented).frame(maxWidth: 600)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch tab {
                    case 0: sources
                    case 1: agents
                    case 2: archive
                    case 3: pricing
                    default:
                        Card {
                            Toggle("显示每周预算", isOn: Binding(get: { model.settings.showWeeklyBudget == true }, set: { model.settings.showWeeklyBudget = $0; model.persistSettings() })).toggleStyle(.switch)
                        }
                    }
                }.frame(maxWidth: 1050, alignment: .leading).padding(.vertical, 10)
            }
        }.padding(28).navigationTitle("设置")
        .sheet(item: $editor) { agent in AgentEditor(agent: agent).environmentObject(model) }
        .sheet(isPresented: $showRegistry) { RegistryView().environmentObject(model) }
        .sheet(item: $historyAgent) { agent in NativeHistoryView(agent: agent).environmentObject(model) }
        .onAppear {
            prices = (try? JSONValue.encode(model.settings.prices).text) ?? "{}"
            remoteName = model.settings.archiveRemote?.remote ?? "origin"; remoteBranch = model.settings.archiveRemote?.branch ?? "main"
            model.pollBackground()
        }
        .onChange(of: model.settings.archivePath) { _, _ in checkedRemote = nil; remotePreview = "" }
    }
    var sources: some View {
        Group {
            Card {
                VStack(alignment: .leading, spacing: 18) {
                    Text("本地会话目录").font(.headline)
                    Text("首次读取全部历史，之后自动扫描变化。源日志只读；应用中的新对话通过各工具自己的接口保存。").font(.callout).foregroundStyle(.secondary)
                    ForEach(Array(model.settings.locations.enumerated()), id: \.offset) { i, location in
                        HStack {
                            Text(sourceName(location.source)).frame(width: 140, alignment: .leading)
                            TextField("目录", text: Binding(get: { model.settings.locations[i].path }, set: { model.settings.locations[i].path = $0 })).textFieldStyle(.roundedBorder)
                            Button("选择…") { if let path = model.chooseProject() { model.settings.locations[i].path = path } }
                        }
                    }
                    HStack { Spacer(); Button("保存并扫描") { model.persistSettings(); Task { await model.refresh() } }.buttonStyle(.borderedProminent).disabled(model.scanning) }
                }
            }
            Card {
                HStack {
                    VStack(alignment: .leading, spacing: 8) { Text("Claude 普通聊天").font(.headline); Text("导入官方 ZIP 或 conversations.json；不含原始上传附件，缺失用量显示未知。").font(.caption).foregroundStyle(.secondary) }
                    Spacer(); Button("导入官方导出包…") { model.importDesktop() }
                }
            }
            if !model.warnings.isEmpty {
                Card { VStack(alignment: .leading, spacing: 10) { Text("最近读取与连接提示").font(.headline); ForEach(Array(model.warnings.suffix(15).enumerated()), id: \.offset) { _, warning in Text(warning).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary) } } }
            }
        }
    }
    var agents: some View {
        Group {
            HStack {
                VStack(alignment: .leading, spacing: 6) { Text("对话提供方").font(.headline); Text("原生接口与 ACP 共用聊天界面；登录和模型能力由 Agent 提供。").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("添加本地 ACP") { editor = AgentConfig(name: "新 ACP Agent", command: "") }
                Button("浏览官方目录") { showRegistry = true }.buttonStyle(.borderedProminent)
            }
            ForEach(model.settings.agents) { agent in
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: agent.kind == "acp" ? "puzzlepiece.extension" : "cpu").font(.title2).foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 4) { Text(agent.name).font(.headline); Text("\(agent.kind == "acp" ? "ACP" : "原生接口")\(agent.version.map { " · \($0)" } ?? "")").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if model.busyAgents.contains(agent.id) { ProgressView().controlSize(.small) }
                            Button("检测连接") { Task { await model.probe(agent) } }.disabled(model.busyAgents.contains(agent.id))
                            Button("编辑") { editor = agent }
                            if agent.kind == "codex" || agent.kind == "claude" { Button("登录…") { Task { await model.nativeLogin(agent) } } }
                            if agent.kind == "acp" { Button("导入历史") { if let project = model.chooseProject() { Task { await model.listNative(agent, project: project); historyAgent = agent } } } }
                            if agent.kind == "acp" { Button("移除", role: .destructive) { Task { await model.removeAgent(agent) } } }
                        }
                        Text(([agent.command] + agent.args).joined(separator: " ")).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        if let info = model.agentInfo[agent.id] {
                            let methods = info["authMethods"].array.isEmpty ? info["auth"]["methods"].array : info["authMethods"].array
                            if !methods.isEmpty {
                                HStack {
                                    Text("登录：").font(.caption)
                                    ForEach(Array(methods.enumerated()), id: \.offset) { _, method in Button(method["name"].string) { Task { await model.authenticate(agent, methodID: method["methodId"].string.isEmpty ? method["id"].string : method["methodId"].string) } }.disabled(model.busyAgents.contains(agent.id)) }
                                }
                            }
                            DisclosureGroup("连接信息与能力") { Text(info.text).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        }
                    }
                }
            }
            if !model.loginLinks.isEmpty { Card { VStack(alignment: .leading, spacing: 8) { Text("登录链接").font(.headline); ForEach(model.loginLinks, id: \.self) { url in Link("打开登录页面 · \(url.host ?? "")", destination: url) } } } }
        }
    }
    var archive: some View {
        Group {
            Card {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Git 自动归档").font(.headline)
                    Text("启动时先读取 Git 仓库的历史，再检查本机新增数据。保存完整会话、原始记录、Markdown 和元数据；自动创建本地提交，可开启指定远端的自动推送。").foregroundStyle(.secondary)
                    HStack { Text(model.settings.archivePath.isEmpty ? "尚未选择目录" : model.settings.archivePath).font(.system(.caption, design: .monospaced)).textSelection(.enabled); Spacer(); Button("选择专用仓库…") { model.chooseArchive() }.disabled(model.scanning || model.archiving || model.loadingArchive || !model.running.isEmpty) }
                    Text(model.archiveStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack {
                        if let date = model.lastArchive { Text("上次完成：\(date.formatted())").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if model.archiving { ProgressView().controlSize(.small) }
                        Button("立即归档") { Task { await model.archiveNow() } }.buttonStyle(.borderedProminent).disabled(model.archiving || model.settings.archivePath.isEmpty)
                    }
                    Text("Markdown 内嵌图片保存为独立文件并使用相对路径引用；超过 50 MiB 的原始文件无损压缩为 gzip。自动保存采用 30 秒防抖，最长合并 5 分钟。源文件删除后保留已有归档；手工修改会阻止自动覆盖。Git 需要已配置提交者姓名与邮箱。").font(.caption).foregroundStyle(.secondary)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("远端归档推送").font(.headline)
                    Text("推送包含所选 Git 分支的全部历史及对话内容，请使用专用归档仓库。认证沿用系统 Git；失败保留本地提交并自动重试，远端分歧不会强制覆盖。").font(.caption).foregroundStyle(.secondary)
                    HStack { TextField("远端名称", text: $remoteName); TextField("目标分支", text: $remoteBranch) }.textFieldStyle(.roundedBorder)
                    if !remotePreview.isEmpty { Text(remotePreview).font(.caption).textSelection(.enabled) }
                    Text(model.syncStatus).font(.caption).textSelection(.enabled)
                    HStack {
                        Button("检查推送目标") {
                            let draft = ArchiveRemote(remote: remoteName, branch: remoteBranch), path = model.settings.archivePath
                            Task { do {
                                let preview = try await Task.detached { try ArchiveSync.preview(root: URL(fileURLWithPath: path), remote: draft.remote, branch: draft.branch) }.value
                                guard model.settings.archivePath == path, remoteName == draft.remote, remoteBranch == draft.branch else { return }
                                remotePreview = preview
                                checkedRemote = draft
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
                    Text("当前用户登录期间持续扫描、归档和推送，退出 Ragdoll 后继续运行。后台不执行交互对话。").font(.caption).foregroundStyle(.secondary)
                    Text("后台运行需要有效的 Apple 签名；外置磁盘及受保护目录还需系统授予访问权限。").font(.caption).foregroundStyle(.secondary)
                    Text(model.backgroundStatus).font(.caption)
                    HStack {
                        Button(model.settings.backgroundEnabled == true ? "停用后台服务" : "启用后台服务") { Task { await model.setBackground(model.settings.backgroundEnabled != true) } }
                        Button("打开系统登录项") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("排除项目").font(.headline)
                    Text("取消选择的项目仍可浏览和统计，其后续变化不写入归档；已有归档不会删除。").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.projects, id: \.self) { project in
                        Toggle(project, isOn: Binding(get: { !model.settings.excludedProjects.contains(project) }, set: { include in
                            model.settings.excludedProjects.removeAll { $0 == project }; if !include { model.settings.excludedProjects.append(project) }; model.persistSettings(refreshArchive: true)
                        })).toggleStyle(.checkbox).font(.caption)
                    }
                }
            }
        }
    }
    var pricing: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text("模型价格（USD / 百万 Token）").font(.headline)
                Text("内置表记录官方标准价格和核实日期。可按实际提供方修正；没有精确匹配的模型显示未知。缓存时长、上下文长度、服务层级和历史调价可能影响估算。").font(.caption).foregroundStyle(.secondary)
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

struct AgentEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State var agent: AgentConfig
    @State private var arguments = ""
    @State private var environment = ""
    @State private var failedToLoad = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("配置 \(agent.kind == "acp" ? "ACP Agent" : agent.name)").font(.title2.bold())
            Form {
                TextField("名称", text: $agent.name)
                TextField("程序路径或命令", text: $agent.command)
                LabeledContent("参数（每行一项）") { TextEditor(text: $arguments).font(.system(.caption, design: .monospaced)).frame(height: 80) }
                LabeledContent("环境变量（NAME=value）") { TextEditor(text: $environment).font(.system(.caption, design: .monospaced)).frame(height: 100) }
                if agent.kind == "acp" {
                    Picker("协议", selection: Binding(get: { agent.protocol ?? 0 }, set: { agent.protocol = $0 == 0 ? nil : $0 })) { Text("自动协商").tag(0); Text("ACP v1").tag(1); Text("ACP v2（实验性）").tag(2) }
                }
            }
            Text("直接运行程序，不展开 Shell 表达式。环境变量保存到系统钥匙串，不写入会话归档。").font(.caption).foregroundStyle(.secondary)
            HStack { Button("取消") { dismiss() }; Spacer(); Button("保存") { save() }.buttonStyle(.borderedProminent).disabled(agent.name.isEmpty || agent.command.isEmpty || failedToLoad) }
        }.padding(28).frame(width: 640)
        .onAppear {
            arguments = agent.args.joined(separator: "\n")
            do { let env = try Secrets.load(agent.id).merging(agent.env) { old, _ in old }; environment = env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n") }
            catch { failedToLoad = true; model.error = error.localizedDescription }
        }
    }
    func save() {
        do {
            var env: [String: String] = [:]
            for line in environment.components(separatedBy: .newlines) where !line.isEmpty {
                guard let separator = line.firstIndex(of: "=") else { model.error = "环境变量每行必须为 NAME=value"; return }
                let name = String(line[..<separator]); guard name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else { model.error = "无效的环境变量名称"; return }
                env[name] = String(line[line.index(after: separator)...])
            }
            agent.args = arguments.components(separatedBy: .newlines).filter { !$0.isEmpty }; agent.env = env
            try model.saveAgent(agent); dismiss()
        } catch { model.error = error.localizedDescription }
    }
}

struct RegistryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var search = ""
    var entries: [JSONValue] { model.registry.filter { search.isEmpty || ($0["name"].string + $0["description"].string).localizedCaseInsensitiveContains(search) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("ACP 官方目录").font(.title2.bold()); Spacer(); if model.registryLoading { ProgressView().controlSize(.small) }; Button("刷新") { Task { await model.loadRegistry() } }; Button("完成") { dismiss() } }
            Text("Agent 在本机执行，使用自己的账号和权限。安装前可查看项目来源及许可证；更新不会自动进行。").font(.caption).foregroundStyle(.secondary)
            TextField("搜索 Agent", text: $search).textFieldStyle(.roundedBorder)
            List(Array(entries.enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack { Text(entry["name"].string).font(.headline); Text(entry["version"].string).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }
                        Text(entry["description"].string).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        HStack { if let url = URL(string: entry["repository"].string) { Link("项目来源", destination: url) }; if let url = URL(string: entry["license_url"].string) { Link("许可证", destination: url) } }.font(.caption)
                    }
                    Spacer()
                    let installed = model.settings.agents.first { $0.registryID == entry["id"].string }
                    if model.busyAgents.contains(entry["id"].string) { ProgressView().controlSize(.small) }
                    Button(installed == nil ? "安装" : installed?.version == entry["version"].string ? "已安装" : "更新") { Task { await model.installAgent(entry) } }.disabled(model.busyAgents.contains(entry["id"].string) || installed?.version == entry["version"].string)
                }.padding(.vertical, 10)
            }
        }.padding(24).frame(width: 850, height: 650).task { if model.registry.isEmpty { await model.loadRegistry() } }
    }
}

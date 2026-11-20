import SwiftUI
import RagdollCore

struct SessionUsageView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("会话用量").font(.largeTitle.bold())
                Spacer()
                Picker("来源", selection: $model.source) {
                    Text("全部来源").tag("all")
                    ForEach(Array(Set(model.sessions.map(\.source))).sorted(), id: \.self) { Text(sourceName($0)).tag($0) }
                }.frame(width: 180)
                Picker("项目", selection: $model.project) {
                    Text("全部项目").tag("")
                    ForEach(model.projects, id: \.self) { Text(URL(fileURLWithPath: $0).lastPathComponent).tag($0) }
                }.frame(width: 160)
            }
            TextField("搜索会话名称、项目或会话 ID", text: $model.query).textFieldStyle(.roundedBorder)
            if let day = model.heatmapFilter {
                HStack { Text("\(day.formatted(date: .abbreviated, time: .omitted)) 的会话").font(.caption); Button("清除日期筛选") { model.heatmapFilter = nil } }
            }
            HSplitView {
                List(selection: $model.selectedID) {
                    ForEach(model.filtered) { session in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(session.title).lineLimit(2)
                            HStack {
                                Text(sourceName(session.nativeSource ?? session.source))
                                Text(session.projectName).lineLimit(1)
                                Spacer()
                                Text(session.usage.isEmpty ? "用量未知" : "\(compact(session.tokens)) Token").monospacedDigit()
                            }.font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 6).tag(session.id)
                    }
                }.frame(minWidth: 260, idealWidth: 330)
                if let session = model.filtered.first(where: { $0.id == model.selectedID }) {
                    details(session).frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("选择会话查看 Token 明细", systemImage: "chart.bar.doc.horizontal").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.padding(28).navigationTitle("会话用量")
        .onChange(of: model.query) { _, _ in do { try model.reload() } catch { model.error = error.localizedDescription } }
    }
    private func details(_ session: Session) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(session.title).font(.title2.bold()).textSelection(.enabled)
                Text(session.nativeID).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                Text(session.project.isEmpty ? "未关联项目" : session.project).font(.caption).textSelection(.enabled)
                Text("\(sourceName(session.nativeSource ?? session.source)) · 更新于 \(Date(timeIntervalSince1970: session.updated / 1000).formatted())").font(.caption).foregroundStyle(.secondary)
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(session.usage.isEmpty ? "用量未知" : "\(session.tokens.formatted()) Token").font(.title2.bold())
                        LabeledContent("输入", value: session.usage.reduce(0) { $0 + $1.input }.formatted())
                        LabeledContent("输出", value: session.usage.reduce(0) { $0 + $1.output }.formatted())
                        LabeledContent("缓存读取", value: session.usage.reduce(0) { $0 + $1.cacheRead }.formatted())
                        LabeledContent("缓存写入", value: session.usage.reduce(0) { $0 + $1.cacheWrite }.formatted())
                    }.monospacedDigit()
                }
                Text("用量记录 · \(session.usage.count) 条").font(.headline)
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(session.usage) { usage in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(usage.model.isEmpty ? "未知模型" : usage.model); Spacer(); Text("\(usage.tokens.formatted()) Token").monospacedDigit() }
                            Text(Date(timeIntervalSince1970: usage.time / 1000).formatted()).font(.caption).foregroundStyle(.secondary)
                            Text("输入 \(usage.input.formatted()) · 输出 \(usage.output.formatted()) · 缓存读取 \(usage.cacheRead.formatted()) · 缓存写入 \(usage.cacheWrite.formatted())").font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                    }
                }
                ForEach(Array(session.warnings.enumerated()), id: \.offset) { _, warning in Text(warning).font(.caption).foregroundStyle(.secondary) }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

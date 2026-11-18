import SwiftUI
import RagdollCore

struct ConversationProject: Identifiable {
    let id: String
    let name: String
    let sessions: [Session]

    static func group(_ sessions: [Session]) -> [Self] {
        var byPath = Dictionary(grouping: sessions, by: \.project)
        let unassigned = byPath.removeValue(forKey: "")
        var projects = sessions.compactMap { session -> Self? in
            guard let members = byPath.removeValue(forKey: session.project) else { return nil }
            return Self(id: session.project, name: session.projectName, sessions: members)
        }
        if let unassigned, let first = unassigned.first {
            projects.append(Self(id: first.project, name: first.projectName, sessions: unassigned))
        }
        return projects
    }
}

struct ConversationProjectList: View {
    let sessions: [Session]
    @Binding var selection: String?
    let selectedProject: String?
    let running: Set<String>
    let searching: Bool
    let createChat: (String) -> Void
    @State private var expansion: [String: Bool] = [:]

    var body: some View {
        let projects = ConversationProject.group(sessions)
        if projects.isEmpty {
            ContentUnavailableView(
                searching ? "没有匹配的对话" : "没有对话",
                systemImage: searching ? "magnifyingglass" : "bubble.left.and.bubble.right"
            )
        } else {
            List(selection: $selection) {
                ForEach(projects) { project in
                    let expanded = searching || (expansion[project.id] ?? (project.id == selectedProject || project.id == projects.first?.id))
                    projectRow(project, expanded: expanded)
                        .selectionDisabled()
                        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                    if expanded {
                        ForEach(project.sessions) { session in
                            HStack(spacing: 8) {
                                Text(session.title).lineLimit(1)
                                Spacer(minLength: 0)
                                if running.contains(session.id) { ProgressView().controlSize(.mini).accessibilityLabel("运行中") }
                            }
                            .font(.callout)
                            .padding(.leading, 24)
                            .padding(.vertical, 3)
                            .help("\(session.title) · \(sourceName(session.source)) · \(session.usage.isEmpty ? "用量未知" : compact(session.tokens))")
                            .tag(session.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .onChange(of: selection) { _, id in
                if id != nil, let selectedProject { expansion[selectedProject] = true }
            }
        }
    }

    private func projectRow(_ project: ConversationProject, expanded: Bool) -> some View {
        HStack(spacing: 4) {
            if searching {
                projectLabel(project, expanded: true)
                    .accessibilityAddTraits(.isHeader)
            } else {
                Button { expansion[project.id] = !expanded } label: { projectLabel(project, expanded: expanded) }
                    .buttonStyle(.plain)
                    .accessibilityValue(expanded ? "已展开" : "已折叠")
            }
            if !project.id.isEmpty {
                Button { createChat(project.id) } label: {
                    Image(systemName: "plus").font(.caption.weight(.medium)).frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("在 \(project.name) 中新建对话")
                .help("在此项目中新建对话")
            }
        }
    }

    private func projectLabel(_ project: ConversationProject, expanded: Bool) -> some View {
        HStack(spacing: 7) {
            if !searching {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 10)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: project.id.isEmpty ? "tray" : expanded ? "folder.fill" : "folder")
                .foregroundStyle(.secondary)
            Text(project.name).font(.callout.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 26)
        .contentShape(Rectangle())
        .help(project.id.isEmpty ? project.name : project.id)
    }
}

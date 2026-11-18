import RagdollCore
import Testing
@testable import Ragdoll

@Test func conversationProjectsGroupIndexedSessionsByFullPath() throws {
    let store = try Store(path: ":memory:")
    try store.save(Session(id: "unassigned", source: "desktop", title: "命中", updated: 7))
    try store.save(Session(id: "second-path", source: "codex", title: "命中", project: "/other/repo", updated: 3))
    try store.save(Session(id: "older", source: "dsh", title: "其他", project: "/work/repo", updated: 2))
    try store.save(Session(
        id: "recent", source: "codex", title: "最近", project: "/work/repo", updated: 5,
        messages: [Message(role: "user", text: "命中")]
    ))
    try store.save(Session(id: "middle", source: "desktop", title: "其他", project: "/work/repo", updated: 4))

    let projects = ConversationProject.group(try store.list())
    #expect(projects.map(\.id) == ["/work/repo", "/other/repo", ""])
    #expect(projects.map { $0.sessions.map(\.id) } == [["recent", "middle", "older"], ["second-path"], ["unassigned"]])

    let matches = ConversationProject.group(try store.list(query: "命中"))
    #expect(matches.map { $0.sessions.map(\.id) } == [["recent"], ["second-path"], ["unassigned"]])
    #expect(ConversationProject.group(try store.list(query: "无结果")).isEmpty)
}

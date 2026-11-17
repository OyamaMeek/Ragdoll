import RagdollCore
import Testing
@testable import Ragdoll

@Test func conversationHidesToolsWithoutRemovingHistory() {
    let messages = [
        Message(id: "system", role: "system", text: "系统规则"),
        Message(id: "developer", role: "developer", text: "开发者规则"),
        Message(id: "user", role: "user", text: "用户提问"),
        Message(id: "call", role: "tool", text: "工具调用"),
        Message(id: "result", role: "function", text: "工具结果"),
        Message(id: "kind", role: "assistant", text: "工具事件", kind: "tool"),
        Message(id: "assistant", role: "assistant", text: "助手回复")
    ]
    let session = Session(id: "chat", source: "codex", title: "会话", messages: messages)
    #expect(session.conversationMessages.map(\.id) == ["system", "developer", "user", "assistant"])
    #expect(session.messages == messages)
}

@Test func conversationPaginatesVisibleMessagesAfterHidingTools() {
    let messages = (0..<105).flatMap { index in
        [Message(id: "user-\(index)", role: "user", text: "提问 \(index)"),
         Message(id: "tool-\(index)", role: "tool", text: "调用 \(index)", kind: "tool")]
    }
    let session = Session(id: "chat", source: "codex", title: "会话", messages: messages)
    let page = session.conversationMessages.suffix(100)
    #expect(page.count == 100)
    #expect(page.first?.id == "user-5")
    #expect(page.last?.id == "user-104")
    #expect(session.conversationMessages.count - page.count == 5)
    #expect(session.messages.count == 210)
}

@Test func conversationFoldsInstructionsAndPreservesActualRequests() {
    for role in ["system", "developer"] {
        #expect(Message(role: role, text: "规则").isSystemPrompt)
    }
    for text in ["# AGENTS.md instructions for /project\n<INSTRUCTIONS>规则</INSTRUCTIONS>",
                 "  <environment_context>环境</environment_context>",
                 "<permissions instructions>权限</permissions instructions>",
                 "<INSTRUCTIONS>规则</INSTRUCTIONS>"] {
        #expect(Message(role: "user", text: text).isSystemPrompt)
    }
    for text in ["解释 system 和 developer 的区别", "# AGENTS.md 的用途", "<environment_context>环境</environment_context>\n## My request:\n修改界面"] {
        #expect(!Message(role: "user", text: text).isSystemPrompt)
    }
    #expect(!Message(role: "assistant", text: "<INSTRUCTIONS>示例</INSTRUCTIONS>").isSystemPrompt)
}

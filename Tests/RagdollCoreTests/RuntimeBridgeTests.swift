import Foundation
import Testing
@testable import RagdollCore

private actor ReceivedSessions {
    var messages: [JSONValue] = []
    func receive(_ event: String, _ data: JSONValue) {
        if event == "session" { messages.append(data) }
    }
}

@Test func scanSkipsLargeUnicodeBodiesAndDeliversSessionMetadataWithoutStalling() async throws {
    let root = try testDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("codex")
    let sessions = home.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let text = String(repeating: "中文🙂", count: 1_600_000)
    let record: [String: Any] = ["type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": text]]]]
    try (JSONSerialization.data(withJSONObject: record) + Data([10])).write(to: sessions.appendingPathComponent("large.jsonl"))
    let small = Data("{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"短消息\"}]}}\n".utf8)
    try small.write(to: sessions.appendingPathComponent("a-small.jsonl"))
    try small.write(to: sessions.appendingPathComponent("z-small.jsonl"))
    let bridge = RuntimeBridge(), received = ReceivedSessions()
    await bridge.setHandler { event, data in await received.receive(event, data) }
    try await bridge.start(dataDirectory: root.appendingPathComponent("data"))
    do {
        let result = try await bridge.request("scan", ["locations": .array([.object(["source": .string("codex"), "path": .string(home.path)])])], timeout: 8)
        #expect(result["count"] == .number(3))
        let delivered = await received.messages
        #expect(delivered.count == 3)
        #expect(delivered.contains { $0["nativeID"].string == "large" })
        #expect(delivered.allSatisfy { $0["messages"] == .null && $0["files"] == .null })
        #expect(delivered.allSatisfy { $0.text.utf8.count < 1024 })
        let next = try await bridge.request("scan", ["locations": .array([])], timeout: 2)
        #expect(next["count"] == .number(0))
    } catch {
        await bridge.close()
        throw error
    }
    await bridge.close()
}

import Foundation

public struct Message: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var role: String
    public var text: String
    public var time: Double
    public var kind: String
    public init(id: String = UUID().uuidString, role: String, text: String, time: Double = Date().timeIntervalSince1970 * 1000, kind: String = "text") {
        self.id = id; self.role = role; self.text = text; self.time = time; self.kind = kind
    }
}

public struct Usage: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var time: Double
    public var model: String
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var tokens: Int { input + output + cacheRead + cacheWrite }
    public init(id: String = UUID().uuidString, time: Double, model: String, input: Int, output: Int, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.id = id; self.time = time; self.model = model; self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
    }
}

public struct Session: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var nativeID: String
    public var source: String
    public var title: String
    public var project: String
    public var home: String
    public var created: Double
    public var updated: Double
    public var parentID: String?
    public var provider: String?
    public var instanceID: String?
    public var nativeSource: String?
    public var canonicalID: String?
    public var nativeStarted: Bool?
    public var migration: MigrationOrigin?
    public var messages: [Message]
    public var usage: [Usage]
    public var files: [String]
    public var warnings: [String]
    public var tokens: Int { usage.reduce(0) { $0 + $1.tokens } }
    public var projectName: String { project.isEmpty ? "未关联项目" : URL(fileURLWithPath: project).lastPathComponent }
    public init(id: String, nativeID: String? = nil, source: String, title: String, project: String = "", home: String = "", created: Double = Date().timeIntervalSince1970 * 1000, updated: Double? = nil, messages: [Message] = [], usage: [Usage] = [], files: [String] = [], warnings: [String] = []) {
        self.id = id; self.nativeID = nativeID ?? id; self.source = source; self.title = title; self.project = project; self.home = home; self.created = created; self.updated = updated ?? created
        self.messages = messages; self.usage = usage; self.files = files; self.warnings = warnings
    }
}

public struct Location: Codable, Sendable, Equatable {
    public var source: String
    public var path: String
    public init(source: String, path: String) { self.source = source; self.path = path }
}

public struct AgentConfig: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var kind: String
    public var command: String
    public var args: [String]
    public var env: [String: String]
    public var version: String?
    public var registryID: String?
    public var installPath: String?
    public var `protocol`: Int?
    public init(id: String = UUID().uuidString, name: String, kind: String = "acp", command: String, args: [String] = [], env: [String: String] = [:]) {
        self.id = id; self.name = name; self.kind = kind; self.command = command; self.args = args; self.env = env
    }
}

public struct Price: Codable, Sendable, Equatable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double
    public var reference: String
    public var date: String
    public init(input: Double, output: Double, cacheRead: Double = 0, cacheWrite: Double = 0, reference: String = "用户设置", date: String = "2026-11-16") {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite; self.reference = reference; self.date = date
    }
    public func cost(_ usage: Usage) -> Double {
        (Double(usage.input) * input + Double(usage.output) * output + Double(usage.cacheRead) * cacheRead + Double(usage.cacheWrite) * cacheWrite) / 1_000_000
    }
}

public struct MigrationOrigin: Codable, Sendable, Equatable {
    public var sourceID: String
    public var source: String
    public var sourceNativeID: String
    public var created: Double
    public var attachments: [String]?
    public init(sourceID: String, source: String, sourceNativeID: String, created: Double) {
        self.sourceID = sourceID; self.source = source; self.sourceNativeID = sourceNativeID; self.created = created
    }
}

public struct ArchiveRemote: Codable, Sendable, Equatable {
    public var remote: String
    public var branch: String
    public init(remote: String = "origin", branch: String = "main") { self.remote = remote; self.branch = branch }
}

public struct Settings: Codable, Sendable {
    public var locations: [Location] = []
    public var agents: [AgentConfig] = []
    public var archivePath = ""
    public var archiveRemote: ArchiveRemote?
    public var backgroundEnabled: Bool?
    public var excludedProjects: [String] = []
    public var weeklyBudget: Double?
    public var showWeeklyBudget: Bool?
    public var prices: [String: Price] = [
        "gpt-6.1-sol": Price(input: 2, output: 10, cacheRead: 0.1, cacheWrite: 2.5, reference: "https://developers.openai.com/api/docs/pricing"),
        "gpt-6.1-terra": Price(input: 1, output: 5, cacheRead: 0.05, cacheWrite: 1.25, reference: "https://developers.openai.com/api/docs/pricing"),
        "gpt-6-astra": Price(input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5, reference: "https://developers.openai.com/api/docs/pricing"),
        "gpt-6-luna": Price(input: 0.1, output: 0.5, cacheRead: 0.01, cacheWrite: 0.125, reference: "https://developers.openai.com/api/docs/pricing"),
        "claude-opus-5-5": Price(input: 4, output: 20, cacheRead: 0.2, cacheWrite: 5, reference: "https://platform.claude.com/docs/en/about-claude/pricing"),
        "claude-sonnet-5-5": Price(input: 2, output: 10, cacheRead: 0.1, cacheWrite: 2.5, reference: "https://platform.claude.com/docs/en/about-claude/pricing")
    ]
    public init() {}
}

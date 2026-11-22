import Foundation

public struct CodexAccount: Decodable, Identifiable, Sendable {
    public struct Window: Decodable, Sendable {
        public let usedPercent: Double
        public let resetAt: Double?
        public var exhausted: Bool { usedPercent >= 100 && (resetAt ?? 0) > Date().timeIntervalSince1970 }
    }
    public let id: String
    public let label: String
    public let email: String
    public let planType: String
    public let isCurrent: Bool
    public let fiveHour: Window?
    public let oneWeek: Window?
    public let fetchedAt: Double?
    public let usageError: String?
    public var displayName: String { email.isEmpty ? label : email }
    public var exhausted: Bool { fiveHour?.exhausted == true || oneWeek?.exhausted == true }
    public var state: String { usageError != nil ? "需处理" : exhausted ? "额度耗尽" : isCurrent ? "当前登录" : "可用" }
}

public struct CodexAccountsResponse: Decodable, Sendable {
    public let accounts: [CodexAccount]
    public let message: String?
    public let status: String?
}

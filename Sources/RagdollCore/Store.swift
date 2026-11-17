import Foundation
import GRDB

public final class Store: Sendable {
    private let db: DatabaseQueue
    public init(path: String) throws {
        var configuration = Configuration(); configuration.busyMode = .timeout(10)
        db = try DatabaseQueue(path: path, configuration: configuration)
        try db.write { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, source TEXT NOT NULL, native_id TEXT NOT NULL, title TEXT NOT NULL, project TEXT NOT NULL, updated REAL NOT NULL, body BLOB NOT NULL, summary BLOB NOT NULL, search TEXT NOT NULL)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS sessions_updated ON sessions(updated DESC)")
            if try !db.columns(in: "sessions").contains(where: { $0.name == "canonical_id" }) { try db.execute(sql: "ALTER TABLE sessions ADD COLUMN canonical_id TEXT") }
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS sessions_native ON sessions(source,native_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS sessions_canonical ON sessions(canonical_id)")
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS settings (id INTEGER PRIMARY KEY CHECK(id=1), body BLOB NOT NULL)")
        }
    }
    @discardableResult public func save(_ session: Session) throws -> Bool {
        return try db.write { db in
            var session = session
            if let existing = try Data.fetchOne(db, sql: "SELECT body FROM sessions WHERE id=?", arguments: [session.id]) {
                let previous = try JSONDecoder().decode(Session.self, from: existing)
                guard session.updated >= previous.updated else { return false }
                session.files = Array(Set(previous.files + session.files)).sorted()
                session.instanceID = session.instanceID ?? previous.instanceID
                session.migration = session.migration ?? previous.migration
            }
            if let nativeSource = session.nativeSource {
                let candidates = try Data.fetchAll(db, sql: "SELECT body FROM sessions WHERE source=? AND native_id=?", arguments: [nativeSource, session.nativeID]).map { try JSONDecoder().decode(Session.self, from: $0) }.filter { $0.home == session.home }
                if candidates.count == 1, let native = candidates.first {
                    session.canonicalID = native.id; session.files = Array(Set(session.files + native.files)).sorted(); session.usage = native.usage
                    session.migration = session.migration ?? native.migration
                }
            }
            var changed = try Self.upsert(db, session)
            if session.source != "acp" {
                let aliases = try Data.fetchAll(db, sql: "SELECT body FROM sessions WHERE source='acp' AND native_id=?", arguments: [session.nativeID]).map { try JSONDecoder().decode(Session.self, from: $0) }
                for var alias in aliases where alias.nativeSource == session.source && alias.home == session.home {
                    alias.canonicalID = session.id; alias.usage = session.usage; alias.files = Array(Set(alias.files + session.files)).sorted()
                    alias.migration = alias.migration ?? session.migration
                    changed = try Self.upsert(db, alias) || changed
                }
            }
            return changed
        }
    }
    private static func upsert(_ db: Database, _ session: Session) throws -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(session)
        guard try Data.fetchOne(db, sql: "SELECT body FROM sessions WHERE id=?", arguments: [session.id]) != body else { return false }
        var summary = session; summary.messages = []
        let summaryData = try encoder.encode(summary)
        try db.execute(sql: "INSERT INTO sessions(id,source,native_id,title,project,updated,body,summary,search,canonical_id) VALUES (?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title, project=excluded.project, updated=excluded.updated, body=excluded.body, summary=excluded.summary, search=excluded.search, canonical_id=excluded.canonical_id", arguments: [session.id, session.source, session.nativeID, session.title, session.project, session.updated, body, summaryData, session.title + "\n" + session.messages.map(\.text).joined(separator: "\n"), session.canonicalID])
        return true
    }
    public func list(query: String = "", limit: Int = Int.max) throws -> [Session] {
        try db.read { db in
            let escaped = query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            return try Data.fetchAll(db, sql: "SELECT summary FROM sessions s WHERE search LIKE ? ESCAPE '\\' AND NOT EXISTS (SELECT 1 FROM sessions a WHERE a.canonical_id=s.id) ORDER BY updated DESC LIMIT ?", arguments: ["%\(escaped)%", limit]).map { try JSONDecoder().decode(Session.self, from: $0) }
        }
    }
    public func session(_ id: String) throws -> Session? {
        try db.read { db in
            try Data.fetchOne(db, sql: "SELECT body FROM sessions WHERE id=?", arguments: [id]).map { try JSONDecoder().decode(Session.self, from: $0) }
        }
    }
    public func settings() throws -> Settings {
        try db.read { db in
            try Data.fetchOne(db, sql: "SELECT body FROM settings WHERE id=1").map { try JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
        }
    }
    public func saveSettings(_ settings: Settings) throws {
        let data = try JSONEncoder().encode(settings)
        try db.write { db in try db.execute(sql: "INSERT INTO settings(id,body) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET body=excluded.body", arguments: [data]) }
    }
    public func dataVersion() throws -> Int { try db.read { try Int.fetchOne($0, sql: "PRAGMA data_version") ?? 0 } }
}

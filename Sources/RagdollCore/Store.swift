import Foundation
import GRDB

public final class Store: Sendable {
    private let db: DatabaseQueue
    public init(path: String) throws {
        var configuration = Configuration(); configuration.busyMode = .timeout(10)
        db = try DatabaseQueue(path: path, configuration: configuration)
        let legacy = try db.read { try $0.tableExists("sessions") && $0.columns(in: "sessions").contains { $0.name == "summary" } }
        if legacy {
            let backup = path + ".before-usage"
            guard !FileManager.default.fileExists(atPath: backup) else {
                throw NSError(domain: "Ragdoll.Store", code: 1, userInfo: [NSLocalizedDescriptionKey: "用量迁移恢复点已存在，请先保留并移走该文件后重试：\(backup)"])
            }
            try db.writeWithoutTransaction { try $0.execute(sql: "VACUUM INTO ?", arguments: [backup]) }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup)
        }
        try db.write { db in
            if legacy {
                let sessions = try Data.fetchAll(db, sql: "SELECT summary FROM sessions").map { try JSONDecoder().decode(Session.self, from: $0) }
                try db.execute(sql: "DROP TABLE sessions")
                try Self.createSessions(db)
                for session in sessions { _ = try Self.upsert(db, session) }
                if let settings = try Data.fetchOne(db, sql: "SELECT body FROM settings WHERE id=1") {
                    try db.execute(sql: "UPDATE settings SET body=? WHERE id=1", arguments: [try JSONEncoder().encode(JSONDecoder().decode(Settings.self, from: settings))])
                }
                try db.execute(sql: "PRAGMA user_version=1")
            } else { try Self.createSessions(db) }
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS sessions_updated ON sessions(updated DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS sessions_native ON sessions(source,native_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS sessions_canonical ON sessions(canonical_id)")
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS settings (id INTEGER PRIMARY KEY CHECK(id=1), body BLOB NOT NULL)")
        }
        if try db.read({ try Int.fetchOne($0, sql: "PRAGMA user_version") }) == 1 {
            try db.writeWithoutTransaction { try $0.execute(sql: "VACUUM"); try $0.execute(sql: "PRAGMA user_version=2") }
        }
    }
    private static func createSessions(_ db: Database) throws {
        try db.execute(sql: "CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, source TEXT NOT NULL, native_id TEXT NOT NULL, title TEXT NOT NULL, project TEXT NOT NULL, updated REAL NOT NULL, body BLOB NOT NULL, canonical_id TEXT)")
    }
    @discardableResult public func save(_ session: Session) throws -> Bool {
        return try db.write { db in
            var session = session
            if let existing = try Data.fetchOne(db, sql: "SELECT body FROM sessions WHERE id=?", arguments: [session.id]) {
                let previous = try JSONDecoder().decode(Session.self, from: existing)
                guard session.updated >= previous.updated else { return false }
            }
            if let nativeSource = session.nativeSource {
                let candidates = try Data.fetchAll(db, sql: "SELECT body FROM sessions WHERE source=? AND native_id=?", arguments: [nativeSource, session.nativeID]).map { try JSONDecoder().decode(Session.self, from: $0) }.filter { $0.home == session.home }
                if candidates.count == 1, let native = candidates.first {
                    session.canonicalID = native.id; session.usage = native.usage
                }
            }
            var changed = try Self.upsert(db, session)
            if session.source != "acp" {
                let aliases = try Data.fetchAll(db, sql: "SELECT body FROM sessions WHERE source='acp' AND native_id=?", arguments: [session.nativeID]).map { try JSONDecoder().decode(Session.self, from: $0) }
                for var alias in aliases where alias.nativeSource == session.source && alias.home == session.home {
                    alias.canonicalID = session.id; alias.usage = session.usage
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
        try db.execute(sql: "INSERT INTO sessions(id,source,native_id,title,project,updated,body,canonical_id) VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title, project=excluded.project, updated=excluded.updated, body=excluded.body, canonical_id=excluded.canonical_id", arguments: [session.id, session.source, session.nativeID, session.title, session.project, session.updated, body, session.canonicalID])
        return true
    }
    public func list(query: String = "", limit: Int = Int.max) throws -> [Session] {
        try db.read { db in
            let escaped = query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            let pattern = "%\(escaped)%"
            return try Data.fetchAll(db, sql: "SELECT body FROM sessions s WHERE (title LIKE ? ESCAPE '\\' OR project LIKE ? ESCAPE '\\' OR native_id LIKE ? ESCAPE '\\') AND NOT EXISTS (SELECT 1 FROM sessions a WHERE a.canonical_id=s.id) ORDER BY updated DESC LIMIT ?", arguments: [pattern, pattern, pattern, limit]).map { try JSONDecoder().decode(Session.self, from: $0) }
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

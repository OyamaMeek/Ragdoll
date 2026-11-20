import Foundation
import Darwin

public enum ServiceLeaseError: Error, LocalizedError {
    case occupied
    public var errorDescription: String? { "另一个进程正在处理此目录" }
}

public final class ServiceLease: Sendable {
    private let descriptor: Int32
    public init(root: URL, name: String = "service-lock") throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(root.appendingPathComponent(name).path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno; close(descriptor)
            if code == EWOULDBLOCK { throw ServiceLeaseError.occupied }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        let owner = Data(String(getpid()).utf8)
        guard ftruncate(descriptor, 0) == 0, owner.withUnsafeBytes({ write(descriptor, $0.baseAddress, $0.count) }) == owner.count else {
            let code = errno; flock(descriptor, LOCK_UN); close(descriptor); throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        self.descriptor = descriptor
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

public struct ServiceStatus: Codable, Sendable {
    public var pid: Int32 = getpid()
    public var updated: Date = Date()
    public var scan = "等待扫描"
    public var archive = "等待归档"
    public var sync = "未启用远端推送"
    public var lastArchive: Date?
    public init() {}
}

public enum BackgroundService {
    public static func isRunning(root: URL) throws -> Bool {
        do { let lease = try ServiceLease(root: root); withExtendedLifetime(lease) {}; return false }
        catch ServiceLeaseError.occupied { return true }
    }
    public static func ownerPID(root: URL) throws -> Int32? {
        Int32(try String(contentsOf: root.appendingPathComponent("service-lock"), encoding: .utf8))
    }
    public static func request(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(UUID().uuidString.utf8).write(to: root.appendingPathComponent("service-request"), options: .atomic)
    }
    public static func requestPush(root: URL) throws {
        try Data("pending".utf8).write(to: root.appendingPathComponent("sync-pending"), options: .atomic)
        try Data(UUID().uuidString.utf8).write(to: root.appendingPathComponent("service-push-request"), options: .atomic)
    }
    public static func status(root: URL) throws -> ServiceStatus? {
        let path = root.appendingPathComponent("service-status.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return try JSONDecoder().decode(ServiceStatus.self, from: Data(contentsOf: path))
    }
}

public actor BackgroundWorker {
    private let root: URL
    private let store: Store
    private let bridge = RuntimeBridge()
    private var state = ServiceStatus()
    private var dirtySince: Date?
    private var lastDirty: Date?
    private var generation = 0
    private var needsScan = true
    private var fatalFailure: String?
    private var lastPush = Date.distantPast

    public init(root: URL) throws {
        self.root = root
        store = try Store(path: root.appendingPathComponent("index.sqlite").path)
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("archive-dirty").path) { dirtySince = .distantPast; lastDirty = .distantPast }
    }
    private func publish() throws {
        state.updated = Date()
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("service-status.json"), options: .atomic)
    }
    private func markDirty() throws {
        dirtySince = dirtySince ?? Date(); lastDirty = Date(); generation += 1
        try Data("pending".utf8).write(to: root.appendingPathComponent("archive-dirty"), options: .atomic)
    }
    private func receive(_ event: String, _ data: JSONValue) {
        do {
            if event == "session", try store.save(data.decode(Session.self)) { try markDirty() }
            if event == "sourceChanged" { needsScan = true }
            if event == "warning" { state.scan = data.string }
            if event == "disconnected" { state.scan = data.string; fatalFailure = data.string }
        } catch { state.scan = error.localizedDescription; fatalFailure = "索引写入失败：\(error.localizedDescription)" }
    }
    public func run(once: Bool = false) async throws {
        let lease = try ServiceLease(root: root)
        defer { withExtendedLifetime(lease) {} }
        await bridge.setHandler { [weak self] event, data in await self?.receive(event, data) }
        try await bridge.start(dataDirectory: root)
        _ = try await bridge.request("initialize")
        var lastScan = Date.distantPast, lastArchiveAttempt = Date.distantPast, lastRequest: Data?, lastPushRequest: Data?, lastSettings: Data?, lastVersion: Int?
        var loadedArchive: String?
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        repeat {
            do {
                let settings = try store.settings()
                if !once && settings.backgroundEnabled != true { break }
                guard !settings.archivePath.isEmpty else {
                    state.scan = "请先在 Ragdoll 中设置 Git 仓库"; try publish()
                    if once { break }
                    try await Task.sleep(for: .seconds(2)); continue
                }
                if let fatalFailure { throw NSError(domain: "Ragdoll.Service", code: 2, userInfo: [NSLocalizedDescriptionKey: fatalFailure]) }
                if loadedArchive != settings.archivePath {
                    state.scan = "正在读取 Git 仓库"; try publish()
                    let store = self.store
                    let count = try await Task.detached(priority: .utility) { try Archive.restore(from: URL(fileURLWithPath: settings.archivePath), into: store) }.value
                    loadedArchive = settings.archivePath
                    state.archive = "已读取 Git 仓库 · \(count) 个会话"
                }
                let settingsData = try encoder.encode(settings)
                if settingsData != lastSettings { lastSettings = settingsData; needsScan = true; try markDirty() }
                let version = try store.dataVersion()
                if version != lastVersion { lastVersion = version; try markDirty() }
                let requestPath = root.appendingPathComponent("service-request")
                let request = FileManager.default.fileExists(atPath: requestPath.path) ? try Data(contentsOf: requestPath) : nil
                let requested = request != lastRequest
                if requested { lastRequest = request; needsScan = true; try markDirty() }
                let pushPath = root.appendingPathComponent("service-push-request")
                let pushRequest = FileManager.default.fileExists(atPath: pushPath.path) ? try Data(contentsOf: pushPath) : nil
                if pushRequest != lastPushRequest { lastPushRequest = pushRequest; lastPush = .distantPast }
                try await pushPending(settings)
                if needsScan || Date().timeIntervalSince(lastScan) >= 60 {
                    needsScan = false; state.scan = "正在扫描"; try publish()
                    let result = try await bridge.request("scan", ["locations": try .encode(settings.locations)], timeout: 600)
                    if let fatalFailure { throw NSError(domain: "Ragdoll.Service", code: 2, userInfo: [NSLocalizedDescriptionKey: fatalFailure]) }
                    state.scan = "扫描完成 · \(result["count"].text) 个变更"; lastScan = Date()
                }
                let due = dirtySince.map { Date().timeIntervalSince($0) >= 300 || Date().timeIntervalSince(lastDirty ?? $0) >= 30 } ?? false
                if !settings.archivePath.isEmpty && (once || requested || (due && Date().timeIntervalSince(lastArchiveAttempt) >= 30)) {
                    lastArchiveAttempt = Date()
                    let current = generation
                    state.archive = "正在保存并提交"; try publish()
                    let store = self.store
                    let result = try await Task.detached(priority: .utility) {
                        let sessions = try store.list().filter { !settings.excludedProjects.contains($0.project) }
                        return try Archive.save(sessions, to: URL(fileURLWithPath: settings.archivePath), sourceRoots: settings.locations.map(\.path), prices: settings.prices)
                    }.value
                    state.archive = result.commit.map { "本地归档已提交 · \($0)" } ?? "本地归档已是最新"
                    state.lastArchive = Date()
                    if current == generation { dirtySince = nil; try FileManager.default.removeItem(at: root.appendingPathComponent("archive-dirty")) }
                    if settings.archiveRemote != nil { try Data("pending".utf8).write(to: root.appendingPathComponent("sync-pending"), options: .atomic); lastPush = .distantPast }
                }
                try await pushPending(settings)
                if settings.archiveRemote == nil { state.sync = "未启用远端推送" }
                try publish()
            } catch {
                state.archive = "处理失败：\(error.localizedDescription)"; try publish()
                if once || fatalFailure != nil { await bridge.close(); throw error }
            }
            if once { break }
            try await Task.sleep(for: .seconds(2))
        } while !Task.isCancelled
        await bridge.close()
    }
    private func pushPending(_ settings: Settings) async throws {
        guard let remote = settings.archiveRemote, !settings.archivePath.isEmpty,
              FileManager.default.fileExists(atPath: root.appendingPathComponent("sync-pending").path), Date().timeIntervalSince(lastPush) >= 60 else { return }
        lastPush = Date(); state.sync = "正在推送"; try publish()
        do {
            _ = try await Task.detached(priority: .utility) { try ArchiveSync.push(root: URL(fileURLWithPath: settings.archivePath), remote: remote.remote, branch: remote.branch) }.value
            try FileManager.default.removeItem(at: root.appendingPathComponent("sync-pending"))
            state.sync = "已推送到 \(remote.remote)/\(remote.branch)"
        } catch { state.sync = "推送待重试：\(error.localizedDescription)" }
    }
}

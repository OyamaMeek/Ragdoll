import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSONValue { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    public var string: String { if case .string(let v) = self { return v }; return "" }
    public var array: [JSONValue] { if case .array(let v) = self { return v }; return [] }
    public var dictionary: [String: JSONValue] { if case .object(let v) = self { return v }; return [:] }
    public var text: String {
        if case .string(let v) = self { return v }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
    public static func encode<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) }
    public func decode<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder().decode(type, from: JSONEncoder().encode(self)) }
}

public actor RuntimeBridge {
    private var process: Process?
    private var input: FileHandle?
    private var serial = 0
    private var pending: [String: CheckedContinuation<JSONValue, any Error>] = [:]
    private var handler: (@Sendable (String, JSONValue) async -> Void)?
    private var stderr = ""
    public init() {}
    public func setHandler(_ handler: @escaping @Sendable (String, JSONValue) async -> Void) { self.handler = handler }

    public func start(dataDirectory: URL) throws {
        guard process == nil else { return }
        let resources = Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bundled = resources.appendingPathComponent("runtime")
        let isBundled = FileManager.default.fileExists(atPath: bundled.appendingPathComponent("app/dist/main.mjs").path)
        let script = isBundled ? bundled.appendingPathComponent("app/dist/main.mjs") : repo.appendingPathComponent("runtime/dist/main.mjs")
        let node = isBundled ? bundled.appendingPathComponent("node/bin/node") : URL(fileURLWithPath: "/opt/homebrew/bin/node")
        guard FileManager.default.fileExists(atPath: script.path), FileManager.default.isExecutableFile(atPath: node.path) else { throw failure("缺少 SDK 助手，请先运行构建脚本。") }
        let p = Process(); p.executableURL = node; p.arguments = [script.path, "--data-dir", dataDirectory.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = node.deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        p.environment = environment
        let stdin = Pipe(), stdout = Pipe(), errors = Pipe()
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = errors
        p.terminationHandler = { [weak self] p in Task { await self?.terminated(p.terminationStatus) } }
        try p.run(); process = p; input = stdin.fileHandleForWriting
        let reader = stdout.fileHandleForReading
        Task.detached { [weak self] in
            var pending = Data()
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let index = pending.firstIndex(of: 10) {
                    let line = pending.prefix(upTo: index); pending.removeSubrange(...index)
                    await self?.receive(Data(line))
                }
            }
        }
        let errorReader = errors.fileHandleForReading
        Task.detached { [weak self] in
            while true { let data = errorReader.availableData; if data.isEmpty { break }; await self?.errorOutput(String(decoding: data, as: UTF8.self)) }
        }
    }
    public func request(_ method: String, _ params: [String: JSONValue] = [:], timeout: Double = 120) async throws -> JSONValue {
        guard let input else { throw failure("SDK 助手尚未启动") }
        serial += 1; let id = String(serial)
        let message = try JSONEncoder().encode(JSONValue.object(["id": .string(id), "method": .string(method), "params": .object(params)])) + Data([10])
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try input.write(contentsOf: message) }
            catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
            if timeout > 0 { Task { try? await Task.sleep(for: .seconds(timeout)); timedOut(id, method) } }
        }
    }
    private func timedOut(_ id: String, _ method: String) { pending.removeValue(forKey: id)?.resume(throwing: failure("助手请求超时：\(method)。运行中的操作不会自动重试。")) }
    private func receive(_ data: Data) async {
        do {
            let message = try JSONDecoder().decode(JSONValue.self, from: data)
            if !message["event"].string.isEmpty { await handler?(message["event"].string, message["data"]); return }
            let id = message["id"].string
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if message["error"] != .null { continuation.resume(throwing: failure(message["error"]["message"].string)) }
            else { continuation.resume(returning: message["result"]) }
        } catch { await handler?("warning", .string("助手返回无效数据：\(error.localizedDescription)")) }
    }
    private func errorOutput(_ text: String) { stderr = String((stderr + text).suffix(4000)) }
    private func terminated(_ code: Int32) async {
        process = nil; input = nil
        let error = failure("SDK 助手已退出（\(code)）：\(stderr)")
        for continuation in pending.values { continuation.resume(throwing: error) }; pending.removeAll()
        await handler?("disconnected", .string(error.localizedDescription))
    }
    public func close() async {
        _ = try? await request("shutdown", timeout: 5)
        try? input?.close(); process?.terminate()
    }
    private func failure(_ message: String) -> NSError { NSError(domain: "Ragdoll.Runtime", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

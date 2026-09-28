import Foundation

public enum RedisKeyType: String, Sendable, CaseIterable, Codable {
    case string, hash, list, set, zset, stream, json = "ReJSON-RL", none

    public var label: String {
        switch self {
        case .string: "String"
        case .hash: "Hash"
        case .list: "List"
        case .set: "Set"
        case .zset: "Sorted Set"
        case .stream: "Stream"
        case .json: "JSON"
        case .none: "—"
        }
    }

    public var short: String {
        switch self {
        case .string: "STR"
        case .hash: "HASH"
        case .list: "LIST"
        case .set: "SET"
        case .zset: "ZSET"
        case .stream: "STREAM"
        case .json: "JSON"
        case .none: "?"
        }
    }
}

public struct RedisKeyInfo: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public var type: RedisKeyType
    /// Seconds to live; nil when the key doesn't expire.
    public var ttl: Int64?
    public var memory: Int64?
    public var length: Int64?
}

public enum RedisValue: Sendable, Equatable {
    case string(Data)
    case hash([(field: String, value: Data)])
    case list([Data])
    case set([Data])
    case zset([(member: Data, score: Double)])
    case stream([StreamEntry])
    case json(String)
    case missing

    public struct StreamEntry: Sendable, Equatable, Identifiable {
        public let id: String
        public let fields: [(String, String)]
        public static func == (a: Self, b: Self) -> Bool {
            a.id == b.id && a.fields.map(\.0) == b.fields.map(\.0) && a.fields.map(\.1) == b.fields.map(\.1)
        }
    }

    public static func == (a: Self, b: Self) -> Bool {
        switch (a, b) {
        case (.string(let x), .string(let y)): x == y
        case (.hash(let x), .hash(let y)): x.map(\.field) == y.map(\.field) && x.map(\.value) == y.map(\.value)
        case (.list(let x), .list(let y)), (.set(let x), .set(let y)): x == y
        case (.zset(let x), .zset(let y)): x.map(\.member) == y.map(\.member) && x.map(\.score) == y.map(\.score)
        case (.stream(let x), .stream(let y)): x == y
        case (.json(let x), .json(let y)): x == y
        case (.missing, .missing): true
        default: false
        }
    }
}

/// Redis operations used by the app, on top of a `RedisConnection`.
public final class RedisClient: Sendable {
    public let connection: RedisConnection
    /// How many items of a collection are loaded at most.
    public static let valueLimit = 1000

    public init(connection: RedisConnection) {
        self.connection = connection
    }

    public static func connect(_ options: RedisConnection.Options) async throws -> RedisClient {
        RedisClient(connection: try await RedisConnection.open(options))
    }

    public func ping() async throws -> Duration {
        let clock = ContinuousClock()
        let start = clock.now
        try await connection.checked(["PING"])
        return clock.now - start
    }

    // MARK: Keys

    public struct ScanPage: Sendable {
        public let cursor: String
        public let keys: [String]
        public var isComplete: Bool { cursor == "0" }
    }

    public func scan(cursor: String = "0", match: String = "*", count: Int = 500, type: RedisKeyType? = nil) async throws -> ScanPage {
        var args = ["SCAN", cursor, "MATCH", match.isEmpty ? "*" : match, "COUNT", String(count)]
        if let type, type != .none { args += ["TYPE", type.rawValue] }
        let reply = try await connection.checked(args).array
        guard reply.count == 2, let next = reply[0].string else { throw RedisError("Unexpected SCAN reply") }
        return ScanPage(cursor: next, keys: reply[1].array.compactMap(\.string))
    }

    /// Scans until at least `limit` keys are found or the keyspace is exhausted.
    public func scanKeys(match: String, type: RedisKeyType? = nil, limit: Int = 5000) async throws -> (keys: [String], complete: Bool) {
        var cursor = "0"
        var keys: [String] = []
        var seen = Set<String>()
        repeat {
            try Task.checkCancellation()
            let page = try await scan(cursor: cursor, match: match, count: 1000, type: type)
            for k in page.keys where seen.insert(k).inserted { keys.append(k) }
            cursor = page.cursor
        } while cursor != "0" && keys.count < limit
        return (keys, cursor == "0")
    }

    /// Type, TTL and size for many keys at once, pipelined.
    public func describe(_ names: [String]) async throws -> [RedisKeyInfo] {
        try await withThrowingTaskGroup(of: (Int, RedisKeyInfo).self) { group in
            for (i, name) in names.enumerated() {
                group.addTask { (i, try await self.describe(name)) }
            }
            var out = [RedisKeyInfo?](repeating: nil, count: names.count)
            for try await (i, info) in group { out[i] = info }
            return out.compactMap { $0 }
        }
    }

    public func describe(_ name: String) async throws -> RedisKeyInfo {
        async let typeReply = connection.send(["TYPE", name])
        async let ttlReply = connection.send(["TTL", name])
        async let memReply = connection.send(["MEMORY", "USAGE", name])
        let type = RedisKeyType(rawValue: try await typeReply.string ?? "none") ?? .none
        let ttl = try await ttlReply.int ?? -1
        let mem = try await memReply.int
        var length: Int64?
        let lengthCommand: [String]? = switch type {
        case .string: ["STRLEN", name]
        case .hash: ["HLEN", name]
        case .list: ["LLEN", name]
        case .set: ["SCARD", name]
        case .zset: ["ZCARD", name]
        case .stream: ["XLEN", name]
        default: nil
        }
        if let lengthCommand { length = try await connection.send(lengthCommand).int }
        return RedisKeyInfo(name: name, type: type, ttl: ttl >= 0 ? ttl : nil, memory: mem, length: length)
    }

    public func value(of key: String, type: RedisKeyType) async throws -> RedisValue {
        let n = String(Self.valueLimit - 1)
        switch type {
        case .string:
            let r = try await connection.checked(["GET", key])
            return r.isNull ? .missing : .string(r.data ?? Data())
        case .hash:
            let r = try await connection.checked(["HSCAN", key, "0", "COUNT", String(Self.valueLimit)]).array
            let flat = r.count == 2 ? r[1].array : []
            var pairs: [(String, Data)] = []
            var i = 0
            while i + 1 < flat.count {
                pairs.append((flat[i].string ?? "", flat[i + 1].data ?? Data()))
                i += 2
            }
            pairs.sort { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
            return .hash(pairs.map { (field: $0.0, value: $0.1) })
        case .list:
            let r = try await connection.checked(["LRANGE", key, "0", n])
            return .list(r.array.compactMap(\.data))
        case .set:
            let r = try await connection.checked(["SSCAN", key, "0", "COUNT", String(Self.valueLimit)]).array
            let members = (r.count == 2 ? r[1].array : []).compactMap(\.data)
            return .set(members.sorted { String(decoding: $0, as: UTF8.self) < String(decoding: $1, as: UTF8.self) })
        case .zset:
            let r = try await connection.checked(["ZRANGE", key, "0", n, "WITHSCORES"]).array
            var items: [(Data, Double)] = []
            var i = 0
            while i + 1 < r.count {
                items.append((r[i].data ?? Data(), Double(r[i + 1].string ?? "") ?? 0))
                i += 2
            }
            return .zset(items.map { (member: $0.0, score: $0.1) })
        case .stream:
            let r = try await connection.checked(["XREVRANGE", key, "+", "-", "COUNT", String(Self.valueLimit)]).array
            return .stream(r.map { entry in
                let parts = entry.array
                let id = parts.first?.string ?? ""
                let flat = parts.count > 1 ? parts[1].array : []
                var fields: [(String, String)] = []
                var i = 0
                while i + 1 < flat.count {
                    fields.append((flat[i].string ?? "", flat[i + 1].string ?? ""))
                    i += 2
                }
                return RedisValue.StreamEntry(id: id, fields: fields)
            })
        case .json:
            let r = try await connection.checked(["JSON.GET", key])
            return .json(r.string ?? "null")
        case .none:
            return .missing
        }
    }

    // MARK: Edits

    public func setString(_ key: String, _ value: String, keepTTL: Bool = true) async throws {
        var args = ["SET", key, value]
        if keepTTL { args.append("KEEPTTL") }
        try await connection.checked(args)
    }

    public func hashSet(_ key: String, field: String, value: String) async throws {
        try await connection.checked(["HSET", key, field, value])
    }

    public func hashDelete(_ key: String, field: String) async throws {
        try await connection.checked(["HDEL", key, field])
    }

    public func listPush(_ key: String, _ value: String) async throws {
        try await connection.checked(["RPUSH", key, value])
    }

    public func listSet(_ key: String, index: Int, _ value: String) async throws {
        try await connection.checked(["LSET", key, String(index), value])
    }

    /// Removes the element at `index`, even when other elements share its value.
    public func listRemove(_ key: String, index: Int) async throws {
        let marker = "__spool_deleted_\(UUID().uuidString)__"
        try await connection.checked(["LSET", key, String(index), marker])
        try await connection.checked(["LREM", key, "1", marker])
    }

    public func setAdd(_ key: String, _ member: String) async throws {
        try await connection.checked(["SADD", key, member])
    }

    public func setRemove(_ key: String, _ member: Data) async throws {
        _ = try await connection.send([Data("SREM".utf8), Data(key.utf8), member])
    }

    public func zsetAdd(_ key: String, _ member: String, score: Double) async throws {
        try await connection.checked(["ZADD", key, String(score), member])
    }

    public func zsetRemove(_ key: String, _ member: Data) async throws {
        _ = try await connection.send([Data("ZREM".utf8), Data(key.utf8), member])
    }

    public func streamAdd(_ key: String, fields: [(String, String)]) async throws {
        try await connection.checked(["XADD", key, "*"] + fields.flatMap { [$0.0, $0.1] })
    }

    public func streamDelete(_ key: String, id: String) async throws {
        try await connection.checked(["XDEL", key, id])
    }

    /// Sets the TTL in seconds, or removes it when `seconds` is nil.
    public func expire(_ key: String, seconds: Int64?) async throws {
        if let seconds {
            try await connection.checked(["EXPIRE", key, String(seconds)])
        } else {
            try await connection.checked(["PERSIST", key])
        }
    }

    public func rename(_ key: String, to newName: String) async throws {
        if try await connection.checked(["RENAMENX", key, newName]).int != 1 {
            throw RedisError("A key named “\(newName)” already exists.")
        }
    }

    @discardableResult
    public func delete(_ keys: [String]) async throws -> Int64 {
        guard !keys.isEmpty else { return 0 }
        var total: Int64 = 0
        for chunk in stride(from: 0, to: keys.count, by: 500).map({ Array(keys[$0..<min($0 + 500, keys.count)]) }) {
            total += try await connection.checked(["UNLINK"] + chunk).int ?? 0
        }
        return total
    }

    public func exists(_ key: String) async throws -> Bool {
        try await connection.checked(["EXISTS", key]).int == 1
    }

    // MARK: Server

    public func info() async throws -> RedisInfo {
        let r = try await connection.checked(["INFO", "everything"])
        return RedisInfo(parsing: r.string ?? "")
    }

    public func databaseSize() async throws -> Int64 {
        try await connection.checked(["DBSIZE"]).int ?? 0
    }

    public struct SlowLogEntry: Sendable, Identifiable, Hashable {
        public let id: Int64
        public let date: Date
        public let duration: Duration
        public let command: String
        public let client: String
    }

    public func slowLog(count: Int = 50) async throws -> [SlowLogEntry] {
        let r = try await connection.checked(["SLOWLOG", "GET", String(count)]).array
        return r.compactMap { e in
            let p = e.array
            guard p.count >= 4, let id = p[0].int, let ts = p[1].int, let us = p[2].int else { return nil }
            return SlowLogEntry(
                id: id,
                date: Date(timeIntervalSince1970: TimeInterval(ts)),
                duration: .microseconds(us),
                command: p[3].array.compactMap(\.string).map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " "),
                client: p.count > 4 ? (p[4].string ?? "") : "")
        }
    }

    public struct ClientInfo: Sendable, Identifiable, Hashable {
        public let id: String
        public let address: String
        public let name: String
        public let age: Int
        public let idle: Int
        public let db: Int
        public let command: String
    }

    public func clients() async throws -> [ClientInfo] {
        let text = try await connection.checked(["CLIENT", "LIST"]).string ?? ""
        return text.split(whereSeparator: \.isNewline).map { line in
            var f: [String: String] = [:]
            for part in line.split(separator: " ") {
                let kv = part.split(separator: "=", maxSplits: 1)
                if kv.count == 2 { f[String(kv[0])] = String(kv[1]) }
            }
            return ClientInfo(id: f["id"] ?? UUID().uuidString, address: f["addr"] ?? "", name: f["name"] ?? "",
                              age: Int(f["age"] ?? "") ?? 0, idle: Int(f["idle"] ?? "") ?? 0,
                              db: Int(f["db"] ?? "") ?? 0, command: f["cmd"] ?? "")
        }
    }

    /// Runs a console line such as `HGETALL user:1`.
    public func run(line: String) async throws -> RESPValue {
        let args = try RESP.tokenize(line)
        guard !args.isEmpty else { throw RedisError("Empty command") }
        return try await connection.send(args)
    }
}

public struct RedisInfo: Sendable {
    public private(set) var sections: [(name: String, fields: [(String, String)])] = []
    private var flat: [String: String] = [:]

    public init(parsing text: String) {
        var current = ""
        var fields: [(String, String)] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                if !current.isEmpty { sections.append((current, fields)) }
                current = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                fields = []
            } else if let colon = line.firstIndex(of: ":") {
                let k = String(line[..<colon]), v = String(line[line.index(after: colon)...])
                fields.append((k, v))
                flat[k] = v
            }
        }
        if !current.isEmpty { sections.append((current, fields)) }
    }

    public subscript(_ key: String) -> String? { flat[key] }
    public func int(_ key: String) -> Int64? { flat[key].flatMap { Int64($0) } }
    public func double(_ key: String) -> Double? { flat[key].flatMap { Double($0) } }

    public var version: String { self["redis_version"] ?? self["valkey_version"] ?? "?" }
    public var usedMemory: Int64 { int("used_memory") ?? 0 }
    public var maxMemory: Int64 { int("maxmemory") ?? 0 }
    public var connectedClients: Int64 { int("connected_clients") ?? 0 }
    public var opsPerSecond: Int64 { int("instantaneous_ops_per_sec") ?? 0 }
    public var uptime: Int64 { int("uptime_in_seconds") ?? 0 }
    public var hits: Int64 { int("keyspace_hits") ?? 0 }
    public var misses: Int64 { int("keyspace_misses") ?? 0 }
    public var inputKbps: Double { double("instantaneous_input_kbps") ?? 0 }
    public var outputKbps: Double { double("instantaneous_output_kbps") ?? 0 }
    public var role: String { self["role"] ?? "?" }

    /// Key counts per database, e.g. `db0:keys=12,expires=0,avg_ttl=0`.
    public var keyspace: [(db: Int, keys: Int64, expires: Int64)] {
        flat.compactMap { k, v -> (Int, Int64, Int64)? in
            guard k.hasPrefix("db"), let n = Int(k.dropFirst(2)) else { return nil }
            var keys: Int64 = 0, expires: Int64 = 0
            for part in v.split(separator: ",") {
                let kv = part.split(separator: "=")
                guard kv.count == 2 else { continue }
                if kv[0] == "keys" { keys = Int64(kv[1]) ?? 0 }
                if kv[0] == "expires" { expires = Int64(kv[1]) ?? 0 }
            }
            return (n, keys, expires)
        }
        .sorted { $0.0 < $1.0 }
        .map { (db: $0.0, keys: $0.1, expires: $0.2) }
    }
}

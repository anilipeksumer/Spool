import Foundation
import SpoolKit

/// State for one connected Redis server.
@Observable
final class RedisSession {
    enum Status: Equatable {
        case idle, connecting, connected, failed(String)
    }

    let profile: ConnectionProfile
    private(set) var status: Status = .idle
    private(set) var client: RedisClient?

    // Key browser
    var pattern = ""
    var typeFilter: RedisKeyType?
    private(set) var keys: [String] = []
    private(set) var keyInfo: [String: RedisKeyInfo] = [:]
    private(set) var scanComplete = true
    private(set) var isScanning = false
    var selectedKey: String?
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    // Server
    private(set) var info: RedisInfo?
    private(set) var samples: [ServerSample] = []
    private(set) var latency: Duration?

    struct ServerSample: Identifiable {
        var id: Date { date }
        let date: Date
        let opsPerSecond: Double
        let memory: Double
        let clients: Double
        let inputKbps: Double
        let outputKbps: Double
    }

    // Console
    var consoleEntries: [ConsoleEntry] = []

    struct ConsoleEntry: Identifiable {
        let id = UUID()
        let command: String
        let reply: RESPValue?
        let error: String?
        let duration: Duration
    }

    init(profile: ConnectionProfile) {
        self.profile = profile
    }

    var errorMessage: String? {
        if case .failed(let m) = status { return m }
        return nil
    }

    func connect() async {
        guard status != .connecting else { return }
        status = .connecting
        do {
            let c = try await RedisClient.connect(profile.redisOptions)
            client = c
            status = .connected
            latency = try? await c.ping()
            await refreshInfo()
            reloadKeys()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        scanTask?.cancel()
        client?.connection.close()
        client = nil
        status = .idle
    }

    /// Runs an operation, reconnecting once if the connection dropped.
    func perform<T>(_ body: (RedisClient) async throws -> T) async throws -> T {
        if client == nil || client?.connection.isOpen == false {
            await connect()
        }
        guard let client else { throw RedisError(errorMessage ?? "Not connected") }
        do {
            return try await body(client)
        } catch let e as RedisError where !client.connection.isOpen {
            status = .failed(e.message)
            await connect()
            guard let again = self.client else { throw e }
            return try await body(again)
        }
    }

    // MARK: Keys

    func reloadKeys() {
        scanTask?.cancel()
        let match = pattern.isEmpty ? "*" : (pattern.contains("*") || pattern.contains("?") ? pattern : "*\(pattern)*")
        let type = typeFilter
        isScanning = true
        scanTask = Task {
            do {
                let result = try await perform { try await $0.scanKeys(match: match, type: type, limit: 10_000) }
                guard !Task.isCancelled else { return }
                keys = result.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                scanComplete = result.complete
                let found = Set(result.keys)
                keyInfo = keyInfo.filter { found.contains($0.key) }
                if let sel = selectedKey, !keys.contains(sel) { selectedKey = nil }
            } catch is CancellationError {
            } catch {
                status = .failed(error.localizedDescription)
            }
            isScanning = false
        }
    }

    /// Loads type and TTL for keys as they scroll into view. Requests from
    /// rows that appear together are batched into one pipelined round.
    func describe(_ name: String) {
        guard keyInfo[name] == nil, !describing.contains(name) else { return }
        describeQueue.insert(name)
        guard !describeScheduled else { return }
        describeScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(25))
            let batch = Array(describeQueue)
            describeQueue.removeAll()
            describeScheduled = false
            describing.formUnion(batch)
            defer { describing.subtract(batch) }
            guard let client, let infos = try? await client.describe(batch) else { return }
            for i in infos { keyInfo[i.name] = i }
        }
    }

    @ObservationIgnored private var describeQueue: Set<String> = []
    @ObservationIgnored private var describing: Set<String> = []
    @ObservationIgnored private var describeScheduled = false

    func refreshKey(_ name: String) async {
        guard let client else { return }
        if let info = try? await client.describe(name) {
            if info.type == .none {
                keyInfo[name] = nil
                keys.removeAll { $0 == name }
                if selectedKey == name { selectedKey = nil }
            } else {
                keyInfo[name] = info
                if !keys.contains(name) {
                    keys.append(name)
                    keys.sort { $0.localizedStandardCompare($1) == .orderedAscending }
                }
            }
        }
    }

    func delete(_ names: [String]) async throws {
        try await perform { _ = try await $0.delete(names) }
        let gone = Set(names)
        keys.removeAll { gone.contains($0) }
        for n in names { keyInfo[n] = nil }
        if let s = selectedKey, gone.contains(s) { selectedKey = nil }
    }

    func rename(_ key: String, to newName: String) async throws {
        try await perform { try await $0.rename(key, to: newName) }
        keys.removeAll { $0 == key }
        keyInfo[key] = nil
        await refreshKey(newName)
        selectedKey = newName
    }

    // MARK: Server

    func refreshInfo() async {
        guard let client, let i = try? await client.info() else { return }
        info = i
        samples.append(ServerSample(date: .now, opsPerSecond: Double(i.opsPerSecond), memory: Double(i.usedMemory),
                                    clients: Double(i.connectedClients), inputKbps: i.inputKbps, outputKbps: i.outputKbps))
        if samples.count > 180 { samples.removeFirst(samples.count - 180) }
    }

    // MARK: Console

    func run(_ line: String) async {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if trimmed.lowercased() == "clear" {
            consoleEntries.removeAll()
            return
        }
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let reply = try await perform { try await $0.run(line: trimmed) }
            consoleEntries.append(ConsoleEntry(command: trimmed, reply: reply, error: nil, duration: clock.now - start))
            let verb = trimmed.split(separator: " ").first?.uppercased() ?? ""
            if ["SELECT", "FLUSHDB", "FLUSHALL"].contains(verb) { reloadKeys() }
        } catch {
            consoleEntries.append(ConsoleEntry(command: trimmed, reply: nil, error: error.localizedDescription, duration: clock.now - start))
        }
    }
}

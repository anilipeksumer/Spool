import Foundation
import Network

/// A single pipelined connection to a Redis server.
///
/// Commands are written in order and replies are matched to callers
/// first-in first-out, so any number of tasks can send concurrently.
public final class RedisConnection: @unchecked Sendable {
    public struct Options: Sendable, Hashable, Codable {
        public var host: String
        public var port: Int
        public var username: String?
        public var password: String?
        public var database: Int
        public var tls: Bool

        public init(host: String = "127.0.0.1", port: Int = 6379, username: String? = nil,
                    password: String? = nil, database: Int = 0, tls: Bool = false) {
            self.host = host
            self.port = port
            self.username = username
            self.password = password
            self.database = database
            self.tls = tls
        }
    }

    public let options: Options
    private let queue = DispatchQueue(label: "spool.redis")
    private let connection: NWConnection
    // State below is only touched on `queue`.
    private var buffer: [UInt8] = []
    private var pending: [CheckedContinuation<RESPValue, Error>] = []
    private var failure: Error?

    public init(_ options: Options) {
        self.options = options
        let params: NWParameters = options.tls ? .tls : .tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 5
        }
        connection = NWConnection(
            host: NWEndpoint.Host(options.host),
            port: NWEndpoint.Port(integerLiteral: UInt16(clamping: options.port)),
            using: params)
    }

    deinit { connection.cancel() }

    /// Opens the connection, authenticates and selects the database.
    public static func open(_ options: Options) async throws -> RedisConnection {
        let c = RedisConnection(options)
        try await c.start()
        if let password = options.password, !password.isEmpty {
            var args = ["AUTH"]
            if let user = options.username, !user.isEmpty { args.append(user) }
            args.append(password)
            try await c.checked(args)
        }
        if options.database != 0 {
            try await c.checked(["SELECT", String(options.database)])
        }
        return c
    }

    private func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once()
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    once.run { cont.resume() }
                    self?.receive()
                case .waiting(let err), .failed(let err):
                    once.run { cont.resume(throwing: RedisError(Self.describe(err))) }
                    self?.fail(err)
                case .cancelled:
                    once.run { cont.resume(throwing: CancellationError()) }
                    self?.fail(RedisError("Connection closed"))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 6) { [weak self] in
                once.run {
                    cont.resume(throwing: RedisError("Timed out connecting to \(self?.options.host ?? ""):\(self?.options.port ?? 0)"))
                    self?.connection.cancel()
                }
            }
        }
    }

    public func close() { connection.cancel() }

    public var isOpen: Bool { queue.sync { failure == nil } }

    /// Sends a command and returns the raw reply. Server errors come back
    /// as `.error`, not as thrown errors.
    public func send(_ args: [String]) async throws -> RESPValue {
        try await send(args.map { Data($0.utf8) })
    }

    public func send(_ args: [Data]) async throws -> RESPValue {
        let payload = RESP.encode(args)
        return try await withCheckedThrowingContinuation { cont in
            queue.async { [self] in
                if let failure { cont.resume(throwing: failure); return }
                pending.append(cont)
                connection.send(content: payload, completion: .contentProcessed { [weak self] err in
                    if let err { self?.fail(err) }
                })
            }
        }
    }

    /// Sends a command and throws if the server replied with an error.
    @discardableResult
    public func checked(_ args: [String]) async throws -> RESPValue {
        let reply = try await send(args)
        if case .error(let msg) = reply { throw RedisError(msg) }
        return reply
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data, !data.isEmpty {
                buffer.append(contentsOf: data)
                drain()
            }
            if let err { fail(err); return }
            if done { fail(RedisError("Server closed the connection")); return }
            receive()
        }
    }

    private func drain() {
        var pos = 0
        do {
            while let (value, next) = try RESP.parse(buffer, at: pos) {
                pos = next
                if pending.isEmpty { continue } // unsolicited (e.g. after a timeout)
                pending.removeFirst().resume(returning: value)
            }
        } catch {
            fail(error)
            return
        }
        if pos > 0 { buffer.removeFirst(pos) }
    }

    private func fail(_ error: Error) {
        queue.async { [self] in
            let err = (error as? RedisError) ?? RedisError(Self.describe(error))
            if failure == nil { failure = err }
            let waiting = pending
            pending.removeAll()
            waiting.forEach { $0.resume(throwing: err) }
            connection.cancel()
        }
    }

    private static func describe(_ error: Error) -> String {
        if let nw = error as? NWError {
            switch nw {
            case .posix(.ECONNREFUSED): return "Connection refused — is the server running?"
            case .posix(.ETIMEDOUT): return "Timed out"
            case .dns: return "Host not found"
            case .tls(let status): return "TLS error (\(status))"
            default: return nw.localizedDescription
            }
        }
        return error.localizedDescription
    }
}

/// Runs a closure at most once, from any thread.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}

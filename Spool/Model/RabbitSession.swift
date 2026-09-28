import Foundation
import SpoolKit

/// State for one RabbitMQ server, refreshed every few seconds while open.
@Observable
final class RabbitSession {
    enum Status: Equatable {
        case idle, connecting, connected, failed(String)
    }

    let profile: ConnectionProfile
    private(set) var status: Status = .idle
    private(set) var client: RabbitClient?

    private(set) var overview: RabbitOverview?
    private(set) var queues: [RabbitQueue] = []
    private(set) var exchanges: [RabbitExchange] = []
    private(set) var connections: [RabbitConnectionInfo] = []
    private(set) var consumers: [RabbitConsumer] = []
    private(set) var canMove = false
    private(set) var lastRefresh: Date?

    /// Rolling history per queue id and for the whole server.
    private(set) var queueHistory: [String: [QueueSample]] = [:]
    private(set) var serverHistory: [ServerSample] = []

    struct QueueSample: Identifiable {
        var id: Date { date }
        let date: Date
        let ready: Double
        let unacked: Double
        let publishRate: Double
        let deliverRate: Double
    }

    struct ServerSample: Identifiable {
        var id: Date { date }
        let date: Date
        let ready: Double
        let unacked: Double
        let publishRate: Double
        let deliverRate: Double
        let ackRate: Double
    }

    static let refreshInterval: Duration = .seconds(5)
    /// Called after every successful refresh (menu bar watches).
    @ObservationIgnored var onRefresh: ((RabbitSession) -> Void)?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init(profile: ConnectionProfile) {
        self.profile = profile
    }

    var errorMessage: String? {
        if case .failed(let m) = status { return m }
        return nil
    }

    var vhosts: [String] {
        Array(Set(queues.map(\.vhost) + exchanges.map(\.vhost))).sorted()
    }

    func connect() async {
        guard status != .connecting else { return }
        status = .connecting
        let c = RabbitClient(profile.rabbitOptions)
        do {
            overview = try await c.overview()
            client = c
            status = .connected
            canMove = await c.canMoveMessages()
            await refresh()
            startPolling()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        pollTask?.cancel()
        pollTask = nil
        client = nil
        status = .idle
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.refreshInterval)
                guard let self, !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    func refresh() async {
        guard let client else { return }
        do {
            async let o = client.overview()
            async let q = client.queues()
            async let e = client.exchanges()
            async let cn = client.connections()
            async let cs = client.consumers()
            let (overview, queues, exchanges) = try await (o, q, e)
            self.overview = overview
            self.queues = queues.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            self.exchanges = exchanges.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            connections = (try? await cn) ?? connections
            consumers = (try? await cs) ?? consumers
            if case .failed = status { status = .connected }
            record()
            lastRefresh = .now
            onRefresh?(self)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func record() {
        let now = Date.now
        let cutoff = now.addingTimeInterval(-15 * 60)
        for q in queues {
            var h = queueHistory[q.id, default: []]
            h.append(QueueSample(date: now, ready: Double(q.messagesReady ?? 0), unacked: Double(q.messagesUnacknowledged ?? 0),
                                 publishRate: q.messageStats?.publishRate ?? 0, deliverRate: q.messageStats?.deliverRate ?? 0))
            h.removeAll { $0.date < cutoff }
            queueHistory[q.id] = h
        }
        if let o = overview {
            serverHistory.append(ServerSample(
                date: now,
                ready: Double(o.queueTotals?.messagesReady ?? 0),
                unacked: Double(o.queueTotals?.messagesUnacknowledged ?? 0),
                publishRate: o.messageStats?.publishRate ?? 0,
                deliverRate: o.messageStats?.deliverRate ?? 0,
                ackRate: o.messageStats?.ackRate ?? 0))
            serverHistory.removeAll { $0.date < cutoff }
        }
    }

    func queue(_ id: String?) -> RabbitQueue? {
        queues.first { $0.id == id }
    }

    func consumers(of queue: RabbitQueue) -> [RabbitConsumer] {
        consumers.filter { $0.queue.name == queue.name && $0.queue.vhost == queue.vhost }
    }

    /// Runs a change and refreshes right after.
    func perform(_ body: (RabbitClient) async throws -> Void) async throws {
        guard let client else { throw RabbitError("Not connected") }
        try await body(client)
        await refresh()
    }
}

/// Keeps one live session per saved connection.
@Observable
final class SessionRegistry {
    let watches: WatchStore
    // Sessions are created lazily while views render, so the maps aren't
    // observed directly; `generation` changes (outside the render) instead.
    @ObservationIgnored private var redis: [UUID: RedisSession] = [:]
    @ObservationIgnored private var rabbit: [UUID: RabbitSession] = [:]
    private var generation = 0

    private func bump() {
        Task { @MainActor in generation += 1 }
    }

    init(watches: WatchStore) {
        self.watches = watches
    }

    func redis(for profile: ConnectionProfile) -> RedisSession {
        if let s = redis[profile.id], s.profile == profile { return s }
        redis[profile.id]?.disconnect()
        let s = RedisSession(profile: profile)
        redis[profile.id] = s
        bump()
        return s
    }

    func rabbit(for profile: ConnectionProfile) -> RabbitSession {
        if let s = rabbit[profile.id], s.profile == profile { return s }
        rabbit[profile.id]?.disconnect()
        let s = RabbitSession(profile: profile)
        s.onRefresh = { [watches] in watches.evaluate($0) }
        rabbit[profile.id] = s
        bump()
        return s
    }

    func existingRabbit(_ id: UUID) -> RabbitSession? {
        _ = generation
        return rabbit[id]
    }

    func existingRedis(_ id: UUID) -> RedisSession? {
        _ = generation
        return redis[id]
    }

    func drop(_ id: UUID) {
        redis.removeValue(forKey: id)?.disconnect()
        rabbit.removeValue(forKey: id)?.disconnect()
        bump()
    }

    /// Whether the session is connected, for the sidebar dot.
    func isConnected(_ id: UUID) -> Bool? {
        _ = generation
        if let s = redis[id] { return s.status == .connected ? true : (s.errorMessage != nil ? false : nil) }
        if let s = rabbit[id] { return s.status == .connected ? true : (s.errorMessage != nil ? false : nil) }
        return nil
    }
}

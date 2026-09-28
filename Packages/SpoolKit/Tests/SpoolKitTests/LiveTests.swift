import Foundation
import Testing
@testable import SpoolKit

/// Runs against real servers when they are reachable:
/// Redis on SPOOL_TEST_REDIS_PORT (default 6399) and RabbitMQ's
/// management API on localhost:15672 (guest/guest).
@Suite(.serialized) struct LiveRedisTests {
    static let port = Int(ProcessInfo.processInfo.environment["SPOOL_TEST_REDIS_PORT"] ?? "") ?? 6399

    func client() async throws -> RedisClient? {
        try? await RedisClient.connect(.init(port: Self.port, database: 9))
    }

    @Test func roundTripAndTypes() async throws {
        guard let c = try await client() else { return }
        let p = "spooltest:\(UUID().uuidString.prefix(6)):"
        defer { Task { _ = try? await c.delete(try await c.scanKeys(match: p + "*").keys) } }

        try await c.setString(p + "s", "{\"a\":1}")
        try await c.hashSet(p + "h", field: "name", value: "Anıl")
        try await c.listPush(p + "l", "one")
        try await c.listPush(p + "l", "two")
        try await c.listPush(p + "l", "one")
        try await c.setAdd(p + "set", "x")
        try await c.zsetAdd(p + "z", "m", score: 2.5)
        try await c.streamAdd(p + "x", fields: [("event", "created")])
        try await c.expire(p + "s", seconds: 100)

        let (keys, complete) = try await c.scanKeys(match: p + "*")
        #expect(complete)
        #expect(Set(keys) == Set(["s", "h", "l", "set", "z", "x"].map { p + $0 }))

        let infos = try await c.describe(keys.sorted())
        let byName = Dictionary(uniqueKeysWithValues: infos.map { ($0.name, $0) })
        #expect(byName[p + "s"]?.type == .string)
        #expect((byName[p + "s"]?.ttl ?? 0) > 90)
        #expect(byName[p + "h"]?.type == .hash)
        #expect(byName[p + "l"]?.length == 3)
        #expect(byName[p + "x"]?.type == .stream)

        #expect(try await c.value(of: p + "h", type: .hash) == .hash([(field: "name", value: Data("Anıl".utf8))]))
        // Removing by index keeps the other element with the same value.
        try await c.listRemove(p + "l", index: 0)
        #expect(try await c.value(of: p + "l", type: .list) == .list([Data("two".utf8), Data("one".utf8)]))

        try await c.rename(p + "set", to: p + "set2")
        await #expect(throws: RedisError.self) { try await c.rename(p + "set2", to: p + "h") }
    }

    @Test func concurrentPipelining() async throws {
        guard let c = try await client() else { return }
        let key = "spooltest:counter:\(UUID().uuidString.prefix(6))"
        try await withThrowingTaskGroup(of: Void.self) { g in
            for _ in 0..<500 { g.addTask { _ = try await c.connection.send(["INCR", key]) } }
            try await g.waitForAll()
        }
        #expect(try await c.connection.send(["GET", key]).int == 500)
        _ = try await c.delete([key])
    }

    @Test func consoleAndErrors() async throws {
        guard let c = try await client() else { return }
        let r = try await c.run(line: "ECHO \"hi there\"")
        #expect(r == .bulk(Data("hi there".utf8)))
        let e = try await c.run(line: "NOSUCHCOMMAND")
        if case .error = e {} else { Issue.record("expected error, got \(e)") }
        let info = try await c.info()
        #expect(info.version.first?.isNumber == true)
    }

    @Test func refusedConnectionFailsFast() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: (any Error).self) { _ = try await RedisClient.connect(.init(port: 1)) }
        #expect(clock.now - start < .seconds(3))
    }
}

@Suite(.serialized) struct LiveRabbitTests {
    func client() async -> RabbitClient? {
        let c = RabbitClient(.init(baseURL: URL(string: "http://localhost:15672")!))
        return (try? await c.overview()) != nil ? c : nil
    }

    @Test func queueLifecycle() async throws {
        guard let c = await client() else { return }
        let q = "spooltest.\(UUID().uuidString.prefix(6))"
        let dlq = q + ".dlq"
        try await c.declareQueue(q, vhost: "/")
        try await c.declareQueue(dlq, vhost: "/")
        defer { Task { try? await c.deleteQueue(q, vhost: "/"); try? await c.deleteQueue(dlq, vhost: "/") } }

        for i in 0..<3 {
            let routed = try await c.publish(exchange: "", vhost: "/", routingKey: dlq, payload: "{\"n\":\(i)}",
                                             properties: .init(contentType: "application/json", headers: ["tenant_id": .string("t1")]))
            #expect(routed)
        }
        let peeked = try await c.getMessages(queue: dlq, vhost: "/", count: 10, mode: .peek)
        #expect(peeked.count == 3)
        #expect(peeked.first?.headers["tenant_id"] == .string("t1"))
        #expect(JSONFormatter.pretty(peeked[0].payloadData) != nil)

        // Peeking puts messages back.
        try await Task.sleep(for: .seconds(1))
        let again = try await c.getMessages(queue: dlq, vhost: "/", count: 10, mode: .peek)
        #expect(again.count == 3)

        if await c.canMoveMessages() {
            try await c.moveMessages(from: dlq, to: q, vhost: "/")
            var moved: [RabbitMessage] = []
            for _ in 0..<20 where moved.count < 3 {
                try await Task.sleep(for: .milliseconds(500))
                moved = try await c.getMessages(queue: q, vhost: "/", count: 10, mode: .peek)
            }
            #expect(moved.count == 3)
        }

        try await c.purge(queue: q, vhost: "/")
        try await c.purge(queue: dlq, vhost: "/")
        #expect(try await c.getMessages(queue: dlq, vhost: "/", count: 10).isEmpty)

        let names = try await c.queues().map(\.name)
        #expect(names.contains(q))
        let overview = try await c.overview()
        #expect(overview.rabbitmqVersion != nil)
    }

    @Test func badPasswordIsReported() async throws {
        guard await client() != nil else { return }
        let c = RabbitClient(.init(baseURL: URL(string: "http://localhost:15672")!, password: "wrong"))
        await #expect(throws: RabbitError("Wrong username or password", status: 401)) { _ = try await c.overview() }
    }
}
